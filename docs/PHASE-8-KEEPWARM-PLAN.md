# Phase 8 — Cache Keep-Warm Hook (Plan v1)

Workflow: **spike first (S0 gates the architecture), then implement each subphase
TDD-style (bats first), self-review when a subphase reports green.** Same rhythm as
PLAN.md / PHASE-6 / PHASE-7.

> **How to use this plan.** Self-contained — a fresh session can implement it. Before
> writing code, read: `share/hooks/resume_budget_check.sh` (hook style: stdin JSON, jq,
> no `set -e`, always exit 0), `share/claude-isolation.sh` lines ~160–280
> (`_ccage_seed_session_docs_hooks` — the settings-merge pattern this phase clones,
> incl. the grep fast-path and the "KEEP IN SYNC with `_ccage_doctor_seed`" contract),
> `share/ccage-doctor.sh` (backfill + worklist), `install.sh` / `uninstall.sh`
> (session-docs asset wiring), `tests/test_budget_check.bats` + `tests/test_seed_hooks.bats`
> (test style). All paths repo-relative from `/home/ff235/dev/ccage`.

---

## Why

Anthropic's prompt cache expires after a TTL of inactivity — 5 minutes on API-key auth,
1 hour on subscription auth (measured on this machine 2026-06-05: 7,815/7,821 recent
cache-writing requests used the 1h tier). Each *use* of the cached prefix resets the
clock. When a session sits idle past the TTL, the next turn rewrites the entire
conversation prefix at the cache-write rate (2× input on the 1h tier) instead of
reading it at 0.1×. A read costs ~5–8% of a rewrite, so refreshing the cache just
before expiry is strictly cheaper than letting it lapse — up to a break-even of
roughly 12–20 refreshes (≈ a working day on the 1h tier).

There is no upstream feature for this. Community keep-alive tools exist for the
5-minute tier (Stop-hook based, sleep ~240 s then force a turn); nothing ships for the
1-hour tier, and nothing integrates with ccage's per-cage seeding.

## Goal

An opt-in, per-cage **keep-warm hook**: after a turn ends, if the session stays idle
for `interval` minutes (default **55**), force one minimal turn through Claude Code
itself — refreshing the cache TTL from inside the session, with a hard cap on
consecutive pings. Configurable interval; safe-by-default; zero new daemons; zero
direct API calls by ccage (the ping rides Claude Code's own request path, so the
byte-identical-prefix problem never arises).

## Non-goals

- **No external request replay.** ccage never reconstructs or replays API requests
  (the resume bug demonstrates byte-exact reconstruction is infeasible from outside).
