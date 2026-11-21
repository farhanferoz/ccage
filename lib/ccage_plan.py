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
root of the plan file and passes on exit 0. A check the item describes in words ("done when:
... `command`", on its checkbox line or the indented lines under it) may be moved, unchanged,
into that slot without the owner's approval when the plan as last committed already describes
it so (described_checks): the item's definition of done is the same, only now the guard can run it.

A document RESUME's `### Plan` section names is guarded too, with or without a `## Progress`
heading: then every checkbox line of the file is an item. A tick on an item with no check may
carry its evidence instead, as one of two annotations on the item's lines:

    DONE <date>: <evidence>                 evidence holds a commit `git cat-file` finds, a path that
                                            exists, a decision Dnnn that DECISIONS.md has, or a job
                                            number RESUME.md or CHANGELOG.md mentions
    SUPERSEDED by Dnnn (<date>): '<quote>'  the quote is, verbatim, inside entry Dnnn of DECISIONS.md
                                            (the owner's recorded words)

An annotation is not part of the item's identity (title, write set, check), so adding one needs
no approval. `(open <date>: <what remains>)` is the third annotation (Part C of the design).

Dependencies: standard library only. The review calls agentcall through its Python API in an
interpreter that has it installed (see `call_agentcall`).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

# Each constant below is the DEFAULT of a setting `_setting` reads from the environment when it is
# used: CCAGE_PLAN_<NAME> (docs/FEATURES.md lists them), so a guard call and a review each see the
# value of their own run.
# A check may run up to 4 minutes (owner 2026-11-07: "cannot run more than 3 or 4 minutes"), held
# by its own `timeout 240`; the guard leaves room for that and a few seconds of tests before it.
CHECK_TIMEOUT_S = 270
TAIL_LINES = 20
MIN_QUOTE_CHARS = 20
GIT_TIMEOUT_S = 10         # `git show` of the committed plan, `git rev-parse` of its root
DIFF_TIMEOUT_S = 60        # `git diff` gathered for a review
REVIEW_SLACK_S = 60        # the review subprocess may outlive agentcall's own timeout by this
HEADING_PROGRESS = re.compile(r"^##\s+Progress\s*$", re.MULTILINE)
ITEM = re.compile(r"^\s*[-*]\s+\[([ xX])\]\s+(.*?)\s*$")
DONE_WHEN = re.compile(r"\s+—\s+done when:\s+`(.+)`\s*$")
# A check described in words on the checkbox line ("... fixed. done when: the referee passes"):
# neither title nor write set, so re-wrapping it under the item changes neither.
PROSE_DONE_WHEN = re.compile(r"\bdone when:", re.IGNORECASE)
# The command such a check names: a backticked span right after a colon ("done when: `cmd`",
# "... read from its log: `cmd`"). Evidence lines under the item ("evidence 2026-11-07: ...")
# are never the check, however they are written.
CHECK_SPAN = re.compile(r":\s*`([^`]+)`")
EVIDENCE_LINE = re.compile(r"^evidence\b", re.IGNORECASE)
APPROVED = re.compile(r'owner approved:\s*"(.+)"')
# The annotation grammar (docstring). A date is ISO, or "21 Nov" with an optional year. An annotation
# runs to the end of its line, or to the ` — done when: `command`` that closes the line.
DATE = r"(?:\d{4}-\d{2}-\d{2}|\d{1,2} [A-Z][a-z]{2}(?: \d{4})?)"
LINE_END = r"(?=\s+—\s+done when:\s+`[^`]+`\s*$|$)"
DONE_NOTE = re.compile(rf"\bDONE\s+{DATE}:\s*(?P<evidence>.+?)\s*{LINE_END}")
SUPERSEDED_NOTE = re.compile(rf"\bSUPERSEDED by (?P<id>D\d+) \({DATE}\):\s*(?P<quote>.+?)\s*{LINE_END}")
OPEN_NOTE = re.compile(rf"\(open {DATE}:")
ANNOTATION_START = re.compile(rf"\s*(?:\bDONE\s+{DATE}:|\bSUPERSEDED by D\d+ \({DATE}\):|\(open {DATE}:)")
# git's default abbreviated hash is 7 hex digits and a full one 40: a fact of git, not a setting.
COMMIT_TOKEN = re.compile(r"\b[0-9a-f]{7,40}\b")
DECISION_TOKEN = re.compile(r"\bD\d+\b")
FILE_EXTENSION = re.compile(r"\w\.[A-Za-z0-9]{1,5}$")
PATH_STRIP = "'\"()[],;:."          # punctuation that clings to a path written in prose
# Words that make a number a job number in evidence ("slurm 8697908", "Turing 381"); a fact of how
# this project's evidence is written, so it is a setting (CCAGE_PLAN_JOB_WORDS).
JOB_WORDS = "job|jobs|slurm|sbatch|isambard|turing|run"
# A PreToolUse command hook that outlives its timeout (600 s default) does not block the
# call, so a guard call stops running checks after this many seconds and denies the rest.
GUARD_BUDGET_S = 480
# Entries the harness records as user turns although the owner did not type them: other
# sessions and teammates, task notifications, command output, hook feedback, and the text
# ccage-auto types itself (bin/ccage-auto: auto-checkpoint and supervisor nudges, the
# post-/clear resume prompt, a --say message queued before the session started). A quote
# found only in one of these is not the owner's approval. A message the owner types while the
# session is working is recorded as a queued-command attachment, not a user turn, and counts
# (user_texts). KNOWN LIMITS: a --say message typed into a running session, idle or mid-turn,
# carries no marker and counts; the committed plan a moved check is read from (moved_check) is
# the session's own writing too, so a check committed through Bash and then moved passes, and
# the MOVE log line names the command for that audit.
NOT_OWNER_PREFIXES = ("<system-reminder>", "<teammate-message", "Another Claude session sent a message",
                      "<local-command", "<command-name>", "[SYSTEM NOTIFICATION", "Stop hook feedback",
                      "[auto-checkpoint]", "[supervisor]", "Resume the task from RESUME.md", "[queued ")
REVIEW_TIMEOUT_S = 900
DIFF_CAP_CHARS = 200_000
SECTION_CAP_CHARS = 6000


@dataclass(frozen=True)
class Item:
    id: str
    checked: bool
    rest: str                 # everything after the checkbox, whitespace-collapsed
    done_when: str | None
    lines: str = ""           # the indented lines under the checkbox, each whitespace-collapsed, "\n"-joined


def has_progress(text: str) -> bool:
    return bool(HEADING_PROGRESS.search(text))


def has_boxes(text: str) -> bool:
    return any(ITEM.match(line) for line in text.splitlines())


def _progress_lines(text: str, whole: bool = False) -> list[tuple[bool, str, str]]:
    """(checked, rest, lines) for each checkbox line of the `## Progress` section (of the whole
    file when `whole`: a document RESUME lists that has no such section): rest is the
    checkbox line after the box, lines the indented lines under it (up to the next checkbox,
    heading or unindented line), each line whitespace-collapsed, joined by newlines."""
    inside, under_item, out = whole, False, []
    for line in text.splitlines():
        if HEADING_PROGRESS.match(line):
            inside, under_item = True, False
            continue
        if re.match(r"^#{1,2}\s", line):
            inside, under_item = whole, False
        if not inside:
            continue
        m = ITEM.match(line)
        rest = " ".join(m.group(2).split()) if m else ""
        if rest:
            out.append([m.group(1) in "xX", rest, ""])
            under_item = True
        elif under_item and line[:1].isspace() and line.strip():
            out[-1][2] = f"{out[-1][2]}\n{' '.join(line.split())}".lstrip("\n")
        elif line.strip():
            under_item = False            # an unindented line ends the item's own lines
    return [(checked, rest, lines) for checked, rest, lines in out]


def _without_annotation(text: str) -> str:
    """text up to its first annotation (DONE, SUPERSEDED, open): an annotation is evidence about
    an item, not part of its identity."""
    m = ANNOTATION_START.search(text)
    return text[:m.start()] if m else text


def _word(item_id: str) -> re.Pattern[str]:
    """Matches item_id as a whole word."""
    return re.compile(r"(?<!\w)" + re.escape(item_id) + r"(?!\w)")


def _head(rest: str) -> str:
    """ID and title: the text before the first " — ", before a check described in words and
    before an annotation (DONE, SUPERSEDED, open), without trailing punctuation."""
    head = _without_annotation(rest).split(" — ")[0]
    prose = PROSE_DONE_WHEN.search(head)
    return (head[:prose.start()] if prose else head).rstrip(" .,;:")


def colliding_keys(*texts: str, whole: bool = False) -> tuple[set[str], set[str]]:
    """First words, and heads, shared by two items of one text ("Step" for "Step 2", "Step 5")."""
    words: set[str] = set()
    heads: set[str] = set()
    for t in texts:
        rests = [rest for _, rest, _ in _progress_lines(t, whole)]
        firsts, hs = [r.split()[0] for r in rests], [_head(r) for r in rests]
        words |= {w for w in firsts if firsts.count(w) > 1}
        heads |= {h for h in hs if hs.count(h) > 1}
    return words, heads


def parse_progress(text: str, colliding: tuple[set[str], set[str]] | None = None,
                   whole: bool = False) -> dict[str, Item]:
    """Items of the `## Progress` section (the whole file when `whole`) in file order, keyed by
    first word (ID); by the head (text before the first " — ") when the first word collides with
    another item's; by the whole line when the heads collide too. A shared key would hide one
    item behind another."""
    words, heads = colliding_keys(text, whole=whole) if colliding is None else colliding
    items: dict[str, Item] = {}
    for checked, rest, lines in _progress_lines(text, whole):
        first, head = rest.split()[0], _head(rest)
        item_id = first if first not in words else head if head not in heads else rest
        dw = DONE_WHEN.search(rest)
        items[item_id] = Item(item_id, checked, rest, dw.group(1) if dw else None, lines)
    return items


def signature(rest: str) -> tuple[str, tuple[str, ...], str | None]:
    """What a change needs the owner's approval for: ID and title, write set (the backticked
    paths), done-when. Other text on the line (an annotation in the write-set part, a check
    described in words) is free."""
    dw = DONE_WHEN.search(rest)
    body = _without_annotation(rest[:dw.start()] if dw else rest)
    prose = PROSE_DONE_WHEN.search(body)
    if prose:  # the words run to the next " — " part; a write set after them is still compared
        end = body.find(" — ", prose.start())
        body = body[:prose.start()] + (body[end:] if end >= 0 else "")
    head = _head(body)
    return head, tuple(re.findall(r"`([^`]+)`", body[len(head):])), dw.group(1) if dw else None


def committed_text(plan: Path) -> str | None:
    """The plan as last committed (git HEAD), or None when it is not in git or not committed."""
    try:
        out = subprocess.run(["git", "-C", str(plan.parent), "show", f"HEAD:./{plan.name}"],
                             capture_output=True, text=True, errors="replace",
                             timeout=_setting("CCAGE_PLAN_GIT_TIMEOUT_S", GIT_TIMEOUT_S), check=False)
    except (subprocess.SubprocessError, OSError):
        return None
    return out.stdout if out.returncode == 0 else None


def described_checks(item: Item) -> list[str]:
    """The commands an item's own text gives as its check, whitespace-collapsed: each backticked
    span right after a colon, from the item's first "done when:" on, before its evidence lines."""
    own = [item.rest]
    for line in item.lines.split("\n"):
        if EVIDENCE_LINE.match(line):
            break
        own.append(line)
    text = "\n".join(own)
    start = PROSE_DONE_WHEN.search(text)
    return [" ".join(m.group(1).split()) for m in CHECK_SPAN.finditer(text, start.end() - 1)] if start else []


def moved_check(was: Item, now: Item, committed: Item | None) -> bool:
    """True when the edit only moves the item's own check into the checkbox line's ` — done
    when: ` slot: the line had none, title and write set are unchanged, and the command is,
    unchanged, the check the item's own text in the committed plan describes (described_checks).
    A check first written since the last commit is a new check and still needs the owner."""
    return (was.done_when is None and now.done_when is not None and committed is not None
            and signature(was.rest)[:2] == signature(now.rest)[:2]
            and " ".join(now.done_when.split()) in described_checks(committed))


def git_root(path: Path) -> Path:
    """The plan's git root, else its nearest existing directory (a Write may create the dir)."""
    start = path.parent
    while not start.exists() and start != start.parent:
        start = start.parent
    try:
        out = subprocess.run(["git", "-C", str(start), "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=_setting("CCAGE_PLAN_GIT_TIMEOUT_S", GIT_TIMEOUT_S),
                             check=True)
        return Path(out.stdout.strip())
    except (subprocess.SubprocessError, OSError):
        return start


def run_check(cmd: str, cwd: Path, timeout: float | None = None) -> tuple[bool, str]:
    """Run a done-when command; (passed, the last CCAGE_PLAN_TAIL_LINES lines of its output). It
    runs in its own process group, so a timeout kills the whole pipeline, not just bash.
    `timeout` defaults to CCAGE_PLAN_CHECK_TIMEOUT_S."""
    if timeout is None:
        timeout = _setting("CCAGE_PLAN_CHECK_TIMEOUT_S", CHECK_TIMEOUT_S)
    try:
        p = subprocess.Popen(["bash", "-c", cmd], cwd=cwd, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, text=True,
                             start_new_session=True)
    except OSError as exc:
        return False, f"could not run: {exc}"
    try:
        out, _ = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.wait()
        return False, f"timed out after {timeout:g} s"
    tail_lines = int(_setting("CCAGE_PLAN_TAIL_LINES", TAIL_LINES))
    return p.returncode == 0, "\n".join(out.splitlines()[-tail_lines:])


# ---- the project around a plan: RESUME's plan list, DECISIONS, annotations ------

@dataclass(frozen=True)
class Project:
    """The project a plan belongs to: its git root and, when present, its RESUME and DECISIONS."""
    root: Path
    resume: Path | None
    decisions: Path | None


def project_of(plan: Path) -> Project:
    """The project directory is $CLAUDE_PROJECT_DIR (set for hooks), else the plan's git root; its
    RESUME is RESUME.md, or RESUME.<slot>.md under a valid CCAGE_SLOT (as resume_autoload.sh)."""
    given = os.environ.get("CLAUDE_PROJECT_DIR")
    base = Path(given) if given and Path(given).is_dir() else git_root(plan)
    slot = os.environ.get("CCAGE_SLOT", "")
    name = f"RESUME.{slot}.md" if slot and re.fullmatch(r"[A-Za-z0-9_-]+", slot) else "RESUME.md"
    resume, decisions = base / name, base / "DECISIONS.md"
    return Project(base, resume if resume.is_file() else None, decisions if decisions.is_file() else None)


def plan_docs_script() -> Path | None:
    """hooks/lib/plan_docs.sh: beside this file when installed with the hooks, in the checkout's
    share/hooks/lib, or in the config directory's hooks (when run from `ccage`'s own lib)."""
    here = Path(__file__).resolve().parent
    config = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
    for cand in (here / "lib" / "plan_docs.sh", here.parent / "share" / "hooks" / "lib" / "plan_docs.sh",
                 config / "hooks" / "lib" / "plan_docs.sh", Path.home() / ".claude" / "hooks" / "lib" / "plan_docs.sh"):
        if cand.is_file():
            return cand
    return None


def listed_plans(project: Project) -> list[Path]:
    """The documents RESUME's `### Plan` names that exist, in listing order, from the one
    definition of that list (plan_doc_paths in plan_docs.sh; the status line and session start use it)."""
    script = plan_docs_script()
    if project.resume is None or script is None:
        return []
    try:
        out = subprocess.run(["bash", "-c", '. "$1"; plan_doc_paths "$2" "$3"', "_", str(script),
                              str(project.resume), str(project.root)],
                             capture_output=True, text=True, errors="replace",
                             timeout=_setting("CCAGE_PLAN_GIT_TIMEOUT_S", GIT_TIMEOUT_S), check=False)
    except (subprocess.SubprocessError, OSError) as exc:
        log(f"ERROR-listing {project.resume}: {type(exc).__name__}: {exc}")
        return []
    return [Path(line).resolve() for line in out.stdout.splitlines() if line.strip()]


def is_listed(plan: Path, project: Project) -> bool:
    return plan.resolve() in listed_plans(project)


DECISION_HEAD = re.compile(r"^[-*]\s+\*\*(D\d+)\*\*")
ENTRY_END = re.compile(r"^(?:[-*]\s|#)")


def decision_entries(text: str) -> dict[str, str]:
    """DECISIONS.md entry text by id ("D385"): the `- **D385**` bullet and the lines under it up to
    the next bullet or heading, curly quotes made straight. An id that has an index line and a full
    entry gets both."""
    entries: dict[str, str] = {}
    current = None
    for line in text.translate(CURLY).splitlines():
        head = DECISION_HEAD.match(line)
        if head:
            current = head.group(1)
            entries[current] = f"{entries.get(current, '')}{line}\n"
        elif ENTRY_END.match(line):
            current = None
        elif current:
            entries[current] += f"{line}\n"
    return entries


def read_text(path: Path | None) -> str:
    try:
        return path.read_text(errors="replace") if path else ""
    except OSError:
        return ""


def quoted_spans(text: str) -> list[str]:
    """Candidate quotations in `text`: each '...' and "..." span, and the span from the first
    apostrophe to the last (a quotation may itself hold an apostrophe)."""
    out = re.findall(r"'([^']+)'", text) + re.findall(r'"([^"]+)"', text)
    first, last = text.find("'"), text.rfind("'")
    if last > first >= 0:
        out.append(text[first + 1:last])
    return out


@dataclass(frozen=True)
class Verdict:
    """What an item's annotation says about a tick: kind is "none" (no annotation), "done" or
    "superseded"; error is why the annotation does not hold, None when it does; detail names the
    evidence that verified it (logged)."""
    kind: str
    error: str | None = None
    detail: str = ""


def _squash(text: str) -> str:
    return " ".join(text.translate(CURLY).split())


def superseded_verdict(decision_id: str, quote: str, project: Project) -> Verdict:
    min_quote = int(_setting("CCAGE_PLAN_MIN_QUOTE_CHARS", MIN_QUOTE_CHARS))
    entry = decision_entries(read_text(project.decisions)).get(decision_id)
    if entry is None:
        where = project.decisions or "DECISIONS.md (none found in the project)"
        return Verdict("superseded", f"SUPERSEDED by {decision_id}: no entry {decision_id} in {where}. Name the ruling "
                       "that closes the item, as written in DECISIONS.md.")
    text = _squash(entry)
    found = next((q for q in quoted_spans(quote) if len(_squash(q)) >= min_quote and _squash(q) in text), None)
    if found is None:
        return Verdict("superseded", f"SUPERSEDED by {decision_id}: no quotation of {min_quote}+ characters in "
                       f"'...' is found verbatim in entry {decision_id} of DECISIONS.md. Copy the owner's words "
                       f"from that entry, whole and in order, inside single quotes.")
    return Verdict("superseded", None, f"quote from {decision_id}: {_squash(found)[:60]}")


def commits_found(candidates: list[str], root: Path) -> list[str]:
    """The candidates (hashes, possibly abbreviated) that name a commit in the repository at root."""
    if not candidates:
        return []
    try:
        out = subprocess.run(["git", "-C", str(root), "cat-file", "--batch-check"],
                             input="".join(f"{c}^{{commit}}\n" for c in candidates),
                             capture_output=True, text=True, errors="replace",
                             timeout=_setting("CCAGE_PLAN_GIT_TIMEOUT_S", GIT_TIMEOUT_S), check=False)
    except (subprocess.SubprocessError, OSError):
        return []
    return [c for c, line in zip(candidates, out.stdout.splitlines()) if line.split()[1:2] == ["commit"]]


def existing_path(token: str, root: Path, plan: Path) -> bool:
    """token looks like a path (holds a "/" or ends in a file extension; not a URL) and exists:
    absolute, under ~, or relative to the project root or the plan's folder."""
    token = token.strip(PATH_STRIP)
    if not ("/" in token or FILE_EXTENSION.search(token)) or "://" in token:
        return False
    if token.startswith("~/"):
        return (Path.home() / token[2:]).exists()
    candidates = [Path(token)] if token.startswith("/") else [root / token, plan.parent / token]
    return any(c.exists() for c in candidates)


def done_verdict(evidence: str, plan: Path, project: Project) -> Verdict:
    """DONE <date>: <evidence> holds when the evidence carries one verifiable token: a commit the
    repository has, a path that exists, a decision DECISIONS.md has, or a job number RESUME.md or
    CHANGELOG*.md mentions (a number of three or more digits after a job word)."""
    hashes = commits_found(COMMIT_TOKEN.findall(evidence), project.root)
    if hashes:
        return Verdict("done", None, f"commit {hashes[0]}")
    for token in evidence.replace("`", " ").split():
        if existing_path(token, project.root, plan):
            return Verdict("done", None, f"path {token.strip(PATH_STRIP)}")
    wanted = set(DECISION_TOKEN.findall(evidence))
    if wanted:
        have = set(decision_entries(read_text(project.decisions)))
        if wanted & have:
            return Verdict("done", None, f"decision {sorted(wanted & have)[0]}")
    words = _words_setting("CCAGE_PLAN_JOB_WORDS", JOB_WORDS)
    numbers = re.findall(rf"\b(?:{words})\s+#?(\d{{3,}})\b", evidence, re.IGNORECASE)
    if numbers:
        record = read_text(project.resume) + "".join(read_text(c) for c in sorted(project.root.glob("CHANGELOG*.md")))
        for n in numbers:
            if re.search(rf"(?<!\d){n}(?!\d)", record):
                return Verdict("done", None, f"job {n}")
    return Verdict("done", "DONE annotation without evidence that can be verified. Put one of these in it: a commit "
                   "hash this repository has, a path that exists, a decision id (Dnnn) that DECISIONS.md has, or a "
                   "job number (after the word job, slurm, Turing or Isambard) that RESUME.md or CHANGELOG.md mentions.")


def annotation_verdict(item: Item, plan: Path, project: Project) -> Verdict:
    """The verdict on an item's own lines: its SUPERSEDED annotation if it has one, else its DONE."""
    lines = [item.rest, *(item.lines.split("\n") if item.lines else [])]
    for line in lines:
        m = SUPERSEDED_NOTE.search(line)
        if m:
            return superseded_verdict(m.group("id"), m.group("quote"), project)
    for line in lines:
        m = DONE_NOTE.search(line)
        if m:
            return done_verdict(m.group("evidence"), plan, project)
    return Verdict("none")


# ---- guard ----------------------------------------------------------------

def user_texts(transcript: Path) -> list[str] | None:
    """Text the owner typed: user turns, and messages typed while the session was working
    (queued-command attachments of human origin); never tool results, meta, a compaction
    summary or assistant text. None when the transcript cannot be read."""
    try:
        raw = transcript.read_text(errors="replace")
    except OSError:
        return None
    texts: list[str] = []
    for line in raw.splitlines():
        try:
            d = json.loads(line)
        except ValueError:
            continue
        att = d.get("attachment") if d.get("type") == "attachment" else None
        if isinstance(att, dict) and att.get("type") == "queued_command":
            # measured 2026-11-07: an owner's mid-turn message is {"type": "attachment",
            # "attachment": {"type": "queued_command", "prompt": ..., "origin": {"kind": "human"}}};
            # task notifications arrive the same way with origin kind "task-notification".
            if (att.get("origin") or {}).get("kind") == "human":
                content = att.get("prompt")
                texts += [content] if isinstance(content, str) else [
                    b.get("text", "") for b in (content if isinstance(content, list) else [])
                    if isinstance(b, dict) and b.get("type") == "text"]
            continue
        if (d.get("type") != "user" or d.get("isMeta") or d.get("isCompactSummary")
                or (d.get("origin") or {}).get("kind") not in (None, "human")):
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


# Claude Code's Edit matches a straight-quote old_string against curly quotes in the file
# (measured 2026-11-04: `owner's "first"` matched `owner’s “first”` and the edit applied).
CURLY = str.maketrans({"‘": "'", "’": "'", "“": '"', "”": '"'})


def fold_quotes(obj):
    """obj with curly quotes made straight in every string inside it."""
    if isinstance(obj, str):
        return obj.translate(CURLY)
    if isinstance(obj, list):
        return [fold_quotes(v) for v in obj]
    if isinstance(obj, dict):
        return {k: fold_quotes(v) for k, v in obj.items()}
    return obj


def approved_quotes(text: str, item_id: str) -> list[str]:
    """Candidate quotes on the approval lines naming item_id: the span to the line's last `"`
    (a quote may itself contain `"`) and each separate "..." span (a later quoted word on the
    line must not void the approval)."""
    word, out = _word(item_id), []
    for line in text.splitlines():
        m = APPROVED.search(line) if word.search(line) else None
        if m:
            out += [m.group(1), *re.findall(r'"([^"]+)"', line[m.start():])]
    return out


def violations(old: str, new: str, plan: Path, transcript: Path | None, folded: bool = False,
               whole: bool = False) -> list[str]:
    """Every refusal for this edit; folded: old and new had curly quotes made straight, so the
    committed plan is read the same way; whole: the plan has no Progress section and every checkbox
    of the file is an item (a document RESUME lists)."""
    committed = committed_text(plan)
    committed = committed.translate(CURLY) if committed and folded else committed
    shared = colliding_keys(old, new, *([committed] if committed else []), whole=whole)
    before, after = parse_progress(old, shared, whole), parse_progress(new, shared, whole)
    at_commit = parse_progress(committed, shared, whole) if committed else {}
    moved = {i for i, now in after.items()
             if i in before and moved_check(before[i], now, at_commit.get(i))}
    for item_id in moved:
        log(f"MOVE {plan} {item_id}: its committed check moved unchanged onto the checkbox line: "
            f"`{after[item_id].done_when[:200]}`")
    out: list[str] = []
    project = project_of(plan)
    root = project.root
    deadline = time.monotonic() + _setting("CCAGE_PLAN_GUARD_BUDGET_S", GUARD_BUDGET_S)
    check_timeout = _setting("CCAGE_PLAN_CHECK_TIMEOUT_S", CHECK_TIMEOUT_S)
    tail_lines = int(_setting("CCAGE_PLAN_TAIL_LINES", TAIL_LINES))
    for item_id, item in after.items():
        was = before.get(item_id)
        if not item.checked or (was and was.checked):
            continue
        cmd = item.done_when if item_id in moved else (was or item).done_when
        note = annotation_verdict(item, plan, project)
        if note.kind == "superseded" or (note.kind == "done" and not cmd):
            if note.error:
                out.append(f"TICK {item_id}: {note.error}")
            else:
                log(f"TICK-EVIDENCE {plan} {item_id}: ticked on a {note.kind} annotation ({note.detail})")
            continue
        if not cmd:
            out.append(f"TICK {item_id}: no done-when command. An item is ticked only when its "
                       "check passes; put the check on the checkbox line as "
                       "` — done when: `<command>``. The check the item already describes (right "
                       "after its \"done when:\") moves there unchanged without approval; a new or "
                       "different check needs the owner's words. An item with no check may be ticked "
                       "on evidence instead: add `DONE <date>: <evidence>` (a commit, an existing "
                       "path, a decision id, or a job number RESUME.md or CHANGELOG.md mentions), or "
                       "`SUPERSEDED by Dnnn (<date>): '<the owner's words from that entry>'`.")
            continue
        left = deadline - time.monotonic()
        if left <= 0:
            out.append(f"TICK {item_id}: not checked: time budget of one guard call is spent. "
                       "Tick fewer items per edit.")
            continue
        passed, tail = run_check(cmd, root, min(check_timeout, left))
        if not passed:
            out.append(f"TICK {item_id}: its check failed, so it stays open. Check: {cmd}\n"
                       f"last {tail_lines} lines:\n{tail}")
    changed = [i for i, was in before.items()
               if i not in moved and (i not in after or signature(after[i].rest) != signature(was.rest))]
    if changed:
        heard = user_texts(transcript) if transcript else None
        for item_id in changed:
            dropped = item_id not in after
            what = "dropped" if dropped else "changed (ID, title, write set or done-when)"
            hint = "" if dropped else (" Evidence for an item (a commit, a job, a result) needs no "
                                       "approval: put it on an indented line below the item, not in its title.")
            if not dropped and before[item_id].done_when is None and after[item_id].done_when:
                hint += (" A check moves onto the checkbox line without approval only when that same "
                         "command, unchanged, is the check the item describes in the plan as last "
                         "committed (right after its \"done when:\" or a colon after it, outside its "
                         "evidence lines); this one is not, so it is a new check.")
            min_quote = int(_setting("CCAGE_PLAN_MIN_QUOTE_CHARS", MIN_QUOTE_CHARS))
            quotes = [q for q in approved_quotes(new, item_id) if len(q) >= min_quote]
            if heard is None:
                out.append(f"{item_id} {what}: the session transcript is unavailable, so the "
                           f"owner's approval cannot be checked.{hint}")
            elif not any(q in t for q in quotes for t in heard):
                out.append(f"{item_id} {what} without the owner's words. Ask the owner; then put "
                           f'a line `owner approved: "<their words, {min_quote}+ characters>"` naming {item_id} '
                           f"in the plan, their message verbatim inside one pair of double quotes.{hint}")
    return out


def log(msg: str) -> None:
    """Append one line to the guard log. Never raises: a refusal must not turn into exit 1."""
    try:
        path = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
        with open(path / "plan_contract_guard.log", "a") as f:
            f.write(f"{dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')} {msg}\n")
    except Exception:  # noqa: BLE001, S110 -- a lost log line is better than a lost refusal
        pass


def _setting(name: str, default: float) -> float:
    """The number in environment variable `name`, else `default`. A value that is not a non-negative
    number is ignored, with one line in the guard log naming the variable: a guard must never fail
    a session over a setting."""
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        val = float(raw)
    except ValueError:
        val = -1.0
    if not 0 <= val < float("inf"):   # negative, infinite or NaN; every setting here is a duration or a size
        log(f"IGNORED-setting {name}={raw!r}: not a non-negative number; using {default}")
        return default
    return val


def _words_setting(name: str, default: str) -> str:
    """A `a|b|c` list of words from environment variable `name`, else `default`. Anything with a
    character other than letters, digits, `_` and `|` is ignored and logged, like a bad number."""
    raw = (os.environ.get(name) or "").strip()
    if not raw:
        return default
    if not re.fullmatch(r"[A-Za-z0-9_|]+", raw):
        log(f"IGNORED-setting {name}={raw!r}: not words separated by |; using {default}")
        return default
    return raw


def guard(stdin_text: str) -> int:
    try:
        payload = json.loads(stdin_text)
        tool, tin = payload.get("tool_name"), payload.get("tool_input") or {}
        path = Path(tin.get("file_path") or "")
        if tool not in ("Write", "Edit", "MultiEdit") or path.suffix.lower() != ".md":
            return 0
        old = path.read_text() if path.is_file() else ""
        new, folded = new_text(tool, tin, old), False
        if new is None and tool != "Write":
            # Not found verbatim: the tool may still apply it with quotes folded, so judge it
            # that way rather than let it through unjudged.
            old, folded = old.translate(CURLY), True
            new = new_text(tool, fold_quotes(tin), old)
        whole = False
        if new is None:
            return 0
        if not (has_progress(old) or has_progress(new)):
            # No Progress section: guarded all the same when RESUME's `### Plan` lists the file
            # (the plans people use are written in many shapes). Cheap test first: only a file
            # with checkboxes asks RESUME.
            if not (has_boxes(old) or has_boxes(new)):
                return 0
            if not is_listed(path, project_of(path)):
                log(f"SKIP {path}: checkboxes, but no Progress section and not listed under RESUME's ### Plan")
                return 0
            whole = True
        tp = payload.get("transcript_path")
        found = violations(old, new, path, Path(tp) if tp else None, folded, whole)
    except Exception as exc:  # noqa: BLE001 -- a broken guard must not wedge sessions
        log(f"ERROR-allow {type(exc).__name__}: {exc}")
        return 0
    if found:
        log(f"DENY {path} {len(found)} violation(s): " + " | ".join(v.splitlines()[0][:120] for v in found))
        print("Plan contract: this edit to the Progress list is refused.\n\n" + "\n\n".join(found),
              file=sys.stderr)
        return 2
    log(f"ALLOW {path}" + (" (listed under RESUME's ### Plan, no Progress section)" if whole else ""))
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
    word = _word(item_id)
    for i, line in enumerate(lines):
        m = re.match(r"^(#+)\s", line)
        if m and word.search(line):
            body = []
            for nxt in lines[i + 1:]:
                n = re.match(r"^(#+)\s", nxt)
                if n and len(n.group(1)) <= len(m.group(1)):
                    break
                body.append(nxt)
            return "\n".join([line, *body])[:int(_setting("CCAGE_PLAN_SECTION_CAP_CHARS", SECTION_CAP_CHARS))]
    return ""


def gather_evidence(root: Path, diff_range: str | None, files: list[str]) -> str:
    parts = []
    cap = int(_setting("CCAGE_PLAN_DIFF_CAP_CHARS", DIFF_CAP_CHARS))
    if diff_range or not files:
        r = subprocess.run(["git", "-C", str(root), "diff", diff_range or "HEAD"],
                           capture_output=True, text=True,
                           timeout=_setting("CCAGE_PLAN_DIFF_TIMEOUT_S", DIFF_TIMEOUT_S), check=False)
        if r.returncode != 0:
            raise SystemExit(f"git diff {diff_range or 'HEAD'} failed: {r.stderr.strip()}")
        d = r.stdout
        note = f"\n[TRUNCATED at {cap} characters]" if len(d) > cap else ""
        parts.append(f"## Diff ({diff_range or 'HEAD, working tree'})\n```diff\n{d[:cap]}{note}\n```")
    for f in files:
        p = Path(f) if Path(f).is_absolute() else root / f
        parts.append(f"## File {f}\n```\n{p.read_text(errors='replace')[:cap]}\n```")
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
    review_timeout = _setting("CCAGE_PLAN_REVIEW_TIMEOUT_S", REVIEW_TIMEOUT_S)
    req = {"prompt": prompt, "system": system, "model": model, "effort": effort,
           "schema": SCHEMA, "timeout": review_timeout}
    r = subprocess.run([agentcall_python(), "-c", _RUNNER], input=json.dumps(req),
                       capture_output=True, text=True, check=False,
                       timeout=review_timeout + _setting("CCAGE_PLAN_REVIEW_SLACK_S", REVIEW_SLACK_S))
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
    # The ID may be a title with "/" in it: keep the file name inside reviews/.
    safe = re.sub(r"[^\w.-]+", "_", item.id).strip("._") or "item"
    path = root / "reviews" / f"{safe}-{dt.datetime.now(dt.timezone.utc):%Y%m%d-%H%M%S}.md"
    path.parent.mkdir(parents=True, exist_ok=True)
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
    # 1 means NEEDS_WORK; a review that could not be made exits 2.
    try:
        return review(args)
    except SystemExit as exc:
        if not isinstance(exc.code, str):
            raise
        print(exc.code, file=sys.stderr)
    except (OSError, subprocess.SubprocessError, ValueError, LookupError, TypeError) as exc:
        print(f"ccage review: {type(exc).__name__}: {exc}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
