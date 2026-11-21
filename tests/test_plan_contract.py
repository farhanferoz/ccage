"""Tests for the plan contract (lib/ccage_plan.py, share/hooks/plan_contract_guard.sh).

The guard is driven through the real hook script with a real hook payload, so the wrapper,
the payload shape and the exit code are all under test.
"""
import argparse
import json
import os
import shutil
import subprocess
import time
from pathlib import Path


from lib import ccage_plan

ROOT = Path(__file__).resolve().parent.parent
HOOK = ROOT / "share" / "hooks" / "plan_contract_guard.sh"
FIXTURE = ROOT / "tests" / "fixtures" / "plan_staleness"
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


def queued(text, kind="human"):
    """A message that arrived while the session was working (transcript shape of 2026-11-07)."""
    return {"type": "attachment", "attachment": {"type": "queued_command", "prompt": text,
                                                 "origin": {"kind": kind}}}


def guard(tmp_path, old, new, transcript_path=None, env=None, rel="plan.md", edit=None):
    """Write `old` to a plan (None: the file and its dir do not exist yet), fire the hook for a
    Write of `new` (or an Edit of `edit` = (old_string, new_string)), return (exit code, stderr)."""
    f = tmp_path / rel
    if old is not None:
        f.write_text(old)
    tool_input = ({"file_path": str(f), "old_string": edit[0], "new_string": edit[1]} if edit
                  else {"file_path": str(f), "content": new})
    payload = {"tool_name": "Edit" if edit else "Write", "tool_input": tool_input,
               "transcript_path": str(transcript_path) if transcript_path else None}
    r = subprocess.run(["bash", str(HOOK)], input=json.dumps(payload), capture_output=True,
                       text=True, check=False, env={"PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": str(tmp_path), **(env or {})})
    return r.returncode, r.stderr


def test_tick_denied_when_its_check_fails(tmp_path):
    code, err = guard(tmp_path, plan(t1_check="`false`"), plan("[x]", "`false`"))
    assert code == 2 and "TICK T1" in err and "check failed" in err
    # the log says why, not only how many
    assert "DENY" in (log := (tmp_path / "plan_contract_guard.log").read_text()) and "TICK T1" in log
    # a new plan written into a directory that does not exist yet is judged, not let through
    code, err = guard(tmp_path, None, plan("[x]", "`false`"), rel="new/dir/plan.md")
    assert code == 2 and "TICK T1" in err
    assert guard(tmp_path, None, plan("[x]"), rel="new2/dir/plan.md")[0] == 0
    # an Edit written with straight quotes against curly ones (the tool applies it) is judged
    curly = plan(t1_check="`false`").replace("First", "The owner’s “first”")
    code, err = guard(tmp_path, curly, None, edit=("- [ ] T1 The owner's \"first\"", "- [x] T1 The owner's \"first\""))
    assert code == 2 and "TICK T1" in err


