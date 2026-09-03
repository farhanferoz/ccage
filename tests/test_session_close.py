"""Tests for ccage-auto's prompt-line sanitation and its done-marker session
close — the two mechanisms a v0.18.1 review found inert in production while the
bats suite was green.

Both defects were invisible to the bats suite by construction, so both are
pinned here instead:

  * `_clean_input` wrote b"\\x1b\\x15" in one go. A terminal keypress parser
    decodes ESC followed closely by another byte as ONE Alt-modified key, so
    neither `escape` nor `ctrl+u` was ever emitted and the prompt line was never
    cleared. The bats fake claude matches raw bytes and has no keypress parser,
    so it could not see this. test_clean_input_* decode the bytes the watcher
    actually writes with the same parser the real TUI's is a fork of.

  * `_close_session` fell back to SIGTERM on the pty child. In a real cage that
    child is an interactive bash (the `claude` shell function's body ends in a
    subshell), which IGNORES SIGTERM, with claude as its child. bats launches
    via CCAGE_AUTOCK_EXEC, a bare command bash execs in place, so the harness
    could only ever exercise the shape where the wrong signal happens to work.
    test_close_session_* pin the signal escalation directly.

bin/ccage-auto has no .py suffix, so it is loaded via SourceFileLoader — same
pattern as tests/test_weekly_floor.py.
"""
import json
import os
import shutil
import signal
import subprocess
import threading
import time
from pathlib import Path

import pytest

from conftest import load_ccage_auto

ROOT = Path(__file__).resolve().parent.parent


AUTO = load_ccage_auto("ccage_auto_close")


class RecordingWatcher:
    """A Watcher wired to an in-memory pty replacement that timestamps writes."""

    def __init__(self, tmp_path, **cfg_over):
        self.writes = []          # (monotonic seconds, bytes)
        self.logs = []
        cfg = AUTO.Config([])
        for k, v in cfg_over.items():
            setattr(cfg, k, v)
        self.w = AUTO.Watcher(cfg, master_fd=-1, write_lock=threading.Lock(),
                              cwd=str(tmp_path), sdir=str(tmp_path), logf=None,
                              pid=None)
        self.w._write = self._write
        self.w._log = self.logs.append

    def _write(self, data):
        self.writes.append((time.monotonic(), data))
        return True

    def keys(self):
        """Decode the recorded writes the way a terminal does, preserving the
        real inter-write gaps, and return the key names in order."""
        return decode_keys(self.writes)


def decode_keys(writes):
    """Feed timestamped writes through node's readline keypress parser.

    node's parser is the one Ink forks, and `escapeCodeTimeout` is present in the
    shipped claude bundle, so this is the closest reproduction of the real TUI's
    decoding that does not require driving a live session. Returns a list of
    {name, ctrl, meta} dicts.
    """
    node = shutil.which("node")
    if node is None:
        pytest.skip("node not available to decode keypresses")
    steps = []
    base = writes[0][0] if writes else 0.0
    prev = base
    for ts, data in writes:
        steps.append({"delay": round((ts - prev) * 1000), "bytes": list(data)})
        prev = ts
    script = """
const readline = require('readline');
const { PassThrough } = require('stream');
const steps = JSON.parse(process.argv[1]);
const s = new PassThrough();
readline.emitKeypressEvents(s);
const got = [];
s.on('keypress', (ch, key) => got.push(
    {name: key.name === undefined ? null : key.name, ctrl: !!key.ctrl, meta: !!key.meta}));
(function step(i) {
  if (i >= steps.length) {
    // outlast the escape timeout so a trailing lone ESC is flushed as a key
    setTimeout(() => { console.log(JSON.stringify(got)); }, 900);
    return;
  }
  setTimeout(() => { s.write(Buffer.from(steps[i].bytes)); step(i + 1); }, steps[i].delay);
})(0);
"""
    out = subprocess.run([node, "-e", script, json.dumps(steps)],
                         capture_output=True, text=True, timeout=120)
    assert out.returncode == 0, out.stderr
    return json.loads(out.stdout.strip().splitlines()[-1])


# --------------------------------------------------------------------------
# _clean_input: ESC and Ctrl+U must decode as SEPARATE keypresses
# --------------------------------------------------------------------------

def test_clean_input_never_writes_esc_and_ctrl_u_in_one_chunk(tmp_path):
    """The original defect, pinned at the byte level: the two control bytes must
    not share a write, or the parser sees one Alt-modified key."""
    rw = RecordingWatcher(tmp_path)
    rw.w._clean_input()
    for _, data in rw.writes:
        assert b"\x1b\x15" not in data, "ESC and Ctrl+U written as one chunk"
        assert not (b"\x1b" in data and b"\x15" in data)


