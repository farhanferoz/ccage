"""Stuck-subagent detection for ccage-auto (circuit breaker v2).

Pure logic only: no pty, no threads. bin/ccage-auto owns wiring.
"""
import dataclasses
import fcntl
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from lib.ccb_types import ActionKind, AgentPhase, AgentRecord, CCBConfig, EventKind, TaskStatus, Tier, tier_allows


def list_subagent_transcripts(session_dir: Path) -> list[Path]:
    """Every subagent transcript under session_dir/subagents/."""
    sub_dir = session_dir / "subagents"
    if not sub_dir.is_dir():
        return []
    return sorted(sub_dir.glob("agent-*.jsonl"))


@dataclass(frozen=True)
class AgentMeta:
    teammate_id: str
    team_name: str | None


_ID_DISALLOWED = re.compile(r"[^A-Za-z0-9._-]")


def _sanitize_id(raw: str, limit: int = 80) -> str:
    """teammate_id is UNTRUSTED — it comes from a subagent's .meta.json, which can
    carry model-/tool-generated content — and flows into two sinks: RESUME.md
    (auto-injected into the next session's context by the SessionStart hook) and
    the orchestrator's pty nudge. Restrict it to the identifier charset the Agent
    tooling actually emits ([A-Za-z0-9._-]): this strips newlines/control bytes
    (RESUME-line forge, pty control sequences) AND shell/markdown/quote
    metacharacters, then caps the length. Legitimate ids are unchanged, so
    vouch/completion matching against the raw transcript markers is unaffected."""
    return _ID_DISALLOWED.sub("", raw)[:limit]


def agent_meta(transcript: Path) -> AgentMeta:
    """Authoritative identity from <agent>.meta.json (V11). The transcript
    filename encodes a DIFFERENT string than the real teammate id — never
    parse it. Fallback (meta missing/corrupt): the stem, which at least
    dedupes consistently even if it can't match vouch/completion signals.
    The id is sanitized at this trust boundary (untrusted meta content).
    """
    try:
        m = json.loads(transcript.with_suffix(".meta.json").read_text())
        name = m.get("name")
        if isinstance(name, str) and name:
            return AgentMeta(teammate_id=_sanitize_id(name), team_name=m.get("teamName") or None)
    except (OSError, ValueError):
        pass
    return AgentMeta(teammate_id=_sanitize_id(transcript.stem), team_name=None)


_TEAMMATE_MSG = re.compile(r'<teammate-message[^>]*\bteammate_id=\\?"([^"\\]+)\\?"')
_VOUCH = re.compile(r"CCB-VOUCH\s+agent=([\w-]+)\s+extend=(\d+)")
# Task 14: the orchestrator's acknowledgement that it stopped a teammate. S2:
# a TaskStopped teammate leaves NO distinct on-disk terminal marker (its
# transcript ends like a normal finish), so this reply marker is the only
# reliable stop-verification signal. Same keying/escaping as _VOUCH.
_STOPPED = re.compile(r"CCB-STOPPED\s+agent=([\w-]+)")
# Task 4b: teammate completion comes from the in-band idle_notification (S4:
# the signal is written to the PARENT transcript, NOT a hook feed-file). Quotes
# are JSON-escaped on disk, so \\? mirrors the _TEAMMATE_MSG fix. Verified to
# capture real teammates (cb-phase1, cb-spike-stop) from the live transcript.
_IDLE = re.compile(
    r'idle_notification\\?"\s*,\s*\\?"from\\?"\s*:\s*\\?"([^"\\]+)\\?"'
    r'\s*,\s*\\?"timestamp\\?"\s*:\s*\\?"([^"\\]+)\\?"')


@dataclass
class ParentScan:
    offset: int = 0
    msg_counts: dict[str, int] = field(default_factory=dict)  # liveness (V6: NOT completion)
    vouches: dict[str, int] = field(default_factory=dict)     # cumulative minutes
    idle: dict[str, float] = field(default_factory=dict)      # teammate -> latest idle epoch (Task 4b/S4)
    stopped: dict[str, int] = field(default_factory=dict)     # teammate -> 1 once CCB-STOPPED seen (Task 14)


def scan_parent_transcript(path: Path, prev: ParentScan) -> ParentScan:
    """Resume scanning at prev.offset; consume only complete lines.

    Extracts teammate-message counts (liveness only — these recur through an
    agent's life, V6) and CCB-VOUCH markers from raw line text — regex over
    the line, not JSON traversal, so nested content shapes can't hide a
    marker. Torn final lines are left for the next poll (offset advances
    only past a trailing newline).
    """
    out = ParentScan(prev.offset, dict(prev.msg_counts), dict(prev.vouches),
                     dict(prev.idle), dict(prev.stopped))
    try:
        with path.open("rb") as f:
            f.seek(out.offset)
            while True:
                line = f.readline()
                if not line:
                    break
                if not line.endswith(b"\n"):
                    break  # torn write — re-read next poll
                out.offset += len(line)
                text = line.decode("utf-8", errors="replace")
                for m in _TEAMMATE_MSG.finditer(text):
                    out.msg_counts[m.group(1)] = out.msg_counts.get(m.group(1), 0) + 1
                for m in _VOUCH.finditer(text):
                    out.vouches[m.group(1)] = out.vouches.get(m.group(1), 0) + int(m.group(2))
                for m in _STOPPED.finditer(text):
                    out.stopped[m.group(1)] = 1
                for m in _IDLE.finditer(text):
                    try:
                        epoch = _parse_iso(m.group(2)).timestamp()
                    except (ValueError, TypeError, OverflowError, AttributeError):
                        continue  # unparseable ts: skip, never crash the scan
                    name = m.group(1)
                    if epoch > out.idle.get(name, 0.0):
                        out.idle[name] = epoch
    except OSError:
        pass  # transcript rotated/missing: keep previous state, retry next poll
    return out