def test_tick_denied_without_a_check(tmp_path):
    old = plan().replace(" — done when: `true`", "", 1)
    code, err = guard(tmp_path, old, old.replace("[ ] T1", "[x] T1"))
    assert code == 2 and "no done-when command" in err
    # the shape refused on 2026-11-07: the check sits in the item's own lines under a check
    # described in words (or in those words); moved unchanged onto the checkbox line and ticked,
    # it needs no approval when the committed plan has it there, and a check written there since
    # the commit does. "Step" is shared, so these items are keyed by title.
    prose = ("## Progress\n- [ ] Step 2 referee fixed (owner yes). done when: the referee at commit\n"
             "  abc (`submit --referee`) passes, read from its log:\n  `{cmd}`\n  evidence: job 1\n"
             "- [ ] Step 5 ledger fixed (abc1). done when: `{cmd}` passes and goes red\n"
             "  evidence: `echo ok` passed\n")
    moved = ("## Progress\n- [x] Step 2 referee fixed (owner yes) — done when: `{cmd}`\n"
             "  The check: the referee at commit abc passes.\n  evidence: job 1\n"
             "- [x] Step 5 ledger fixed (abc1) — done when: `{cmd}`\n  It passes and goes red.\n")
    (tmp_path / "plan.md").write_text(prose.format(cmd="true"))
    for git in (["init", "-q"], ["add", "plan.md"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "p"]):
        subprocess.run(["git", "-C", str(tmp_path), *git], check=True)
    assert guard(tmp_path, prose.format(cmd="true"), moved.format(cmd="true"))[0] == 0
    assert "MOVE" in (tmp_path / "plan_contract_guard.log").read_text()
    code, err = guard(tmp_path, prose.format(cmd="echo hi"), moved.format(cmd="echo hi"))
    assert code == 2 and "Step 2 referee fixed (owner yes) changed" in err and "new check" in err
    # a committed span that is not the check moves nowhere: one beside the words, one in evidence
    other = moved.format(cmd="true").replace("`true`", "`submit --referee`", 1).replace("`true`", "`echo ok`", 1)
    code, err = guard(tmp_path, prose.format(cmd="true"), other)
    assert code == 2 and "Step 2 referee fixed (owner yes) changed" in err and "Step 5 ledger fixed (abc1) changed" in err


def test_tick_allowed_when_its_check_passes(tmp_path):
    assert guard(tmp_path, plan(), plan("[x]"))[0] == 0
    # evidence beside the write set is not a change; evidence in the title is, and the
    # refusal says where evidence goes instead
    noted = plan("[x]").replace("`a.py` —", "`a.py` (merged abc123) —")
    assert guard(tmp_path, plan(), noted)[0] == 0
    code, err = guard(tmp_path, plan(), plan("[x]").replace("First", "First (merged abc123)"))
    assert code == 2 and "T1 changed" in err and "indented line" in err
    # a check described in words is free, but a write set after it is still compared
    words = "## Progress\n- [ ] A1 T. done when: x passes — `a.py`\n"
    assert guard(tmp_path, words, words.replace("x passes", "y passes"))[0] == 0
    assert guard(tmp_path, words, words.replace("a.py", "b.py"))[0] == 2


def test_drop_denied_without_an_owner_quote(tmp_path):
    code, err = guard(tmp_path, plan(), plan(t2=False), transcript(tmp_path, user("hello")))
    assert code == 2 and "T2 dropped" in err
    # a transcript path that does not exist is "unavailable", never an internal error that allows
    code, err = guard(tmp_path, plan(), plan(t2=False) + APPROVAL, tmp_path / "gone.jsonl")
    assert code == 2 and "unavailable" in err


def test_drop_allowed_with_a_quote_from_a_user_turn(tmp_path):
    t = transcript(tmp_path, user(f"ok: {QUOTE}, go ahead"))
    assert guard(tmp_path, plan(), plan(t2=False) + APPROVAL, t)[0] == 0
    # a later quoted word on the approval line does not void the quote
    later = f'  owner approved: "{QUOTE}" (T2, and they said "do it")\n'
    assert guard(tmp_path, plan(), plan(t2=False) + later, t)[0] == 0
    # a message the owner typed while the session was working counts too
    t = transcript(tmp_path, user("hello"), queued(f"ok: {QUOTE}, go ahead"))
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
    # an ID with "/" (a title-keyed item) is saved inside reviews/, not lost after the call
    f.write_text("## Progress\n- [ ] src/x.py: fix — done when: `true`\n")
    assert ccage_plan.review(argparse.Namespace(**{**vars(args), "id": "src/x.py:"})) == 1
    assert next((tmp_path / "reviews").glob("src_x.py-*.md"))
    # a review that could not be made exits 2, never 1 (NEEDS_WORK)
    assert ccage_plan.main(["review", str(tmp_path / "missing.md"), "T1"]) == 2


