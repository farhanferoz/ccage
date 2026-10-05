"""Tests for ccage-auto's keep-warm pings.

A ping is one typed turn that re-reads the cached conversation and resets the
prompt-cache clock. It is typed into a live session, so the two things that must
never happen are (a) typing into a dialog the user is looking at, where text plus
Enter would select an option on their behalf, and (b) appending to a half-typed
message. Both are gated on facts -- the transcript's tool_use/tool_result pairing
and the keystrokes the watcher itself forwarded -- never on screen text.

Every gate has its own test, and every one of them was seen RED against a build
with that gate removed before it was trusted (see the commit message).

The transcript rows follow the structure of a real Claude Code 2.1.289
transcript, copied from ~/.claude-ccage/projects/: one row per content block, all
rows of one assistant message sharing message.id (a thinking row, then the
tool_use row); a tool_result is a `type: user` row whose content block carries
tool_use_id. Structure only, no real content.

bin/ccage-auto has no .py suffix, so it is loaded via the shared conftest.
"""
import json
import os
import shutil
import subprocess
import threading
import time

import pytest

from conftest import ROOT, load_ccage_auto

AUTO = load_ccage_auto("ccage_auto_keepwarm")

INTERVAL = 3300.0          # 55 minutes, the shipped default
QUIET = INTERVAL + 600.0   # comfortably due


@pytest.fixture(autouse=True)
def _hermetic_env(monkeypatch):
    """A developer may run this inside a live autonomous session, which exports
    its own CCAGE_AUTOCK_* settings into the child."""
    for name in list(os.environ):
        if name.startswith("CCAGE_AUTOCK_"):
            monkeypatch.delenv(name)


# ------------------------------------------------------------ transcript rows

_ids = iter(range(1, 10**6))


def _usage(tokens, tier):
    """Usage in the real shape. `tier` is "1h", "5m" or None (no cache_creation)."""
    usage = {"input_tokens": 6, "cache_creation_input_tokens": 0,
             "cache_read_input_tokens": tokens - 6, "output_tokens": 40,
             "server_tool_use": {"web_search_requests": 0, "web_fetch_requests": 0}}
    if tier == "1h":
        usage["cache_creation"] = {"ephemeral_1h_input_tokens": 5000,
                                   "ephemeral_5m_input_tokens": 0}
    elif tier == "5m":
        usage["cache_creation"] = {"ephemeral_1h_input_tokens": 0,
                                   "ephemeral_5m_input_tokens": 5000}
    return usage


def assistant_rows(blocks, tokens=300_000, tier="1h", mid=None):
    """One row per content block, all sharing one message.id, like Claude Code."""
    mid = mid or "msg_%06d" % next(_ids)
    rows = []
    for block in blocks:
        rows.append({
            "parentUuid": "p", "isSidechain": False, "type": "assistant",
            "uuid": "u%d" % next(_ids), "timestamp": "2026-10-05T10:00:00.000Z",
            "message": {"model": "claude-opus-5", "id": mid, "type": "message",
                        "role": "assistant", "content": [block],
                        "stop_reason": "tool_use" if block["type"] == "tool_use" else "end_turn",
                        "usage": _usage(tokens, tier)},
            "sessionId": "s", "version": "2.1.289"})
    return rows


def tool_use(tid, name="Bash"):
    return {"type": "tool_use", "id": tid, "name": name,
            "input": {"command": "true"}, "caller": {"type": "direct"}}


def tool_result(tid):
    return {"parentUuid": "p", "isSidechain": False, "type": "user",
            "uuid": "u%d" % next(_ids), "timestamp": "2026-10-05T10:00:01.000Z",
            "message": {"role": "user", "content": [
                {"tool_use_id": tid, "type": "tool_result", "content": "ok",
                 "is_error": False}]},
            "sessionId": "s", "version": "2.1.289"}


def text_block(text="done"):
    return {"type": "text", "text": text}


def thinking_block():
    return {"type": "thinking", "thinking": "", "signature": "sig"}


