#!/usr/bin/env bats
# Tests for `ccage doctor` — Phase 7 (component F). Runs the real bin/ccage
# dispatcher against a SANDBOX CCAGE_ROOT (never the user's real ~/.claude-*),
# so no running session is affected.
bats_require_minimum_version 1.5.0

setup() {
    command -v jq >/dev/null 2>&1 || skip "jq required"
    command -v python3 >/dev/null 2>&1 || skip "python3 required"
    CCAGE="$BATS_TEST_DIRNAME/../bin/ccage"
    ROOT="$BATS_TEST_TMPDIR/root"
    HOOKS="$BATS_TEST_TMPDIR/hooks"
    mkdir -p "$ROOT"
    AUTOLOAD_CMD="bash $HOOKS/resume_autoload.sh"
    BUDGET_CMD="bash $HOOKS/resume_budget_check.sh"
    unset CCAGE_RESUME_BUDGET_LINES CCAGE_MEMORY_ORPHAN_MAX
    export CCAGE_ROOT="$ROOT" CCAGE_PREFIX=.claude- CCAGE_HOOKS_DIR="$HOOKS"
}

# mkcage <name> <owner-path>  → echoes the cage dir, stamps .owning_path.
mkcage() {
    local dir="$ROOT/.claude-$1"
    mkdir -p "$dir"
    printf '%s\n' "$2" > "$dir/.owning_path"
    printf '%s\n' "$dir"
}

# has_cmd <settings.json> <event> <command>
has_cmd() {
    jq -e --arg ev "$2" --arg c "$3" \
        '[ .hooks[$ev][]?.hooks[]?.command ] | any(. == $c)' "$1" >/dev/null 2>&1
}

@test "doctor seeds a cage that has no settings.json" {
    local cage; cage=$(mkcage proj1 "$BATS_TEST_TMPDIR/repo1")
    run "$CCAGE" doctor
    [ "$status" -eq 0 ]
    has_cmd "$cage/settings.json" SessionStart "$AUTOLOAD_CMD"
    has_cmd "$cage/settings.json" PostToolUse  "$BUDGET_CMD"
    [[ "$output" == *"seeded hooks"* ]]
}

@test "doctor preserves existing settings keys when backfilling" {
    local cage; cage=$(mkcage proj2 "$BATS_TEST_TMPDIR/repo2")
    printf '{"statusLine":{"type":"command","command":"x"},"effortLevel":"high"}\n' > "$cage/settings.json"
    run "$CCAGE" doctor
    [ "$status" -eq 0 ]
    [ "$(jq -r '.statusLine.command' "$cage/settings.json")" = "x" ]
    [ "$(jq -r '.effortLevel' "$cage/settings.json")" = "high" ]
    has_cmd "$cage/settings.json" SessionStart "$AUTOLOAD_CMD"
}

@test "doctor is idempotent: a second run seeds nothing new" {
    mkcage proj3 "$BATS_TEST_TMPDIR/repo3" >/dev/null
    "$CCAGE" doctor >/dev/null
    run "$CCAGE" doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 cage(s) seeded"* ]]
}

@test "doctor --dry-run reports but writes nothing" {
    local cage; cage=$(mkcage proj4 "$BATS_TEST_TMPDIR/repo4")
    run "$CCAGE" doctor --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would seed"* ]]
    [ ! -f "$cage/settings.json" ]
}

@test "doctor skips directories without an .owning_path" {
    mkdir -p "$ROOT/.claude-notacage"
    run "$CCAGE" doctor
    [ "$status" -eq 0 ]
    [ ! -f "$ROOT/.claude-notacage/settings.json" ]
    [[ "$output" == *"scanned 0 cage"* ]]
}

@test "doctor lists a repo with a bloated RESUME" {
    local repo="$BATS_TEST_TMPDIR/repo6"; mkdir -p "$repo"
    seq 1 300 > "$repo/RESUME.md"
    mkcage proj6 "$repo" >/dev/null
    run "$CCAGE" doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"bloated RESUME"* ]]
    [[ "$output" == *"$repo"* ]]
}

