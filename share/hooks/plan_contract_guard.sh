#!/usr/bin/env bash
# PreToolUse guard (Edit|Write|MultiEdit) — a plan item is done when its check passes.
#
# For any markdown file with a `## Progress` section, compares the Progress items before
# and after the edit (rules and plan format: lib/ccage_plan.py header):
#   * ticking `- [ ]` -> `- [x]` needs the item's `done when` command to exit 0;
#   * dropping an item, or changing its ID/title/write set/done-when, needs a line
#     `owner approved: "<quote>"` whose quote appears in a user turn of this session.
# Everything else is allowed. Any internal error allows the edit and is logged.
#
# Exit codes: 0 = allow; 2 = block (stderr becomes model guidance).
# Log (allow, deny, error): ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plan_contract_guard.log
# The logic lives in ccage_plan.py, installed beside this script (checkout: ../../lib).

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for helper in "$here/ccage_plan.py" "$here/../../lib/ccage_plan.py"; do
    [ -f "$helper" ] && break
done
if ! command -v python3 >/dev/null 2>&1 || [ ! -f "$helper" ]; then cat >/dev/null; exit 0; fi
exec python3 "$helper" guard
