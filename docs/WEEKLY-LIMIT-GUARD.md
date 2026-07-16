# Weekly-limit floor for `ccage-auto` (`CCAGE_AUTOCK_WEEKLY_FLOOR`)

**Status: implemented, v0.13.0 (2026-07-16). Default: OFF (opt-in).**

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

## As built

Maps each design part to where it landed. No part changed shape from the design above; the notes below are implementation-level detail and the one place the shipped behavior is more specific than the design's wording.

- **Part 1 — tee (sensor persistence).** `share/hooks/ccage-statusline-tee.sh` — reads stdin once, tees `{five_hour, seven_day, ts}` via `jq` (guarded by `command -v jq` and a `select(... != null)` filter) atomically (`mktemp` + `mv`) into `$CLAUDE_CONFIG_DIR/rate-limits-state.json`, then `exec bash -c "$1"` with the original stdin restored. `ts` is stamped by the tee at write time (`now | floor`), not left to file mtime, so a copied/restored state file can't masquerade as fresh — this is called out in the script's own header but is worth restating here since it's exactly the property the watcher's stale guard below depends on.
  Seeder: `_ccage_seed_statusline_tee` in `share/claude-isolation.sh` (function body + call site right after `_ccage_pre_exec_hook` in the `claude()` wrapper). Wraps/unwraps `statusLine.command` in a cage's `settings.json`, gated on `CCAGE_AUTOCK_WEEKLY_FLOOR`; two fast-path early-returns (armed+already-wrapped, disarmed+never-wrapped) skip the `python3` fork on the steady-state path since this runs on every caged launch.
- **Part 2 — watcher.** `bin/ccage-auto`: `Config.weekly_floor` (parsed from `CCAGE_AUTOCK_WEEKLY_FLOOR` / `--weekly-floor`), `Config.validate()` (out-of-range → disabled with a warning, never clamped — deliberately, per the design's "safe failure" note), `read_weekly_state()` (state-file parse + age calculation), and `Watcher._weekly_tick()` / `_arm_weekly()` / `_weekly_resume_note()` / `_weekly_warn_msg()` / `_weekly_floor_msg()` implement the three stages plus recovery exactly as designed: unknown sensor → no action, logged once (`wf_stale_logged`); warn at `floor + WEEKLY_WARN_MARGIN` (5.0); floor forces the checkpoint via the shared hard-backstop nudge/confirm/re-nudge machinery and then sets `self.stop = True`; recovery above `floor + 5` resets `wf_stage` from any state, including `"floored"`. `_weekly_tick()` is called from the main poll loop before the occupancy machine, and returning `True` (floored, still waiting on confirmation) makes the loop `continue` — skipping the occupancy machine entirely for that tick, exactly per the design's stated reason (a `/clear` would defeat the stand-down).
- **Part 3 — docs, doctor, install/uninstall.** `docs/FEATURES.md` gained the env/flag table and stage writeup this document points back to. `ccage-auto --status` prints a `weekly floor :` line (`share/ccage-doctor.sh` is a separate surface — see next). `share/ccage-doctor.sh` gained a report-only status line, `Weekly-limit floor (CCAGE_AUTOCK_WEEKLY_FLOOR): disabled.` / `... armed at <N>% remaining — sensor state in <X> of <Y> scanned cage(s).` — **this is more specific than the design's parenthetical** ("armed? floor? last sensor timestamp?"): the shipped line reports how many scanned cages currently carry a `rate-limits-state.json` file at all (a plain `[ -f ]` existence count, not a parsed/aged reading), not a timestamp of the most recent sensor write. `_ccage_doctor_unseed` (the function behind `ccage doctor --unseed`) also unwraps a wrapped `statusLine` back to its original command, and `install.sh` / `uninstall.sh` deploy/remove the tee script at the fixed hooks path — both were not explicitly spelled out as doctor/install responsibilities in the design's Part 3 bullet, which only mentioned the `FEATURES.md` entry, the env-var table, and the doctor line; unwrap-on-uninstall and unwrap-on-unseed are a direct consequence of Part 1's wrap being a persistent `settings.json` mutation, so leaving them out would have meant an uninstall or `--unseed` run could strand a cage pointing at a deleted script.

## Test plan (bats, alongside existing `test_autock.bats`)

- Tee: fake statusline input with/without `.rate_limits` → state file written/not; malformed
  JSON → real statusline still runs, no state write; atomicity (no partial file on kill).
- Watcher: synthetic state files (fresh/stale/missing; remaining above/at-warn/at-floor) →
  correct stage transitions, nudge text, stand-down marker, RESUME note; feature absent env →
  zero behavior change (the off-by-default proof).
