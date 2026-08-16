#!/usr/bin/env bash
# Stop hook — refuse to end an UNATTENDED turn while work is plainly available.
#
# THE SYMPTOM (user-reported, 2026-08-10, recurring across many sessions): during
# an autonomous run the root goes quiet while unblocked work remains. Two shapes,
# both reported verbatim:
#   A. "I've done this. This is what I'm going to do next" — and then it stops,
#      without doing it. The reasoning is intact; the CONTINUATION fails.
#   B. It dispatches agents, then stops doing anything at all, even though there
#      is more work that is completely unblocked and it could do meanwhile.
#
# WHY THE OBVIOUS DESIGN IS WRONG. The intervention originally written for this
# complaint was a turn-end ENUMERATION gate: make the root list remaining tasks
# and classify each done/dispatched/blocked. That check PASSES TRIVIALLY here —
# the failing sessions already enumerate correctly ("next I'll do X"). Enumeration
# is not the deficit. Acting on the enumeration is. Detect the gap between the
# stated intention and the absent action, not the absence of a statement.
#
# SHAPE B IS NOT A DEADLOCK, IT IS A SERIALISATION. Ending a turn with subagents
# running is normal — their completion re-invokes the parent. The defect is the
# root idling through that window instead of doing unblocked work, which turns a
# parallel plan into a sequential one at wall-clock cost.
#
# SCOPE: autonomous runs ONLY. Registered by ccage-auto into its per-run settings
# file (same pattern as autonomous_ask_guard.sh), and additionally gated on the
# CCAGE_AUTONOMOUS marker so it stays inert if that settings file is ever reused.
# An interactive session must never pay a turn-end check.
#
# RUNAWAY PROTECTION IS OURS. The docs do not describe any built-in cap on
# consecutive Stop refusals, and no stop_hook_active field exists in the Stop
# payload (verified against the hooks reference 2026-08-10). A Stop hook that can
# refuse forever can wedge a session, so this one counts its own consecutive
# blocks per session and yields after CCLAUDE_STOPGUARD_MAX (default 2). A guard
# that traps a session is worse than the stall it prevents.
#
# HONEST PRECISION NOTE. Shape B keys on GROUND TRUTH (live subagent transcripts
# on disk). Shape A keys on PHRASE MATCHING of last_assistant_message, which is
# the weaker half — same tradeoff as poll_loop_guard's narrow/broad split. Shape A
# therefore ships CONSERVATIVE: it fires only on an explicit first-person future
# commitment, and never when a question was put to the user.
#
# MODES: CCLAUDE_STOPGUARD_MODE = enforce (default) | observe | off.
# FAIL-OPEN ALWAYS: any parse error, missing field or unwritable state allows the
# stop. Never wedge a session on bad data.

payload="$(cat 2>/dev/null || true)"

python3 - "$payload" <<'PY'
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile
import time

MODE = os.environ.get("CCLAUDE_STOPGUARD_MODE", "enforce")
try:
    MAX_BLOCKS = int(os.environ.get("CCLAUDE_STOPGUARD_MAX", "2"))
except ValueError:
    MAX_BLOCKS = 2

# Freshness window for "this subagent is alive": its transcript was touched
# recently. Mirrors the mtime liveness test used elsewhere in this setup.
LIVE_WINDOW_S = 180

# Freshness window for a session-declared serial gate (see the shape B
# exemption below) -- longer than LIVE_WINDOW_S because a gate is declared
# once and then waited on, not refreshed every heartbeat.
SERIAL_GATE_WINDOW_S = 2700  # 45 minutes

# How recently the human must have TYPED for this session to count as attended.
# 15 minutes: on 2026-08-12 the user typed at 08:23 and 08:24 and the guard went
# on firing at 08:34, 08:35, 08:43 and 08:49, telling a person sitting at the
# keyboard that nobody was there. A window this size covers a working exchange
# while still letting a genuinely-departed session return to unattended rules.
ATTENDED_WINDOW_S = 900


def allow():
    """Let the turn end. The only safe default."""
    sys.exit(0)


if MODE == "off":
    allow()

