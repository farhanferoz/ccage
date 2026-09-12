"""Tests for the idle supervisor's DECLARED WAIT suppression — watchers and holds.

The defect these pin: `ccage-watch arm` is advertised by the supervisor's own
poke text as the "waiting on a MACHINE" exit ("After either of the last two I
will not ask again until it resolves"), but the armed-watcher check was
consulted only under `state == "growing"` — only while THIS session had a
tracked background job still producing output. A watcher bridging work that
happens outside the session (a separate executor process, CI, a cluster job)
left `_job_state()` at "none", so the check was skipped and the poke fired
anyway for the whole wait. Measured 2026-09-12 in the guard cage, where one such
poke produced an unwanted /checkpoint.

The fix is four parts and every row of the table in
plans/2026-09-12-supervisor-watcher-suppression-fix.md is a test here:

  A placement   — a live watcher suppresses in every job state, AFTER the
                  landed-job poke (a landing is news the session can act on
                  without the user, so a declared wait must not bury it).
  B liveness    — a spec silences only while its daemon is provably alive AND
                  within min(its ttl, SUP_WAIT_MAX_S); a pid-less spec past
                  SUP_PIDLESS_GRACE_S is not a declaration. This is what keeps A
                  legal under the ratified asymmetry: a model-authored signal may
                  keep the supervisor awake but may never send it to sleep.
  C ladder      — the END of a wait re-enters at the POKE rung, never at
                  escalation, so a watcher that fires cannot trigger a
                  checkpoint/clear at the moment its input arrived.
  D scope       — a spec silences only sessions reading the same RESUME file, so
                  a parallel slot's declaration neither mutes this session nor
                  gets deleted by it.

bin/ccage-auto has no .py suffix, so it is loaded via SourceFileLoader — same
pattern as tests/test_session_close.py.
"""
import json
import os
import threading
import time

import pytest

from conftest import load_ccage_auto

AUTO = load_ccage_auto("ccage_auto_wait")

# The two new ceilings are read through getattr with their intended values on
# purpose, so the rows below express the BEHAVIOUR ("a wait past the cap must not
# silence") rather than the presence of a symbol. Run against a tree that lacks
# the constants these rows must fail on an ASSERTION; a red that only says "this
# name is missing" is the same weak evidence as a ModuleNotFoundError, which is
# exactly the kind of red this project rejects at review.
WAIT_CAP = getattr(AUTO, "SUP_WAIT_MAX_S", 86400.0)
PIDLESS_GRACE = getattr(AUTO, "SUP_PIDLESS_GRACE_S", 5.0)


def dead_pid():
    """A pid that is provably gone: forked, exited, and reaped."""
    pid = os.fork()
    if pid == 0:
        os._exit(0)
    os.waitpid(pid, 0)
    return pid


class Harness:
    """A Watcher whose watch dir, job state and poking are all under our control.

    `_config_dir()` is two levels above sdir, so sdir=<tmp>/projects/<slug> puts
    the watch dir at <tmp>/watch — the same shape a real cage has.
    """

    def __init__(self, tmp_path, state="none", slot=None):
        self.cage = tmp_path
        self.watch = tmp_path / "watch"
        self.watch.mkdir(parents=True, exist_ok=True)
        sdir = tmp_path / "projects" / "slug"
        sdir.mkdir(parents=True, exist_ok=True)
        self.transcript = sdir / "session.jsonl"
        self.transcript.write_text("")

        cfg = AUTO.Config([])
        cfg.supervisor = True
        cfg.sup_idle = 300.0
        cfg.sup_escalate = 600.0
        self.pokes = []
        self.logs = []
        self.nudges = []

        w = AUTO.Watcher(cfg, master_fd=-1, write_lock=threading.Lock(),
                         cwd=str(tmp_path), sdir=str(sdir), logf=None, pid=None)
        w._log = self.logs.append
        w._supervisor_poke = lambda idle_min, detail: (
            self.pokes.append(idle_min), setattr(w, "sup_pokes", w.sup_pokes + 1),
            setattr(w, "sup_acted_at", time.time()))
        w._arm_nudge = lambda path, pct: self.nudges.append(pct)
        w._parked = lambda path: {"jobs": {}}
        w._job_state = lambda rec: state
        w._worked_since = lambda path, when: False
        w._user_typed_since = lambda path, when: False
        w._sup_detail = lambda rec: ""
        # idle well past sup_idle
        w.last_growth = time.time() - 10_000
        self.w = w

    def spec(self, name="w1", **over):
        """A watcher spec that is, by default, a valid live declaration."""
        spec = {
            "id": name,
            "cwd": str(self.cage),
            "resume_file": "RESUME.md",
            "cond": "true",
            "note": "",
            "interval": 600,
            "ttl": 86400,
            "armed_epoch": time.time(),
            "pid": os.getpid(),          # this process: provably alive
        }
        spec.update(over)
        path = self.watch / (name + ".json")
        path.write_text(json.dumps(spec))
        return path

    def hold(self, name="h1", **over):
        spec = {
            "id": name,
            "kind": AUTO.HOLD_KIND,
            "cwd": str(self.cage),
            "resume_file": "RESUME.md",
            "question": "waiting on you",
            "ttl": 259200,
            "armed_epoch": time.time(),
            "pid": None,
        }
        spec.update(over)
        path = self.watch / (name + ".json")
        path.write_text(json.dumps(spec))
        return path

    def tick(self):
        self.w._supervise(str(self.transcript), 12.0)
        return self.pokes


