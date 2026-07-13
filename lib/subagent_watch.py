"""Stuck-subagent detection for ccage-auto (circuit breaker v2).

Pure logic only: no pty, no threads. bin/ccage-auto owns wiring.
"""
import json
import re
from dataclasses import dataclass, field
from pathlib import Path


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