def idle_completed(idle_epoch: float | None, transcript_mtime: float | None) -> bool:
    """Task 4b completion predicate, from the S4-verified in-band idle signal.
    A teammate is complete when it emitted an idle_notification AND has not
    written to its transcript since — renewed writes after idle mean it resumed,
    so completion is REVERSIBLE and can never permanently blind the breaker (V6).
    Both signals required; either missing => not complete (fail-safe: keep
    watching)."""
    if idle_epoch is None or transcript_mtime is None:
        return False
    return transcript_mtime <= idle_epoch


def _parse_iso(ts: str) -> datetime:
    """Parse an ISO timestamp that may use a literal 'Z' suffix, and
    guarantee the result is timezone-aware (assume UTC if unspecified) so
    subtracting two of these never raises on naive/aware mismatch.
    """
    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def elapsed_seconds(path: Path, now_iso: str) -> int | None:
    """Seconds between the first line's timestamp and now_iso.

    Returns None (never raises) if the file is empty or its first line
    isn't valid JSON yet — a real race between file creation and the first
    write landing, not a hypothetical.
    """
    try:
        with path.open() as f:
            first_line = f.readline()
    except OSError:
        return None  # glob-then-open race: transcript vanished/became unreadable
    if not first_line.strip():
        return None
    try:
        first = json.loads(first_line)
        first_ts = _parse_iso(first["timestamp"])
    except (json.JSONDecodeError, KeyError, ValueError):
        return None
    now = _parse_iso(now_iso)
    return int((now - first_ts).total_seconds())


def stale_minutes(path: Path, now: float) -> float | None:
    """Minutes since the transcript was last written; None if unreadable."""
    try:
        return (now - path.stat().st_mtime) / 60.0
    except OSError:
        return None


_OPEN_STATUSES = {TaskStatus.PENDING, TaskStatus.IN_PROGRESS, TaskStatus.UNKNOWN}


def _task_dir(config_root: Path, session_id: str, team_name: str | None = None) -> Path | None:
    """Prefer the meta.json teamName (V11 — the ONLY reliable mapping; the
    incident session's team dir 'session-cc9d022f' is NOT derivable from its
    session UUID 1e0c8efe…). UUID-shaped fallbacks cover non-team sessions."""
    cands = []
    if team_name:
        cands.append(config_root / "tasks" / team_name)
    cands += [config_root / "tasks" / session_id,
              config_root / "tasks" / f"session-{session_id[:8]}"]
    for cand in cands:
        if cand.is_dir():
            return cand
    return None


def open_task_count(config_root: Path, session_id: str, team_name: str | None = None) -> int | None:
    """Open tasks for this session; None if no task dir exists (not a teams session).

    Presence proves nothing (completed files persist on disk — V4); only the
    status field decides. Unreadable files count as open (fail-open).
    """
    d = _task_dir(config_root, session_id, team_name)
    if d is None:
        return None
    n = 0
    for p in d.glob("*.json"):
        try:
            status = TaskStatus(json.loads(p.read_text()).get("status", ""))
        except (OSError, ValueError):
            status = TaskStatus.UNKNOWN
        if status in _OPEN_STATUSES:
            n += 1
    return n


def session_cost_usd(session_id: str, tokenol_base_url: str) -> float | None:
    """Whole-session cost (parent + ALL subagents merged) — tokenol cannot
    scope to one subagent (V3). Annotation only; never a per-agent decision
    input.

    Returns None (never raises) if tokenol's serve isn't running, the
    session isn't found, or the response isn't shaped as expected — the
    watcher must degrade to time-only detection rather than crash when
    tokenol is unavailable or returns something unexpected.
    """
    url = f"{tokenol_base_url}/api/session/{session_id}"
    try:
        with urllib.request.urlopen(url, timeout=3) as resp:
            data = json.loads(resp.read())
        if not isinstance(data, dict):
            return None
        totals = data.get("totals")
        return totals.get("cost_usd") if isinstance(totals, dict) else None
    except (urllib.error.URLError, TimeoutError, ValueError, KeyError, AttributeError):
        return None


@dataclass(frozen=True)
class Observation:
    elapsed_min: float
    stale_min: float
    completed: bool          # Task 4b's completion-feed predicate — reversible, never fully trusted (V6)
    vouch_total_min: int     # cumulative vouched minutes for this agent
    now: float               # epoch seconds
    stopped: bool = False    # Task 14: CCB-STOPPED marker seen (verified stop) — terminal, non-reversible


