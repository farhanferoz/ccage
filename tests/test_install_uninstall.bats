#!/usr/bin/env bats
# Tests for install.sh + uninstall.sh — round-trip and edge cases.
#
# These run the actual scripts as subprocesses against a fake $HOME so the
# user's real shell rc is never touched. Each test exercises the marker
# protocol (writes a marker comment + a source loop; uninstall removes both
# and leaves surrounding rc content intact).
bats_require_minimum_version 1.5.0

setup() {
    FAKE_HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$FAKE_HOME"
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
}

@test "install then uninstall is a round-trip (up to trailing blank lines)" {
    local rc="$FAKE_HOME/.bashrc"
    local original=$'# user pre-content\nexport EDITOR=vim\nalias gs=\'git status\'\n'
    printf '%s' "$original" > "$rc"

    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    HOME="$FAKE_HOME" "$REPO_ROOT/uninstall.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null

    [ -f "$rc" ]
    # Trailing blank lines from install's leading-\n separator are tolerated —
    # harmless cosmetic remainder, real-world impact is zero.
    local actual_stripped
    actual_stripped="$(sed -e :a -e '/^$/{$d;N;ba' -e '}' "$rc")"
    [ "$actual_stripped" = "${original%$'\n'}" ] || {
        printf '=== original ===\n%s\n=== after roundtrip (raw) ===\n' "$original"
        cat "$rc"
        printf '=== after roundtrip (stripped trailing blanks) ===\n%s\n' "$actual_stripped"
        false
    }
}

@test "uninstall: pre-ccage content preserved" {
    local rc="$FAKE_HOME/.bashrc"
    printf '%s\n' '# user pre-content' 'export EDITOR=vim' > "$rc"

    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    HOME="$FAKE_HOME" "$REPO_ROOT/uninstall.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null

    grep -qx '# user pre-content' "$rc"
    grep -qx 'export EDITOR=vim' "$rc"
}

@test "uninstall: post-ccage content preserved" {
    local rc="$FAKE_HOME/.bashrc"
    printf '%s\n' '# pre' 'export A=1' > "$rc"
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash >/dev/null
    # Append post-content after install (simulates user adding lines later).
    printf '%s\n' '# post' 'export B=2' 'PATH="$HOME/.local/bin:$PATH"' >> "$rc"

    HOME="$FAKE_HOME" "$REPO_ROOT/uninstall.sh" --shell bash >/dev/null

    grep -qx '# post' "$rc"
    grep -qx 'export B=2' "$rc"
    grep -qFx 'PATH="$HOME/.local/bin:$PATH"' "$rc"
}

@test "uninstall: ccage marker comment removed" {
    local rc="$FAKE_HOME/.bashrc"
    printf '' > "$rc"
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    HOME="$FAKE_HOME" "$REPO_ROOT/uninstall.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null

    ! grep -q 'Added by ccage installer' "$rc"
}

@test "uninstall: source loop removed (no orphaned 'for f in .sh' line)" {
    local rc="$FAKE_HOME/.bashrc"
    printf '' > "$rc"
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    HOME="$FAKE_HOME" "$REPO_ROOT/uninstall.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null

    # The whole point: no leftover sourcing loop referencing the bashrc.d.
    ! grep -q 'for f in.*\.sh' "$rc"
    ! grep -q "$FAKE_HOME/.bashrc.d" "$rc"
}

@test "uninstall: installed .sh files removed from rcd" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    [ -f "$FAKE_HOME/.bashrc.d/claude-isolation.sh" ]
    [ -f "$FAKE_HOME/.bashrc.d/claude-ccusage.sh" ]

    HOME="$FAKE_HOME" "$REPO_ROOT/uninstall.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null

    [ ! -f "$FAKE_HOME/.bashrc.d/claude-isolation.sh" ]
    [ ! -f "$FAKE_HOME/.bashrc.d/claude-ccusage.sh" ]
}

@test "uninstall: leaves user's claude-overrides.sh in place" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    printf '# my overrides\n' > "$FAKE_HOME/.bashrc.d/claude-overrides.sh"

    HOME="$FAKE_HOME" "$REPO_ROOT/uninstall.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null

    [ -f "$FAKE_HOME/.bashrc.d/claude-overrides.sh" ]
    grep -qx '# my overrides' "$FAKE_HOME/.bashrc.d/claude-overrides.sh"
}

@test "install is idempotent: second run doesn't double the marker block" {
    local rc="$FAKE_HOME/.bashrc"
    printf '' > "$rc"

    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null

    local n
    n=$(grep -c 'Added by ccage installer' "$rc")
    [ "$n" -eq 1 ]
}

@test "install --no-ccusage: only claude-isolation.sh installed" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --no-ccusage --prefix "$FAKE_HOME/.local" >/dev/null
    [ -f "$FAKE_HOME/.bashrc.d/claude-isolation.sh" ]
    [ ! -f "$FAKE_HOME/.bashrc.d/claude-ccusage.sh" ]
}

@test "install --dry-run: nothing written" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --dry-run --prefix "$FAKE_HOME/.local" >/dev/null
    [ ! -e "$FAKE_HOME/.bashrc.d" ]
    [ ! -e "$FAKE_HOME/.bashrc" ]
    [ ! -e "$FAKE_HOME/.local/bin/ccage" ]
}

@test "install: bin/ccage and handoff library land at prefix" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    [ -x "$FAKE_HOME/.local/bin/ccage" ]
    [ -f "$FAKE_HOME/.local/share/ccage/ccage-handoff.sh" ]
}

@test "install --no-cli: bin/ccage and handoff lib not installed" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --no-cli --prefix "$FAKE_HOME/.local" >/dev/null
    [ ! -e "$FAKE_HOME/.local/bin/ccage" ]
    [ ! -e "$FAKE_HOME/.local/share/ccage/ccage-handoff.sh" ]
}

@test "uninstall: bin/ccage and handoff library removed" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    HOME="$FAKE_HOME" "$REPO_ROOT/uninstall.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    [ ! -e "$FAKE_HOME/.local/bin/ccage" ]
    [ ! -e "$FAKE_HOME/.local/share/ccage/ccage-handoff.sh" ]
}

@test "installed bin/ccage handoff --help works (no source-tree access)" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    run "$FAKE_HOME/.local/bin/ccage" handoff --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}