# ATTENDED SESSIONS ARE NO LONGER EXEMPT (2026-08-11). This used to return here
# unless CCAGE_AUTONOMOUS was set, on the reasoning that "an attended session must
# never pay this cost". The user then caught an attended session sitting idle with
# five pending tasks and nothing watching -- the exact failure this file exists to
# catch, in the half of the world it had been switched off for. Scoping a fix to
# where the failures happened to be MEASURED left the other half uncovered.
#
# The two halves get different treatment, because the right behaviour differs:
#   * AUTONOMOUS: all four triggers, up to MAX_BLOCKS pushes. Nobody is watching,
#     so the guard is the only thing that can restart the work.
#   * ATTENDED: ONE trigger and ONE push -- open work with no stated reason for
#     stopping. Handing back to the user is legitimate and often correct; what is
#     not legitimate is going quiet, because silence reads identically whether the
#     turn is blocked or merely idle. So the remedy is cheap and always available:
#     say what you are waiting for. ASKED_USER already detects exactly that.
AUTONOMOUS = os.environ.get("CCAGE_AUTONOMOUS", "") in ("1", "true", "yes")

# ATTENDED OVERRIDE. ccage-auto sets the autonomous marker for the whole run, so
# a session the user is actively working in is still labelled autonomous and
# still pays guards whose stated premise is "there is nobody to prompt you to
# continue". On 2026-08-12 that premise was false while it fired: the user was
# typing throughout. The marker says how the run was LAUNCHED; whether a human
# is present right now is a different question, and answerable.
ATTENDED = False
if not AUTONOMOUS:
    MAX_BLOCKS = 1          # nudge once, never nag an attended user

try:
    p = json.loads(sys.argv[1])
except Exception:
    allow()

session_id = str(p.get("session_id") or "")
cwd = p.get("cwd") or ""
last_msg = p.get("last_assistant_message") or ""
if not session_id:
    allow()

# THE ANCHOR IS THE PROJECT, NEVER THE PAYLOAD'S cwd (2026-08-14). Every ground
# truth this hook consults -- the transcript, the subagent dir, the session
# scratchpad, RESUME -- is keyed on the project. `cwd` is NOT the project: it is
# "the current working directory when the hook is invoked" and it follows
# Claude's own `cd` (the docs ship a CwdChanged event for exactly that), while
# CLAUDE_PROJECT_DIR stays at the root. MEASURED from a subdirectory of this
# repo: payload cwd=/home/ff235/dev/ccage/tests while CLAUDE_PROJECT_DIR
# =/home/ff235/dev/ccage -- and both the transcript
# (<config>/projects/-home-ff235-dev-ccage/) and a background job started from
# that subdirectory (/tmp/claude-<uid>/-home-ff235-dev-ccage/) stayed under the
# PROJECT slug.
#
# So a single `cd` pointed every path below at a directory that does not exist,
# and each trigger then fails SILENTLY in the permissive direction: no transcript
# dir -> no live agents (shape B off), no tasks dir -> no background jobs, no
# RESUME -> no plan items, no typed-turn record -> an attended session read as
# unattended. A guard that switches itself off on `cd` is worse than no guard,
# because its silence is indistinguishable from a clean stop. Fall back to cwd
# only when the variable is absent, which is also what resume_autoload.sh does.
project = os.environ.get("CLAUDE_PROJECT_DIR") or cwd

config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
# Claude Code's on-disk project slug: EVERY non-alphanumeric becomes "-". One
# copy, computed once -- this rule had four local copies in this file, and the
# repo already paid for that once (28 macOS failures, 0.15.0, from a fifth copy
# that spelled the same rule differently).
slug = re.sub(r"[^A-Za-z0-9]", "-", project) if project else ""
state_dir = os.path.join(config, "stop_guard_state")
counter = os.path.join(state_dir, session_id + ".count")


def read_count():
    try:
        with open(counter) as f:
            return int(f.read().strip() or "0")
    except (OSError, ValueError):
        return 0


def write_count(n):
    try:
        os.makedirs(state_dir, exist_ok=True)
        with open(counter, "w") as f:
            f.write(str(n))
    except OSError:
        pass


