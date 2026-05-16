#!/usr/bin/env bats
# Regression tests: the wrapper must not crash under `set -u` (strict mode).
#
# Pre-fix: 5 env-var reads in claude-isolation.sh dereferenced unset names
# directly, causing "unbound variable" on the very first `claude` invocation
# in any shell that had `set -u` active. Documented in RESUME.md "Known bugs"
# and the README "Limitations" section.
bats_require_minimum_version 1.5.0

load helpers

setup() {
    load_ccage
    # Stub `claude` so the wrapper's terminal `command claude "$@"` finds something.
    local bin_dir="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin_dir"
    printf '#!/bin/sh\nexit 0\n' > "$bin_dir/claude"
    chmod +x "$bin_dir/claude"
    PATH="$bin_dir:$PATH"
    # Strict mode for the test body — this is what we're guarding against.
    set -u
    # Make sure none of the env vars are exported from the test env.
    unset CCAGE_DISABLE CCAGE_KEEP_ATTRIBUTION CCAGE_KEEP_AUTOUPDATER
    unset CCAGE_NO_ONBOARDING_PATCH CCAGE_NO_AUTO_SIGNORE
}

teardown() {
    set +u
}

@test "claude() runs without unbound-variable errors under set -u" {
    # The wrapper must complete cleanly — any "unbound variable" message on
    # stderr is a regression of the 5-env-var bug.
    run --separate-stderr claude --version
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"unbound variable"* ]]
    [[ "$stderr" != *"CCAGE_DISABLE"* ]]
    [[ "$stderr" != *"CCAGE_KEEP_ATTRIBUTION"* ]]
    [[ "$stderr" != *"CCAGE_KEEP_AUTOUPDATER"* ]]
    [[ "$stderr" != *"CCAGE_NO_ONBOARDING_PATCH"* ]]
    [[ "$stderr" != *"CCAGE_NO_AUTO_SIGNORE"* ]]
}

@test "_ccage_bootstrap_dir does not crash with NO_ONBOARDING_PATCH unset" {
    run --separate-stderr _ccage_bootstrap_dir "$BATS_TEST_TMPDIR/d" /some/proj
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"unbound"* ]]
}

@test "_ccage_write_signore does not crash with NO_AUTO_SIGNORE unset" {
    mkdir -p "$BATS_TEST_TMPDIR/proj"
    run --separate-stderr _ccage_write_signore "$BATS_TEST_TMPDIR/proj"
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"unbound"* ]]
}
