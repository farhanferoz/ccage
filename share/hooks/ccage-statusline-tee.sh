#!/usr/bin/env bash
# ccage statusline tee — persist the server-side rate-limit state, then run the
# real statusline.
#
# Claude Code passes rate-limit state (.rate_limits.{five_hour,seven_day}.
# {used_percentage,resets_at}) to every statusline render, and NOWHERE else that
# local code can reach without credential handling. This wrapper is the sensor
# for the ccage-auto weekly-limit floor (CCAGE_AUTOCK_WEEKLY_FLOOR): on each
# render it tees that state into $CLAUDE_CONFIG_DIR/rate-limits-state.json,
# then execs the user's real statusline command with the original stdin.
#
# The seeded statusLine.command becomes:  bash <this-script> '<original command>'
# (see _ccage_seed_statusline_tee in share/claude-isolation.sh).
#
# FAIL-OPEN by design: a missing jq, malformed payload, absent .rate_limits, or
# unwritable state file all skip the tee and still run the real statusline — a
# broken sensor must never break the status bar. The state write is atomic
# (mktemp + mv) so a reader never sees a partial file. Deliberately no `set -e`.

input="$(cat)"

state_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
state="$state_dir/rate-limits-state.json"

if command -v jq >/dev/null 2>&1 && [ -d "$state_dir" ]; then
    # Both windows are recorded (the floor only reads seven_day; five_hour is
    # kept for a later pacing feature). `ts` is the write time — the watcher's
    # 30-min stale guard keys on it, not on file mtime, so a copied/restored
    # file can't masquerade as fresh.
    rl="$(printf '%s' "$input" | jq -c \
        'select((.rate_limits.five_hour // .rate_limits.seven_day) != null)
         | {five_hour: .rate_limits.five_hour,
            seven_day: .rate_limits.seven_day,
            ts: (now | floor)}' 2>/dev/null)" || rl=""
    if [ -n "$rl" ]; then
        if tmp="$(mktemp "$state.XXXXXX" 2>/dev/null)"; then
            if printf '%s\n' "$rl" > "$tmp" 2>/dev/null; then
                mv -f "$tmp" "$state" 2>/dev/null || rm -f "$tmp" 2>/dev/null
            else
                rm -f "$tmp" 2>/dev/null
            fi
        fi
    fi
fi

# Hand the ORIGINAL stdin to the real statusline. The wrapped command arrives
# as a single argument (quoted by the seeder) and ran under a shell before we
# existed, so run it under one again. No argument → tee-only: emit nothing.
if [ "$#" -gt 0 ] && [ -n "$1" ]; then
    printf '%s' "$input" | exec bash -c "$1"
fi
exit 0
