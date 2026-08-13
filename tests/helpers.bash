# shellcheck shell=bash
# Shared fixtures for ccage bats tests.

# The on-disk project slug, computed the way Claude Code computes it: EVERY
# non-alphanumeric character becomes "-", not just the path separators.
#
# Deliberately an INDEPENDENT implementation (python, not the shell `tr` the
# code under test uses) so a test pins the RULE rather than mirroring whatever
# the implementation happens to do.
#
# Why this is shared rather than re-written per file: `${path//\//-}` replaces
# slashes ONLY, so it agrees with the real rule exactly when the path holds no
# other punctuation. Linux bats tmpdirs (/tmp/bats-run-XXXX) satisfy that by
# luck; macOS ones do not -- /var/folders/df/djsxfhc17x95674wsm_g8s980000gn/T/...
# carries an underscore, so every fixture written under a bash-derived slug
# lands in a directory the code never looks in. That is 28 red tests on the
# macOS CI leg (2026-08-13) from one shortcut copied into three files, and the
# same rule CHANGELOG:197 already fixed once in the production code.
oracle_slug() {
    python3 -c 'import re,sys; print(re.sub(r"[^A-Za-z0-9]", "-", sys.argv[1]))' "$1"
}

load_ccage() {
    # Source the isolation wrapper with a temp root so tests never touch $HOME.
    CCAGE_ROOT="$BATS_TEST_TMPDIR"
    export CCAGE_ROOT
    # shellcheck source=../share/claude-isolation.sh disable=SC1091
    source "$BATS_TEST_DIRNAME/../share/claude-isolation.sh"
}