@dataclass(frozen=True)
class Action:
    kind: ActionKind
    agent: AgentRecord


_DEBOUNCE_TICKS = 2  # consecutive breach polls required before the first tier step (Section 1)


def _in_breach(o: Observation, cfg: CCBConfig, extension_min: int) -> bool:
    # A vouch extends BOTH floors (review #5): a vouched agent must be
    # protected in the quiet-stuck mode too, not just the churn mode.
    quiet_stuck = (o.elapsed_min > cfg.t_soft_min + extension_min
                   and o.stale_min > cfg.t_stale_min)
    churn_stuck = o.elapsed_min > cfg.t_hard_min + extension_min
    return quiet_stuck or churn_stuck


def evaluate(rec: AgentRecord, o: Observation, cfg: CCBConfig) -> tuple[AgentRecord, list[Action]]:
    """One poll tick for one agent. Pure: no I/O, no clock reads.

    Invariants (tested above):
      - completion always wins, emits nothing — and is REVERSIBLE (a cleared
        completion signal returns the agent to watch; V6);
      - at most ONE tier step per tick;
      - debounce: 2 consecutive breach ticks before the first step;
      - one alert per breach episode (rec.alerted; reset on de-escalation);
      - a vouch (below cap) always de-escalates to VOUCHED, and VOUCHED
        re-enters detection like RUNNING (no trap state);
      - a breach that clears on its own de-escalates SUSPECT, NUDGED, and
        STOP_REQUESTED (a recovered agent is never escalated);
      - nothing above cfg.max_tier is ever emitted.
    """
    rec = dataclasses.replace(rec)
    actions: list[Action] = []

    # Completion OR a verified stop resolves from ANY phase and emits nothing.
    # A verified stop (o.stopped, Task 14) differs from completion in one way:
    # it is terminal, not reversible — S2 confirmed TaskStop ends the teammate's
    # turn, and the CCB-STOPPED marker is cumulative in the scan, so o.stopped
    # stays True and RESOLVED never reverts. Completion alone (idle signal) can
    # still clear and return the agent to watch below (V6).
    if o.completed or o.stopped:
        rec.phase = AgentPhase.RESOLVED
        rec.breach_ticks, rec.alerted = 0, False
        return rec, actions
    if rec.phase is AgentPhase.RESOLVED:
        rec.phase = AgentPhase.RUNNING       # signal cleared: back under watch
        rec.phase_changed_at = o.now
        return rec, actions

    # Vouch handling: a new vouch (total grew) below the cap de-escalates.
    if o.vouch_total_min > rec.extension_min and rec.phase in (
        AgentPhase.SUSPECT, AgentPhase.NUDGED, AgentPhase.STOP_REQUESTED
    ):
        if rec.vouches_used < cfg.max_vouches:
            rec.vouches_used += 1
            rec.extension_min = o.vouch_total_min
            rec.phase = AgentPhase.VOUCHED
            rec.breach_ticks, rec.alerted = 0, False
            rec.phase_changed_at = o.now
            return rec, actions
        # cap hit: swallow the vouch, stay on the ladder

    breach = _in_breach(o, cfg, rec.extension_min)

    if rec.phase in (AgentPhase.RUNNING, AgentPhase.VOUCHED):
        if breach:                            # VOUCHED re-detects too (review #3)
            rec.phase = AgentPhase.SUSPECT
            rec.breach_ticks = 1
            rec.phase_changed_at = o.now
        else:
            rec.breach_ticks = 0
        return rec, actions

    if rec.phase is AgentPhase.SUSPECT:
        if not breach:
            rec.phase, rec.breach_ticks, rec.alerted = AgentPhase.RUNNING, 0, False
            return rec, actions
        rec.breach_ticks += 1
        if rec.breach_ticks >= _DEBOUNCE_TICKS:
            if not rec.alerted:               # one alert per episode (review #6)
                actions.append(Action(ActionKind.ALERT, rec))
                rec.alerted = True
            if tier_allows(cfg.max_tier, Tier.NUDGE):
                actions.append(Action(ActionKind.NUDGE, rec))
                rec.phase = AgentPhase.NUDGED
                rec.breach_ticks = 0
                rec.phase_changed_at = o.now
            # max_tier=OBSERVE: park in SUSPECT, already-alerted, silent
        return rec, actions

    grace_s = cfg.grace_min * 60
    if rec.phase is AgentPhase.NUDGED:
        if not breach:                        # recovered on its own during grace
            rec.phase, rec.breach_ticks, rec.alerted = AgentPhase.RUNNING, 0, False
            return rec, actions
        if (o.now - rec.phase_changed_at) > grace_s and tier_allows(cfg.max_tier, Tier.STOP):
            rec.phase = AgentPhase.STOP_REQUESTED
            rec.phase_changed_at = o.now
            actions.append(Action(ActionKind.STOP, rec))
        return rec, actions

    if rec.phase is AgentPhase.STOP_REQUESTED:
        if not breach:                        # recovered even after the stop ask (re-review #1):
            rec.phase, rec.breach_ticks, rec.alerted = AgentPhase.RUNNING, 0, False
            return rec, actions               # never escalate a now-healthy agent
        if (o.now - rec.phase_changed_at) > grace_s:
            rec.phase = AgentPhase.ESCALATED
            rec.phase_changed_at = o.now
            actions.append(Action(ActionKind.ESCALATE, rec))
        return rec, actions

    return rec, actions                       # ESCALATED: session-level logic owns it (Task 15)


