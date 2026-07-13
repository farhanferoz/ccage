import json
import os
from pathlib import Path

from lib.subagent_watch import list_subagent_transcripts


def test_lists_jsonl_files_under_subagents_dir(tmp_path):
    session_dir = tmp_path / "9f7fab1a-9707-423b-a552-b021774b0db1"
    sub_dir = session_dir / "subagents"
    sub_dir.mkdir(parents=True)
    (sub_dir / "agent-asr8-vrp-freefirst-d3a5d24802e63d21.jsonl").write_text("{}\n")
    (sub_dir / "agent-a23b9840c03e0811f.jsonl").write_text("{}\n")  # unnamed agent (V2)
    (session_dir / "not-a-subagent.jsonl").write_text("{}\n")

    found = list_subagent_transcripts(session_dir)

    assert [f.name for f in found] == sorted(
        ["agent-a23b9840c03e0811f.jsonl", "agent-asr8-vrp-freefirst-d3a5d24802e63d21.jsonl"]
    )


def test_config_reads_env_overrides(monkeypatch):
    from lib.ccb_types import CCBConfig, Tier

    monkeypatch.setenv("CCB_MAX_TIER", "kill")
    monkeypatch.setenv("CCB_T_HARD_MIN", "240")
    cfg = CCBConfig.from_env()
    assert cfg.max_tier is Tier.KILL
    assert cfg.t_hard_min == 240
    assert cfg.t_soft_min == 45  # untouched default


def test_config_rejects_bad_tier(monkeypatch):
    from lib.ccb_types import CCBConfig, Tier

    monkeypatch.setenv("CCB_MAX_TIER", "obliterate")
    cfg = CCBConfig.from_env()
    assert cfg.max_tier is Tier.OBSERVE  # bad value -> fail safe to observe, never raises


def test_agent_meta_reads_name_and_team(tmp_path):
    from lib.subagent_watch import agent_meta

    t = tmp_path / "agent-asr6-cost-regrade-a8829e1a20628718.jsonl"
    t.write_text("{}\n")
    t.with_suffix(".meta.json").write_text(
        '{"agentType":"sr6-cost-regrade","name":"sr6-cost-regrade",'
        '"teamName":"session-cc9d022f","taskKind":"in_process_teammate"}'
    )
    m = agent_meta(t)
    assert m.teammate_id == "sr6-cost-regrade"     # NOT "asr6-cost-regrade"
    assert m.team_name == "session-cc9d022f"


def test_agent_meta_missing_or_corrupt_falls_back_to_stem(tmp_path):
    from lib.subagent_watch import agent_meta

    t = tmp_path / "agent-a23b9840c03e0811f.jsonl"
    t.write_text("{}\n")
    m = agent_meta(t)                               # no meta file at all
    assert m.teammate_id == "agent-a23b9840c03e0811f" and m.team_name is None

    t.with_suffix(".meta.json").write_text("{corrupt")
    m = agent_meta(t)                               # unreadable meta: same fallback
    assert m.teammate_id == "agent-a23b9840c03e0811f" and m.team_name is None


def _wr(path, blobs):
    with path.open("a") as f:
        for b in blobs:
            f.write(json.dumps(b) + "\n")


def test_scanner_counts_messages_and_vouches_incrementally(tmp_path):
    from lib.subagent_watch import ParentScan, scan_parent_transcript

    t = tmp_path / "parent.jsonl"
    _wr(t, [
        {"type": "user", "message": {"content": [{"type": "text",
            "text": '<teammate-message teammate_id="sr2-f5-bug-audit" summary="progress">body</teammate-message>'}]}},
        {"type": "assistant", "message": {"content": [{"type": "text",
            "text": "Expected long run. CCB-VOUCH agent=sr6-cost-regrade extend=90"}]}},
    ])

    scan = ParentScan()
    scan = scan_parent_transcript(t, scan)
    assert scan.msg_counts == {"sr2-f5-bug-audit": 1}    # liveness, NOT completion (V6)
    assert scan.vouches == {"sr6-cost-regrade": 90}
    offset_after_first = scan.offset

    # Append another message from the same teammate; rescan resumes from offset.
    _wr(t, [{"type": "user", "message": {"content": [{"type": "text",
        "text": '<teammate-message teammate_id="sr2-f5-bug-audit" summary="more">x</teammate-message>'}]}}])
    scan = scan_parent_transcript(t, scan)
    assert scan.msg_counts == {"sr2-f5-bug-audit": 2}
    assert scan.offset > offset_after_first


def test_scanner_survives_partial_last_line(tmp_path):
    from lib.subagent_watch import ParentScan, scan_parent_transcript

    t = tmp_path / "parent.jsonl"
    t.write_text('{"type":"user","message":{"content":[{"type":"text","text":"ok"}]}}\n{"type":"assis')  # torn write

    scan = scan_parent_transcript(t, ParentScan())
    # Torn tail must not be consumed (offset stays at end of last full line) and must not raise.
    assert scan.offset == t.read_text().index('{"type":"assis')


def test_elapsed_since_first_line(tmp_path):
    from lib.subagent_watch import elapsed_seconds

    f = tmp_path / "agent-x.jsonl"
    f.write_text(json.dumps({"timestamp": "2026-07-12T10:13:42.587000+00:00"}) + "\n")

    # 2026-07-12T11:02:10Z is ~2908s after the first line's timestamp
    now_iso = "2026-07-12T11:02:10.930000+00:00"
    assert elapsed_seconds(f, now_iso=now_iso) == 2908


def test_elapsed_since_first_line_accepts_z_suffix(tmp_path):
    from lib.subagent_watch import elapsed_seconds

    f = tmp_path / "agent-x.jsonl"
    f.write_text(json.dumps({"timestamp": "2026-07-12T10:13:42Z"}) + "\n")

    # Must not raise on Python < 3.11, where fromisoformat rejects "Z" outright.
    assert elapsed_seconds(f, now_iso="2026-07-12T10:14:42Z") == 60


def test_elapsed_since_first_line_returns_none_on_empty_file(tmp_path):
    from lib.subagent_watch import elapsed_seconds

    f = tmp_path / "agent-x.jsonl"
    f.touch()  # exists but nothing written yet — a real race, not a hypothetical

    # Must degrade gracefully (None = "can't tell yet"), never raise.
    assert elapsed_seconds(f, now_iso="2026-07-12T10:14:42Z") is None


def test_stale_minutes_from_mtime(tmp_path):
    from lib.subagent_watch import stale_minutes

    f = tmp_path / "agent-x.jsonl"
    f.write_text("{}\n")
    now = f.stat().st_mtime + 720          # 12 min since last write
    assert stale_minutes(f, now=now) == 12.0
    assert stale_minutes(tmp_path / "gone.jsonl", now=now) is None   # never raises


def test_open_task_count_parses_status_not_presence(tmp_path):
    from lib.subagent_watch import open_task_count

    sid = "5097af1b-48e3-4019-9d7a-fbf611f152ee"
    d = tmp_path / "tasks" / f"session-{sid[:8]}"   # teams naming (V5)
    d.mkdir(parents=True)
    (d / "1.json").write_text('{"id":"1","status":"completed"}')   # persists on disk (V4)!
    (d / "2.json").write_text('{"id":"2","status":"in_progress"}')
    (d / "3.json").write_text('{"id":"3","status":"pending"}')
    (d / "4.json").write_text("not json")  # corrupt → UNKNOWN → counted open (fail-open)

    assert open_task_count(tmp_path, session_id=sid) == 3  # in_progress + pending + unknown


def test_open_task_count_full_uuid_dir_variant(tmp_path):
    from lib.subagent_watch import open_task_count

    sid = "409497e5-401d-4499-a9ac-767f8e0f16e8"
    d = tmp_path / "tasks" / sid                     # non-teams naming (V5)
    d.mkdir(parents=True)
    (d / "1.json").write_text('{"id":"1","status":"pending"}')
    assert open_task_count(tmp_path, session_id=sid) == 1


def test_open_task_count_prefers_meta_team_name(tmp_path):
    from lib.subagent_watch import open_task_count

    # Real incident shape (V11): team dir name unrelated to the session UUID.
    d = tmp_path / "tasks" / "session-cc9d022f"
    d.mkdir(parents=True)
    (d / "1.json").write_text('{"id":"1","status":"in_progress"}')
    assert open_task_count(tmp_path, session_id="1e0c8efe-964a-4167-b722-8019792e8645",
                           team_name="session-cc9d022f") == 1


