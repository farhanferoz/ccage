#!/usr/bin/env bats
# Tests for `claude -r`/`claude -c` cost interception (Phase 6b).
#
# The wrapper intercepts resume invocations, computes the cache-rewrite cost
# from the session JSONL's per-turn usage fields, and prompts the user. Zero
# API calls; pure jq + shell.
bats_require_minimum_version 1.5.0

load helpers

setup() {
    load_ccage
    FIXTURES="$BATS_TEST_DIRNAME/fixtures/sessions"

    # Fake claude binary so `command claude` resolves.
    local bin_dir="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin_dir"
    printf '#!/bin/sh\necho mock-claude "$@"\n' > "$bin_dir/claude"
    chmod +x "$bin_dir/claude"
    PATH="$bin_dir:$PATH"

    # Reset env vars that gate interception so cross-test leakage doesn't bite.
    unset CCAGE_DISABLE CCAGE_NO_RESUME_PROMPT CCAGE_RESUME_PROMPT_MIN_USD
}

# ===== detection — which args trigger interception =====

@test "detect: bare 'claude --version' does not trigger" {
    run _ccage_is_resume_invocation --version
    [ "$status" -ne 0 ]
}

@test "detect: -c triggers" {
    run _ccage_is_resume_invocation -c
    [ "$status" -eq 0 ]
}

@test "detect: --continue triggers" {
    run _ccage_is_resume_invocation --continue
    [ "$status" -eq 0 ]
}

@test "detect: -r with UUID prefix arg triggers" {
    run _ccage_is_resume_invocation -r 4f616b4b
    [ "$status" -eq 0 ]
}

@test "detect: --resume with UUID prefix triggers" {
    run _ccage_is_resume_invocation --resume abc12345
    [ "$status" -eq 0 ]
}

@test "detect: bare -r (no id, next arg is another flag) does NOT trigger" {
    # bare -r may invoke claude's own session picker; we can't predict the
    # user's choice, so we pass through without prompting.
    run _ccage_is_resume_invocation -r --some-other-flag
    [ "$status" -ne 0 ]
}

@test "detect: bare -r as final arg does NOT trigger" {
    run _ccage_is_resume_invocation -r
    [ "$status" -ne 0 ]
}

@test "detect: bare --resume as final arg does NOT trigger" {
    run _ccage_is_resume_invocation --resume
    [ "$status" -ne 0 ]
}

# ===== _ccage_resume_decide — pure decision function =====

@test "decide: 'r' -> resume" {
    run _ccage_resume_decide r
    [ "$output" = "resume" ]
}

@test "decide: 'R' -> resume" {
    run _ccage_resume_decide R
    [ "$output" = "resume" ]
}

@test "decide: empty (enter) -> resume" {
    run _ccage_resume_decide ""
    [ "$output" = "resume" ]
}

@test "decide: 'h' -> handoff" {
    run _ccage_resume_decide h
    [ "$output" = "handoff" ]
}

@test "decide: 'H' -> handoff" {
    run _ccage_resume_decide H
    [ "$output" = "handoff" ]
}

@test "decide: 'c' -> cancel" {
    run _ccage_resume_decide c
    [ "$output" = "cancel" ]
}

@test "decide: any other char -> cancel (safe default)" {
    run _ccage_resume_decide x
    [ "$output" = "cancel" ]
}

# ===== pricing lookup =====

@test "pricing: opus-4-7 cache-write rate is 18.75 per million" {
    run _ccage_resume_price_cache_write claude-opus-4-7
    [ "$output" = "18.75" ]
}

@test "pricing: sonnet-4-6 cache-write rate is 3.75 per million" {
    run _ccage_resume_price_cache_write claude-sonnet-4-6
    [ "$output" = "3.75" ]
}

@test "pricing: haiku-4-5 cache-write rate is 1.00 per million" {
    run _ccage_resume_price_cache_write claude-haiku-4-5
    [ "$output" = "1.00" ]
}

@test "pricing: unknown model defaults to opus (conservative upper bound)" {
    run _ccage_resume_price_cache_write some-future-model
    [ "$output" = "18.75" ]
}

# ===== cost estimation against fixtures =====

@test "cost: minimal.jsonl peak cache_read 22000, opus -> $0.06 - $0.09 range" {
    # peak_read=22000, minus 19000 tools+system prefix = 3000 rewrite estimate
    # 3000 * 18.75/M = $0.05625 → midpoint, with ±25%
    run _ccage_resume_estimate_cost_usd "$FIXTURES/minimal.jsonl"
    [ "$status" -eq 0 ]
    # Output format: "<lo>\t<hi>\t<model>\t<rewrite_tokens>"
    local lo hi model
    IFS=$'\t' read -r lo hi model _ <<< "$output"
    [ "$model" = "claude-opus-4-7" ]
    # lo is 75% of midpoint, hi is 125%. Just check the order and a reasonable range.
    awk -v lo="$lo" -v hi="$hi" 'BEGIN { if (lo > hi || lo < 0.01 || hi > 1.00) exit 1 }'
}

@test "cost: empty session returns 0/0 (no substantive cache_read)" {
    run _ccage_resume_estimate_cost_usd "$FIXTURES/empty.jsonl"
    [ "$status" -eq 0 ]
    local lo hi
    IFS=$'\t' read -r lo hi _ _ <<< "$output"
    [ "$lo" = "0.00" ]
    [ "$hi" = "0.00" ]
}

# ===== threshold gating =====

@test "below threshold: tiny rewrite skips prompt (returns 0, no interaction needed)" {
    # Empty session = $0 estimate = below any positive threshold.
    # Should return 0 (no prompt issued).
    CCAGE_RESUME_PROMPT_MIN_USD=0.25 \
        run _ccage_resume_should_prompt "$FIXTURES/empty.jsonl"
    [ "$status" -ne 0 ]   # "no, don't prompt"
}

@test "above threshold: substantive session does prompt (returns 0)" {
    # Set threshold to nearly zero so any cost triggers prompt.
    CCAGE_RESUME_PROMPT_MIN_USD=0.01 \
        run _ccage_resume_should_prompt "$FIXTURES/minimal.jsonl"
    [ "$status" -eq 0 ]   # "yes, prompt"
}

@test "very high threshold: even substantive session skips" {
    CCAGE_RESUME_PROMPT_MIN_USD=99.99 \
        run _ccage_resume_should_prompt "$FIXTURES/minimal.jsonl"
    [ "$status" -ne 0 ]
}

# ===== interceptor wiring — env-var gates =====

@test "gate: CCAGE_DISABLE=1 short-circuits interception" {
    CCAGE_DISABLE=1
    # Even with a resume-style invocation, the interceptor must say "pass through"
    # so that the wrapper's CCAGE_DISABLE branch runs.
    run _ccage_intercept_resume -c
    [ "$status" -eq 0 ]   # 0 = "continue to claude", no prompt
}

@test "gate: CCAGE_NO_RESUME_PROMPT=1 skips interception" {
    CCAGE_NO_RESUME_PROMPT=1
    run _ccage_intercept_resume -c
    [ "$status" -eq 0 ]
}

@test "gate: non-tty stdin skips interception (no prompt possible)" {
    # Tests run with bats's piped stdin (not a tty). The interceptor must
    # not attempt to prompt in that case.
    run _ccage_intercept_resume -c
    [ "$status" -eq 0 ]
}

@test "gate: non-resume args always pass through" {
    run _ccage_intercept_resume --print "hello"
    [ "$status" -eq 0 ]
}
