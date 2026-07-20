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

# ---- instrumentation: record every SessionStart source ----
# Added 2026-07-20 while chasing "a --set threshold silently un-set itself
# minutes later, same transcript throughout" (Task 6, failure mode 4). Cheap,
# best-effort, append-only, never blocks a session start. Without this the
# only way to reconstruct what actually fired is cross-referencing the
# ccage-auto log against transcript birth times after the fact — this makes
# the next one a one-line grep instead of an investigation.
log_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -d "$log_dir" ]; then
    printf '%s  src=%s  base=%s  pid=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${src:-<empty>}" "$base" "$$" \
        >> "$log_dir/resume-autoload.log" 2>/dev/null
fi

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
#
# BUT both files are scoped to the PROJECT DIRECTORY, not to any one session —
# and `startup` fires for EVERY new session that starts in that directory, not
# just a restart of the one ccage-auto is actually watching. Confirmed live
# 2026-07-20 (see plans/wave2-task6-findings.md): an unrelated second session
# starting in the same repo wiped a control file a running `--set soft=45` had
# just written, ~2 minutes earlier, while the watched session's own transcript
# never restarted. So only clear when no OTHER `ccage-auto` watcher is
# currently alive for this directory — that is the one thing that actually
# depends on these files; a sibling session starting up must not step on it.
#
# First cut of this fix (superseded, see the same findings doc) scanned every
# process on the machine with `pgrep -f ccage-auto` + `lsof -a -p <pid> -d cwd`
# per match: measured 42x slower on a marker-file-present path (34ms -> 1.4s,
# dominated by lsof at ~110ms per match) AND unsafe — pgrep's substring match
# caught transient shells that merely *mentioned* "ccage-auto" in their
# command line (e.g. while profiling this very hook), with cwd == the project
# dir, so they satisfied the check and blocked a delete that should have
# happened. That's not a harmless false positive: a stale `.ccage-session-done`
# surviving a startup that should have cleared it makes /keepwarm and
# ccage-auto believe finished work is still finished when it isn't.
#
# Now: ccage-auto writes its own pid (+ a start-time token) to
# .ccage-autock.pid.<pid> when it starts watching this directory, and exports
# CCAGE_AUTOCK_WATCHER_PID into the launched session's environment so this
# hook can tell "the pidfile names MY OWN launcher" apart from "some other,
# still-running session's watcher" with a plain string compare — no process
# enumeration, no substring matching, no /proc, no lsof/pgrep. A deliberate
# restart under a fresh ccage-auto still clears stale state (its own pidfile
# write makes CCAGE_AUTOCK_WATCHER_PID match), exactly as before. No pidfile at
# all falls back to the original unconditional clear.
#
# ONE FILE PER WATCHER, and ANY live one blocks: two ccage-auto watchers in a
# single directory is an observed condition, and with a single shared record
# the second watcher's normal teardown deleted the first's ownership — after
# which this hook cleared conf/done state a live watcher was still using (the
# original "--set silently reverted" symptom). Each watcher now only ever
# writes and removes its own file, so a sibling exiting (or being SIGKILLed,
# leaving a dead record behind) cannot unrepresent a live one. The legacy
# unsuffixed name is still read, so a watcher started before an upgrade keeps
# its protection.
if [ "$src" = "startup" ] || [ "$src" = "resume" ]; then
    if [ -f "$base/.ccage-session-done" ] || [ -f "$base/.ccage-autock.conf" ]; then
        watcher_elsewhere=0
        for pidfile in "$base"/.ccage-autock.pid "$base"/.ccage-autock.pid.*; do
            # Unmatched glob stays literal in POSIX sh — the -f test drops it.
            [ -f "$pidfile" ] || continue
            wpid="$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' "$pidfile" | head -1)"
            wstart="$(sed -n 's/^start=\([0-9][0-9]*\)$/\1/p' "$pidfile" | head -1)"
            [ -n "$wpid" ] || continue
            [ "$wpid" != "${CCAGE_AUTOCK_WATCHER_PID:-}" ] || continue
            kill -0 "$wpid" 2>/dev/null || continue
            # Live, and not this session's own launcher. Guard against pid
            # reuse (ccage-auto exited without cleaning up, e.g. SIGKILL,
            # and an unrelated process later got the same pid): compare
            # the recorded start time against the CURRENT process at that
            # pid, via `ps -o etime=` (elapsed running time, not the
            # locale-dependent `lstart=` string) — cheap (~3ms measured)
            # and only ever runs in this already-rare branch. NOT
            # `etimes` (plural, seconds directly): that is a Linux/procps
            # extension, confirmed absent from the BSD/Darwin ps keyword
            # table — using it would silently no-op this whole guard on
            # macOS (empty output -> skipped -> watcher_elsewhere stays
            # 0 -> the guard this fix exists for never fires there). Parse
            # etime's `[[DD-]hh:]mm:ss` with awk instead (portable to
            # both gawk and BSD/nawk). No start token recorded (ps
            # unavailable at write time)? trust the pid alone rather than
            # block the delete on a check we can't perform.
            if [ -n "$wstart" ]; then
                now_etime_secs="$(ps -o etime= -p "$wpid" 2>/dev/null | awk '
                    {
                        s = $0
                        gsub(/^[ \t]+|[ \t]+$/, "", s)
                        days = 0
                        if (split(s, dparts, "-") == 2) { days = dparts[1] + 0; s = dparts[2] }
                        n = split(s, t, ":")
                        if (n == 2)      { h = 0; m = t[1]; sec = t[2] }
                        else if (n == 3) { h = t[1]; m = t[2]; sec = t[3] }
                        else             { exit 1 }
                        printf "%d\n", days*86400 + h*3600 + m*60 + sec
                    }')"
                [ -n "$now_etime_secs" ] || continue
                now_start=$(( $(date +%s) - now_etime_secs ))
                diff=$(( now_start - wstart ))
                [ "$diff" -lt 0 ] && diff=$(( -diff ))
                [ "$diff" -le 2 ] || continue
            fi
            watcher_elsewhere=1
            break
        done
        if [ "$watcher_elsewhere" -eq 0 ]; then
            rm -f "$base/.ccage-session-done" "$base/.ccage-autock.conf" 2>/dev/null
        fi
    fi
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