# ---------------------------------------------------------------- placement (A)

def test_row1_watcher_armed_no_local_job_is_silent(tmp_path):
    """Row 1 — THE DEFECT. No tracked job, so state is "none"; before the fix the
    growing-branch check was skipped entirely and the supervisor poked."""
    h = Harness(tmp_path, state="none")
    h.spec()
    assert h.tick() == []


def test_row2_watcher_armed_job_growing_is_silent(tmp_path):
    h = Harness(tmp_path, state="growing")
    h.spec()
    assert h.tick() == []


def test_row3_landed_job_pokes_through_an_armed_watcher(tmp_path):
    """Row 3 — a landing is news the session can act on without the user, so it
    must survive a declared wait. This is why the check sits after the branch."""
    h = Harness(tmp_path, state="landed")
    h.spec()
    assert len(h.tick()) == 1
    assert h.w.sup_pokes == 1


def test_no_watcher_no_hold_still_pokes(tmp_path):
    """The control: suppression must not be unconditional."""
    h = Harness(tmp_path, state="none")
    assert len(h.tick()) == 1


# ---------------------------------------------------------------- liveness (B)

BOTH_STATES = pytest.mark.parametrize("state", ["none", "growing"])
"""Every liveness/scope row runs in BOTH job states on purpose.

With state="none" the pre-fix code poked regardless, so such a row would pass on
the unfixed tree for the wrong reason and could never catch a regression in part
B or D. The "growing" case reaches _watch_armed() even before part A, so it
binds the liveness and scope rules independently of placement.
"""


@BOTH_STATES
def test_row6_dead_daemon_does_not_silence(tmp_path, state):
    h = Harness(tmp_path, state=state)
    h.spec(pid=dead_pid())
    assert len(h.tick()) == 1


@BOTH_STATES
def test_row7_pidless_spec_within_grace_is_silent(tmp_path, state):
    h = Harness(tmp_path, state=state)
    h.spec(pid=None, armed_epoch=time.time())
    assert h.tick() == []


@BOTH_STATES
def test_row8_pidless_spec_past_grace_does_not_silence(tmp_path, state):
    """Row 8 — a spawn that died after the spec was written used to mute the
    supervisor for the rest of the session, with no process behind it."""
    h = Harness(tmp_path, state=state)
    h.spec(pid=None,
           armed_epoch=time.time() - (PIDLESS_GRACE + 60))
    assert len(h.tick()) == 1


@BOTH_STATES
def test_row9_ttl_beyond_the_cap_is_bounded(tmp_path, state):
    """Row 9 — ttl is model-supplied, so the supervisor caps what it honours."""
    h = Harness(tmp_path, state=state)
    h.spec(ttl=10 * 365 * 86400,
           armed_epoch=time.time() - (WAIT_CAP + 60))
    assert len(h.tick()) == 1


@BOTH_STATES
def test_row9b_inside_the_cap_is_still_silent(tmp_path, state):
    h = Harness(tmp_path, state=state)
    h.spec(ttl=10 * 365 * 86400,
           armed_epoch=time.time() - (WAIT_CAP - 600))
    assert h.tick() == []


@BOTH_STATES
def test_row9c_own_ttl_shorter_than_the_cap_still_governs(tmp_path, state):
    h = Harness(tmp_path, state=state)
    h.spec(ttl=60, armed_epoch=time.time() - 600)
    assert len(h.tick()) == 1


@pytest.mark.parametrize("bad", [
    {"armed_epoch": time.time() + 3600},   # future stamp / clock skew
    {"armed_epoch": None},
    {"armed_epoch": "yesterday"},
    {"ttl": None},
    {"ttl": 0},
    {"ttl": "forever"},
])
@BOTH_STATES
def test_row10_untrustworthy_timestamps_do_not_silence(tmp_path, bad, state):
    h = Harness(tmp_path, state=state)
    h.spec(**bad)
    assert len(h.tick()) == 1, f"{bad} bought silence"


@BOTH_STATES
def test_row16_invalid_json_spec_does_not_silence(tmp_path, state):
    h = Harness(tmp_path, state=state)
    (h.watch / "broken.json").write_text("{not json")
    assert len(h.tick()) == 1


# ---------------------------------------------------------------- ladder (C)

