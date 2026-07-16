#!/usr/bin/env bats
# Tests for share/hooks/ccage-statusline-tee.sh (the rate-limit sensor tee) and
# _ccage_seed_statusline_tee (share/claude-isolation.sh) -- the wrap/unwrap of a
# cage's statusLine.command that arms the ccage-auto weekly-limit floor sensor.
# See docs/WEEKLY-LIMIT-GUARD.md for the design this implements.
bats_require_minimum_version 1.5.0

load helpers

TEE_SRC="$BATS_TEST_DIRNAME/../share/hooks/ccage-statusline-tee.sh"

setup() {
    command -v jq >/dev/null 2>&1 || skip "jq required"
    command -v python3 >/dev/null 2>&1 || skip "python3 required"
    load_ccage
    unset CCAGE_AUTOCK_WEEKLY_FLOOR

    HOOKS_DIR="$BATS_TEST_TMPDIR/hooks"
    mkdir -p "$HOOKS_DIR"
    cp "$TEE_SRC" "$HOOKS_DIR/ccage-statusline-tee.sh"
    export CCAGE_HOOKS_DIR="$HOOKS_DIR"

    CAGE="$BATS_TEST_TMPDIR/cage"
    mkdir -p "$CAGE"
    SETTINGS="$CAGE/settings.json"
}

# ---------------------------------------------------------------------------
# The tee script itself
# ---------------------------------------------------------------------------

@test "tee: writes both windows + integer ts, then runs the real statusline" {
    STATE_DIR="$BATS_TEST_TMPDIR/state1"
    mkdir -p "$STATE_DIR"
    INPUT="$BATS_TEST_TMPDIR/input1.json"
    cat > "$INPUT" <<'JSON'
{"rate_limits":{"five_hour":{"used_percentage":12.3},"seven_day":{"used_percentage":45.6,"resets_at":"2026-07-20T00:00:00Z"}}}
JSON
    run bash -c "CLAUDE_CONFIG_DIR='$STATE_DIR' bash '$TEE_SRC' 'printf real-status' < '$INPUT'"
    [ "$status" -eq 0 ]
    [ "$output" = "real-status" ]

    STATE="$STATE_DIR/rate-limits-state.json"
    [ -f "$STATE" ]
    [ "$(jq -r '.five_hour.used_percentage' "$STATE")" = "12.3" ]
    [ "$(jq -r '.seven_day.used_percentage' "$STATE")" = "45.6" ]
    [ "$(jq -r '.seven_day.resets_at' "$STATE")" = "2026-07-20T00:00:00Z" ]
    TS="$(jq -r '.ts' "$STATE")"
    [[ "$TS" =~ ^[0-9]+$ ]]
}

@test "tee: absent .rate_limits leaves state untouched, real statusline still runs" {
    STATE_DIR="$BATS_TEST_TMPDIR/state2"
    mkdir -p "$STATE_DIR"
    STATE="$STATE_DIR/rate-limits-state.json"
    printf '{"seven_day":{"used_percentage":1},"ts":42}\n' > "$STATE"
    BEFORE="$(cat "$STATE")"
    INPUT="$BATS_TEST_TMPDIR/input2.json"
    printf '{"hello":"world"}' > "$INPUT"

    run bash -c "CLAUDE_CONFIG_DIR='$STATE_DIR' bash '$TEE_SRC' 'printf ran' < '$INPUT'"
    [ "$status" -eq 0 ]
    [ "$output" = "ran" ]
    [ "$(cat "$STATE")" = "$BEFORE" ]
}

@test "tee: malformed stdin JSON -> real statusline still runs, no state write" {
    STATE_DIR="$BATS_TEST_TMPDIR/state3"
    mkdir -p "$STATE_DIR"
    INPUT="$BATS_TEST_TMPDIR/input3.json"
    printf 'not json {' > "$INPUT"

    run bash -c "CLAUDE_CONFIG_DIR='$STATE_DIR' bash '$TEE_SRC' 'printf ran' < '$INPUT'"
    [ "$status" -eq 0 ]
    [ "$output" = "ran" ]
    [ ! -f "$STATE_DIR/rate-limits-state.json" ]
}

@test "tee: no leftover mktemp files after a successful write" {
    STATE_DIR="$BATS_TEST_TMPDIR/state4"
    mkdir -p "$STATE_DIR"
    INPUT="$BATS_TEST_TMPDIR/input4.json"
    printf '{"rate_limits":{"seven_day":{"used_percentage":5}}}' > "$INPUT"

    run bash -c "CLAUDE_CONFIG_DIR='$STATE_DIR' bash '$TEE_SRC' 'printf ran' < '$INPUT'"
    [ "$status" -eq 0 ]
    run bash -c "find '$STATE_DIR' -maxdepth 1 -name 'rate-limits-state.json.*'"
    [ -z "$output" ]
}

@test "tee: no-arg mode is tee-only -- emits nothing, exits 0" {
    STATE_DIR="$BATS_TEST_TMPDIR/state5"
    mkdir -p "$STATE_DIR"
    INPUT="$BATS_TEST_TMPDIR/input5.json"
    printf '{"rate_limits":{"seven_day":{"used_percentage":9}}}' > "$INPUT"

    run bash -c "CLAUDE_CONFIG_DIR='$STATE_DIR' bash '$TEE_SRC' < '$INPUT'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -f "$STATE_DIR/rate-limits-state.json" ]
}