@dataclass
class WatchState:
    agents: dict[str, AgentRecord] = field(default_factory=dict)
    parent_scan: ParentScan = field(default_factory=ParentScan)


def save_state(path: Path, state: WatchState) -> None:
    """Atomic write (tmp + rename) so a crash mid-write can never leave a
    truncated/corrupt state file for the next restart to trip over."""
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(dataclasses.asdict(state)))
    os.replace(tmp, path)


def load_state(path: Path) -> WatchState:
    """Rehydrate WatchState from disk. Missing or corrupt state is never
    fatal — the watcher just starts fresh (worst case: one re-alert)."""
    try:
        data = json.loads(path.read_text())
        agents = {}
        for name, rec in data["agents"].items():
            rec = dict(rec)
            rec["phase"] = AgentPhase(rec["phase"])
            agents[name] = AgentRecord(**rec)
        parent_scan = ParentScan(**data["parent_scan"])
        return WatchState(agents=agents, parent_scan=parent_scan)
    except (OSError, ValueError, KeyError, TypeError):
        return WatchState()  # any schema drift / corruption => start fresh, never crash


_RESUME_ALERT_HEADING = "### Stuck-subagent alerts"
_FLOCK_RETRIES = 3
_FLOCK_RETRY_DELAY_S = 0.2


def append_resume_alert(path: Path, line: str) -> None:
    """Append one alert line to RESUME.md under a dedicated heading,
    flock-guarded against the other writers touching this file (the
    existing context watcher, /checkpoint). A delayed alert beats a
    corrupted RESUME: on repeated lock failure, skip this tick silently.
    """
    now_iso = datetime.now(timezone.utc).isoformat()
    with path.open("a+") as f:
        for attempt in range(_FLOCK_RETRIES):
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if attempt == _FLOCK_RETRIES - 1:
                    return  # skip this tick rather than write unsynchronized
                time.sleep(_FLOCK_RETRY_DELAY_S)
        try:
            f.seek(0)
            text = f.read()
            if _RESUME_ALERT_HEADING not in text:
                f.seek(0, os.SEEK_END)
                f.write(f"\n{_RESUME_ALERT_HEADING}\n")
            f.seek(0, os.SEEK_END)
            f.write(f"- {now_iso} {line}\n")
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def notify(cfg: CCBConfig, msg: str) -> None:
    """Best-effort external notification (e.g. the user's Telegram hook);
    must never raise or hang the watcher even if the configured command is
    broken, missing, or misbehaving."""
    if not cfg.notify_cmd:
        return
    try:
        subprocess.run(cfg.notify_cmd, shell=True, input=msg.encode(),
                       timeout=10, capture_output=True)
    except Exception:
        pass


def ledger_write(path: Path, event: EventKind, rec, cfg, *, session_id: str, cwd: str,
                 elapsed_min, stale_min, session_cost_usd, open_tasks, now_iso: str,
                 orchestrator_model: str | None = None) -> None:
    """Append one telemetry line; best-effort, never raises (telemetry must
    never take down the watcher). Config snapshot rides along so a later
    review knows which thresholds produced each decision. The orchestrator's
    model id is captured from day one so vouch-trust can later be keyed on
    orchestrator capability (never hardcoded per-model) — the model is a
    variable, not a constant."""
    row = {
        "ts": now_iso, "event": event.value, "session_id": session_id, "cwd": cwd,
        "agent": rec.name, "teammate_id": rec.teammate_id, "phase": rec.phase.value,
        "orchestrator_model": orchestrator_model,
        "elapsed_min": elapsed_min, "stale_min": stale_min,
        "session_cost_usd": session_cost_usd, "open_tasks": open_tasks,
        "vouches_used": rec.vouches_used, "extension_min": rec.extension_min,
        "peak_elapsed_min": rec.peak_elapsed_min, "peak_stale_min": rec.peak_stale_min,
        "cfg": {k: (v.value if hasattr(v, "value") else v)
                for k, v in dataclasses.asdict(cfg).items() if k != "notify_cmd"},
    }
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as f:
            f.write(json.dumps(row) + "\n")
    except OSError:
        pass


# --- Task 18: ledger evaluation / threshold-tuning report -------------------

_FLAG_EVENTS = frozenset({EventKind.NUDGE, EventKind.ALERT, EventKind.STOP,
                          EventKind.STOP_VERIFIED, EventKind.KILL, EventKind.ESCALATE_BLOCKED})
_STOP_LIKE = frozenset({EventKind.STOP, EventKind.STOP_VERIFIED})


