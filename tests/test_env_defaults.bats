#!/usr/bin/env bats
# Backfill tests for env var defaults exported by the claude() wrapper — Phase 4.
bats_require_minimum_version 1.5.0

load helpers

setup() {
    load_ccage

    # Fake `claude` binary so `command claude` resolves without error.
    local bin_dir="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin_dir"
    printf '#!/bin/sh\nexit 0\n' > "$bin_dir/claude"
    chmod +x "$bin_dir/claude"
    PATH="$bin_dir:$PATH"

    # Reset env vars under test so previous tests don't bleed through.
    unset CLAUDE_CODE_ATTRIBUTION_HEADER
    unset DISABLE_AUTOUPDATER
    unset CCAGE_KEEP_ATTRIBUTION
    unset CCAGE_KEEP_AUTOUPDATER
    unset CCAGE_DISABLE
}

@test "default: CLAUDE_CODE_ATTRIBUTION_HEADER=0 and DISABLE_AUTOUPDATER=1 exported" {
    claude 2>/dev/null || true
    [ "${CLAUDE_CODE_ATTRIBUTION_HEADER:-}" = "0" ]
    [ "${DISABLE_AUTOUPDATER:-}" = "1" ]
}

@test "CCAGE_KEEP_ATTRIBUTION=1: CLAUDE_CODE_ATTRIBUTION_HEADER not exported" {
    CCAGE_KEEP_ATTRIBUTION=1
    claude 2>/dev/null || true
    [ -z "${CLAUDE_CODE_ATTRIBUTION_HEADER+x}" ]
}

@test "CCAGE_KEEP_AUTOUPDATER=1: DISABLE_AUTOUPDATER not exported" {
    CCAGE_KEEP_AUTOUPDATER=1
    claude 2>/dev/null || true
    [ -z "${DISABLE_AUTOUPDATER+x}" ]
}

@test "CCAGE_DISABLE=1: pure pass-through, no ccage env vars set" {
    CCAGE_DISABLE=1
    claude 2>/dev/null || true
    [ -z "${CLAUDE_CODE_ATTRIBUTION_HEADER+x}" ]
    [ -z "${DISABLE_AUTOUPDATER+x}" ]
}
