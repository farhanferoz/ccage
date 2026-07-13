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
