#!/usr/bin/env bats
# Tests for _ccage_seed_session_docs_hooks — Phase 7 (component D).
# Verifies the gated, idempotent settings.json MERGE: it adds the SessionStart
# auto-read + PostToolUse budget hooks without clobbering existing keys, honors
# the master opt-in and the two sub-opt-outs, and is a no-op when off.
bats_require_minimum_version 1.5.0

load helpers

setup() {
    command -v python3 >/dev/null 2>&1 || skip "python3 not available"
    load_ccage
    unset CCAGE_SESSION_DOCS CCAGE_NO_AUTOLOAD CCAGE_NO_BUDGET_HOOK

    CAGE="$BATS_TEST_TMPDIR/cage"
    mkdir -p "$CAGE"
    SETTINGS="$CAGE/settings.json"

    HOOKS_DIR="$BATS_TEST_TMPDIR/hooks"
    export CCAGE_HOOKS_DIR="$HOOKS_DIR"
    AUTOLOAD_CMD="bash $HOOKS_DIR/resume_autoload.sh"
    CHUNKS="${CCAGE_DOC_CHUNKS:-12}"
    # autoload + one command per part, for each of DECISIONS and RESUME.
    SS_TOTAL=$((1 + 2 * CHUNKS))
    BUDGET_CMD="bash $HOOKS_DIR/resume_budget_check.sh"
}

# jq helper: does any hook entry under EVENT carry COMMAND?
has_cmd() {
    local event="$1" cmd="$2"
    jq -e --arg ev "$event" --arg c "$cmd" \
        '[ .hooks[$ev][]?.hooks[]?.command ] | any(. == $c)' \
        "$SETTINGS" >/dev/null 2>&1
}

@test "CCAGE_SESSION_DOCS unset: no-op, settings.json not created" {
    _ccage_seed_session_docs_hooks "$CAGE"
    [ ! -f "$SETTINGS" ]
}

@test "opt-in, no prior settings: both hooks seeded with correct matchers" {
    CCAGE_SESSION_DOCS=1
    _ccage_seed_session_docs_hooks "$CAGE"
    [ -f "$SETTINGS" ]
    has_cmd SessionStart "$AUTOLOAD_CMD"
    has_cmd PostToolUse  "$BUDGET_CMD"
    [ "$(jq -r '.hooks.SessionStart[0].matcher' "$SETTINGS")" = "startup|resume|clear|compact" ]
    [ "$(jq -r '.hooks.PostToolUse[0].matcher'  "$SETTINGS")" = "Write|Edit" ]
}

@test "opt-in preserves existing unrelated keys (statusLine, plugins, effort)" {
    CCAGE_SESSION_DOCS=1
    cat > "$SETTINGS" <<'JSON'
{
  "statusLine": {"type": "command", "command": "bash ~/.claude/statusline.sh"},
  "enabledPlugins": ["foo@bar"],
  "effortLevel": "xhigh"
}
JSON
    _ccage_seed_session_docs_hooks "$CAGE"
    # Existing keys intact.
    [ "$(jq -r '.statusLine.command' "$SETTINGS")" = "bash ~/.claude/statusline.sh" ]
    [ "$(jq -r '.enabledPlugins[0]' "$SETTINGS")" = "foo@bar" ]
    [ "$(jq -r '.effortLevel' "$SETTINGS")" = "xhigh" ]
    # Hooks added.
    has_cmd SessionStart "$AUTOLOAD_CMD"
    has_cmd PostToolUse  "$BUDGET_CMD"
}

@test "idempotent: second run adds no duplicate entries" {
    CCAGE_SESSION_DOCS=1
    _ccage_seed_session_docs_hooks "$CAGE"
    _ccage_seed_session_docs_hooks "$CAGE"
    [ "$(jq '.hooks.SessionStart | length' "$SETTINGS")" -eq "$SS_TOTAL" ]
    [ "$(jq '.hooks.PostToolUse  | length' "$SETTINGS")" -eq 1 ]
}

@test "the chunk hook is seeded once per part, for both docs, with the count baked in" {
    CCAGE_SESSION_DOCS=1
    _ccage_seed_session_docs_hooks "$CAGE"
    local cmds; cmds=$(jq -r '[.hooks.SessionStart[].hooks[].command] | .[]' "$SETTINGS")
    [ "$(printf '%s\n' "$cmds" | grep -c 'session_doc_chunk.sh decisions ')" -eq "$CHUNKS" ]
    [ "$(printf '%s\n' "$cmds" | grep -c 'session_doc_chunk.sh resume ')"    -eq "$CHUNKS" ]
    # Each part is a DISTINCT registration — the bug a basename-only dedup key
    # would cause is exactly one part seeded and the rest silently dropped.
    [ "$(printf '%s\n' "$cmds" | grep 'session_doc_chunk.sh' | sort -u | wc -l)" -eq "$((2 * CHUNKS))" ]
    printf '%s\n' "$cmds" | grep -qF "session_doc_chunk.sh decisions 1 $CHUNKS"
    printf '%s\n' "$cmds" | grep -qF "session_doc_chunk.sh resume $CHUNKS $CHUNKS"
}

