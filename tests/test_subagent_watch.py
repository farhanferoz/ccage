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
