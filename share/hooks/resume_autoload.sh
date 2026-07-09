#!/usr/bin/env bash
# ccage SessionStart hook — auto-load RESUME into context + cheap health check.
#
# Registered (by _ccage_seed_session_docs_hooks in claude-isolation.sh) on
# SessionStart for all four sources: startup, resume, clear, compact. A
# SessionStart hook's plain stdout is injected into the model's context for the
# next request, so after `/clear` the prior RESUME is reloaded with zero
# copy/paste — that is the whole point of the `clear` source.
#
# Behavior:
#   1. cat the slot-aware RESUME file (component G) to stdout, if present.
#   2. Emit at most two one-line NOTEs when state needs maintenance:
#        - RESUME over budget   → "run /checkpoint"
#        - memory dir messy      → "run /checkpoint --tidy"
#
# Always exits 0 — a SessionStart hook must never block a session from starting.
# Deliberately no `set -e`: a parse hiccup should no-op, not abort the start.
#
# Env (inherited from the claude process; all optional):
#   CCAGE_SLOT                slot suffix; validated, unsafe value → plain file
#   CCAGE_RESUME_BUDGET_LINES RESUME line budget before nagging (default 250)
#   CCAGE_RESUME_BUDGET_BYTES RESUME byte budget before nagging (default 14000)
#   CCAGE_MEMORY_ORPHAN_MAX   max un-indexed memory files before nagging (def 3)
#   CLAUDE_PROJECT_DIR        project root (falls back to $PWD)
#   CLAUDE_CONFIG_DIR         cage dir, for locating this cage's memory/

budget="${CCAGE_RESUME_BUDGET_LINES:-250}"
budget_bytes="${CCAGE_RESUME_BUDGET_BYTES:-14000}"
orphan_max="${CCAGE_MEMORY_ORPHAN_MAX:-3}"
base="${CLAUDE_PROJECT_DIR:-$PWD}"

# SessionStart delivers its trigger source (startup|resume|clear|compact) as JSON
# on stdin. Read it once — guarded by `timeout` when available so a blocked stdin
# can never hang session start (Claude Code closes stdin after the JSON, so the
# plain `cat` fallback returns on stock systems without `timeout`, e.g. macOS).
# Source is extracted with sed, not jq — stock macOS ships neither timeout nor
# jq, and a silently-empty $src would disable the marker clear and compact nudge.
if command -v timeout >/dev/null 2>&1; then
    hook_input="$(timeout 2 cat 2>/dev/null)"
else
    hook_input="$(cat 2>/dev/null)"
fi
src="$(printf '%s' "$hook_input" | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

# ---- slot-aware RESUME filename (component G) ----
# Mirror the wrapper's CCAGE_SLOT validation: an unsafe slot is ignored and we
# fall back to the plain file, exactly as _ccage_config_dir_for does.
slot=""
case "${CCAGE_SLOT:-}" in
    "")               ;;
    *[!A-Za-z0-9_-]*) ;;   # unsafe → ignore, use plain RESUME.md
    *)                slot=".${CCAGE_SLOT}" ;;
esac
resume="$base/RESUME${slot}.md"

# ---- 0. clear stale ccage-auto state on a genuinely new session ----
# Two transient files steer the background helpers and must not carry over:
#   .ccage-session-done  — written by `/checkpoint --final`; tells /keepwarm and
#                          ccage-auto the work is finished.
#   .ccage-autock.conf   — written by /checkpoint-threshold; a live soft/hard/
#                          pause override for a running ccage-auto watcher.
# Both must survive `/clear` (source=clear) so an autonomous run's own clear
# cycles keep the final-marker / threshold override in force — but starting fresh
# (source=startup) or resuming (source=resume, `claude -r`) means the user is
# working again, so state left over from a previous run would falsely quit or
# mis-tune today's helpers. Clear both on startup and resume only.
if [ "$src" = "startup" ] || [ "$src" = "resume" ]; then
    rm -f "$base/.ccage-session-done" "$base/.ccage-autock.conf" 2>/dev/null
