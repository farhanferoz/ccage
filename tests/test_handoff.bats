#!/usr/bin/env bats
# Tests for share/ccage-handoff.sh — JSONL → Markdown handoff brief.
# Phase 6a. Pure-shell + jq; zero API calls; offline.
bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    FIXTURES="$BATS_TEST_DIRNAME/fixtures/sessions"
    # shellcheck source=../share/ccage-handoff.sh disable=SC1091
    source "$REPO_ROOT/share/ccage-handoff.sh"

    # Pin handoff output dir into a temp area so tests never write to $HOME.
    CCAGE_HANDOFF_DIR="$BATS_TEST_TMPDIR/handoffs"
    export CCAGE_HANDOFF_DIR
}

# ===== pwd-to-slug =====

@test "pwd_to_slug: /home/u/proj -> -home-u-proj" {
    run _ccage_handoff_pwd_to_slug /home/u/proj
    [ "$status" -eq 0 ]
    [ "$output" = "-home-u-proj" ]
}

@test "pwd_to_slug: defaults to PWD when no arg" {
    PWD=/some/place run _ccage_handoff_pwd_to_slug
    [ "$status" -eq 0 ]
    [ "$output" = "-some-place" ]
}

@test "pwd_to_slug: handles nested paths with dashes in segments" {
    run _ccage_handoff_pwd_to_slug /home/u/my-project/sub
    [ "$output" = "-home-u-my-project-sub" ]
}

# ===== locate JSONL =====

@test "locate: single session in dir returns that file" {
    local dir="$BATS_TEST_TMPDIR/sessions"
    mkdir -p "$dir"
    cp "$FIXTURES/minimal.jsonl" "$dir/abc123-xx.jsonl"
    run _ccage_handoff_locate "$dir"
    [ "$status" -eq 0 ]
    [ "$output" = "$dir/abc123-xx.jsonl" ]
}

@test "locate: no session dir errors with stderr message" {
    run --separate-stderr _ccage_handoff_locate "$BATS_TEST_TMPDIR/nope"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"no sessions"* ]]
}

@test "locate: empty session dir errors with stderr message" {
    mkdir -p "$BATS_TEST_TMPDIR/empty-sessions"
    run --separate-stderr _ccage_handoff_locate "$BATS_TEST_TMPDIR/empty-sessions"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"no .jsonl"* ]]
}

@test "locate: multiple files, no prefix, returns newest by mtime" {
    local dir="$BATS_TEST_TMPDIR/sessions"
    mkdir -p "$dir"
    cp "$FIXTURES/minimal.jsonl" "$dir/abc-old.jsonl"
    cp "$FIXTURES/minimal.jsonl" "$dir/xyz-new.jsonl"
    # POSIX -t format: [[CC]YY]MMDDhhmm — portable across GNU touch and BSD touch (macOS).
    touch -t 202001010000 "$dir/abc-old.jsonl"
    touch -t 202601010000 "$dir/xyz-new.jsonl"
    run _ccage_handoff_locate "$dir"
    [ "$status" -eq 0 ]
    [ "$output" = "$dir/xyz-new.jsonl" ]
}

@test "locate: prefix matches single file" {
    local dir="$BATS_TEST_TMPDIR/sessions"
    mkdir -p "$dir"
    cp "$FIXTURES/minimal.jsonl" "$dir/abc123.jsonl"
    cp "$FIXTURES/minimal.jsonl" "$dir/xyz789.jsonl"
    run _ccage_handoff_locate "$dir" abc
    [ "$status" -eq 0 ]
    [ "$output" = "$dir/abc123.jsonl" ]
}

@test "locate: ambiguous prefix errors with candidate list" {
    local dir="$BATS_TEST_TMPDIR/sessions"
    mkdir -p "$dir"
    cp "$FIXTURES/minimal.jsonl" "$dir/abc111.jsonl"
    cp "$FIXTURES/minimal.jsonl" "$dir/abc222.jsonl"
    run --separate-stderr _ccage_handoff_locate "$dir" abc
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"ambiguous"* ]]
    [[ "$stderr" == *"abc111"* ]]
    [[ "$stderr" == *"abc222"* ]]
}

@test "locate: prefix with no matches errors" {
    local dir="$BATS_TEST_TMPDIR/sessions"
    mkdir -p "$dir"
    cp "$FIXTURES/minimal.jsonl" "$dir/abc111.jsonl"
    run --separate-stderr _ccage_handoff_locate "$dir" zzz
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"no sessions matching"* ]]
}

# ===== token totals =====

@test "token_totals: sums all assistant turns in minimal.jsonl" {
    run _ccage_handoff_token_totals "$FIXTURES/minimal.jsonl"
    [ "$status" -eq 0 ]
    # 3 assistant turns: in 50+60+70=180, out 30+40+50=120,
    # cache_write 1200+1500+1800=4500, cache_read 15000+18000+22000=55000
    [[ "$output" == *"input=180"* ]]
    [[ "$output" == *"output=120"* ]]
    [[ "$output" == *"cache_write=4500"* ]]
    [[ "$output" == *"cache_read=55000"* ]]
}

