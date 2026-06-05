#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031
# SC2030/2031: every test subshell intentionally gets a clean PATH/HOME;
# the "modification is local" / "might be lost" warnings are by design.
#
# tests/validate-e2e.sh — end-to-end validation of ccage behavior.
#
# Stubs `claude` with a mock binary so the wrapper can run its full code path
# (config-dir computation, env exports, bootstrap, sharing) without touching
# any real config dir or making API calls. All state lives in $TMP and a fake
# $HOME under $TMP — the user's real ~/.claude* dirs are never read or written.
#
# Run from repo root:  ./tests/validate-e2e.sh
#                      ./tests/validate-e2e.sh --with-real-claude
#
# Without --with-real-claude: 30 mock-stub assertions, no API spend, fully
# offline. Suitable for CI and pre-push checks.
#
# With --with-real-claude: ALSO runs 4 scenarios that invoke the real `claude`
# binary against ccage-bootstrapped config dirs. Costs a few cents in API
# spend. Verifies that claude itself accepts what ccage produces. Requires
# either ANTHROPIC_API_KEY in env, or an existing .credentials.json that the
# script can symlink. Real HOME and PATH are preserved; ccage dirs are
# redirected via CCAGE_ROOT into $TMP so nothing lands in the user's $HOME.
#
# Exit code = number of failed assertions.

# Note: deliberately not `set -u` — the wrapper reads optional env vars
# without `${var:-}` defaults (a separate finding, see RESUME.md). We don't
# want to mask non-strictness bugs here, so the test runs in lenient mode.
set -eo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$REPO/share/claude-isolation.sh"
[ -f "$WRAPPER" ] || { echo "wrapper not found at $WRAPPER" >&2; exit 2; }

TMP=$(mktemp -d -t ccage-validate-XXXXXX)
FAKE_HOME="$TMP/home"
MOCK_BIN="$TMP/bin"
mkdir -p "$FAKE_HOME" "$MOCK_BIN"

# shellcheck disable=SC2329  # invoked via trap
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- mock claude: records env + args, exits 0. ---
cat > "$MOCK_BIN/claude" <<'MOCK'
#!/usr/bin/env bash
{
  echo "MOCK_INVOKED"
  echo "PWD=$PWD"
  echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR-unset}"
  echo "CLAUDE_CODE_ATTRIBUTION_HEADER=${CLAUDE_CODE_ATTRIBUTION_HEADER-unset}"
  echo "DISABLE_AUTOUPDATER=${DISABLE_AUTOUPDATER-unset}"
  echo "ARGS=$*"
} >> "${MOCK_LOG:?MOCK_LOG must be set}"
MOCK
chmod +x "$MOCK_BIN/claude"

