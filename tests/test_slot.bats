#!/usr/bin/env bats
# Tests for CCAGE_SLOT suffix — Phase 3a.
bats_require_minimum_version 1.5.0

load helpers

setup() {
    load_ccage
    unset CCAGE_SLOT
}

@test "CCAGE_SLOT unset: no suffix on config dir" {
    unset CCAGE_SLOT
    run _ccage_config_dir_for /some/path
    [ "$status" -eq 0 ]
    [ "$output" = "$BATS_TEST_TMPDIR/.claude-path" ]
}

@test "CCAGE_SLOT=review: double-dash suffix appended after basename" {
    CCAGE_SLOT=review
    run _ccage_config_dir_for /some/path
    [ "$status" -eq 0 ]
    [ "$output" = "$BATS_TEST_TMPDIR/.claude-path--review" ]
}

@test "CCAGE_SLOT with collision: slot appended after hash disambiguation" {
    # Simulate a collision: the candidate dir exists, owned by a different path.
    local candidate="$BATS_TEST_TMPDIR/.claude-proj"
    mkdir -p "$candidate"
    printf '%s\n' "/other/proj" > "$candidate/.owning_path"

    CCAGE_SLOT=bg
    run _ccage_config_dir_for /some/proj
    [ "$status" -eq 0 ]

    local sha; sha="$(_ccage_sha1 /some/proj)"
    [ "$output" = "$BATS_TEST_TMPDIR/.claude-proj-${sha}--bg" ]
}

@test "CCAGE_SLOT with unsafe chars: ignored with stderr warning" {
    CCAGE_SLOT="bad/slot"
    run --separate-stderr _ccage_config_dir_for /some/path
    [ "$status" -eq 0 ]
    # Slot is unsafe — output must be the plain path with no slot suffix.
    [ "$output" = "$BATS_TEST_TMPDIR/.claude-path" ]
    # A warning must appear on stderr.
    [[ "$stderr" == *"CCAGE_SLOT"* ]]
}

@test "override hook takes precedence over CCAGE_SLOT" {
    _CCAGE_OVERRIDE_ACTIVE=1
    _ccage_config_dir_override() {
        printf '%s\n' "/fixed/config"
        return 0
    }
    CCAGE_SLOT=review
    run _ccage_config_dir_for /some/path
    [ "$status" -eq 0 ]
    [ "$output" = "/fixed/config" ]
}
