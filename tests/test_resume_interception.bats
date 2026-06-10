#!/usr/bin/env bats
# Tests for `claude -r`/`claude -c` cost interception (Phase 6b).
#
# The wrapper intercepts resume invocations, computes the cache-rewrite cost
# from the session JSONL's per-turn usage fields, and prompts the user. Zero
# API calls; pure jq + shell. Pure-function cases are grouped one test per
# function (all inputs inside) to keep the suite lean.
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

    unset CCAGE_DISABLE CCAGE_NO_RESUME_PROMPT CCAGE_RESUME_PROMPT_MIN_USD
}

# ===== detection — which args trigger interception =====

@test "detect: -c / --continue / -r <id> / --resume <id> all trigger" {
    for a in "-c" "--continue"; do
        run _ccage_is_resume_invocation "$a"; [ "$status" -eq 0 ]
    done
    run _ccage_is_resume_invocation -r 4f616b4b;     [ "$status" -eq 0 ]
    run _ccage_is_resume_invocation --resume abc12345; [ "$status" -eq 0 ]
}

@test "detect: --version and bare -r/--resume (no id) do NOT trigger" {
    # bare -r may invoke claude's own session picker; we can't predict the
    # user's choice, so we pass through without prompting.
    run _ccage_is_resume_invocation --version;            [ "$status" -ne 0 ]
    run _ccage_is_resume_invocation -r --some-other-flag; [ "$status" -ne 0 ]
    run _ccage_is_resume_invocation -r;                   [ "$status" -ne 0 ]
    run _ccage_is_resume_invocation --resume;             [ "$status" -ne 0 ]
}

# ===== _ccage_resume_decide — pure decision function =====

@test "decide: r/R/empty→resume, h/H→handoff, c/other→cancel (safe default)" {
    for i in r R ""; do run _ccage_resume_decide "$i"; [ "$output" = "resume" ]; done
    for i in h H;     do run _ccage_resume_decide "$i"; [ "$output" = "handoff" ]; done
    for i in c x;     do run _ccage_resume_decide "$i"; [ "$output" = "cancel" ]; done
}

# ===== pricing lookup =====

@test "pricing: per-model cache-write rates; unknown defaults to opus" {
    run _ccage_resume_price_cache_write claude-opus-4-7;   [ "$output" = "18.75" ]
    run _ccage_resume_price_cache_write claude-sonnet-4-6; [ "$output" = "3.75" ]
    run _ccage_resume_price_cache_write claude-haiku-4-5;  [ "$output" = "1.00" ]
    run _ccage_resume_price_cache_write some-future-model; [ "$output" = "18.75" ]  # conservative
}

# ===== cost estimation against fixtures =====

@test "cost: substantive session yields an ordered range; empty session is 0/0" {
    run _ccage_resume_estimate_cost_usd "$FIXTURES/minimal.jsonl"
    [ "$status" -eq 0 ]
    # Output: "<lo>\t<hi>\t<model>\t<rewrite_tokens>"
    local lo hi model
    IFS=$'\t' read -r lo hi model _ <<< "$output"
    [ "$model" = "claude-opus-4-7" ]
    awk -v lo="$lo" -v hi="$hi" 'BEGIN { if (lo > hi || lo < 0.01 || hi > 1.00) exit 1 }'

    run _ccage_resume_estimate_cost_usd "$FIXTURES/empty.jsonl"
    [ "$status" -eq 0 ]
    IFS=$'\t' read -r lo hi _ _ <<< "$output"
    [ "$lo" = "0.00" ] && [ "$hi" = "0.00" ]
}

# ===== threshold gating =====

@test "threshold: below skips, above prompts, very-high skips" {
    CCAGE_RESUME_PROMPT_MIN_USD=0.25 run _ccage_resume_should_prompt "$FIXTURES/empty.jsonl"
    [ "$status" -ne 0 ]                                   # $0 < threshold → no prompt
    CCAGE_RESUME_PROMPT_MIN_USD=0.01 run _ccage_resume_should_prompt "$FIXTURES/minimal.jsonl"
    [ "$status" -eq 0 ]                                   # cost ≥ threshold → prompt
    CCAGE_RESUME_PROMPT_MIN_USD=99.99 run _ccage_resume_should_prompt "$FIXTURES/minimal.jsonl"
    [ "$status" -ne 0 ]                                   # threshold above any cost → skip
}

# ===== interceptor wiring — env-var + tty gates all pass through =====

@test "gates pass through: CCAGE_DISABLE, CCAGE_NO_RESUME_PROMPT, non-tty, non-resume" {
    CCAGE_DISABLE=1 run _ccage_intercept_resume -c;            [ "$status" -eq 0 ]
    CCAGE_NO_RESUME_PROMPT=1 run _ccage_intercept_resume -c;   [ "$status" -eq 0 ]
    run _ccage_intercept_resume -c;                            [ "$status" -eq 0 ]  # non-tty bats stdin
    run _ccage_intercept_resume --print "hello";              [ "$status" -eq 0 ]  # non-resume args
}