def typed_user_row(text, when_iso="2026-10-05T10:05:00.000Z"):
    return {"parentUuid": "p", "isSidechain": False, "type": "user",
            "uuid": "u%d" % next(_ids), "timestamp": when_iso,
            "origin": {"kind": "human"}, "promptSource": "typed",
            "message": {"role": "user", "content": text}}


# ------------------------------------------------------------------- harness

class Harness:
    """A Watcher on a temp project dir whose pty writes are recorded, whose
    transcript is quiet for QUIET seconds, and for which every keep-warm gate is
    open until a test closes one."""

    def __init__(self, tmp_path):
        self.tmp = tmp_path
        self.cwd = tmp_path / "proj"
        self.cwd.mkdir()
        self.sdir = tmp_path / "cage" / "projects" / "slug"
        self.sdir.mkdir(parents=True)
        self.path = self.sdir / "session.jsonl"
        self.typed, self.logs = [], []

        cfg = AUTO.Config([])
        cfg.kw_interval = INTERVAL
        self.cfg = cfg
        w = AUTO.Watcher(cfg, master_fd=-1, write_lock=threading.Lock(),
                         cwd=str(self.cwd), sdir=str(self.sdir), logf=None, pid=None)
        w._log = self.logs.append
        w._type = lambda text, **kw: self.typed.append(text)
        w.tui_ready.set()
        w.start_time = time.time() - 100_000   # the transcript below is "this run's"
        w.cfg.soft = 40.0
        self.w = w
        self.write([])          # default: an answered, finished turn
        self.quiet()

    def write(self, rows, tokens=300_000, tier="1h", mode="w"):
        """(Re)write the transcript: a finished turn, then `rows` appended."""
        base = []
        if mode == "w":
            base += assistant_rows([text_block("hello")], tokens=tokens, tier=tier)
        with open(self.path, mode) as fh:
            for row in base + rows:
                fh.write(json.dumps(row) + "\n")

    def quiet(self, seconds=QUIET):
        """Make the transcript `seconds` old: the session has been idle that long."""
        old = time.time() - seconds
        os.utime(self.path, (old, old))

    def tick(self):
        self.w._keepwarm_tick()
        return len(self.typed)

    def logged(self, needle):
        return [m for m in self.logs if needle in m]


@pytest.fixture
def h(tmp_path):
    return Harness(tmp_path)


# ---------------------------------------------------- the positive control

def test_all_gates_open_types_one_ping_and_logs_it(h):
    assert h.tick() == 1
    assert h.typed == [AUTO.KEEPWARM_PING]
    assert "\n" not in AUTO.KEEPWARM_PING            # one line, so Enter submits it
    assert h.w.kw_pings == 1
    assert h.logged("keep-warm ping 1/6 at 300k tokens (1h tier)")


def test_ping_is_not_repeated_while_the_first_has_not_been_logged(h):
    """The transcript only grows once the ping lands. If it never does (a wedged
    session, a lost keystroke) the next poll still sees a transcript that is quiet
    past the interval, and must not type again until a full interval has passed
    since the PING."""
    assert h.tick() == 1
    assert h.tick() == 1
    assert h.tick() == 1


# --------------------------------------------------- gates, one test each

def test_gate_disabled_never_pings(h):
    h.w.keepwarm = False
    assert h.tick() == 0


def test_gate_tui_not_ready_never_pings(h):
    h.w.tui_ready.clear()
    assert h.tick() == 0


@pytest.mark.parametrize("state", ["CLEARING", "NUDGED", "COOLDOWN"])
def test_gate_state_must_be_normal(h, state):
    h.w.state = getattr(h.w, state)
    assert h.tick() == 0


def test_gate_weekly_floor_owning_the_session_never_pings(h):
    h.w.wf_stage = "floored"
    assert h.tick() == 0


def test_gate_session_done_marker_never_pings(h):
    (h.cwd / AUTO.SESSION_DONE_MARKER).write_text("done\n")
    assert h.tick() == 0