def test_open_task_count_none_when_no_task_dir(tmp_path):
    from lib.subagent_watch import open_task_count

    # None = "not a teams session / no task info" (V10 gates on this), distinct from 0.
    assert open_task_count(tmp_path, session_id="deadbeef-0000-0000-0000-000000000000") is None


def test_session_cost_lookup_falls_back_when_tokenol_unreachable(monkeypatch):
    from lib.subagent_watch import session_cost_usd
    import urllib.error

    def raise_conn_error(*a, **kw):
        raise urllib.error.URLError("connection refused")

    monkeypatch.setattr("urllib.request.urlopen", raise_conn_error)
    # Falls back to None (unknown), never raises — the watcher must degrade
    # gracefully when tokenol's serve isn't running.
    assert session_cost_usd(session_id="abc123", tokenol_base_url="http://localhost:8787") is None


def test_session_cost_lookup_falls_back_on_non_dict_response(monkeypatch):
    from lib.subagent_watch import session_cost_usd

    class FakeResp:
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def read(self): return b"[]"  # a list, not the expected dict shape

    monkeypatch.setattr("urllib.request.urlopen", lambda *a, **kw: FakeResp())
    # Must not raise AttributeError when the API returns an unexpected shape.
    assert session_cost_usd(session_id="abc123", tokenol_base_url="http://localhost:8787") is None


from lib.ccb_types import AgentPhase, AgentRecord, CCBConfig, Tier


def _obs(**kw):
    from lib.subagent_watch import Observation
    base = dict(elapsed_min=0.0, stale_min=0.0, completed=False,
                vouch_total_min=0, now=1_000_000.0)
    base.update(kw)
    return Observation(**base)


def _rec(phase=AgentPhase.RUNNING, **kw):
    r = AgentRecord(name="agent-x-0123456789abcdef", teammate_id="x", phase=phase)
    for k, v in kw.items():
        setattr(r, k, v)
    return r


def test_completion_wins_from_any_phase():
    from lib.subagent_watch import evaluate
    for phase in AgentPhase:
        rec, actions = evaluate(_rec(phase=phase), _obs(completed=True), CCBConfig())
        assert rec.phase is AgentPhase.RESOLVED
        assert actions == []          # a completed agent NEVER triggers anything


def test_resolved_is_reversible_when_completion_signal_clears():
    from lib.subagent_watch import evaluate
    # The completion signal is not fully trusted (V6): if the agent writes
    # again after going idle, completed flips back to False and the agent
    # must return to watch — a wrong "done" can never blind the breaker.
    rec, actions = evaluate(_rec(phase=AgentPhase.RESOLVED), _obs(completed=False), CCBConfig())
    assert rec.phase is AgentPhase.RUNNING and actions == []


def test_healthy_long_agent_below_thresholds_stays_running():
    from lib.subagent_watch import evaluate
    rec, actions = evaluate(_rec(), _obs(elapsed_min=100, stale_min=2), CCBConfig())
    assert rec.phase is AgentPhase.RUNNING and actions == []


def test_quiet_stuck_needs_two_consecutive_polls_then_alerts_and_nudges():
    from lib.subagent_watch import evaluate
    cfg = CCBConfig(max_tier=Tier.STOP)  # soft=45, stale=10
    o = _obs(elapsed_min=60, stale_min=15)

    rec, actions = evaluate(_rec(), o, cfg)
    assert rec.phase is AgentPhase.SUSPECT and actions == []       # debounce tick 1

    rec, actions = evaluate(rec, o, cfg)
    assert rec.phase is AgentPhase.NUDGED
    assert [a.kind for a in actions] == ["alert", "nudge"]          # one tier step, audited


def test_churn_stuck_caught_by_hard_threshold_despite_fresh_writes():
    from lib.subagent_watch import evaluate
    cfg = CCBConfig(max_tier=Tier.STOP)  # hard=120
    o = _obs(elapsed_min=130, stale_min=0.1)                        # writing constantly
    rec, _ = evaluate(_rec(), o, cfg)
    rec, actions = evaluate(rec, o, cfg)
    assert rec.phase is AgentPhase.NUDGED                           # v1's blind spot, closed


def test_vouch_deescalates_and_protects_both_stuck_modes():
    from lib.subagent_watch import evaluate
    cfg = CCBConfig(max_tier=Tier.STOP)  # soft=45, stale=10, hard=120, grace=10
    t0 = 1_000_000.0
    rec = _rec(phase=AgentPhase.NUDGED, phase_changed_at=t0 - 60)   # within grace
    rec, actions = evaluate(rec, _obs(elapsed_min=130, vouch_total_min=90), cfg)
    assert rec.phase is AgentPhase.VOUCHED and rec.vouches_used == 1 and actions == []
    # Extension shifts BOTH floors (review #5): quiet-stuck needs 45+90=135,
    # churn needs 120+90=210 — a vouched agent quietly working at 130 min is safe.
    rec, actions = evaluate(rec, _obs(elapsed_min=130, stale_min=20, vouch_total_min=90), cfg)
    assert rec.phase is AgentPhase.VOUCHED and actions == []
    # ...but a breach past the extended budget re-enters the ladder (review #3:
    # VOUCHED must not be a trap state that escapes detection forever).
    o = _obs(elapsed_min=260, stale_min=20, vouch_total_min=90)
    rec, _ = evaluate(rec, o, cfg)                                   # VOUCHED -> SUSPECT
    rec, actions = evaluate(rec, o, cfg)
    assert rec.phase is AgentPhase.NUDGED
    assert [a.kind for a in actions] == ["alert", "nudge"]           # fresh episode, fresh alert


def test_vouch_cap_swallows_vouch_then_grace_expiry_stops():
    from lib.subagent_watch import evaluate
    cfg = CCBConfig(max_tier=Tier.STOP)  # max_vouches=2, grace=10
    t0 = 1_000_000.0
    rec = _rec(phase=AgentPhase.NUDGED, vouches_used=2, extension_min=300,
               phase_changed_at=t0 - 60)                             # within grace (review #4)
    o_stuck = _obs(elapsed_min=500, stale_min=60, vouch_total_min=400, now=t0)
    rec, actions = evaluate(rec, o_stuck, cfg)
    assert rec.phase is AgentPhase.NUDGED and actions == []          # vouch IGNORED (cap hit)
    rec, actions = evaluate(rec, _obs(elapsed_min=511, stale_min=71, vouch_total_min=400,
                                      now=t0 + 11 * 60), cfg)
    assert rec.phase is AgentPhase.STOP_REQUESTED                    # grace expired -> Tier B
    assert [a.kind for a in actions] == ["stop"]


def test_recovery_during_nudge_grace_deescalates_without_vouch():
    from lib.subagent_watch import evaluate
    cfg = CCBConfig()
    t0 = 1_000_000.0
    rec = _rec(phase=AgentPhase.NUDGED, phase_changed_at=t0 - 60, alerted=True)
    # Transcript writing again and under every threshold: breach cleared on its own.
    rec, actions = evaluate(rec, _obs(elapsed_min=50, stale_min=0.5, now=t0), cfg)
    assert rec.phase is AgentPhase.RUNNING and actions == [] and rec.alerted is False


def test_recovery_during_stop_grace_never_escalates():
    from lib.subagent_watch import evaluate
    cfg = CCBConfig()
    t0 = 1_000_000.0
    rec = _rec(phase=AgentPhase.STOP_REQUESTED, phase_changed_at=t0 - 60, alerted=True)
    # Breach cleared after the stop directive went out: de-escalate, don't
    # advance to ESCALATED against a now-healthy agent (re-review #1).
    rec, actions = evaluate(rec, _obs(elapsed_min=50, stale_min=0.5, now=t0 + 11 * 60), cfg)
    assert rec.phase is AgentPhase.RUNNING and actions == []


def test_nudge_grace_expiry_escalates_to_stop_then_session():
    from lib.subagent_watch import evaluate
    cfg = CCBConfig(max_tier=Tier.STOP)  # grace=10
    t0 = 1_000_000.0
    rec = _rec(phase=AgentPhase.NUDGED, phase_changed_at=t0)
    rec, actions = evaluate(rec, _obs(elapsed_min=200, stale_min=60, now=t0 + 11 * 60), cfg)
    assert rec.phase is AgentPhase.STOP_REQUESTED
    assert [a.kind for a in actions] == ["stop"]
    rec, actions = evaluate(rec, _obs(elapsed_min=210, stale_min=70, now=t0 + 22 * 60), cfg)
    assert rec.phase is AgentPhase.ESCALATED
    assert [a.kind for a in actions] == ["escalate"]


