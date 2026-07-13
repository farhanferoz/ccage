"""Closed variant sets and config for the subagent circuit breaker."""
import os
from dataclasses import dataclass
from enum import StrEnum


class Tier(StrEnum):
    OBSERVE = "observe"
    NUDGE = "nudge"
    STOP = "stop"
    KILL = "kill"


_TIER_ORDER = [Tier.OBSERVE, Tier.NUDGE, Tier.STOP, Tier.KILL]


def tier_allows(max_tier: Tier, action: Tier) -> bool:
    return _TIER_ORDER.index(action) <= _TIER_ORDER.index(max_tier)


class AgentPhase(StrEnum):
    RUNNING = "running"
    SUSPECT = "suspect"          # breach seen once (debounce pending)
    NUDGED = "nudged"            # Tier A taken, grace running
    VOUCHED = "vouched"          # orchestrator vouched; budget extended
    STOP_REQUESTED = "stop_requested"  # Tier B taken, grace running
    ESCALATED = "escalated"      # handed to session-level Tier C evaluation
    RESOLVED = "resolved"        # completion signal seen (terminal)


class TaskStatus(StrEnum):
    PENDING = "pending"
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"
    UNKNOWN = "unknown"


class EventKind(StrEnum):
    ALERT = "alert"
    NUDGE = "nudge"
    VOUCH = "vouch"
    STOP = "stop"
    STOP_VERIFIED = "stop_verified"
    ESCALATE_BLOCKED = "escalate_blocked"
    KILL = "kill"
    RESOLVED = "resolved"           # normal completion; carries peak stats


class ActionKind(StrEnum):
    """The closed set of actions evaluate() emits for run_tick to execute."""
    ALERT = "alert"
    NUDGE = "nudge"
    STOP = "stop"
    ESCALATE = "escalate"


@dataclass
class CCBConfig:
    # Fail SAFE by default: a deployed watcher must never act above OBSERVE
    # unless explicitly opted up. Production only ever builds this via from_env
    # (which also fails safe on a malformed value); tests that exercise the
    # nudge/stop/kill ladder pass max_tier= explicitly.
    max_tier: Tier = Tier.OBSERVE
    t_soft_min: int = 45
    t_stale_min: int = 10
    t_hard_min: int = 120
    grace_min: int = 10
    parent_stale_min: int = 15
    max_vouches: int = 2
    notify_cmd: str | None = None
    tokenol_url: str = "http://localhost:8787"

    @classmethod
    def from_env(cls, env: dict | None = None) -> "CCBConfig":
        e = os.environ if env is None else env
        cfg = cls()
        raw_tier = e.get("CCB_MAX_TIER", "").strip().lower()
        try:
            cfg.max_tier = Tier(raw_tier)
        except ValueError:
            # Absent, garbage, or mis-cased ("OBSERVE", " stop ") -> fall back to
            # the SAFE floor, never silently to the more permissive class default.
            cfg.max_tier = Tier.OBSERVE
        for attr, var in [
            ("t_soft_min", "CCB_T_SOFT_MIN"), ("t_stale_min", "CCB_T_STALE_MIN"),
            ("t_hard_min", "CCB_T_HARD_MIN"), ("grace_min", "CCB_GRACE_MIN"),
            ("parent_stale_min", "CCB_PARENT_STALE_MIN"), ("max_vouches", "CCB_MAX_VOUCHES"),
        ]:
            if e.get(var, "").isdigit():
                setattr(cfg, attr, int(e[var]))
        cfg.notify_cmd = e.get("CCB_NOTIFY_CMD") or None
        cfg.tokenol_url = e.get("CCB_TOKENOL_URL", cfg.tokenol_url)
        return cfg


@dataclass
class AgentRecord:
    name: str                     # transcript stem, e.g. agent-asr6-cost-regrade-<hash>
    teammate_id: str              # authoritative id from .meta.json "name" (Task 3) — NOT the filename
    phase: AgentPhase = AgentPhase.RUNNING
    breach_ticks: int = 0         # consecutive polls in breach (debounce counter)
    vouches_used: int = 0
    extension_min: int = 0        # total vouched extension
    phase_changed_at: float = 0.0 # epoch seconds of last phase transition
    alerted: bool = False         # one alert per breach episode (reset on de-escalation)
    peak_elapsed_min: float = 0.0 # telemetry: max observed (healthy agents teach us thresholds)
    peak_stale_min: float = 0.0   # telemetry: max observed transcript quiet