def test_gate_transcript_quiet_must_reach_the_interval(h):
    h.quiet(INTERVAL - 60)
    assert h.tick() == 0
    assert h.logs == []                 # not-yet-due is silent, not a skip
    h.quiet(INTERVAL + 5)
    assert h.tick() == 1


def test_gate_min_tokens(h):
    h.write([], tokens=99_000)
    h.quiet()
    assert h.tick() == 0
    assert h.logged("keep-warm skipped: context is 99000 tokens")


def test_gate_min_tokens_is_inclusive_at_the_threshold(h):
    h.write([], tokens=100_000)
    h.quiet()
    assert h.tick() == 1


def test_gate_five_minute_tier_never_pings(h):
    h.write([], tier="5m")
    h.quiet()
    assert h.tick() == 0
    assert h.logged("cache tier is 5m")


def test_gate_unknown_tier_never_pings(h):
    h.write([], tier=None)
    h.quiet()
    assert h.tick() == 0
    assert h.logged("cache tier is unknown")


def test_gate_max_pings_per_idle_stretch(h):
    """Each ping is followed by its own reply and 55 quiet minutes. Without the cap
    this runs forever; with it the sixth ping is the last."""
    for n in range(1, 7):
        assert h.tick() == n
        h.write(assistant_rows([text_block("ok")]), mode="a")
        h.quiet(INTERVAL + 5)
        h.w.kw_ping_at = time.time() - INTERVAL - 10   # that much time has passed
    assert h.tick() == 6
    assert h.logged("cap reached (6/6 pings)")


def test_gate_paused_never_pings_and_says_so(h):
    h.w.paused = True
    assert h.tick() == 0
    assert h.logged("auto-checkpoint is paused")


def test_gate_context_at_soft_threshold_is_left_to_the_checkpoint_nudge(h):
    h.w.last_pct = 41.0
    assert h.tick() == 0


# ---- SAFETY: no dialog pending (read from the transcript, not the screen) ----

def test_dialog_gate_unanswered_tool_use_blocks_the_ping(h):
    """THE case. A pending permission prompt, AskUserQuestion menu or plan approval
    is, in the transcript, a tool_use whose tool_result has not arrived."""
    h.write(assistant_rows([thinking_block(), tool_use("toolu_A", "AskUserQuestion")]),
            mode="a")
    h.quiet()
    assert h.tick() == 0
    assert h.logged("a tool call has no result yet")


def test_dialog_gate_answered_tool_use_does_not_block(h):
    h.write(assistant_rows([thinking_block(), tool_use("toolu_A")]) +
            [tool_result("toolu_A")], mode="a")
    h.quiet()
    assert h.tick() == 1


def test_dialog_gate_one_of_two_parallel_calls_unanswered_blocks(h):
    h.write(assistant_rows([tool_use("toolu_A"), tool_use("toolu_B")]) +
            [tool_result("toolu_A")], mode="a")
    h.quiet()
    assert h.tick() == 0


def test_dialog_gate_only_the_last_assistant_message_counts(h):
    """An older call that never got a result (an interrupted tool) must not block
    pings for the rest of the session once the model has spoken again."""
    h.write(assistant_rows([tool_use("toolu_OLD")]) +
            assistant_rows([text_block("carrying on")]), mode="a")
    h.quiet()
    assert h.tick() == 1


def test_dialog_gate_fails_closed_when_the_transcript_cannot_be_read(tmp_path):
    assert AUTO.has_pending_tool_use(str(tmp_path / "missing.jsonl")) is True


