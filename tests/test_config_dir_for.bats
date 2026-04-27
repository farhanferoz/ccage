#!/usr/bin/env bats
# Backfill tests for _ccage_config_dir_for — Phase 4.
bats_require_minimum_version 1.5.0

load helpers

setup() {
    load_ccage
    unset CCAGE_SLOT
}

@test "plain basename mapping: no collision" {
    run _ccage_config_dir_for /some/myproject
    [ "$status" -eq 0 ]
    [ "$output" = "$BATS_TEST_TMPDIR/.claude-myproject" ]
}

@test "collision where .owning_path matches current PWD: no hash suffix" {
    local candidate="$BATS_TEST_TMPDIR/.claude-proj"
    mkdir -p "$candidate"
    printf '%s\n' "/home/me/proj" > "$candidate/.owning_path"

    run _ccage_config_dir_for /home/me/proj
    [ "$status" -eq 0 ]
    [ "$output" = "$BATS_TEST_TMPDIR/.claude-proj" ]
}

@test "collision where .owning_path points elsewhere: hash suffix applied, 8 chars" {
    local candidate="$BATS_TEST_TMPDIR/.claude-proj"
    mkdir -p "$candidate"
    printf '%s\n' "/other/proj" > "$candidate/.owning_path"

    run _ccage_config_dir_for /my/proj
    [ "$status" -eq 0 ]

    local sha; sha="$(_ccage_sha1 /my/proj)"
    [ "${#sha}" -eq 8 ]
    [ "$output" = "$BATS_TEST_TMPDIR/.claude-proj-${sha}" ]
}

@test "existing dir without .owning_path: current PWD claims it (backward compat)" {
    local candidate="$BATS_TEST_TMPDIR/.claude-proj"
    mkdir -p "$candidate"
    # No .owning_path file written.

    run _ccage_config_dir_for /any/proj
    [ "$status" -eq 0 ]
    [ "$output" = "$BATS_TEST_TMPDIR/.claude-proj" ]
}

@test "override returns empty stdout: falls through to basename keying" {
    _CCAGE_OVERRIDE_ACTIVE=1
    _ccage_config_dir_override() {
        printf ''   # empty stdout
        return 0
    }

    run _ccage_config_dir_for /some/path
    [ "$status" -eq 0 ]
    [ "$output" = "$BATS_TEST_TMPDIR/.claude-path" ]
}

@test "CCAGE_ROOT and CCAGE_PREFIX are respected" {
    local alt_root="$BATS_TEST_TMPDIR/alt"
    mkdir -p "$alt_root"
    CCAGE_ROOT="$alt_root" CCAGE_PREFIX="cc-" \
        run _ccage_config_dir_for /some/proj
    [ "$status" -eq 0 ]
    [ "$output" = "$alt_root/cc-proj" ]
}