def test_max_tier_observe_alerts_exactly_once_then_parks():
    from lib.subagent_watch import evaluate
    cfg = CCBConfig(max_tier=Tier.OBSERVE)
    o = _obs(elapsed_min=600, stale_min=600)
    rec, actions = evaluate(_rec(), o, cfg)
    assert actions == []                                             # debounce tick 1
    rec, actions = evaluate(rec, o, cfg)
    assert [a.kind for a in actions] == ["alert"]                    # the ONE alert
    for _ in range(3):                                               # review #6: Phase 1 runs
        rec, actions = evaluate(rec, o, cfg)                         # for days — no spam
        assert actions == []
    assert rec.phase is AgentPhase.SUSPECT                           # parked; no nudge ever


def test_state_roundtrip_and_no_realert_after_restart(tmp_path):
    from lib.ccb_types import AgentPhase, AgentRecord
    from lib.subagent_watch import ParentScan, WatchState, load_state, save_state

    st = WatchState(
        agents={"agent-x-0123456789abcdef": AgentRecord(
            name="agent-x-0123456789abcdef", teammate_id="x",
            phase=AgentPhase.NUDGED, vouches_used=1, extension_min=90,
            phase_changed_at=1_000_000.0)},
        parent_scan=ParentScan(offset=12345, msg_counts={"y": 7}, vouches={"x": 90}),
    )
    p = tmp_path / ".ccb-state.json"
    save_state(p, st)
    st2 = load_state(p)
    assert st2.agents["agent-x-0123456789abcdef"].phase is AgentPhase.NUDGED
    assert st2.parent_scan.offset == 12345 and st2.parent_scan.msg_counts == {"y": 7}


def test_load_state_missing_or_corrupt_returns_fresh(tmp_path):
    from lib.subagent_watch import load_state

    assert load_state(tmp_path / "absent.json").agents == {}
    bad = tmp_path / "bad.json"
    bad.write_text("{truncated")
    assert load_state(bad).agents == {}   # never crash the watcher


def test_resume_alert_appends_under_heading_with_flock(tmp_path):
    from lib.subagent_watch import append_resume_alert

    resume = tmp_path / "RESUME.md"
    resume.write_text("# RESUME\n\n## State\n- fine\n")
    append_resume_alert(resume, "watch: teammate sr6 nudged at 92min (session $41.20)")
    append_resume_alert(resume, "watch: teammate sr6 stop requested at 104min")

    text = resume.read_text()
    assert text.count("### Stuck-subagent alerts") == 1     # heading created once
    assert "sr6 nudged" in text and "stop requested" in text


def test_notify_cmd_receives_message_on_stdin(tmp_path):
    from lib.ccb_types import CCBConfig
    from lib.subagent_watch import notify

    out = tmp_path / "sink.txt"
    cfg = CCBConfig(notify_cmd=f"cat > {out}")
    notify(cfg, "teammate sr6 nudged")
    assert out.read_text() == "teammate sr6 nudged"


def test_notify_never_raises_on_broken_cmd():
    from lib.ccb_types import CCBConfig
    from lib.subagent_watch import notify

    notify(CCBConfig(notify_cmd="/no/such/binary"), "x")   # must not raise
    notify(CCBConfig(notify_cmd=None), "x")                # no-op


def test_ledger_appends_transition_with_signals_and_config(tmp_path):
    from lib.ccb_types import AgentRecord, CCBConfig, EventKind, Tier
    from lib.subagent_watch import ledger_write

    ledger = tmp_path / "events.jsonl"
    rec = AgentRecord(name="agent-sr6-cost-regrade-a8829e1a20628718",
                      teammate_id="sr6-cost-regrade",
                      peak_elapsed_min=92.0, peak_stale_min=14.0)
    ledger_write(
        ledger, EventKind.NUDGE, rec, CCBConfig(max_tier=Tier.STOP),
        session_id="1e0c8efe-964a-4167-b722-8019792e8645", cwd="/home/ff235/dev/Oasis/StrategyA",
        elapsed_min=92.0, stale_min=14.0, session_cost_usd=41.2, open_tasks=3,
        now_iso="2026-07-13T12:00:00+00:00", orchestrator_model="claude-opus-4-8[1m]",
    )
    ledger_write(  # second line appends, never truncates
        ledger, EventKind.RESOLVED, rec, CCBConfig(),
        session_id="1e0c8efe-964a-4167-b722-8019792e8645", cwd="/home/ff235/dev/Oasis/StrategyA",
        elapsed_min=97.0, stale_min=0.0, session_cost_usd=42.0, open_tasks=2,
        now_iso="2026-07-13T12:05:00+00:00",   # model omitted -> captured as None
    )

    lines = [json.loads(l) for l in ledger.read_text().splitlines()]
    assert [l["event"] for l in lines] == ["nudge", "resolved"]
    first = lines[0]
    assert first["teammate_id"] == "sr6-cost-regrade"
    assert first["elapsed_min"] == 92.0 and first["session_cost_usd"] == 41.2
    assert first["cfg"]["t_hard_min"] == 120 and first["cfg"]["max_tier"] == "stop"
    assert first["peak_elapsed_min"] == 92.0     # healthy-distribution data
    assert first["session_id"].startswith("1e0c8efe")
    assert first["orchestrator_model"] == "claude-opus-4-8[1m]"   # captured from day one
    assert lines[1]["orchestrator_model"] is None                 # absent -> null, never missing


def test_ledger_write_never_raises_on_unwritable_path():
    from lib.ccb_types import AgentRecord, CCBConfig, EventKind
    from lib.subagent_watch import ledger_write
    from pathlib import Path

    rec = AgentRecord(name="agent-x-0123456789abcdef", teammate_id="x")
    ledger_write(Path("/proc/nope/events.jsonl"), EventKind.ALERT, rec, CCBConfig(),
                 session_id="s", cwd="/x", elapsed_min=1, stale_min=1,
                 session_cost_usd=None, open_tasks=None,
                 now_iso="2026-07-13T12:00:00+00:00")  # must not raise


def test_report_aggregates_outcomes_and_percentiles(tmp_path):
    import json
    from lib.subagent_watch import summarize_ledger

    ledger = tmp_path / "events.jsonl"
    rows = [
        # healthy agent, never flagged: baseline data
        {"event": "resolved", "teammate_id": "ok1", "cwd": "/p", "peak_elapsed_min": 80.0,
         "peak_stale_min": 4.0, "vouches_used": 0, "ts": "2026-07-13T10:00:00+00:00"},
        # flagged, vouched, finished fine: FALSE POSITIVE
        {"event": "nudge", "teammate_id": "long1", "cwd": "/p", "peak_elapsed_min": 130.0,
         "peak_stale_min": 12.0, "vouches_used": 0, "ts": "2026-07-13T10:10:00+00:00"},
        {"event": "vouch", "teammate_id": "long1", "cwd": "/p", "peak_elapsed_min": 130.0,
         "peak_stale_min": 12.0, "vouches_used": 1, "ts": "2026-07-13T10:12:00+00:00"},
        {"event": "resolved", "teammate_id": "long1", "cwd": "/p", "peak_elapsed_min": 200.0,
         "peak_stale_min": 12.0, "vouches_used": 1, "ts": "2026-07-13T11:30:00+00:00"},
        # flagged, stopped: TRUE POSITIVE
        {"event": "nudge", "teammate_id": "stuck1", "cwd": "/p", "peak_elapsed_min": 125.0,
         "peak_stale_min": 60.0, "vouches_used": 0, "ts": "2026-07-13T12:00:00+00:00"},
        {"event": "stop", "teammate_id": "stuck1", "cwd": "/p", "peak_elapsed_min": 140.0,
         "peak_stale_min": 75.0, "vouches_used": 0, "ts": "2026-07-13T12:11:00+00:00"},
        {"event": "stop_verified", "teammate_id": "stuck1", "cwd": "/p",
         "peak_elapsed_min": 141.0, "peak_stale_min": 75.0, "vouches_used": 0,
         "ts": "2026-07-13T12:14:00+00:00"},
    ]
    ledger.write_text("".join(json.dumps(r) + "\n" for r in rows))

    s = summarize_ledger(ledger)
    assert s["agents_seen"] == 3
    assert s["nudges"] == 2
    assert s["vouched_after_nudge"] == 1      # false-positive count
    assert s["stopped_after_nudge"] == 1      # true-positive count
    assert s["kills"] == 0
    assert s["healthy_peak_elapsed_p95"] >= 80.0   # threshold-tuning input


