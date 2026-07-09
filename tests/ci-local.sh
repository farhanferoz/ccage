#!/usr/bin/env bash
# Reproduce the GitHub Actions CI (.github/workflows/ci.yml) locally, exactly.
#
# WHY THIS EXISTS: CI has repeatedly failed on things a *casual* local check
# missed — a truncated `shellcheck | head`, a different file list, or a step run
# on a shell we didn't exercise. This script runs the SAME commands CI runs, in
# the same order, un-truncated, and exits non-zero if any step fails. Run it
# before every push:
#
#     bash tests/ci-local.sh
#
# Keep the commands below in sync with ci.yml — if you change one, change both.
# (This file lives under tests/ and is not itself in CI's shellcheck list.)

set -u
cd "$(dirname "$0")/.." || exit 2

fail=0
step() { printf '\n=== %s ===\n' "$1"; }
ok()   { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

# 1. shellcheck — EXACT file list from ci.yml (do not truncate the output).
step "shellcheck (exact ci.yml file list)"
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck share/*.sh share/hooks/*.sh share/skills/checkpoint/*.sh \
                  share/skills/keepwarm/*.sh install.sh uninstall.sh; then
        ok "shellcheck"
    else
        bad "shellcheck"
    fi
else
    bad "shellcheck not installed (CI would run it) — install it before trusting a local pass"
fi

# 2. source smoke test — bash.
step "source smoke test (bash)"
if bash -c 'source share/claude-isolation.sh && typeset -f claude >/dev/null'; then
    ok "source smoke (bash)"
else
    bad "source smoke (bash)"
fi

# 3. source smoke test — zsh (CI runs this on the zsh matrix legs).
step "source smoke test (zsh)"
if command -v zsh >/dev/null 2>&1; then
    if zsh -ec 'source share/claude-isolation.sh && typeset -f claude >/dev/null'; then
        ok "source smoke (zsh)"
    else
        bad "source smoke (zsh)"
    fi
else
    printf 'SKIP: zsh not installed locally (CI still runs it — verify there)\n'
fi

# 4. bats — the full suite, like CI.
step "bats tests/"
if ./tests/bats/bin/bats tests/; then
    ok "bats"
else
    bad "bats"
fi

step "summary"
if [ "$fail" -eq 0 ]; then
    printf 'ALL CI-MIRROR STEPS PASSED — safe to push.\n'
else
    printf 'ONE OR MORE STEPS FAILED — fix before pushing (CI will fail otherwise).\n'
fi
exit "$fail"