def _percentile(values: list[float], q: float) -> float | None:
    """Linear-interpolation percentile (q in [0, 1]); None on empty input.
    A single value returns itself — avoids statistics.quantiles' n>=2 rule so
    the very first healthy agent still yields a usable baseline."""
    s = sorted(values)
    if not s:
        return None
    pos = q * (len(s) - 1)
    lo = int(pos)
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (pos - lo)


def _summarize_groups(gdict: dict) -> dict:
    """One group = every ledger event for a single (cwd, teammate_id). Classify
    each agent's outcome and roll up counts + the healthy-agent peak
    distributions (the data thresholds should be tuned against)."""
    nudges = kills = 0
    vouched_after_nudge = stopped_after_nudge = escalate_blocked = 0
    healthy_elapsed: list[float] = []
    healthy_stale: list[float] = []
    for events in gdict.values():
        kinds = {e.get("event") for e in events}
        nudges += sum(1 for e in events if e.get("event") == EventKind.NUDGE)
        kills += sum(1 for e in events if e.get("event") == EventKind.KILL)
        if EventKind.ESCALATE_BLOCKED in kinds:
            escalate_blocked += 1
        if EventKind.NUDGE in kinds:
            if kinds & _STOP_LIKE or EventKind.KILL in kinds:
                stopped_after_nudge += 1          # true positive: nudge -> stop/kill
            elif EventKind.VOUCH in kinds:
                vouched_after_nudge += 1           # false positive: nudge -> vouch, finished fine
        if not kinds & _FLAG_EVENTS:               # never flagged => healthy baseline
            healthy_elapsed.append(max((e.get("peak_elapsed_min") or 0.0) for e in events))
            healthy_stale.append(max((e.get("peak_stale_min") or 0.0) for e in events))
    return {
        "agents_seen": len(gdict),
        "nudges": nudges,
        "vouched_after_nudge": vouched_after_nudge,   # false-positive count
        "stopped_after_nudge": stopped_after_nudge,   # true-positive count
        "kills": kills,
        "escalate_blocked": escalate_blocked,
        "healthy_count": len(healthy_elapsed),
        "healthy_peak_elapsed_p50": _percentile(healthy_elapsed, 0.50),
        "healthy_peak_elapsed_p95": _percentile(healthy_elapsed, 0.95),
        "healthy_peak_stale_p50": _percentile(healthy_stale, 0.50),
        "healthy_peak_stale_p95": _percentile(healthy_stale, 0.95),
    }


def summarize_ledger(path: Path) -> dict:
    """Aggregate the telemetry ledger (Task 10b) into the evaluation the user
    asked for: is the breaker working, what did it cost, what should the
    thresholds be? Groups by (cwd, teammate_id); best-effort — skips corrupt
    lines, never raises. Returns the flat rollup plus a per_project breakdown."""
    groups: dict = {}
    try:
        with path.open() as f:
            for raw in f:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    row = json.loads(raw)
                except ValueError:
                    continue
                groups.setdefault((row.get("cwd", ""), row.get("teammate_id", "")), []).append(row)
    except OSError:
        pass
    out = _summarize_groups(groups)
    projects: dict = {}
    for (cwd, tid), events in groups.items():
        projects.setdefault(cwd, {})[(cwd, tid)] = events
    out["per_project"] = {cwd: _summarize_groups(g) for cwd, g in projects.items()}
    return out


# --- Task 13: Tier A — the nudge message --------------------------------------
# extend_hint_min is the number the model is told to write in its CCB-VOUCH
# marker (a fixed suggestion, default 60); deadline_min (= cfg.grace_min) is how
# long it has before the breaker escalates on its own. They are DIFFERENT
# numbers (plan Task 13 Step 3): the first extends, the second is the config
# deadline — conflating them was the plan's own noted bug.
_DEFAULT_EXTEND_HINT_MIN = 60


def nudge_message(rec: AgentRecord, elapsed_min: float, stale_min: float,
                  session_cost_usd: float | None, open_tasks: int | None,
                  extend_hint_min: int, deadline_min: int) -> str:
    """The Tier-A message injected into the orchestrator's pty (S1: reaches the
    running model at the next tool boundary). Pure and testable — states the
    facts, the exact CCB-VOUCH grammar to extend, and the TaskStop escape. The
    injector collapses newlines before writing (single-line is the S1-verified
    submit shape); the structure here is for readability of the model-facing
    text and the tests."""
    cost = f"${session_cost_usd:.2f}" if session_cost_usd is not None else "unknown"
    open_s = open_tasks if open_tasks is not None else "?"
    return (
        f"[ccage circuit-breaker] Teammate '{rec.teammate_id}' has been running "
        f"{elapsed_min:.0f} min (transcript quiet {stale_min:.0f} min; session cost {cost}; "
        f"{open_s} open tasks). Decide NOW, do not defer:\n"
        f"(a) If this is expected long work, include this exact marker in your reply: "
        f"CCB-VOUCH agent={rec.teammate_id} extend={extend_hint_min}\n"
        f"(b) Otherwise check it (TaskList / SendMessage) and stop it with TaskStop, "
        f"then record its partial results in RESUME.md.\n"
        f"If you do neither within {deadline_min:.0f} min, the circuit breaker escalates on its own."
    )