def test_report_handles_empty_or_corrupt_ledger(tmp_path):
    from lib.subagent_watch import summarize_ledger

    empty = tmp_path / "none.jsonl"
    assert summarize_ledger(empty)["agents_seen"] == 0
    bad = tmp_path / "bad.jsonl"
    bad.write_text("not json\n" + '{"event": "resolved", "teammate_id": "a", "cwd": "/p", '
                   '"peak_elapsed_min": 1, "peak_stale_min": 1, "vouches_used": 0, '
                   '"ts": "2026-07-13T10:00:00+00:00"}\n')
    assert summarize_ledger(bad)["agents_seen"] == 1   # skips bad lines, never raises


def test_scanner_captures_in_band_idle_notification(tmp_path):
    from lib.subagent_watch import ParentScan, scan_parent_transcript, _parse_iso

    ts = "2026-07-13T12:35:12.937Z"
    idle_json = ('{"type":"idle_notification","from":"cb-phase1","timestamp":"'
                 + ts + '","idleReason":"available"}')
    content = ("Another Claude session sent a message:\n"
               '<teammate-message teammate_id="cb-phase1" color="blue">\n'
               + idle_json + "\n</teammate-message>")
    t = tmp_path / "parent.jsonl"
    _wr(t, [{"type": "user", "message": {"role": "user", "content": content}}])

    scan = scan_parent_transcript(t, ParentScan())
    # idle captured from the PARENT transcript (in-band, S4), keyed by 'from'
    # (== the teammate's .meta.json "name"), stored as epoch seconds.
    assert scan.idle == {"cb-phase1": _parse_iso(ts).timestamp()}


def test_scanner_keeps_latest_idle_and_survives_bad_timestamp(tmp_path):
    from lib.subagent_watch import ParentScan, scan_parent_transcript, _parse_iso

    def idle_line(name, ts):
        return {"type": "user", "message": {"role": "user", "content":
                '<teammate-message teammate_id="' + name + '">\n'
                '{"type":"idle_notification","from":"' + name + '","timestamp":"'
                + ts + '","idleReason":"available"}\n</teammate-message>'}}

    t = tmp_path / "parent.jsonl"
    _wr(t, [idle_line("a", "2026-07-13T10:00:00.000Z"),
            idle_line("a", "2026-07-13T11:00:00.000Z"),   # later idle wins
            idle_line("b", "not-a-timestamp")])            # unparseable -> skipped, no crash
    scan = scan_parent_transcript(t, ParentScan())
    assert scan.idle == {"a": _parse_iso("2026-07-13T11:00:00.000Z").timestamp()}


def test_idle_completed_predicate_is_reversible():
    from lib.subagent_watch import idle_completed

    idle = 1000.0
    assert idle_completed(idle, transcript_mtime=999.0) is True     # nothing written since idle
    assert idle_completed(idle, transcript_mtime=1000.0) is True    # boundary: idle >= last write
    assert idle_completed(idle, transcript_mtime=1001.0) is False   # wrote after idle -> re-watch
    assert idle_completed(None, transcript_mtime=999.0) is False    # no idle signal seen
    assert idle_completed(idle, transcript_mtime=None) is False     # unknown mtime


# --- Task 11: run_tick orchestration (observe mode) -------------------------

def _mk_agent(session_dir, name, first_ts, *, mtime=None, team_name="session-abcd1234"):
    """A subagent transcript + its .meta.json under session_dir/subagents.
    `first_ts` is the first line's timestamp (drives elapsed); `mtime`, if
    given, is pinned via os.utime (drives staleness) so tests need no wall
    clock. Returns the transcript path (stem = 'agent-<name>')."""
    sub = session_dir / "subagents"
    sub.mkdir(parents=True, exist_ok=True)
    p = sub / ("agent-%s.jsonl" % name)
    p.write_text(json.dumps({"type": "assistant", "timestamp": first_ts}) + "\n")
    meta = {"name": name, "taskKind": "in_process_teammate"}
    if team_name is not None:
        meta["teamName"] = team_name
    p.with_suffix(".meta.json").write_text(json.dumps(meta))
    if mtime is not None:
        os.utime(p, (mtime, mtime))
    return p


def test_run_tick_alerts_stuck_agent_writes_ledger_resume_and_state(tmp_path, monkeypatch):
    from lib.ccb_types import AgentPhase, CCBConfig, Tier
    from lib.subagent_watch import WatchState, _parse_iso, load_state, run_tick

    monkeypatch.setattr("lib.subagent_watch.session_cost_usd", lambda *a, **k: 12.5)

    session_dir = tmp_path / "proj"
    now = _parse_iso("2026-07-13T11:00:00+00:00").timestamp()
    # Stuck: started 60 min ago, transcript quiet for 20 min -> quiet breach.
    _mk_agent(session_dir, "cb-stuck", "2026-07-13T10:00:00+00:00", mtime=now - 20 * 60)
    # Healthy: just started, writing now -> stays RUNNING, never alerts.
    _mk_agent(session_dir, "cb-fresh", "2026-07-13T11:00:00+00:00", mtime=now)

    # A teams session: a task dir makes open_task_count return a real number.
    tasks = tmp_path / "tasks" / "session-abcd1234"
    tasks.mkdir(parents=True)
    (tasks / "1.json").write_text('{"id":"1","status":"in_progress"}')

    sink = tmp_path / "notify.txt"
    cfg = CCBConfig(max_tier=Tier.OBSERVE, notify_cmd="cat >> %s" % sink)
    resume = tmp_path / "RESUME.md"
    ledger = tmp_path / "events.jsonl"
    state_path = tmp_path / ".ccb-state.json"

    kw = dict(session_dir=session_dir, config_root=tmp_path, session_id="s-uuid",
              cwd="/home/ff235/dev/proj", cfg=cfg, now=now, parent_transcript=None,
              resume_path=resume, ledger_path=ledger, state_path=state_path,
              orchestrator_model="claude-sonnet-5")

    state = run_tick(state=WatchState(), **kw)   # debounce tick 1: SUSPECT, silent
    assert not resume.exists()                   # nothing alerted on the first breach
    state = run_tick(state=state, **kw)          # tick 2: the one alert

    text = resume.read_text()
    assert "### Stuck-subagent alerts" in text
    assert "cb-stuck stuck at 60min" in text and "1 open task" in text and "$12.50" in text
    assert "cb-fresh" not in text                # healthy agent never alerted

    rows = [json.loads(l) for l in ledger.read_text().splitlines()]
    assert [r["event"] for r in rows] == ["alert"]
    assert rows[0]["teammate_id"] == "cb-stuck" and rows[0]["open_tasks"] == 1
    assert rows[0]["orchestrator_model"] == "claude-sonnet-5"   # threaded through run_tick

    assert sink.read_text().count("cb-stuck") == 1     # notify fired exactly once

    persisted = load_state(state_path)
    assert persisted.agents["agent-cb-stuck"].phase is AgentPhase.SUSPECT
    assert persisted.agents["agent-cb-fresh"].phase is AgentPhase.RUNNING


def test_run_tick_logs_one_resolved_line_on_completion_no_dup(tmp_path, monkeypatch):
    from lib.ccb_types import AgentPhase, CCBConfig, Tier
    from lib.subagent_watch import WatchState, _parse_iso, load_state, run_tick

    monkeypatch.setattr("lib.subagent_watch.session_cost_usd", lambda *a, **k: None)

    session_dir = tmp_path / "proj"
    idle_ts = "2026-07-13T10:30:00.000Z"
    idle_epoch = _parse_iso(idle_ts).timestamp()
    # Completed: went idle at idle_ts and wrote nothing since (mtime < idle).
    _mk_agent(session_dir, "cb-done", "2026-07-13T10:00:00+00:00", mtime=idle_epoch - 60)

    # Parent transcript carries the in-band idle_notification (S4 completion).
    parent = tmp_path / "parent.jsonl"
    content = ('<teammate-message teammate_id="cb-done">\n'
               '{"type":"idle_notification","from":"cb-done","timestamp":"'
               + idle_ts + '","idleReason":"available"}\n</teammate-message>')
    parent.write_text(
        json.dumps({"type": "user", "message": {"role": "user", "content": content}}) + "\n")

    now = _parse_iso("2026-07-13T11:00:00+00:00").timestamp()
    resume = tmp_path / "RESUME.md"
    ledger = tmp_path / "events.jsonl"
    state_path = tmp_path / ".ccb-state.json"

    kw = dict(session_dir=session_dir, config_root=tmp_path, session_id="s-uuid",
              cwd="/p", cfg=CCBConfig(max_tier=Tier.OBSERVE), now=now,
              parent_transcript=parent, resume_path=resume, ledger_path=ledger,
              state_path=state_path)

    state = WatchState()
    for _ in range(3):                           # transition-in fires once, then never again
        state = run_tick(state=state, **kw)

    rows = [json.loads(l) for l in ledger.read_text().splitlines()]
    assert [r["event"] for r in rows] == ["resolved"]     # exactly one, never duplicated per tick
    assert not resume.exists()                            # a completed agent never alerts
    assert load_state(state_path).agents["agent-cb-done"].phase is AgentPhase.RESOLVED