def test_only_items_with_a_shared_first_word_are_keyed_by_title(tmp_path):
    old = "## Progress\n- [ ] Step 2 — wire it\n- [ ] Step 5 — ship it\n- [ ] A2 Second — x\n"
    code, err = guard(tmp_path, old, old.replace("[ ] Step 2", "[x] Step 2"))
    assert code == 2 and "TICK Step 2" in err and "no done-when" in err
    t = transcript(tmp_path, user(f"ok: {QUOTE}, go ahead"))
    dropped = old.replace("- [ ] A2 Second — x\n", "") + f'A2 owner approved: "{QUOTE}"\n'
    assert guard(tmp_path, old, dropped, t)[0] == 0
    # items sharing their whole title are keyed by line: ticking the first is still checked
    twins = "## Progress\n- [ ] Tests — done when: `false`\n- [ ] Tests — done when: `true`\n"
    code, err = guard(tmp_path, twins, twins.replace("[ ] Tests", "[x] Tests", 1))
    assert code == 2 and "check failed" in err


def test_a_quote_found_only_in_a_teammate_message_is_denied(tmp_path):
    # each entry alone would carry the quote; the owner typed none of them
    t = transcript(tmp_path, user("hello"), user(f'<teammate-message teammate_id="x">{QUOTE}</teammate-message>'),
                   {**user(QUOTE), "origin": {"kind": "task-notification"}}, queued(QUOTE, "task-notification"),
                   queued(7),  # a malformed prompt is skipped, never an internal error that allows
                   user(f"[supervisor] This session has been idle. {QUOTE}"),
                   user(f"Resume the task from RESUME.md — {QUOTE}"),
                   {**user(f"This session is being continued. {QUOTE}"), "isCompactSummary": True})
    assert guard(tmp_path, plan(), plan(t2=False) + APPROVAL, t)[0] == 2


def test_guard_limits_come_from_the_environment(tmp_path):
    """A cap is chosen by CCAGE_PLAN_<NAME>, the default unchanged: a failing check prints its
    last 20 lines, or the last 1 when CCAGE_PLAN_TAIL_LINES=1."""
    check = "`seq 11 13; false`"
    code, err = guard(tmp_path, plan(t1_check=check), plan("[x]", check))
    assert code == 2 and "last 20 lines:\n11\n12\n13" in err
    code, err = guard(tmp_path, plan(t1_check=check), plan("[x]", check), env={"CCAGE_PLAN_TAIL_LINES": "1"})
    assert code == 2 and "last 1 lines:\n13" in err and "\n12\n" not in err


def test_a_bad_guard_setting_is_ignored_and_logged(tmp_path):
    """A hook never fails over a setting: a value that is not a non-negative number leaves the
    default in force and names the variable in the guard log (the budget one used to make the
    guard allow every tick)."""
    check = "`false`"
    # `inf` parses as a number but has no integer value; it must fall back too, not crash.
    for var, bad in (("CCAGE_PLAN_TAIL_LINES", "lots"), ("CCAGE_PLAN_TAIL_LINES", "inf"),
                     ("CCAGE_PLAN_GUARD_BUDGET_S", "lots")):
        code, err = guard(tmp_path, plan(t1_check=check), plan("[x]", check), env={var: bad})
        assert code == 2 and "check failed" in err and "last 20 lines" in err
        assert f"IGNORED-setting {var}={bad!r}" in (tmp_path / "plan_contract_guard.log").read_text()


def test_ticks_beyond_the_time_budget_are_denied_unchecked(tmp_path):
    code, err = guard(tmp_path, plan(), plan("[x]"), env={"CCAGE_PLAN_GUARD_BUDGET_S": "0"})
    assert code == 2 and "time budget" in err
    # a check that times out takes its whole pipeline down, not only bash
    passed, tail = ccage_plan.run_check("sleep 37.25 | cat", tmp_path, timeout=0.5)
    assert not passed and "timed out" in tail
    assert subprocess.run(["pgrep", "-f", "sleep 37.25"], capture_output=True, check=False).returncode == 1


