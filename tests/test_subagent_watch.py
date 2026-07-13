import json
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
    assert cfg.max_tier is Tier.STOP  # falls back to default, never raises


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
    cfg = CCBConfig()  # soft=45, stale=10, max_tier=STOP
    o = _obs(elapsed_min=60, stale_min=15)

    rec, actions = evaluate(_rec(), o, cfg)
    assert rec.phase is AgentPhase.SUSPECT and actions == []       # debounce tick 1

    rec, actions = evaluate(rec, o, cfg)
    assert rec.phase is AgentPhase.NUDGED
    assert [a.kind for a in actions] == ["alert", "nudge"]          # one tier step, audited


def test_churn_stuck_caught_by_hard_threshold_despite_fresh_writes():
    from lib.subagent_watch import evaluate
    cfg = CCBConfig()  # hard=120
    o = _obs(elapsed_min=130, stale_min=0.1)                        # writing constantly
    rec, _ = evaluate(_rec(), o, cfg)
    rec, actions = evaluate(rec, o, cfg)
    assert rec.phase is AgentPhase.NUDGED                           # v1's blind spot, closed


def test_vouch_deescalates_and_protects_both_stuck_modes():
    from lib.subagent_watch import evaluate
    cfg = CCBConfig()  # soft=45, stale=10, hard=120, grace=10
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
    cfg = CCBConfig()  # max_vouches=2, grace=10
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
    cfg = CCBConfig()  # grace=10
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
    from lib.ccb_types import AgentRecord, CCBConfig, EventKind
    from lib.subagent_watch import ledger_write

    ledger = tmp_path / "events.jsonl"
    rec = AgentRecord(name="agent-sr6-cost-regrade-a8829e1a20628718",
                      teammate_id="sr6-cost-regrade",
                      peak_elapsed_min=92.0, peak_stale_min=14.0)
    ledger_write(
        ledger, EventKind.NUDGE, rec, CCBConfig(),
        session_id="1e0c8efe-964a-4167-b722-8019792e8645", cwd="/home/ff235/dev/Oasis/StrategyA",
        elapsed_min=92.0, stale_min=14.0, session_cost_usd=41.2, open_tasks=3,
        now_iso="2026-07-13T12:00:00+00:00",
    )
    ledger_write(  # second line appends, never truncates
        ledger, EventKind.RESOLVED, rec, CCBConfig(),
        session_id="1e0c8efe-964a-4167-b722-8019792e8645", cwd="/home/ff235/dev/Oasis/StrategyA",
        elapsed_min=97.0, stale_min=0.0, session_cost_usd=42.0, open_tasks=2,
        now_iso="2026-07-13T12:05:00+00:00",
    )

    lines = [json.loads(l) for l in ledger.read_text().splitlines()]
    assert [l["event"] for l in lines] == ["nudge", "resolved"]
    first = lines[0]
    assert first["teammate_id"] == "sr6-cost-regrade"
    assert first["elapsed_min"] == 92.0 and first["session_cost_usd"] == 41.2
    assert first["cfg"]["t_hard_min"] == 120 and first["cfg"]["max_tier"] == "stop"
    assert first["peak_elapsed_min"] == 92.0     # healthy-distribution data
    assert first["session_id"].startswith("1e0c8efe")


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
