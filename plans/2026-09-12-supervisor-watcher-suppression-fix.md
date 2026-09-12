# Fix: an armed watcher must silence the idle supervisor in every job state

**STATUS: IMPLEMENTED 2026-09-12.** All four parts landed in `bin/ccage-auto`, with
`tests/test_supervisor_wait.py` (44 cases) covering every row of §4. Verification, and the two places
this differs from the spec as written, are recorded in §7.

**Target:** `bin/ccage-auto` (installed copy `/home/ff235/.local/bin/ccage-auto`; edit the repo source and
reinstall). `bin/ccage-watch` needs **no change** — every field the fix reads is already written.
**Design it amends:** `plans/2026-08-16-idle-session-supervisor.md`. Line numbers below are from the installed copy
on 2026-09-12; grep for the symbol, do not trust the number.

## 1. The defect, reproduced

`ccage-watch arm` is the supervisor's third exit — "waiting on a MACHINE" — and the poke text promises: *"After
either of the last two I will not ask again until it resolves."* That promise holds for `hold` and only
conditionally for `arm`. The ladder in `_supervise_idle` (~2119–2136):

```python
if state == "growing":
    self.sup_landed_poked = False
    if held or self._watch_armed():
        return               # declared wait: silent until it ends
elif state == "landed" and not self.sup_landed_poked:
    ...poke with the path...; return
if held:
    return                   # a hold suppresses in EVERY state
if self.sup_pokes == 0:
    ...poke once...
```

`_watch_armed()` is consulted **only when `state == "growing"`** — when *this* session has a tracked
`run_in_background` job still producing output. `held` is additionally checked standalone. So a watcher bridging
work that happens **outside this session** (a separate executor process, a remote queue, CI, a cluster job) never
silences anything, because `_job_state()` returns `"none"` and the growing branch is skipped.

Measured 2026-09-12 in the guard cage: watcher `fdee376a4222` armed on a gate file written by a separate `agy`
process; the supervisor poked at 5-minute intervals for the whole wait, and one of those pokes produced an unwanted
`/checkpoint`. The inversion is the point: a watcher whose condition is satisfied by *this* session's own job is
already covered by that job being visible; the case `arm` exists for is exactly the case that gets no suppression.

## 2. The invariant every part must preserve

From `_hold_active`'s docstring and the design doc (`plans/2026-08-16-idle-session-supervisor.md:442`): **a
model-authored signal may keep the supervisor awake but may never send it to sleep by itself.** A hold qualifies
only because its silence expires **without the session's cooperation** (ttl lapses; `reap` records the question).
A watcher must qualify the same way — its daemon exits on FIRED or EXPIRED, which is outside the session's control —
**but only if nothing lets a spec silence the supervisor with no live daemon behind it.** Part B is what makes
part A legal; do not land A without B.

Second doctrine, from `_watch_armed`'s docstring: for this supervisor **"ask" is the fail-safe direction, not
"stay silent"** (the 11-hour idle incident was all silence). Every ambiguous case below resolves toward poking.

## 3. The fix — four parts, all required

### A. Placement: a live watcher suppresses in every state, after the landed-job poke

Move the watcher check out of the `"growing"` branch so it sits beside the standalone hold check, **after** the
`"landed"` branch — a landed local job is news the session can act on without the user and must still poke, for a
watcher exactly as for a hold:

```python
if state == "growing":
    self.sup_landed_poked = False
elif state == "landed" and not self.sup_landed_poked:
    ...unchanged...; return
if held or watch_active:          # watch_active computed ONCE per tick, see part C
    return                        # declared wait: silent until it ends
```

Compute `held` and `watch_active` once at the top of the tick (the hold check already runs every tick for its
clearing side effect — see the comment at ~2087–2095, which explains why it cannot live inside the growing branch;
the same reasoning now applies to the watcher).

### B. Liveness: a spec silences only while its daemon is provably alive AND inside a supervisor-side cap

`_watch_armed()` (~1972–1983) today returns `True` when `pid is None or _pid_alive(pid)`. Two holes, both of which
A turns from "silent while a job runs" into "silent forever":

1. **`pid is None` is not "freshly armed"; it is "the daemon never wrote its pid".** `cmd_arm` writes the spec with
   `pid: None`, spawns, sleeps `SETTLE_S`, and the daemon overwrites the pid as its first act (`daemon()`,
   ~345–348). A spawn that fails after the spec is written leaves `pid: None` **until `reap` at the next
   SessionStart** — a permanent, model-authored mute. Rule: `pid is None` counts as armed only while
   `now - armed_epoch <= SETTLE_GRACE_S` (use `2 * SETTLE_S`, read the constant from the same place `cmd_arm` does
   or duplicate it with a comment naming the source). After that, a pid-less spec is **not** a declaration.
