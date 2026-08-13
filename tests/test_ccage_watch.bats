#!/usr/bin/env bats
# Behavioural tests for bin/ccage-watch — the session-bridging condition watcher.
#
# The one property that matters is that an armed watcher OUTLIVES the process
# that armed it: the whole tool exists because an in-harness background watcher
# is killed 50-131 s after the session's last turn (measured, see the design
# doc). Every test therefore arms through a child shell that exits immediately,
# so "still running" always means "survived its parent".
#
# Kept fast deliberately: intervals of 1 s and TTLs of 1-2 s, with bounded waits
# rather than fixed sleeps, so the file adds ~10 s to the suite rather than
# minutes. This suite is also the reason a full-suite run is worth keeping cheap.
bats_require_minimum_version 1.5.0

setup() {
    command -v python3 >/dev/null 2>&1 || skip "python3 required"
    WATCH="$BATS_TEST_DIRNAME/../bin/ccage-watch"
    # HERMETIC: the watcher stores specs under CLAUDE_CONFIG_DIR and appends to
    # RESUME.md in the cwd. Both are redirected into the per-test tmpdir so the
    # suite can never touch the developer's real cage or a real RESUME.
    export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cage"
    PROJ="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$CLAUDE_CONFIG_DIR" "$PROJ"
    cd "$PROJ" || return 1
}

teardown() {
    python3 "$WATCH" disarm --all >/dev/null 2>&1 || true
}

