#!/usr/bin/env bats
# Tests for `ccage enable-mcp` / `ccage disable-mcp`. Runs the real bin/ccage
# dispatcher against a SANDBOX project dir (never the user's real repos or
# cages), so no running session is affected. The isolation test proves the
# command writes ONLY <dir>/.mcp.json — never a cage's .claude.json or ~/.claude.
bats_require_minimum_version 1.5.0

setup() {
    command -v jq >/dev/null 2>&1 || skip "jq required"
    command -v python3 >/dev/null 2>&1 || skip "python3 required"
    CCAGE="$BATS_TEST_DIRNAME/../bin/ccage"
    PROJ="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$PROJ"
    MCP="$PROJ/.mcp.json"
}

# server <file> <name> → echoes "command + args" for that server, or empty.
server() {
    jq -r --arg n "$2" \
        '.mcpServers[$n] | (.command + " " + (.args // [] | join(" ")))' "$1" 2>/dev/null
}

@test "enable-mcp creates .mcp.json with the server command + args" {
    run "$CCAGE" enable-mcp playwright-test --dir "$PROJ" -- npx playwright run-test-mcp-server --headless
    [ "$status" -eq 0 ]
    [[ "$output" == *"enabled playwright-test"* ]]
    [ "$(jq -r '.mcpServers["playwright-test"].command' "$MCP")" = "npx" ]
    [ "$(jq -r '.mcpServers["playwright-test"].args | join(" ")' "$MCP")" = "playwright run-test-mcp-server --headless" ]
}

@test "enable-mcp is idempotent: re-enabling the same server reports unchanged" {
    "$CCAGE" enable-mcp pw --dir "$PROJ" -- npx playwright run-test-mcp-server >/dev/null
    run "$CCAGE" enable-mcp pw --dir "$PROJ" -- npx playwright run-test-mcp-server
    [ "$status" -eq 0 ]
    [[ "$output" == *"already enabled"* ]]
    [ "$(jq '.mcpServers | length' "$MCP")" -eq 1 ]
}

@test "enable-mcp preserves other servers and unrelated top-level keys" {
    printf '%s\n' '{"mcpServers":{"makerkit":{"command":"node","args":["x"]}},"otherKey":42}' > "$MCP"
    run "$CCAGE" enable-mcp playwright-test --dir "$PROJ" -- npx playwright run-test-mcp-server
    [ "$status" -eq 0 ]
    [ "$(server "$MCP" makerkit)" = "node x" ]
    [ "$(jq -r '.otherKey' "$MCP")" = "42" ]
    [ "$(jq -r '.mcpServers["playwright-test"].command' "$MCP")" = "npx" ]
}

@test "enable-mcp updates a server whose command changed" {
    "$CCAGE" enable-mcp pw --dir "$PROJ" -- old-cmd >/dev/null
    run "$CCAGE" enable-mcp pw --dir "$PROJ" -- new-cmd --flag
    [ "$status" -eq 0 ]
    [[ "$output" == *"updated pw"* ]]
    [ "$(server "$MCP" pw)" = "new-cmd --flag" ]
}

@test "enable-mcp --dry-run writes nothing" {
    run "$CCAGE" enable-mcp pw --dir "$PROJ" --dry-run -- npx server
    [ "$status" -eq 0 ]
    # Verb must be the infinitive "enable", not the status word "enabled".
    [[ "$output" == *"would enable pw"* ]]
    [ ! -f "$MCP" ]
}

@test "enable-mcp preserves extra keys on an existing entry (e.g. env)" {
    printf '%s\n' '{"mcpServers":{"pw":{"command":"old","args":[],"env":{"K":"v"}}}}' > "$MCP"
    run "$CCAGE" enable-mcp pw --dir "$PROJ" -- new-cmd --flag
    [ "$status" -eq 0 ]
    [[ "$output" == *"updated pw"* ]]
    [ "$(server "$MCP" pw)" = "new-cmd --flag" ]
    [ "$(jq -r '.mcpServers.pw.env.K' "$MCP")" = "v" ]
}

@test "enable-mcp errors when no command follows --" {
    run "$CCAGE" enable-mcp pw --dir "$PROJ" --
    [ "$status" -eq 2 ]
    [[ "$output" == *"missing command"* ]]
    [ ! -f "$MCP" ]
}

@test "enable-mcp rejects an invalid server name" {
    run "$CCAGE" enable-mcp 'bad name!' --dir "$PROJ" -- npx server
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid server name"* ]]
}

@test "enable-mcp errors on a missing directory" {
    run "$CCAGE" enable-mcp pw --dir "$PROJ/nope" -- npx server
    [ "$status" -eq 2 ]
    [[ "$output" == *"no such directory"* ]]
}

@test "disable-mcp removes the server and deletes a now-empty file" {
    "$CCAGE" enable-mcp pw --dir "$PROJ" -- npx server >/dev/null
    run "$CCAGE" disable-mcp pw --dir "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"disabled pw"* ]]
    [ ! -f "$MCP" ]
}

@test "disable-mcp keeps other servers and the file" {
    "$CCAGE" enable-mcp a --dir "$PROJ" -- cmd-a >/dev/null
    "$CCAGE" enable-mcp b --dir "$PROJ" -- cmd-b >/dev/null
    run "$CCAGE" disable-mcp a --dir "$PROJ"
    [ "$status" -eq 0 ]
    [ -f "$MCP" ]
    [ "$(jq -r '.mcpServers | keys | join(",")' "$MCP")" = "b" ]
}

@test "disable-mcp on an absent server is a no-op" {
    "$CCAGE" enable-mcp a --dir "$PROJ" -- cmd-a >/dev/null
    run "$CCAGE" disable-mcp ghost --dir "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no change"* ]]
    [ "$(jq -r '.mcpServers | keys | join(",")' "$MCP")" = "a" ]
}

@test "disable-mcp when no .mcp.json exists is a no-op" {
    run "$CCAGE" disable-mcp pw --dir "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not enabled"* ]]
}

@test "enable-mcp --help and disable-mcp --help print usage" {
    run "$CCAGE" enable-mcp --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: ccage enable-mcp"* ]]
    run "$CCAGE" disable-mcp --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: ccage disable-mcp"* ]]
}

# ---- isolation: writes ONLY <dir>/.mcp.json --------------------------------
# The whole point of the command is that it cannot blend MCP across projects or
# race a live cage's .claude.json. Prove it touches nothing but DIR/.mcp.json:
# a sentinel ~/.claude.json under a sandbox HOME must be byte-identical after.
@test "enable-mcp does not touch \$HOME/.claude.json (no cross-project blend)" {
    local home="$BATS_TEST_TMPDIR/home"; mkdir -p "$home"
    printf '%s\n' '{"sentinel":"untouched"}' > "$home/.claude.json"
    local before; before=$(cat "$home/.claude.json")
    HOME="$home" run "$CCAGE" enable-mcp pw --dir "$PROJ" -- npx server
    [ "$status" -eq 0 ]
    [ -f "$MCP" ]
    [ ! -f "$PROJ/.claude.json" ]
    [ "$(cat "$home/.claude.json")" = "$before" ]
}