def test_dialog_gate_fails_closed_with_no_assistant_message(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(json.dumps(typed_user_row("hi")) + "\n")
    assert AUTO.has_pending_tool_use(str(p)) is True


# ---- SAFETY: no unsent draft ----

def test_draft_gate_keystrokes_without_enter_block_the_ping(h):
    h.w.note_user_input(b"half a mess")
    assert h.tick() == 0
    assert h.logged("unsent keystrokes")


def test_draft_gate_cleared_by_an_enter_that_ends_the_input(h):
    h.w.note_user_input(b"half")
    h.w.note_user_input(b"done\r")
    assert h.tick() == 1


def test_draft_gate_keystrokes_after_the_last_enter_block(h):
    h.w.note_user_input(b"sent\rand then more")
    assert h.tick() == 0


def test_draft_gate_terminal_reports_are_not_keystrokes(h):
    """Focus and mouse reports arrive on stdin with nobody typing; counting them
    would leave a draft behind after every window switch."""
    h.w.note_user_input(b"\x1b[I\x1b[O\x1b[<64;10;5M\x1b[<0;10;5m")
    assert h.w.kw_draft is False and h.w.kw_user_at == 0.0
    assert h.tick() == 1


# --------------------------------------------------- idle-stretch resets

def _ping_and_reply(h):
    assert h.tick() == 1
    h.write(assistant_rows([text_block("ok")]), mode="a")      # the ping's own turn


def test_reset_on_a_user_keystroke(h):
    h.w.kw_pings, h.w.kw_ping_at = 3, time.time() - 10
    h.w.note_user_input(b"x\r")
    h.tick()
    assert h.w.kw_pings == 1            # reset to 0, then this poll's ping


def test_reset_on_growth_that_is_not_the_pings_own_turn(h):
    _ping_and_reply(h)
    assert h.w.kw_pings == 1
    h.w.kw_ping_at = time.time() - AUTO.KEEPWARM_OWN_TURN_S - 60   # long ago
    h.write(assistant_rows([text_block("the user came back")]), mode="a")
    h.tick()                            # sees growth outside the ping's window
    assert h.w.kw_pings == 0
    assert h.logged("idle stretch reset by transcript activity")


def test_ping_own_growth_does_not_reset(h):
    _ping_and_reply(h)
    h.tick()
    assert h.w.kw_pings == 1
    assert not h.logged("idle stretch reset")


def test_reset_on_a_tool_call_in_the_pings_turn(h):
    """A ping that makes the model DO something is not an idle stretch any more."""
    assert h.tick() == 1
    row = assistant_rows([tool_use("toolu_P")])[0]
    row["timestamp"] = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() + 5))
    h.write([row, tool_result("toolu_P")], mode="a")
    h.tick()
    assert h.w.kw_pings == 0
    assert h.logged("a tool call after the ping")


def test_reset_on_a_new_transcript(h):
    assert h.tick() == 1
    first = h.path
    second = h.sdir / "after-clear.jsonl"
    second.write_text(first.read_text())
    os.utime(first, (time.time() - QUIET - 100,) * 2)       # the older one
    os.utime(second, (time.time() - QUIET,) * 2)            # newest by mtime
    h.w.kw_ping_at = time.time() - INTERVAL - 10
    h.tick()
    assert h.logged("idle stretch reset by a new transcript")


def test_skips_are_logged_once_per_stretch_and_again_after_a_reset(h):
    h.write([], tokens=1000)
    h.quiet()
    for _ in range(4):
        h.tick()
    assert len(h.logged("keep-warm skipped")) == 1
    h.w.note_user_input(b"x\r")
    h.tick()
    assert len(h.logged("keep-warm skipped")) == 2


def test_a_poll_that_typed_a_say_message_does_not_also_ping(h):
    """run() must not type a ping behind a --say message on the same poll: that
    message's own turn is about to grow the transcript."""
    ticks, polls = [], []
    h.cfg.validate()                    # run() logs the resolved thresholds
    h.cfg.poll = 0
    h.w._keepwarm_tick = lambda: ticks.append(len(polls))

    def say():
        polls.append(1)
        if len(polls) >= 2:
            h.w.stop = True
        return len(polls) == 1          # typed a message on the first poll only

    h.w._deliver_say = say
    h.w.run()
    assert ticks == [2]                 # the first poll skipped the tick, the second ran it


# -------------------------------------- control file and the live switch