def test_clean_input_gap_exceeds_the_escape_timeout(tmp_path):
    """ESC must be followed by a gap wider than the ~500ms escape timeout.

    Measured boundary: a 300ms gap is still merged into one meta keypress; 700ms
    separates. _interrupt's 0.5s settle plus ESC_TAIL has to clear 500ms.
    """
    rw = RecordingWatcher(tmp_path)
    rw.w._clean_input()
    esc_at = next(ts for ts, d in rw.writes if b"\x1b" in d)
    next_at = next(ts for ts, d in rw.writes if ts > esc_at)
    assert next_at - esc_at > 0.5, "gap after ESC does not clear the escape timeout"


def test_clean_input_decodes_as_escape_then_line_kill(tmp_path):
    """End to end through a real keypress parser: escape, then ctrl+e, ctrl+u.

    Ctrl+E first because Ctrl+U deletes to line START only, so text right of the
    cursor would otherwise survive. Both bindings are present in the shipped
    bundle (endOfLine / deleteToLineStart).
    """
    rw = RecordingWatcher(tmp_path)
    rw.w._clean_input()
    names = [(k["name"], k["ctrl"]) for k in rw.keys()]
    assert ("escape", False) in names, names
    assert ("u", True) in names, names
    assert names.index(("escape", False)) < names.index(("u", True))
    # and nothing decoded as a lone Alt-modified mystery key
    assert not [k for k in rw.keys() if k["name"] is None and k["meta"]], rw.keys()


def test_clean_input_sends_no_sigint_byte(tmp_path):
    """Ctrl+C would raise SIGINT in the session's own child processes."""
    rw = RecordingWatcher(tmp_path)
    rw.w._clean_input()
    assert not any(b"\x03" in d for _, d in rw.writes)


# --------------------------------------------------------------------------
# _close_session: signal escalation, and the shape bats cannot reach
# --------------------------------------------------------------------------

def test_close_session_escalates_sighup_then_sigkill(tmp_path, monkeypatch):
    """/exit first; if the child does not go, SIGHUP, then SIGKILL — never
    SIGTERM, which an interactive bash ignores."""
    rw = RecordingWatcher(tmp_path)
    rw.w.pid = 4242
    sent = []
    monkeypatch.setattr(AUTO, "EXIT_GRACE", 0.05)
    monkeypatch.setattr(AUTO, "EXIT_KILL_GRACE", 0.05)
    monkeypatch.setattr(rw.w, "_clean_input", lambda: None)
    monkeypatch.setattr(rw.w, "_signal", lambda sig: sent.append(sig))
    monkeypatch.setattr(rw.w, "_await_exit", lambda t: False)   # never dies
    rw.w._close_session()
    assert sent == [signal.SIGHUP, signal.SIGKILL]
    assert signal.SIGTERM not in sent
    assert any(b"/exit" in d for _, d in rw.writes)


def test_close_session_stops_at_exit_when_the_child_goes(tmp_path, monkeypatch):
    rw = RecordingWatcher(tmp_path)
    rw.w.pid = 4242
    sent = []
    monkeypatch.setattr(rw.w, "_clean_input", lambda: None)
    monkeypatch.setattr(rw.w, "_signal", lambda sig: sent.append(sig))
    monkeypatch.setattr(rw.w, "_await_exit", lambda t: True)
    rw.w._close_session()
    assert sent == [], "signalled a child that had already exited"


def test_close_session_does_not_mark_the_turn_as_injected(tmp_path, monkeypatch):
    """/exit ends a session rather than starting a turn, so it must not leave the
    stop guard's `.injected` marker behind."""
    rw = RecordingWatcher(tmp_path)
    marked = []
    monkeypatch.setattr(rw.w, "_clean_input", lambda: None)
    monkeypatch.setattr(rw.w, "_await_exit", lambda t: True)
    monkeypatch.setattr(rw.w, "_config_dir", lambda: marked.append(1) or str(tmp_path))
    rw.w._close_session()
    assert marked == [], "/exit wrote an injected-turn marker"


def test_await_exit_reaps_and_records_status(tmp_path):
    """_await_exit polls the child, not self.stop, and keeps the status so
    run_proxy can still report a real exit code after the reap."""
    pid = os.fork()
    if pid == 0:
        os._exit(7)
    rw = RecordingWatcher(tmp_path)
    rw.w.pid = pid
    assert rw.w._await_exit(5.0) is True
    assert rw.w.child_status is not None
    assert os.waitstatus_to_exitcode(rw.w.child_status) == 7


def test_await_exit_returns_false_while_the_child_lives(tmp_path):
    pid = os.fork()
    if pid == 0:
        time.sleep(30)
        os._exit(0)
    try:
        rw = RecordingWatcher(tmp_path)
        rw.w.pid = pid
        assert rw.w._await_exit(0.4) is False
        assert rw.w.child_status is None
    finally:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)


