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
