#!/usr/bin/env bats
# Tests for share/ccage-handoff.sh — JSONL → Markdown handoff brief.
# Phase 6a. Pure-shell + jq; zero API calls; offline.
#
# Speed note: _ccage_handoff_generate forks many jq passes per brief, so the
# brief-generation tests assert MANY things against ONE generated brief per
# fixture rather than regenerating per assertion. Pure-function helpers are
# likewise grouped one test per helper (all cases inside).
bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    FIXTURES="$BATS_TEST_DIRNAME/fixtures/sessions"
    # shellcheck source=../share/ccage-handoff.sh disable=SC1091
    source "$REPO_ROOT/share/ccage-handoff.sh"

    # Pin handoff output dir into a temp area so tests never write to $HOME.
    CCAGE_HANDOFF_DIR="$BATS_TEST_TMPDIR/handoffs"
    export CCAGE_HANDOFF_DIR

    # Stub pbcopy so NO test can ever reach a real clipboard tool. pbcopy is
    # first in _ccage_handoff_copy_to_clipboard's fallback chain, so putting it
    # on PATH ahead of everything else guarantees it wins even on a machine
    # that also has a real (possibly hanging) wl-copy/xclip/xsel. This is the
    # primary defense against the file-mode tests below reaching the network/
    # display-server clipboard at all — see the comment on the "default file
    # write" test for why a stub beats the fd-3 trick alone.
    local stub_bin="$BATS_TEST_TMPDIR/stubbin"
    mkdir -p "$stub_bin"
    cat > "$stub_bin/pbcopy" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 0
STUB
    chmod +x "$stub_bin/pbcopy"
    PATH="$stub_bin:$PATH"
    export PATH
}

# ===== pure-function helpers (fast: one jq/shell call each) =====

@test "pwd_to_slug: path → dashed slug; defaults to PWD; preserves segment dashes" {
    run _ccage_handoff_pwd_to_slug /home/u/proj
    [ "$output" = "-home-u-proj" ]
    run _ccage_handoff_pwd_to_slug /home/u/my-project/sub
    [ "$output" = "-home-u-my-project-sub" ]
    PWD=/some/place run _ccage_handoff_pwd_to_slug
    [ "$output" = "-some-place" ]
}

@test "locate: selects single file, newest-by-mtime, and by prefix" {
    local dir="$BATS_TEST_TMPDIR/sessions"
    mkdir -p "$dir"
    cp "$FIXTURES/minimal.jsonl" "$dir/abc-old.jsonl"
    run _ccage_handoff_locate "$dir"          # single (only file so far)
    [ "$status" -eq 0 ] && [ "$output" = "$dir/abc-old.jsonl" ]

    cp "$FIXTURES/minimal.jsonl" "$dir/xyz-new.jsonl"
    # POSIX -t format [[CC]YY]MMDDhhmm — portable across GNU and BSD touch.
    touch -t 202001010000 "$dir/abc-old.jsonl"
    touch -t 202601010000 "$dir/xyz-new.jsonl"
    run _ccage_handoff_locate "$dir"          # newest by mtime
    [ "$output" = "$dir/xyz-new.jsonl" ]

    run _ccage_handoff_locate "$dir" abc      # prefix match
    [ "$output" = "$dir/abc-old.jsonl" ]
}

@test "locate: error paths (no dir, empty dir, ambiguous prefix, no match)" {
    run --separate-stderr _ccage_handoff_locate "$BATS_TEST_TMPDIR/nope"
    [ "$status" -eq 2 ] && [[ "$stderr" == *"no sessions"* ]]

    mkdir -p "$BATS_TEST_TMPDIR/empty-sessions"
    run --separate-stderr _ccage_handoff_locate "$BATS_TEST_TMPDIR/empty-sessions"
    [ "$status" -eq 2 ] && [[ "$stderr" == *"no .jsonl"* ]]

    local dir="$BATS_TEST_TMPDIR/sessions"
    mkdir -p "$dir"
    cp "$FIXTURES/minimal.jsonl" "$dir/abc111.jsonl"
    cp "$FIXTURES/minimal.jsonl" "$dir/abc222.jsonl"
    run --separate-stderr _ccage_handoff_locate "$dir" abc
    [ "$status" -eq 2 ] && [[ "$stderr" == *"ambiguous"* ]]
    [[ "$stderr" == *"abc111"* ]] && [[ "$stderr" == *"abc222"* ]]

    run --separate-stderr _ccage_handoff_locate "$dir" zzz
    [ "$status" -eq 2 ] && [[ "$stderr" == *"no sessions matching"* ]]
}

