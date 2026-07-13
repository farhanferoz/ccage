# Circuit Breaker (subagent watchdog) — feature doc

> **Status:** the full ladder is **built and unit-verified (61/61 tests)** —
> detection + telemetry + `ccb-report` + the `SubagentWatcher` thread wired into
> `ccage-auto`, plus all four tiers: **Observe** (alert), **A/nudge**, **B/stop**,
> **C/kill** (Tasks 11–15). All decision logic is the pure, unit-tested
> `lib.subagent_watch`; the bin owns only the two side effects (pty `inject`, pid
> `kill_session`). Every ledger row captures the **orchestrator model** so
> vouch-trust can later key on capability tier, never a hardcoded model.
>
> **What is NOT yet done:** the attended **Task 17 live-fire** (the gate for
> raising the shipped default past `observe` and for flipping the Tier-C default
> on), and deploying `lib/` via `install.sh`. Until the lib is deployed, the
> breaker is **fully inert in installed cages** (`_load_ccb()` finds no `lib/` →
> no `SubagentWatcher`). Treat B/C as validated-in-unit-tests-only until Task 17.

## 1. The ladder

Every stuck-teammate breach climbs the same ladder. A step is taken only after
**two consecutive breach polls** (debounce), and **at most one step per poll**. A
breach that clears on its own, or a vouch, de-escalates the agent back toward
`running` — no state is a trap. Nothing above the configured `CCB_MAX_TIER` is
ever emitted (`evaluate` caps it), so the ceiling is a hard cap, not a hint.

| Tier | Phase reached | Trigger | Action | Reversible? |
|---|---|---|---|---|
| **Observe** | `suspect` | breach ×2 | one **alert** → RESUME + log + notify | yes (clears → `running`) |
| **A — nudge** | `nudged` | tier ≥ `nudge` | inject the vouch/stop **nudge** into the orchestrator's pty; start the grace clock | yes (recover or vouch → `running`/`vouched`) |
| **B — stop** | `stop_requested` | nudge grace expired, no vouch, tier ≥ `stop` | inject the **stop directive**; verify via the `CCB-STOPPED` marker | yes (recover → `running`; verified → `resolved`) |
| **C — kill** | `escalated` | stop grace expired **and** `kill_permitted` | pre-kill salvage dump → notify → **SIGTERM the session**; else re-issue stop once + `escalate_blocked` | terminal |

**Operating rule — measure before you escalate.** The whole point of the ledger
(§4) is that thresholds are *tuned from data*, not guessed. Run in `observe` first,
read `ccb-report`, and only raise the tier once the healthy-agent peak
distributions show the thresholds won't fire on legitimate long work.

**Completion always wins.** A teammate that finished (in-band `idle_notification`,
S4) or was verifiably stopped (`CCB-STOPPED`) resolves from *any* phase and is
never flagged again — the v1 "completed agent re-flagged later" bug class is
closed. Completion (idle) is reversible (a later write returns it to watch);
a verified stop is terminal (S2: `TaskStop` ends the turn).

## 2. Configuration

All via environment, read once at watcher start (`CCBConfig.from_env`). Garbage
or absent values keep the default — the watcher never crashes on config.

| Env var | Default | Meaning |
|---|---|---|
| `CCB_MAX_TIER` | `stop` (code) / **`observe` (rollout)** | ceiling: `observe` \| `nudge` \| `stop` \| `kill` |
| `CCB_T_SOFT_MIN` | `45` | quiet-stuck elapsed floor (min) |
| `CCB_T_STALE_MIN` | `10` | transcript-quiet floor for quiet-stuck (min) |
| `CCB_T_HARD_MIN` | `120` | churn-stuck elapsed floor — catches constant-writers (min) |
| `CCB_GRACE_MIN` | `10` | grace between ladder steps (min) |
| `CCB_PARENT_STALE_MIN` | `15` | orchestrator-unresponsive floor for Tier C (min) |
| `CCB_MAX_VOUCHES` | `2` | vouches honoured per agent before the ladder ignores them |
| `CCB_NOTIFY_CMD` | *(none)* | shell command fed each alert on stdin (e.g. a Telegram hook) |
| `CCB_TOKENOL_URL` | `http://localhost:8787` | tokenol base URL for whole-session cost |
| `CCB_LEDGER` | `~/.local/share/ccage/ccb/events.jsonl` | telemetry ledger path (read by `ccb-report`) |

## 3. Vouch / stop marker protocol

