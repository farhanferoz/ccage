---
name: checkpoint-threshold
description: >-
  Retune ccage-auto's auto-checkpoint behaviour live, mid-session, without
  restarting: raise or lower the soft (advisory nudge) or hard (forced backstop)
  context-occupancy percentage, pause auto-checkpointing entirely during
  delicate work, resume it, reset to the launch values, or show the current
  settings. Use when the user says "/checkpoint-threshold", "raise/lower the
  checkpoint threshold", "checkpoint at N%", "checkpoint later/sooner", "give me
  more room before checkpointing", "pause / hold off auto-checkpoint", "resume
  auto-checkpoint", or asks what the auto-checkpoint threshold currently is.
  Only affects a session launched under `ccage-auto`.
---

# /checkpoint-threshold

`ccage-auto` watches this session's context occupancy and, at a **soft**
threshold (default 40%), nudges you to `/checkpoint`; if that goes
unconfirmed it **re-nudges** once at `hard − 5%` (default 55%) or after a
timeout, whichever comes first; at a **hard** threshold (default `soft + 20%`,
capped at 100%, so 60% by default) it forces a checkpoint as a backstop before
auto-compact. Naming `hard` explicitly always overrides that `soft + 20`
default. Those percentages are fixed when `ccage-auto` launches. This skill
changes them — or pauses the whole mechanism — **while the session is
running**, by writing a small control file (`.ccage-autock.conf`) in the
project dir that the watcher re-reads on its next poll (~12 s). No restart, no
lost context.

It does this by shelling out to `ccage-auto` itself, so all validation lives in
one place.

## 1. Map the request to one action

Percentages are **context-window occupancy** — the fraction of the model's
window currently in use. *soft* = where you get the advisory nudge; *hard* = the
forced backstop (always kept above soft).

| The user says… | Run |
|---|---|
| a bare number `N` / "raise to N" / "checkpoint at N%" / "more room → N" | `ccage-auto --set soft=N` |
| two numbers `N M` / "soft N, hard M" | `ccage-auto --set soft=N hard=M` |
| "hard N" / "backstop at N" | `ccage-auto --set hard=N` |
| "pause" / "hold off" / "suspend" / "don't checkpoint for a while" | `ccage-auto --pause` |
| "resume" / "re-enable" / "continue auto-checkpoint" | `ccage-auto --resume` |
| "reset" / "back to default/launch" | `ccage-auto --reset` |
| "status" / "what is it now" / no argument | *(nothing — go to step 3)* |

A lone number is the **soft** threshold — that is the one people mean by "the
checkpoint threshold." Only touch `hard` when they name it.

## 2. Apply it (one Bash call, from the project dir)

Run the chosen command, e.g.:

```bash
ccage-auto --set soft=50
```

- If `ccage-auto` is **not found** (not installed / not on `PATH`), say so plainly
  and stop — there is nothing to retune.
- `--set` echoes the resulting thresholds and clamps a bad pair (out-of-range
  values snap back to defaults; `soft ≥ hard` raises `hard`). Setting `soft`
  alone re-derives `hard` (`soft + 20`, capped at 100) unless `hard` was named
  explicitly, at launch or in an earlier `--set` — that stays sticky. Relay any
  clamp/derivation warning it prints — don't hide it, especially the one for a
  derived `hard` hitting the 100% cap (a backstop at a full window is too late
  to help).

## 3. Confirm — cheaply

**After a mutation** (`--set` / `--pause` / `--resume` / `--reset`): the command
already prints the resulting thresholds on stdout — **that echo is your
confirmation. Do NOT also run `--status`.** Just relay what it printed, e.g.:

> Auto-checkpoint now nudges at **50%**.

A soft-only `--set` only echoes `soft=`, never a derived `hard` (it isn't
persisted — it stays dynamic, re-deriving from soft on every read) — don't
invent a backstop number the command didn't print. If the user asks what the
backstop actually is now, that's a `--status` question (step 3, "effective").

**Only for a bare `status` request** (or if the user asks how full they are) run:

```bash
ccage-auto --status
```

and report the **effective** soft/hard (and `PAUSED` if so) plus the current
**occupancy**, e.g.:

> Nudge at **50%**, backstop 70%. Currently at 22% — plenty of room.

(Why: `--set` is ~0.3 s but `--status` reads the transcript and resolves the
cage dir, so it's slower — skip it when the mutation already told you the
answer.)

## Honesty notes (say these when they apply, not every time)

- **Live-only, this run.** The override affects a running `ccage-auto` watcher in
  *this* project dir and takes effect within one poll. It is cleared at the next
  session start (startup / `claude -r` resume), so it does **not** persist across
  restarts — for a permanent change, launch with `--soft`/`--hard` or set
  `CCAGE_AUTOCK_SOFT`/`CCAGE_AUTOCK_HARD`. It **does** survive ccage-auto's own
  `/clear` cycles (that is the point).
- **No watcher, no effect.** If this session was *not* started with `ccage-auto`,
  the file is still written but nothing reads it (and it's cleaned up next
  start). If `--status` shows no occupancy / no transcript, note that the change
  only bites under a live `ccage-auto` session.
- **Pause is for delicate stretches**, not "off forever" — while paused, context
  can grow to auto-compact with no checkpoint. Resume once the risky work (a long
  subagent run, a big refactor you don't want interrupted) is done. A
  `/checkpoint --final` still stands the watcher down regardless.