@test "token_totals: sums assistant turns; zeros on empty" {
    run _ccage_handoff_token_totals "$FIXTURES/minimal.jsonl"
    [ "$status" -eq 0 ]
    # 3 turns: in 50+60+70, out 30+40+50, cw 1200+1500+1800, cr 15000+18000+22000
    [[ "$output" == *"input=180"* ]] && [[ "$output" == *"output=120"* ]]
    [[ "$output" == *"cache_write=4500"* ]] && [[ "$output" == *"cache_read=55000"* ]]
    run _ccage_handoff_token_totals "$FIXTURES/empty.jsonl"
    [[ "$output" == *"input=0"* ]] && [[ "$output" == *"cache_write=0"* ]]
}

@test "peak_cache_read: max substantive read; 0 on empty" {
    run _ccage_handoff_peak_cache_read "$FIXTURES/minimal.jsonl"
    [ "$output" = "22000" ]
    run _ccage_handoff_peak_cache_read "$FIXTURES/empty.jsonl"
    [ "$output" = "0" ]
}

@test "last_model: minimal, diverse, and 'unknown' fallback on empty" {
    run _ccage_handoff_last_model "$FIXTURES/minimal.jsonl"
    [ "$output" = "claude-opus-4-7" ]
    run _ccage_handoff_last_model "$FIXTURES/diverse.jsonl"
    [ "$output" = "claude-sonnet-4-6" ]
    run _ccage_handoff_last_model "$FIXTURES/empty.jsonl"
    [ "$output" = "unknown" ]
}

@test "prompt/assistant counts: real prompts excl. meta+tool-results; assistant turns" {
    run _ccage_handoff_count_prompts "$FIXTURES/minimal.jsonl"
    [ "$output" = "2" ]
    run _ccage_handoff_count_prompts "$FIXTURES/diverse.jsonl"   # counts array-content prompt
    [ "$output" = "3" ]
    run _ccage_handoff_count_prompts "$FIXTURES/empty.jsonl"
    [ "$output" = "0" ]
    run _ccage_handoff_count_assistants "$FIXTURES/minimal.jsonl"
    [ "$output" = "3" ]
}

# ===== brief generation (one generation per fixture, many assertions) =====

@test "generate(minimal): sections, id, prompts, files, last turn, cost, exclusions" {
    run _ccage_handoff_generate "$FIXTURES/minimal.jsonl" --stdout
    [ "$status" -eq 0 ]
    # required sections
    [[ "$output" == *"# Handoff:"* ]]
    [[ "$output" == *"User prompts"* ]] && [[ "$output" == *"Files touched"* ]]
    [[ "$output" == *"Commands run"* ]] && [[ "$output" == *"Last assistant turn"* ]]
    [[ "$output" == *"Tokens billed"* ]]
    # session id + both prompts verbatim + Read'd file + last assistant text
    [[ "$output" == *"test-min-001"* ]]
    [[ "$output" == *"hello, please help me with the bug"* ]]
    [[ "$output" == *"now show me what changed"* ]]
    [[ "$output" == *"/tmp/foo.py"* ]]
    [[ "$output" == *"Here's a summary of what I found."* ]]
    # pricing-based cost estimate present (some "~$X.YZ")
    [[ "$output" == *"~\$"* ]]
    # exclusions: no synthetic meta content; tool_use_result text not under User prompts
    [[ "$output" != *"<system-reminder>"* ]]
    local user_section
    user_section="$(printf '%s\n' "$output" | awk '/^## User prompts/{flag=1; next} /^## /{flag=0} flag')"
    [[ "$user_section" != *"file content here"* ]]
}

@test "generate(diverse): Edit/Write/Read files, command filtering, array-content prompt" {
    run _ccage_handoff_generate "$FIXTURES/diverse.jsonl" --stdout
    [ "$status" -eq 0 ]
    [[ "$output" == *"/tmp/x.py"* ]] && [[ "$output" == *"/tmp/y.py"* ]]
    [[ "$output" == *"git status"* ]]
    [[ "$output" == *"prompt two from array content"* ]]
    # trivial 'pwd' filtered out of the Commands section
    local commands_section
    commands_section="$(printf '%s\n' "$output" | awk '/^## Commands/{flag=1; next} /^## /{flag=0} flag')"
    [[ "$commands_section" != *"- \`pwd\`"* ]] && [[ "$commands_section" != *"- pwd"* ]]
}

