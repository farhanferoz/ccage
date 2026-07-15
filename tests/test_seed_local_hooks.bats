#!/usr/bin/env bats
# Tests for _ccage_seed_local_hooks — seeds the USER's own hook registrations
# into a cage's settings.json.
#
# The failure this guards: a hook under ~/.claude/hooks is inert until a
# settings.json registers it, and every cage has its own. So a global policy the
# user maintains reached a cage only if someone hand-edited that cage, and every
# NEW cage was born without it. Measured on one machine: the per-turn
# orchestration gate was live in 34 of 71 cages while the policy claimed it fired
# in "every single project".
bats_require_minimum_version 1.5.0

load helpers

setup() {
    command -v python3 >/dev/null 2>&1 || skip "python3 not available"
    load_ccage
    unset CCAGE_SEED_LOCAL_HOOKS CCAGE_LOCAL_HOOKS_SRC

    CAGE="$BATS_TEST_TMPDIR/cage"
    mkdir -p "$CAGE"
    SETTINGS="$CAGE/settings.json"

    HOOKS_DIR="$BATS_TEST_TMPDIR/hooks"
    export CCAGE_HOOKS_DIR="$HOOKS_DIR"

    SRC="$BATS_TEST_TMPDIR/user_settings.json"
    export CCAGE_LOCAL_HOOKS_SRC="$SRC"
    GATE_CMD="bash $HOOKS_DIR/orchestrator_check.sh"
}

# jq helper: does any hook entry under EVENT carry COMMAND?
has_cmd() {
    local event="$1" cmd="$2"
    jq -e --arg ev "$event" --arg c "$cmd" \
        '[ .hooks[$ev][]?.hooks[]?.command ] | any(. == $c)' \
        "$SETTINGS" >/dev/null 2>&1
}

write_src() { cat > "$SRC"; }

@test "opt-out (unset): no-op, settings.json not created" {
    write_src <<JSON
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"$GATE_CMD"}]}]}}
JSON
    _ccage_seed_local_hooks "$CAGE"
    [ ! -f "$SETTINGS" ]
}

@test "opt-in: a local hook is seeded into the cage" {
    CCAGE_SEED_LOCAL_HOOKS=1
    write_src <<JSON
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"$GATE_CMD"}]}]}}
JSON
    _ccage_seed_local_hooks "$CAGE"
    [ -f "$SETTINGS" ]
    has_cmd UserPromptSubmit "$GATE_CMD"
}

@test "tilde-form registrations are expanded, not silently skipped" {
    # The bug that made the first implementation of this a no-op for the most
    # important hook: the user's settings.json used `bash ~/.claude/hooks/x.sh`
    # while the match tested the absolute path.
    CCAGE_SEED_LOCAL_HOOKS=1
    unset CCAGE_HOOKS_DIR                 # default: $HOME/.claude/hooks
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.claude/hooks"
    write_src <<'JSON'
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/orchestrator_check.sh"}]}]}}
JSON
    _ccage_seed_local_hooks "$CAGE"
    has_cmd UserPromptSubmit "bash $HOME/.claude/hooks/orchestrator_check.sh"
    # and the tilde form must NOT be written verbatim
    run jq -e '[ .hooks.UserPromptSubmit[]?.hooks[]?.command ] | any(test("~"))' "$SETTINGS"
    [ "$status" -ne 0 ]
}

@test "ccage's own session-docs hooks are NOT copied (they have their own opt-outs)" {
    CCAGE_SEED_LOCAL_HOOKS=1
    write_src <<JSON
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash $HOOKS_DIR/resume_autoload.sh"}]}],
          "UserPromptSubmit":[{"hooks":[{"type":"command","command":"$GATE_CMD"}]}]}}
JSON
    _ccage_seed_local_hooks "$CAGE"
    has_cmd UserPromptSubmit "$GATE_CMD"
    run has_cmd SessionStart "bash $HOOKS_DIR/resume_autoload.sh"
    [ "$status" -ne 0 ]
}

@test "hooks that are not ours (inline commands) are not spread" {
    CCAGE_SEED_LOCAL_HOOKS=1
    write_src <<'JSON'
{"hooks":{"Notification":[{"hooks":[{"type":"command","command":"curl -X POST http://127.0.0.1:8177/notify"}]}]}}
JSON
    _ccage_seed_local_hooks "$CAGE"
    [ ! -f "$SETTINGS" ]
}

@test "idempotent: second run adds no duplicate" {
    CCAGE_SEED_LOCAL_HOOKS=1
    write_src <<JSON
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"$GATE_CMD"}]}]}}
JSON
    _ccage_seed_local_hooks "$CAGE"
    _ccage_seed_local_hooks "$CAGE"
    [ "$(jq '[ .hooks.UserPromptSubmit[]?.hooks[]? ] | length' "$SETTINGS")" = "1" ]
}

@test "preserves existing unrelated keys and existing hooks" {
    CCAGE_SEED_LOCAL_HOOKS=1
    cat > "$SETTINGS" <<JSON
{"statusLine":{"type":"command","command":"x"},
 "effortLevel":"high",
 "hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"bash $HOOKS_DIR/keepme.sh"}]}]}}
JSON
    write_src <<JSON
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"$GATE_CMD"}]}]}}
JSON
    _ccage_seed_local_hooks "$CAGE"
    [ "$(jq -r '.effortLevel' "$SETTINGS")" = "high" ]
    [ "$(jq -r '.statusLine.command' "$SETTINGS")" = "x" ]
    has_cmd SessionEnd "bash $HOOKS_DIR/keepme.sh"
    has_cmd UserPromptSubmit "$GATE_CMD"
}

@test "never clobbers a present-but-unparseable settings.json" {
    CCAGE_SEED_LOCAL_HOOKS=1
    printf 'not json at all' > "$SETTINGS"
    write_src <<JSON
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"$GATE_CMD"}]}]}}
JSON
    _ccage_seed_local_hooks "$CAGE"
    [ "$(cat "$SETTINGS")" = "not json at all" ]
}

@test "missing source settings: no-op" {
    CCAGE_SEED_LOCAL_HOOKS=1
    rm -f "$SRC"
    _ccage_seed_local_hooks "$CAGE"
    [ ! -f "$SETTINGS" ]
}

@test "source == target (uncaged): no-op, never seeds a file from itself" {
    CCAGE_SEED_LOCAL_HOOKS=1
    write_src <<JSON
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"$GATE_CMD"}]}]}}
JSON
    export CCAGE_LOCAL_HOOKS_SRC="$SETTINGS"
    cp "$SRC" "$SETTINGS"
    _ccage_seed_local_hooks "$CAGE"
    [ "$(jq '[ .hooks.UserPromptSubmit[]?.hooks[]? ] | length' "$SETTINGS")" = "1" ]
}
