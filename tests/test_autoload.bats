#!/usr/bin/env bats
# Tests for the SessionStart auto-read hook — Phase 7 (component B + G).
# The hook is a standalone executable; run it as a subprocess with a controlled
# cwd and environment (it reads $CCAGE_SLOT / $CLAUDE_CONFIG_DIR from the env it
# inherits from the claude process).
bats_require_minimum_version 1.5.0

HOOK="$BATS_TEST_DIRNAME/../share/hooks/resume_autoload.sh"

setup() {
    REPO="$BATS_TEST_TMPDIR/repo"
    CAGE="$BATS_TEST_TMPDIR/cage"
    mkdir -p "$REPO"
    unset CCAGE_SLOT CCAGE_RESUME_BUDGET_LINES CCAGE_MEMORY_ORPHAN_MAX
    export CLAUDE_CONFIG_DIR="$CAGE"
    unset CLAUDE_PROJECT_DIR
}

# Run the hook with cwd = the temp repo (mirrors how Claude Code runs hooks).
run_hook() { ( cd "$REPO" && "$HOOK" ); }

# Path to this cage's memory dir for the repo, matching the hook's slug logic:
# replace BOTH "/" and "_" with "-" via two single-char subs (no bracket class,
# which macOS bash 3.2 mishandles).
memdir() { local s="${REPO//\//-}"; s="${s//_/-}"; printf '%s/projects/%s/memory' "$CAGE" "$s"; }

@test "no RESUME: empty stdout, exit 0" {
    run run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "RESUME present: contents echoed to stdout" {
    printf '# Resume\n\nthread one\n' > "$REPO/RESUME.md"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"thread one"* ]]
}

@test "CCAGE_SLOT=review: reads RESUME.review.md, not RESUME.md" {
    printf 'PLAIN FILE\n' > "$REPO/RESUME.md"
    printf 'SLOT FILE\n'  > "$REPO/RESUME.review.md"
    CCAGE_SLOT=review run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"SLOT FILE"* ]]
    [[ "$output" != *"PLAIN FILE"* ]]
}

@test "unsafe CCAGE_SLOT: falls back to plain RESUME.md" {
    printf 'PLAIN FILE\n' > "$REPO/RESUME.md"
    CCAGE_SLOT="bad/slot" run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"PLAIN FILE"* ]]
}

@test "RESUME over line budget: emits trim NOTE" {
    seq 1 300 > "$REPO/RESUME.md"
    CCAGE_RESUME_BUDGET_LINES=250 run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"over budget"* ]]
    [[ "$output" == *"/checkpoint"* ]]
}

@test "RESUME under budget: no trim NOTE" {
    seq 1 50 > "$REPO/RESUME.md"
    CCAGE_RESUME_BUDGET_LINES=250 run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" != *"over budget"* ]]
}

@test "more than 3 session blocks: emits trim NOTE even if short" {
    {
        echo "## Session 1"; echo "## Session 2"
        echo "## Session 3"; echo "## Session 4"
    } > "$REPO/RESUME.md"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"over budget"* ]]
}

@test "messy memory (dead index link): emits tidy NOTE" {
    local md; md="$(memdir)"; mkdir -p "$md"
    printf -- '- [Gone](missing_note.md) — hook\n' > "$md/MEMORY.md"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"--tidy"* ]]
}

@test "clean memory (all links resolve): no tidy NOTE" {
    local md; md="$(memdir)"; mkdir -p "$md"
    printf 'fact\n' > "$md/note_a.md"
    printf -- '- [A](note_a.md) — hook\n' > "$md/MEMORY.md"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" != *"--tidy"* ]]
}

@test "many orphan memory files: emits tidy NOTE" {
    local md; md="$(memdir)"; mkdir -p "$md"
    printf -- '- [A](note_1.md) — hook\n' > "$md/MEMORY.md"
    local i
    for i in $(seq 1 6); do printf 'x\n' > "$md/note_$i.md"; done
    CCAGE_MEMORY_ORPHAN_MAX=3 run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"--tidy"* ]]
}

@test "no memory dir at all: no tidy NOTE" {
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" != *"--tidy"* ]]
}
