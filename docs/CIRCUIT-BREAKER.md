# Circuit Breaker (subagent watchdog) — feature doc

> **Status:** Phase 1 complete & verified (43/43 tests) — detection + telemetry
> + `ccb-report` + the **observe-mode watcher wired into `ccage-auto`** (Task 11:
> a `SubagentWatcher` daemon thread delegating to the unit-tested
> `lib.subagent_watch.run_tick`; alert/RESUME/notify/ledger only, no escalation).
> Every ledger row now also captures the **orchestrator model** so vouch-trust
> can later key on capability tier, never a hardcoded model. Phase 2 (autonomous
> nudge/stop/kill) stays gated on spike S1 (exact pty-write bytes) and the
> attended Task 17 live-fire. This doc currently holds the **spike findings**;
> the full ladder / config / vouch-protocol sections land with Task 16.

## Spike findings (Phase 0)

Run **2026-07-13, from inside a live Agent-Teams session** — that session is
itself an *internal orchestrator* with real teammates, so the spikes did **not**
need a separate hand-run harness. Config dir `~/.claude-ccage`, session
`79924fa7…`. External vs internal orchestrator: `ccage-auto` is the *external*
supervisor (owns the pty, does the watching/poking); the root Claude session is
the *internal* orchestrator (spawns teammates, receives the vouch/stop nudge).

### S1 — does an out-of-band message reach a running model? — **core: YES**
- Premise verified: a message injected mid-turn is delivered to the model at the
  next tool boundary (V7; observed repeatedly — user mid-turn messages *and*
  orchestrator→teammate `SendMessage` both land within the running turn).
- **Not yet tested:** the exact byte sequence `ccage-auto` writes to the session
  pty master fd — that needs a `ccage-auto`-wrapped session. Fallback if it proves
  hard: signal file + `UserPromptSubmit` hook (plan S1 abort path). The Tier A/B
  premise (a nudge reaches the orchestrator) is sound either way.

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