# ---- 1b. plan-doc pointers: the plan must be READ, not summarized from ----
# Measured failure (2026-07-16, user-reported, recurring): a resumed session
# acts on RESUME's summary bullets, never opens the plan doc they point to —
# tasks silently drop — and executes what's left sequentially, because a
# bullet list carries no dependency structure. RESUME is deliberately lean
# (the budget above enforces it), which makes its plan POINTERS load-bearing;
# this block re-asserts them, with a read-and-dispatch directive, at the exact
# moment they are about to be skipped. Best-effort and silent on any failure:
# a NOTE must never block or garble a session start. Only docs that actually
# exist on disk are named — a stale pointer earns silence, not a directive.
#
# Scope: the `### Plan` section ONLY. That section is where /checkpoint records
# the GOVERNING doc (exact path), so any .md under it governs by construction —
# no filename guessing. Scanning the whole RESUME instead (the prior approach)
# dragged in tangential/stale/foreign `PLAN.md` mentions from Session-block
# history and fired the dispatcher directive on sessions that weren't plan-
# governed at all. No `### Plan` section, or none of its refs on disk → this
# block emits nothing (a session that isn't plan-driven gets no directive).
if [ -f "$resume" ]; then
    plan_note=""
    # awk carves out the `### Plan` block (up to the next ## / ### heading);
    # grep then pulls any .md path token from it — filename-agnostic on purpose.
    plan_refs="$(awk '
            /^###[[:space:]]+Plan[[:space:]]*$/ { inplan=1; next }
            inplan && /^##/                     { inplan=0 }
            inplan
        ' "$resume" 2>/dev/null \
        | grep -oE '[~/A-Za-z0-9._-][A-Za-z0-9._/~-]*\.md' 2>/dev/null \
        | sort -u | head -5)"
    for ref in $plan_refs; do
        # shellcheck disable=SC2088  # the "~/" pattern matches literal text from RESUME; no expansion intended
        case "$ref" in
            "~/"*) cand="$HOME/${ref#\~/}" ;;
            /*)    cand="$ref" ;;
            *)     cand="$base/$ref" ;;
        esac
        if [ -f "$cand" ]; then
            plan_note="${plan_note}  - ${cand}
"
        fi
    done
    if [ -n "$plan_note" ]; then
        printf '\nNOTE: RESUME references the plan doc(s) below (verified present on disk).\n'
        printf 'RESUME is a summary, never the plan: READ each doc before executing any task\n'
        printf 'it governs. An execution-level plan with independent remaining tasks means\n'
        printf 'DISPATCHER mode — partition into dependency waves and dispatch concurrently;\n'
        printf 'never execute the list sequentially inline.\n%s' "$plan_note"
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