The orchestrator talks back to the breaker with two exact-grammar markers, matched
verbatim out of the parent transcript (regex over the raw line — nested content
can't hide one):

- **Extend a legitimately long teammate:** `CCB-VOUCH agent=<teammate_id> extend=<minutes>`
  — de-escalates to `vouched` and shifts *both* the quiet and churn floors by
  `<minutes>`. Honoured up to `CCB_MAX_VOUCHES` times, then ignored (a genuinely
  runaway agent can't be vouched forever). ⚠ A vouch is trust-based: it extends
  the budget, it does not prove work is happening (Task 4 note).
- **Confirm a stop:** `CCB-STOPPED agent=<teammate_id>` — the only reliable
  stop-verification signal, because S2 showed a stopped teammate leaves no
  distinct on-disk terminal marker. Moves the agent to `resolved` (terminal).

`<teammate_id>` is the authoritative `.meta.json` `"name"`, never the transcript
filename (Task 3 / V11).

## 4. Telemetry ledger + `ccb-report`

One JSON line per decision is appended to `CCB_LEDGER`, durable across sessions.
Event kinds: `alert`, `nudge`, `vouch`, `stop`, `stop_verified`, `escalate_blocked`,
`kill`, `resolved` (the last also emitted for healthy never-flagged agents, so the
baseline peak distributions have data). Each row carries: `ts`, `event`,
`session_id`, `cwd`, `agent`, `teammate_id`, `phase`, `orchestrator_model`,
`elapsed_min`, `stale_min`, `session_cost_usd`, `open_tasks`, `vouches_used`,
`extension_min`, `peak_elapsed_min`, `peak_stale_min`, and a `cfg` snapshot of the
thresholds in force.

`bin/ccb-report [--ledger PATH] [--project SUBSTR] [--json]` aggregates it into the
review: agents seen, nudges, **false positives** (nudge → vouch → finished fine),
**true positives** (nudge → stop/kill), kills, `escalate_blocked` count, and the
healthy-agent p50/p95 of peak elapsed/stale — the numbers you tune the thresholds
against. Every Task 17 scenario must be reconstructible from the ledger alone.

## 5. Scope & caveats

- **Teams sessions only (V10).** A non-teams session can't produce the in-band
  completion signal the higher tiers rely on, so the breaker is *forced to
  `observe`* there (alert-only) regardless of `CCB_MAX_TIER` — a stuck agent is
  still surfaced, never nudged/stopped/killed on a session whose completion we
  can't read.
- **Session-merged cost (V3).** `session_cost_usd` is the whole session (parent +
  all subagents); tokenol can't scope to one teammate. It's annotation only, never
  a per-agent decision input.
- **Orphaned shell children (S2).** `TaskStop` ends a teammate's *turn* but can
  leave its `Bash` sub-processes running (they keep costing) — the stop directive
  says so and asks the orchestrator to clean them up. There is no per-teammate OS
  process to kill (S3: in-process teammates), so Tier C's only OS lever is killing
  the whole session.
- **Kill is for a wedged orchestrator, not a stuck teammate.** Tier C SIGTERMs the
  session only when the orchestrator's *own* transcript has gone quiet past
  `CCB_PARENT_STALE_MIN` — sound because a wedged orchestrator can't consume the
  queued nudge/stop (S1), so its transcript stays quiet, whereas a live one
  consumes it and resets the clock. A live orchestrator is never killed.

## 6. Enabling it (rollout + the Tier-C default-flip criterion)

1. `install.sh` deploys `lib/` beside `bin/ccage-auto` (else the breaker is inert).
2. Run at `CCB_MAX_TIER=observe` and collect a ledger across real teams sessions.
3. `ccb-report` → confirm healthy p95 sits comfortably under the thresholds; raise
   to `nudge`, then `stop`, watching the false-positive count stay ~zero.
4. **Tier-C default flip** — only after the attended **Task 17** live-fire passes
   every scenario (stuck-quiet, healthy+vouch, churner, completed-agent regression,
   unresponsive-orchestrator KILL with a *verified* resume-from-dump, restart
   safety, ledger completeness): flip the shipped `CCBConfig` default and this doc
   from `stop` to `kill` in a dedicated commit. **Revised (2026-07-13):** the
   KILL scenario specifically cannot be staged honestly — a well-behaved
   orchestrator correctly refuses a prompt asking it to fake being wedged (a
   busy-wait has no purpose but to tie up the session, exactly what its own
   safeguards exist to catch), and *should* refuse. Treat Tier-C's live-fire
   leg as gated on a **naturally occurring** wedge (a real hung call, a real
   infinite loop) rather than a manufactured one; unit + wiring coverage
   (`kill_session` against a real process, `kill_permitted`'s gating logic,
   the full ladder state machine) is the accepted bar until one occurs.

## 7. Validation status

**Deterministic coverage (61 unit tests + 2 scripted live-fire bats):**

| What | How |
|---|---|
| Full ladder state machine (every transition, vouch, recovery, debounce, cap) | `evaluate` unit tests |
| `run_tick` end-to-end: alert, nudge, stop→`CCB-STOPPED`→`stop_verified`, escalate-blocked, escalate→kill | `run_tick` unit tests |
| Injection bytes (`<text>`+`\r`, newlines collapsed), rate-limit, no-pty / not-ready no-ops | `inject_message` over an `os.pipe` |
| Real session SIGTERM | `kill_session` against a real child process |
| Restart safety (state round-trip, no re-alert), completed-agent never re-flagged | state + `evaluate` unit tests |
| **Full pty wiring in the real `ccage-auto` process** — `run_proxy`→`SubagentWatcher` (master_fd/lock/ready_event/pid)→thread→real pty write; the Tier-A nudge reaches the child carrying the vouch grammar; `tui_ready` gate; observe = alert-only | **scripted live-fire** (`tests/test_autock.bats`, real ccage-auto + fake claude) |
| A mid-turn pty injection reaches a **real model** and is consumed at the next tool boundary | spike **S1** (real Haiku) |

**Attended Task 17, Leg 1 — PASSED (2026-07-13), against a real session post-fix:**

A real Sonnet 5 orchestrator (not a stub) received the actual Tier-A nudge
injected over the real pty mid-session, reasoned about it correctly ("this is
the expected long-running work"), and replied with the exact
`CCB-VOUCH agent=stalled-worker extend=60` marker. The breaker parsed it and
advanced the record to `vouched`. Ledger confirms the full real sequence:
`alert → nudge → vouch`, `orchestrator_model: claude-sonnet-5`. This is the
first live-fire evidence of a real model — not a fake `claude` stub — closing
the loop end to end.

**Bug found by the same attended run, a second teammate later in the same session (2026-07-13):** `scan_parent_transcript` matched `CCB-VOUCH`/`CCB-STOPPED` against every transcript line, not just the model's own. The CB's own injected nudge/stop directive lands as an ordinary `"type": "user"` turn — indistinguishable from real input — and necessarily spells out the exact marker grammar as the example to copy, so the very next poll it satisfied its own verification regex regardless of whether the model ever replied. Caught directly: a real orchestrator explicitly refused to fabricate `CCB-STOPPED` for a teammate it had confirmed (via `TaskList`) had already finished, yet the ledger recorded `stop_verified` 12 seconds later — traced to the CB's own injected line, not the refusal text. This retroactively means the *mechanism* backing the Leg 1 vouch above wasn't yet provably discriminating (the model's reply was genuine, confirmed by transcript role and timing, but the pre-fix scanner couldn't tell that from a self-match). Fixed in v0.11.3 by scoping both regexes to `"type": "assistant"` lines only; regression test proves a `"type": "user"` line carrying the exact grammar is ignored.

**Attended Task 17, Leg 2 (Tier-C KILL + verified resume) — deliberately not staged:**

See §6's revised default-flip criterion above. Attempting to manufacture a
wedge got a (correct) refusal from the orchestrator model. Left as unit- and
wiring-validated only, pending a real occurrence.

**Still open:**

- Churner and healthy-long-plus-vouch behaviour end-to-end with a real teammate (lower priority than the above; Leg 1's vouch path already exercises the healthy+vouch case).

Tier B/C acting behavior stays unit- and wiring-validated; the deployed default stays at `observe`.

**Bug found by the first real attended Task 17 attempt (2026-07-13):** `list_subagent_transcripts` globbed `session_dir/subagents/`, but a real Claude Code session nests subagent transcripts one level deeper, under a directory named for the session's own transcript-file stem (`session_dir/<session_id>/subagents/`). Every unit test's fixture placed transcripts at the flat (wrong) path, so this was never caught — in production the breaker found zero subagents on every tick and never tracked a single teammate, on any tier, since v0.11.0 shipped. Fixed by threading `session_id` into the lookup; regression test builds the real nested layout plus a same-named decoy at the old flat path to prove it isn't picked up. Same root-cause shape as the v0.11.1 installed-lib bug: a test fixture modeled a plausible-but-wrong directory layout.

## Spike findings (Phase 0)

Run **2026-07-13, from inside a live Agent-Teams session** — that session is
itself an *internal orchestrator* with real teammates, so the spikes did **not**
need a separate hand-run harness. Config dir `~/.claude-ccage`, session
`79924fa7…`. External vs internal orchestrator: `ccage-auto` is the *external*
supervisor (owns the pty, does the watching/poking); the root Claude session is
the *internal* orchestrator (spawns teammates, receives the vouch/stop nudge).

### S1 — does an out-of-band message reach a running model? — **RESOLVED: YES**
- Premise verified: a message injected mid-turn is delivered to the model at the
  next tool boundary (V7; observed repeatedly — user mid-turn messages *and*
  orchestrator→teammate `SendMessage` both land within the running turn).
- **Exact byte sequence — confirmed:** ccage-auto's `_type()` writes `<text>`
  (UTF-8) then **`\r` (0x0D)** to the pty master; `_interrupt()` prefixes
  **`\x1b` (ESC)** for the mid-turn case. Not `\n`, not CSI-u. This is the shipped
  mechanism: the `make_fake_claude` bats e2e harness (`tests/test_autock.bats`)
  captures *every injected byte* and asserts on them, and production autock drives
  a real TUI with it (`/clear` — which requires submit+parse — works).
- **Live confirmation (2026-07-13)** against a real external `claude` (Haiku 4.5,
  `--effort low`) via a throwaway standalone pty probe (no repo changes):
  (i) `text+\r` written to the master fd → the model received it and replied with
  the probe token (`● <token>` assistant message, "Brewed for 1s"); (ii) `text+\r`
  injected *while a `sleep` Bash tool was executing* → the TUI **queued** it
  (`Press up to edit queued messages`) and carried it through `Ran 1 shell command`,
  then processed it — mid-tool injection is accepted and consumed at the next
  boundary. (Disk-transcript verification was unreliable only because the probe
  SIGKILLs the child before it flushes; the raw pty output is authoritative.)
- **Conclusion:** the pty-write injection path is sound; the signal-file +
  `UserPromptSubmit` **fallback is NOT needed**. This unblocks Task 12 (injection
  writer) and Tier A (nudge, non-destructive). The destructive Tier B/C stay gated
  on the attended Task 17 KILL-by-default live-fire — S1 does not lift that.

### S2 — does `TaskStop` stop a running teammate? — **turn: YES; shell children: NO**
- `TaskStop <teammate>` returns success and ends the teammate's turn
  (`task_type: in_process_teammate`).
- **But it orphans the teammate's Bash sub-process.** A teammate running
  `sleep 300` kept running after the stop, reparented to the main `claude` PID;
  it had to be killed manually. Confirms claude-code#23154.
- **Design constraint for Tier B (stop):** the stop directive must warn that the
  teammate's tool sub-processes may still be running (and keep costing). The
  reversible-`RESOLVED` mechanic already guards the watcher side.
- On disk, a stopped teammate's transcript ends in an ordinary assistant event —
  no distinct "stopped" marker (same shape as a normal finish; see S4).

### S3 — are teammates separate OS processes? — **NO, in-process**
- A teammate's Bash child (`sleep 300`) is a **direct child of the single shared
  `claude` process** — the same PID as the orchestrator. Confirms
  `taskKind: in_process_teammate` (V11). No per-teammate OS process exists.
- The tool sub-process is **not attributable to a specific teammate** from the
  process table (generic `bash -c … eval '<cmd>'`, no teammate id embedded).
- **Implication:** no clean per-agent SIGSTOP/SIGTERM lever → Tier C's only
  OS-level mechanism stays "kill the whole session" (pty/`claude` process). The
  v3 "maybe" Tier B′ per-agent process control is closed as **not feasible**.

### S4 — how do we know a teammate FINISHED (vs just quiet)? — **load-bearing**
- **A finished teammate's transcript ends in an ordinary assistant message with
  no terminal marker** — confirmed on two real teammates (`cb-phase1` finished
  normally; `cb-spike-stop` stopped). Transcript terminal event is therefore NOT
  a completion discriminator (confirms V6).
- The actual completion signal observed is an **in-band `idle_notification`
  teammate-message** in the parent transcript:
  `{"type":"idle_notification","from":"<teammate_name>","idleReason":"available"}`,
  timed at the last assistant event (`cb-phase1`: final message and idle
  notification both at 12:35:12Z).
- **⚠ Plan-adjustment (stop-and-verify per ground rule #1):** Task 4b assumed a
  `TeammateIdle` *hook* writing `{ts,teammate_name,team_name}` to
  `.ccb-idle-feed.jsonl`. No such feed file appears, and the signal actually
  surfaces **in-band in the parent transcript**, not via a hook-to-file. So Task
  4b's completion feed should **parse `idle_notification` messages out of the
  parent transcript** (join key = `from` == teammate name), OR we must first
  confirm the `TeammateIdle` hook reliably fires + writes. **Do not build Task 4b
  until this one decision is settled.** Reversible-`RESOLVED` remains the safety
  net regardless.
- Join-key note: the `from` field is the teammate name (e.g. `cb-phase1`);
  confirm it equals the teammate's `.meta.json` `"name"` before wiring the join
  (avoids the round-1 identity-mismatch class of bug).
