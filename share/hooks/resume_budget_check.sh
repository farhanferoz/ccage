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

over=0
{ [ "$n" -gt "$MAX" ] || [ "$bytes" -gt "$budget_bytes" ]; } 2>/dev/null && over=1

# --- last-seen size, so a shrinking write is recognised as progress ----------
state_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
state="$state_dir/.resume_budget_state"
prev=""
if [ -r "$state" ]; then
    prev="$(awk -F'\t' -v p="$fp" '$1 == p { v = $2 } END { print v }' "$state" 2>/dev/null)"
fi
if [ -d "$state_dir" ] && [ -w "$state_dir" ]; then
    tmp="$state.$$"
    { [ -r "$state" ] && awk -F'\t' -v p="$fp" '$1 != p' "$state" 2>/dev/null
      printf '%s\t%s\n' "$fp" "$bytes"
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$state" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
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