# ---------------------------------------------------------------- shape B
# Ground truth: subagent transcripts under this session, touched recently.
def live_agents():
    sub = os.path.join(config, "projects", slug, session_id, "subagents")
    if not os.path.isdir(sub):
        return []
    now, live = time.time(), []
    try:
        for name in os.listdir(sub):
            if not (name.startswith("agent-") and name.endswith(".jsonl")):
                continue
            path = os.path.join(sub, name)
            try:
                if now - os.path.getmtime(path) <= LIVE_WINDOW_S:
                    live.append(name[len("agent-"):-len(".jsonl")])
            except OSError:
                continue
    except OSError:
        return []
    return live


def user_recently_typed():
    """True if the human typed into THIS session within ATTENDED_WINDOW_S.

    The distinction that makes this possible: a genuinely typed turn carries
    `origin: {"kind": "human"}` and `promptSource: "typed"`. Injected turns --
    hook feedback, teammate messages, system reminders, slash-command bodies --
    carry neither, and they all arrive as `type: "user"` records, which is why
    "was there a recent user message" is the wrong question. Measured on a real
    transcript 2026-08-13: ten typed turns all carried the marker, and all
    eighteen injected turns lacked it, with no overlap.
    """
    path = os.path.join(config, "projects", slug, session_id + ".jsonl")
    try:
        size = os.path.getsize(path)
    except OSError:
        return False
    try:
        with open(path, "rb") as f:                 # tail only; these get large
            f.seek(max(0, size - 400_000))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return False
    for line in reversed(lines):
        if '"kind": "human"' not in line and '"kind":"human"' not in line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("type") != "user":
            continue
        origin = row.get("origin") or {}
        if origin.get("kind") != "human":
            continue
        stamp = str(row.get("timestamp") or "")
        try:
            when = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        except ValueError:
            return False
        age = (datetime.datetime.now(datetime.timezone.utc) - when).total_seconds()
        return age <= ATTENDED_WINDOW_S
    return False


def serial_gate_active():
    """True if this session has a fresh marker declaring a serial wait.

    Same session dir as live_agents() -- both key on the shared project `slug`,
    just a different leaf file.
    """
    marker = os.path.join(config, "projects", slug, session_id, "serial-gate")
    try:
        return (time.time() - os.path.getmtime(marker)) <= SERIAL_GATE_WINDOW_S
    except OSError:
        return False


# Resolve the attended question now that the payload and the helpers both exist.
# Kept cheap: one tail read of this session's own transcript.
if AUTONOMOUS and user_recently_typed():
    ATTENDED = True
    MAX_BLOCKS = 1          # present user: nudge once, never nag

# ---------------------------------------------------------------- shape A
# Conservative: an explicit first-person commitment to a NEXT action. Deliberately
# does not try to catch every phrasing — a false block costs a wasted turn, and
# this half has no ground truth behind it.
COMMIT = re.compile(
    r"\b(?:"
    r"i(?:'| a)?m going to (?:now )?(?:start|run|build|write|check|fix|dispatch|look)"
    r"|i(?:'| wi)?ll (?:now |then )?(?:start|run|build|write|check|fix|dispatch|look|proceed)"
    r"|next(?:,| step| up)? i(?:'| wi)?ll"
    r"|let me (?:now )?(?:start|run|build|write|check|fix|dispatch)"
    r"|proceeding to"
    r"|moving on to"
    r")\b",
    re.I,
)
# If the turn ended by asking the user something, or by NAMING WHAT IT IS WAITING
# ON, stopping is CORRECT.
#
# MEASURED 2026-08-11: trigger 5 fired FIVE times in one conversation, and in
# three of those the message opened with "I am waiting on you for two things:" /
# "Waiting on you for one thing:". None matched. The old pattern accepted a
# trailing question mark or one of nine fixed phrasings — "waiting on your" hit,
# "waiting on you for" missed by one word — so the guard told the reader its
# message "does not say what you are waiting for" when what it had actually
# tested was "did not end in '?' and used none of nine wordings". A guard whose
# stated trigger and real trigger differ teaches that its reasons are noise, and
# keying on phrasing rather than fact is the failure D7 exists to stop.
#
# This trigger is irreducibly textual — "did this turn hand a decision back?" has
# no mechanical ground truth the way a live subagent or a file size does. So the
# pattern is widened to the ways a person actually writes it, and, more
# importantly, trigger 5's message below now states what it really checked.
ASKED_USER = re.compile(
    r"(?:\?\s*$)"
    r"|\b(?:which do you want|your call|let me know|want me to|shall i|"
    r"should i|do you want|confirm before)\b"
    # Naming the blocker, in the forms people actually use.
    r"|\bwaiting (?:on|for)\b"
    r"|\bblocked (?:on|by)\b"
    r"|\bneeds? your\b"
    r"|\byour (?:go-?ahead|approval|decision|answer|sign-?off)\b"
    r"|\b(?:say|just say) (?:go|the word)\b"
    r"|\bcan(?:no|')t proceed\b"
    r"|\bawaiting\b",
    re.I,
)