fi

# ---- 1. inject RESUME into context ----
# Bounded: a runaway RESUME (the exact failure the budget NOTE below nags about)
# must degrade instead of flooding every session start. 2× budget is generous —
# the budget NOTE fires long before the cut is ever reached.
if [ -f "$resume" ]; then
    head -n $((budget * 2)) "$resume"
    if [ "$(wc -l < "$resume" 2>/dev/null | tr -d '[:space:]')" -gt "$((budget * 2))" ] 2>/dev/null; then
        printf '\nNOTE: RESUME truncated at %d lines for injection — run /checkpoint to trim it.\n' "$((budget * 2))"
    fi
fi

# ---- 1b. post-compaction nudge ----
# After auto-compaction (or a manual /compact) the conversation is summarized and
# the RESUME above is only as fresh as the last /checkpoint. A hook can't run the
# /checkpoint skill itself, so prompt the model to refresh RESUME before continuing.
if [ "$src" = "compact" ]; then
    printf '\nNOTE: context was just auto-compacted — run /checkpoint now to fold any work since your last checkpoint into RESUME.md, then continue.\n'
fi

# ---- 2. health notes (one line each, only when something is wrong) ----
# RESUME budget: too many lines, more than 3 "## Session" blocks, or too many
# bytes (a dense file — long lines — can bloat well under the line cap).
if [ -f "$resume" ]; then
    lines=$(wc -l < "$resume" 2>/dev/null | tr -d '[:space:]')
    blocks=$(grep -c '^## Session' "$resume" 2>/dev/null)
    bytes=$(wc -c < "$resume" 2>/dev/null | tr -d '[:space:]')
    [ -n "$lines" ] || lines=0
    [ -n "$blocks" ] || blocks=0
    [ -n "$bytes" ] || bytes=0
    if { [ "$lines" -gt "$budget" ] || [ "$blocks" -gt 3 ] || [ "$bytes" -gt "$budget_bytes" ]; } 2>/dev/null; then
        printf 'NOTE: RESUME is over budget — run /checkpoint to trim (roll shipped Threads/Decisions to CHANGELOG).\n'
    fi
fi

# Memory hygiene for THIS cage's memory dir (never another cage's).
# Claude Code's project slug: EVERY non-alphanumeric character becomes "-"
# (verified against real projects/ dirs: "/", "_" and "." all convert). tr, not
# a ${var//[^…]/} bracket class — macOS bash 3.2 mishandles such a class, so
# the tidy NOTE would silently never fire there.
slug=$(printf '%s' "$base" | LC_ALL=C tr -c 'A-Za-z0-9' '-')
memdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$slug/memory"
index="$memdir/MEMORY.md"
if [ -f "$index" ]; then
    needs_tidy=0

    # (a) dead index link: a referenced .md file that no longer exists.
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        [ -f "$memdir/$ref" ] || needs_tidy=1
    done < <(grep -oE '\]\([^)]+\.md\)' "$index" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//')

    # (b) orphans: memory files not represented in the index.
    if [ "$needs_tidy" -eq 0 ]; then
        files=$(find "$memdir" -maxdepth 1 -type f -name '*.md' ! -name 'MEMORY.md' 2>/dev/null | wc -l | tr -d '[:space:]')
        idx=$(grep -cE '^[[:space:]]*-[[:space:]]*\[' "$index" 2>/dev/null)
        [ -n "$files" ] || files=0
        [ -n "$idx" ] || idx=0
        [ "$((files - idx))" -gt "$orphan_max" ] && needs_tidy=1

        # (c) large flat index with no section headers at all.
        if [ "$needs_tidy" -eq 0 ] && [ "$files" -gt 8 ] && ! grep -q '^## ' "$index" 2>/dev/null; then
            needs_tidy=1
        fi
    fi

    [ "$needs_tidy" -eq 1 ] && printf 'NOTE: memory needs tidying — run /checkpoint --tidy.\n'
fi

exit 0