def test_control_file_round_trips_keepwarm(tmp_path):
    cwd = str(tmp_path)
    AUTO.write_control_file(cwd, {"keepwarm": False})
    assert AUTO.read_control_file(cwd) == {"keepwarm": False}
    assert "keepwarm=off" in (tmp_path / AUTO.AUTOCK_CONF).read_text()
    AUTO.write_control_file(cwd, {"keepwarm": True, "paused": True})
    assert AUTO.read_control_file(cwd) == {"keepwarm": True, "paused": True}
    assert "keepwarm=on" in (tmp_path / AUTO.AUTOCK_CONF).read_text()


def test_control_file_off_stops_pings_and_removal_restores_the_launch_value(h):
    conf = h.cwd / AUTO.AUTOCK_CONF
    conf.write_text("keepwarm=off\n")
    h.w._refresh_control()
    assert h.w.keepwarm is False
    assert h.tick() == 0
    assert h.logged("control update: keep-warm off")
    conf.unlink()
    h.w._refresh_control()
    assert h.w.keepwarm is True
    assert h.tick() == 1


def test_control_file_on_overrides_a_launch_that_was_off(tmp_path):
    h = Harness(tmp_path)
    h.cfg.keepwarm = False
    h.w.keepwarm = False
    (h.cwd / AUTO.AUTOCK_CONF).write_text("keepwarm=on\n")
    h.w._refresh_control()
    assert h.tick() == 1


