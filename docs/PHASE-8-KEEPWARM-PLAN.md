# Phase 8 — Cache Keep-Warm (Plan v2 — skill architecture)

Workflow: **implement TDD-style (bats first), self-review when green.** Same rhythm as
PLAN.md / PHASE-6 / PHASE-7. v1 of this plan proposed a Stop-hook sleeper; research
(S0, below) killed it before implementation. v2 promotes the scheduler-skill design.

> **How to use this plan.** Self-contained — a fresh session can implement it. Before
> writing code, read: `share/skills/checkpoint/SKILL.md` (the shipped-skill pattern:
> frontmatter, when-to-use, deterministic helper script), `install.sh` (how the
> checkpoint skill + hooks are deployed; `--no-session-docs` bundle),
> `tests/test_checkpoint.bats` (how a shipped skill is tested), `docs/FEATURES.md`
> (doc style). Paths repo-relative from `/home/ff235/dev/ccage`.

---

## Why

Anthropic's prompt cache expires after a TTL of inactivity — 5 minutes on API-key
auth, 1 hour on subscription auth (measured on this machine 2026-06-05: 7,815/7,821
recent cache-writing requests used the 1h tier). Each *use* of the cached prefix
resets the clock. A session idle past the TTL pays a full prefix **rewrite** on the
next turn (2× input rate on the 1h tier) instead of a **read** (0.1×). A read costs
~5–8% of a rewrite, so refreshing shortly before expiry is strictly cheaper for gaps
up to ~12–20 refresh cycles.

## Goal

A `/keepwarm` skill: the user invokes it before stepping away; the agent then
schedules a trivial self-wake turn every `interval` minutes (**default 55**,
configurable per invocation), each one touching the cached prefix and resetting the
TTL, until a ping cap is hit, the user returns, or the user says stop.

## Non-goals

