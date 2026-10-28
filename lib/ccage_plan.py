"""Plan contract: a plan item is done when its check passes, not when it is ticked.

One module behind three entry points, so the rules cannot drift apart:

  guard        PreToolUse hook body (share/hooks/plan_contract_guard.sh). Reads the hook
               payload on stdin; exit 2 blocks the write and stderr is fed back to the model.
  plan-report  `ccage plan-report <plan.md> [--no-run]`: every Progress item, its check, and
               the result of running that check now.
  review       `ccage review <plan.md> <ID> ...`: an independent model review of one item.

Plan format (backward compatible with plans that carry no check): a `## Progress` section of
checkbox lines

    - [ ] ID Title — `path` — done when: `command`

The trailing ` — done when: `command`` is optional. A command runs under `bash -c` in the git
root of the plan file and passes on exit 0.

Dependencies: standard library only. The review calls agentcall through its Python API in an
interpreter that has it installed (see `call_agentcall`).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

CHECK_TIMEOUT_S = 120
TAIL_LINES = 20
MIN_QUOTE_CHARS = 20
HEADING_PROGRESS = re.compile(r"^##\s+Progress\s*$", re.MULTILINE)
ITEM = re.compile(r"^\s*[-*]\s+\[([ xX])\]\s+(.*?)\s*$")
DONE_WHEN = re.compile(r"\s+—\s+done when:\s+`(.+)`\s*$")
APPROVED = re.compile(r'owner approved:\s*"(.+)"')
# A PreToolUse command hook that outlives its timeout (600 s default) does not block the
# call, so a guard call stops running checks after this many seconds and denies the rest.
GUARD_BUDGET_S = 480
# Entries the harness records as user turns although the owner did not type them: other
# sessions and teammates, task notifications, command output, hook feedback, ccage-auto's
# own nudges. A quote found only in one of these is not the owner's approval.
NOT_OWNER_PREFIXES = ("<system-reminder>", "<teammate-message", "Another Claude session sent a message",
                      "<local-command", "<command-name>", "[SYSTEM NOTIFICATION", "Stop hook feedback",
                      "[auto-checkpoint]")
REVIEW_TIMEOUT_S = 900
DIFF_CAP_CHARS = 200_000
SECTION_CAP_CHARS = 6000


@dataclass(frozen=True)
class Item:
    id: str
    checked: bool
    rest: str                 # everything after the checkbox, whitespace-collapsed
    done_when: str | None


def has_progress(text: str) -> bool:
    return bool(HEADING_PROGRESS.search(text))


def _rests(text: str) -> list[str]:
    inside, out = False, []
    for line in text.splitlines():
        if HEADING_PROGRESS.match(line):
            inside = True
            continue
        if inside and re.match(r"^#{1,2}\s", line):
            inside = False
        m = ITEM.match(line) if inside else None
        if m and m.group(2).strip():
            out.append(" ".join(m.group(2).split()))
    return out


def colliding_words(*texts: str) -> set[str]:
    """First words shared by two items of one text ("Step" for "Step 2", "Step 5")."""
    out: set[str] = set()
    for t in texts:
        firsts = [r.split()[0] for r in _rests(t)]
        out |= {w for w in firsts if firsts.count(w) > 1}
    return out


def parse_progress(text: str, colliding: set[str] | None = None) -> dict[str, Item]:
    """Items of the `## Progress` section in file order, keyed by first word (ID), or by the
    text before the first " — " (the title) when the first word collides with another item's."""
    colliding = colliding_words(text) if colliding is None else colliding
    items: dict[str, Item] = {}
    inside = False
    for line in text.splitlines():
        if HEADING_PROGRESS.match(line):
            inside = True
            continue
        if inside and re.match(r"^#{1,2}\s", line):
            inside = False
        m = ITEM.match(line) if inside else None
        if not m:
            continue
        rest = " ".join(m.group(2).split())
        if not rest:
            continue
        dw = DONE_WHEN.search(rest)
        item_id = rest.split(" — ")[0] if rest.split()[0] in colliding else rest.split()[0]
        items[item_id] = Item(item_id, m.group(1) in "xX", rest, dw.group(1) if dw else None)
    return items


