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

# Run the hook with the SessionStart JSON on stdin, as Claude Code delivers it.
run_hook_src() { ( cd "$REPO" && printf '{"source":"%s"}' "$1" | "$HOOK" ); }

# Path to this cage's memory dir for the repo. Deliberately an INDEPENDENT
# implementation of the slug rule (python re.sub, not the hook's tr) so the
# tests pin the rule itself — every non-alphanumeric char becomes "-" —
# rather than mirroring whatever the hook happens to do.
memdir() {
    local s
    s=$(python3 -c 'import re,sys; print(re.sub(r"[^A-Za-z0-9]", "-", sys.argv[1]))' "$REPO")
    printf '%s/projects/%s/memory' "$CAGE" "$s"
}

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

# ===== slug regression — pinned to Claude Code's real projects/ layout =====
# Claude Code converts EVERY non-alphanumeric cwd char to "-" ("_" and "."
# included, verified against real cages). A "/"-only slug silently misses the
# memory dir for any path containing "_" or ".".

@test "slug: repo path with _ and . still resolves the memory dir (tidy NOTE fires)" {
    REPO="$BATS_TEST_TMPDIR/my_repo.v2"
    mkdir -p "$REPO"
    local md; md="$(memdir)"; mkdir -p "$md"
    printf -- '- [Gone](missing_note.md) — hook\n' > "$md/MEMORY.md"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"--tidy"* ]]
}

# ===== completion-marker lifecycle by SessionStart source =====

@test "marker: cleared on source=startup" {
    : > "$REPO/.ccage-session-done"
    run run_hook_src startup
    [ "$status" -eq 0 ]
    [ ! -e "$REPO/.ccage-session-done" ]
}

@test "marker: cleared on source=resume (claude -r means working again)" {
    : > "$REPO/.ccage-session-done"
    run run_hook_src resume
    [ "$status" -eq 0 ]
    [ ! -e "$REPO/.ccage-session-done" ]
}

@test "marker: survives source=clear and source=compact" {
    : > "$REPO/.ccage-session-done"
    run run_hook_src clear
    [ "$status" -eq 0 ]
    [ -e "$REPO/.ccage-session-done" ]
    run run_hook_src compact
    [ "$status" -eq 0 ]
    [ -e "$REPO/.ccage-session-done" ]
}

@test "autock control file: cleared on startup/resume, survives clear/compact" {
    # The /checkpoint-threshold override is transient per-run: it must NOT carry
    # into a genuinely new session, but MUST survive ccage-auto's own /clear.
    : > "$REPO/.ccage-autock.conf"
    run run_hook_src startup
    [ "$status" -eq 0 ]
    [ ! -e "$REPO/.ccage-autock.conf" ]

    : > "$REPO/.ccage-autock.conf"
    run run_hook_src resume
    [ "$status" -eq 0 ]
    [ ! -e "$REPO/.ccage-autock.conf" ]

    : > "$REPO/.ccage-autock.conf"
    run run_hook_src clear
    [ "$status" -eq 0 ]
    [ -e "$REPO/.ccage-autock.conf" ]
    run run_hook_src compact
    [ "$status" -eq 0 ]
    [ -e "$REPO/.ccage-autock.conf" ]
}

# ===== bounded injection =====

@test "huge RESUME: injection truncated at 2x budget with a NOTE" {
    seq 1 600 > "$REPO/RESUME.md"
    CCAGE_RESUME_BUDGET_LINES=250 run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"truncated at 500 lines"* ]]
    [[ "$output" == *$'\n500\n'* ]]     # last injected line
    [[ "$output" != *$'\n501\n'* ]]     # nothing beyond the cut
}

@test "RESUME within 2x budget: injected whole, no truncation NOTE" {
    seq 1 300 > "$REPO/RESUME.md"
    CCAGE_RESUME_BUDGET_LINES=250 run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\n300'* ]]
    [[ "$output" != *"truncated"* ]]
}

# ===== byte budget (dense content can bloat under the line cap) =====

@test "RESUME under line budget but over byte budget: emits over-budget NOTE" {
    local line; line=$(printf 'x%.0s' $(seq 1 500))
    yes "$line" | head -n 40 > "$REPO/RESUME.md"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"over budget"* ]]
}

@test "small RESUME: no byte-budget NOTE" {
    printf 'short\n' > "$REPO/RESUME.md"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" != *"over budget"* ]]
}

