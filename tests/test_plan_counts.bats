#!/usr/bin/env bats
# Part A of the plan-staleness fix: honest plan counts (status segment, session start, spread).
# The fixture is the ten plan documents RESUME listed on 21 Nov 2026 before they were reconciled
# (tests/fixtures/plan_staleness, each trimmed to its headings and checkbox items): 53 open boxes
# of 102, 29 open of 62 in the first five, and one finished document (the GS32 plan).
bats_require_minimum_version 1.5.0

export CCAGE_NO_INTERACTIVE_RESOLVE=1

HOOK="$BATS_TEST_DIRNAME/../share/hooks/resume_autoload.sh"
LIB="$BATS_TEST_DIRNAME/../share/hooks/lib/plan_docs.sh"
FIXTURE="$BATS_TEST_DIRNAME/fixtures/plan_staleness"

setup() {
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO"
    export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cage"
    unset CLAUDE_PROJECT_DIR CCAGE_AUTOLOAD_MAX_PLANS CCAGE_PLAN_SPREAD_MIN
    cp -r "$FIXTURE/." "$REPO/"
}

segment() { bash -c '. "$1"; plan_status_segment "$2/RESUME.md" "$2"' _ "$LIB" "$REPO"; }

@test "status segment: open first, over all ten listed documents, finished ones named" {
    run segment
    [ "$status" -eq 0 ]
    # the old segment printed "33/62 steps" (done over total, first five documents only)
    [ "$output" = "plan 53 open / 102 (10 docs, 1 finished)" ]
}

@test "status segment: listed documents without a checkbox say so; no document, no segment" {
    printf '# n\nno boxes\n' > "$REPO/docs/only.md"
    printf '### Plan\n- docs/only.md\n' > "$REPO/RESUME.md"
    run segment
    [ "$output" = "plan: no checkboxes to count" ]
    printf '### Plan\n- docs/missing.md\n' > "$REPO/RESUME.md"
    run segment
    [ -z "$output" ]
}

@test "session start: the totals cover every listed document, past the read-first cap" {
    run bash -c 'cd "$1" && "$2" </dev/null' _ "$REPO" "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PLAN COUNT (fact): 53 open of 102 boxes in all 10 listed documents; 1 finished"* ]]
    # the five dropped from the read-first list are announced and say they are counted
    [[ "$output" == *"counted in PLAN COUNT below:"* ]]
}

@test "plan spread: plans kept out of git are found on disk when git holds no live plan" {
    rm -rf "$REPO/docs"
    git -C "$REPO" init -q
    printf 'notes/\n' >> "$REPO/.git/info/exclude"
    mkdir -p "$REPO/notes/design"
    for n in a b c; do printf -- '- [ ] open, `x.py`\n' > "$REPO/notes/design/${n}_plan.md"; done
    printf '# Resume\n\n### Plan\n- notes/design/a_plan.md\n' > "$REPO/RESUME.md"
    run bash -c 'cd "$1" && "$2" </dev/null' _ "$REPO" "$HOOK"
    [[ "$output" == *'PLAN SPREAD (fact): 3 plan files here still hold open items; RESUME "### Plan" names 1 of them'* ]]
    # a folder named in CCAGE_PLAN_FIND_PRUNE is not searched
    CCAGE_PLAN_FIND_PRUNE="notes" run bash -c 'cd "$1" && "$2" </dev/null' _ "$REPO" "$HOOK"
    [[ "$output" != *"PLAN SPREAD"* ]]
}
