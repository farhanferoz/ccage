#!/usr/bin/env bats
# Tests for the /keepwarm skill — Phase 8. Covers the deterministic helper
# (keepwarm-calc.sh probe: transcript discovery, peak/tier extraction, graceful
# degradation), SKILL.md structural invariants (defaults, clamps), and the
# install/uninstall wiring (--no-keepwarm). The scheduling loop itself is agent
# judgment and is not scripted.
bats_require_minimum_version 1.5.0

HELPER="$BATS_TEST_DIRNAME/../share/skills/keepwarm/keepwarm-calc.sh"
SKILL="$BATS_TEST_DIRNAME/../share/skills/keepwarm/SKILL.md"

setup() {
    FAKE_CONFIG="$BATS_TEST_TMPDIR/config"
    PROJ="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$FAKE_CONFIG" "$PROJ"
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    unset CCAGE_SHARE_FROM CCAGE_HOOKS_DIR
}

# Write a usage entry line into the project's session dir.
# args: FILE CACHE_READ EPHEMERAL_1H EPHEMERAL_5M
emit_entry() {
    printf '{"message":{"usage":{"cache_read_input_tokens":%s,"cache_creation":{"ephemeral_1h_input_tokens":%s,"ephemeral_5m_input_tokens":%s}}}}\n' \
        "$2" "$3" "$4" >> "$1"
}

session_dir() { printf '%s/projects/%s\n' "$FAKE_CONFIG" "${PROJ//\//-}"; }

probe() { CLAUDE_CONFIG_DIR="$FAKE_CONFIG" run bash "$HELPER" probe "$PROJ"; }

# ---- helper: probe -----------------------------------------------------------

@test "probe: no sessions dir → none/0/unknown, exit 0" {
    probe
    [ "$status" -eq 0 ]
    [[ "$output" == *"transcript=none"* ]]
    [[ "$output" == *"peak_cache_read=0"* ]]
    [[ "$output" == *"tier=unknown"* ]]
}

@test "probe: picks newest jsonl and reports peak cache_read" {
    mkdir -p "$(session_dir)"
    old="$(session_dir)/aaa.jsonl"; new="$(session_dir)/bbb.jsonl"
    emit_entry "$old" 99999 0 0
    emit_entry "$new" 100 50000 0
    emit_entry "$new" 5000 60000 0
    emit_entry "$new" 3000 0 0
    touch -t 202601010000 "$old"
    probe
    [ "$status" -eq 0 ]
    [[ "$output" == *"transcript=$new"* ]]
    [[ "$output" == *"peak_cache_read=5000"* ]]
}

@test "probe: 1h-dominant session → tier=1h" {
    mkdir -p "$(session_dir)"
    f="$(session_dir)/s.jsonl"
    emit_entry "$f" 100 90000 200
    probe
    [[ "$output" == *"tier=1h"* ]]
}

@test "probe: 5m-dominant session → tier=5m" {
    mkdir -p "$(session_dir)"
    f="$(session_dir)/s.jsonl"
    emit_entry "$f" 100 0 7000
    probe
    [[ "$output" == *"tier=5m"* ]]
}

@test "probe: no cache_creation data → tier=unknown" {
    mkdir -p "$(session_dir)"
    printf '{"message":{"usage":{"cache_read_input_tokens":1234}}}\n' > "$(session_dir)/s.jsonl"
    probe
    [ "$status" -eq 0 ]
    [[ "$output" == *"peak_cache_read=1234"* ]]
    [[ "$output" == *"tier=unknown"* ]]
}

@test "probe: malformed transcript degrades to 0/unknown, exit 0" {
    mkdir -p "$(session_dir)"
    printf 'this is not json {{{\n' > "$(session_dir)/s.jsonl"
    probe
    [ "$status" -eq 0 ]
    [[ "$output" == *"peak_cache_read=0"* ]]
    [[ "$output" == *"tier=unknown"* ]]
}

@test "probe: non-message lines are tolerated (summary/system entries)" {
    mkdir -p "$(session_dir)"
    f="$(session_dir)/s.jsonl"
    printf '{"type":"summary","summary":"hi"}\n' >> "$f"
    emit_entry "$f" 4200 1000 0
    probe
    [ "$status" -eq 0 ]
    [[ "$output" == *"peak_cache_read=4200"* ]]
    [[ "$output" == *"tier=1h"* ]]
}

@test "helper: unknown subcommand → usage, exit 2" {
    run bash "$HELPER" frobnicate
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage:"* ]]
}

# ---- SKILL.md structural invariants -------------------------------------------

@test "SKILL.md: frontmatter has name: keepwarm and a description" {
    head -1 "$SKILL" | grep -qx -- '---'
    grep -q '^name: keepwarm$' "$SKILL"
    grep -q '^description: >-$' "$SKILL"
}

@test "SKILL.md: documents the defaults (55 min interval, 6-ping cap) and clamps" {
    grep -q 'Default \*\*55\*\*' "$SKILL"
    grep -q 'Default \*\*6\*\*' "$SKILL"
    grep -q '\[1, 59\]' "$SKILL"
    grep -q '\[1, 24\]' "$SKILL"
}

@test "SKILL.md: arming announcement contract present (cost, auto-stop, cancel)" {
    grep -qi 'auto-stops' "$SKILL"
    grep -qi 'defaults are never silent' "$SKILL"
}

@test "SKILL.md: no attribution trailers" {
    ! grep -qi 'co-authored-by\|generated with' "$SKILL"
}

# ---- install / uninstall wiring ------------------------------------------------

@test "install deploys the keepwarm skill; uninstall removes it" {
    FAKE_HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$FAKE_HOME"
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    [ -f "$FAKE_HOME/.claude/skills/keepwarm/SKILL.md" ]
    [ -x "$FAKE_HOME/.claude/skills/keepwarm/keepwarm-calc.sh" ]
    HOME="$FAKE_HOME" "$REPO_ROOT/uninstall.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    [ ! -e "$FAKE_HOME/.claude/skills/keepwarm/SKILL.md" ]
    [ ! -e "$FAKE_HOME/.claude/skills/keepwarm/keepwarm-calc.sh" ]
}

@test "install --no-keepwarm skips the skill" {
    FAKE_HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$FAKE_HOME"
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" --no-keepwarm >/dev/null
    [ ! -e "$FAKE_HOME/.claude/skills/keepwarm" ]
}

@test "uninstall leaves user-created files in the skill dir" {
    FAKE_HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$FAKE_HOME"
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    printf 'mine\n' > "$FAKE_HOME/.claude/skills/keepwarm/NOTES.md"
    HOME="$FAKE_HOME" "$REPO_ROOT/uninstall.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    [ -f "$FAKE_HOME/.claude/skills/keepwarm/NOTES.md" ]
}