@test "doctor lists a cage with messy memory (dead index link)" {
    local repo="$BATS_TEST_TMPDIR/repo7"; mkdir -p "$repo"
    local cage; cage=$(mkcage proj7 "$repo")
    local md="$cage/projects/${repo//\//-}/memory"
    mkdir -p "$md"
    printf -- '- [Gone](missing.md) — note\n' > "$md/MEMORY.md"
    run "$CCAGE" doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"--tidy"* ]]
    [[ "$output" == *"$repo"* ]]
}

@test "doctor reports (none) when nothing needs attention" {
    local repo="$BATS_TEST_TMPDIR/repo8"; mkdir -p "$repo"
    printf 'lean resume\n' > "$repo/RESUME.md"
    mkcage proj8 "$repo" >/dev/null
    run "$CCAGE" doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"(none)"* ]]
}

@test "doctor --help prints usage" {
    run "$CCAGE" doctor --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: ccage doctor"* ]]
}

# ---- slot-aware RESUME glob (F2) -------------------------------------------
# A bloated slot RESUME (RESUME.<slot>.md) must be flagged even when the plain
# RESUME.md is lean. Pre-fix the scan only looked at RESUME.md and missed it.
@test "doctor lists a bloated slot-aware RESUME file" {
    local repo="$BATS_TEST_TMPDIR/repo9"; mkdir -p "$repo"
    printf 'lean\n'  > "$repo/RESUME.md"          # plain file is fine
    seq 1 300        > "$repo/RESUME.review.md"   # slotted file is bloated
    mkcage proj9 "$repo" >/dev/null
    run "$CCAGE" doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"bloated RESUME"* ]]
    [[ "$output" == *"RESUME.review.md"* ]]
}

# ---- per-project memory iteration (F3) ------------------------------------
# An empty .owning_path used to build "projects//memory" and skip the scan
# entirely; now every projects/*/memory dir is swept regardless of the marker.
@test "doctor scans memory even when .owning_path is empty" {
    local cage="$ROOT/.claude-proj10"; mkdir -p "$cage"
    : > "$cage/.owning_path"                       # present but empty
    local md="$cage/projects/-some-proj/memory"; mkdir -p "$md"
    printf -- '- [Gone](missing.md) — note\n' > "$md/MEMORY.md"
    run "$CCAGE" doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"$md"* ]]
}

# A multi-project cage: the project that does NOT match the owner slug must
# still be swept. Pre-fix only the single owner-derived slug was checked.
@test "doctor scans every project memory dir in a multi-project cage" {
    local repo="$BATS_TEST_TMPDIR/repo11"; mkdir -p "$repo"
    local cage; cage=$(mkcage proj11 "$repo")
    # project A == owner, tidy (grouped index, indexed file present)
    local mdA="$cage/projects/${repo//\//-}/memory"; mkdir -p "$mdA"
    printf '## Grouped\n- [ok](ok.md)\n' > "$mdA/MEMORY.md"
    printf 'x\n' > "$mdA/ok.md"
    # project B != owner, messy (dead index link)
    local mdB="$cage/projects/-other-proj/memory"; mkdir -p "$mdB"
    printf -- '- [Gone](missing.md) — note\n' > "$mdB/MEMORY.md"
    run "$CCAGE" doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"$mdB"* ]]
}

# ---- backfill safety: preserve unrelated hooks, honor sub-opt-outs, dedup ----
# The doctor merge is a second copy of the wrapper's; it must append, not clobber.
@test "doctor preserves a pre-existing unrelated hooks entry" {
    local cage; cage=$(mkcage proj12 "$BATS_TEST_TMPDIR/repo12")
    printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"echo hi"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo pre"}]}]}}' > "$cage/settings.json"
    run "$CCAGE" doctor
    [ "$status" -eq 0 ]
    has_cmd "$cage/settings.json" SessionStart "echo hi"
    has_cmd "$cage/settings.json" PreToolUse  "echo pre"
    has_cmd "$cage/settings.json" SessionStart "$AUTOLOAD_CMD"
    [ "$(jq '[.hooks.SessionStart[]?.hooks[]?.command] | length' "$cage/settings.json")" -eq 2 ]
}