- **No Stop-hook implementation** (rejected — S0).
- **No external request replay** (byte-identical-prefix problem; resume-bug lesson).
- **Not a resume fix** — a warm cache does not survive `claude -r` (structural miss,
  GitHub #51764). Keep-warm only helps when returning to the *same live session*.
- **No subagent coverage** (always 5m tier; small caches).
- **No auto-arming.** Keep-warm fires real turns and consumes plan quota; it must be a
  deliberate per-session act, consistent with ccage's "auto-clear is a non-goal"
  philosophy. (A future auto-arm via SessionStart hook would need its own opt-in
  debate — out of scope.)

---

## S0 — research findings (2026-06-05; replaces the v1 spike)

Questions answered via official docs + prior art (no empirical spike needed for the
kill decision):

| # | Question | Answer | Source |
|---|---|---|---|
| S0.1 | Can a Stop hook run ~55 min? | Yes — default hook timeout 600 s, per-command `"timeout"` extends it, no documented ceiling. | code.claude.com/docs/en/hooks.md |
| S0.2 | Is the TUI usable while a Stop hook runs? | **No — input is blocked**; spinner shown; nothing queues; only Esc kills the hook. | hooks docs + prior-art README warning |
| S0.3 | Does `{"decision":"block"}` after a sleep force a turn? | Yes; follow-up Stop carries `stop_hook_active: true` (must check to avoid loops). Edge-case flakiness reported (#8615). | hooks docs; anthropics/claude-code#8615 |
| S0.4 | Prior art? | **yujiachen-y/claude-code-cache-keepalive** — Stop hook, sleep 240 s (5-minute tier), then block. Its README warns the UI "looks stuck" even at 240 s. | github.com/yujiachen-y/claude-code-cache-keepalive |
| S0.5 | Async hooks? | `"async": true` exists but is fire-and-forget — cannot emit block decisions, so it cannot inject the ping turn. | hooks docs |

**Why this kills Architecture A (Stop-hook sleeper):** a 55-minute frozen TUI looks
like a crash, and — fatally — the v1 design's "stand down when the user becomes
active" check can never fire, because a blocked UI means the user *cannot* become
active while the hook sleeps. The design self-contradicts. The 240 s prior art is
tolerable only because the freeze is short. Decision: **skill architecture is
primary**; the hook variant is permanently rejected, not deferred.

---

## Architecture — `/keepwarm` skill

### New files: `share/skills/keepwarm/SKILL.md` (+ optional `keepwarm-calc.sh`)

Follows the `/checkpoint` skill pattern. Frontmatter `name: keepwarm`, description
covering trigger phrases ("keep warm", "keep the cache alive", "stepping away",
"/keepwarm"). Body instructs the agent to:

1. **Parse args:** `/keepwarm [interval-minutes] [max-pings]` — defaults **55** and
   **6**. Validate: interval clamped to [1, 590] (≤4 recommended on the 5-minute tier
   — API-key auth), max-pings clamped to [1, 24]. Bad input → say so, use defaults.
2. **Sanity checks before arming (cheap, local):**
   - If the session transcript's peak `cache_read_input_tokens` is small
     (< ~20K), tell the user a rewrite would cost pennies and ask whether to bother.
   - Tier hint: read the latest `message.usage.cache_creation` from the transcript —
     if `ephemeral_5m_input_tokens` dominates and interval > 4, warn that the cache
     will expire long before the first ping (suggest interval 4, or
     `ENABLE_PROMPT_CACHING_1H=1`).
   (A small deterministic helper `keepwarm-calc.sh <transcript>` MAY ship for these
   two reads — jq one-liners, zero API calls — mirroring `checkpoint-init.sh`'s role.
   If the logic stays ≤ ~10 lines of instructions, skip the helper; the skill doc
   decides at implementation time.)
3. **Arm the loop:** schedule a self-wake every `interval` minutes (the harness
   scheduler — same mechanism as `/loop`; in dynamic mode pass the keep-warm prompt
   back each turn). Each wake: reply with one short line
   (`keep-warm ping <n>/<max> — cache refreshed, next at HH:MM`), no tools, then
   reschedule.
4. **Stop conditions** (checked at each wake): ping count ≥ max → stop and say so;
   user has interacted since the last wake → reset the count and *continue* the loop
   silently re-anchored to the latest activity (their turns already refreshed the
   cache); user says "stop"/"I'm back" → stop; session restarted → the schedule is
   gone naturally (wakeups don't survive restarts — document this).
5. **Quota honesty (defaults are never silent):** when arming, announce the full
   contract in one line — interval, cap (flagging which values were defaulted),
   approximate per-ping cost (≈ a cache-read of the conversation, ~0.1× of one full
   turn's input), the projected auto-stop time, and how to cancel. Example:
   `keep-warm armed: ping every 25 min, up to 6× (default cap) ≈ $0.05 each —
   auto-stops ~16:40, or say "stop".`

### Why the harness scheduler and not shell timers

Only a real turn in the live session touches the byte-identical prefix. The harness's
wake mechanism produces exactly that, with zero new processes, no settings.json
seeding, no per-cage state, and full interactivity between pings. Dependency note:
self-scheduling is a current Claude Code capability (the bundled `/loop` skill rides
it); FEATURES.md should state the minimum CC version once verified during
implementation (check `claude --version` + changelog).

### install / uninstall / sharing

- `install.sh`: deploy `share/skills/keepwarm/` → master skills dir, exactly like the
  checkpoint skill (same `--no-session-docs` bundle? **No** — new tiny bundle flag
  `--no-keepwarm`, since this skill is unrelated to session docs; default installs).
- `uninstall.sh`: remove the skill dir (mirror checkpoint handling).
- Per-cage propagation is free via the existing `CCAGE_SHARE_FROM` symlink of
  `skills/` — no settings.json changes anywhere, **no seeding work at all**.
- `ccage doctor`: nothing to backfill (symlinked skills appear everywhere on next
  session start). No doctor changes in v1.

### Config surface

| Knob | Where | Default | Meaning |
|---|---|---|---|
| interval | skill arg 1 | `55` | Idle minutes between pings. Use ≤4 on the 5-minute (API-key) tier. |
| max pings | skill arg 2 | `6` | Stop after this many consecutive pings (~6 h at defaults). |
| `--no-keepwarm` | install.sh | installs | Skip deploying the skill. |

No new `CCAGE_*` env vars: invocation is explicit and per-session, so env-based gates
(v1's `CCAGE_KEEPWARM`, `CCAGE_NO_KEEPWARM`, interval var) are unnecessary surface.
(Revisit only if auto-arming ever becomes a goal.)

### Economics (goes in FEATURES.md, 3 lines)

Ping ≈ 0.1× of the conversation prefix (cache read) + a few output tokens. Expired
return ≈ 2× of the prefix (1h-tier write). Break-even ≈ 20 pings; default cap 6 keeps
worst-case waste ≈ 30% of one rewrite while covering ~6 h. Only useful when returning
to the **same live session** — never before a `claude -r`.

---

## Test plan

`tests/test_keepwarm_skill.bats` (mirror `test_checkpoint.bats` granularity):

1. install deploys `skills/keepwarm/SKILL.md` to the master skills dir; `--no-keepwarm` skips it.
2. uninstall removes it; user-created files in the dir survive (match checkpoint semantics).
3. SKILL.md frontmatter parses: has `name: keepwarm`, non-empty description, no
   AI-attribution strings (repo-wide invariant).
4. Defaults documented in the body: literal "55" and "6" present (guards accidental
   default drift).
5. If `keepwarm-calc.sh` ships: bats for the two jq reads against fixture JSONLs
   (peak cache_read; 5m-vs-1h dominance), exit 0 on malformed input.
6. `tests/validate-e2e.sh`: one assertion — skill present in a bootstrapped cage via
   the `CCAGE_SHARE_FROM` symlink.
7. shellcheck clean (helper script, if any).

**Manual validation recipe:** in a live caged session, `/keepwarm 1 2` → walk away 2
min → expect two one-line pings ~60 s apart, then auto-stop; confirm in the session
JSONL that each ping's `usage.cache_read_input_tokens` ≈ the prefix size (hit, not
rewrite). Control: same idle without the skill on a 5m-tier (`FORCE_PROMPT_CACHING_5M=1`)
session → `cache_creation` spike on return.

## Implementation order (TDD; each step = commit, green gate before next)

| Step | Scope | Notes |
|---|---|---|
| 8a | `share/skills/keepwarm/SKILL.md` (+ helper iff needed) + `tests/test_keepwarm_skill.bats` | The meat; prompt-engineering care on stop conditions. |
| 8b | install/uninstall wiring + `--no-keepwarm` + e2e assertion | Mirror checkpoint-skill wiring. |
| 8c | Docs: FEATURES.md section (usage, defaults, economics, tier caveat, "not a resume fix"), README ≤3 lines under the cache-TTL note, CHANGELOG `[Unreleased]` | Verify + record minimum CC version for self-scheduling. |

Estimated size: ~1 SKILL.md (~120 lines), ~30 lines install/uninstall, ~15 bats.
Tier-1/2 review on completion (likely ≤4 commits → `simplify` only; bump to Tier 2 if
the helper script ships).

## Decisions log

- **Skill over Stop hook** — S0: Stop hooks block the TUI for their whole runtime
  (docs + prior-art warning); a 55-min freeze looks like a crash and defeats
  activity detection. Decision is terminal, not deferred.
- **55 min default** — 5-minute margin under the 1h TTL; tier measured on this machine
  2026-06-05 (7,815/7,821 requests on 1h).
- **Manual arm, no auto** — pings cost quota; deliberate act per session; consistent
  with the auto-clear non-goal.
- **Cap 6** — bounded waste (~30% of one rewrite worst-case), covers a working block.
- **No env vars / no seeding / no doctor work** — skill args + symlinked skills dir
  make the whole settings.json machinery unnecessary. Smallest possible footprint.
- **Prior art credited** — yujiachen-y/claude-code-cache-keepalive validates the ping
  mechanism at 240 s on the 5m tier; our divergence (skill, 1h tier) is UX-driven.

## Open questions (resolve during 8a/8c)

1. Minimum Claude Code version for self-scheduling wakeups (check changelog; record in FEATURES.md).
2. Helper script: ship `keepwarm-calc.sh` or keep checks as skill-prose jq? (Decide by line count at implementation.)
3. Does a pending wakeup surviving into an *active* conversation annoy (one stray
   "keep-warm ping" mid-work)? Mitigation drafted in stop-conditions (silent re-anchor);
   verify feel in manual validation.
