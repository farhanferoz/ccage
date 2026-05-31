#!/usr/bin/env bats
# Behavioral tests for the PostToolUse budget guard (share/hooks/resume_budget_check.sh).
# The hook reads a PostToolUse payload on stdin, and when the edited file is a
# RESUME file with more than MAX (3) "## Session" blocks, emits a non-blocking
# jq reminder. Silent + exit 0 in every other case.
bats_require_minimum_version 1.5.0

setup() {
    command -v jq >/dev/null 2>&1 || skip "jq required"
    HOOK="$BATS_TEST_DIRNAME/../share/hooks/resume_budget_check.sh"
}

# Feed a synthesized PostToolUse payload referencing $1; hook stdout is captured.
emit() { printf '{"tool_input":{"file_path":"%s"}}' "$1" | bash "$HOOK"; }
# Feed raw bytes straight to the hook (for the malformed-stdin cases).
feed() { printf '%s' "$1" | bash "$HOOK"; }

blocks() {  # write $1 "## Session" blocks to file $2
    local n="$1" f="$2" i
    : > "$f"
    for ((i = 1; i <= n; i++)); do printf '## Session %d\nstuff\n' "$i" >> "$f"; done
}

@test "over-budget RESUME (>3 blocks) emits a reminder" {
    local r="$BATS_TEST_TMPDIR/RESUME.md"; blocks 4 "$r"
    run emit "$r"
    [ "$status" -eq 0 ]
    [[ "$output" == *systemMessage* ]]
    [[ "$output" == *"session blocks"* ]]
}

@test "the emitted reminder is valid JSON with a PostToolUse additionalContext" {
    local r="$BATS_TEST_TMPDIR/RESUME.md"; blocks 5 "$r"
    run emit "$r"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.systemMessage and .hookSpecificOutput.additionalContext' >/dev/null
    [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "PostToolUse" ]
}

@test "exactly 3 blocks (== MAX) is within budget — no output" {
    local r="$BATS_TEST_TMPDIR/RESUME.md"; blocks 3 "$r"
    run emit "$r"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "under-budget RESUME (2 blocks) — no output" {
    local r="$BATS_TEST_TMPDIR/RESUME.md"; blocks 2 "$r"
    run emit "$r"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a slot-aware RESUME.<slot>.md is recognized by the budget guard" {
    local r="$BATS_TEST_TMPDIR/RESUME.review.md"; blocks 4 "$r"
    run emit "$r"
    [ "$status" -eq 0 ]
    [[ "$output" == *systemMessage* ]]
}

@test "a non-RESUME file is a silent no-op" {
    local r="$BATS_TEST_TMPDIR/NOTES.md"; blocks 9 "$r"
    run emit "$r"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "an over-budget RESUME path that no longer exists is a no-op" {
    run emit "$BATS_TEST_TMPDIR/RESUME.md"   # file never created
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "missing file_path in the payload exits 0 without output" {
    run feed '{"tool_input":{}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "garbage (non-JSON) stdin exits 0 without crashing" {
    run feed 'not json at all'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "empty stdin exits 0 without crashing" {
    run feed ''
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