def test_run_tick_non_teams_forces_observe_only_and_logs_once(tmp_path, monkeypatch):
    from lib.ccb_types import AgentPhase, CCBConfig, Tier
    from lib.subagent_watch import WatchState, _parse_iso, load_state, run_tick

    monkeypatch.setattr("lib.subagent_watch.session_cost_usd", lambda *a, **k: None)

    session_dir = tmp_path / "proj"
    now = _parse_iso("2026-07-13T11:00:00+00:00").timestamp()
    # Stuck, but a non-teams session: no team, no idle, no task dir.
    _mk_agent(session_dir, "solo", "2026-07-13T09:00:00+00:00",
              mtime=now - 40 * 60, team_name=None)

    logs = []
    resume = tmp_path / "RESUME.md"
    kw = dict(session_dir=session_dir, config_root=tmp_path, session_id="",
              cwd="/p", cfg=CCBConfig(max_tier=Tier.STOP),   # would allow nudges in a teams session
              now=now, parent_transcript=None, resume_path=resume,
              ledger_path=tmp_path / "events.jsonl", state_path=tmp_path / ".ccb-state.json",
              log=logs.append, flags={})

    state = WatchState()
    for _ in range(4):
        state = run_tick(state=state, **kw)

    forced = [m for m in logs if "forced to observe-only" in m]
    assert len(forced) == 1                                  # logged once, not every tick
    assert not any("phase2 not wired" in m for m in logs)    # capped before any nudge action
    # Even at cfg=STOP the agent only ever parks in SUSPECT (observe behaviour),
    # never NUDGED — proving the non-teams cap held across the grace window.
    assert load_state(tmp_path / ".ccb-state.json").agents["agent-solo"].phase is AgentPhase.SUSPECT


# --- Task 11 Step 3: the bin SubagentWatcher wiring, end to end -------------

