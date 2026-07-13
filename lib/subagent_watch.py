"""Stuck-subagent detection for ccage-auto (circuit breaker v2).

Pure logic only: no pty, no threads. bin/ccage-auto owns wiring.
"""
import json
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from lib.ccb_types import TaskStatus


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
