#!/usr/bin/env bats
# Backfill tests for _ccage_bootstrap_dir — Phase 4.
bats_require_minimum_version 1.5.0

load helpers

setup() {
    load_ccage
    unset CCAGE_NO_ONBOARDING_PATCH
}

@test "fresh dir: creates dir, stamps .owning_path, writes .claude.json with onboarding flag" {
    local dir="$BATS_TEST_TMPDIR/fresh"
    _ccage_bootstrap_dir "$dir" /some/project

    [ -d "$dir" ]
    [ "$(cat "$dir/.owning_path")" = "/some/project" ]
    grep -q '"hasCompletedOnboarding"' "$dir/.claude.json"
}

@test "existing .claude.json without flag: flag added, other keys preserved" {
    command -v python3 >/dev/null 2>&1 || skip "python3 not available"

    local dir="$BATS_TEST_TMPDIR/existing"
    mkdir -p "$dir"
    printf '{"someKey": "someValue"}\n' > "$dir/.claude.json"

    _ccage_bootstrap_dir "$dir" /some/project

    grep -q '"hasCompletedOnboarding"' "$dir/.claude.json"
    grep -q '"someKey"' "$dir/.claude.json"
}

@test "existing .claude.json already with flag: file unchanged" {
    local dir="$BATS_TEST_TMPDIR/already"
    mkdir -p "$dir"
    local original='{"hasCompletedOnboarding": true}'
    printf '%s\n' "$original" > "$dir/.claude.json"

    _ccage_bootstrap_dir "$dir" /some/project

    [ "$(cat "$dir/.claude.json")" = "$original" ]
}

@test "CCAGE_NO_ONBOARDING_PATCH=1: .claude.json not created" {
    local dir="$BATS_TEST_TMPDIR/nopatch"
    CCAGE_NO_ONBOARDING_PATCH=1
    _ccage_bootstrap_dir "$dir" /some/project

    [ -d "$dir" ]
    [ ! -f "$dir/.claude.json" ]
}

@test "missing python3: no crash, onboarding patch silently skipped" {
    local dir="$BATS_TEST_TMPDIR/nopy"
    mkdir -p "$dir"
    printf '{"otherKey": 1}\n' > "$dir/.claude.json"

    # Override python3 with a fake that exits non-zero so the patch is skipped.
    local bin_dir="$BATS_TEST_TMPDIR/nopy-bin"
    mkdir -p "$bin_dir"
    printf '#!/bin/sh\nexit 1\n' > "$bin_dir/python3"
    chmod +x "$bin_dir/python3"
    PATH="$bin_dir:$PATH"

    _ccage_bootstrap_dir "$dir" /some/project

    # No crash; file exists unchanged (no flag added).
    [ -f "$dir/.claude.json" ]
    grep -q '"otherKey"' "$dir/.claude.json"
    ! grep -q '"hasCompletedOnboarding"' "$dir/.claude.json"
}