def _load_ccage_auto():
    """Import bin/ccage-auto as a module (it has no .py extension). Module-level
    code is import-safe: main() is guarded by __main__, and _load_ccb() only
    resolves lib/. Returns the module, or None if CB failed to load."""
    import importlib.util
    from importlib.machinery import SourceFileLoader

    path = str(Path(__file__).resolve().parent.parent / "bin" / "ccage-auto")
    loader = SourceFileLoader("ccage_auto", path)
    spec = importlib.util.spec_from_loader("ccage_auto", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def test_subagent_watcher_class_tick_end_to_end(tmp_path, monkeypatch):
    """Drive the REAL bin `SubagentWatcher` synchronously via `_tick()` — the
    wiring glue the `run_tick` unit tests don't reach: config_root derivation
    (`sdir.parent.parent`), the RESUME/ledger paths, `session_id` from
    `active_jsonl`, `orchestrator_model` from `latest_usage`, and state
    persistence. This is the observe-mode live-fire (Task 11 Step 3) made
    deterministic — no pty, no thread, no wall-clock injection games."""
    import time as _time
    from datetime import datetime, timezone

    from lib.ccb_types import AgentPhase
    from lib.subagent_watch import load_state

    ccage_auto = _load_ccage_auto()
    if ccage_auto._ccb_watch is None:
        import pytest
        pytest.skip("circuit-breaker lib not importable")

    monkeypatch.setattr("lib.subagent_watch.session_cost_usd", lambda *a, **k: None)
    monkeypatch.delenv("CCAGE_SLOT", raising=False)

    now = _time.time()
    cfg_root = tmp_path / "config"
    cwd = tmp_path / "proj"
    cwd.mkdir()
    sdir = cfg_root / "projects" / ccage_auto.cwd_slug(str(cwd))
    subs = sdir / "subagents"
    subs.mkdir(parents=True)

    def iso(e):
        return datetime.fromtimestamp(e, timezone.utc).isoformat()

    def mk(name, first_ts, mtime, team="session-live1234"):
        p = subs / ("agent-%s.jsonl" % name)
        p.write_text(json.dumps({"type": "assistant", "timestamp": iso(first_ts)}) + "\n")
        p.with_suffix(".meta.json").write_text(json.dumps(
            {"name": name, "teamName": team, "taskKind": "in_process_teammate"}))
        os.utime(p, (mtime, mtime))

    mk("cb-stuck", now - 7200, now - 1800)      # 120min old, 30min stale -> breach
    mk("cb-fresh", now, now)                     # brand new -> healthy, silent
    idle_epoch = now - 300
    mk("cb-done", now - 3600, idle_epoch - 60)   # went idle, wrote nothing since -> RESOLVED

    tdir = cfg_root / "tasks" / "session-live1234"
    tdir.mkdir(parents=True)
    (tdir / "1.json").write_text('{"id":"1","status":"in_progress"}')

    notify = tmp_path / "notify.txt"
    ledger = tmp_path / "ledger.jsonl"
    monkeypatch.setenv("CCB_MAX_TIER", "observe")
    monkeypatch.setenv("CCB_T_SOFT_MIN", "1")
    monkeypatch.setenv("CCB_T_STALE_MIN", "1")
    monkeypatch.setenv("CCB_NOTIFY_CMD", "cat >> %s" % notify)
    monkeypatch.setenv("CCB_LEDGER", str(ledger))

    logf = (tmp_path / "log").open("a")
    w = ccage_auto.SubagentWatcher(poll=1, cwd=str(cwd), sdir=str(sdir), logf=logf)

    # Parent transcript must post-date the watcher's start_time (active_jsonl
    # `since` filter); it carries the orchestrator model + the in-band idle signal.
    parent = sdir / "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"
    content = ('<teammate-message teammate_id="cb-done">\n'
               '{"type":"idle_notification","from":"cb-done","timestamp":"'
               + iso(idle_epoch) + '","idleReason":"available"}\n</teammate-message>')
    with parent.open("w") as f:
        f.write(json.dumps({"type": "assistant", "message": {
            "model": "claude-opus-4-8[1m]",
            "usage": {"input_tokens": 20, "cache_read_input_tokens": 5,
                      "cache_creation_input_tokens": 2}}}) + "\n")
        f.write(json.dumps({"type": "user", "message": {"role": "user", "content": content}}) + "\n")
    os.utime(parent, (w.start_time + 5, w.start_time + 5))

    w._tick()          # debounce tick 1
    w._tick()          # tick 2 -> the alert
    logf.close()

    rows = [json.loads(x) for x in ledger.read_text().splitlines()]
    events = [(r["event"], r["teammate_id"]) for r in rows]
    assert ("alert", "cb-stuck") in events
    assert ("resolved", "cb-done") in events                       # healthy-resolved baseline
    assert not any(tid == "cb-fresh" for _, tid in events)         # healthy agent never logged
    assert sum(1 for e, _ in events if e == "alert") == 1          # no re-alert
    assert sum(1 for e, _ in events if e == "resolved") == 1       # RESOLVED logged once, not per tick
    assert all(r.get("orchestrator_model") == "claude-opus-4-8[1m]" for r in rows)

    resume_txt = (cwd / "RESUME.md").read_text()
    assert "### Stuck-subagent alerts" in resume_txt and "cb-stuck stuck" in resume_txt
    assert notify.read_text().count("cb-stuck") == 1

    st = load_state(sdir / ".ccb-state.json")
    assert st.agents["agent-cb-stuck"].phase is AgentPhase.SUSPECT
    assert st.agents["agent-cb-done"].phase is AgentPhase.RESOLVED
    assert st.agents["agent-cb-fresh"].phase is AgentPhase.RUNNING


# --- Task 13: the Tier-A nudge message (pure) -------------------------------

def test_nudge_message_contains_protocol_and_facts():
    from lib.ccb_types import AgentRecord
    from lib.subagent_watch import nudge_message

    rec = AgentRecord(name="agent-sr6-cost-regrade-a8829e1a20628718",
                      teammate_id="sr6-cost-regrade")
    msg = nudge_message(rec, elapsed_min=92, stale_min=14, session_cost_usd=41.2,
                        open_tasks=3, extend_hint_min=60, deadline_min=10)
    assert "sr6-cost-regrade" in msg
    # extend hint (60) rides in the vouch marker; deadline (grace=10) in the escape.
    assert "CCB-VOUCH agent=sr6-cost-regrade extend=60" in msg
    assert "TaskStop" in msg and "92" in msg
    assert "within 10 min" in msg          # deadline = grace, NOT the extend hint
    assert "$41.20" in msg and "3 open tasks" in msg


def test_nudge_message_tolerates_missing_cost_and_open_tasks():
    from lib.ccb_types import AgentRecord
    from lib.subagent_watch import nudge_message

    rec = AgentRecord(name="agent-x-0", teammate_id="x")
    msg = nudge_message(rec, elapsed_min=50, stale_min=12, session_cost_usd=None,
                        open_tasks=None, extend_hint_min=60, deadline_min=10)
    assert "unknown" in msg and "? open tasks" in msg     # never a stray None/format crash


# --- Task 12/13: nudge action wired through run_tick + the pty injector ------

def test_run_tick_nudge_injects_and_ledgers(tmp_path, monkeypatch):
    from lib.ccb_types import AgentPhase, CCBConfig, Tier
    from lib.subagent_watch import WatchState, _parse_iso, load_state, run_tick

    monkeypatch.setattr("lib.subagent_watch.session_cost_usd", lambda *a, **k: 41.2)

    session_dir = tmp_path / "proj"
    now = _parse_iso("2026-07-13T11:00:00+00:00").timestamp()
    # Stuck: started 60 min ago (> soft 45), quiet 20 min (> stale 10) -> breach.
    _mk_agent(session_dir, "cb-stuck", "2026-07-13T10:00:00+00:00", mtime=now - 20 * 60)

    tasks = tmp_path / "tasks" / "session-abcd1234"
    tasks.mkdir(parents=True)
    (tasks / "1.json").write_text('{"id":"1","status":"in_progress"}')

    injected = []
    cfg = CCBConfig(max_tier=Tier.NUDGE)          # teams session -> nudge allowed
    resume = tmp_path / "RESUME.md"
    ledger = tmp_path / "events.jsonl"
    state_path = tmp_path / ".ccb-state.json"
    kw = dict(session_dir=session_dir, config_root=tmp_path, session_id="s-uuid",
              cwd="/p", cfg=cfg, now=now, parent_transcript=None,
              resume_path=resume, ledger_path=ledger, state_path=state_path,
              inject=lambda t: injected.append(t) or True)

    state = run_tick(state=WatchState(), **kw)    # debounce tick 1: SUSPECT, silent
    assert injected == []                         # nothing injected on the first breach
    state = run_tick(state=state, **kw)           # tick 2: alert + nudge

    assert len(injected) == 1                      # exactly one nudge injected
    text = injected[0]
    assert "CCB-VOUCH agent=cb-stuck extend=60" in text and "TaskStop" in text
    assert "within 10 min" in text                 # grace deadline, not the hint

    rows = [json.loads(l) for l in ledger.read_text().splitlines()]
    assert [r["event"] for r in rows] == ["alert", "nudge"]
    assert rows[1]["phase"] == "nudged" and rows[1]["teammate_id"] == "cb-stuck"

    assert "nudged: teammate cb-stuck" in resume.read_text()
    assert load_state(state_path).agents["agent-cb-stuck"].phase is AgentPhase.NUDGED


def test_run_tick_observe_never_injects(tmp_path, monkeypatch):
    from lib.ccb_types import CCBConfig, Tier
    from lib.subagent_watch import WatchState, _parse_iso, run_tick

    monkeypatch.setattr("lib.subagent_watch.session_cost_usd", lambda *a, **k: None)
    session_dir = tmp_path / "proj"
    now = _parse_iso("2026-07-13T11:00:00+00:00").timestamp()
    _mk_agent(session_dir, "cb-stuck", "2026-07-13T10:00:00+00:00", mtime=now - 20 * 60)
    tasks = tmp_path / "tasks" / "session-abcd1234"
    tasks.mkdir(parents=True)
    (tasks / "1.json").write_text('{"id":"1","status":"in_progress"}')

    injected = []
    kw = dict(session_dir=session_dir, config_root=tmp_path, session_id="s-uuid",
              cwd="/p", cfg=CCBConfig(max_tier=Tier.OBSERVE), now=now,
              parent_transcript=None, resume_path=tmp_path / "RESUME.md",
              ledger_path=tmp_path / "events.jsonl", state_path=tmp_path / ".ccb-state.json",
              inject=lambda t: injected.append(t) or True)
    state = WatchState()
    for _ in range(4):                             # well past debounce + grace
        state = run_tick(state=state, **kw)
    assert injected == []                          # observe mode never nudges


def _mk_watcher(tmp_path, **kw):
    """A real bin SubagentWatcher over a tmp sdir, or skip if the CB lib is
    absent. StringIO log so _log() is inspectable."""
    import io

    ccage_auto = _load_ccage_auto()
    if ccage_auto._ccb_watch is None:
        import pytest
        pytest.skip("circuit-breaker lib not importable")
    sdir = tmp_path / "config" / "projects" / "slug"
    sdir.mkdir(parents=True)
    log = io.StringIO()
    return ccage_auto.SubagentWatcher(poll=1, cwd=str(tmp_path), sdir=str(sdir),
                                      logf=log, **kw), log


def test_subagent_watcher_inject_writes_collapsed_text_then_cr(tmp_path):
    import threading

    r, w = os.pipe()
    lock = threading.Lock()
    watcher, _ = _mk_watcher(tmp_path, master_fd=w, write_lock=lock)

    assert watcher.inject_message("line one\nline two   tabbed") is True
    got = os.read(r, 4096)
    # S1's verified shape: single-line body (whitespace/newlines collapsed) + \r.
    assert got == b"line one line two tabbed\r"
    os.close(r)
    os.close(w)


def test_subagent_watcher_inject_noop_without_pty(tmp_path):
    watcher, log = _mk_watcher(tmp_path)                 # no master_fd/write_lock
    assert watcher.inject_message("hello") is False
    assert "inject skipped (no pty)" in log.getvalue()


def test_subagent_watcher_inject_rate_limited_to_one_per_tick(tmp_path):
    import threading

    r, w = os.pipe()
    watcher, log = _mk_watcher(tmp_path, master_fd=w, write_lock=threading.Lock())
    assert watcher.inject_message("first") is True
    assert watcher.inject_message("second") is False     # same tick -> refused
    assert os.read(r, 4096) == b"first\r"                 # only the first reached the pty
    assert "rate-limited" in log.getvalue()
    watcher._injected_this_tick = False                  # next tick clears it (as _tick does)
    assert watcher.inject_message("third") is True
    assert os.read(r, 4096) == b"third\r"
    os.close(r)
    os.close(w)


def test_subagent_watcher_inject_gated_on_tui_ready(tmp_path):
    import threading

    r, w = os.pipe()
    ready = threading.Event()                            # TUI not ready (bypass screen up)
    watcher, log = _mk_watcher(tmp_path, master_fd=w, write_lock=threading.Lock(),
                               ready_event=ready)
    assert watcher.inject_message("early") is False
    assert "TUI not ready" in log.getvalue()
    ready.set()
    assert watcher.inject_message("ready now") is True
    assert os.read(r, 4096) == b"ready now\r"
    os.close(r)
    os.close(w)


# --- Task 14: Tier B — surgical stop + CCB-STOPPED verification --------------

def test_scanner_captures_ccb_stopped_marker(tmp_path):
    from lib.subagent_watch import ParentScan, scan_parent_transcript

    p = tmp_path / "parent.jsonl"
    p.write_text(json.dumps({"type": "user", "message": {"role": "user",
                 "content": "CCB-STOPPED agent=cb-stuck done"}}) + "\n")
    scan = scan_parent_transcript(p, ParentScan())
    assert scan.stopped.get("cb-stuck") == 1


def test_stop_message_carries_grammar_and_orphan_caveat():
    from lib.ccb_types import AgentRecord
    from lib.subagent_watch import stop_message

    msg = stop_message(AgentRecord(name="agent-x-0", teammate_id="sr6"), grace_min=10)
    assert "TaskStop" in msg and "CCB-STOPPED agent=sr6" in msg
    assert "sub-processes" in msg          # S2 orphaned-child caveat is present


def test_verified_stop_resolves_from_any_phase_and_never_escalates():
    from lib.subagent_watch import evaluate

    cfg = CCBConfig()
    # A CCB-STOPPED marker (o.stopped) resolves regardless of current phase —
    # even mid-grace STOP_REQUESTED — and emits nothing (never escalates).
    for phase in (AgentPhase.NUDGED, AgentPhase.STOP_REQUESTED, AgentPhase.SUSPECT):
        rec, actions = evaluate(_rec(phase=phase),
                                _obs(elapsed_min=200, stale_min=90, stopped=True), cfg)
        assert rec.phase is AgentPhase.RESOLVED and actions == []
    # And it is terminal: with the marker still set, it stays RESOLVED (unlike a
    # bare completion signal, which can clear and revert to RUNNING).
    rec, _ = evaluate(_rec(phase=AgentPhase.RESOLVED),
                      _obs(elapsed_min=200, stale_min=90, stopped=True), cfg)
    assert rec.phase is AgentPhase.RESOLVED


def _stuck_teams_kw(tmp_path, session_dir, now, cfg, **over):
    """Shared setup for the stop/escalate run_tick tests: one quiet-stuck teammate
    on a teams session (task dir => is_teams), plus the RESUME/ledger/state paths."""
    _mk_agent(session_dir, "cb-stuck", "2026-07-13T10:00:00+00:00", mtime=now - 20 * 60)
    tasks = tmp_path / "tasks" / "session-abcd1234"
    tasks.mkdir(parents=True, exist_ok=True)
    (tasks / "1.json").write_text('{"id":"1","status":"in_progress"}')
    kw = dict(session_dir=session_dir, config_root=tmp_path, session_id="s-uuid",
              cwd="/p", cfg=cfg, parent_transcript=None,
              resume_path=tmp_path / "RESUME.md", ledger_path=tmp_path / "events.jsonl",
              state_path=tmp_path / ".ccb-state.json")
    kw.update(over)
    return kw


def test_run_tick_stop_then_ccb_stopped_verifies(tmp_path, monkeypatch):
    from lib.ccb_types import AgentPhase, CCBConfig, Tier
    from lib.subagent_watch import WatchState, _parse_iso, load_state, run_tick

    monkeypatch.setattr("lib.subagent_watch.session_cost_usd", lambda *a, **k: None)
    session_dir = tmp_path / "proj"
    t0 = _parse_iso("2026-07-13T12:00:00+00:00").timestamp()
    parent = tmp_path / "parent.jsonl"
    parent.write_text(json.dumps({"type": "assistant", "message": {"role": "assistant",
                      "content": "working"}}) + "\n")

    injected, killed = [], []
    cfg = CCBConfig(max_tier=Tier.STOP)          # grace_min=10 default
    kw = _stuck_teams_kw(tmp_path, session_dir, t0, cfg, parent_transcript=parent,
                         inject=lambda t: injected.append(t) or True,
                         kill_session=lambda tid: killed.append(tid) or True)

    state = run_tick(state=WatchState(), now=t0, **kw)          # SUSPECT
    state = run_tick(state=state, now=t0, **kw)                 # NUDGED (+ nudge inject)
    assert len(injected) == 1
    state = run_tick(state=state, now=t0 + 660, **kw)           # grace expired -> STOP_REQUESTED
    assert load_state(kw["state_path"]).agents["agent-cb-stuck"].phase is AgentPhase.STOP_REQUESTED
    assert len(injected) == 2 and "CCB-STOPPED agent=cb-stuck" in injected[1]   # stop directive

    # Orchestrator replies with the verification marker; next tick resolves it.
    with parent.open("a") as f:
        f.write(json.dumps({"type": "user", "message": {"role": "user",
                "content": "CCB-STOPPED agent=cb-stuck"}}) + "\n")
    state = run_tick(state=state, now=t0 + 720, **kw)
    assert load_state(kw["state_path"]).agents["agent-cb-stuck"].phase is AgentPhase.RESOLVED
    assert killed == []                                          # Tier B never kills

    events = [json.loads(l)["event"] for l in (kw["ledger_path"]).read_text().splitlines()]
    assert events == ["alert", "nudge", "stop", "stop_verified"]


# --- Task 15: Tier C — session-kill backstop --------------------------------

def test_kill_precondition_requires_unresponsive_parent_and_kill_tier():
    from lib.ccb_types import CCBConfig, Tier
    from lib.subagent_watch import kill_permitted

    cfg = CCBConfig(max_tier=Tier.KILL)          # parent_stale_min=15
    assert kill_permitted(cfg, parent_stale_min=20) is True
    assert kill_permitted(cfg, parent_stale_min=5) is False       # orchestrator alive -> NEVER kill
    assert kill_permitted(cfg, parent_stale_min=None) is False     # unreadable -> fail-safe alive
    assert kill_permitted(CCBConfig(max_tier=Tier.STOP), parent_stale_min=60) is False


def _drive_to_escalation(tmp_path, monkeypatch, cfg, parent):
    """Run the nudge->stop->escalate ladder to the ESCALATED transition (no vouch,
    no CCB-STOPPED). Returns (kw, injected, killed, final_state)."""
    from lib.subagent_watch import WatchState, _parse_iso, run_tick

    monkeypatch.setattr("lib.subagent_watch.session_cost_usd", lambda *a, **k: 7.0)
    session_dir = tmp_path / "proj"
    t0 = _parse_iso("2026-07-13T12:00:00+00:00").timestamp()
    injected, killed = [], []
    kw = _stuck_teams_kw(tmp_path, session_dir, t0, cfg, parent_transcript=parent,
                         inject=lambda t: injected.append(t) or True,
                         kill_session=lambda tid: killed.append(tid) or True)
    state = run_tick(state=WatchState(), now=t0, **kw)           # SUSPECT
    state = run_tick(state=state, now=t0, **kw)                  # NUDGED
    state = run_tick(state=state, now=t0 + 660, **kw)            # STOP_REQUESTED
    state = run_tick(state=state, now=t0 + 660 + 661, **kw)      # ESCALATED
    return kw, injected, killed, state


def test_run_tick_escalate_blocked_at_stop_tier_reissues_stop(tmp_path, monkeypatch):
    from lib.ccb_types import AgentPhase, CCBConfig, Tier
    from lib.subagent_watch import load_state

    parent = tmp_path / "parent.jsonl"
    parent.write_text(json.dumps({"type": "assistant"}) + "\n")     # parent alive-ish (fresh mtime)
    cfg = CCBConfig(max_tier=Tier.STOP)
    kw, injected, killed, _ = _drive_to_escalation(tmp_path, monkeypatch, cfg, parent)

    assert killed == []                                             # tier < kill -> never killed
    assert load_state(kw["state_path"]).agents["agent-cb-stuck"].phase is AgentPhase.ESCALATED
    events = [json.loads(l)["event"] for l in kw["ledger_path"].read_text().splitlines()]
    assert events == ["alert", "nudge", "stop", "escalate_blocked"]
    assert len(injected) == 3 and "CCB-STOPPED agent=cb-stuck" in injected[2]   # stop re-issued once
    assert "escalation blocked" in kw["resume_path"].read_text()


def test_run_tick_escalate_kills_when_orchestrator_unresponsive(tmp_path, monkeypatch):
    from lib.ccb_types import AgentPhase, CCBConfig, Tier
    from lib.subagent_watch import _parse_iso, load_state

    parent = tmp_path / "parent.jsonl"
    parent.write_text(json.dumps({"type": "assistant"}) + "\n")
    # Parent transcript quiet for an hour (orchestrator wedged); reads never bump
    # mtime, so parent_stale keeps growing across ticks -> kill_permitted True.
    old = _parse_iso("2026-07-13T11:00:00+00:00").timestamp()
    os.utime(parent, (old, old))
    cfg = CCBConfig(max_tier=Tier.KILL)
    kw, injected, killed, _ = _drive_to_escalation(tmp_path, monkeypatch, cfg, parent)

    assert killed == ["cb-stuck"]                                   # session terminated
    assert load_state(kw["state_path"]).agents["agent-cb-stuck"].phase is AgentPhase.ESCALATED
    events = [json.loads(l)["event"] for l in kw["ledger_path"].read_text().splitlines()]
    assert events == ["alert", "nudge", "stop", "kill"]
    dump = kw["resume_path"].read_text()
    assert "TIER-C KILL pre-mortem" in dump and "cb-stuck[escalated]" in dump


def test_subagent_watcher_kill_session_sigterms_the_child(tmp_path):
    import signal
    import subprocess

    proc = subprocess.Popen(["sleep", "30"])
    watcher, log = _mk_watcher(tmp_path, pid=proc.pid)
    assert watcher.kill_session("cb-stuck") is True
    assert proc.wait(timeout=5) == -signal.SIGTERM                  # child actually died on SIGTERM
    assert watcher.stop is True                                     # watcher stood itself down


def test_subagent_watcher_kill_session_noop_without_pid(tmp_path):
    watcher, log = _mk_watcher(tmp_path)                            # no pid
    assert watcher.kill_session("cb-stuck") is False
    assert "kill skipped (no pid)" in log.getvalue()


# --- Review fixes: input sanitization, fail-safe config, race guard, delivery -

def test_agent_meta_sanitizes_control_chars_in_name(tmp_path):
    from lib.subagent_watch import agent_meta

    t = tmp_path / "agent-x.jsonl"
    t.write_text("{}\n")
    # A crafted name with a newline (RESUME-line forge) + an ESC byte (pty control
    # sequence) must be neutralized at the trust boundary: printable chars and
    # spaces survive, control bytes do not.
    t.with_suffix(".meta.json").write_text(json.dumps(
        {"name": "evil\n- forged bullet\x1b[2Kmore", "teamName": "t"}))
    m = agent_meta(t)
    # Strict allowlist: newline/ESC/space AND markdown/shell chars ('[', '(', '$'…)
    # are all stripped; only [A-Za-z0-9._-] survives.
    assert all(c not in m.teammate_id for c in "\n\x1b []")
    assert m.teammate_id == "evil-forgedbullet2Kmore"


def test_elapsed_seconds_missing_file_returns_none(tmp_path):
    from lib.subagent_watch import elapsed_seconds

    # Glob-then-open race: the transcript was listed, then deleted before read.
    # Must honor its "never raises" contract and return None (find-bugs #3).
    gone = tmp_path / "agent-vanished.jsonl"
    assert elapsed_seconds(gone, now_iso="2026-07-12T10:14:42Z") is None


def test_config_tier_case_insensitive_and_whitespace_fails_safe(monkeypatch):
    from lib.ccb_types import CCBConfig, Tier

    # Mis-cased/whitespace values normalize; a real garbage value falls back to
    # OBSERVE (the safe floor), never a more permissive tier (find-bugs #2).
    monkeypatch.setenv("CCB_MAX_TIER", "  STOP ")
    assert CCBConfig.from_env().max_tier is Tier.STOP        # normalized + honored
    monkeypatch.setenv("CCB_MAX_TIER", "OBSERVE")
    assert CCBConfig.from_env().max_tier is Tier.OBSERVE
    monkeypatch.setenv("CCB_MAX_TIER", "kil")                # typo -> fail safe
    assert CCBConfig.from_env().max_tier is Tier.OBSERVE
    monkeypatch.delenv("CCB_MAX_TIER", raising=False)        # unset -> safe default
    assert CCBConfig.from_env().max_tier is Tier.OBSERVE


def test_run_tick_undelivered_nudge_neither_advances_nor_claims_delivery(tmp_path, monkeypatch):
    """One-per-tick pty injection: when two teammates breach in the same tick, the
    second nudge is dropped. It must NOT be ledgered/RESUMEd as delivered, and the
    agent must NOT advance to NUDGED with a grace clock the orchestrator was never
    told about (find-bugs #1). It re-fires next tick once the injector is free."""
    from lib.ccb_types import AgentPhase, CCBConfig, Tier
    from lib.subagent_watch import WatchState, _parse_iso, load_state, run_tick

    monkeypatch.setattr("lib.subagent_watch.session_cost_usd", lambda *a, **k: None)
    session_dir = tmp_path / "proj"
    now = _parse_iso("2026-07-13T11:00:00+00:00").timestamp()
    # Two quiet-stuck teammates (sorted: cb-aaa before cb-bbb) on a teams session.
    _mk_agent(session_dir, "cb-aaa", "2026-07-13T10:00:00+00:00", mtime=now - 20 * 60)
    _mk_agent(session_dir, "cb-bbb", "2026-07-13T10:00:00+00:00", mtime=now - 20 * 60)
    tasks = tmp_path / "tasks" / "session-abcd1234"
    tasks.mkdir(parents=True)
    (tasks / "1.json").write_text('{"id":"1","status":"in_progress"}')

    # Injector that delivers only ONE message per tick (mirrors the bin rate
    # limit); the test resets the budget between ticks as SubagentWatcher._tick does.
    budget = {"n": 1}
    delivered, dropped = [], []

    def inject(text):
        if budget["n"] > 0:
            budget["n"] -= 1
            delivered.append(text)
            return True
        dropped.append(text)
        return False

    resume = tmp_path / "RESUME.md"
    ledger = tmp_path / "events.jsonl"
    state_path = tmp_path / ".ccb-state.json"
    kw = dict(session_dir=session_dir, config_root=tmp_path, session_id="s",
              cwd="/p", cfg=CCBConfig(max_tier=Tier.NUDGE), parent_transcript=None,
              resume_path=resume, ledger_path=ledger, state_path=state_path, inject=inject)

    budget["n"] = 1
    state = run_tick(state=WatchState(), now=now, **kw)      # tick 1: both SUSPECT, silent
    budget["n"] = 1
    state = run_tick(state=state, now=now, **kw)            # tick 2: both nudge; only aaa delivered

    agents = load_state(state_path).agents
    assert agents["agent-cb-aaa"].phase is AgentPhase.NUDGED        # delivered -> advanced
    assert agents["agent-cb-bbb"].phase is AgentPhase.SUSPECT       # dropped -> reverted, NOT nudged
    assert len(delivered) == 1 and "cb-aaa" in delivered[0]
    assert len(dropped) == 1 and "cb-bbb" in dropped[0]
    events = [json.loads(l)["event"] for l in ledger.read_text().splitlines()]
    assert events.count("nudge") == 1                              # only the delivered nudge ledgered
    text = resume.read_text()
    assert "nudged: teammate cb-aaa" in text
    assert "nudged: teammate cb-bbb" not in text                   # no phantom-delivery line

    budget["n"] = 1
    state = run_tick(state=state, now=now, **kw)           # tick 3: injector free -> bbb nudged for real
    agents = load_state(state_path).agents
    assert agents["agent-cb-bbb"].phase is AgentPhase.NUDGED
    assert len(delivered) == 2 and "cb-bbb" in delivered[1]


def test_installed_layout_resolves_lib_past_a_decoy_lib_dir(tmp_path):
    """Regression: in an installed tree, <prefix>/lib (e.g. ~/.local/lib, Python's
    user site) must NOT shadow <prefix>/share/ccage/lib. Both bin/ccb-report and
    bin/ccage-auto's _load_ccb resolve the lib by matching lib/subagent_watch.py,
    not any dir merely named "lib". Build a fake installed tree WITH a decoy lib/
    at the prefix and confirm ccb-report still resolves the real lib and runs."""
    import shutil
    import subprocess
    import sys

    repo = Path(__file__).resolve().parent.parent
    prefix = tmp_path / "prefix"
    (prefix / "bin").mkdir(parents=True)
    (prefix / "share" / "ccage" / "lib").mkdir(parents=True)
    (prefix / "lib").mkdir()                                     # the decoy that shadowed it
    shutil.copy(repo / "bin" / "ccb-report", prefix / "bin" / "ccb-report")
    for p in (repo / "lib").glob("*.py"):                        # incl. __init__.py if present
        shutil.copy(p, prefix / "share" / "ccage" / "lib" / p.name)

    ledger = tmp_path / "events.jsonl"
    ledger.write_text("")
    r = subprocess.run([sys.executable, str(prefix / "bin" / "ccb-report"),
                        "--ledger", str(ledger), "--json"],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr                          # no ModuleNotFoundError
    assert '"agents_seen"' in r.stdout