# Poll for $2 seconds until file $1 contains $3. Bounded, so a hang fails fast.
wait_for() {
    local file="$1" secs="$2" needle="$3" i=0
    while [ "$i" -lt "$((secs * 5))" ]; do
        [ -f "$file" ] && grep -qF "$needle" "$file" && return 0
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

specs() { ls "$CLAUDE_CONFIG_DIR"/watch/*.json 2>/dev/null | wc -l | tr -d ' '; }

@test "arm writes a spec and reports the id" {
    run python3 "$WATCH" arm --cond "false" --interval 1 --ttl 30
    [ "$status" -eq 0 ]
    [[ "$output" == *"armed "* ]]
    [ "$(specs)" -eq 1 ]
}

@test "the watcher outlives the process that armed it" {
    # bash -c is a separate process; it exits before the assertion runs.
    bash -c "python3 '$WATCH' arm --cond false --interval 1 --ttl 30" >/dev/null
    local pid
    pid=$(python3 -c "import json,glob;print(json.load(open(glob.glob('$CLAUDE_CONFIG_DIR/watch/*.json')[0]))['pid'])")
    [ -n "$pid" ]
    kill -0 "$pid" 2>/dev/null
}

@test "re-arming the same condition is refused, and --replace overrides" {
    python3 "$WATCH" arm --cond "false" --interval 1 --ttl 30 >/dev/null
    run python3 "$WATCH" arm --cond "false" --interval 1 --ttl 30
    [ "$status" -eq 0 ]
    [[ "$output" == *"already armed"* ]]
    [ "$(specs)" -eq 1 ]

    run python3 "$WATCH" arm --cond "false" --interval 1 --ttl 30 --replace
    [ "$status" -eq 0 ]
    [[ "$output" == *"armed "* ]]
    [ "$(specs)" -eq 1 ]
}

@test "a different condition arms a second, independent watcher" {
    python3 "$WATCH" arm --cond "false" --interval 1 --ttl 30 >/dev/null
    python3 "$WATCH" arm --cond "test -f nope" --interval 1 --ttl 30 >/dev/null
    [ "$(specs)" -eq 2 ]
}

@test "list shows armed watchers and disarm --all removes them" {
    python3 "$WATCH" arm --cond "false" --interval 1 --ttl 30 >/dev/null
    run python3 "$WATCH" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"condition"* ]]

    run python3 "$WATCH" disarm --all
    [ "$status" -eq 0 ]
    [ "$(specs)" -eq 0 ]
}

@test "list is quiet and successful when nothing is armed" {
    run python3 "$WATCH" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"no watchers armed"* ]]
}

@test "firing appends a marked block to RESUME.md and cleans up the spec" {
    python3 "$WATCH" arm --cond "test -f done.txt" --note "the long job" \
        --interval 1 --ttl 30 >/dev/null
    touch done.txt
    wait_for RESUME.md 20 "WATCH FIRED"
    grep -qF "ccage-watch:begin" RESUME.md
    grep -qF "ccage-watch:end" RESUME.md
    grep -qF "the long job" RESUME.md
    [ "$(specs)" -eq 0 ]
}

@test "RESUME.md is created when the project has none" {
    [ ! -f RESUME.md ]
    python3 "$WATCH" arm --cond "true" --interval 1 --ttl 30 >/dev/null
    wait_for RESUME.md 20 "WATCH FIRED"
    grep -qF "Watch results" RESUME.md
}

@test "appending never rewrites existing RESUME content" {
    printf '# RESUME\n\n### Next\n1. a pre-existing item\n' > RESUME.md
    local before
    before=$(cat RESUME.md)
    python3 "$WATCH" arm --cond "true" --interval 1 --ttl 30 >/dev/null
    wait_for RESUME.md 20 "WATCH FIRED"
    # every original byte still present, in order, at the head of the file
    [[ "$(cat RESUME.md)" == "$before"* ]]
}

@test "the section header is not duplicated on a second append" {
    python3 "$WATCH" arm --cond "true" --interval 1 --ttl 30 >/dev/null
    wait_for RESUME.md 20 "WATCH FIRED"
    python3 "$WATCH" arm --cond "test 1 -eq 1" --interval 1 --ttl 30 >/dev/null
    wait_for RESUME.md 20 "test 1 -eq 1"
    [ "$(grep -cF 'Watch results' RESUME.md)" -eq 1 ]
}

@test "TTL expiry is recorded, and worded so it cannot read as success" {
    python3 "$WATCH" arm --cond "false" --note "a job that never ends" \
        --interval 1 --ttl 1 >/dev/null
    wait_for RESUME.md 20 "WATCH EXPIRED"
    grep -qF "UNKNOWN, not as success" RESUME.md
    [ "$(specs)" -eq 0 ]
}

@test "durations accept suffixes and reject nonsense" {
    run python3 "$WATCH" arm --cond "false" --interval 1 --ttl 2h
    [ "$status" -eq 0 ]
    python3 "$WATCH" disarm --all >/dev/null

    run python3 "$WATCH" arm --cond "false" --ttl "next tuesday"
    [ "$status" -ne 0 ]
}

@test "disarm requires an id or --all" {
    run python3 "$WATCH" disarm
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# The five tests below cover the UNCONFIGURED default path — the one every test
# above configures away. All three defects they pin were found on 2026-08-11 by
# running the shipped tool with nothing set up, not by any test.
# ---------------------------------------------------------------------------

@test "a watcher killed without reporting is reaped into RESUME, not silent" {
    python3 "$WATCH" arm --cond "false" --note "the long job" \
        --interval 1 --ttl 600 >/dev/null
    local pid
    pid=$(python3 -c "import json,glob;print(json.load(open(glob.glob('$CLAUDE_CONFIG_DIR/watch/*.json')[0]))['pid'])")
    kill -9 "$pid"
    local i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 40 ]; do sleep 0.2; i=$((i + 1)); done

    run python3 "$WATCH" reap
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIED"* ]]
    grep -qF "WATCH DIED" RESUME.md
    grep -qF "not as success" RESUME.md      # a death must never read as done
    grep -qF "the long job" RESUME.md        # what it was bridging is named
    [ "$(specs)" -eq 0 ]
}

@test "a failed RESUME write keeps the spec, so reap still reports it" {
    # RESUME.md unwritable: the append fails. The spec is the only trace of the
    # watcher, so deleting it here would leave nothing for any future session.
    printf '# RESUME\n' > RESUME.md
    chmod 0444 RESUME.md
    python3 "$WATCH" arm --cond "true" --interval 1 --ttl 30 >/dev/null
    local pid i=0
    pid=$(python3 -c "import json,glob;print(json.load(open(glob.glob('$CLAUDE_CONFIG_DIR/watch/*.json')[0]))['pid'])")
    # wait for the daemon to finish its (failing) write and exit
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
    [ "$(specs)" -eq 1 ]                      # evidence kept, not swallowed
    chmod 0644 RESUME.md
    run python3 "$WATCH" reap
    [[ "$output" == *"DIED"* ]]
    grep -qF "WATCH DIED" RESUME.md
}

@test "reap is silent when no watcher is armed" {
    run python3 "$WATCH" reap
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f RESUME.md ]
}

@test "read-only commands never create a config dir" {
    export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/absent-cage"
    run python3 "$WATCH" list
    [ "$status" -eq 0 ]
    run python3 "$WATCH" reap
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/absent-cage" ]
}

@test "armed from a subdirectory, the outcome lands at the project root" {
    git init -q . 2>/dev/null || skip "git required"
    printf '# RESUME\n' > RESUME.md
    mkdir -p deep/nested
    cd deep/nested || return 1
    run python3 "$WATCH" arm --cond "true" --interval 1 --ttl 30
    [ "$status" -eq 0 ]
    [[ "$output" == *"$PROJ/RESUME.md"* ]]     # the target is named at arm time
    wait_for "$PROJ/RESUME.md" 20 "WATCH FIRED"
    [ ! -f RESUME.md ]                         # no stray file in the subdirectory
}

@test "a slotted cage is reported into the RESUME file it actually reads" {
    CCAGE_SLOT=b python3 "$WATCH" arm --cond "true" --interval 1 --ttl 30 >/dev/null
    wait_for RESUME.b.md 20 "WATCH FIRED"
    [ ! -f RESUME.md ]
}

@test "selftest passes" {
    run python3 "$WATCH" selftest
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
    [[ "$output" != *"FAIL"* ]]
}
