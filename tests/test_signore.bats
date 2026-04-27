#!/usr/bin/env bats
# Backfill tests for _ccage_write_signore — Phase 4.
bats_require_minimum_version 1.5.0

load helpers

setup() {
    load_ccage
    unset CCAGE_NO_AUTO_SIGNORE
}

@test "no .claudesignore: baseline written" {
    local project="$BATS_TEST_TMPDIR/project"
    mkdir -p "$project"

    _ccage_write_signore "$project"

    [ -f "$project/.claudesignore" ]
    grep -q "node_modules" "$project/.claudesignore"
    grep -q ".venv" "$project/.claudesignore"
}

@test "existing .claudesignore: not touched" {
    local project="$BATS_TEST_TMPDIR/project"
    mkdir -p "$project"
    printf 'my-custom-ignore\n' > "$project/.claudesignore"

    _ccage_write_signore "$project"

    [ "$(cat "$project/.claudesignore")" = "my-custom-ignore" ]
}

@test "CCAGE_NO_AUTO_SIGNORE=1: nothing written even if file absent" {
    local project="$BATS_TEST_TMPDIR/project"
    mkdir -p "$project"
    CCAGE_NO_AUTO_SIGNORE=1

    _ccage_write_signore "$project"

    [ ! -f "$project/.claudesignore" ]
}
