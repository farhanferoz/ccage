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

# --- the cap must not silently drop the doc that matters -------------------
# MEASURED 2026-08-13 on the live ccage RESUME: `sort -u | head -5` ran BEFORE
# the existence filter, so alphabetical order plus a prose `CLAUDE.md` token
# displaced BOTH governing docs of the running programme, with no notice. The
# mechanism built against silent plan-item loss silently lost the plan.

@test "plan pointer: listing order beats alphabetical under the cap" {
    # 6 real docs; the governing one is listed FIRST but sorts LAST alphabetically.
    mkdir -p "$REPO/plans"
    for n in zz-governing aa bb cc dd ee; do printf 'x\n' > "$REPO/plans/$n.md"; done
    {
        printf '### Plan\n'
        printf -- '- `plans/zz-governing.md` — THE governing doc\n'
        for n in aa bb cc dd ee; do printf -- '- plans/%s.md\n' "$n"; done
    } > "$REPO/RESUME.md"
    run run_hook
    [ "$status" -eq 0 ]
    # Assert on the RESOLVED ABSOLUTE path: the hook echoes RESUME's own body
    # too, where the relative `plans/zz-governing.md` token appears regardless,
    # so a bare substring match passes even when the doc was dropped. Only the
    # NOTE block carries the absolute form.
    [[ "$output" == *"  - $REPO/plans/zz-governing.md"* ]]  # survived the cap, first slot
    [[ "$output" == *"NOT shown or counted: ee.md"* ]]      # the drop is announced, by name
}

@test "plan pointer: missing refs do not consume cap slots" {
    # 6 refs that do NOT exist listed before 1 that does: the real doc must survive.
    mkdir -p "$REPO/plans"
    printf 'x\n' > "$REPO/plans/real-plan.md"
    {
        printf '### Plan\n'
        for i in 1 2 3 4 5 6; do printf -- '- plans/ghost-%s.md\n' "$i"; done
        printf -- '- `plans/real-plan.md`\n'
    } > "$REPO/RESUME.md"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"  - $REPO/plans/real-plan.md"* ]]     # absolute form: NOTE, not echo
}

@test "plan pointer: five or fewer existing refs emit no drop notice" {
    mkdir -p "$REPO/plans"
    for n in a b; do printf 'x\n' > "$REPO/plans/$n.md"; done
    printf '### Plan\n- plans/a.md\n- plans/b.md\n' > "$REPO/RESUME.md"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" != *"NOT shown"* ]]
}

# ===== watcher-alive guard on the startup/resume clear (Task 6, failure ====
# ===== mode 4 + the pgrep/lsof false-positive it was replaced with)     ====
#
# .ccage-session-done / .ccage-autock.conf are scoped to the PROJECT
# DIRECTORY, not to one session — any new session starting there fires its
# own `startup` hook, which must not wipe a file a DIFFERENT, still-running
# session's ccage-auto watcher depends on. Each watcher records itself in its
# OWN .ccage-autock.pid.<pid> (pid + a `ps -o etime=`-derived start-time
# token); the hook reads those specific pids instead of scanning every process
# on the machine, so there is nothing left to substring-match against — and
# because no watcher ever writes or removes a sibling's file, a second watcher
# in the same directory can neither overwrite nor delete the first's ownership
# (the regressions below).

# Parses ps's `[[DD-]hh:]mm:ss` elapsed-time format (stdin) into seconds on
# stdout. Mirrors the awk block embedded in resume_autoload.sh exactly, so
# this test file's OWN fixtures compute start times the same portable way
# the hook does — `etimes=` (bare seconds) is Linux/procps-only and would
# silently misbehave on the macOS CI leg this suite also runs on.
parse_etime() {
    awk '
        {
            s = $0
            gsub(/^[ \t]+|[ \t]+$/, "", s)
            days = 0
            if (split(s, dparts, "-") == 2) { days = dparts[1] + 0; s = dparts[2] }
            n = split(s, t, ":")
            if (n == 2)      { h = 0; m = t[1]; sec = t[2] }
            else if (n == 3) { h = t[1]; m = t[2]; sec = t[3] }
            else             { exit 1 }
            printf "%d\n", days*86400 + h*3600 + m*60 + sec
        }'
}

