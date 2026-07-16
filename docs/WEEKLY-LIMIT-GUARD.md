# Weekly-limit floor for `ccage-auto` (`CCAGE_AUTOCK_WEEKLY_FLOOR`)

**Status: designed 2026-07-16, NOT implemented. Target: v0.13.0. Default: OFF (opt-in).**

## Problem (user-stated)

`ccage-auto` manages *context* (auto-checkpoint at occupancy thresholds) but is blind to the
*weekly usage limit*. An unattended autonomous run can burn the week's capacity; the user wants
a floor: "when remaining weekly capacity drops to X%, warn the sessions to checkpoint — because
they will be closed." Opt-in, off by default.

## The sensor — verified 2026-07-16, no guessing

Claude Code passes the server-side rate-limit state to every statusline render. The user's own
`~/.claude/statusline-command.sh` already consumes it (lines 7–8):

```
FIVE_H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
WEEK=$(echo "$input"  | jq -r '.rate_limits.seven_day.used_percentage // empty')
```

So the weekly percentage is available to LOCAL code, fresh on every statusline render, with no
credential handling and no undocumented API. This is the only sensor this feature uses.
(`ccusage` was considered and rejected for this purpose: it estimates *local token spend* from
transcripts; it cannot know the server-side seven-day percentage.)

## Design

Three small parts, all fail-open:

1. **Tee (sensor persistence).** ccage wraps the configured statusline command: on each render,
   if stdin JSON carries `.rate_limits`, atomically write
   `{"five_hour": .., "seven_day": .., "ts": <epoch>}` to
   `$CLAUDE_CONFIG_DIR/rate-limits-state.json`, then exec the user's real statusline with the
   original stdin. Wrapper adds one `jq` call per render; any error → skip the tee, never break
   the statusline. Seeding the wrapped command follows the existing UI-only statusLine seeding
   path.
2. **Watcher (in `ccage-auto`'s existing checkpoint watcher loop).** When armed
   (`CCAGE_AUTOCK_WEEKLY_FLOOR=<remaining-%>`, or flag `--weekly-floor N`):
   - read the state file; `remaining = 100 - seven_day.used_percentage`;
   - **stale guard**: state older than 30 min → treat as unknown, do nothing (log once);
   - **warn stage** (`remaining <= floor + 5`): inject the existing nudge channel — "weekly
     limit nearly at the configured floor: checkpoint now; this run stands down at the floor";
   - **floor stage** (`remaining <= floor`): force `/checkpoint` via the existing hard-backstop
     mechanism, append a `RESUME.md` note ("stood down at weekly floor, N% remaining, resets
     <ts if available>"), and stand the auto run down (no further auto-driven turns). Sessions
     are then safe to be closed.
3. **Docs**: `FEATURES.md` entry + env-var table row + `ccage-doctor` line (armed? floor? last
   sensor timestamp?).

## Decisions locked

- **Opt-in, default off** (user-stated). Same posture as `CCAGE_SESSION_DOCS` /
  `CCAGE_SEED_LOCAL_HOOKS`.
- Floor is expressed as **remaining percent** (matches how the user thinks about it), not
  used-percent.
- The guard **warns then stands down**; it never kills a mid-turn session (data loss). The
  checkpoint IS the shutdown preparation.
- Five-hour limit is out of scope for v1 (it recovers on its own within the run's horizon);
  the state file records it anyway so a later version can use it for pacing.

## Non-goals

- No OAuth/credentials scraping, no reliance on undocumented endpoints.
- No enforcement outside `ccage-auto` (interactive sessions just keep showing the statusline).
- No cost accounting (that is `ccusage` / `agent-cost` territory).

## Test plan (bats, alongside existing `test_autock.bats`)

- Tee: fake statusline input with/without `.rate_limits` → state file written/not; malformed
  JSON → real statusline still runs, no state write; atomicity (no partial file on kill).
- Watcher: synthetic state files (fresh/stale/missing; remaining above/at-warn/at-floor) →
  correct stage transitions, nudge text, stand-down marker, RESUME note; feature absent env →
  zero behavior change (the off-by-default proof).