@test "token_totals: empty session emits zeros" {
    run _ccage_handoff_token_totals "$FIXTURES/empty.jsonl"
    [ "$status" -eq 0 ]
    [[ "$output" == *"input=0"* ]]
    [[ "$output" == *"cache_write=0"* ]]
}

# ===== peak cache read =====

@test "peak_cache_read: returns max substantive cache_read from minimal" {
    run _ccage_handoff_peak_cache_read "$FIXTURES/minimal.jsonl"
    [ "$status" -eq 0 ]
    [ "$output" = "22000" ]
}

@test "peak_cache_read: empty session returns 0" {
    run _ccage_handoff_peak_cache_read "$FIXTURES/empty.jsonl"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

# ===== last model =====

@test "last_model: minimal session" {
    run _ccage_handoff_last_model "$FIXTURES/minimal.jsonl"
    [ "$output" = "claude-opus-4-7" ]
}

@test "last_model: diverse session" {
    run _ccage_handoff_last_model "$FIXTURES/diverse.jsonl"
    [ "$output" = "claude-sonnet-4-6" ]
}

@test "last_model: empty session falls back to 'unknown'" {
    run _ccage_handoff_last_model "$FIXTURES/empty.jsonl"
    [ "$output" = "unknown" ]
}

# ===== user prompt counting =====

@test "count_prompts: minimal has 2 real prompts (excludes meta + tool-results)" {
    run _ccage_handoff_count_prompts "$FIXTURES/minimal.jsonl"
    [ "$output" = "2" ]
}

@test "count_prompts: diverse counts array-content prompt" {
    run _ccage_handoff_count_prompts "$FIXTURES/diverse.jsonl"
    [ "$output" = "3" ]
}

@test "count_prompts: empty session is 0" {
    run _ccage_handoff_count_prompts "$FIXTURES/empty.jsonl"
    [ "$output" = "0" ]
}

@test "count_assistants: minimal has 3 assistant turns" {
    run _ccage_handoff_count_assistants "$FIXTURES/minimal.jsonl"
    [ "$output" = "3" ]
}

# ===== brief generation — section presence =====

@test "generate: brief contains all required sections" {
    run _ccage_handoff_generate "$FIXTURES/minimal.jsonl" --stdout
    [ "$status" -eq 0 ]
    [[ "$output" == *"# Handoff:"* ]]
    [[ "$output" == *"User prompts"* ]]
    [[ "$output" == *"Files touched"* ]]
    [[ "$output" == *"Commands run"* ]]
    [[ "$output" == *"Last assistant turn"* ]]
    [[ "$output" == *"Tokens billed"* ]]
}

@test "generate: includes session ID from JSONL" {
    run _ccage_handoff_generate "$FIXTURES/minimal.jsonl" --stdout
    [[ "$output" == *"test-min-001"* ]]
}

@test "generate: includes both user prompts verbatim" {
    run _ccage_handoff_generate "$FIXTURES/minimal.jsonl" --stdout
    [[ "$output" == *"hello, please help me with the bug"* ]]
    [[ "$output" == *"now show me what changed"* ]]
}

@test "generate: excludes meta-message synthetic content" {
    run _ccage_handoff_generate "$FIXTURES/minimal.jsonl" --stdout
    [[ "$output" != *"<system-reminder>"* ]]
}

@test "generate: excludes tool_use_result content" {
    run _ccage_handoff_generate "$FIXTURES/minimal.jsonl" --stdout
    # Tool result texts were "file content here" / "file list" — must not appear as user prompts
    # (they may appear inside Files-touched paths or Commands sections, but not under User prompts).
    # Check the User prompts section specifically:
    local user_section
    user_section="$(printf '%s\n' "$output" | awk '/^## User prompts/{flag=1; next} /^## /{flag=0} flag')"
    [[ "$user_section" != *"file content here"* ]]
}

@test "generate: lists file from Read tool_use" {
    run _ccage_handoff_generate "$FIXTURES/minimal.jsonl" --stdout
    [[ "$output" == *"/tmp/foo.py"* ]]
}

@test "generate: shows last assistant turn text" {
    run _ccage_handoff_generate "$FIXTURES/minimal.jsonl" --stdout
    [[ "$output" == *"Here's a summary of what I found."* ]]
}

@test "generate: diverse session shows Edit, Write, Read in files table" {
    run _ccage_handoff_generate "$FIXTURES/diverse.jsonl" --stdout
    [[ "$output" == *"/tmp/x.py"* ]]
    [[ "$output" == *"/tmp/y.py"* ]]
}

@test "generate: diverse session shows 'git status' but trivial 'pwd' filtered" {
    run _ccage_handoff_generate "$FIXTURES/diverse.jsonl" --stdout
    [[ "$output" == *"git status"* ]]
    # 'pwd' is the entire command, must not appear in Commands section
    local commands_section
    commands_section="$(printf '%s\n' "$output" | awk '/^## Commands/{flag=1; next} /^## /{flag=0} flag')"
    [[ "$commands_section" != *"- \`pwd\`"* ]]
    [[ "$commands_section" != *"- pwd"* ]]
}

@test "generate: array-content user prompt extracted from diverse" {
    run _ccage_handoff_generate "$FIXTURES/diverse.jsonl" --stdout
    [[ "$output" == *"prompt two from array content"* ]]
}

@test "generate: includes pricing-based cost estimate" {
    run _ccage_handoff_generate "$FIXTURES/minimal.jsonl" --stdout
    # 4500 cache_write tokens on opus-4-7 at $18.75/M ≈ $0.08
    # Display format is "$X.YZ" — just check that some dollar amount appears.
    [[ "$output" == *"~\$"* ]]
}

# ===== brief generation — max-prompts truncation =====

@test "generate: --max-prompts 1 truncates and notes elided count" {
    run _ccage_handoff_generate "$FIXTURES/minimal.jsonl" --stdout --max-prompts 1
    [ "$status" -eq 0 ]
    # Should show the most-recent ("now show me what changed"), not the first.
    [[ "$output" == *"now show me what changed"* ]]
    [[ "$output" != *"hello, please help me with the bug"* ]]
    # Elision marker must reference the elided count (1 of 2).
    [[ "$output" == *"earlier prompt"* ]]
}

@test "generate: --max-prompts >= count: no elision marker" {
    run _ccage_handoff_generate "$FIXTURES/minimal.jsonl" --stdout --max-prompts 100
    [[ "$output" != *"earlier prompts elided"* ]]
}

# ===== brief generation — empty session =====

@test "generate: empty session produces brief with placeholder sections" {
    run _ccage_handoff_generate "$FIXTURES/empty.jsonl" --stdout
    [ "$status" -eq 0 ]
    [[ "$output" == *"User prompts"* ]]
    [[ "$output" == *"Files touched"* ]]
}

# ===== brief generation — malformed lines =====

@test "generate: malformed-line resilience" {
    run _ccage_handoff_generate "$FIXTURES/malformed.jsonl" --stdout
    [ "$status" -eq 0 ]
    [[ "$output" == *"first valid prompt"* ]]
    [[ "$output" == *"second valid prompt"* ]]
    [[ "$output" == *"Recovered after malformed line"* ]]
}

# ===== brief generation — file output =====

@test "generate: writes file to CCAGE_HANDOFF_DIR by default" {
    run _ccage_handoff_generate "$FIXTURES/minimal.jsonl"
    [ "$status" -eq 0 ]
    [ -d "$CCAGE_HANDOFF_DIR" ]
    local f
    f=$(ls -t "$CCAGE_HANDOFF_DIR"/*.md 2>/dev/null | head -1)
    [ -n "$f" ]
    grep -q "Handoff: test-min-001" "$f"
}

@test "generate: filename contains project slug + session prefix + timestamp" {
    PWD=/home/u/myproj _ccage_handoff_generate "$FIXTURES/minimal.jsonl"
    local f
    f=$(ls "$CCAGE_HANDOFF_DIR"/*.md 2>/dev/null | head -1)
    [[ "$(basename "$f")" == *"-home-u-myproj"* ]]
    [[ "$(basename "$f")" == *"test-min"* ]]
    [[ "$(basename "$f")" == *".md" ]]
}

@test "generate: --output FILE writes to that path" {
    local out="$BATS_TEST_TMPDIR/explicit.md"
    run _ccage_handoff_generate "$FIXTURES/minimal.jsonl" --output "$out"
    [ "$status" -eq 0 ]
    [ -f "$out" ]
    grep -q "Handoff: test-min-001" "$out"
}

# ===== dispatcher integration — bin/ccage handoff =====

@test "bin/ccage handoff --stdout works against a real fixture-shaped session dir" {
    local proj_dir="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$proj_dir"
    local config_dir="$BATS_TEST_TMPDIR/cfg"
    local slug
    slug="$(_ccage_handoff_pwd_to_slug "$proj_dir")"
    local sd="$config_dir/projects/$slug"
    mkdir -p "$sd"
    cp "$FIXTURES/minimal.jsonl" "$sd/test-min-001.jsonl"
    # bin/ccage uses --project to derive the slug; safer than relying on $PWD
    # which bash re-syncs from getcwd on script startup.
    CLAUDE_CONFIG_DIR="$config_dir" \
        run "$REPO_ROOT/bin/ccage" handoff --project "$proj_dir" --stdout
    [ "$status" -eq 0 ]
    [[ "$output" == *"test-min-001"* ]]
}

@test "bin/ccage handoff with no sessions exits 2 with stderr message" {
    local proj_dir="$BATS_TEST_TMPDIR/no-sessions"
    mkdir -p "$proj_dir"
    local config_dir="$BATS_TEST_TMPDIR/cfg"
    mkdir -p "$config_dir/projects"
    CLAUDE_CONFIG_DIR="$config_dir" \
        run --separate-stderr "$REPO_ROOT/bin/ccage" handoff --project "$proj_dir" --stdout
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"no sessions"* ]] || [[ "$stderr" == *"no .jsonl"* ]]
}

@test "bin/ccage unknown subcommand exits 2" {
    run --separate-stderr "$REPO_ROOT/bin/ccage" garbage
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"unknown"* ]] || [[ "$stderr" == *"usage"* ]]
}
