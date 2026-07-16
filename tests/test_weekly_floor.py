"""Tests for the ccage-auto weekly-limit floor: read_weekly_state, the
Watcher._weekly_tick state machine, and Config's --weekly-floor /
CCAGE_AUTOCK_WEEKLY_FLOOR parsing + validation. See docs/WEEKLY-LIMIT-GUARD.md
for the design.

bin/ccage-auto has no .py suffix, so it is loaded via SourceFileLoader --
same pattern as tests/test_subagent_watch.py's _load_ccage_auto(). Module-level
code is import-safe: main() is guarded by __name__ == "__main__".
"""
import importlib.machinery
import importlib.util
import json
import os
import threading
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parent.parent


def _load_ccage_auto():
    path = str(ROOT / "bin" / "ccage-auto")
    loader = importlib.machinery.SourceFileLoader("ccage_auto_weekly", path)
    spec = importlib.util.spec_from_loader("ccage_auto_weekly", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


ccage_auto = _load_ccage_auto()


def _write_state(config_root, used_percentage, ts, resets_at=None):
    sd = {"used_percentage": used_percentage}
    if resets_at is not None:
        sd["resets_at"] = resets_at
    (config_root / ccage_auto.RATE_LIMITS_STATE).write_text(
        json.dumps({"seven_day": sd, "ts": ts}))


# --- (a) read_weekly_state ---------------------------------------------------

def test_read_weekly_state_happy(tmp_path):
    config_root = tmp_path / "cage"
    config_root.mkdir()
    ts = 1_000_000
    _write_state(config_root, used_percentage=30.0, ts=ts, resets_at="2026-07-20T00:00:00Z")
    remaining, resets, age = ccage_auto.read_weekly_state(str(config_root), now=ts + 42)
    assert remaining == 70.0
    assert resets == "2026-07-20T00:00:00Z"
    assert age == 42


def test_read_weekly_state_missing_file(tmp_path):
    config_root = tmp_path / "cage"
    config_root.mkdir()
    assert ccage_auto.read_weekly_state(str(config_root)) == (None, None, None)


def test_read_weekly_state_malformed_json(tmp_path):
    config_root = tmp_path / "cage"
    config_root.mkdir()
    (config_root / ccage_auto.RATE_LIMITS_STATE).write_text("not json {")
    assert ccage_auto.read_weekly_state(str(config_root)) == (None, None, None)


def test_read_weekly_state_missing_ts(tmp_path):
    config_root = tmp_path / "cage"
    config_root.mkdir()
    (config_root / ccage_auto.RATE_LIMITS_STATE).write_text(
        json.dumps({"seven_day": {"used_percentage": 30.0}}))
    assert ccage_auto.read_weekly_state(str(config_root)) == (None, None, None)


def test_read_weekly_state_not_a_dict(tmp_path):
    config_root = tmp_path / "cage"
    config_root.mkdir()
    (config_root / ccage_auto.RATE_LIMITS_STATE).write_text(json.dumps([1, 2, 3]))
    assert ccage_auto.read_weekly_state(str(config_root)) == (None, None, None)


def test_read_weekly_state_seven_day_not_a_dict(tmp_path):
    config_root = tmp_path / "cage"
    config_root.mkdir()
    (config_root / ccage_auto.RATE_LIMITS_STATE).write_text(
        json.dumps({"seven_day": "nope", "ts": 1000}))
    assert ccage_auto.read_weekly_state(str(config_root)) == (None, None, None)


# --- (i) Config parsing + validate ------------------------------------------

def test_config_weekly_floor_env_absent_defaults_zero(monkeypatch):
    monkeypatch.delenv("CCAGE_AUTOCK_WEEKLY_FLOOR", raising=False)
    cfg = ccage_auto.Config([])
    assert cfg.weekly_floor == 0.0


def test_config_weekly_floor_flag_parses(monkeypatch):
    monkeypatch.delenv("CCAGE_AUTOCK_WEEKLY_FLOOR", raising=False)
    cfg = ccage_auto.Config(["--weekly-floor", "20"])
    assert cfg.weekly_floor == 20.0


def test_config_validate_disables_out_of_range_floor(monkeypatch):
    monkeypatch.delenv("CCAGE_AUTOCK_WEEKLY_FLOOR", raising=False)
    cfg = ccage_auto.Config(["--weekly-floor", "150"])
    warns = cfg.validate()
    assert cfg.weekly_floor == 0.0
    assert any("weekly floor" in w and "disabling" in w for w in warns)


# --- Watcher fixture ---------------------------------------------------------

@pytest.fixture
def make_watcher(tmp_path, monkeypatch):
    """Factory building a real ccage_auto.Watcher wired to a tmp cage, with
    _type/_interrupt replaced by recording stubs. Config comes from real env
    parsing (monkeypatched), matching how Config is built in production."""
    monkeypatch.delenv("CCAGE_SLOT", raising=False)
    created = []

    def _factory(*, weekly_floor, nudge_timeout=600.0, hard_interrupt=True, sentinel=None):
        monkeypatch.setenv("CCAGE_AUTOCK_WEEKLY_FLOOR", str(weekly_floor))
        monkeypatch.setenv("CCAGE_AUTOCK_NUDGE_TIMEOUT", str(nudge_timeout))
        monkeypatch.setenv("CCAGE_AUTOCK_HARD_INTERRUPT", "1" if hard_interrupt else "0")
        if sentinel:
            monkeypatch.setenv("CCAGE_AUTOCK_SENTINEL", sentinel)
        else:
            monkeypatch.delenv("CCAGE_AUTOCK_SENTINEL", raising=False)

        cfg = ccage_auto.Config([])
        warns = cfg.validate()
        assert warns == [], warns  # sanity: tests only use in-range floors

        cwd = tmp_path / ("cwd-%d" % len(created))
        cwd.mkdir()
        config_root = tmp_path / ("cage-%d" % len(created))
        sdir = config_root / "projects" / "slug"
        sdir.mkdir(parents=True)
        transcript = cwd / "transcript.jsonl"
        transcript.write_text('{"type":"assistant"}\n')

        r, w = os.pipe()
        logf = (tmp_path / ("log-%d.txt" % len(created))).open("a")
        watcher = ccage_auto.Watcher(cfg, w, threading.Lock(), str(cwd), str(sdir), logf)

        type_calls = []
        interrupt_calls = []
        monkeypatch.setattr(watcher, "_type",
                             lambda text, submit=True, settle=None: type_calls.append(text))
        monkeypatch.setattr(watcher, "_interrupt", lambda: interrupt_calls.append(True))

        env = SimpleNamespace(
            watcher=watcher, cfg=cfg, cwd=cwd, config_root=config_root,
            transcript=str(transcript), type_calls=type_calls,
            interrupt_calls=interrupt_calls, fds=(r, w), logf=logf,
        )
        created.append(env)
        return env

    yield _factory

    for env in created:
        for fd in env.fds:
            try:
                os.close(fd)
            except OSError:
                pass
        env.logf.close()


# --- (b) above warn threshold ------------------------------------------------

def test_above_warn_no_action(make_watcher):
    env = make_watcher(weekly_floor=20.0)
    _write_state(env.config_root, used_percentage=50.0, ts=int(time.time()))  # remaining=50
    result = env.watcher._weekly_tick(env.transcript)
    assert result is False
    assert env.type_calls == []
    assert env.interrupt_calls == []
    assert env.watcher.wf_stage == "none"


# --- (c) warn band -----------------------------------------------------------

def test_warn_band_types_once_then_silent(make_watcher):
    env = make_watcher(weekly_floor=20.0)
    _write_state(env.config_root, used_percentage=77.0, ts=int(time.time()))  # remaining=23
    result = env.watcher._weekly_tick(env.transcript)
    assert result is False
    assert len(env.type_calls) == 1
    assert "Warning" in env.type_calls[0]
    assert env.watcher.wf_stage == "warned"

    result2 = env.watcher._weekly_tick(env.transcript)
    assert result2 is False
    assert len(env.type_calls) == 1        # no re-warn on the second tick
    assert env.watcher.wf_stage == "warned"


# --- (d) at floor -------------------------------------------------------------

def test_at_floor_interrupts_and_stands_down(make_watcher):
    env = make_watcher(weekly_floor=20.0, hard_interrupt=True)
    _write_state(env.config_root, used_percentage=80.0, ts=int(time.time()))  # remaining=20
    result = env.watcher._weekly_tick(env.transcript)
    assert result is True
    assert env.interrupt_calls == [True]
    assert len(env.type_calls) == 1
    assert "standing down" in env.type_calls[0]
    assert env.watcher.cfg.sentinel in env.type_calls[0]
    assert env.watcher.wf_stage == "floored"


# --- (e) floored + confirmed --------------------------------------------------

def test_floored_confirmed_writes_resume_and_stops(make_watcher, monkeypatch):
    env = make_watcher(weekly_floor=20.0)
    _write_state(env.config_root, used_percentage=80.8, ts=int(time.time()),
                 resets_at="2026-07-20T00:00:00Z")             # remaining=19.2 -> "19%"
    env.watcher.wf_stage = "floored"
    env.watcher.nudge_at = time.time()
    monkeypatch.setattr(env.watcher, "_confirmed", lambda: True)

    result = env.watcher._weekly_tick(env.transcript)

    assert result is True
    assert env.watcher.stop is True
    resume = (env.cwd / "RESUME.md").read_text()
    assert "weekly-limit floor" in resume
    assert "19" in resume                  # remaining %
    assert "20" in resume                  # floor %
    assert "2026-07-20T00:00:00Z" in resume


# --- (f) floored + unconfirmed + timeout -> re-nudge -------------------------

def test_floored_unconfirmed_timeout_renudges(make_watcher, monkeypatch):
    env = make_watcher(weekly_floor=20.0, nudge_timeout=1.0, hard_interrupt=True)
    _write_state(env.config_root, used_percentage=85.0, ts=int(time.time()))  # remaining=15
    env.watcher.wf_stage = "floored"
    env.watcher.nudge_at = time.time() - 5.0        # older than nudge_timeout=1s
    monkeypatch.setattr(env.watcher, "_confirmed", lambda: False)

    result = env.watcher._weekly_tick(env.transcript)

    assert result is True
    assert env.watcher.wf_stage == "floored"
    assert env.interrupt_calls == [True]
    assert len(env.type_calls) == 1
    assert "standing down" in env.type_calls[0]


# --- (g) stale / missing sensor ----------------------------------------------

def test_stale_sensor_no_action_logged_once(make_watcher):
    env = make_watcher(weekly_floor=20.0)
    stale_ts = int(time.time() - 3600)               # older than WEEKLY_STALE_S (30 min)
    _write_state(env.config_root, used_percentage=50.0, ts=stale_ts)

    result = env.watcher._weekly_tick(env.transcript)
    assert result is False
    assert env.type_calls == []
    assert env.interrupt_calls == []
    assert env.watcher.wf_stage == "none"
    assert env.watcher.wf_stale_logged is True

    env.watcher._weekly_tick(env.transcript)          # second tick: no re-log
    env.logf.flush()
    log_text = Path(env.logf.name).read_text()
    assert log_text.count("treating as unknown") == 1


def test_missing_sensor_no_action(make_watcher):
    env = make_watcher(weekly_floor=20.0)              # no state file written at all
    result = env.watcher._weekly_tick(env.transcript)
    assert result is False
    assert env.type_calls == []
    assert env.interrupt_calls == []
    assert env.watcher.wf_stage == "none"
    assert env.watcher.wf_stale_logged is True


# --- (h) recovery --------------------------------------------------------------

def test_recovery_resets_stage_to_none(make_watcher):
    env = make_watcher(weekly_floor=20.0)
    _write_state(env.config_root, used_percentage=77.0, ts=int(time.time()))  # remaining=23
    env.watcher._weekly_tick(env.transcript)
    assert env.watcher.wf_stage == "warned"

    _write_state(env.config_root, used_percentage=0.0, ts=int(time.time()))   # remaining=100
    result = env.watcher._weekly_tick(env.transcript)
    assert result is False
    assert env.watcher.wf_stage == "none"


# --- (j) hard_interrupt=False -------------------------------------------------

def test_hard_interrupt_false_skips_interrupt_on_floor(make_watcher):
    env = make_watcher(weekly_floor=20.0, hard_interrupt=False)
    _write_state(env.config_root, used_percentage=90.0, ts=int(time.time()))  # remaining=10
    result = env.watcher._weekly_tick(env.transcript)
    assert result is True
    assert env.interrupt_calls == []
    assert len(env.type_calls) == 1
    assert env.watcher.wf_stage == "floored"