# ===== plan-doc pointers (component 1b: read-the-plan directive) =====
#
# Detection is SCOPED to the `### Plan` section — the one place /checkpoint
# records the governing doc's exact path. A plan-doc path anywhere else in
# RESUME (a Session block, a Threads bullet, tangential history) must NOT fire
# the directive: the old whole-file scan mis-fired on stale/foreign `PLAN.md`
# mentions and on sessions that were never plan-governed. NOTE lines carry the
# resolved ABSOLUTE path, so "not listed" assertions key on the "$REPO/…" form
# (or the "DISPATCHER mode" signature) — the hook also echoes the raw RESUME
# body, which contains the relative mention.

@test "plan pointer: governing doc under ### Plan earns the READ+dispatch NOTE" {
    mkdir -p "$REPO/plans"
    printf '# the real plan\n' > "$REPO/plans/2026-07-16-feature-plan.md"
    {
        printf '## State\n\n'
        printf '### Plan\n'
        printf -- '- `plans/2026-07-16-feature-plan.md` — 2/5 done; next wave A,B\n'
    } > "$REPO/RESUME.md"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"READ each doc before executing"* ]]
    [[ "$output" == *"DISPATCHER mode"* ]]
    [[ "$output" == *"$REPO/plans/2026-07-16-feature-plan.md"* ]]
}

@test "plan pointer: a doc under ### Plan that is MISSING on disk earns silence" {
    {
        printf '### Plan\n'
        printf -- '- plans/long-gone-plan.md — 0/3 done\n'
    } > "$REPO/RESUME.md"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" != *"DISPATCHER mode"* ]]
}

@test "plan pointer: absolute path under ### Plan resolves; more than 5 refs capped" {
    mkdir -p "$REPO/other"
    printf 'x\n' > "$REPO/other/IMPLEMENTATION_PLAN.md"
    {
        printf '### Plan\n'
        printf -- '- abs: %s/other/IMPLEMENTATION_PLAN.md\n' "$REPO"
        for i in 1 2 3 4 5 6 7; do printf -- '- also plans/missing-%s-plan.md\n' "$i"; done
    } > "$REPO/RESUME.md"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"$REPO/other/IMPLEMENTATION_PLAN.md"* ]]
}

@test "plan pointer: RESUME with no ### Plan section stays exactly as before" {
    printf '## State\n- just prose, nothing planny\n' > "$REPO/RESUME.md"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" != *"DISPATCHER"* ]]
    [[ "$output" == *"just prose"* ]]
}

@test "plan pointer: programme-plan layout under ### Plan (MASTER.md + strand) is detected" {
    mkdir -p "$REPO/plan"
    printf '# index\n' > "$REPO/plan/MASTER.md"
    printf '# strand\n' > "$REPO/plan/strand-a.md"
    {
        printf '### Plan\n'
        printf -- '- programme index: plan/MASTER.md\n'
        printf -- '- working strand: plan/strand-a.md\n'
    } > "$REPO/RESUME.md"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"$REPO/plan/MASTER.md"* ]]
    [[ "$output" == *"$REPO/plan/strand-a.md"* ]]
    [[ "$output" == *"DISPATCHER mode"* ]]
}

# --- over-fire guards: the whole point of scoping to ### Plan ---

@test "plan pointer: a plan doc mentioned OUTSIDE ### Plan (Session block) stays silent" {
    mkdir -p "$REPO/docs"
    printf 'x\n' > "$REPO/docs/OLD-PLAN.md"          # exists on disk...
    {
        printf '## State\n\n### Now\n- shipping v1\n\n'
        printf '## Session 2026-07-16\n'
        printf 'Earlier we followed docs/OLD-PLAN.md, now superseded.\n'  # ...but only in history
    } > "$REPO/RESUME.md"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" != *"DISPATCHER mode"* ]]
    [[ "$output" != *"$REPO/docs/OLD-PLAN.md"* ]]     # abs form = the NOTE listing it
}

@test "plan pointer: only ### Plan docs listed, not a stray existing PLAN.md elsewhere" {
    mkdir -p "$REPO/docs"
    printf 'live\n'  > "$REPO/docs/WEEKLY-GUARD.md"
    printf 'stale\n' > "$REPO/docs/PLAN.md"           # exists, but not the governing doc
    {
        printf '### Plan\n- `docs/WEEKLY-GUARD.md` — 3/3 built; release remains\n\n'
        printf '## Session\nBuilt on top of the old docs/PLAN.md scaffold.\n'
    } > "$REPO/RESUME.md"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"$REPO/docs/WEEKLY-GUARD.md"* ]]
    [[ "$output" != *"$REPO/docs/PLAN.md"* ]]
}

@test "plan pointer: bootstrap ### Plan placeholder (no real .md) stays silent" {
    {
        printf '### Plan\n'
        printf -- '- <full path to plan doc> — <N/M tasks done>\n'
    } > "$REPO/RESUME.md"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" != *"DISPATCHER mode"* ]]
}
