#!/usr/bin/env bash
# ccage PostToolUse(Write|Edit) guard — keep RESUME lean.
#
# Vendored into ccage (was a loose ~/.claude/hooks file with no repo home).
# install.sh deploys it to ~/.claude/hooks/resume_budget_check.sh; the seeded
# hooks block (see _ccage_seed_session_docs_hooks in claude-isolation.sh)
# references it by absolute path.
#
# Reads the hook JSON on stdin; if the edited file is a RESUME file — RESUME.md
# or the slot-aware RESUME.<slot>.md (component G) — with more than MAX top-level
# "## Session" blocks, surfaces a NON-BLOCKING reminder (to both the user and
# the model) to archive old blocks into CHANGELOG. Silent + exit 0 in every
# other case. Deliberately no `set -e`: a hook that aborts on a parse hiccup is
# worse than one that no-ops.
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

if { [ "$n" -gt "$MAX" ] || [ "$bytes" -gt "$budget_bytes" ]; } 2>/dev/null; then
  msg="RESUME is ${bytes} bytes / $n session blocks (budgets: ${budget_bytes} bytes, ${MAX} blocks). Roll shipped ### Threads and memory-duplicated ### Decisions into CHANGELOG — keep RESUME lean."
  jq -cn --arg m "$msg" \
    '{systemMessage:$m, hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$m}}'
fi
exit 0