def test_row4_watcher_firing_reenters_at_the_poke_rung(tmp_path):
    """Row 4/14 — the hazard part A creates. While the wait suppressed, sup_pokes
    kept a stale value; when the daemon exits (the work is READY) the next tick
    must poke, not escalate into checkpoint/clear."""
    h = Harness(tmp_path, state="none")
    spec = h.spec()
    assert h.tick() == []                       # silent while armed

    # a stale ladder position from before the wait, and a stale escalate timer
    h.w.sup_pokes = 1
    h.w.sup_acted_at = time.time() - 100_000

    spec.unlink()                               # daemon fired and removed it
    h.tick()

    assert h.nudges == [], "escalated instead of poking when the watcher fired"
    assert len(h.pokes) == 1
    assert any("declared wait ended" in m for m in h.logs)


def test_row5_watcher_expiring_reenters_at_the_poke_rung(tmp_path):
    """Row 5 — expiry differs from firing only in what the daemon wrote to
    RESUME; the supervisor-side transition is the same."""
    h = Harness(tmp_path, state="none")
    h.spec(ttl=3600)
    assert h.tick() == []
    h.w.sup_pokes = 2                           # the give-up rung
    h.w.sup_acted_at = time.time() - 100_000
    # lapse it in place rather than removing it: the daemon can die without
    # cleaning up (OOM/SIGKILL), which is exactly the leftover-spec case.
    h.spec(ttl=3600, armed_epoch=time.time() - 7200)
    h.tick()
    assert h.nudges == []
    assert len(h.pokes) == 1


def test_wait_that_never_started_does_not_reset_the_ladder(tmp_path):
    """The transition must be an EDGE, not a level: an ordinary idle session with
    no declared wait must still climb the ladder normally."""
    h = Harness(tmp_path, state="none")
    h.tick()                                    # poke 1
    assert len(h.pokes) == 1
    h.w.sup_acted_at = time.time() - 100_000    # escalate window elapsed
    h.tick()
    assert h.nudges == [1] or h.w.sup_pokes == 2, "ladder no longer escalates"


def test_row15_work_resuming_during_a_wait_resets_the_episode(tmp_path):
    """Row 15 — the pre-existing evidence-of-work reset must be untouched."""
    h = Harness(tmp_path, state="none")
    h.spec()
    h.tick()
    h.w.sup_pokes = 1
    h.w.sup_acted_at = time.time() - 10
    h.w._worked_since = lambda path, when: True
    h.tick()
    assert h.w.sup_pokes == 0
    assert any("work resumed" in m for m in h.logs)


# ---------------------------------------------------------------- scope (D)

@BOTH_STATES
def test_row11_another_slots_watcher_does_not_silence_us(tmp_path, state):
    h = Harness(tmp_path, state=state)
    h.spec(resume_file="RESUME.other.md")
    assert len(h.tick()) == 1


def test_row11b_another_slots_hold_is_neither_honoured_nor_deleted(tmp_path):
    """The sharper half of row 11: _hold_active DELETES a hold when the user has
    typed. Before the scope check it would delete a hold this session never
    armed, silently discarding another session's question."""
    h = Harness(tmp_path, state="none")
    path = h.hold(resume_file="RESUME.other.md")
    h.w._user_typed_since = lambda p, when: True
    assert len(h.tick()) == 1
    assert path.exists(), "deleted another session's hold"


@BOTH_STATES
def test_row12_spec_without_resume_file_does_not_silence(tmp_path, state):
    h = Harness(tmp_path, state=state)
    spec = json.loads((h.spec()).read_text())
    del spec["resume_file"]
    (h.watch / "w1.json").write_text(json.dumps(spec))
    assert len(h.tick()) == 1


@BOTH_STATES
def test_our_own_slot_still_silences(tmp_path, monkeypatch, state):
    """Scope narrows by RESUME file, so a slotted session honours its OWN spec."""
    monkeypatch.setenv("CCAGE_SLOT", "gen")
    h = Harness(tmp_path, state=state)
    h.spec(resume_file="RESUME.gen.md")
    assert h.tick() == []


# ---------------------------------------------------------------- holds (A/D)

def test_row13_hold_clears_on_a_user_turn_but_the_watcher_still_silences(tmp_path):
    """Row 13 — the two declarations are independent. A hold is turn-scoped; a
    watcher is condition-scoped and must survive the user typing, which is what
    makes it the right primitive for a wait spanning many exchanges."""
    h = Harness(tmp_path, state="none")
    hold_path = h.hold()
    h.spec()
    h.w._user_typed_since = lambda p, when: True
    assert h.tick() == []
    assert not hold_path.exists(), "our own answered hold should be cleared"


def test_hold_alone_still_silences_in_every_state(tmp_path):
    """The hold behaviour this change must not regress."""
    h = Harness(tmp_path, state="none")
    h.hold()
    assert h.tick() == []


def test_hold_past_the_cap_lapses(tmp_path):
    """Holds get the same supervisor-side ceiling as watchers: the default hold
    ttl is 259200 s and model-settable, which is a three-day mute."""
    h = Harness(tmp_path, state="none")
    h.hold(ttl=259200, armed_epoch=time.time() - (WAIT_CAP + 60))
    assert len(h.tick()) == 1
    assert any("hold lapsed" in m for m in h.logs)
