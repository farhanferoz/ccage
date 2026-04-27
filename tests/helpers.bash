# shellcheck shell=bash
# Shared fixtures for ccage bats tests.

load_ccage() {
    # Source the isolation wrapper with a temp root so tests never touch $HOME.
    CCAGE_ROOT="$BATS_TEST_TMPDIR"
    export CCAGE_ROOT
    # shellcheck source=../share/claude-isolation.sh disable=SC1091
    source "$BATS_TEST_DIRNAME/../share/claude-isolation.sh"
}

