#!/usr/bin/env bats
# Behavioral tests for the PostToolUse budget guard (share/hooks/resume_budget_check.sh).
# The hook reads a PostToolUse payload on stdin. When the edited file is a RESUME
# file over the block budget (MAX 3) or the byte budget, it ENFORCES: exit 2 with
# stderr guidance. Two exceptions stay advisory (exit 0 + jq JSON): observe mode,
# and a write that SHRINKS the file (never block the trim that fixes it).
# Silent + exit 0 in every other case.
bats_require_minimum_version 1.5.0

setup() {
    command -v jq >/dev/null 2>&1 || skip "jq required"
    HOOK="$BATS_TEST_DIRNAME/../share/hooks/resume_budget_check.sh"
    # HERMETIC: the hook records last-seen sizes under CLAUDE_CONFIG_DIR. Without
    # this the suite would write into the developer's real ~/.claude and, worse,
    # inherit its state — the same non-hermeticity that made the autock tests
    # pass in CI while failing on the developer's machine.
    export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
    mkdir -p "$CLAUDE_CONFIG_DIR"
    unset "${!CCAGE_RESUME_BUDGET@}"
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

@test "over-budget RESUME (>3 blocks) BLOCKS with exit 2" {
    local r="$BATS_TEST_TMPDIR/RESUME.md"; blocks 4 "$r"
    run emit "$r"
    [ "$status" -eq 2 ]
    [[ "$output" == *"session blocks"* ]]
    [[ "$output" == *"blocking error"* ]]
}

@test "observe mode keeps the old advisory JSON contract" {
    local r="$BATS_TEST_TMPDIR/RESUME.md"; blocks 5 "$r"
    CCAGE_RESUME_BUDGET_MODE=observe run emit "$r"
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
    [ "$status" -eq 2 ]
    [[ "$output" == *"session blocks"* ]]
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

# ===== byte budget (dense content can bloat under the block cap) =====

@test "dense RESUME under block budget but over byte budget BLOCKS" {
    local r="$BATS_TEST_TMPDIR/RESUME.md"
    local line; line=$(printf 'x%.0s' $(seq 1 500))
    yes "$line" | head -n 40 > "$r"
    run emit "$r"
    [ "$status" -eq 2 ]
    [[ "$output" == *"14000 bytes"* ]]
}

@test "lean RESUME (few blocks, small bytes) stays silent" {
    local r="$BATS_TEST_TMPDIR/RESUME.md"; blocks 1 "$r"
    run emit "$r"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ===== enforcement: progress must never be punished =====

@test "a write that SHRINKS an over-budget RESUME is advised, not blocked" {
    local r="$BATS_TEST_TMPDIR/RESUME.md"
    local line; line=$(printf 'x%.0s' $(seq 1 500))
    yes "$line" | head -n 60 > "$r"      # well over budget
    run emit "$r"                        # first write: seeds state, blocks
    [ "$status" -eq 2 ]
    yes "$line" | head -n 40 > "$r"      # smaller, still over budget
    run emit "$r"
    [ "$status" -eq 0 ]                  # progress -> advisory only
    [[ "$output" == *"shrinking, keep going"* ]]
}

@test "growing further while already over budget still BLOCKS" {
    local r="$BATS_TEST_TMPDIR/RESUME.md"
    local line; line=$(printf 'x%.0s' $(seq 1 500))
    yes "$line" | head -n 40 > "$r"
    run emit "$r"
    [ "$status" -eq 2 ]
    yes "$line" | head -n 60 > "$r"      # grew
    run emit "$r"
    [ "$status" -eq 2 ]
}

@test "the state file records the last-seen size and does not accumulate duplicates" {
    local r="$BATS_TEST_TMPDIR/RESUME.md"; blocks 4 "$r"
    run emit "$r"; run emit "$r"; run emit "$r"
    local state="$CLAUDE_CONFIG_DIR/.resume_budget_state"
    [ -f "$state" ]
    [ "$(grep -cF "$r" "$state")" -eq 1 ]
}

@test "an unwritable config dir degrades to enforcing, never crashes" {
    local r="$BATS_TEST_TMPDIR/RESUME.md"; blocks 4 "$r"
    CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/nonexistent-dir" run emit "$r"
    [ "$status" -eq 2 ]
}

@test "a lean RESUME writes state but stays silent" {
    local r="$BATS_TEST_TMPDIR/RESUME.md"; blocks 1 "$r"
    run emit "$r"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -f "$CLAUDE_CONFIG_DIR/.resume_budget_state" ]
}