pidfile_for() {  # pidfile_for PID -- write a liveness record for a real, live pid
    local pid="$1" elapsed start
    elapsed="$(ps -o etime= -p "$pid" 2>/dev/null | parse_etime)"
    start=$(( $(date +%s) - ${elapsed:-0} ))
    printf 'pid=%d\nstart=%d\n' "$pid" "$start" > "$REPO/.ccage-autock.pid.$pid"
}

@test "watcher pidfile absent: falls back to the original unconditional clear" {
    : > "$REPO/.ccage-session-done"
    : > "$REPO/.ccage-autock.conf"
    run run_hook_src startup
    [ "$status" -eq 0 ]
    [ ! -e "$REPO/.ccage-session-done" ]
    [ ! -e "$REPO/.ccage-autock.conf" ]
}

@test "watcher pidfile names a LIVE, unrelated pid: startup/resume must NOT clear" {
    : > "$REPO/.ccage-session-done"
    : > "$REPO/.ccage-autock.conf"
    pidfile_for "$$"          # this test's own shell -- alive, but not our launcher
    run run_hook_src startup
    [ "$status" -eq 0 ]
    [ -e "$REPO/.ccage-session-done" ]
    [ -e "$REPO/.ccage-autock.conf" ]
}

@test "watcher pidfile names THIS session's own launcher (CCAGE_AUTOCK_WATCHER_PID match): still clears" {
    : > "$REPO/.ccage-session-done"
    pidfile_for "$$"
    CCAGE_AUTOCK_WATCHER_PID="$$" run run_hook_src startup
    [ "$status" -eq 0 ]
    [ ! -e "$REPO/.ccage-session-done" ]
}

@test "watcher pidfile names a dead pid: falls back to clearing" {
    : > "$REPO/.ccage-session-done"
    printf 'pid=999999\nstart=1\n' > "$REPO/.ccage-autock.pid.999999"   # not a real pid
    run run_hook_src startup
    [ "$status" -eq 0 ]
    [ ! -e "$REPO/.ccage-session-done" ]
}

@test "pid-reuse guard: a live pid whose recorded start time doesn't match is treated as dead" {
    : > "$REPO/.ccage-session-done"
    # Same live pid as the 'unrelated watcher' test, but a start time that
    # can't be this shell's real one -- simulates ccage-auto exiting without
    # cleanup and an unrelated process later inheriting the same pid.
    printf 'pid=%d\nstart=1\n' "$$" > "$REPO/.ccage-autock.pid.$$"
    run run_hook_src startup
    [ "$status" -eq 0 ]
    [ ! -e "$REPO/.ccage-session-done" ]
}

# --- two watchers in one directory (W1) --------------------------------------
#
# The shared single pidfile reopened the very bug this guard exists to close.
# Both sequences below ended with a LIVE watcher's conf/done state deleted;
# per-watcher files make each one structurally impossible.

@test "W1-A: a sibling watcher's clean exit does not delete a live watcher's ownership" {
    : > "$REPO/.ccage-session-done"
    : > "$REPO/.ccage-autock.conf"
    # A (live, this shell) is watching; B starts in the same directory and then
    # exits normally. B's teardown removes its OWN record only -- with one
    # shared file it overwrote A's and then deleted it, leaving A invisible.
    ( cd "$REPO" && exec -a "sibling-watcher-B" sleep 5 ) &
    local b_pid=$!
    pidfile_for "$$"
    pidfile_for "$b_pid"
    [ -f "$REPO/.ccage-autock.pid.$$" ]          # B's start did not clobber A's
    kill "$b_pid" 2>/dev/null
    rm -f "$REPO/.ccage-autock.pid.$b_pid"       # B's teardown: its own file
    run run_hook_src startup
    [ "$status" -eq 0 ]
    [ -e "$REPO/.ccage-session-done" ]
    [ -e "$REPO/.ccage-autock.conf" ]
    [ -e "$REPO/.ccage-autock.pid.$$" ]          # ...and A still owns the dir
}