@test "generate: --max-prompts keeps most-recent + elision marker; no marker when >= count" {
    run _ccage_handoff_generate "$FIXTURES/minimal.jsonl" --stdout --max-prompts 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"now show me what changed"* ]]
    [[ "$output" != *"hello, please help me with the bug"* ]]
    [[ "$output" == *"earlier prompt"* ]]
    run _ccage_handoff_generate "$FIXTURES/minimal.jsonl" --stdout --max-prompts 100
    [[ "$output" != *"earlier prompts elided"* ]]
}

@test "generate: empty session still produces a brief with placeholder sections" {
    run _ccage_handoff_generate "$FIXTURES/empty.jsonl" --stdout
    [ "$status" -eq 0 ]
    [[ "$output" == *"User prompts"* ]] && [[ "$output" == *"Files touched"* ]]
}

@test "generate: malformed-line resilience (recovers valid lines)" {
    run _ccage_handoff_generate "$FIXTURES/malformed.jsonl" --stdout
    [ "$status" -eq 0 ]
    [[ "$output" == *"first valid prompt"* ]] && [[ "$output" == *"second valid prompt"* ]]
    [[ "$output" == *"Recovered after malformed line"* ]]
}

@test "generate: default file write (dir + slug/prefix filename) and --output path" {
    # File mode auto-copies to the clipboard. Primary defense: the pbcopy stub
    # from setup() is first in the fallback chain, so wl-copy/xclip/xsel are
    # never invoked here at all -- neither of wl-copy's two hang modes can
    # fire (daemonizing while holding bats's control fd; OR, the worse one,
    # blocking in the FOREGROUND before it daemonizes at all when
    # WAYLAND_DISPLAY is set but the socket never answers -- observed live,
    # 23 minutes, 2026-07-16). That foreground case is exactly what the fd-3
    # trick below CANNOT fix, since the hang happens before wl-copy backgrounds
    # itself; the stub is what actually closes the gap. The mute + `3>&-` is
    # kept only as belt-and-braces for a machine where the stub dir somehow
    # isn't first on PATH.
    PWD=/home/u/myproj _ccage_handoff_generate "$FIXTURES/minimal.jsonl" >/dev/null 2>&1 </dev/null 3>&-
    [ -d "$CCAGE_HANDOFF_DIR" ]
    local f
    f=$(ls -t "$CCAGE_HANDOFF_DIR"/*.md 2>/dev/null | head -1)
    [ -n "$f" ]
    grep -q "Handoff: test-min-001" "$f"
    [[ "$(basename "$f")" == *"-home-u-myproj"* ]]
    [[ "$(basename "$f")" == *"test-min"* ]] && [[ "$(basename "$f")" == *".md" ]]
    # explicit --output path (also file mode → same fd-3 guard)
    local out="$BATS_TEST_TMPDIR/explicit.md"
    _ccage_handoff_generate "$FIXTURES/minimal.jsonl" --output "$out" >/dev/null 2>&1 </dev/null 3>&-
    [ -f "$out" ]
    grep -q "Handoff: test-min-001" "$out"
}

@test "generate: file mode completes promptly with the pbcopy stub (no clipboard hang)" {
    # Directly proves the fix: previously a live wl-copy foreground-hang wedged
    # this exact code path for 23 minutes. With the pbcopy stub in place the
    # whole generate-and-copy call must finish in well under that.
    SECONDS=0
    PWD=/home/u/promptcheck _ccage_handoff_generate "$FIXTURES/minimal.jsonl" >/dev/null 2>&1 </dev/null 3>&-
    [ "$SECONDS" -lt 10 ]
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
    CLAUDE_CONFIG_DIR="$config_dir" \
        run "$REPO_ROOT/bin/ccage" handoff --project "$proj_dir" --stdout
    [ "$status" -eq 0 ]
    [[ "$output" == *"test-min-001"* ]]
}

@test "bin/ccage handoff no-sessions exits 2; unknown subcommand exits 2" {
    local proj_dir="$BATS_TEST_TMPDIR/no-sessions"
    mkdir -p "$proj_dir"
    local config_dir="$BATS_TEST_TMPDIR/cfg"
    mkdir -p "$config_dir/projects"
    CLAUDE_CONFIG_DIR="$config_dir" \
        run --separate-stderr "$REPO_ROOT/bin/ccage" handoff --project "$proj_dir" --stdout
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"no sessions"* ]] || [[ "$stderr" == *"no .jsonl"* ]]

    run --separate-stderr "$REPO_ROOT/bin/ccage" garbage
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"unknown"* ]] || [[ "$stderr" == *"usage"* ]]
}

# Pricing regression guard. The 2026-05-16 table drifted badly: opus read
# $15/$75 against an actual $5/$25, every model released after that date fell
# through to the opus default (costing a Sonnet 5 session at 5x), and all
# cache-write was charged at the 5-minute 1.25x rate even though these sessions
# cache at the 1-hour 2x TTL. Each assertion below pins one of those.
@test "pricing: current rates, family globbing, derived cache rates, TTL split" {
    # Corrected input/output table.
    [ "$(_ccage_handoff_price_input claude-opus-4-8)" = 5 ]
    [ "$(_ccage_handoff_price_output claude-opus-4-8)" = 25 ]
    [ "$(_ccage_handoff_price_input claude-sonnet-5)" = 3 ]
    [ "$(_ccage_handoff_price_output claude-sonnet-5)" = 15 ]
    [ "$(_ccage_handoff_price_input claude-haiku-4-5)" = 1 ]
    [ "$(_ccage_handoff_price_output claude-haiku-4-5)" = 5 ]
    [ "$(_ccage_handoff_price_input claude-fable-5)" = 10 ]
    [ "$(_ccage_handoff_price_output claude-fable-5)" = 50 ]

    # A suffixed id (how a 1M-context session reports itself) must match its
    # family rather than falling through to the default.
    [ "$(_ccage_handoff_price_input 'claude-opus-4-8[1m]')" = 5 ]

    # Unknown/future model falls back to the CURRENT opus tier.
    [ "$(_ccage_handoff_price_input some-unreleased-model)" = 5 ]
    [ "$(_ccage_handoff_price_output some-unreleased-model)" = 25 ]

    # Cache rates are derived from input, never hand-maintained.
    [ "$(_ccage_handoff_price_cache_write claude-opus-4-8)" = 6.25 ]
    [ "$(_ccage_handoff_price_cache_write_1h claude-opus-4-8)" = 10 ]
    [ "$(_ccage_handoff_price_cache_read claude-opus-4-8)" = 0.5 ]

    # 1M tokens in each single bucket, priced independently.
    run _ccage_handoff_cost 0 0 1000000 0 0 claude-opus-4-8
    [ "$output" = '$6.25' ]
    run _ccage_handoff_cost 0 0 0 1000000 0 claude-opus-4-8
    [ "$output" = '$10.00' ]   # 1-hour TTL is 1.6x the 5-minute rate

    # All five components together: 5 + 25 + 6.25 + 10 + 0.5.
    run _ccage_handoff_cost 1000000 1000000 1000000 1000000 1000000 claude-opus-4-8
    [ "$output" = '$46.75' ]

    # Sonnet 5 must not be costed at opus rates (the headline regression).
    run _ccage_handoff_cost 1000000 0 0 0 0 claude-sonnet-5
    [ "$output" = '$3.00' ]
}

# An older transcript carries only `cache_creation_input_tokens` with no per-TTL
# breakdown. Those tokens must still be billed — attributed to the cheaper
# 5-minute bucket rather than silently dropped or invented as a premium.
@test "collect: cache-write TTL split, with fallback for pre-split transcripts" {
    local split="$BATS_TEST_TMPDIR/split.jsonl"
    printf '%s\n' '{"type":"assistant","sessionId":"s1","timestamp":"2026-07-20T10:00:00Z","message":{"model":"claude-opus-4-8","usage":{"cache_creation_input_tokens":300,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200}}}}' > "$split"
    run _ccage_handoff_collect "$split"
    [[ "$output" == *'"cw5":100'* ]]
    [[ "$output" == *'"cw1":200'* ]]

    # Pre-split transcript: exactly 1M cache-creation tokens, no breakdown.
    # Sized so the resulting dollar figure is unambiguous rather than rounding
    # to $0.00 and proving nothing.
    local unsplit="$BATS_TEST_TMPDIR/unsplit.jsonl"
    printf '%s\n' '{"type":"assistant","sessionId":"s2","timestamp":"2026-07-20T10:00:00Z","message":{"model":"claude-opus-4-8","usage":{"cache_creation_input_tokens":1000000}}}' > "$unsplit"
    run _ccage_handoff_collect "$unsplit"
    [[ "$output" == *'"cw":1000000'* ]]
    [[ "$output" == *'"cw5":0'* ]]
    [[ "$output" == *'"cw1":0'* ]]

    # The fallback lives in the generate path: those 1M tokens must be billed at
    # the 5-minute rate ($6.25), NOT dropped ($0.00) and NOT charged the 1-hour
    # premium ($10.00). All three outcomes are distinguishable here.
    run _ccage_handoff_generate "$unsplit" --stdout
    [[ "$output" == *'~$6.25'* ]]
}