def test_control_action_writes_the_switch_in_the_cwd(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    assert AUTO.control_command(["--keepwarm", "off"]) == 0
    assert AUTO.read_control_file(str(tmp_path)) == {"keepwarm": False}
    assert AUTO.control_command(["--keepwarm", "ON"]) == 0
    assert AUTO.read_control_file(str(tmp_path)) == {"keepwarm": True}
    assert "keep-warm ON" in capsys.readouterr().out


def test_control_action_rejects_anything_but_on_or_off(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    assert AUTO.control_command(["--keepwarm", "maybe"]) == 2
    assert AUTO.control_command(["--keepwarm"]) == 2
    assert not (tmp_path / AUTO.AUTOCK_CONF).exists()


def test_keepwarm_is_a_control_action_but_the_launch_flag_is_not():
    assert "--keepwarm" in AUTO.CONTROL_ACTIONS
    assert AUTO._find_control_action(["--dangerously-skip-permissions", "--keepwarm", "off"]) == 1
    assert AUTO._find_control_action(["--no-keepwarm"]) is None


def test_reset_drops_the_override_with_the_whole_control_file(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    AUTO.control_command(["--keepwarm", "off"])
    assert AUTO.control_command(["--reset"]) == 0
    assert AUTO.read_control_file(str(tmp_path)) == {}


# -------------------------------------------------- env and flag parsing

def test_defaults_are_on_55_minutes_6_pings_100k_tokens():
    cfg = AUTO.Config([])
    assert cfg.keepwarm is True
    assert cfg.kw_interval == 55 * 60.0
    assert cfg.kw_max == 6
    assert cfg.kw_min_tokens == 100_000


@pytest.mark.parametrize("value", ["0", "false", "off", "no", "OFF", ""])
def test_env_disables(monkeypatch, value):
    monkeypatch.setenv("CCAGE_AUTOCK_KEEPWARM", value)
    assert AUTO.Config([]).keepwarm is False


def test_env_truthy_values_keep_it_on(monkeypatch):
    monkeypatch.setenv("CCAGE_AUTOCK_KEEPWARM", "1")
    assert AUTO.Config([]).keepwarm is True


def test_no_keepwarm_flag_disables_and_is_consumed():
    cfg = AUTO.Config(["--no-keepwarm", "--model", "opus"])
    assert cfg.keepwarm is False
    assert cfg.claude_args == ["--model", "opus"]


@pytest.mark.parametrize("raw,minutes", [("0", 1), ("1", 1), ("30", 30),
                                         ("59", 59), ("120", 59), ("nonsense", 55)])
def test_interval_env_is_clamped_to_1_59_minutes(monkeypatch, raw, minutes):
    monkeypatch.setenv("CCAGE_AUTOCK_KEEPWARM_INTERVAL", raw)
    cfg = AUTO.Config([])
    cfg.validate()
    assert cfg.kw_interval == minutes * 60.0


@pytest.mark.parametrize("raw,cap", [("0", 1), ("1", 1), ("12", 12),
                                     ("24", 24), ("99", 24), ("nonsense", 6)])
def test_max_env_is_clamped_to_1_24(monkeypatch, raw, cap):
    monkeypatch.setenv("CCAGE_AUTOCK_KEEPWARM_MAX", raw)
    assert AUTO.Config([]).kw_max == cap


def test_clamped_settings_are_warned_about(monkeypatch):
    monkeypatch.setenv("CCAGE_AUTOCK_KEEPWARM_INTERVAL", "120")
    monkeypatch.setenv("CCAGE_AUTOCK_KEEPWARM_MAX", "99")
    warns = AUTO.Config([]).validate()
    assert any("KEEPWARM_INTERVAL" in w for w in warns)
    assert any("KEEPWARM_MAX" in w for w in warns)


def test_min_tokens_env(monkeypatch):
    monkeypatch.setenv("CCAGE_AUTOCK_KEEPWARM_MIN_TOKENS", "250000")
    assert AUTO.Config([]).kw_min_tokens == 250_000


def test_seconds_override_is_unclamped_and_test_only(monkeypatch):
    monkeypatch.setenv("CCAGE_AUTOCK_KEEPWARM_INTERVAL_S", "2")
    assert AUTO.Config([]).kw_interval == 2.0


# ------------------------------------------------- cache tier and the probe

def _tier_of(tmp_path, one_h, five_m):
    p = tmp_path / "t.jsonl"
    rows = []
    for a, b in zip(one_h, five_m):
        rows.append({"message": {"usage": {"cache_creation": {
            "ephemeral_1h_input_tokens": a, "ephemeral_5m_input_tokens": b}}}})
    p.write_text("".join(json.dumps(r) + "\n" for r in rows))
    return p


@pytest.mark.parametrize("one_h,five_m,tier", [
    ([100], [0], "1h"), ([100], [100], "1h"), ([100], [101], "5m"),
    ([0], [5], "5m"), ([0], [0], "unknown"), ([], [], "unknown")])
def test_cache_tier_rule(tmp_path, one_h, five_m, tier):
    assert AUTO.cache_tier(str(_tier_of(tmp_path, one_h, five_m))).value == tier


@pytest.mark.skipif(shutil.which("jq") is None, reason="jq not installed")
@pytest.mark.parametrize("one_h,five_m", [([100, 50], [0, 20]), ([10], [40]),
                                          ([0], [0]), ([30], [30])])
def test_cache_tier_agrees_with_the_shell_probe(tmp_path, one_h, five_m):
    """The Python tier is a port of keepwarm-calc.sh; where the two disagree the
    manual /keepwarm loop and the watcher would give opposite advice."""
    proj = tmp_path / "proj"
    proj.mkdir()
    sd = tmp_path / "cfg" / "projects" / AUTO.cwd_slug(str(proj))
    sd.mkdir(parents=True)
    t = _tier_of(tmp_path, one_h, five_m)
    shutil.copy(t, sd / "s.jsonl")
    out = subprocess.run(
        ["bash", str(ROOT / "share/skills/keepwarm/keepwarm-calc.sh"), "probe", str(proj)],
        env={**os.environ, "CLAUDE_CONFIG_DIR": str(tmp_path / "cfg")},
        capture_output=True, text=True, check=True).stdout
    shell_tier = [ln.split("=", 1)[1] for ln in out.splitlines() if ln.startswith("tier=")][0]
    assert AUTO.cache_tier(str(t)).value == shell_tier


# -------------------------------- interplay with the idle supervisor

def test_a_ping_turn_is_not_evidence_of_work_to_the_supervisor(h):
    """The supervisor resets its episode on a real tool call only. The ping is a
    typed user row and a text-only reply, so it must read as no work at all."""
    h.write([typed_user_row(AUTO.KEEPWARM_PING)] + assistant_rows([text_block("ok")]),
            mode="a")
    assert h.w._worked_since(str(h.path), time.time() - 10_000) is False