- **Not a resume fix.** A warm cache does not survive `claude -r` (structural miss,
  GitHub #51764); keep-warm only pays off when returning to the *same live session*.
- **No subagent coverage.** Subagents always use the 5m tier; their caches are small
  and not worth pinging. Only the main-agent `Stop` event is hooked (never
  `SubagentStop`).
- **No auto-detection of the user's TTL tier in v1.** The default (55 min) assumes the
  1h tier. API-key users set the interval to ≤4. (A tier-sniff warning is a stretch
  goal, S5.)

---

## S0 — SPIKE (gates everything; do this before any implementation)

The load-bearing unknown: **what happens to an interactive session while a `Stop` hook
is still running?** Three questions, each with an empirical test on this machine
(pattern: the pty harness from `/tmp/ccage-smoke-pty.py`, 2026-06-05 — drive a real
`claude` TUI in a pty, observe):

| # | Question | Test | Pass criterion |
|---|---|---|---|
| S0.1 | Can a `Stop` hook run long? Is the per-hook `timeout` field honored beyond 60 s (need ≈ `interval*60+120` s)? | Register a Stop hook that sleeps 90 s with `"timeout": 200`, end a turn, watch whether it's killed at 60 s or runs to completion. | Hook survives ≥ 90 s. |
| S0.2 | Does a sleeping Stop hook **block user input** (can the user type and submit a new prompt while the hook sleeps)? | While the 90 s hook sleeps, send keystrokes + Enter through the pty; check whether a new turn starts. | New turn starts while hook sleeps (= non-blocking), **or** input is queued and the hook can detect activity and exit (acceptable if queued input is processed promptly after hook exit). |
| S0.3 | Does `{"decision":"block","reason":"…"}` emitted after a long sleep still force a continuation turn, and does the follow-up `Stop` event carry `stop_hook_active: true`? | Hook sleeps 60 s then emits block; observe a model turn and capture the next Stop payload to a temp file. | Model produces a turn; next Stop fires; no infinite chain when the hook then exits 0. |

**Decision tree:**
- S0.1 ∧ S0.3 pass, S0.2 acceptable → **Architecture A** (Stop-hook sleeper, below).
- S0.2 fails hard (UI frozen for the full sleep, queued input lost or badly delayed) →
  **Architecture B** (skill-based scheduler): ship `/keepwarm [minutes]` as a skill that
  instructs the agent to self-schedule a trivial wake turn on the interval (harness
  scheduling — `/loop`-style). No hook, no seeding; document in FEATURES; close the
  phase small. The config surface below still applies where meaningful.
- S0.1 fails (hard timeout cap < interval) → Architecture B, or A with chained short
  hooks **only if** the chain is clean (not worth heroics — prefer B).

Record S0 results in this file under a `## S0 results` heading before proceeding.

---

## Architecture A — Stop-hook keep-warm (primary)

### New file: `share/hooks/keepwarm.sh`

Style contract: same as `resume_budget_check.sh` — bash, stdin JSON, `jq`, no `set -e`,
**every** path exits 0 except the single deliberate block emission. Logic:

1. **Gate:** `[ -n "${CCAGE_KEEPWARM:-}" ] || exit 0`; `[ -n "${CCAGE_NO_KEEPWARM:-}" ] && exit 0`.
2. **Parse stdin:** `session_id`, `transcript_path`, `stop_hook_active` (jq; missing → exit 0).
3. **Config (env, all validated numerically, defaults):**
   `CCAGE_KEEPWARM_INTERVAL_MIN` (default `55`; clamp to `[1, 590]`),
   `CCAGE_KEEPWARM_MAX_PINGS` (default `6`; `0` = unlimited is **not** allowed — clamp to ≥1),
   `CCAGE_KEEPWARM_MIN_TOKENS` (default `20000`).
4. **Min-context guard:** cheapest peak estimate straight off the transcript —
   `jq -r '.message.usage.cache_read_input_tokens // 0' "$transcript_path" | sort -n | tail -1`
   style single pass (match the streaming pattern used in `share/ccage-handoff.sh`;
   do **not** source the handoff lib from a hook). Below `MIN_TOKENS` → exit 0
   (rewrite would be too cheap to bother saving).
5. **State + lock:** dir `"$(dirname "$transcript_path")/.ccage-keepwarm/"`, files
   `<session_id>.count` and `<session_id>.lock`. Lock = write own `$$` + a nonce;
   newest-writer-wins takeover: each sleep slice, re-read the lock; if it no longer
   matches, a newer Stop fired — exit 0 silently. (This handles back-to-back turns:
   every Stop spawns a hook; only the latest keeps its timer.)
6. **Cap check:** `count ≥ MAX_PINGS` → exit 0 (leave count; it resets on real user
   activity, step 8).
7. **Sleep loop:** total `INTERVAL_MIN*60` seconds in 30 s slices (slice length via
   `CCAGE_KEEPWARM_SLICE_SECS`, default 30 — injectable for tests). Each slice:
   a. lock stolen → exit 0;
   b. transcript `mtime` advanced since loop start → *user/agent activity* → reset
      `count` to 0, exit 0 (the new turn's own Stop hook re-arms);
   c. transcript deleted or parent claude process gone (`kill -0 $PPID`) → cleanup
      state files, exit 0;
   d. **suspend detection:** if wall-clock jumped more than `2×slice` over one slice
      (laptop slept), and total elapsed real time exceeds the TTL window, the cache is
      already dead → exit 0 *without* pinging (a post-expiry ping pre-pays the rewrite
      for nothing).
8. **Ping:** increment count file, then emit
   `{"decision":"block","reason":"ccage keep-warm ping <n>/<max> — cache TTL refresh. Reply with exactly: warm. Do not run tools or take any other action."}`
   and exit 0. The forced turn re-reads the prefix (cache hit → TTL reset). Its own
   Stop event re-enters this script (with `stop_hook_active: true` — we *do* re-arm;
   the flag is informational here, the cap + timer prevent loops).
9. **Never** block when `stop_hook_active` is true **and** the count file's mtime is
   < 5 s old (belt-and-suspenders against a pathological insta-loop if a future Claude
   Code version fires Stop without honoring the sleep).

### Seeding: `_ccage_seed_keepwarm_hook()` in `share/claude-isolation.sh`

Clone of `_ccage_seed_session_docs_hooks` (lines ~173–280), gated on `CCAGE_KEEPWARM`:

- Merges one entry: `hooks.Stop → [{hooks:[{type:"command", command:"bash <hooks_dir>/keepwarm.sh", timeout: <INTERVAL*60+120>}]}]`.
- Same invariants: grep fast-path on `keepwarm.sh`, basename dedup, mode-preserving
  `mkstemp` rewrite, never clobber unparseable JSON, python merge marked
  **KEEP IN SYNC** with the doctor copy.
- **Timeout staleness rule:** if the seeded `timeout` no longer matches the configured
  interval (user changed `CCAGE_KEEPWARM_INTERVAL_MIN`), update the entry in place
  (the fast-path grep must therefore also verify the timeout value — grep for
  `"timeout": <expected>` alongside the basename; mismatch → run the merge).
- Called from `_ccage_bootstrap_dir`'s call site right after
  `_ccage_seed_session_docs_hooks "$CLAUDE_CONFIG_DIR"` (line ~626).

### Doctor: `share/ccage-doctor.sh`

- Backfill: extend `_ccage_doctor_seed`'s merge to include the Stop entry **only when**
  `CCAGE_KEEPWARM` is set in the environment (doctor inherits the user's overrides).
- Worklist: report cages whose seeded timeout mismatches the current interval.
- `--dry-run` honors both, as today.

### install / uninstall

- `install.sh`: deploy `share/hooks/keepwarm.sh` → `~/.claude/hooks/keepwarm.sh`
  alongside the two session-docs hooks (same `--no-session-docs` bundle — no new flag;
  the file is inert without `CCAGE_KEEPWARM=1`).
- `uninstall.sh`: remove the file; per existing policy, seeded `settings.json` entries
  in cages are left (documented; they no-op once the script is gone — Claude Code
  tolerates a missing hook command with a non-blocking error. **Verify that tolerance
  in S0.3's teardown**; if it's noisy, doctor gains a `--strip-keepwarm` sweep — small
  follow-up, not v1).

### Config surface (all upstream-documented in FEATURES.md)

| Variable | Default | Meaning |
|---|---|---|
| `CCAGE_KEEPWARM=1` | off | Master opt-in: seed + arm the hook. |
| `CCAGE_NO_KEEPWARM=1` | — | Per-shell/per-cage kill switch when globally enabled. |
| `CCAGE_KEEPWARM_INTERVAL_MIN` | `55` | Idle minutes before the ping. ≤4 for 5m-tier (API-key) users. Clamp [1, 590]. |
| `CCAGE_KEEPWARM_MAX_PINGS` | `6` | Consecutive pings without real activity before standing down (≈ 6 h on defaults). |
| `CCAGE_KEEPWARM_MIN_TOKENS` | `20000` | Skip pinging tiny sessions (rewrite cheaper than the bother). |
| `CCAGE_KEEPWARM_SLICE_SECS` | `30` | Test injection point; not user-documented. |

### Economics note (goes in FEATURES.md)

Ping cost ≈ 0.1× of prefix (cache read) + ~50 output tokens. Rewrite cost ≈ 2× of
prefix (1h tier). Break-even ≈ 20 pings; cap at 6 keeps worst-case waste ≈ 30% of one
rewrite while covering a working day. On subscriptions the "cost" is plan-quota weight,
same arithmetic.

---

## Architecture B — `/keepwarm` skill (fallback only; build only if S0 fails)

`share/skills/keepwarm/SKILL.md`: instructs the agent to schedule a self-wake every
`<minutes>` (default 55) that replies "warm" and reschedules, stopping after
`<max>` wakes or when the user says stop. Pure prompt/skill — no hook, no seeding, no
timing code in ccage; per-session, user-invoked. Document the trade (manual, but
unkillable by hook-timeout semantics). Config via skill args, not env.

---

## Test plan (Architecture A)

New `tests/test_keepwarm.bats` (style: `tests/test_budget_check.bats` — pipe stdin
fixtures, fake transcript file, assert stdout/exit):

1. gate-off (no `CCAGE_KEEPWARM`) → silent exit 0, no state dir.
2. `CCAGE_NO_KEEPWARM` overrides on.
3. malformed stdin / missing transcript → exit 0.
4. min-tokens guard: transcript with peak `cache_read` below threshold → no ping.
5. interval clamp: `0` → 1; `9999` → 590; garbage → default 55.
6. activity reset: touch transcript mid-sleep (SLICE_SECS=0 + injectable sleep) → exit
   0, count reset to 0.
7. lock takeover: second instance steals lock → first exits without pinging.
8. ping emission: idle through interval → stdout is valid JSON with
   `.decision=="block"` and reason matching `ping 1/6`; count file == 1.
9. cap: count file pre-set to 6 → no ping.
10. suspend stand-down: simulate wall-clock jump (injectable `now` command) → exit 0,
    no ping.
11. parent-death cleanup: PPID probe fails → state files removed.
12. insta-loop guard: `stop_hook_active=true` + count mtime < 5 s → no ping.

`tests/test_seed_hooks.bats` additions (mirror existing cases): seed-on-gate, merge
preserves keys, basename dedup, timeout-mismatch reseed, fast-path skip, doctor parity.
`tests/validate-e2e.sh`: one assertion — seeded cage's settings.json contains the Stop
entry when `CCAGE_KEEPWARM=1`.
Shellcheck: hook + edited libs clean.

**Manual validation recipe (document in this file's S0 results):**
`CCAGE_KEEPWARM=1 CCAGE_KEEPWARM_INTERVAL_MIN=1` in a live caged session → wait 60 s →
observe the "warm" turn; then confirm in the session JSONL that the post-ping turn's
`usage.cache_read_input_tokens` ≈ prior prefix (hit, not rewrite), and after a real
>TTL idle *without* the hook, `cache_creation` spikes (control).

## Implementation order (TDD; each step = commit, green gate before next)

| Step | Scope | Notes |
|---|---|---|
| 8a | **S0 spike** | pty harness; record results + decision in this doc. Gates A vs B. |
| 8b | `share/hooks/keepwarm.sh` + `tests/test_keepwarm.bats` | The meat. Mechanical once S0 numbers are known. |
| 8c | Seeding fn + seed tests | Clone-and-trim of session-docs seeding. |
| 8d | Doctor backfill + worklist + test | Follows existing doctor copy. KEEP IN SYNC note both sides. |
| 8e | install/uninstall wiring + e2e assertion | Bundle with session-docs assets. |
| 8f | Docs: FEATURES.md section (config table + economics + tier caveat), README one-liner under the cache-TTL note, CHANGELOG `[Unreleased]` | Keep README addition ≤3 lines. |

Estimated size: ~1 hook (~120 lines), ~60 lines lib, ~40 lines doctor, ~25 tests.
Tier-2 review on completion (5–15 commits): `simplify` → `find-bugs` → `/second-opinion` → `fp-check`.

## Decisions log

- **55 min default** — 5-minute safety margin under the 1h TTL; measured tier on this
  machine is 1h (2026-06-05; 7,815/7,821 requests).
- **Stop hook over daemon/cron** — only an in-session turn touches the byte-identical
  prefix; everything external is unreconstructable (resume-bug lesson).
- **Opt-in (`CCAGE_KEEPWARM`)** — costs real quota; silent default-on is unacceptable.
- **Cap 6** — bounded worst-case waste; resets on any real activity.
- **State in the cage dir, not `/tmp`** — multi-user safety + slot/session isolation
  for free (keyed by `session_id`).
- **No new install flag** — file is inert without the env gate; fewer knobs.

## Open questions (carry to S0)

1. Hook `timeout` ceiling — is ~3,500 s honored? (S0.1)
2. UI behavior during a sleeping Stop hook. (S0.2 — the architecture gate)
3. Does a missing hook script after uninstall produce user-visible noise? (S0.3 teardown)
4. Stretch (S5, post-v1): tier sniff from the last session JSONL (`ephemeral_1h` vs
   `ephemeral_5m`) → warn when interval ≥5 min on a 5m tier; `ccage doctor` tier report.