2. **The ttl is model-supplied and unbounded.** `--ttl` is whatever the arming session passed; under A a huge ttl is
   a huge mute. Add `SUP_WAIT_MAX_S = 86400` in `ccage-auto` and treat a spec as active only while
   `now - armed_epoch <= min(spec["ttl"], SUP_WAIT_MAX_S)`. **Apply the same cap in `_hold_active`** — the hole is
   identical there today (default 259200 s, model-settable) and was accepted only because nothing depended on it;
   say so in the commit. The daemon keeps its own ttl and its own EXPIRED report; the cap only bounds what the
   *supervisor* honours.

`_pid_alive` (~961–972) errs toward alive on `EPERM`/other `OSError`; keep that — it matches ccage-watch's own
UNKNOWN-counts-as-alive stance, and the cap now bounds how long "unknown" can silence.

### C. Ladder reset when a declared wait ends

New hazard created by A: while a watcher silences, `sup_pokes` and `sup_acted_at` keep whatever values they had
before it was armed. When the daemon exits (FIRED — the work is *ready*), the next tick sees, say,
`sup_pokes == 1` and `now - sup_acted_at >= sup_escalate`, and **escalates straight to the convert/restart rung
with no fresh poke** — restarting the session at the exact moment its input arrived. A hold does not have this
problem only because it ends with a human turn, which resets the idle episode.

Track the transition: keep `self.sup_wait_prev` (bool, init `False`); each tick compute
`waiting = held or watch_active`; if `self.sup_wait_prev and not waiting`, reset `sup_pokes = 0`,
`sup_acted_at = now`, `sup_landed_poked = False`, and log once (`SUPERVISOR: declared wait ended — ladder reset`);
then `self.sup_wait_prev = waiting`. The end of a wait must always yield **one fresh poke, then the ladder** — the
same termination guarantee Task 6 gives a wedged session.

### D. Scope: a spec silences only the session that wrote it

Both `_hold_active` and `_watch_armed` glob the **whole cage's** `watch/*.json` (`_config_dir()` is
`<config>/`, i.e. `~/.claude-<cage>/`, shared by every session in that cage). Today this means: a parallel
session's hold silences this one, and this session's user typing **deletes** the other session's hold
(`os.remove(spath)` at ~1947). A masks the watcher half of this; A removes the mask, so D lands with it.

No session id reaches `ccage-watch` (checked: only `CCAGE_SLOT` and `CLAUDE_CONFIG_DIR` are read), and plumbing
one is out of scope. **The spec already carries `resume_file`**, which encodes the slot (`RESUME.md` or
`RESUME.<slot>.md`) — and parallel same-directory sessions are exactly what slots exist to separate. So: in both
functions, skip any spec whose `resume_file` differs from this supervisor's own
(`"RESUME" + slot_suffix() + ".md"`, `slot_suffix` at ~603). A spec **without** `resume_file` does not silence
(doctrine: ask is the safe default); this only affects specs armed before the field existed, all of which are
inside one ttl of retirement.

This does not separate two **slotless** sessions in one cage; say so in the docstring. That residual is
pre-existing, and the design doc's own position is that parallel sessions take slots.

## 4. Edge-case table — every row must be a test

| # | Situation | Required behaviour | Part |
|---|---|---|---|
| 1 | Watcher armed, no local job (`state == "none"`) | silent | A |
| 2 | Watcher armed, local job growing | silent (unchanged) | A |
| 3 | Watcher armed, local job **landed** | pokes once with the path (unchanged) | A |
| 4 | Watcher FIRES (daemon exits, spec removed) | next tick: **one fresh poke**, ladder from rung 0 | C |
| 5 | Watcher EXPIRES unfired | same as 4; RESUME already carries the EXPIRED block from the daemon | C |
| 6 | Daemon killed (OOM/SIGKILL; spec left, pid dead) | pokes — pid not alive | B |
| 7 | Spec with `pid: None`, age ≤ grace | silent | B |
| 8 | Spec with `pid: None`, age > grace | pokes | B |
| 9 | Spec with `ttl` = 10 years, daemon alive | silent until `SUP_WAIT_MAX_S`, then pokes | B |
| 10 | Spec `armed_epoch` in the future / absent / non-numeric | pokes (unreadable = not a declaration) | B |
| 11 | Spec from another slot | ignored: neither silences nor is deleted by this session | D |
| 12 | Spec with no `resume_file` | ignored | D |
| 13 | Hold + watcher both active, user types | hold cleared, watcher still silences | A, D |
| 14 | `sup_pokes == 2` when a watcher is armed, then it fires hours later | rung 0, not escalation | C |
| 15 | Real work resumes while armed (tool_use) | idle episode resets as today; no interaction | — |
| 16 | Mid-write / invalid JSON spec | skipped (unchanged) | — |

