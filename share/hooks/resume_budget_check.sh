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

input="$(cat)"
fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
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
next_n="$(awk '/^### Next/{f=1;next} /^### /{f=0} f && /^[0-9]+\./{c++} END{print c+0}' "$fp" 2>/dev/null)"

over=0
{ [ "$n" -gt "$MAX" ] || [ "$bytes" -gt "$budget_bytes" ]; } 2>/dev/null && over=1

# --- last-seen size, so a shrinking write is recognised as progress ----------
state_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
state="$state_dir/.resume_budget_state"
prev=""; prev_next=""
if [ -r "$state" ]; then
    # BOTH previous values must be read BEFORE the rewrite below — reading
    # prev_next afterwards compares the new value against itself, which silently
    # disabled the shrink check entirely (caught by the behavioural test).
    prev="$(awk -F'\t' -v p="$fp" '$1 == p { v = $2 } END { print v }' "$state" 2>/dev/null)"
    prev_next="$(awk -F'\t' -v p="$fp" '$1 == p { v = $3 } END { print v }' "$state" 2>/dev/null)"
fi
if [ -d "$state_dir" ] && [ -w "$state_dir" ]; then
    tmp="$state.$$"
    { [ -r "$state" ] && awk -F'\t' -v p="$fp" '$1 != p' "$state" 2>/dev/null
      printf '%s\t%s\t%s\n' "$fp" "$bytes" "$next_n"
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
    cat >&2 <<MSG
RESUME '### Next' SHRANK: $prev_next items -> ${next_n:-0}. Blocked once, deliberately.

'### Next' is the only durable record of pending work, and RESUME is git-excluded
— dropped items are unrecoverable. Confirm each removed item is genuinely done
(roll it to CHANGELOG.md) rather than forgotten, then re-issue this same write:
the count is already recorded, so the retry goes through.
Escape hatch: CCAGE_RESUME_BUDGET_MODE=observe
MSG
    exit 2
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
    jq -cn --arg m "$note" \
      '{systemMessage:$m, hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$m}}'
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
