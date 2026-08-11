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
import json
import os
import re
import sys
import time

MODE = os.environ.get("CCLAUDE_STOPGUARD_MODE", "enforce")
try:
    MAX_BLOCKS = int(os.environ.get("CCLAUDE_STOPGUARD_MAX", "2"))
except ValueError:
    MAX_BLOCKS = 2

# Freshness window for "this subagent is alive": its transcript was touched
# recently. Mirrors the mtime liveness test used elsewhere in this setup.
LIVE_WINDOW_S = 180


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

config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
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
    slug = re.sub(r"[^A-Za-z0-9]", "-", cwd) if cwd else ""
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
# If the turn ended by asking the user something, stopping is CORRECT.
ASKED_USER = re.compile(
    r"(?:\?\s*$)|\b(?:which do you want|your call|let me know|want me to|shall i|"
    r"should i|do you want|confirm before|waiting on your)\b",
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
    resume = os.path.join(cwd, "RESUME.md") if cwd else ""
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
            path = os.path.join(cwd, path)
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


# ------------------------------------------------------- trigger 5 (attended)
# Tasks still open. The task list is NOT persisted anywhere readable (the
# tasks/ dirs are empty), so reconstruct it from this session's own transcript:
# TaskCreate results carry "Task #N created", TaskUpdate inputs carry the status
# changes. Last status wins; anything never updated is still pending.
def open_task_count():
    slug = re.sub(r"[^A-Za-z0-9]", "-", cwd) if cwd else ""
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
elif agents and not asked:
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
elif (PROMISED_LATER.search(tail) and not watcher_armed()
        and ccage_watch_available()):
    # Issue 5 is inert without this: a watcher that survives the session is
    # useless if the session never arms one, and arming is exactly the kind of
    # judgment call that has failed every time it was left to judgment.
    reason = (
        "Your final message promises something will happen after this turn — a "
        "notification, a job continuing — but NO watcher is armed.\n"
        "Measured: an in-harness background watcher is killed 50-131s after the "
        "session ends, so that promise silently evaporates and the user returns "
        "hours later to nothing.\n"
        "DO NOW: arm one — `ccage-watch arm --cond '<cmd, exit 0 = done>' --note "
        "'<what this bridges>'` — which survives the session and writes the outcome "
        "into RESUME for the next one. Or withdraw the promise and record the "
        "handoff in RESUME '### Next' yourself. Do not leave it implicit."
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
            "You are ending the turn with %d task(s) still open, and your final "
            "message does not say what you are waiting for.\n"
            "Stopping may well be right — handing back is often correct. But going "
            "quiet is not: silence looks identical whether you are blocked or idle, "
            "and the reader has to guess which.\n"
            "DO NOW, whichever is true: continue with the next open task, OR name "
            "the one thing you are waiting on (a decision, an approval, an external "
            "result). Either ends the turn cleanly."
            % open_tasks
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
