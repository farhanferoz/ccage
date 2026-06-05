---
name: keepwarm
description: >-
  Keep this session's prompt cache warm while the user steps away, by
  scheduling a tiny self-wake turn every N minutes (default 55, under the
  1-hour cache TTL) so the cached conversation prefix is re-read before it
  expires — avoiding a full cache rewrite on the user's return. Use when the
  user says "/keepwarm", "keep warm", "keep the cache alive/warm", "I'm
  stepping away / going to a meeting / lunch — keep the session warm", or asks
  to prevent the prompt cache from expiring. Not a resume fix: a warm cache
  never survives `claude -r`.
---

# /keepwarm

Arms a bounded keep-warm loop: after `interval` minutes of scheduling delay, the
session wakes itself for one minimal turn. That turn re-sends the conversation,
which is served **from cache** (a ~0.1× read, not a 1.25–2× rewrite) and resets
the cache TTL clock. Repeats up to `max` times, then stands down.

Invocations:

```
/keepwarm                      # interval 55 min, max 6 pings (defaults)
/keepwarm <interval>           # custom interval, max defaults to 6
/keepwarm <interval> <max>     # both custom
/keepwarm --ping <n> <max> <interval>   # INTERNAL — a scheduled wake re-entering
```

---

## 1. Parse and validate arguments

- `interval` (minutes): integer, clamped to **[1, 59]** — the scheduler's
  single-hop ceiling is 60 minutes, and an interval ≥ the 1-hour TTL is useless
  anyway. Default **55**. Non-numeric → use the default and say so.
- `max` (pings): integer, clamped to **[1, 24]**. Default **6**. There is no
  "forever": past ~20 pings the loop costs more than the one rewrite it avoids.
- Track which values came from defaults — the arming announcement must say so.

If the arguments start with `--ping`, skip to §5 (this is a scheduled wake, not
a user invocation).

## 2. Probe the session (cheap, local — one Bash call)

Run the bundled helper (skip all checks gracefully if it is missing):

```bash
bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/keepwarm/keepwarm-calc.sh" probe
```

It prints `transcript=`, `peak_cache_read=` (≈ the cached prefix size in
tokens), and `tier=` (`1h`, `5m`, or `unknown`).

## 3. Warn before arming (when warranted)

- **Tier mismatch:** `tier=5m` and `interval > 4` → warn: the cache will expire
  long before the first ping. Offer: re-arm with `/keepwarm 4`, or set
  `ENABLE_PROMPT_CACHING_1H=1` (upstream Claude Code env var, API-key auth) and
  restart the session.
- **Tiny session:** `peak_cache_read < 20000` → a full rewrite would cost only
  fractions of a cent; tell the user and ask whether to bother. Arm only if they
  confirm.
- `tier=unknown` → proceed; mention the tier could not be determined and 55 min
  assumes the 1-hour tier.

## 4. Announce the contract, then arm (defaults are never silent)

One line, always stating interval, cap (flagging defaulted values), approximate
per-ping cost from `peak_cache_read` (read rate ≈ 0.1× input — e.g. ~$0.05 per
ping for a 100K-token Opus session), projected auto-stop clock time, and how to
cancel:

> keep-warm armed: ping every 25 min, up to 6× (default cap) ≈ $0.05 each —
> auto-stops ~16:40, or say "stop".

Then schedule the first wake using the environment's self-scheduling mechanism
(the same one `/loop` rides — e.g. the ScheduleWakeup tool, dynamic mode):
delay = `interval × 60` seconds, prompt = `/keepwarm --ping 1 <max> <interval>`,
reason = `keep-warm ping 1/<max>`. If no self-scheduling mechanism exists in
this environment, do **not** arm — tell the user and suggest
`/loop <interval>m` as the manual alternative.

## 5. On a scheduled wake (`--ping <n> <max> <interval>`)

A wake **is** the cache refresh — the request that delivered it already re-read
the prefix and reset the TTL. Your only jobs are bookkeeping and the next hop.
Strict rules for the wake turn: **no tools** (except the rescheduling call), no
file changes, at most one short output line.

1. **User said stop?** If the conversation shows "stop" / "I'm back" / an
   equivalent since arming → reply `keep-warm stopped.` and do not reschedule.
2. **User active since the previous wake?** Their turns already refreshed the
   cache — reset the counter: treat this wake as ping 1 of `max` again, reply
   `keep-warm: you were active — counter reset; next ping at <HH:MM>.` and
   reschedule with `--ping 2 <max> <interval>`.
3. **Normal ping (`n < max`):** reply
   `keep-warm ping <n>/<max> — cache refreshed; next at <HH:MM>.` and
   reschedule with `--ping <n+1> <max> <interval>`.
4. **Cap reached (`n = max`):** reply
   `keep-warm done (<max>/<max>) — cache expires ~1h after your last activity.`
   Do not reschedule.

## Honesty rules

- Pings cost real quota (≈ a cache-read of the whole conversation each). Never
  arm without an explicit user request, and never exceed the announced cap.
- On subscription plans, a ping that fires while no usage window is active
  **opens a fresh 5-hour rate-limit window** — the user may return to a window
  that is already hours old. Mention this when arming for a long absence.
- The schedule does not survive a session restart — if asked, say so.
- A warm cache does **not** help `claude -r` / `--resume` (structural cache
  miss regardless of warmth). If the user plans to exit, point at `/checkpoint`
  or `ccage handoff` instead of arming this.
