#!/usr/bin/env bash
# ccage PostToolUse(Write|Edit) guard — keep RESUME lean.
#
# Vendored into ccage (was a loose ~/.claude/hooks file with no repo home).
# install.sh deploys it to ~/.claude/hooks/resume_budget_check.sh; the seeded
# hooks block (see _ccage_seed_session_docs_hooks in claude-isolation.sh)
# references it by absolute path.
#
# ENFORCES as of 2026-08-10 (was advisory-only since inception).
#
# WHY THE CHANGE: this hook checks a purely MECHANICAL fact — a file's size
# against a number — and used to only print about it. Measured that day: it
# fired three times in one session and was ignored twice, while RESUME sat 38%
# over budget. An advisory hook enforcing a mechanical rule is the worst of both
# worlds; it costs tokens every time and binds nothing. The pattern that does
# work is code_hygiene_check.sh's: exit 2 so stderr is fed back to the model as
# a blocking error it must handle before moving on.
#
# PostToolUse fires AFTER the write, so this cannot prevent one. It makes the
# breach impossible to walk past, which is the available lever at this event.
#
# PROGRESS IS NEVER PUNISHED. Blocking every write to an over-budget file would
# also block the trimming that fixes it — training exactly the "ignore the hook"
# reflex this change exists to break. So a write that SHRINKS the file is only
# ever advised, never blocked; the last-seen size is kept in a small state file.
#
# Escape hatch: CCAGE_RESUME_BUDGET_MODE=observe restores advisory-only.
# Deliberately no `set -e`: a hook that aborts on a parse hiccup is worse than
# one that no-ops.
MAX=3

# Advisory note as PostToolUse JSON. jq when it is there; a hand-rolled fallback
# when it is not, because the whole point of the jq handling below is that this
# guard degrades loudly instead of disappearing. Newlines are folded — a note is
# one line by construction, and an unescaped one would produce invalid JSON.
emit_note() {
    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg m "$1" \
          '{systemMessage:$m, hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$m}}'
    else
        esc="$(printf '%s' "$1" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g')"
        printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' \
            "$esc" "$esc"
    fi
}

input="$(cat)"
# jq FIRST, sed as the fallback — not the other way round: jq parses JSON
# correctly, sed only pattern-matches it. But stock macOS ships no jq, and
# without the fallback this guard SWITCHED ITSELF OFF SILENTLY there: no path,
# no check, no word about either (found 2026-08-11 by running it with jq off the
# PATH). A guard that is absent must never look like a guard that passed.
fp=""
command -v jq >/dev/null 2>&1 && \
    fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
if [ -z "$fp" ]; then
    fp="$(printf '%s' "$input" \
        | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi
[ -n "$fp" ] || exit 0
case "$(basename -- "$fp")" in
    RESUME.md|RESUME.*.md) ;;
    *) exit 0 ;;
esac
[ -f "$fp" ] || exit 0

# Read via stdin redirection so a file_path beginning with '-' can't be parsed
# as a grep option (Claude Code supplies absolute paths, but be defensive).
n="$(grep -c '^## Session' < "$fp" 2>/dev/null)"
bytes="$(wc -c < "$fp" 2>/dev/null | tr -d '[:space:]')"
[ -n "$n" ] || n=0
[ -n "$bytes" ] || bytes=0
budget_bytes="${CCAGE_RESUME_BUDGET_BYTES:-14000}"

# Counted BEFORE the state write below, which records it.
#
# The pattern must match what a READER counts as an item, or the guard defends a
# different list from the one people maintain. `^[0-9]+\.` — the original — saw 8
# of the 11 items in this repo's own RESUME: `7b.` and `7c.` (letter suffixes,
# the normal way an item is split) and `1–3.` (an en-dash range) were invisible,
# so deleting one of them passed silently. That is precisely the silent drop this
# check exists to catch. Now: a line starting with a digit, then any non-space
# run, then a dot and a space. Verified against the live file — 11 of 11.
next_n="$(awk '/^### Next/{f=1;next} /^### /{f=0} f && /^[0-9][^[:space:]]*\.[[:space:]]/{c++} END{print c+0}' "$fp" 2>/dev/null)"

# The LABELS too, not just how many. A count can only say "you lost one"; the
# labels say WHICH — and since RESUME is git-excluded, that difference is the
# difference between a recoverable mistake and a lost one. Comma-joined; item
# labels never contain a comma or a tab.
next_labels="$(awk '/^### Next/{f=1;next} /^### /{f=0}
    f && /^[0-9][^[:space:]]*\.[[:space:]]/ { out = out (out ? "," : "") $1 }
    END { print out }' "$fp" 2>/dev/null)"

over=0
{ [ "$n" -gt "$MAX" ] || [ "$bytes" -gt "$budget_bytes" ]; } 2>/dev/null && over=1

# --- last-seen size, so a shrinking write is recognised as progress ----------
state_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
state="$state_dir/.resume_budget_state"
prev=""; prev_next=""; prev_labels=""
if [ -r "$state" ]; then
    # ALL previous values must be read BEFORE the rewrite below — reading
    # prev_next afterwards compares the new value against itself, which silently
    # disabled the shrink check entirely (caught by the behavioural test).
    prev="$(awk -F'\t' -v p="$fp" '$1 == p { v = $2 } END { print v }' "$state" 2>/dev/null)"
    prev_next="$(awk -F'\t' -v p="$fp" '$1 == p { v = $3 } END { print v }' "$state" 2>/dev/null)"
    prev_labels="$(awk -F'\t' -v p="$fp" '$1 == p { v = $4 } END { print v }' "$state" 2>/dev/null)"