## 5. Acceptance

- Unit tests in the harness `bin/ccage-auto` already uses (find it; if there is none, add
  `tests/test_supervisor_wait.py` driving one tick of the ladder against a temp config dir with fabricated spec
  files and a fabricated transcript). One test per row above, named by row.
- `ccage-watch selftest` still passes unchanged — the watcher side is not modified.
- A live check: arm a watcher on `test -f /tmp/x` in a session with **no** background job, wait > 2 poke
  intervals, confirm zero pokes; `touch /tmp/x`; confirm exactly one poke within one poll interval and no
  escalation.
- Update `plans/2026-08-16-idle-session-supervisor.md` where it describes the third exit, and the poke text is
  now **true as written** — do not change the text.

## 6. Not changed, deliberately

The poke message (it states an observation, never a reason — measured 2026-08-16). The `"landed"` exception. The
daemon's own ttl and reporting. `reap`. The `"ask" is fail-safe` direction — every new `continue`/`return False`
above resolves toward poking.

---

## 7. Implementation record — 2026-09-12

**Landed:** all four parts, plus `tests/test_supervisor_wait.py` (44 cases; every row of §4, with the
liveness and scope rows parametrised over both job states — see below).

### Verification

| Gate | Result |
|---|---|
| New tests against the **unfixed** tree | **21 failed / 23 passed**, and **0 of the failures were `AttributeError`** |
| New tests against the fixed tree | **44 passed** |
| Whole Python suite (`tests/`) | **143 passed** |
| `ccage-watch selftest` | **PASS** (unchanged side, as predicted) |
| `ruff check bin/ccage-auto` | **125 before, 125 after — zero delta** |
| `ruff check tests/test_supervisor_wait.py` | clean |
| bats (`tests/test_autock.bats`) | **NOT RUN** — see below |

Two things about that table are worth more than the numbers.

**The red run was made honest on the second attempt.** The first version of the liveness and scope rows
used `state="none"`, where the pre-fix code pokes regardless — so they passed on the unfixed tree *for the
wrong reason* and could never have caught a regression in part B or D. They are now parametrised over
`["none", "growing"]`; the `"growing"` case reaches `_watch_armed()` even before part A, so it binds
liveness and scope independently of placement. Separately, 14 of the original 24 failures were
`AttributeError` from referencing the two new constants — a symbol-presence red, which is the same weak
evidence as a `ModuleNotFoundError` and is rejected at review in this project's sibling repos. The
constants are now read via `getattr(AUTO, ..., <intended value>)` so those rows fail on an **assertion**
against a tree that lacks them.

**The ruff delta was nearly mis-reported.** Measured first against a scratch copy of the original outside
the repo, ruff claimed +3 (`FURB162` ×2, `UP017`) — all `datetime` rules, in a change that adds no
`datetime` code. The scratch directory infers a different Python target version. Re-measured with both
files inside the repo, the count is identical. Compare like with like, or the delta gate reports
the environment rather than the change.

### NOT RUN: the bats suite

`tests/test_autock.bats` could not be run in this clone. `tests/bats/bin/` is **empty** and the
submodule's git dir is missing (`git submodule status` → `fatal: not a git repository:
tests/bats/../../.git/modules/tests/bats`; `git submodule update --init tests/bats` → `fatal: could not
get a repository handle`). Invoking `libexec/bats-core/bats` directly gets as far as discovering 160
tests and then executes 0, because `bats_readlinkf` — normally defined by the missing `bin/bats` — is
unavailable, so `BATS_LIBEXEC` resolves to the cwd and `bats-exec-test` is not found. Pre-existing and
unrelated to this change; `tests/ci-local.sh` would hit the same wall here. **The bats regression for
this change is still owed** and should be run where the submodule is intact.

### Deviations from the spec as written

1. **`SUP_PIDLESS_GRACE_S = 5.0`, not `2 * SETTLE_S`.** §3B said to reuse ccage-watch's `SETTLE_S`, which
   is **0.2 s** — a 0.4 s window. That is the *parent's* grace for the daemon to write its state, and a
   loaded machine can delay the daemon's first write past it, which would turn a legitimately-arming
   watcher into a poke. 5 s is still negligible against `sup_idle` (minutes), which is the property that
   actually matters: a spec whose daemon never started can never buy a meaningful silence.
2. **`_spec_age()` also rejects a *future* `armed_epoch`.** §4 row 10 listed it; the spec's prose in §3B
   did not say where it lived. It is in the shared age helper, so both a hold and a watcher get it.

### Not done

Deploying to `~/.local/bin/ccage-auto` is a copy of the file (what `install.sh` does for it). **A running
`ccage-auto` has already loaded its source, so a live supervisor keeps the old behaviour until it is
restarted** — the fix applies to sessions started afterwards.
