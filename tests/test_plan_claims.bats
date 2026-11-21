#!/usr/bin/env bats
# Parts C and E of the plan-staleness fix: what RESUME and DECISIONS say about plan items,
# checked by the PostToolUse hook resume_budget_check.sh when either file is edited.
# Fixture: tests/fixtures/plan_staleness (the ten plan documents RESUME listed on 21 Nov 2026
# before they were reconciled, RESUME, five rulings, CHANGELOG).
bats_require_minimum_version 1.5.0

HOOK="$BATS_TEST_DIRNAME/../share/hooks/resume_budget_check.sh"
FIXTURE="$BATS_TEST_DIRNAME/fixtures/plan_staleness"
W10='W10: DONE (worker), MERGED + PUSHED af969669 (overlays covariance_form/point_scaled|point_state; swe64 settings:'

setup() {
    command -v jq >/dev/null 2>&1 || skip "jq required"
    P="$BATS_TEST_TMPDIR/proj"
    cp -r "$FIXTURE" "$P"
    export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg" HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$CLAUDE_CONFIG_DIR" "$HOME/.claude"
    unset "${!CCAGE_RESUME_BUDGET@}" "${!CCAGE_PLAN@}" CLAUDE_PROJECT_DIR
    LOG="$CLAUDE_CONFIG_DIR/resume_budget_check.log"
}

# fire FILE TEXT: the PostToolUse payload of an Edit of FILE that put TEXT in it, sent to the hook.
fire() {
    python3 -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1],"old_string":"x","new_string":sys.argv[2]}}))' "$1" "$2" \
        | bash "$HOOK"
}

@test "C: RESUME calls W10 done while the plan shows it open: refused once, naming the item and the remedy" {
    run -2 --separate-stderr fire "$P/RESUME.md" "   $W10"
    [[ "$stderr" == *"W10 in docs/work_list_2026-11-21.md"* ]]
    [[ "$stderr" == *"DONE <date>: <evidence>"* && "$stderr" == *"(open <date>: <what remains>"* ]]
    [ "$(printf '%s\n' "$stderr" | wc -l)" -le 5 ]
    # the same text again passes: blocked once, deliberately
    run -0 fire "$P/RESUME.md" "   $W10"
    grep -q "DENY-planclaims" "$LOG"
    grep -q "ALLOW-planclaims" "$LOG"
}

@test "C: an item that is ticked, or annotated with what remains, is not contradicted" {
    local doc="$P/docs/work_list_2026-11-21.md"
    sed -i 's/^- \[ \] W10\. \(.*\)$/- [ ] W10. \1 (open 2026-11-21: settings part DONE; left: rule reads; blocked on job 8696014)/' "$doc"
    grep -q "(open 2026-11-21" "$doc"
    run -0 fire "$P/RESUME.md" "   $W10"
    sed -i 's/^- \[ \] W10\. /- [x] W10. /; s/ (open 2026-11-21:.*$//' "$doc"
    run -0 fire "$P/RESUME.md" "   $W10"
}

@test "C: negation, a lower-case done and an ID open in two documents without a document name are not claims" {
    run -0 fire "$P/RESUME.md" "   W10: NOT DONE yet, not MERGED"
    run -0 fire "$P/RESUME.md" "   W10: when done, merge it"
    # P1 is open in the CI plan and in the next-systems plan: which one is not said
    run -0 fire "$P/RESUME.md" "   P1 DONE (the audit)"
    grep -q "CLAIMS-AMBIGUOUS.*P1" "$CLAUDE_CONFIG_DIR/plan_contract_guard.log"
    # naming the document settles it
    run -2 --separate-stderr fire "$P/RESUME.md" "   plan_ci_green_and_test_pruning_2026-11-19 P1 DONE (the audit)"
    [[ "$stderr" == *"P1 in docs/plan_ci_green_and_test_pruning_2026-11-19.md"* ]]
    # W3 is finished in the 21 Nov list (listed first) and open in the 19 Nov list: "W3: DONE" is the
    # first one's (measured in the real RESUME of 21 Nov), unless the line names the 19 Nov list
    run -0 fire "$P/RESUME.md" "   W3: DONE + PUSHED feb31cf8"
    run -2 --separate-stderr fire "$P/RESUME.md" "   work_list_2026-11-19 W3: DONE"
    [[ "$stderr" == *"W3 in docs/work_list_2026-11-19.md"* ]]
}

@test "C: observe mode says it as a note and does not block" {
    CCAGE_RESUME_BUDGET_MODE=observe run -0 fire "$P/RESUME.md" "   $W10"
    [[ "$output" == *"W10 in docs/work_list_2026-11-21.md"* ]]
}

@test "B: session start prints the stale-plan facts, and nothing for a project with none" {
    export CCAGE_NO_INTERACTIVE_RESOLVE=1
    run bash -c 'cd "$1" && "$2" </dev/null' _ "$P" "$BATS_TEST_DIRNAME/../share/hooks/resume_autoload.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PLAN STALE (facts, checkable"* ]]
    [[ "$output" == *"W1 in work_list_2026-11-19.md cites D368, which D385 supersedes"* ]]
    [[ "$output" == *"plan_gs32_input_following_sizes_2026-11-16.md has no open item (5 done)"* ]]
    # a project whose open item is annotated, whose rulings supersede nothing it cites and
    # whose plan is not finished has nothing to say
    printf '%s\n' '- [ ] A1 open (open 2026-11-21: waiting on the owner)' > "$P/docs/a.md"
    printf '### Plan\n- docs/a.md — in progress\n' > "$P/RESUME.md"
    run bash -c 'cd "$1" && "$2" </dev/null' _ "$P" "$BATS_TEST_DIRNAME/../share/hooks/resume_autoload.sh"
    [[ "$output" != *"PLAN STALE"* ]]
}