PASS=0; FAIL=0
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  \e[32m✓\e[0m %s\n' "$name"; PASS=$((PASS+1))
  else
    printf '  \e[31m✗\e[0m %s\n' "$name"; FAIL=$((FAIL+1))
  fi
}

run_in_proj() {
  # run_in_proj <pwd> <log> [extra env exports...] -- runs `claude --version`
  # in a subshell with fake HOME and mock PATH. Each call is an isolated subshell;
  # nothing leaks back into the parent.
  local pwd_arg="$1" log="$2"; shift 2
  (
    # Strip any ccage-related env inherited from the parent (this validation
    # script may itself be running inside a ccage'd shell). We want each test
    # subshell to start clean so assertions about "var unset" mean what they say.
    unset CLAUDE_CONFIG_DIR CLAUDE_CODE_ATTRIBUTION_HEADER DISABLE_AUTOUPDATER
    unset CCAGE_DISABLE CCAGE_KEEP_ATTRIBUTION CCAGE_KEEP_AUTOUPDATER
    unset CCAGE_SHARE_FROM CCAGE_SHARE_DIRS CCAGE_SLOT
    unset CCAGE_NO_ONBOARDING_PATCH CCAGE_NO_AUTO_SIGNORE
    unset CCAGE_SESSION_DOCS CCAGE_NO_AUTOLOAD CCAGE_NO_BUDGET_HOOK CCAGE_HOOKS_DIR
    cd "$pwd_arg"
    # shellcheck disable=SC2030  # subshell-local by design
    HOME=$FAKE_HOME
    PATH="$MOCK_BIN:$PATH"
    MOCK_LOG="$log"
    export HOME PATH MOCK_LOG
    local kv; for kv in "$@"; do export "${kv?}"; done
    # shellcheck disable=SC1090
    source "$WRAPPER"
    claude --version
  )
}

# ===== 1. Parallel sessions get distinct, non-colliding config dirs =====
echo "[1] parallel sessions land in distinct config dirs"
mkdir -p "$TMP/projA" "$TMP/projB"
run_in_proj "$TMP/projA" "$TMP/log-a"
run_in_proj "$TMP/projB" "$TMP/log-b"

DIR_A=$(grep '^CLAUDE_CONFIG_DIR=' "$TMP/log-a" | cut -d= -f2-)
DIR_B=$(grep '^CLAUDE_CONFIG_DIR=' "$TMP/log-b" | cut -d= -f2-)

check "projA got a config dir"           test -n "$DIR_A"
check "projB got a config dir"           test -n "$DIR_B"
check "config dirs differ"               test "$DIR_A" != "$DIR_B"
check "projA dir was created"            test -d "$DIR_A"
check "projB dir was created"            test -d "$DIR_B"
check "projA owning_path written"        grep -qx "$TMP/projA" "$DIR_A/.owning_path"
check "projB owning_path written"        grep -qx "$TMP/projB" "$DIR_B/.owning_path"
check "dirs live under fake HOME (A)"    test "${DIR_A#"$FAKE_HOME"/}" != "$DIR_A"
check "dirs live under fake HOME (B)"    test "${DIR_B#"$FAKE_HOME"/}" != "$DIR_B"

# ===== 2. Env defaults exported before exec =====
echo "[2] default env vars exported"
check "CLAUDE_CODE_ATTRIBUTION_HEADER=0" grep -qx "CLAUDE_CODE_ATTRIBUTION_HEADER=0" "$TMP/log-a"
check "DISABLE_AUTOUPDATER=1"            grep -qx "DISABLE_AUTOUPDATER=1" "$TMP/log-a"

# ===== 3. Onboarding gate patched =====
echo "[3] onboarding patch applied to fresh config dir"
check ".claude.json created"             test -f "$DIR_A/.claude.json"
check "hasCompletedOnboarding=true"      grep -q '"hasCompletedOnboarding"' "$DIR_A/.claude.json"

# ===== 4. Skills sharing via CCAGE_SHARE_FROM =====
echo "[4] skills/commands/agents symlinked from master"
MASTER="$FAKE_HOME/.claude-master"
mkdir -p "$MASTER/skills/demo-skill" "$MASTER/commands" "$MASTER/agents"
echo "demo content" > "$MASTER/skills/demo-skill/SKILL.md"
mkdir -p "$TMP/projC"
run_in_proj "$TMP/projC" "$TMP/log-c" CCAGE_SHARE_FROM="$MASTER"
DIR_C=$(grep '^CLAUDE_CONFIG_DIR=' "$TMP/log-c" | cut -d= -f2-)

check "skills/ is a symlink"             test -L "$DIR_C/skills"
check "skills points to master"          test "$(readlink "$DIR_C/skills")" = "$MASTER/skills"
check "skill content visible via link"   test -f "$DIR_C/skills/demo-skill/SKILL.md"
check "commands/ symlinked"              test -L "$DIR_C/commands"
check "agents/ symlinked"                test -L "$DIR_C/agents"

# ===== 5. CCAGE_DISABLE pass-through =====
echo "[5] CCAGE_DISABLE bypasses the wrapper entirely"
mkdir -p "$TMP/projD"
run_in_proj "$TMP/projD" "$TMP/log-d" CCAGE_DISABLE=1

check "mock claude was still invoked"    grep -qx "MOCK_INVOKED" "$TMP/log-d"
check "no CONFIG_DIR exported"           grep -qx "CLAUDE_CONFIG_DIR=unset" "$TMP/log-d"
check "no ATTRIBUTION_HEADER exported"   grep -qx "CLAUDE_CODE_ATTRIBUTION_HEADER=unset" "$TMP/log-d"
check "no AUTOUPDATER exported"          grep -qx "DISABLE_AUTOUPDATER=unset" "$TMP/log-d"
check "no per-project dir created"       test ! -e "$FAKE_HOME/.claude-projD"

# ===== 6. Opt-outs =====
echo "[6] CCAGE_KEEP_* opt-outs respected"
mkdir -p "$TMP/projE"
run_in_proj "$TMP/projE" "$TMP/log-e" CCAGE_KEEP_ATTRIBUTION=1 CCAGE_KEEP_AUTOUPDATER=1
check "ATTRIBUTION_HEADER not set"       grep -qx "CLAUDE_CODE_ATTRIBUTION_HEADER=unset" "$TMP/log-e"
check "AUTOUPDATER not set"              grep -qx "DISABLE_AUTOUPDATER=unset" "$TMP/log-e"

# ===== 7. Re-invocation idempotency (same project, second call) =====
echo "[7] re-invoking in the same project is idempotent"
run_in_proj "$TMP/projA" "$TMP/log-a2"
DIR_A2=$(grep '^CLAUDE_CONFIG_DIR=' "$TMP/log-a2" | cut -d= -f2-)
check "second call resolves to same dir" test "$DIR_A" = "$DIR_A2"
check "owning_path unchanged"            grep -qx "$TMP/projA" "$DIR_A/.owning_path"

# ===== 8. Basename collision triggers hash suffix =====
echo "[8] basename collision: second claimant gets hashed dir"
mkdir -p "$TMP/sub1/shared" "$TMP/sub2/shared"   # both basenames = "shared"
run_in_proj "$TMP/sub1/shared" "$TMP/log-s1"
run_in_proj "$TMP/sub2/shared" "$TMP/log-s2"
DIR_S1=$(grep '^CLAUDE_CONFIG_DIR=' "$TMP/log-s1" | cut -d= -f2-)
DIR_S2=$(grep '^CLAUDE_CONFIG_DIR=' "$TMP/log-s2" | cut -d= -f2-)
check "first claimant got plain basename" test "$DIR_S1" = "$FAKE_HOME/.claude-shared"
check "second claimant got hash suffix"   test "$DIR_S1" != "$DIR_S2"
check "second claimant dir matches pattern" \
    bash -c "[[ '$DIR_S2' == '$FAKE_HOME/.claude-shared-'* ]]"

# ===== 9. ccage handoff against a fixture-shaped session dir =====
# Phase 6a. Verifies bin/ccage handoff produces a brief from a real
# ccage-bootstrapped config dir, no API calls, no claude invocation.
echo "[9] ccage handoff against a fixture-shaped session dir"
mkdir -p "$TMP/projF"
# Bootstrap the config dir via the wrapper (no flag injection needed).
run_in_proj "$TMP/projF" "$TMP/log-f"
DIR_F=$(grep '^CLAUDE_CONFIG_DIR=' "$TMP/log-f" | cut -d= -f2-)
# Compute the slug Claude Code would use for this PWD.
SLUG_F=$(printf '%s' "$TMP/projF" | sed 's|/|-|g')
SESS_F="$DIR_F/projects/$SLUG_F"
mkdir -p "$SESS_F"
cp "$REPO/tests/fixtures/sessions/minimal.jsonl" "$SESS_F/test-min-001.jsonl"
# Capture handoff brief to a file (check() can't see pipe output post-redirect).
CCAGE_HANDOFF_DIR="$TMP/handoff-out" CLAUDE_CONFIG_DIR="$DIR_F" \
    "$REPO/bin/ccage" handoff --project "$TMP/projF" --stdout > "$TMP/handoff-brief.md" 2>/dev/null || true
check "handoff produced a brief"                 test -s "$TMP/handoff-brief.md"
check "brief includes session ID"                grep -q "test-min-001" "$TMP/handoff-brief.md"
check "brief lists user prompts section"         grep -q "User prompts" "$TMP/handoff-brief.md"
check "brief lists files-touched section"        grep -q "Files touched" "$TMP/handoff-brief.md"
check "brief extracts /tmp/foo.py file"          grep -q "/tmp/foo.py" "$TMP/handoff-brief.md"
check "brief extracts last assistant turn"       grep -q "Here's a summary" "$TMP/handoff-brief.md"
check "brief has cost estimate"                  grep -q '~\$' "$TMP/handoff-brief.md"
check "no API call signal in brief generation"   bash -c "! grep -q 'api.anthropic.com\\|fetch\\|curl' '$TMP/handoff-brief.md'"

# ===== 10. resume cost interception gates (Phase 6b) =====
# Verifies the interceptor's non-interactive gates: CCAGE_DISABLE,
# CCAGE_NO_RESUME_PROMPT, and non-tty stdin all pass-through silently.
# Cannot exercise the actual prompt UI here (it reads from /dev/tty,
# which is unavailable in CI); the prompt is unit-tested in bats.
echo "[10] resume interception gates pass through silently"
mkdir -p "$TMP/projG"

# 10a: CCAGE_NO_RESUME_PROMPT=1 should pass through with -c, no prompt to stderr.
run_in_proj "$TMP/projG" "$TMP/log-g-noprompt" CCAGE_NO_RESUME_PROMPT=1
DIR_G=$(grep '^CLAUDE_CONFIG_DIR=' "$TMP/log-g-noprompt" | cut -d= -f2-)

# Drop a substantive fixture into the project's session dir so the cost
# estimator has something to chew on. Without this, the empty-session path
# trivially short-circuits and we wouldn't be testing the gate.
SLUG_G=$(printf '%s' "$TMP/projG" | sed 's|/|-|g')
mkdir -p "$DIR_G/projects/$SLUG_G"
cp "$REPO/tests/fixtures/sessions/minimal.jsonl" "$DIR_G/projects/$SLUG_G/test-min.jsonl"

# Re-run with -c and capture stderr — gate should suppress the prompt.
STDERR_LOG_G="$TMP/stderr-g.log"
(
    unset CLAUDE_CONFIG_DIR CLAUDE_CODE_ATTRIBUTION_HEADER DISABLE_AUTOUPDATER
    unset CCAGE_DISABLE CCAGE_KEEP_ATTRIBUTION CCAGE_KEEP_AUTOUPDATER
    unset CCAGE_SHARE_FROM CCAGE_SHARE_DIRS CCAGE_SLOT
    unset CCAGE_NO_ONBOARDING_PATCH CCAGE_NO_AUTO_SIGNORE
    cd "$TMP/projG"
    HOME=$FAKE_HOME
    PATH="$MOCK_BIN:$PATH"
    MOCK_LOG="$TMP/log-g-c"
    export HOME PATH MOCK_LOG
    export CCAGE_NO_RESUME_PROMPT=1
    # shellcheck disable=SC1090
    source "$WRAPPER"
    claude -c 2> "$STDERR_LOG_G"
)
check "CCAGE_NO_RESUME_PROMPT=1: no prompt on -c"     test ! -s "$STDERR_LOG_G" || \
    bash -c "! grep -q '\[r\]esume' '$STDERR_LOG_G'"
check "CCAGE_NO_RESUME_PROMPT=1: claude still invoked" grep -qx "MOCK_INVOKED" "$TMP/log-g-c"

# 10b: CCAGE_DISABLE=1 + -c should bypass entirely.
(
    unset CLAUDE_CONFIG_DIR CLAUDE_CODE_ATTRIBUTION_HEADER DISABLE_AUTOUPDATER
    unset CCAGE_KEEP_ATTRIBUTION CCAGE_KEEP_AUTOUPDATER
    unset CCAGE_SHARE_FROM CCAGE_SHARE_DIRS CCAGE_SLOT
    unset CCAGE_NO_ONBOARDING_PATCH CCAGE_NO_AUTO_SIGNORE CCAGE_NO_RESUME_PROMPT
    cd "$TMP/projG"
    HOME=$FAKE_HOME
    PATH="$MOCK_BIN:$PATH"
    MOCK_LOG="$TMP/log-g-disable"
    export HOME PATH MOCK_LOG
    export CCAGE_DISABLE=1
    # shellcheck disable=SC1090
    source "$WRAPPER"
    claude -c 2> "$TMP/stderr-g-disable.log"
)
check "CCAGE_DISABLE=1 with -c: no prompt"            bash -c "! grep -q '\[r\]esume' '$TMP/stderr-g-disable.log' 2>/dev/null"
check "CCAGE_DISABLE=1 with -c: claude invoked"       grep -qx "MOCK_INVOKED" "$TMP/log-g-disable"

# 10c: non-resume invocation (e.g. --print) never prompts even without gates.
(
    unset CLAUDE_CONFIG_DIR CLAUDE_CODE_ATTRIBUTION_HEADER DISABLE_AUTOUPDATER
    unset CCAGE_DISABLE CCAGE_KEEP_ATTRIBUTION CCAGE_KEEP_AUTOUPDATER
    unset CCAGE_SHARE_FROM CCAGE_SHARE_DIRS CCAGE_SLOT
    unset CCAGE_NO_ONBOARDING_PATCH CCAGE_NO_AUTO_SIGNORE CCAGE_NO_RESUME_PROMPT
    cd "$TMP/projG"
    HOME=$FAKE_HOME
    PATH="$MOCK_BIN:$PATH"
    MOCK_LOG="$TMP/log-g-print"
    export HOME PATH MOCK_LOG
    # shellcheck disable=SC1090
    source "$WRAPPER"
    claude --print "hi" 2> "$TMP/stderr-g-print.log"
)
check "non-resume invocation: no prompt"              bash -c "! grep -q '\[r\]esume' '$TMP/stderr-g-print.log' 2>/dev/null"
check "non-resume invocation: claude invoked"         grep -qx "MOCK_INVOKED" "$TMP/log-g-print"

# ===== 11. session-docs hooks seeding through the wrapper (Phase 7) =====
# Opt-in: with CCAGE_SESSION_DOCS=1 the wrapper merges a hooks block into the
# cage's settings.json before exec'ing claude. Sandbox only — fake HOME + a
# temp hooks dir; no real cage is touched.
echo "[11] CCAGE_SESSION_DOCS seeds the hooks block into the cage"
HOOKS_E="$TMP/hooks-e"; mkdir -p "$HOOKS_E" "$TMP/projH"
run_in_proj "$TMP/projH" "$TMP/log-h" CCAGE_SESSION_DOCS=1 CCAGE_HOOKS_DIR="$HOOKS_E"
DIR_H=$(grep '^CLAUDE_CONFIG_DIR=' "$TMP/log-h" | cut -d= -f2-)
check "seeding created settings.json"        test -f "$DIR_H/settings.json"
check "SessionStart auto-read hook seeded"   grep -q 'resume_autoload.sh'     "$DIR_H/settings.json"
check "PostToolUse budget hook seeded"       grep -q 'resume_budget_check.sh' "$DIR_H/settings.json"

# Opt-in respected: no flag → no hooks block.
mkdir -p "$TMP/projI"
run_in_proj "$TMP/projI" "$TMP/log-i"
DIR_I=$(grep '^CLAUDE_CONFIG_DIR=' "$TMP/log-i" | cut -d= -f2-)
check "no hooks block without CCAGE_SESSION_DOCS" \
    bash -c "! grep -q 'resume_autoload.sh' '$DIR_I/settings.json' 2>/dev/null"

# ===== 12. /checkpoint bootstrap → resume_autoload re-injection (deterministic) =====
# The full loop's human steps (/clear) can't be scripted, but the two scriptable
# halves can: the skill's helper bootstraps the files, and the SessionStart hook
# re-injects RESUME exactly as it would after /clear.
echo "[12] checkpoint bootstrap, then auto-read re-injects RESUME"
REPO_J="$TMP/repoJ"; mkdir -p "$REPO_J"
( cd "$REPO_J" && git init -q 2>/dev/null || true )
( cd "$REPO_J" && bash "$REPO/share/skills/checkpoint/checkpoint-init.sh" bootstrap >/dev/null )
check "bootstrap created RESUME.md"     test -f "$REPO_J/RESUME.md"
check "bootstrap created CHANGELOG.md"  test -f "$REPO_J/CHANGELOG.md"
( cd "$REPO_J" && CLAUDE_CONFIG_DIR="$TMP/cage-j" bash "$REPO/share/hooks/resume_autoload.sh" ) > "$TMP/injected-j.txt" 2>/dev/null
check "auto-read re-injects RESUME content" grep -q '## State' "$TMP/injected-j.txt"

# ===== 13. ccage doctor backfills cages (sandbox root) =====
echo "[13] ccage doctor backfills the hooks block across cages"
DROOT="$TMP/doctor-root"; DHOOKS="$TMP/doctor-hooks"
mkdir -p "$DROOT/.claude-one" "$DROOT/.claude-two"
printf '%s\n' "$TMP/repo-one" > "$DROOT/.claude-one/.owning_path"
printf '%s\n' "$TMP/repo-two" > "$DROOT/.claude-two/.owning_path"
CCAGE_ROOT="$DROOT" CCAGE_PREFIX=.claude- CCAGE_HOOKS_DIR="$DHOOKS" \
    "$REPO/bin/ccage" doctor >/dev/null 2>&1 || true
check "doctor seeded cage one" grep -q 'resume_autoload.sh'     "$DROOT/.claude-one/settings.json"
check "doctor seeded cage two" grep -q 'resume_budget_check.sh' "$DROOT/.claude-two/settings.json"

# ===== 14. /keepwarm probe (deterministic, Phase 8) =====
echo "[14] keepwarm probe reads peak + tier from the newest session JSONL"
KWCFG="$TMP/kw-cfg"; KWPROJ="$TMP/kw-proj"
mkdir -p "$KWCFG/projects/${KWPROJ//\//-}" "$KWPROJ"
printf '{"message":{"usage":{"cache_read_input_tokens":42000,"cache_creation":{"ephemeral_1h_input_tokens":9000,"ephemeral_5m_input_tokens":0}}}}\n' \
    > "$KWCFG/projects/${KWPROJ//\//-}/s.jsonl"
CLAUDE_CONFIG_DIR="$KWCFG" bash "$REPO/share/skills/keepwarm/keepwarm-calc.sh" probe "$KWPROJ" > "$TMP/kw-probe.txt"
check "probe reports prefix size" grep -q 'peak_cache_read=42000' "$TMP/kw-probe.txt"
check "probe reports cache tier"  grep -q 'tier=1h'               "$TMP/kw-probe.txt"

# ===== Real claude integration (opt-in) =====
if [ "${1:-}" = "--with-real-claude" ]; then
    echo
    echo "===== real claude integration (opt-in) ====="

    # Discover auth: prefer env-based, fall back to a discoverable creds file.
    REAL_AUTH_FILE=""
    AUTH_MODE=""
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        AUTH_MODE="env"
    else
        # shellcheck disable=SC2031  # parent-shell HOME, not the subshell-local HOME above
        for candidate in \
            "${CLAUDE_CONFIG_DIR:-/dev/null}/.credentials.json" \
            "$HOME/.claude/.credentials.json" \
            "$HOME/.claude-ccage/.credentials.json"
        do
            if [ -f "$candidate" ]; then
                REAL_AUTH_FILE="$candidate"
                AUTH_MODE="file"
                break
            fi
        done
    fi

    if [ -z "$AUTH_MODE" ]; then
        echo "  ✗ no auth available (no ANTHROPIC_API_KEY, no .credentials.json found)"
        echo "  skipping real-claude scenarios"
        FAIL=$((FAIL+1))
    elif ! command -v claude >/dev/null 2>&1; then
        echo "  ✗ real \`claude\` binary not on PATH"
        echo "  skipping real-claude scenarios"
        FAIL=$((FAIL+1))
    else
        echo "  auth: $AUTH_MODE${REAL_AUTH_FILE:+ ($REAL_AUTH_FILE)}"
        CCAGE_REAL_ROOT="$TMP/configs"
        mkdir -p "$CCAGE_REAL_ROOT"

        # Seeds creds into the expected ccage'd dir, then runs the real claude
        # binary with a 60s timeout. Real HOME/PATH preserved. Output goes to $log.
        run_in_proj_real() {
            local pwd_arg="$1" basename="$2" log="$3"; shift 3
            local expected_dir="$CCAGE_REAL_ROOT/.claude-${basename}"

            mkdir -p "$expected_dir"
            if [ "$AUTH_MODE" = "file" ]; then
                ln -sf "$REAL_AUTH_FILE" "$expected_dir/.credentials.json"
            fi

            (
                # Drop strict mode for the claude invocation. The wrapper uses
                # `[ -n "$X" ] && return 0` patterns and other constructs that
                # trip set -e in subtle ways under bash's "errexit in functions"
                # rules. Real-world users source ccage in interactive shells,
                # not strict ones — testing with set -e creates false negatives.
                set +e
                unset CLAUDE_CONFIG_DIR CLAUDE_CODE_ATTRIBUTION_HEADER DISABLE_AUTOUPDATER
                unset CCAGE_DISABLE CCAGE_KEEP_ATTRIBUTION CCAGE_KEEP_AUTOUPDATER
                unset CCAGE_SHARE_FROM CCAGE_SHARE_DIRS CCAGE_SLOT
                unset CCAGE_NO_ONBOARDING_PATCH CCAGE_NO_AUTO_SIGNORE
                cd "$pwd_arg"
                CCAGE_ROOT="$CCAGE_REAL_ROOT"
                export CCAGE_ROOT
                local kv; for kv in "$@"; do export "${kv?}"; done
                # shellcheck disable=SC1090
                source "$WRAPPER"
                # Note: don't wrap in `timeout` — it can't exec a shell function,
                # so it would silently call the real `claude` binary directly,
                # bypassing the wrapper's bootstrap. claude --print is bounded
                # (single API call), so a hang would indicate a real problem.
                claude --print "Reply with the single word: OK" \
                    > "$log" 2>&1 || echo "[exit=$?]" >> "$log"
            )
        }

        # --- A: fresh ccage'd dir ---
        echo "[real-A] fresh ccage'd dir, default settings"
        mkdir -p "$TMP/realA"
        run_in_proj_real "$TMP/realA" "realA" "$TMP/log-rA"
        check "claude returned successfully" grep -qi "OK" "$TMP/log-rA"
        check "no [exit=N] error marker"     test ! "$(grep -c '\[exit=' "$TMP/log-rA")" -gt 0
        check ".owning_path written by bootstrap"   test -f "$CCAGE_REAL_ROOT/.claude-realA/.owning_path"
        check ".claude.json patched by bootstrap"   test -f "$CCAGE_REAL_ROOT/.claude-realA/.claude.json"

        # --- B: re-invoke same dir (idempotency under real claude) ---
        echo "[real-B] re-invoke same dir"
        run_in_proj_real "$TMP/realA" "realA" "$TMP/log-rB"
        check "claude returned successfully on second invoke" grep -qi "OK" "$TMP/log-rB"

        # --- C: CCAGE_SHARE_FROM symlinks tolerated by claude ---
        echo "[real-C] CCAGE_SHARE_FROM symlinks tolerated"
        REAL_MASTER="$TMP/configs-master"
        mkdir -p "$REAL_MASTER/skills/demo-skill" "$REAL_MASTER/commands" "$REAL_MASTER/agents"
        printf '%s\n' "---" "name: demo" "description: demo skill" "---" "demo body" \
            > "$REAL_MASTER/skills/demo-skill/SKILL.md"
        mkdir -p "$TMP/realC"
        run_in_proj_real "$TMP/realC" "realC" "$TMP/log-rC" CCAGE_SHARE_FROM="$REAL_MASTER"
        check "claude returned successfully with symlinked subdirs" \
            grep -qi "OK" "$TMP/log-rC"
        check "skills/ in config dir is a symlink to master" \
            test -L "$CCAGE_REAL_ROOT/.claude-realC/skills"

        # --- D: CCAGE_DISABLE passthrough (real claude, real master config) ---
        # Note: this scenario uses the user's real ~/.claude (or whichever auth
        # path claude defaults to) — that's what DISABLE is supposed to do.
        # No CCAGE_ROOT, no pre-seeding. claude --print is read-only enough
        # that this is safe.
        echo "[real-D] CCAGE_DISABLE: passthrough to real claude"
        mkdir -p "$TMP/realD"
        (
            unset CLAUDE_CONFIG_DIR CLAUDE_CODE_ATTRIBUTION_HEADER DISABLE_AUTOUPDATER
            cd "$TMP/realD"
            CCAGE_DISABLE=1
            export CCAGE_DISABLE
            # shellcheck disable=SC1090
            source "$WRAPPER"
            claude --print "Reply with the single word: OK" \
                > "$TMP/log-rD" 2>&1 || echo "[exit=$?]" >> "$TMP/log-rD"
        )
        check "claude returned successfully under CCAGE_DISABLE" \
            grep -qi "OK" "$TMP/log-rD"
        check "no per-project dir created under CCAGE_DISABLE" \
            test ! -e "$CCAGE_REAL_ROOT/.claude-realD"
    fi
fi

# ===== summary =====
echo
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
exit "$FAIL"