@test "W1-A2: a SIGKILLed sibling's stale record does not hide the live watcher" {
    : > "$REPO/.ccage-session-done"
    : > "$REPO/.ccage-autock.conf"
    # B is killed without cleanup, so its record survives naming a dead pid.
    # With one shared file that record was all the hook could see -> kill -0
    # failed -> live A's state was cleared. Now a dead record is skipped and
    # the scan continues to A's.
    ( cd "$REPO" && exec -a "sibling-watcher-B" sleep 5 ) &
    local b_pid=$!
    pidfile_for "$b_pid"
    pidfile_for "$$"
    kill -9 "$b_pid" 2>/dev/null
    wait "$b_pid" 2>/dev/null || true
    # Glob order is lexical, so also plant a dead record guaranteed to be
    # visited BEFORE A's: a dead entry must not end the scan early.
    printf 'pid=999999\nstart=1\n' > "$REPO/.ccage-autock.pid.0999999"
    run run_hook_src startup
    [ "$status" -eq 0 ]
    [ -e "$REPO/.ccage-session-done" ]
    [ -e "$REPO/.ccage-autock.conf" ]
}

@test "a legacy unsuffixed pidfile (watcher started before the upgrade) still blocks the clear" {
    : > "$REPO/.ccage-session-done"
    local elapsed start
    elapsed="$(ps -o etime= -p "$$" 2>/dev/null | parse_etime)"
    start=$(( $(date +%s) - ${elapsed:-0} ))
    printf 'pid=%d\nstart=%d\n' "$$" "$start" > "$REPO/.ccage-autock.pid"
    run run_hook_src startup
    [ "$status" -eq 0 ]
    [ -e "$REPO/.ccage-session-done" ]
}

@test "a process merely MENTIONING ccage-auto in its argv, cwd == project dir, does not block the clear" {
    # Regression for the pgrep -f 'ccage-auto' substring-match false positive:
    # a transient shell whose command line contains the word "ccage-auto"
    # (e.g. someone grepping for it) with cwd equal to the project dir used to
    # satisfy the old check and skip the delete. The pidfile mechanism has no
    # process-enumeration step left to fool -- confirm the marker still clears
    # even with such a process alive and correctly placed, and no pidfile.
    : > "$REPO/.ccage-session-done"
    ( cd "$REPO" && exec -a "grep-for-ccage-auto-mentions" sleep 5 ) &
    local noise_pid=$!
    sleep 0.2
    run run_hook_src startup
    kill "$noise_pid" 2>/dev/null
    [ "$status" -eq 0 ]
    [ ! -e "$REPO/.ccage-session-done" ]
}

@test "watcher-alive guard: hook stays fast (well under the old pgrep+lsof latency) with a marker present" {
    : > "$REPO/.ccage-session-done"
    local start end elapsed_ms
    start=$(date +%s%N)
    run run_hook_src startup
    end=$(date +%s%N)
    elapsed_ms=$(( (end - start) / 1000000 ))
    [ "$status" -eq 0 ]
    # Measured before this fix: ~1420ms with a marker present (pgrep + lsof
    # per match). Measured after: ~15-20ms. Generous CI-safe ceiling, still
    # an order of magnitude below the old behaviour -- catches a regression
    # back to process-scanning, not machine noise.
    [ "$elapsed_ms" -lt 300 ]
}

# Stubs `ps` to answer one canned BSD-shaped elapsed string for exactly
# `ps -o etime= -p <PID>`, delegating every other invocation to the real ps;
# echoes the directory to prepend to PATH. A canned elapsed time is what makes
# the tolerance tests below exact: the hook derives the running process's start
# as `now - elapsed`, so with `elapsed` pinned, the difference it compares
# against the recorded token is whatever the caller chose, not this machine's
# real process ages. The only slack left is the two `date +%s` calls (the
# caller's and the hook's) straddling a second boundary, worth +/-1s -- every
# offset below is picked so that slack cannot change the verdict.
PS_STUB_ETIME="1-02:00:15"    # 1d 2h 0m 15s, as [[DD-]hh:]mm:ss
PS_STUB_ELAPSED=93615         # the same duration in seconds