@test "doctor honors CCAGE_NO_AUTOLOAD (backfills only the budget hook)" {
    local cage; cage=$(mkcage proj13 "$BATS_TEST_TMPDIR/repo13")
    CCAGE_NO_AUTOLOAD=1 run "$CCAGE" doctor
    [ "$status" -eq 0 ]
    ! has_cmd "$cage/settings.json" SessionStart "$AUTOLOAD_CMD"
    has_cmd "$cage/settings.json" PostToolUse "$BUDGET_CMD"
}

# Adversarial regression: a differing CCAGE_HOOKS_DIR must not append a second
# entry (dedup is on the script basename, not the full command path).
@test "doctor is idempotent across a differing CCAGE_HOOKS_DIR" {
    local cage; cage=$(mkcage proj14 "$BATS_TEST_TMPDIR/repo14")
    "$CCAGE" doctor >/dev/null
    CCAGE_HOOKS_DIR="/somewhere/else/hooks" "$CCAGE" doctor >/dev/null
    [ "$(jq '[.hooks.SessionStart[]?.hooks[]?.command] | length' "$cage/settings.json")" -eq 1 ]
}

# ---- --unseed: the inverse of the backfill (used by uninstall.sh) --------

@test "doctor --unseed removes exactly ccage's two hook entries, preserves other keys" {
    local cage; cage=$(mkcage proj15 "$BATS_TEST_TMPDIR/repo15")
    "$CCAGE" doctor >/dev/null   # seed first
    # A pre-existing statusLine key and a foreign SessionStart hook must survive.
    python3 - "$cage/settings.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f:
    data = json.load(f)
data["statusLine"] = {"type": "command", "command": "my-statusline"}
data["hooks"].setdefault("SessionStart", []).append(
    {"matcher": "startup", "hooks": [{"type": "command", "command": "echo foreign"}]}
)
with open(p, "w") as f:
    json.dump(data, f, indent=2)
PY
    run "$CCAGE" doctor --unseed
    [ "$status" -eq 0 ]
    [[ "$output" == *"unseeded hooks"* ]]
    ! has_cmd "$cage/settings.json" SessionStart "$AUTOLOAD_CMD"
    ! has_cmd "$cage/settings.json" PostToolUse  "$BUDGET_CMD"
    has_cmd "$cage/settings.json" SessionStart "echo foreign"
    [ "$(jq -r '.statusLine.command' "$cage/settings.json")" = "my-statusline" ]
}

@test "doctor --unseed --dry-run changes nothing on disk" {
    local cage; cage=$(mkcage proj16 "$BATS_TEST_TMPDIR/repo16")
    "$CCAGE" doctor >/dev/null   # seed first
    local before; before=$(cat "$cage/settings.json")
    run "$CCAGE" doctor --unseed --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would have the session-docs hooks block removed"* ]]
    has_cmd "$cage/settings.json" SessionStart "$AUTOLOAD_CMD"
    [ "$(cat "$cage/settings.json")" = "$before" ]
}

@test "doctor --unseed leaves an unparseable settings.json untouched and reports it unchanged" {
    local cage; cage=$(mkcage proj17 "$BATS_TEST_TMPDIR/repo17")
    printf '{not valid json' > "$cage/settings.json"
    local before; before=$(cat "$cage/settings.json")
    run "$CCAGE" doctor --unseed
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 cage(s) had the session-docs hooks block removed."* ]]
    [ "$(cat "$cage/settings.json")" = "$before" ]
}

@test "doctor --unseed on a cage with no hooks block reports 0 changed" {
    local cage; cage=$(mkcage proj18 "$BATS_TEST_TMPDIR/repo18")
    printf '{"statusLine":{"type":"command","command":"x"}}\n' > "$cage/settings.json"
    run "$CCAGE" doctor --unseed
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 cage(s) had the session-docs hooks block removed."* ]]
    [ "$(jq -r '.statusLine.command' "$cage/settings.json")" = "x" ]
}
