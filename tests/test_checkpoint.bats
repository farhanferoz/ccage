#!/usr/bin/env bats
# Tests for the /checkpoint skill's bundled helper (checkpoint-init.sh) —
# Phase 7 (component A, deterministic parts). The merge/trim/tidy work is agent
# judgment and is not scripted; this covers slot-aware path resolution and the
# idempotent, non-destructive bootstrap (create-if-absent + .git/info/exclude).
bats_require_minimum_version 1.5.0

HELPER="$BATS_TEST_DIRNAME/../share/skills/checkpoint/checkpoint-init.sh"

setup() {
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO"
    unset CCAGE_SLOT
}

in_repo() { ( cd "$REPO" && "$@" ); }

@test "paths (no slot): plain RESUME/CHANGELOG names" {
    run in_repo bash "$HELPER" paths
    [ "$status" -eq 0 ]
    [[ "$output" == *"resume=RESUME.md"* ]]
    [[ "$output" == *"changelog=CHANGELOG.md"* ]]
}

@test "paths (CCAGE_SLOT=review): slot-suffixed names" {
    CCAGE_SLOT=review run in_repo bash "$HELPER" paths
    [ "$status" -eq 0 ]
    [[ "$output" == *"resume=RESUME.review.md"* ]]
    [[ "$output" == *"changelog=CHANGELOG.review.md"* ]]
}

@test "paths (unsafe slot): falls back to plain names" {
    CCAGE_SLOT="bad/slot" run in_repo bash "$HELPER" paths
    [ "$status" -eq 0 ]
    [[ "$output" == *"resume=RESUME.md"* ]]
    [[ "$output" == *"changelog=CHANGELOG.md"* ]]
}

@test "bootstrap in a git repo: creates both files + excludes both locally" {
    ( cd "$REPO" && git init -q )
    run in_repo bash "$HELPER" bootstrap
    [ "$status" -eq 0 ]
    [ -f "$REPO/RESUME.md" ]
    [ -f "$REPO/CHANGELOG.md" ]
    grep -qxF 'RESUME.md'    "$REPO/.git/info/exclude"
    grep -qxF 'CHANGELOG.md' "$REPO/.git/info/exclude"
    grep -q '^## State' "$REPO/RESUME.md"
    grep -q '^## Session' "$REPO/RESUME.md"
}

@test "bootstrap is idempotent: re-run does not overwrite or duplicate excludes" {
    ( cd "$REPO" && git init -q )
    in_repo bash "$HELPER" bootstrap
    printf 'SENTINEL\n' >> "$REPO/RESUME.md"
    run in_repo bash "$HELPER" bootstrap
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to do"* ]]
    grep -qxF 'SENTINEL' "$REPO/RESUME.md"
    [ "$(grep -cxF 'RESUME.md' "$REPO/.git/info/exclude")" -eq 1 ]
}

@test "bootstrap preserves an existing RESUME and excludes only what it creates" {
    ( cd "$REPO" && git init -q )
    printf 'MY OWN RESUME\n' > "$REPO/RESUME.md"
    run in_repo bash "$HELPER" bootstrap
    [ "$status" -eq 0 ]
    grep -qxF 'MY OWN RESUME' "$REPO/RESUME.md"
    [ -f "$REPO/CHANGELOG.md" ]
    grep -qxF 'CHANGELOG.md' "$REPO/.git/info/exclude"
    ! grep -qxF 'RESUME.md'  "$REPO/.git/info/exclude"
}

@test "bootstrap outside a git repo: creates files, no crash, no exclude" {
    run in_repo bash "$HELPER" bootstrap
    [ "$status" -eq 0 ]
    [ -f "$REPO/RESUME.md" ]
    [ -f "$REPO/CHANGELOG.md" ]
    [ ! -e "$REPO/.git" ]
}

@test "bootstrap with CCAGE_SLOT: creates slot-suffixed files" {
    ( cd "$REPO" && git init -q )
    CCAGE_SLOT=bg run in_repo bash "$HELPER" bootstrap
    [ "$status" -eq 0 ]
    [ -f "$REPO/RESUME.bg.md" ]
    [ -f "$REPO/CHANGELOG.bg.md" ]
    [ ! -e "$REPO/RESUME.md" ]
    grep -qxF 'RESUME.bg.md' "$REPO/.git/info/exclude"
}

@test "mark-done writes the completion marker and excludes it from git" {
    ( cd "$REPO" && git init -q )
    run in_repo bash "$HELPER" mark-done
    [ "$status" -eq 0 ]
    [ -f "$REPO/.ccage-session-done" ]
    grep -qxF '.ccage-session-done' "$REPO/.git/info/exclude"
    # excluded → invisible to git status
    [ -z "$( cd "$REPO" && git status --porcelain )" ]
}

@test "mark-done is idempotent: re-run does not duplicate the exclude line" {
    ( cd "$REPO" && git init -q )
    in_repo bash "$HELPER" mark-done
    run in_repo bash "$HELPER" mark-done
    [ "$status" -eq 0 ]
    [ "$(grep -cxF '.ccage-session-done' "$REPO/.git/info/exclude")" -eq 1 ]
}

@test "clear-done removes the marker and is a no-op when already absent" {
    in_repo bash "$HELPER" mark-done
    [ -f "$REPO/.ccage-session-done" ]
    run in_repo bash "$HELPER" clear-done
    [ "$status" -eq 0 ]
    [ ! -e "$REPO/.ccage-session-done" ]
    run in_repo bash "$HELPER" clear-done          # idempotent
    [ "$status" -eq 0 ]
}

@test "mark-done outside a git repo: writes the marker, no crash, no exclude" {
    run in_repo bash "$HELPER" mark-done
    [ "$status" -eq 0 ]
    [ -f "$REPO/.ccage-session-done" ]
    [ ! -e "$REPO/.git" ]
}

@test "unknown subcommand: usage error, exit 2" {
    run in_repo bash "$HELPER" frobnicate
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage:"* ]]
}
