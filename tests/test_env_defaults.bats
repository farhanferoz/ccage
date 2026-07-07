#!/usr/bin/env bats
# Env vars the claude() wrapper hands to the caged claude process — Phase 4.
# These are scoped to the invocation (`local -x`), so the child process sees
# them but they must NOT leak back into the interactive shell (a stale
# CLAUDE_CONFIG_DIR bleeding into a later `cd` + tool run was the bug).
bats_require_minimum_version 1.5.0

load helpers

setup() {
    load_ccage

    # Fake `claude` that dumps the environment it was invoked with, so we can
    # assert what the child actually received (vs. what the shell retains).
    local bin_dir="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin_dir"
    CHILD_ENV="$BATS_TEST_TMPDIR/childenv"
    export CHILD_ENV
    printf '#!/bin/sh\nprintenv > "$CHILD_ENV"\nexit 0\n' > "$bin_dir/claude"
    chmod +x "$bin_dir/claude"
    PATH="$bin_dir:$PATH"

    # Reset env vars under test so previous tests don't bleed through.
    unset CLAUDE_CODE_ATTRIBUTION_HEADER
    unset DISABLE_AUTOUPDATER
    unset CLAUDE_CONFIG_DIR
    unset CCAGE_KEEP_ATTRIBUTION
    unset CCAGE_KEEP_AUTOUPDATER
    unset CCAGE_DISABLE
}

# --- pass-through: the child claude process receives them ---

@test "default: child claude sees CLAUDE_CODE_ATTRIBUTION_HEADER=0 and DISABLE_AUTOUPDATER=1" {
    claude 2>/dev/null || true
    grep -qx 'CLAUDE_CODE_ATTRIBUTION_HEADER=0' "$CHILD_ENV"
    grep -qx 'DISABLE_AUTOUPDATER=1' "$CHILD_ENV"
}

@test "default: child claude sees a CLAUDE_CONFIG_DIR (the cage dir)" {
    claude 2>/dev/null || true
    grep -q '^CLAUDE_CONFIG_DIR=' "$CHILD_ENV"
}

# --- no leak: the calling shell must NOT retain them after the wrapper returns ---

@test "no leak: CLAUDE_CONFIG_DIR is not set in the shell after claude returns" {
    claude 2>/dev/null || true
    [ -z "${CLAUDE_CONFIG_DIR+x}" ]
}

@test "no leak: attribution/autoupdater vars are not set in the shell after claude returns" {
    claude 2>/dev/null || true
    [ -z "${CLAUDE_CODE_ATTRIBUTION_HEADER+x}" ]
    [ -z "${DISABLE_AUTOUPDATER+x}" ]
}

@test "no leak: a pre-existing CLAUDE_CONFIG_DIR is restored, not overwritten, after claude returns" {
    export CLAUDE_CONFIG_DIR="/some/unrelated/dir"
    claude 2>/dev/null || true
    [ "${CLAUDE_CONFIG_DIR:-}" = "/some/unrelated/dir" ]
}

# --- opt-outs still honored (checked against the child's environment) ---

@test "CCAGE_KEEP_ATTRIBUTION=1: child claude does not see CLAUDE_CODE_ATTRIBUTION_HEADER" {
    CCAGE_KEEP_ATTRIBUTION=1
    claude 2>/dev/null || true
    ! grep -q '^CLAUDE_CODE_ATTRIBUTION_HEADER=' "$CHILD_ENV"
}

@test "CCAGE_KEEP_AUTOUPDATER=1: child claude does not see DISABLE_AUTOUPDATER" {
    CCAGE_KEEP_AUTOUPDATER=1
    claude 2>/dev/null || true
    ! grep -q '^DISABLE_AUTOUPDATER=' "$CHILD_ENV"
}

@test "CCAGE_DISABLE=1: pure pass-through, no ccage env vars set in shell or child" {
    CCAGE_DISABLE=1
    claude 2>/dev/null || true
    [ -z "${CLAUDE_CODE_ATTRIBUTION_HEADER+x}" ]
    [ -z "${DISABLE_AUTOUPDATER+x}" ]
    [ -z "${CLAUDE_CONFIG_DIR+x}" ]
    ! grep -q '^CLAUDE_CODE_ATTRIBUTION_HEADER=' "$CHILD_ENV"
}