def git_root(path: Path) -> Path:
    try:
        out = subprocess.run(["git", "-C", str(path.parent), "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=10, check=True)
        return Path(out.stdout.strip())
    except (subprocess.SubprocessError, OSError):
        return path.parent


def run_check(cmd: str, cwd: Path, timeout: float = CHECK_TIMEOUT_S) -> tuple[bool, str]:
    """Run a done-when command; (passed, last 20 lines of its output)."""
    try:
        r = subprocess.run(["bash", "-c", cmd], cwd=cwd, capture_output=True, text=True,
                           timeout=timeout, stdin=subprocess.DEVNULL, check=False)
    except subprocess.TimeoutExpired:
        return False, f"timed out after {timeout:g} s"
    out = (r.stdout + r.stderr).splitlines()[-TAIL_LINES:]
    return r.returncode == 0, "\n".join(out)


# ---- guard ----------------------------------------------------------------

def user_texts(transcript: Path) -> list[str]:
    """Text the owner typed: user turns only, never tool results, meta or assistant text."""
    texts: list[str] = []
    for line in transcript.read_text(errors="replace").splitlines():
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get("type") != "user" or d.get("isMeta") or (d.get("origin") or {}).get("kind") not in (None, "human"):
            continue
        content = (d.get("message") or {}).get("content")
        if isinstance(content, str):
            texts.append(content)
        elif isinstance(content, list):
            texts += [b.get("text", "") for b in content
                      if isinstance(b, dict) and b.get("type") == "text"]
    return [t for t in texts if not t.lstrip().startswith(NOT_OWNER_PREFIXES)]


def new_text(tool: str, tool_input: dict, old: str) -> str | None:
    """The file's text after the tool call, or None when it cannot be computed."""
    if tool == "Write":
        return tool_input.get("content")
    edits = tool_input.get("edits") if tool == "MultiEdit" else [tool_input]
    text = old
    for e in edits or []:
        before, after = e.get("old_string"), e.get("new_string")
        if before is None or after is None or before not in text:
            return None            # the tool call itself will fail; nothing to judge
        text = text.replace(before, after) if e.get("replace_all") else text.replace(before, after, 1)
    return text


def approved_quotes(text: str, item_id: str) -> list[str]:
    word = re.compile(r"(?<!\w)" + re.escape(item_id) + r"(?!\w)")
    return [m.group(1) for line in text.splitlines() if word.search(line)
            for m in [APPROVED.search(line)] if m]


def violations(old: str, new: str, plan: Path, transcript: Path | None) -> list[str]:
    shared = colliding_words(old, new)
    before, after = parse_progress(old, shared), parse_progress(new, shared)
    out: list[str] = []
    root = git_root(plan)
    deadline = time.monotonic() + float(os.environ.get("CCAGE_PLAN_GUARD_BUDGET_S", GUARD_BUDGET_S))
    for item_id, item in after.items():
        was = before.get(item_id)
        if not item.checked or (was and was.checked):
            continue
        cmd = (was or item).done_when
        if not cmd:
            out.append(f"TICK {item_id}: no done-when command. An item is ticked only when its "
                       "check passes; add `— done when: `<command>`` through an approved plan "
                       "change first.")
            continue
        left = deadline - time.monotonic()
        if left <= 0:
            out.append(f"TICK {item_id}: not checked: time budget of one guard call is spent. "
                       "Tick fewer items per edit.")
            continue
        passed, tail = run_check(cmd, root, min(CHECK_TIMEOUT_S, left))
        if not passed:
            out.append(f"TICK {item_id}: its check failed, so it stays open. Check: {cmd}\n"
                       f"last {TAIL_LINES} lines:\n{tail}")
    changed = [i for i, was in before.items()
               if i not in after or after[i].rest != was.rest]
    if changed:
        heard = user_texts(transcript) if transcript else None
        for item_id in changed:
            what = "dropped" if item_id not in after else "changed (ID, title, write set or done-when)"
            quotes = [q for q in approved_quotes(new, item_id) if len(q) >= MIN_QUOTE_CHARS]
            if heard is None:
                out.append(f"{item_id} {what}: the session transcript is unavailable, so the "
                           "owner's approval cannot be checked.")
            elif not any(q in t for q in quotes for t in heard):
                out.append(f"{item_id} {what} without the owner's words. Ask the owner; then put "
                           f'a line `owner approved: "<their words, 20+ characters>"` naming {item_id} '
                           "in the plan, quoting their message verbatim.")
    return out


def log(msg: str) -> None:
    try:
        path = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
        with open(path / "plan_contract_guard.log", "a") as f:
            f.write(f"{dt.datetime.now(dt.UTC).isoformat(timespec='seconds')} {msg}\n")
    except OSError:
        pass


def guard(stdin_text: str) -> int:
    try:
        payload = json.loads(stdin_text)
        tool, tin = payload.get("tool_name"), payload.get("tool_input") or {}
        path = Path(tin.get("file_path") or "")
        if tool not in ("Write", "Edit", "MultiEdit") or path.suffix.lower() != ".md":
            return 0
        old = path.read_text() if path.is_file() else ""
        new = new_text(tool, tin, old)
        if new is None or not (has_progress(old) or has_progress(new)):
            return 0
        tp = payload.get("transcript_path")
        found = violations(old, new, path, Path(tp) if tp else None)
    except Exception as exc:  # noqa: BLE001 -- a broken guard must not wedge sessions
        log(f"ERROR-allow {type(exc).__name__}: {exc}")
        return 0
    if found:
        log(f"DENY {path} {len(found)} violation(s)")
        print("Plan contract: this edit to the Progress list is refused.\n\n" + "\n\n".join(found),
              file=sys.stderr)
        return 2
    log(f"ALLOW {path}")
    return 0


# ---- plan-report ----------------------------------------------------------

def plan_report(plan: Path, run: bool) -> int:
    items = parse_progress(plan.read_text())
    if not items:
        print(f"{plan}: no Progress items found", file=sys.stderr)
        return 1
    root = git_root(plan)
    rows, regressed = [], False
    for item in items.values():
        if not item.done_when:
            result = "not checkable"
        elif not run:
            result = "not run"
        else:
            passed, _ = run_check(item.done_when, root)
            result = "PASS" if passed else "FAIL"
        state = "DONE" if item.checked else "OPEN"
        if item.checked and result == "FAIL":
            state, regressed = "REGRESSED", True
        title = item.rest[len(item.id):].strip()
        title = DONE_WHEN.sub("", title)
        rows.append((item.id, title[:50], state, item.done_when or "-", result))
    header = ("ID", "Title", "State", "Done when", "Check result now")
    widths = [max(len(r[i]) for r in [header, *rows]) for i in range(4)]
    for r in [header, *rows]:
        print("  ".join(c.ljust(w) for c, w in zip(r[:4], widths)), r[4])
    return 1 if regressed else 0


# ---- review ---------------------------------------------------------------

def item_section(text: str, item_id: str) -> str:
    """Plan text under the first heading that names the item, up to the next heading of its level."""
    lines = text.splitlines()
    word = re.compile(r"(?<!\w)" + re.escape(item_id) + r"(?!\w)")
    for i, line in enumerate(lines):
        m = re.match(r"^(#+)\s", line)
        if m and word.search(line):
            body = []
            for nxt in lines[i + 1:]:
                n = re.match(r"^(#+)\s", nxt)
                if n and len(n.group(1)) <= len(m.group(1)):
                    break
                body.append(nxt)
            return "\n".join([line, *body])[:SECTION_CAP_CHARS]
    return ""


def gather_evidence(root: Path, diff_range: str | None, files: list[str]) -> str:
    parts = []
    if diff_range or not files:
        r = subprocess.run(["git", "-C", str(root), "diff", diff_range or "HEAD"],
                           capture_output=True, text=True, timeout=60, check=False)
        if r.returncode != 0:
            raise SystemExit(f"git diff {diff_range or 'HEAD'} failed: {r.stderr.strip()}")
        d = r.stdout
        note = f"\n[TRUNCATED at {DIFF_CAP_CHARS} characters]" if len(d) > DIFF_CAP_CHARS else ""
        parts.append(f"## Diff ({diff_range or 'HEAD, working tree'})\n```diff\n{d[:DIFF_CAP_CHARS]}{note}\n```")
    for f in files:
        p = Path(f) if Path(f).is_absolute() else root / f
        parts.append(f"## File {f}\n```\n{p.read_text(errors='replace')[:DIFF_CAP_CHARS]}\n```")
    return "\n\n".join(parts)


SCHEMA = {
    "type": "object",
    "properties": {
        "verdict": {"type": "string", "enum": ["PASS", "NEEDS_WORK"]},
        "findings": {"type": "array", "items": {
            "type": "object",
            "properties": {k: {"type": "integer" if k == "line" else "string"}
                           for k in ("severity", "file", "line", "issue", "evidence")},
            "required": ["severity", "file", "line", "issue", "evidence"]}},
    },
    "required": ["verdict", "findings"],
}

_RUNNER = """
import json, sys
from agentcall import generate
r = json.load(sys.stdin)
g = generate(r["prompt"], provider="claude", model=r["model"], effort=r["effort"],
             system_prompt=r["system"], tools="", json_schema=json.dumps(r["schema"]),
             timeout_s=r["timeout"])
u = g.usage
print(json.dumps({"structured": g.structured, "model": g.model, "effort_requested": g.effort_requested.value,
                  "wall_clock_s": g.wall_clock_s, "cli_version": g.cli_version,
                  "usage": {k: getattr(u, k) for k in ("input_tokens", "output_tokens",
                            "cache_creation_input_tokens", "cache_read_input_tokens", "thinking_tokens")}}))
"""


def agentcall_python() -> str:
    """An interpreter that can `import agentcall`: $CCAGE_AGENTCALL_PYTHON, this one, or the checkout venv."""
    for cand in (os.environ.get("CCAGE_AGENTCALL_PYTHON"), sys.executable,
                 str(Path.home() / "dev/agentcall/.venv/bin/python")):
        if cand and subprocess.run([cand, "-c", "import agentcall"], capture_output=True, check=False).returncode == 0:
            return cand
    raise SystemExit("agentcall is not importable: set CCAGE_AGENTCALL_PYTHON to an interpreter "
                     "with it installed (e.g. ~/dev/agentcall/.venv/bin/python)")


def call_agentcall(prompt: str, system: str, model: str, effort: str) -> dict:
    """One schema-constrained, tools-off generation through agentcall's Python API.

    The Python API, not `agentcall generate`: the CLI cannot pass `json_schema` or `tools`, and
    prints only a usage line, not the provenance. Run in a subprocess so ccage itself keeps no
    dependency on agentcall being importable.
    """
    req = {"prompt": prompt, "system": system, "model": model, "effort": effort,
           "schema": SCHEMA, "timeout": REVIEW_TIMEOUT_S}
    r = subprocess.run([agentcall_python(), "-c", _RUNNER], input=json.dumps(req),
                       capture_output=True, text=True, timeout=REVIEW_TIMEOUT_S + 60, check=False)
    if r.returncode != 0:
        raise SystemExit(f"agentcall failed:\n{r.stderr.strip()[-2000:]}")
    return json.loads(r.stdout.strip().splitlines()[-1])


def render_review(item: Item, out: dict) -> str:
    s, u = out["structured"], out["usage"]
    lines = [f"# Review of {item.id}", "", f"Verdict: {s['verdict']}", "", f"Item: {item.rest}", "",
             "## Findings", ""]
    for f in s["findings"]:
        lines.append(f"- [{f['severity']}] {f['file']}:{f['line']} — {f['issue']}\n  Evidence: {f['evidence']}")
    if not s["findings"]:
        lines.append("None.")
    lines += ["", "## Provenance", "",
              f"- model: {out['model']}", f"- effort requested: {out['effort_requested']}",
              (f"- tokens: input {u['input_tokens']}, output {u['output_tokens']}, "
               f"cache write {u['cache_creation_input_tokens']}, "
               f"cache read {u['cache_read_input_tokens']}, thinking {u['thinking_tokens']}"),
              f"- wall clock: {out['wall_clock_s']:.1f} s", f"- CLI version: {out['cli_version']}"]
    return "\n".join(lines) + "\n"


def review(args: argparse.Namespace) -> int:
    plan = Path(args.plan)
    text = plan.read_text()
    item = parse_progress(text).get(args.id)
    if not item:
        print(f"{args.id}: no such Progress item in {plan}", file=sys.stderr)
        return 2
    root = git_root(plan)
    share = Path(os.environ.get("CCAGE_SHARE") or Path(__file__).resolve().parent.parent / "share")
    template = (share / "prompts" / "review.md").read_text()
    system, _, body = template.partition("\n---\n")
    fill = {"ITEM": item.rest, "SECTION": item_section(text, args.id) or "(none)",
            "DONE_WHEN": item.done_when or "(none)", "ID": item.id,
            "EVIDENCE": gather_evidence(root, args.diff, args.files)}
    prompt = re.sub(r"\{\{(\w+)\}\}", lambda m: fill[m.group(1)], body)
    out = call_agentcall(prompt, system.strip(), args.model, args.effort)
    path = root / "reviews" / f"{item.id}-{dt.datetime.now(dt.UTC):%Y%m%d-%H%M}.md"
    path.parent.mkdir(exist_ok=True)
    path.write_text(render_review(item, out))
    print(f"{out['structured']['verdict']}: {path}")
    return 0 if out["structured"]["verdict"] == "PASS" else 1


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="ccage")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("guard")
    pr = sub.add_parser("plan-report")
    pr.add_argument("plan")
    pr.add_argument("--no-run", action="store_true")
    rv = sub.add_parser("review")
    rv.add_argument("plan")
    rv.add_argument("id")
    rv.add_argument("--diff")
    rv.add_argument("--files", nargs="+", default=[])
    rv.add_argument("--model", default="opus")
    rv.add_argument("--effort", default="high")
    args = ap.parse_args(argv)
    if args.cmd == "guard":
        return guard(sys.stdin.read())
    if args.cmd == "plan-report":
        return plan_report(Path(args.plan), not args.no_run)
    return review(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