ps_stub_for() {   # ps_stub_for PID -- echoes a dir to prepend to PATH
    local pid="$1" real_ps stub_bin
    real_ps="$(command -v ps)"
    stub_bin="$BATS_TEST_TMPDIR/psstub"
    mkdir -p "$stub_bin"
    cat > "$stub_bin/ps" <<STUB
#!/usr/bin/env bash
match_etime=0
match_pid=0
next_is_pid=0
for a in "\$@"; do
    if [ "\$next_is_pid" = "1" ]; then
        [ "\$a" = "$pid" ] && match_pid=1
        next_is_pid=0
        continue
    fi
    [ "\$a" = "etime=" ] && match_etime=1
    [ "\$a" = "-p" ] && next_is_pid=1
done
if [ "\$match_etime" = "1" ] && [ "\$match_pid" = "1" ]; then
    echo "$PS_STUB_ETIME"
    exit 0
fi
exec "$real_ps" "\$@"
STUB
    chmod +x "$stub_bin/ps"
    printf '%s\n' "$stub_bin"
}

@test "pid-reuse guard parses ps -o etime= (a BSD-shaped elapsed string), and a regression to etimes= makes it fail" {
    # Real macOS defect: ps -o etimes= is a Linux/procps extension, confirmed
    # absent from the BSD/Darwin ps keyword table -- only etime (singular,
    # [[DD-]hh:]mm:ss) is common to both. On a host where etimes= silently
    # produces nothing, the old code's guard just never engaged (no error,
    # the pid-reuse check always skipped). The stub answers ONLY for an exact
    # `etime=` argument -- NOT for `etimes=`, which is a different string
    # despite the substring overlap -- so this exercises the hook's own
    # embedded awk parser rather than reimplementing it, and would fail on
    # THIS Linux CI leg too if the script reverted to etimes= (the stub would
    # stop intercepting, the real host ps would answer with actual seconds
    # instead of the synthetic 93615, the comparison would miss, and the
    # marker would wrongly clear).
    : > "$REPO/.ccage-session-done"
    local stub_bin; stub_bin="$(ps_stub_for "$$")"

    local wstart=$(( $(date +%s) - PS_STUB_ELAPSED ))
    printf 'pid=%d\nstart=%d\n' "$$" "$wstart" > "$REPO/.ccage-autock.pid.$$"

    PATH="$stub_bin:$PATH" run run_hook_src startup
    [ "$status" -eq 0 ]
    [ -e "$REPO/.ccage-session-done" ]   # start times agree -> "watcher elsewhere" -> preserved
}

# ---- the +/-2s pid-reuse tolerance itself (W5 gap 2) ------------------------
#
# Mutation-measured at fddf504: widening the tolerance from 2s to 100000s (~28h,
# which makes the check meaningless) left the whole suite green. The only test
# touching this path recorded start=1 -- about 1.7 BILLION seconds out, so far
# adrift that a sane window and a useless one both reject it. The guard's actual
# constant was therefore free to drift, and the failure it protects against is
# the one it was written for: a LIVE watcher's .ccage-session-done /
# .ccage-autock.conf deleted under it, originally seen as "--set silently
# reverted". These two pin the constant from both sides.

@test "pid-reuse tolerance: a 60s start-time mismatch is an impostor (kills a widened tolerance)" {
    # Recorded start is 60s EARLIER than the running process actually started:
    # a plausible pid-reuse gap, not an absurd one. 60 is comfortably outside
    # the real 2s window (so this passes today, +/-1s of clock slack included)
    # and comfortably INSIDE any widened one, so any tolerance of 60s or more
    # -- 100000s included -- fails here instead of shipping silently.
    : > "$REPO/.ccage-session-done"
    : > "$REPO/.ccage-autock.conf"
    local stub_bin; stub_bin="$(ps_stub_for "$$")"

    local wstart=$(( $(date +%s) - PS_STUB_ELAPSED - 60 ))
    printf 'pid=%d\nstart=%d\n' "$$" "$wstart" > "$REPO/.ccage-autock.pid.$$"

    PATH="$stub_bin:$PATH" run run_hook_src startup
    [ "$status" -eq 0 ]
    [ ! -e "$REPO/.ccage-session-done" ]   # impostor -> not a live watcher -> cleared
    [ ! -e "$REPO/.ccage-autock.conf" ]
}

