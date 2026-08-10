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

# Autonomous runs only. An attended session must never pay this cost.
if os.environ.get("CCAGE_AUTONOMOUS", "") not in ("1", "true", "yes"):
    allow()

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


tail = last_msg[-1200:] if last_msg else ""
asked = bool(ASKED_USER.search(tail))
committed = bool(COMMIT.search(tail)) and not asked
agents = live_agents()

reason = None
open_items, plan_path = (plan_open_items() if CLAIMS_DONE.search(tail) else (0, None))

if open_items and not asked:
    # Ground truth beats a claim: the plan on disk says otherwise.
    reason = (
        "Your final message claims the work is complete, but the governing plan "
        "(%s) still has %d unticked item(s).\n"
        "DO NOW: either do them, or tick them off with the evidence that they are "
        "done, or state explicitly which are deferred and why — a deferral declared "
        "out loud is fine; a silently dropped item is the failure this exists to "
        "catch. Then stopping is correct and this will allow it."
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
    reason = (
        "Your final message states an action you were about to take, and then the "
        "turn ended without taking it. During an autonomous run there is nobody to "
        "prompt you to continue.\n"
        "DO NOW: take that action. If it turns out to be blocked, say what blocks it "
        "— an external dependency, not a question you could answer from the plan — "
        "and then stopping is correct and this will allow it."
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
    if open_items:
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