# ---------------------------------------------------------------------------
# The seeder: _ccage_seed_statusline_tee (share/claude-isolation.sh)
# ---------------------------------------------------------------------------

@test "seeder: armed wraps statusLine.command" {
    CCAGE_AUTOCK_WEEKLY_FLOOR=20
    printf '{"statusLine":{"type":"command","command":"echo hi"}}' > "$SETTINGS"
    _ccage_seed_statusline_tee "$CAGE"
    CMD="$(jq -r '.statusLine.command' "$SETTINGS")"
    [ "$CMD" = "bash $HOOKS_DIR/ccage-statusline-tee.sh 'echo hi'" ]
}

@test "seeder: idempotent -- second armed run never double-wraps" {
    CCAGE_AUTOCK_WEEKLY_FLOOR=20
    printf '{"statusLine":{"type":"command","command":"echo hi"}}' > "$SETTINGS"
    _ccage_seed_statusline_tee "$CAGE"
    FIRST="$(jq -r '.statusLine.command' "$SETTINGS")"
    _ccage_seed_statusline_tee "$CAGE"
    SECOND="$(jq -r '.statusLine.command' "$SETTINGS")"
    [ "$FIRST" = "$SECOND" ]
    COUNT="$(grep -o 'ccage-statusline-tee.sh' <<< "$SECOND" | wc -l)"
    [ "$COUNT" -eq 1 ]
}

@test "seeder: other settings keys are preserved" {
    CCAGE_AUTOCK_WEEKLY_FLOOR=20
    printf '{"theme":"dark","effortLevel":"high","statusLine":{"type":"command","command":"echo hi"}}' > "$SETTINGS"
    _ccage_seed_statusline_tee "$CAGE"
    [ "$(jq -r '.theme' "$SETTINGS")" = "dark" ]
    [ "$(jq -r '.effortLevel' "$SETTINGS")" = "high" ]
}

@test "seeder: disarmed unwraps back to the exact original command" {
    CCAGE_AUTOCK_WEEKLY_FLOOR=20
    printf '{"statusLine":{"type":"command","command":"echo hi"}}' > "$SETTINGS"
    _ccage_seed_statusline_tee "$CAGE"
    [[ "$(jq -r '.statusLine.command' "$SETTINGS")" == *"ccage-statusline-tee.sh"* ]]

    unset CCAGE_AUTOCK_WEEKLY_FLOOR
    _ccage_seed_statusline_tee "$CAGE"
    [ "$(jq -r '.statusLine.command' "$SETTINGS")" = "echo hi" ]
}

@test "seeder: gate off + never wrapped -> file byte-identical" {
    unset CCAGE_AUTOCK_WEEKLY_FLOOR
    printf '{"statusLine":{"type":"command","command":"echo hi"}}' > "$SETTINGS"
    BEFORE="$(cat "$SETTINGS")"
    _ccage_seed_statusline_tee "$CAGE"
    [ "$(cat "$SETTINGS")" = "$BEFORE" ]
}

@test "seeder: no statusLine key -> settings untouched" {
    CCAGE_AUTOCK_WEEKLY_FLOOR=20
    printf '{"effortLevel":"high"}' > "$SETTINGS"
    BEFORE="$(cat "$SETTINGS")"
    _ccage_seed_statusline_tee "$CAGE"
    [ "$(cat "$SETTINGS")" = "$BEFORE" ]
}

@test "seeder: statusLine.type != command -> untouched" {
    CCAGE_AUTOCK_WEEKLY_FLOOR=20
    printf '{"statusLine":{"type":"static","text":"hi"}}' > "$SETTINGS"
    BEFORE="$(cat "$SETTINGS")"
    _ccage_seed_statusline_tee "$CAGE"
    [ "$(cat "$SETTINGS")" = "$BEFORE" ]
}

@test "seeder: missing settings.json -> no file created" {
    CCAGE_AUTOCK_WEEKLY_FLOOR=20
    rm -f "$SETTINGS"
    _ccage_seed_statusline_tee "$CAGE"
    [ ! -f "$SETTINGS" ]
}

@test "seeder: tee script missing -> no wrap" {
    rm -f "$HOOKS_DIR/ccage-statusline-tee.sh"
    CCAGE_AUTOCK_WEEKLY_FLOOR=20
    printf '{"statusLine":{"type":"command","command":"echo hi"}}' > "$SETTINGS"
    BEFORE="$(cat "$SETTINGS")"
    _ccage_seed_statusline_tee "$CAGE"
    [ "$(cat "$SETTINGS")" = "$BEFORE" ]
}

@test "seeder: unparseable settings.json is never clobbered" {
    CCAGE_AUTOCK_WEEKLY_FLOOR=20
    printf 'not json at all' > "$SETTINGS"
    _ccage_seed_statusline_tee "$CAGE"
    [ "$(cat "$SETTINGS")" = "not json at all" ]
}