@test "pid-reuse tolerance: a 2s start-time mismatch is still the same watcher (kills a narrowed tolerance)" {
    # The boundary case, from the permissive side. Recorded start is 2s LATER
    # than the running process started, so the hook computes a difference of
    # exactly 2 -- or 1 if the two `date +%s` calls straddle a second. Both are
    # within the real window, so correct code ALWAYS preserves here and this
    # can never flake red; a tolerance narrowed to 1s or 0s clears instead and
    # fails. That matters because over-tightening reintroduces the same
    # symptom from the other direction: a live watcher's state deleted.
    : > "$REPO/.ccage-session-done"
    : > "$REPO/.ccage-autock.conf"
    local stub_bin; stub_bin="$(ps_stub_for "$$")"

    local wstart=$(( $(date +%s) - PS_STUB_ELAPSED + 2 ))
    printf 'pid=%d\nstart=%d\n' "$$" "$wstart" > "$REPO/.ccage-autock.pid.$$"

    PATH="$stub_bin:$PATH" run run_hook_src startup
    [ "$status" -eq 0 ]
    [ -e "$REPO/.ccage-session-done" ]   # within tolerance -> live watcher -> preserved
    [ -e "$REPO/.ccage-autock.conf" ]
}

# ---- plan readiness (register issue 4) -------------------------------------
# The autoloader already emits a plan-doc DIRECTIVE. These cover the half added
# 2026-08-11: OPEN ITEM COUNTS as checkable facts. The load-bearing case is the
# last one — a plan with no checkboxes must report UNVERIFIABLE, because a false
# "0 open" would license exactly the silent item-dropping this exists to stop.

# Write a RESUME whose ### Plan section points at $REPO/$1, then create $1.
plan_with() {   # plan_with <filename> <contents>
    printf '# RESUME\n\n### Plan\n- %s/%s\n' "$REPO" "$1" > "$REPO/RESUME.md"
    printf '%s' "$2" > "$REPO/$1"
}

@test "plan readiness: counts open items against the total" {
    plan_with p.md '# P
- [x] shipped, in `lib/a.py`
- [ ] pending, in `lib/b.py`
'
    run run_hook
    [[ "$output" == *"PLAN STATE"* ]]
    [[ "$output" == *"p.md: 1 of 2 items OPEN"* ]]
}

@test "plan readiness: flags open items that name no file" {
    plan_with p.md '# P
- [ ] tidy things up
- [ ] make it better
- [ ] fix `lib/c.py`
'
    run run_hook
    [[ "$output" == *"3 of 3 items OPEN"* ]]
    [[ "$output" == *"2 name no file"* ]]
}

@test "plan readiness: says nothing about write sets when every item names one" {
    plan_with p.md '# P
- [ ] fix `lib/c.py`
- [ ] update docs/readme.md
'
    run run_hook
    [[ "$output" == *"2 of 2 items OPEN"* ]]
    [[ "$output" != *"name no file"* ]]
}

@test "plan readiness: a fully ticked plan reports zero open" {
    plan_with p.md '# P
- [x] one, `a.py`
- [x] two, `b.py`
'
    run run_hook
    [[ "$output" == *"0 of 2 items OPEN"* ]]
}

@test "plan readiness: a plan with NO checkboxes is UNVERIFIABLE, never a false pass" {
    plan_with p.md '# P

Prose only. Several things remain to be done, described in sentences.
'
    run run_hook
    [[ "$output" == *"UNVERIFIABLE"* ]]
    [[ "$output" != *"items OPEN"* ]]
}