fi
if [ -d "$state_dir" ] && [ -w "$state_dir" ]; then
    tmp="$state.$$"
    # Entries for files that no longer exist are dropped on every rewrite. The
    # file otherwise only grows: this cage's held 8 entries, 7 of them dead
    # /tmp paths from old test runs (2026-08-11). Cheap, and it keeps the one
    # line that matters readable when someone inspects the state by hand.
    { if [ -r "$state" ]; then
          while IFS='	' read -r sp sb sn sl; do
              [ -n "$sp" ] || continue
              [ "$sp" = "$fp" ] && continue
              [ -e "$sp" ] || continue
              printf '%s\t%s\t%s\t%s\n' "$sp" "$sb" "$sn" "$sl"
          done < "$state"
      fi
      printf '%s\t%s\t%s\t%s\n' "$fp" "$bytes" "$next_n" "$next_labels"
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$state" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
fi

# ---- ### Next must not silently SHRINK ------------------------------------
# WHY: RESUME's `### Next` is the source of truth for pending work, and the
# measured failure (2026-08-10) is enumerating that work from MEMORY instead of
# reading it — which silently dropped 4 live items from a next-session plan.
# A checkpoint that rewrites `### Next` can drop items the same way, and RESUME
# is git-excluded, so there is no history to recover them from.
#
# The check is mechanical: count the numbered items, and block a write that
# reduces the count. It does NOT judge whether the removal was right — it forces
# one conscious look. The state is updated BEFORE the block, so an immediate
# re-issue of the same write passes: this is a confirm-once speed bump, never a
# deadlock. Legitimately finished items should be rolled to CHANGELOG.
if [ -n "$prev_next" ] && [ "${next_n:-0}" -lt "$prev_next" ] 2>/dev/null \
   && [ "${CCAGE_RESUME_BUDGET_MODE:-}" != "observe" ]; then
    # WHICH items went, not just how many. The count alone left the reader to
    # diff a file they no longer have (PostToolUse fires after the write, and
    # RESUME is git-excluded), so "unrecoverable" was literally true. Naming them
    # makes restoring a copy-paste. Labels are recorded from the previous write.
    missing=""
    if [ -n "$prev_labels" ]; then
        for lbl in $(printf '%s' "$prev_labels" | tr ',' ' '); do
            case ",${next_labels}," in
                *",$lbl,"*) ;;
                *) missing="${missing}${missing:+ }$lbl" ;;
            esac
        done
    fi
    cat >&2 <<MSG
RESUME '### Next' SHRANK: $prev_next items -> ${next_n:-0}. Blocked once, deliberately.
${missing:+GONE: $missing}

'### Next' is the only durable record of pending work, and RESUME is git-excluded
— dropped items are unrecoverable. Confirm each removed item is genuinely done
(roll it to CHANGELOG.md) rather than forgotten, then re-issue this same write:
the count is already recorded, so the retry goes through.
Escape hatch: CCAGE_RESUME_BUDGET_MODE=observe
MSG
    exit 2
fi

# ---- first write for this file: say so, do not go quiet ---------------------
# The shrink check above needs a previous count, so on a fresh cage — no state
# file — it cannot fire at all, and the FIRST checkpoint could drop every item
# in silence (live-fired 2026-08-11: rc=0, no output). The check cannot be made
# retroactive, but its absence can be made visible: announce the baseline once,
# so "the guard has nothing to compare against yet" is never mistaken for "the
# guard looked and was happy".
if [ -z "$prev_next" ] && [ "${next_n:-0}" -gt 0 ]; then
    emit_note "RESUME baseline recorded: ${next_n} items in '### Next' ($next_labels). No previous count existed in this cage, so nothing could be compared this time — a later write that drops any of them will be blocked."
fi

[ "$over" = 1 ] || exit 0

msg="RESUME is ${bytes} bytes / $n session blocks (budgets: ${budget_bytes} bytes, ${MAX} blocks). Roll shipped ### Threads and memory-duplicated ### Decisions into CHANGELOG — keep RESUME lean."

# Advisory when: explicitly in observe mode, OR this write made the file smaller
# (trimming in progress — never block the fix).
shrinking=0
if [ -n "$prev" ] && [ "$bytes" -lt "$prev" ] 2>/dev/null; then shrinking=1; fi
if [ "${CCAGE_RESUME_BUDGET_MODE:-}" = "observe" ] || [ "$shrinking" = 1 ]; then
    note="$msg"
    [ "$shrinking" = 1 ] && note="$msg (was ${prev} B — shrinking, keep going)"
    emit_note "$note"
    exit 0
fi

# ENFORCE: the file is over budget and this write did not reduce it.
cat >&2 <<MSG
$msg

This is a blocking error because the write did not reduce the file. Bring RESUME
back under budget now, before continuing:
  - move shipped ### Threads and superseded ### Decisions into CHANGELOG.md
  - collapse handled ### Stuck-subagent alerts / agent snapshots
  - keep at most ${MAX} '## Session' blocks; older detail belongs in git history
A write that SHRINKS the file is never blocked, so trimming will go through.
Escape hatch if this is genuinely wrong right now: CCAGE_RESUME_BUDGET_MODE=observe
MSG
exit 2