@test "CCAGE_DOC_CHUNKS rewrites the block; a bogus value falls back to the default" {
    CCAGE_SESSION_DOCS=1
    _ccage_seed_session_docs_hooks "$CAGE"
    # Rewritten in place, not appended to — otherwise the parts drift apart from
    # each other as _ccage_seed_local_hooks adds entries between launches.
    CCAGE_DOC_CHUNKS=4 _ccage_seed_session_docs_hooks "$CAGE"
    [ "$(jq '[.hooks.SessionStart[].hooks[].command | select(test("session_doc_chunk"))] | length' "$SETTINGS")" -eq 8 ]
    [ "$(jq '[.hooks.SessionStart[].hooks[].command | select(test("resume_autoload"))]  | length' "$SETTINGS")" -eq 1 ]
    # The value is baked into every registration, so it is validated first.
    CCAGE_DOC_CHUNKS="; rm -rf /" _ccage_seed_session_docs_hooks "$CAGE"
    [ "$(jq '.hooks.SessionStart | length' "$SETTINGS")" -eq "$SS_TOTAL" ]
    run jq -e '[.hooks.SessionStart[].hooks[].command] | any(test("rm -rf"))' "$SETTINGS"
    [ "$status" -ne 0 ]
}

@test "a user hook bundled in the SAME entry as ours survives the rebuild" {
    CCAGE_SESSION_DOCS=1
    cat > "$SETTINGS" <<JSON
{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[
  {"type":"command","command":"bash $HOOKS_DIR/resume_autoload.sh"},
  {"type":"command","command":"echo mine"}]}]}}
JSON
    _ccage_seed_session_docs_hooks "$CAGE"
    jq -e '[.hooks.SessionStart[]?.hooks[]?.command] | any(. == "echo mine")' "$SETTINGS" >/dev/null
    [ "$(jq '[.hooks.SessionStart[].hooks[].command | select(test("resume_autoload"))] | length' "$SETTINGS")" -eq 1 ]
}

@test "CCAGE_NO_AUTOLOAD=1: only the budget hook is seeded" {
    CCAGE_SESSION_DOCS=1
    CCAGE_NO_AUTOLOAD=1
    _ccage_seed_session_docs_hooks "$CAGE"
    run has_cmd SessionStart "$AUTOLOAD_CMD"
    [ "$status" -ne 0 ]
    has_cmd PostToolUse "$BUDGET_CMD"
}

@test "CCAGE_NO_BUDGET_HOOK=1: only the auto-read hook is seeded" {
    CCAGE_SESSION_DOCS=1
    CCAGE_NO_BUDGET_HOOK=1
    _ccage_seed_session_docs_hooks "$CAGE"
    has_cmd SessionStart "$AUTOLOAD_CMD"
    run has_cmd PostToolUse "$BUDGET_CMD"
    [ "$status" -ne 0 ]
}

@test "both sub-opt-outs: no-op, settings.json not created" {
    CCAGE_SESSION_DOCS=1
    CCAGE_NO_AUTOLOAD=1
    CCAGE_NO_BUDGET_HOOK=1
    _ccage_seed_session_docs_hooks "$CAGE"
    [ ! -f "$SETTINGS" ]
}

@test "preserves a pre-existing unrelated SessionStart entry (append, not replace)" {
    CCAGE_SESSION_DOCS=1
    cat > "$SETTINGS" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {"matcher": "startup", "hooks": [{"type": "command", "command": "echo hi"}]}
    ]
  }
}
JSON
    _ccage_seed_session_docs_hooks "$CAGE"
    # The user's entry survives.
    jq -e '[ .hooks.SessionStart[]?.hooks[]?.command ] | any(. == "echo hi")' "$SETTINGS" >/dev/null
    # Ours is appended.
    has_cmd SessionStart "$AUTOLOAD_CMD"
    [ "$(jq '.hooks.SessionStart | length' "$SETTINGS")" -eq "$((1 + SS_TOTAL))" ]
}

@test "preserves a malformed (non-JSON) settings.json without crashing" {
    CCAGE_SESSION_DOCS=1
    printf 'not json at all\n' > "$SETTINGS"
    run _ccage_seed_session_docs_hooks "$CAGE"
    [ "$status" -eq 0 ]
    # Never clobber a file we did not create: the unparseable settings.json is
    # left byte-for-byte intact (Claude Code rejects it too — the user fixes it),
    # so no hooks are seeded into garbage.
    [ "$(cat "$SETTINGS")" = "not json at all" ]
}

@test "seeding preserves the existing settings.json file mode" {
    CCAGE_SESSION_DOCS=1
    printf '{"theme":"dark"}\n' > "$SETTINGS"
    chmod 0600 "$SETTINGS"
    run _ccage_seed_session_docs_hooks "$CAGE"
    [ "$status" -eq 0 ]
    has_cmd SessionStart "$AUTOLOAD_CMD"
    [ "$(ls -ld "$SETTINGS" | cut -c1-10)" = "-rw-------" ]
}

@test "seeding is idempotent across a differing CCAGE_HOOKS_DIR (path is not identity)" {
    CCAGE_SESSION_DOCS=1
    _ccage_seed_session_docs_hooks "$CAGE"
    # Re-seed with a different hooks dir baked into the command path.
    CCAGE_HOOKS_DIR="/somewhere/else/hooks" _ccage_seed_session_docs_hooks "$CAGE"
    # Same commands as before — no duplicate set from the path change.
    [ "$(jq '[.hooks.SessionStart[]?.hooks[]?.command] | length' "$SETTINGS")" -eq "$SS_TOTAL" ]
}