def test_sighup_kills_a_subshell_launcher_that_sigterm_cannot(tmp_path):
    """The production process tree, which the bats harness cannot produce.

    The cage runs `bash -ic 'claude "$@"'` where `claude` is a shell function
    whose body ends in a subshell, so the pty child is an interactive bash with
    the real process beneath it. Pinned here: SIGTERM leaves both alive, SIGHUP
    takes both down. If this ever inverts, _close_session's fallback is wrong
    again.
    """
    import pty

    home = tmp_path / "home"
    home.mkdir()
    (home / "target").write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(120)\n")
    os.chmod(home / "target", 0o755)
    (home / ".bashrc").write_text(
        'claude() {\n    (\n      : "pre-exec hook"\n'
        '      command "$HOME/target" "$@"\n    )\n}\n')

    env = dict(os.environ, HOME=str(home))
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvpe("/bin/bash", ["/bin/bash", "-ic", 'claude "$@"', "bash"], env)
        finally:
            os._exit(127)

    def alive(p):
        try:
            wpid, _ = os.waitpid(p, os.WNOHANG)
        except ChildProcessError:
            return False
        return wpid == 0

    try:
        deadline = time.time() + 15
        while time.time() < deadline and not (home / "target").exists():
            time.sleep(0.1)
        time.sleep(3.0)                      # let bash reach the subshell + exec
        assert alive(pid), "probe child never started"

        os.kill(pid, signal.SIGTERM)
        time.sleep(1.0)
        assert alive(pid), "SIGTERM unexpectedly killed the interactive bash — " \
                           "_close_session's SIGHUP fallback may no longer be needed"

        os.kill(pid, signal.SIGHUP)
        deadline = time.time() + 10
        while time.time() < deadline and alive(pid):
            time.sleep(0.1)
        assert not alive(pid), "SIGHUP failed to close the subshell launcher"
    finally:
        for sig in (signal.SIGKILL,):
            try:
                os.kill(pid, sig)
            except OSError:
                pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        os.close(fd)


# --------------------------------------------------------------------------
# done-marker grace: the close must not cut off the turn that wrote the marker
# --------------------------------------------------------------------------

def test_done_grace_default_and_env_override(monkeypatch):
    """The DEFAULT is what production runs, so it is asserted directly rather
    than only through tests that shorten it."""
    monkeypatch.delenv("CCAGE_AUTOCK_DONE_GRACE", raising=False)
    assert AUTO.Config([]).done_grace == AUTO.DONE_IDLE_GRACE == 10.0
    monkeypatch.setenv("CCAGE_AUTOCK_DONE_GRACE", "0")
    assert AUTO.Config([]).done_grace == 0.0
    monkeypatch.setenv("CCAGE_AUTOCK_DONE_GRACE", "nonsense")
    assert AUTO.Config([]).done_grace == AUTO.DONE_IDLE_GRACE


def test_transcript_quiet_for_tracks_the_active_transcript(tmp_path):
    rw = RecordingWatcher(tmp_path)
    # Pin start_time into the past. active_jsonl() drops any transcript older
    # than it, which broke this test in BOTH directions while it used the real
    # construction time:
    #   * the backdated file below sits 60s BEFORE start_time, so it was
    #     filtered out and _transcript_quiet_for returned the "nothing to read"
    #     sentinel -- 180.0, which satisfies `>= 59` for entirely the wrong
    #     reason. The assertion never measured a quiet transcript at all.
    #   * the fresh file is written microseconds AFTER start_time, and one full
    #     run in eleven saw it filtered too (observed 2026-09-03: 180.0 < 1.0).
    #     That race is unexplained -- a coarse-mtime-clock theory was measured
    #     and falsified at 0/20000, and 3000 standalone iterations of this exact
    #     sequence never reproduced it -- so this pins the input rather than
    #     claiming a diagnosis.
    # What is under test here is the ARITHMETIC (now - mtime), not the since
    # filter, which active_jsonl has its own tests for.
    rw.w.start_time = time.time() - 3600
    assert rw.w._transcript_quiet_for() == AUTO.DONE_CLOSE_CEILING   # nothing yet
    p = tmp_path / "sess.jsonl"
    p.write_text("{}\n")
    os.utime(p, None)
    assert rw.w._transcript_quiet_for() < 1.0
    old = time.time() - 60
    os.utime(p, (old, old))
    quiet = rw.w._transcript_quiet_for()
    assert quiet != AUTO.DONE_CLOSE_CEILING, "must MEASURE the gap, not fall back"
    assert 59 <= quiet < 61


def test_exit_on_done_defaults_on_and_flags_win(monkeypatch):
    monkeypatch.delenv("CCAGE_AUTOCK_EXIT_ON_DONE", raising=False)
    assert AUTO.Config([]).exit_on_done is True
    assert AUTO.Config(["--no-exit-on-done"]).exit_on_done is False
    monkeypatch.setenv("CCAGE_AUTOCK_EXIT_ON_DONE", "0")
    assert AUTO.Config([]).exit_on_done is False
    assert AUTO.Config(["--exit-on-done"]).exit_on_done is True
