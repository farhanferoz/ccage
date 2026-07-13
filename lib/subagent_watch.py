"""Stuck-subagent detection for ccage-auto (circuit breaker v2).

Pure logic only: no pty, no threads. bin/ccage-auto owns wiring.
"""
from pathlib import Path


def list_subagent_transcripts(session_dir: Path) -> list[Path]:
    """Every subagent transcript under session_dir/subagents/."""
    sub_dir = session_dir / "subagents"
    if not sub_dir.is_dir():
        return []
    return sorted(sub_dir.glob("agent-*.jsonl"))
