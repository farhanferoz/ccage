"""Tests for the plan contract (lib/ccage_plan.py, share/hooks/plan_contract_guard.sh).

The guard is driven through the real hook script with a real hook payload, so the wrapper,
the payload shape and the exit code are all under test.
"""
import argparse
import json
import subprocess
from pathlib import Path

from lib import ccage_plan

ROOT = Path(__file__).resolve().parent.parent
HOOK = ROOT / "share" / "hooks" / "plan_contract_guard.sh"
QUOTE = "drop T2, the exchange feed is out of scope"
APPROVAL = f'  owner approved: "{QUOTE}" (T2)\n'


def plan(t1="[ ]", t1_check="`true`", t2=True):
    text = f"# Plan\n\n## Progress\n- {t1} T1 First — `a.py` — done when: {t1_check}\n"
    if t2:
        text += "- [ ] T2 Second — `b.py` — done when: `true`\n"
    return text


def transcript(tmp_path, *entries):
    p = tmp_path / "t.jsonl"
    p.write_text("\n".join(json.dumps(e) for e in entries))
    return p


def user(text):
    return {"type": "user", "message": {"content": [{"type": "text", "text": text}]}}


def tool_result(text):
    return {"type": "user", "message": {"content": [{"type": "tool_result", "content": text}]}}


def guard(tmp_path, old, new, transcript_path=None):
    """Write `old` to a plan, fire the hook for a Write of `new`, return (exit code, stderr)."""
    f = tmp_path / "plan.md"
    f.write_text(old)
    payload = {"tool_name": "Write", "tool_input": {"file_path": str(f), "content": new},
               "transcript_path": str(transcript_path) if transcript_path else None}
    r = subprocess.run(["bash", str(HOOK)], input=json.dumps(payload), capture_output=True,
                       text=True, check=False, env={"PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": str(tmp_path)})
    return r.returncode, r.stderr


def test_tick_denied_when_its_check_fails(tmp_path):
    code, err = guard(tmp_path, plan(t1_check="`false`"), plan("[x]", "`false`"))
    assert code == 2 and "TICK T1" in err and "check failed" in err


def test_tick_denied_without_a_check(tmp_path):
    old = plan().replace(" — done when: `true`", "", 1)
    code, err = guard(tmp_path, old, old.replace("[ ] T1", "[x] T1"))
    assert code == 2 and "no done-when command" in err


def test_tick_allowed_when_its_check_passes(tmp_path):
    assert guard(tmp_path, plan(), plan("[x]"))[0] == 0


def test_drop_denied_without_an_owner_quote(tmp_path):
    code, err = guard(tmp_path, plan(), plan(t2=False), transcript(tmp_path, user("hello")))
    assert code == 2 and "T2 dropped" in err


def test_drop_allowed_with_a_quote_from_a_user_turn(tmp_path):
    t = transcript(tmp_path, user(f"ok: {QUOTE}, go ahead"))
    assert guard(tmp_path, plan(), plan(t2=False) + APPROVAL, t)[0] == 0


def test_a_quote_found_only_in_a_tool_result_is_denied(tmp_path):
    t = transcript(tmp_path, user("hello"), tool_result(QUOTE))
    assert guard(tmp_path, plan(), plan(t2=False) + APPROVAL, t)[0] == 2


def test_plan_report_exits_nonzero_on_a_regressed_item(tmp_path, capsys):
    f = tmp_path / "plan.md"
    f.write_text(plan("[x]", "`false`"))
    assert ccage_plan.plan_report(f, run=True) == 1
    assert "REGRESSED" in capsys.readouterr().out


def test_review_saves_the_verdict_and_exits_by_it(tmp_path, monkeypatch):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    f = tmp_path / "plan.md"
    f.write_text(plan())
    out = {"structured": {"verdict": "NEEDS_WORK", "findings": [
               {"severity": "high", "file": "a.py", "line": 3, "issue": "stub", "evidence": "pass"}]},
           "model": "claude-opus-5-5", "effort_requested": "high", "wall_clock_s": 4.2,
           "cli_version": "2.1", "usage": {k: 1 for k in (
               "input_tokens", "output_tokens", "cache_creation_input_tokens",
               "cache_read_input_tokens", "thinking_tokens")}}
    seen = {}
    monkeypatch.setattr(ccage_plan, "call_agentcall", lambda *a: seen.update(prompt=a[0]) or out)
    monkeypatch.setattr(ccage_plan, "gather_evidence", lambda *a: "EVIDENCE-BLOCK")
    args = argparse.Namespace(plan=str(f), id="T1", diff="HEAD", files=[], model="opus", effort="high")
    assert ccage_plan.review(args) == 1
    saved = next((tmp_path / "reviews").glob("T1-*.md")).read_text()
    assert "NEEDS_WORK" in saved and "a.py:3" in saved and "claude-opus-5-5" in saved
    assert "EVIDENCE-BLOCK" in seen["prompt"] and "{{" not in seen["prompt"]