def stop_message(rec: AgentRecord, grace_min: float) -> str:
    """Tier-B directive (Task 14): the nudge's grace expired with no vouch, so
    order the stop. Carries the S2 caveat — TaskStop ends the teammate's turn
    but can orphan its shell sub-processes (they keep costing) — and the exact
    CCB-STOPPED reply grammar the scanner verifies against."""
    return (
        f"[ccage circuit-breaker] Teammate '{rec.teammate_id}' was flagged {grace_min:.0f} min "
        f"ago and no CCB-VOUCH was seen. Stop it NOW with TaskStop, salvage whatever partial "
        f"output exists into RESUME.md, and reassign or drop its task. Note: TaskStop ends its "
        f"turn but can leave its shell sub-processes running (they keep costing) — check for and "
        f"kill those too. Reply with the marker CCB-STOPPED agent={rec.teammate_id} when done."
    )


def kill_permitted(cfg: CCBConfig, parent_stale_min: float | None) -> bool:
    """Tier C (Task 15) precondition. The session-kill fires ONLY when the
    orchestrator itself is unresponsive — its parent transcript has been quiet
    longer than cfg.parent_stale_min — AND kill is the configured ceiling. A live
    orchestrator is NEVER killed: it can still act on the re-issued stop. An
    unreadable parent staleness (None) counts as alive (fail-safe: never kill on
    missing evidence)."""
    if cfg.max_tier is not Tier.KILL:
        return False
    if parent_stale_min is None:
        return False
    return parent_stale_min > cfg.parent_stale_min


def pre_kill_dump(agents: dict, session_cost: float | None, open_tasks: int | None) -> str:
    """A one-line salvage map written to RESUME.md just before a Tier-C kill, so
    the resumed session knows what every teammate was doing and what it cost. Kept
    to one line to fit append_resume_alert's single-bullet format."""
    cost = "unknown" if session_cost is None else "$%.2f" % session_cost
    ot = "?" if open_tasks is None else str(open_tasks)
    parts = ["TIER-C KILL pre-mortem (session cost %s, %s open tasks) — salvage map:" % (cost, ot)]
    for name in sorted(agents):
        rec = agents[name]
        parts.append("%s[%s] peak_elapsed=%.0fmin peak_stale=%.0fmin"
                     % (rec.teammate_id, rec.phase.value, rec.peak_elapsed_min, rec.peak_stale_min))
    return " ".join(parts)


# --- Task 11: the per-poll orchestration (observe mode) ---------------------
# Pure logic: no threads, no pty, no clock reads (now is injected). All I/O is
# against paths the caller passes, so this is unit-testable end to end.
# bin/ccage-auto's SubagentWatcher is a thin thread wrapper around run_tick.


def _effective_cfg(cfg: CCBConfig, is_teams: bool) -> CCBConfig:
    """Non-teams sessions (V10) cannot produce the in-band completion signal the
    higher tiers rely on, so the breaker never acts beyond OBSERVE there — a
    stuck agent is still alerted, but never nudged/stopped/killed on a session
    whose completion we can't read. Teams sessions (or already-observe config)
    keep the caller's tier unchanged."""
    if is_teams or cfg.max_tier is Tier.OBSERVE:
        return cfg
    return dataclasses.replace(cfg, max_tier=Tier.OBSERVE)


def _transcript_mtime(path: Path) -> float | None:
    try:
        return path.stat().st_mtime
    except OSError:
        return None