# ---- plans RESUME lists, and the annotation grammar (plan-staleness fix, part D) ----------------
# Fixture: the ten plan documents listed in RESUME on 21 Nov 2026, as they were before they were
# reconciled (tests/fixtures/plan_staleness). Only one of them has a `## Progress` heading.

CI_PLAN = "plan_ci_green_and_test_pruning_2026-11-19.md"
PRIORS = "design_rollout_priors_2026-11-16.md"
P2 = "P2 Owner sees the audit's totals"
M1 = "M1 design the mean prior's build"


def project(tmp_path):
    """The fixture project in tmp_path/proj as a git repository; returns (path, short hash of its commit)."""
    proj = tmp_path / "proj"
    shutil.copytree(FIXTURE, proj)
    for git in (["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "fixture"]):
        subprocess.run(["git", "-C", str(proj), *git], check=True)
    head = subprocess.run(["git", "-C", str(proj), "rev-parse", "--short=9", "HEAD"], capture_output=True,
                          text=True, check=True).stdout.strip()
    return proj, head


def tick(tmp_path, proj, doc, marker, note=""):
    """Tick the item holding `marker` in a fixture document, appending `note`; (exit code, stderr)."""
    line = next(ln for ln in (proj / "docs" / doc).read_text().splitlines() if marker in ln)
    new = line.replace("- [ ]", "- [x]", 1) + (f" {note}" if note else "")
    return guard(tmp_path, None, None, rel=f"proj/docs/{doc}", edit=(line, new),
                 env={"CLAUDE_PROJECT_DIR": str(proj)})


def test_a_listed_plan_without_a_progress_heading_is_guarded(tmp_path):
    proj, _ = project(tmp_path)
    # listed under RESUME's ### Plan, no `## Progress`: a tick with no check and no evidence is refused
    code, err = tick(tmp_path, proj, CI_PLAN, P2)
    assert code == 2 and "TICK P2" in err and "no done-when" in err and "DONE <date>: <evidence>" in err
    assert "ALLOW" not in (tmp_path / "plan_contract_guard.log").read_text()
    # a drop needs the owner's words, as in a Progress section
    old = (proj / "docs" / CI_PLAN).read_text()
    code, err = guard(tmp_path, None, None, rel=f"proj/docs/{CI_PLAN}", env={"CLAUDE_PROJECT_DIR": str(proj)},
                      edit=(next(ln for ln in old.splitlines() if P2 in ln) + "\n", ""))
    assert code == 2 and "P2 dropped" in err
    # the same text in a document RESUME does not list is left alone, and the log says why
    (proj / "docs" / "unlisted.md").write_text(old)
    assert guard(tmp_path, None, None, rel="proj/docs/unlisted.md", env={"CLAUDE_PROJECT_DIR": str(proj)},
                 edit=(next(ln for ln in old.splitlines() if P2 in ln), "- [x] P2 done"))[0] == 0
    assert "SKIP" in (tmp_path / "plan_contract_guard.log").read_text()


def test_a_done_annotation_needs_evidence_that_can_be_verified(tmp_path):
    proj, head = project(tmp_path)
    for evidence in (f"merged {head}", "see docs/work_list_2026-11-19.md", "D385 settles it", "slurm 8697908 ran it"):
        code, err = tick(tmp_path, proj, CI_PLAN, P2, f"DONE 2026-11-21: {evidence}")
        assert code == 0, (evidence, err)
    assert "TICK-EVIDENCE" in (tmp_path / "plan_contract_guard.log").read_text()
    # invented: a hash no commit has, a path that is absent, an unknown decision, a job nobody recorded, prose only
    for evidence in ("merged deadbeef1", "see docs/nope.md", "D999 settles it", "slurm 1234567 ran it",
                     "finished yesterday"):
        code, err = tick(tmp_path, proj, CI_PLAN, P2, f"DONE 2026-11-21: {evidence}")
        assert code == 2 and "DONE annotation without evidence that can be verified" in err, evidence
    # the words that make a number a job number are a setting; a malformed one is ignored and logged
    def slurm(env):
        line = next(ln for ln in (proj / "docs" / CI_PLAN).read_text().splitlines() if P2 in ln)
        return guard(tmp_path, None, None, rel=f"proj/docs/{CI_PLAN}", edit=(line, line.replace("- [ ]", "- [x]") + " DONE 2026-11-21: slurm 8697908 ran it"),
                     env={"CLAUDE_PROJECT_DIR": str(proj), **env})[0]
    assert slurm({"CCAGE_PLAN_JOB_WORDS": "job"}) == 2
    assert slurm({"CCAGE_PLAN_JOB_WORDS": "slurm"}) == 0
    assert slurm({"CCAGE_PLAN_JOB_WORDS": "a b(("}) == 0
    assert "IGNORED-setting CCAGE_PLAN_JOB_WORDS" in (tmp_path / "plan_contract_guard.log").read_text()


def test_a_superseded_annotation_needs_the_owners_words_from_that_decision(tmp_path):
    proj, _ = project(tmp_path)
    said = "THE TRAINING-SIDE FIX (D335's mean prior) IS CLOSED"
    assert tick(tmp_path, proj, PRIORS, M1, f"SUPERSEDED by D341 (2026-11-17): '{said}'")[0] == 0
    for note, why in (("SUPERSEDED by D341 (2026-11-17): 'THE FIX WAS NEVER NEEDED, SAYS THE OWNER'", "verbatim"),
                      (f"SUPERSEDED by D999 (2026-11-17): '{said}'", "no entry D999"),
                      ("SUPERSEDED by D341 (2026-11-17): 'agreed'", "20+ characters")):
        code, err = tick(tmp_path, proj, PRIORS, M1, note)
        assert code == 2 and "TICK M1" in err and why in err, (note, err)


def test_an_annotation_is_not_a_change_of_the_item(tmp_path):
    proj, head = project(tmp_path)
    # backticks and dashes inside an annotation are not a new write set or title: no approval needed
    note = "(open 2026-11-21: `a.py` still to do — blocked on the owner)"
    line = next(ln for ln in (proj / "docs" / CI_PLAN).read_text().splitlines() if P2 in ln)
    code, err = guard(tmp_path, None, None, rel=f"proj/docs/{CI_PLAN}", env={"CLAUDE_PROJECT_DIR": str(proj)},
                      edit=(line, f"{line} {note}"))
    assert code == 0, err
    # a failing check still refuses the tick, whatever the evidence says
    doc = proj / "docs" / "checked.md"
    doc.write_text("- [ ] C1 Run it — done when: `false`\n")
    resume = proj / "RESUME.md"
    resume.write_text(resume.read_text().replace("### Reference docs", "- `docs/checked.md`\n\n### Reference docs"))
    code, err = guard(tmp_path, None, None, rel="proj/docs/checked.md", env={"CLAUDE_PROJECT_DIR": str(proj)},
                      edit=("- [ ] C1 Run it — done when: `false`", f"- [x] C1 Run it DONE 2026-11-21: merged {head} — done when: `false`"))
    assert code == 2 and "its check failed" in err


# ---- plan-report --stale (plan-staleness fix, part B) -------------------------------------------

def stale(tmp_path, proj, *flags, env=None):
    """`ccage plan-report --stale` on a project; its stdout lines."""
    cfg = tmp_path / "cfg"
    cfg.mkdir(exist_ok=True)
    r = subprocess.run(["python3", str(ROOT / "lib" / "ccage_plan.py"), "plan-report", "--stale", "--project", str(proj), *flags],
                       capture_output=True, text=True, check=False,
                       env={"PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": str(cfg), **(env or {})})
    assert r.returncode == 0, r.stderr
    return r.stdout.splitlines()


def test_stale_report_names_what_the_disk_and_the_rulings_overtook(tmp_path):
    proj, _ = project(tmp_path)
    audit = proj / "notes/design/project_admin/ci_lint_checks/test_audit_part1_2026-11-19.csv"
    audit.parent.mkdir(parents=True)
    audit.write_text("file,verdict\n")
    out = "\n".join(stale(tmp_path, proj, "--no-run"))
    # an open item whose done-when names a file that now exists
    assert "P1 in plan_ci_green_and_test_pruning_2026-11-19.md: its done-when names test_audit_part1_2026-11-19.csv, which now exists" in out
    # two open items cite decisions that D385 supersedes (D320, D368); an item citing D385 itself is not named
    assert "W1 in work_list_2026-11-19.md cites D368, which D385 supersedes" in out
    assert "4. in plan_paper_runs_after_state_following_trial_2026-11-17.md cites D320, which D385 supersedes" in out
    # a finished document, and the RESUME line that says it was not started
    assert "plan_gs32_input_following_sizes_2026-11-16.md has no open item (5 done): finished" in out
    assert "says not started; 5 of its 5 items are ticked" in out
    # the lines are capped, the last one saying how many more; the open check was not run
    capped = stale(tmp_path, proj, "--no-run", env={"CCAGE_PLAN_REPORT_MAX_LINES": "2"})
    assert len(capped) == 2 and capped[1] == "(+4 more)"
    # an item that cites the superseding decision as well is not stale
    doc = proj / "docs" / "work_list_2026-11-19.md"
    doc.write_text(doc.read_text().replace("W1 J1 (D368)", "W1 J1 (D368, amended by D385)"))
    assert "W1 in work_list_2026-11-19.md" not in "\n".join(stale(tmp_path, proj, "--no-run"))


def test_stale_report_runs_checks_only_when_asked_and_is_silent_when_clean(tmp_path):
    proj, _ = project(tmp_path)
    (proj / "docs" / "extra.md").write_text("- [ ] E1 passes already — done when: `true`\n- [ ] E2 does not — done when: `false`\n")
    resume = proj / "RESUME.md"
    resume.write_text(resume.read_text().replace("### Reference docs", "- `docs/extra.md` — extra items.\n\n### Reference docs"))
    assert not [ln for ln in stale(tmp_path, proj, "--no-run") if "extra.md" in ln]
    lines = [ln for ln in stale(tmp_path, proj) if "extra.md" in ln]
    assert len(lines) == 1 and lines[0].startswith("E1 in extra.md: its check now passes (`true`)")
    # a project with nothing to say prints nothing at all
    clean = tmp_path / "clean"
    clean.mkdir()
    (clean / "p.md").write_text("- [ ] A1 open — done when: `false`\n")
    (clean / "RESUME.md").write_text("### Plan\n- p.md — in progress\n")
    assert stale(tmp_path, clean) == []


def test_stale_report_flags_a_plan_untouched_while_the_project_moved_on(tmp_path):
    proj, _ = project(tmp_path)
    resume = proj / "RESUME.md"
    resume.write_text(resume.read_text().replace("variance parts; waits for go.", "variance parts; COMPLETE."))
    old = time.time() - 30 * 86400
    for name in ("plan_variance_parts_and_state_dependence_2026-11-17.md", "plan_gs32_input_following_sizes_2026-11-16.md"):
        os.utime(proj / "docs" / name, (old, old))
    out = "\n".join(stale(tmp_path, proj, "--no-run"))
    assert "plan_variance_parts_and_state_dependence_2026-11-17.md has not changed for 30 days" in out and "its 2 open items" in out
    assert not [ln for ln in out.splitlines() if "gs32" in ln and "has not changed" in ln]    # a finished document is finished, not stale
    assert "says it is done or complete; 2 of its 4 items are open" in out
    # the age is a setting
    assert "has not changed" not in "\n".join(stale(tmp_path, proj, "--no-run", env={"CCAGE_PLAN_STALE_DAYS": "60"}))