# REWRITTEN 2026-08-11. This test used to assert the OPPOSITE — that a RESUME
# with no ### Plan section produced no PLAN STATE line at all — and it passed,
# green, for a day. It was written by the same reasoning that wrote the code, so
# it encoded the code's blind spot as the specification.
#
# The cost was real: a fresh session in another project was asked for a status
# report, said nothing about plan completeness, and read as "nothing to report"
# rather than "I cannot verify this". Silence and a clean bill of health are
# indistinguishable to a reader, which is the precise failure the sibling test
# ("a plan with NO checkboxes is UNVERIFIABLE, never a false pass") exists to
# prevent one level down. An absent answer must look absent.
@test "plan readiness: NO ### Plan section reports UNVERIFIABLE, never silence" {
    printf '# RESUME\n\n### Next\n1. do a thing\n' > "$REPO/RESUME.md"
    run run_hook
    [[ "$output" == *"PLAN STATE"* ]]
    [[ "$output" == *"UNVERIFIABLE"* ]]
    # It must not be readable as "checked, nothing open".
    [[ "$output" == *"NOT"* ]]
}

@test "plan readiness: no RESUME.md at all stays silent" {
    rm -f "$REPO/RESUME.md"
    run run_hook
    [[ "$output" != *"PLAN STATE"* ]]
}

# ---- watcher reap wiring (added 2026-08-11) --------------------------------
# ccage-watch writes to RESUME only when its condition fires or its TTL expires;
# killed any other way it writes nothing, so a death used to be indistinguishable
# from never having armed one. These pin the WIRING — that reap is called, that
# its output lands ahead of the RESUME body it annotates, that silence stays
# silent, and that a machine without ccage-watch is unaffected. What reap decides
# is ccage-watch's own suite's job, so the command is stubbed here.

# Run the hook with a controlled PATH and HOME (the hook falls back to
# ~/.local/bin/ccage-watch when the command is not on PATH).
run_hook_env() { ( cd "$REPO" && PATH="$1" HOME="$2" "$HOOK" ); }

stub_bin() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/ccage-watch"
    chmod +x "$BATS_TEST_TMPDIR/bin/ccage-watch"
    printf '%s/bin:%s' "$BATS_TEST_TMPDIR" "$PATH"
}

@test "a watcher that died is reported, ahead of the RESUME body it annotates" {
    local p
    p=$(stub_bin <<'EOF'
#!/bin/sh
[ "$1" = "reap" ] || exit 0
echo "WATCHERS (ccage-watch, survives sessions):"
echo "  - DIED deadbeef00: waiting on the overnight job — never reported"
EOF
)
    printf '# Resume\n\nthe resume body\n' > "$REPO/RESUME.md"
    run run_hook_env "$p" "$HOME"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIED deadbeef00"* ]]
    # Order is the point: the death must be in context before the state it corrects.
    [[ "${output%%the resume body*}" == *"DIED deadbeef00"* ]]
}

@test "no watcher armed: reap contributes nothing to session start" {
    local p
    p=$(stub_bin <<'EOF'
#!/bin/sh
exit 0
EOF
)
    printf 'the resume body\n' > "$REPO/RESUME.md"
    run run_hook_env "$p" "$HOME"
    [ "$status" -eq 0 ]
    [[ "$output" == *"the resume body"* ]]
    # Not "no output" — this RESUME has no ### Plan section, so the plan-state
    # block speaks. The claim is narrower: the watcher path adds nothing.
    [[ "$output" != *"WATCHERS"* ]]
    [[ "$output" != *"DIED"* ]]
}

@test "ccage-watch not installed at all: session start is unaffected" {
    mkdir -p "$BATS_TEST_TMPDIR/empty" "$BATS_TEST_TMPDIR/nohome"
    printf 'the resume body\n' > "$REPO/RESUME.md"
    run run_hook_env "$BATS_TEST_TMPDIR/empty:/usr/bin:/bin" "$BATS_TEST_TMPDIR/nohome"
    [ "$status" -eq 0 ]
    [[ "$output" == *"the resume body"* ]]
    [[ "$output" != *"WATCHERS"* ]]
}