def run_tick(
    *,
    session_dir: Path,
    config_root: Path,
    session_id: str,
    cwd: str,
    cfg: CCBConfig,
    state: WatchState,
    now: float,
    parent_transcript: Path | None,
    resume_path: Path,
    ledger_path: Path,
    state_path: Path,
    orchestrator_model: str | None = None,
    tokenol_url: str | None = None,
    log: Callable[[str], None] = lambda _m: None,
    inject: Callable[[str], bool] = lambda _t: False,
    kill_session: Callable[[str], bool] = lambda _id: False,
    flags: dict | None = None,
) -> WatchState:
    """One observe-mode poll tick across every subagent under session_dir.

    Rescans the parent transcript (progress/vouch/idle/stopped), lists subagent
    transcripts, builds an Observation per agent from the tested time/idle
    signals, runs the pure `evaluate` state machine, then executes the returned
    actions:
      - `alert`  — RESUME + log + notify (one per breach episode);
      - `nudge`  — Tier A: inject the vouch/stop directive (via `inject`);
      - `stop`   — Tier B: inject the stop directive; verification arrives later
                   as the CCB-STOPPED marker (o.stopped -> RESOLVED + STOP_VERIFIED);
      - `escalate` — Tier C: if `kill_permitted` (kill tier + unresponsive
                   orchestrator) write the pre-kill dump and terminate the pty
                   child (via `kill_session`); else re-issue the stop once and
                   flag for manual attention (ESCALATE_BLOCKED).
    `evaluate` caps every action at cfg.max_tier, so `nudge`/`stop` only reach
    here on a NUDGE+/STOP+ teams session — the default observe rollout emits only
    `alert`. `inject` (pty write) and `kill_session` (pid SIGTERM) are the two
    bin-owned side effects; everything else is decided and audited here.

    Telemetry (Task 10b): one ledger line per executed alert, per vouch
    consumed, and on the transition INTO RESOLVED only (including healthy
    never-flagged agents — the peak-stats baseline thresholds get tuned
    against). The RESOLVED line is gated on `prev.phase != RESOLVED` so a
    completed agent re-evaluating to RESOLVED every poll never appends a
    duplicate. State is persisted before returning; the returned WatchState is
    the input for the next tick.

    `flags` is a caller-owned scratch dict used only to log the non-teams
    forced-observe notice once per run.
    """
    flags = {} if flags is None else flags
    now_iso = datetime.fromtimestamp(now, timezone.utc).isoformat()
    tok_url = tokenol_url if tokenol_url is not None else cfg.tokenol_url

    scan = state.parent_scan
    if parent_transcript is not None:
        scan = scan_parent_transcript(parent_transcript, scan)

    transcripts = list_subagent_transcripts(session_dir)
    metas = {t: agent_meta(t) for t in transcripts}

    # Session-level context, computed lazily and memoized so a tick makes at
    # most one tokenol call and one task-dir read per distinct team.
    open_tasks_cache: dict[str | None, int | None] = {}
    def _open_tasks(team_name: str | None) -> int | None:
        if team_name not in open_tasks_cache:
            open_tasks_cache[team_name] = open_task_count(config_root, session_id, team_name)
        return open_tasks_cache[team_name]

    cost_cache: dict[str, float | None] = {}
    def _cost() -> float | None:
        if "v" not in cost_cache:
            cost_cache["v"] = session_cost_usd(session_id, tok_url) if session_id else None
        return cost_cache["v"]

    # Teams detection (V10): a teammate-message, an in-band idle signal, or a
    # task dir all mark a teams session. Non-teams => forced observe-only.
    any_task_dir = any(_open_tasks(m.team_name) is not None for m in metas.values())
    is_teams = bool(scan.msg_counts) or bool(scan.idle) or any_task_dir
    if not is_teams and cfg.max_tier is not Tier.OBSERVE and not flags.get("non_teams_logged"):
        log("non-teams session: circuit breaker forced to observe-only (V10)")
        flags["non_teams_logged"] = True
    eff_cfg = _effective_cfg(cfg, is_teams)

    agents = dict(state.agents)
    for t in transcripts:
        meta = metas[t]
        name = t.stem
        prev = agents.get(name)

        elapsed = elapsed_seconds(t, now_iso)
        elapsed_min = elapsed / 60.0 if elapsed is not None else 0.0
        stale = stale_minutes(t, now)
        stale_min = stale if stale is not None else 0.0
        idle_epoch = scan.idle.get(meta.teammate_id)
        completed = idle_completed(idle_epoch, _transcript_mtime(t))
        stopped = bool(scan.stopped.get(meta.teammate_id))

        o = Observation(
            elapsed_min=elapsed_min, stale_min=stale_min, completed=completed,
            vouch_total_min=scan.vouches.get(meta.teammate_id, 0), now=now,
            stopped=stopped,
        )
        base = prev if prev is not None else AgentRecord(name=name, teammate_id=meta.teammate_id)
        rec, actions = evaluate(base, o, eff_cfg)
        rec.peak_elapsed_min = max(rec.peak_elapsed_min, elapsed_min)
        rec.peak_stale_min = max(rec.peak_stale_min, stale_min)

        def _ledger(event: EventKind, rec=rec, elapsed_min=elapsed_min,
                    stale_min=stale_min, team_name=meta.team_name) -> None:
            ledger_write(ledger_path, event, rec, cfg, session_id=session_id, cwd=cwd,
                         elapsed_min=elapsed_min, stale_min=stale_min,
                         session_cost_usd=_cost(), open_tasks=_open_tasks(team_name),
                         now_iso=now_iso, orchestrator_model=orchestrator_model)

        # One terminal line on the transition into RESOLVED only. A verified
        # stop (Task 14) is a distinct event kind so ccb-report can score it as
        # a true positive (nudge -> stop) rather than a healthy completion.
        if rec.phase is AgentPhase.RESOLVED and (prev is None or prev.phase is not AgentPhase.RESOLVED):
            _ledger(EventKind.STOP_VERIFIED if stopped else EventKind.RESOLVED)
        # A consumed vouch (de-escalation to VOUCHED) is auditable telemetry.
        if prev is not None and rec.vouches_used > prev.vouches_used:
            _ledger(EventKind.VOUCH)

        undelivered = False   # a nudge/stop that never reached the pty (rate-limited,
                              # no pty, or TUI not ready) must NOT stick as progress.
        for act in actions:
            if act.kind is ActionKind.ALERT:
                cost = _cost()
                cost_s = "" if cost is None else ", session $%.2f" % cost
                ot = _open_tasks(meta.team_name)
                ot_s = "" if ot is None else ", %d open task%s" % (ot, "" if ot == 1 else "s")
                msg = ("watch: teammate %s stuck at %.0fmin (stale %.0fmin%s%s)"
                       % (meta.teammate_id, elapsed_min, stale_min, ot_s, cost_s))
                append_resume_alert(resume_path, msg)
                notify(cfg, msg)
                log(msg)
                _ledger(EventKind.ALERT)
            elif act.kind is ActionKind.NUDGE:
                # Tier A (Task 13): inject the vouch/stop directive into the
                # orchestrator's pty. deadline = cfg.grace_min (config), extend
                # hint = the fixed 60-min suggestion — two different numbers.
                text = nudge_message(
                    rec, elapsed_min, stale_min, _cost(), _open_tasks(meta.team_name),
                    extend_hint_min=_DEFAULT_EXTEND_HINT_MIN, deadline_min=cfg.grace_min)
                if inject(text):
                    summary = ("nudged: teammate %s at %.0fmin (stale %.0fmin), grace %d min"
                               % (meta.teammate_id, elapsed_min, stale_min, cfg.grace_min))
                    append_resume_alert(resume_path, summary)
                    notify(cfg, summary)
                    log(summary)
                    _ledger(EventKind.NUDGE)
                else:
                    # Delivery dropped: never ledger/RESUME a phantom nudge, and do
                    # not let the phase advance — evaluate re-issues next tick, so the
                    # grace clock starts only once the orchestrator was really told.
                    undelivered = True
                    log("nudge undelivered, deferred to next tick: teammate %s" % meta.teammate_id)
            elif act.kind is ActionKind.STOP:
                # Tier B (Task 14): grace expired, no vouch — inject the stop
                # directive. Verification comes on a later tick when the
                # CCB-STOPPED marker lands (o.stopped -> RESOLVED + STOP_VERIFIED).
                if inject(stop_message(rec, cfg.grace_min)):
                    summary = ("stop requested: teammate %s at %.0fmin (stale %.0fmin), grace %d min"
                               % (meta.teammate_id, elapsed_min, stale_min, cfg.grace_min))
                    append_resume_alert(resume_path, summary)
                    notify(cfg, summary)
                    log(summary)
                    _ledger(EventKind.STOP)
                else:
                    undelivered = True
                    log("stop undelivered, deferred to next tick: teammate %s" % meta.teammate_id)
            elif act.kind is ActionKind.ESCALATE:
                # Tier C (Task 15): the stop's grace expired too. run_tick owns
                # the decision + audit trail (it has the cost/task/ledger
                # context); the irreducibly session-level part — terminating the
                # pty child — is delegated to the bin's kill_session callback,
                # exactly as pty writes are delegated to inject. Fires once (the
                # STOP_REQUESTED->ESCALATED transition emits one escalate action).
                #
                # kill_permitted keys on parent-transcript quiescence to tell a
                # WEDGED orchestrator from a merely-busy one. This is sound
                # because (S1) a mid-tool injection QUEUES when the orchestrator
                # is stuck and is never consumed -> the transcript stays quiet ->
                # parent_stale grows. A healthy orchestrator consumes the nudge/
                # stop at its next tool boundary, writes, and resets the clock (so
                # it is never killed). Task 17's KILL scenario validates this.
                parent_stale = (stale_minutes(parent_transcript, now)
                                if parent_transcript is not None else None)
                if kill_permitted(cfg, parent_stale):
                    # agents[name] is still the pre-tick rec here (written back
                    # after the loop); substitute the current ESCALATED rec so
                    # the escalating agent shows its true phase in the salvage map.
                    dump = pre_kill_dump({**agents, name: rec}, _cost(), _open_tasks(meta.team_name))
                    append_resume_alert(resume_path, dump)
                    notify(cfg, dump)
                    log("TIER-C KILL: orchestrator unresponsive (parent quiet %.0fmin) — terminating session"
                        % (parent_stale or 0.0))
                    _ledger(EventKind.KILL)
                    kill_session(meta.teammate_id)
                else:
                    # Blocked: tier < kill, or the orchestrator is still alive and
                    # can act. Re-issue the stop ONCE (the transition fires once),
                    # flag for manual attention, then park silently in ESCALATED.
                    inject(stop_message(rec, cfg.grace_min))
                    summary = ("escalation blocked for teammate %s (tier/parent-alive); "
                               "manual attention required" % meta.teammate_id)
                    append_resume_alert(resume_path, summary)
                    notify(cfg, summary)
                    log(summary)
                    _ledger(EventKind.ESCALATE_BLOCKED)

        # An undelivered tier action reverts this agent to its pre-tick record
        # (keeping the monotonic peak stats + the already-emitted alert flag) so
        # the SAME action fires again next tick once the pty is free/ready.
        if undelivered:
            rec = dataclasses.replace(base, peak_elapsed_min=rec.peak_elapsed_min,
                                      peak_stale_min=rec.peak_stale_min, alerted=rec.alerted)
        agents[name] = rec

    new_state = WatchState(agents=agents, parent_scan=scan)
    save_state(state_path, new_state)
    return new_state