# ------------------------------------------------------- trigger 4 (issue 4)
# Open plan items. Source of truth is RESUME's `### Plan` section — the same
# section resume_autoload.sh reads, and the one /checkpoint records the GOVERNING
# doc into. Reuse that contract rather than guessing plan filenames.
CLAIMS_DONE = re.compile(
    r"\b(?:all (?:tasks?|items?|steps?|work) (?:are |is )?(?:now )?(?:complete|done|finished)"
    r"|(?:the )?plan is (?:now )?(?:complete|done|fully implemented)"
    r"|everything (?:is )?(?:now )?(?:complete|done|finished)"
    r"|implementation (?:is )?complete"
    r"|nothing (?:else |further )?(?:is )?(?:left|remaining|outstanding))\b",
    re.I,
)


def plan_open_items():
    """(open_count, plan_path) for the governing plan, or (0, None).

    Counts unticked `- [ ]` boxes. A plan with NO checkboxes at all returns
    (0, path) — it is unstructured, so its completion is UNVERIFIABLE, and this
    guard must not manufacture a verdict from silence. That case is reported by
    the session-start autoloader, not blocked here."""
    # SLOT-AWARE, or the contract in the comment above is a lie. A slotted
    # session (CCAGE_SLOT) owns RESUME.<slot>.md, so reading the plain file
    # counts ANOTHER workstream's checkboxes: a false block on items that are
    # not yours, and a false pass while yours are open. Validation MIRRORS
    # resume_autoload.sh:60-69 (and agent_reaper's record()): an unsafe slot is
    # IGNORED and we fall back to the plain file, so a slot can never become a
    # path component. Keep the three in step if any of them changes.
    slot = os.environ.get("CCAGE_SLOT", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", slot or ""):
        slot = ""
    name = "RESUME.%s.md" % slot if slot else "RESUME.md"
    resume = os.path.join(project, name) if project else ""
    if not resume or not os.path.isfile(resume):
        return 0, None
    try:
        with open(resume, errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return 0, None
    refs, inplan = [], False
    for ln in lines:
        if re.match(r"^###\s+Plan\s*$", ln):
            inplan = True
            continue
        if inplan and ln.startswith("##"):
            break
        if inplan:
            refs += re.findall(r"[~/A-Za-z0-9._-][A-Za-z0-9._/~-]*\.md", ln)
    for ref in refs[:5]:
        path = os.path.expanduser(ref) if ref.startswith("~/") else ref
        if not os.path.isabs(path):
            path = os.path.join(project, path)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, errors="replace") as f:
                body = f.read()
        except OSError:
            continue
        open_n = len(re.findall(r"^\s*-\s*\[ \]", body, re.M))
        if open_n:
            return open_n, path
    return 0, None


# ------------------------------------------------------- trigger 3 (issue 5)
# A promise of later notification with no watcher armed. Inert until ccage-watch
# exists — blocking on an unbuildable remedy would just burn the counter.
PROMISED_LATER = re.compile(
    r"\b(?:i(?:'| wi)?ll (?:let you know|notify you|tell you|report back)"
    r"|you(?:'| wi)?ll (?:get|receive) (?:a )?notif"
    r"|(?:it|this|the job|the run) (?:is |keeps )?running in the background"
    r"|i(?:'| wi)?ll check back)\b",
    re.I,
)


def watcher_armed():
    import glob
    return bool(glob.glob(os.path.join(config, "watch", "*.json")))


def ccage_watch_available():
    for d in os.environ.get("PATH", "").split(os.pathsep):
        cand = os.path.join(d, "ccage-watch")
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return True
    return False


# The harness keys its scratch dirs on the session id the PROCESS launched
# with, exported as CLAUDE_CODE_SESSION_ID; /clear rotates the transcript's
# session_id but not this one. MEASURED 2026-08-16: transcript ad2baf5d wrote
# every background job under 425d989b/tasks, so keying on the payload id read
# a directory that never existed and reported "no jobs" for a 14-hour run.
def launch_session_id():
    return os.environ.get("CLAUDE_CODE_SESSION_ID") or session_id


# THE TWO SCRATCH DIRS ARE KEYED DIFFERENTLY, AND ASSUMING OTHERWISE IS THE
# SAME BUG AGAIN (measured 2026-08-16, on the session this whole design came
# from). Under /tmp/claude-<uid>/<slug>/:
#   <LAUNCH id>/tasks/       harness background jobs   -- process-lifetime key
#   <CURRENT id>/scratchpad/ the session's own files   -- rotates on /clear
# On the 2026-08-15 session: tasks/ existed ONLY under 425d989b (the launch
# id), while the scratchpad holding flow_entry_rule_v2.log -- the detached run
# that landed at 23:48 with nobody to read it -- was under ad2baf5d (the
# current id). 425d989b's own scratchpad held only files from its own working
# period, hours stale. Reading the launch scratchpad therefore misses exactly
# the log this feature exists to notice, and misses it SILENTLY.
def _scratch_root(sid):
    return os.path.join(tempfile.gettempdir(), "claude-%d" % os.getuid(),
                        slug, sid)


# An orphan from a long-dead run must not resurrect: the exit marker decides
# liveness, and this only stops an ancient unmarked file counting forever.
STALE_JOB_S = 86400
# Cap the snapshot so a scratchpad full of artifacts cannot bloat the record.
MAX_SNAPSHOT = 200


def live_background_jobs():
    """Background Bash jobs this session started that have not reported an exit.

    Correction B (2026-08-10) asked for a FACT -- "a background job is running
    and no watcher is armed" -- and what shipped keyed on a promise PHRASE
    instead, so a turn that ends silently over a live job fired nothing. That is
    a D7 violation inside the guard family that produced D7, and it was recorded
    as a known limit on 2026-08-13 rather than fixed. This is the fix.

    The fact is on disk: the harness writes each backgrounded job to
    <scratchpad>/tasks/<id>.output and appends a literal `[exited with code N]`
    when it finishes. Fail-open: no tasks dir, or an unreadable one, returns []
    -- an unmeasurable condition must never manufacture a block."""
    tasks = os.path.join(_scratch_root(launch_session_id()), "tasks")
    live, now = [], time.time()
    try:
        names = os.listdir(tasks)
    except OSError:
        return []
    for name in names:
        if not name.endswith(".output"):
            continue
        path = os.path.join(tasks, name)
        try:
            if now - os.path.getmtime(path) > STALE_JOB_S:
                continue
            # The harness appends `[exited with code N]` when a job really
            # ends. That marker is the signal; mtime is not. A 180s freshness
            # window called a quiet-but-running job finished, which is how a
            # live sweep read as "nothing running" on 2026-08-15.
            with open(path, errors="replace") as f:
                if "[exited with code" not in f.read()[-400:]:
                    live.append(name[:-len(".output")])
        except OSError:
            continue
    return live


def detached_logs():
    """(path, size) for everything under this session's scratchpad.

    A `setsid nohup … > log` job — this project's normal pattern for a long
    run — creates no tasks/*.output at all, so the harness records nothing
    about it. Growth between two samples is the only available evidence, and
    two samples need two moments: this hook takes one, ccage-auto compares.
    Fail-open: an unreadable scratchpad returns [] and nothing is claimed."""
    out = []
    sp = os.path.join(_scratch_root(session_id), "scratchpad")
    try:
        names = sorted(os.listdir(sp))[:MAX_SNAPSHOT]
    except OSError:
        return []
    for name in names:
        p = os.path.join(sp, name)
        try:
            st = os.stat(p)
        except OSError:
            continue
        if st.st_size and not os.path.isdir(p):
            out.append((p, st.st_size))
    return out


# ------------------------------------------------------- trigger 5 (attended)
# Tasks still open. The task list is NOT persisted anywhere readable (the
# tasks/ dirs are empty), so reconstruct it from this session's own transcript:
# TaskCreate results carry "Task #N created", TaskUpdate inputs carry the status
# changes. Last status wins; anything never updated is still pending.
def open_task_count():
    path = os.path.join(config, "projects", slug, session_id + ".jsonl")
    if not os.path.isfile(path):
        return 0
    created, status = set(), {}
    try:
        with open(path, errors="replace") as f:
            for line in f:
                if "Task" not in line:
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                content = row.get("message", {}).get("content")
                if not isinstance(content, list):
                    continue
                for c in content:
                    if not isinstance(c, dict):
                        continue
                    if c.get("type") == "tool_use" and c.get("name") == "TaskUpdate":
                        inp = c.get("input") or {}
                        if inp.get("taskId") and inp.get("status"):
                            status[str(inp["taskId"])] = str(inp["status"])
                    elif c.get("type") == "tool_result":
                        for m in re.finditer(r"Task #(\d+) created",
                                             json.dumps(c.get("content"))):
                            created.add(m.group(1))
    except OSError:
        return 0
    return sum(1 for t in created
               if status.get(t, "pending") in ("pending", "in_progress"))


tail = last_msg[-1200:] if last_msg else ""
asked = bool(ASKED_USER.search(tail))
committed = bool(COMMIT.search(tail)) and not asked
agents = live_agents()

reason = None
open_items, plan_path = (plan_open_items() if CLAIMS_DONE.search(tail) else (0, None))
open_tasks = 0


if open_items and not asked:
    # Ground truth beats a claim: the plan on disk says otherwise.
    reason = (
        "Your final message claims the work is complete, but the governing plan "
        "(%s) still has %d unticked item(s).\n"
        "DO NOW: either do them, or tick them off with the evidence that they are "
        "done, or state explicitly which are deferred and why — a deferral declared "
        "out loud is fine; a silently dropped item is the failure this exists to "
        "catch. Then stopping is correct and this will allow it.\n"
        "EVIDENCE, not recollection: run the verification command and show its "
        "output before ticking anything (`verification-before-completion` skill). "
        "Five shipped bugs got past tests their own author called green."
        % (os.path.basename(plan_path), open_items)
    )
# SHAPE B EXEMPTION, serial gate. MEASURED 2026-08-12: this trigger fired
# EIGHT times in one session while it was correctly sitting out a
# deliberately SERIAL evidence gate -- a research-report gate whose whole
# design forbids drafting until it closes. That is a legitimate reason to
# idle, not the failure this file exists to catch, and ground truth alone
# (live subagent transcripts) cannot tell the two apart -- both look like
# "subagents running, root doing nothing." The repeated pressure contributed
# to a rushed draft.
#
# So shape B can be told, out loud, "this wait is serial by design": touch
# <config>/projects/<slug>/<session_id>/serial-gate and this trigger stands
# down for SERIAL_GATE_WINDOW_S. Freshness-gated for the same reason
# LIVE_WINDOW_S is -- an un-refreshed marker from a wait that is long over
# must decay back to the default behaviour, not sit there disabling the
# guard forever.
elif agents and not asked and not serial_gate_active() and not ATTENDED:
    reason = (
        "You are ending this turn with %d subagent(s) still running (%s) during an "
        "AUTONOMOUS run, and your final message contains no work of your own.\n"
        "Their completion will re-invoke you, so this is not a deadlock — it is a "
        "SERIALISATION: the window while they work is being spent idle, turning a "
        "parallel plan into a sequential one.\n"
        "DO NOW: identify work that does NOT depend on their output and do it. If "
        "there genuinely is none, say so explicitly, naming what each worker must "
        "return before you can proceed — then stopping is correct and this will "
        "allow it." % (len(agents), ", ".join(agents[:4]))
    )
elif ((PROMISED_LATER.search(tail) or live_background_jobs())
        and not watcher_armed() and ccage_watch_available()):
    # Issue 5 is inert without this: a watcher that survives the session is
    # useless if the session never arms one, and arming is exactly the kind of
    # judgment call that has failed every time it was left to judgment.
    #
    # TWO WAYS IN, and the second is the one Correction B actually asked for.
    # The phrase match catches a stated promise; `live_background_jobs()` catches
    # the FACT, so a turn that ends silently over a running job no longer slips
    # through. Keying only on wording is the D7 failure both foreground guards
    # were walked past on — recorded as a known limit 2026-08-13, fixed here.
    _jobs = live_background_jobs()
    reason = (
        "You are ending this turn with %s, and NO watcher is armed.\n"
        "Measured: an in-harness background watcher is killed 50-131s after the "
        "session ends, so anything you are counting on to finish afterwards "
        "silently evaporates and the user returns hours later to nothing.\n"
        "DO NOW: arm one — `ccage-watch arm --cond '<cmd, exit 0 = done>' --note "
        "'<what this bridges>'` — which survives the session and writes the outcome "
        "into RESUME for the next one. Or withdraw the promise and record the "
        "handoff in RESUME '### Next' yourself. Do not leave it implicit."
        % ("%d background job(s) still running (%s)"
           % (len(_jobs), ", ".join(_jobs[:3])) if _jobs
           else "a promise that something happens after this turn")
    )
elif committed:
    # The rationale must match the mode it is delivered in. This trigger fires in
    # BOTH (2026-08-11), but the text said "during an autonomous run there is
    # nobody to prompt you to continue" — plainly false when a user is sitting
    # there, and a guard that states something the reader can see is untrue
    # teaches that its reasons are boilerplate. Caught by the one test that still
    # asserted the pre-2026-08-11 behaviour, which is itself the tell.
    why = ("During an autonomous run there is nobody to prompt you to continue."
           if AUTONOMOUS else
           "Stating an action and then stopping leaves the user to re-ask for "
           "what you already said you would do.")
    reason = (
        "Your final message states an action you were about to take, and then the "
        f"turn ended without taking it. {why}\n"
        "DO NOW: take that action. If it turns out to be blocked, say what blocks it "
        "— an external dependency, not a question you could answer from the plan — "
        "and then stopping is correct and this will allow it."
    )

# ---------------------------------------------- trigger 5: OPEN WORK, BOTH MODES
# Added 2026-08-11 after a stop that NONE of the four triggers above could see.
# The session had five pending tasks and ended quietly. Triggers 1-4 look at plan
# checkboxes, live subagents, unarmed promises and stated-then-dropped intentions
# — the TASK LIST was not among them, so there was nothing to fire.
#
# Corrects a wrong diagnosis worth recording: the first attempt blamed the
# CCAGE_AUTONOMOUS gate and put this check on the attended branch only. But that
# session HAD the marker set (ccage-auto exports it), so the gate was never the
# cause and the fix would have missed the very case that prompted it. Verified by
# reading the running process's environment rather than reasoning about it.
# ⇒ This trigger is deliberately mode-independent. Open work is open work.
if reason is None:
    open_tasks = open_task_count()
    if open_tasks and not asked:
        reason = (
            "You are ending the turn with %d task(s) still open, and nothing in "
            "your final message matched a question or a phrase naming what you are "
            "waiting on.\n"
            "That is a TEXT MATCH, not a judgment: if you did name a blocker and "
            "this still fired, the pattern missed it — say so plainly and stop, "
            "rather than rewording the same message until it passes.\n"
            "Otherwise, whichever is true: continue with the next open task, OR "
            "name the one thing you are waiting on (a decision, an approval, an "
            "external result)."
            % open_tasks
        )

# ------------------------------------------- trigger 6: WORK CI HAS NEVER SEEN
# MEASURED 2026-08-13: this branch reached 24 commits ahead of main with ZERO CI
# runs; the first push turned the macOS leg red with 28 failures, none of them
# new — every one latent since the day it was written. Local verification here is
# Linux-only, so the whole BSD/bash-3.2 class is invisible until a push happens,
# and nothing prompted the push. The rule already existed in the handoff plan
# ("Linux locally, then macOS via the branch's CI leg before merge") and 23
# commits went past it, which per D12 means it needs a mechanical shadow.
#
# DELIBERATELY HIGH THRESHOLD, and last in the chain. A per-turn nag on ordinary
# work-in-progress is the failure mode that killed the fan-out-size gate (issue
# 13(b)): it fired on a quarter of correct work and taught its own dismissal. Ten
# unpushed commits on a branch whose repo runs CI is not ordinary WIP — it is a
# backlog of unverified work, and it fires at most MAX_BLOCKS times per session.
def unpushed_vs_ci():
    """(count, branch) of commits the remote has never seen, or (0, None).

    Fail-open everywhere: not a repo, no upstream, no CI config, git missing or
    slow -> (0, None). An unmeasurable condition must not manufacture a block."""
    if not project or not os.path.isdir(os.path.join(project, ".git")):
        return 0, None
    wf = os.path.join(project, ".github", "workflows")
    try:
        if not any(f.endswith((".yml", ".yaml")) for f in os.listdir(wf)):
            return 0, None
    except OSError:
        return 0, None                      # no CI configured: nothing to miss
    def git(*a):
        try:
            p = subprocess.run(("git", "-C", project) + a, capture_output=True,
                               text=True, timeout=5)
            return p.stdout.strip() if p.returncode == 0 else ""
        except Exception:
            return ""
    branch = git("rev-parse", "--abbrev-ref", "HEAD")
    if not branch or branch == "HEAD":
        return 0, None
    # @{u} is the branch's own upstream; absent for a never-pushed branch, in
    # which case every commit since the default branch is unseen.
    n = git("rev-list", "--count", "@{u}..HEAD") or git(
        "rev-list", "--count", "origin/main..HEAD")
    try:
        return int(n), branch
    except ValueError:
        return 0, None


if reason is None and not asked:
    _n, _branch = unpushed_vs_ci()
    if _n >= int(os.environ.get("CCLAUDE_UNPUSHED_MAX", "10")):
        reason = (
            "%d commits on `%s` have never been pushed, so CI has never run on any "
            "of them.\n"
            "Measured on this machine: a branch reached 24 unpushed commits and the "
            "first CI run went red with 28 failures — none new, all latent since the "
            "day they were written. Local runs here are Linux-only, so every "
            "macOS/BSD defect is invisible until a push.\n"
            "DO NOW: push the branch (a draft PR is enough — it only needs to run "
            "CI, not to be reviewed). If this work is deliberately unpublished, say "
            "so and stopping is correct." % (_n, _branch)
        )

if reason is None:
    write_count(0)          # clean stop: reset the streak
    allow()

count = read_count()
if count >= MAX_BLOCKS:
    # Yield, and STAY yielded. Do NOT reset here: resetting on yield produces a
    # block/block/allow CYCLE that can still pin a session in a loop indefinitely
    # (measured 2026-08-10 — attempt 4 blocked again). The streak is cleared only
    # by a clean stop above, which is the genuine signal that progress resumed.
    allow()

log = os.path.join(config, "stop_continuation_guard.log")
try:
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
    if open_tasks:
        kind = "OPEN_WORK_UNDECLARED"
    elif open_items:
        kind = "PLAN_ITEMS_OPEN"
    elif agents:
        kind = "AGENTS_IDLE"
    elif committed:
        kind = "UNKEPT_INTENT"
    else:
        kind = "UNARMED_PROMISE"
    line = "%s %s %s n=%d agents=%d: %s" % (
        stamp, MODE.upper(), kind, count + 1, len(agents),
        tail[-160:].replace("\n", " "))
    prev = open(log).read().splitlines()[-499:] if os.path.exists(log) else []
    open(log, "w").write("\n".join(prev + [line]) + "\n")
except OSError:
    pass

if MODE != "enforce":
    allow()

write_count(count + 1)
print(json.dumps({"decision": "block", "reason": reason}))
sys.exit(0)
PY
