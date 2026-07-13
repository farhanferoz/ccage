"""Stuck-subagent detection for ccage-auto (circuit breaker v2).

Pure logic only: no pty, no threads. bin/ccage-auto owns wiring.
"""
import dataclasses
import json
import os
import re
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from lib.ccb_types import AgentPhase, AgentRecord, CCBConfig, TaskStatus, Tier, tier_allows


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


def agent_meta(transcript: Path) -> AgentMeta:
    """Authoritative identity from <agent>.meta.json (V11). The transcript
    filename encodes a DIFFERENT string than the real teammate id — never
    parse it. Fallback (meta missing/corrupt): the stem, which at least
    dedupes consistently even if it can't match vouch/completion signals.
    """
    try:
        m = json.loads(transcript.with_suffix(".meta.json").read_text())
        name = m.get("name")
        if isinstance(name, str) and name:
            return AgentMeta(teammate_id=name, team_name=m.get("teamName") or None)
    except (OSError, ValueError):
        pass
    return AgentMeta(teammate_id=transcript.stem, team_name=None)


_TEAMMATE_MSG = re.compile(r'<teammate-message[^>]*\bteammate_id=\\?"([^"\\]+)\\?"')
_VOUCH = re.compile(r"CCB-VOUCH\s+agent=([\w-]+)\s+extend=(\d+)")


@dataclass
class ParentScan:
    offset: int = 0
    msg_counts: dict[str, int] = field(default_factory=dict)  # liveness (V6: NOT completion)
    vouches: dict[str, int] = field(default_factory=dict)     # cumulative minutes


def scan_parent_transcript(path: Path, prev: ParentScan) -> ParentScan:
    """Resume scanning at prev.offset; consume only complete lines.

    Extracts teammate-message counts (liveness only — these recur through an
    agent's life, V6) and CCB-VOUCH markers from raw line text — regex over
    the line, not JSON traversal, so nested content shapes can't hide a
    marker. Torn final lines are left for the next poll (offset advances
    only past a trailing newline).
    """
    out = ParentScan(prev.offset, dict(prev.msg_counts), dict(prev.vouches))
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
    except OSError:
        pass  # transcript rotated/missing: keep previous state, retry next poll
    return out


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
    with path.open() as f:
        first_line = f.readline()
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


@dataclass(frozen=True)
class Action:
    kind: str                # "alert" | "nudge" | "stop" | "escalate"
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
    import dataclasses
    rec = dataclasses.replace(rec)
    actions: list[Action] = []

    if o.completed:
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
                actions.append(Action("alert", rec))
                rec.alerted = True
            if tier_allows(cfg.max_tier, Tier.NUDGE):
                actions.append(Action("nudge", rec))
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
            actions.append(Action("stop", rec))
        return rec, actions

    if rec.phase is AgentPhase.STOP_REQUESTED:
        if not breach:                        # recovered even after the stop ask (re-review #1):
            rec.phase, rec.breach_ticks, rec.alerted = AgentPhase.RUNNING, 0, False
            return rec, actions               # never escalate a now-healthy agent
        if (o.now - rec.phase_changed_at) > grace_s:
            rec.phase = AgentPhase.ESCALATED
            rec.phase_changed_at = o.now
            actions.append(Action("escalate", rec))
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
    except (OSError, ValueError, KeyError):
        return WatchState()
