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

# sed_inplace SCRIPT FILE: in-place sed on GNU and BSD alike. `-i` with an attached suffix is the one
# form both accept (BSD reads a bare `-i 's/...'` as a backup suffix: "invalid command code").
sed_inplace() { sed -i.bak "$1" "$2" && rm -f "$2.bak"; }

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
    sed_inplace 's/^- \[ \] W10\. \(.*\)$/- [ ] W10. \1 (open 2026-11-21: settings part DONE; left: rule reads; blocked on job 8696014)/' "$doc"
    grep -q "(open 2026-11-21" "$doc"
    run -0 fire "$P/RESUME.md" "   $W10"
    sed_inplace 's/^- \[ \] W10\. /- [x] W10. /; s/ (open 2026-11-21:.*$//' "$doc"
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

@test "E: a ruling that supersedes another names the open plan items still citing the old one, once" {
    local d385; d385="$(grep -m1 '^- \*\*D385\*\*' "$P/DECISIONS.md")"
    run -0 fire "$P/DECISIONS.md" "$d385"
    local note; note="$(printf '%s' "$output" | jq -r '.systemMessage')"
    [[ "$note" == *"4. in plan_paper_runs_after_state_following_trial_2026-11-17.md cites D320, which D385 supersedes or amends"* ]]
    [[ "$note" == *"W1 in work_list_2026-11-19.md cites D368, which D385 supersedes"* ]]
    # not a block, and the baseline note of a first write is still said
    [[ "$note" == *"DECISIONS baseline recorded"* ]]
    # the same pair is named once
    run -0 fire "$P/DECISIONS.md" "$d385"
    [ -z "$output" ]
    grep -q "NOTE-planrulings" "$LOG"
    grep -q "ALLOW-planrulings" "$LOG"
}

@test "E: an entry that supersedes nothing, and an item that already cites the new ruling, are silent" {
    local d385; d385="$(grep -m1 '^- \*\*D385\*\*' "$P/DECISIONS.md")"
    # an edit that adds an unrelated entry says nothing about D385, whose citations are still open
    run -0 fire "$P/DECISIONS.md" "- **D500** (2026-11-22, owner 'y') A ruling that replaces nothing: items cite D320 freely."
    [[ "$output" != *"cites D3"* ]]
    sed_inplace 's/^\(- \[ \] 4\. .*\)$/\1 (open 2026-11-21: Prodigy replaced, D385)/' "$P/docs/plan_paper_runs_after_state_following_trial_2026-11-17.md"
    sed_inplace 's/^\(- \[ \] W1 .*\)$/\1 (open 2026-11-21: D385 replaced the optimizer)/' "$P/docs/work_list_2026-11-19.md"
    run -0 fire "$P/DECISIONS.md" "$d385"
    [[ "$output" != *"cites D3"* ]]
}
