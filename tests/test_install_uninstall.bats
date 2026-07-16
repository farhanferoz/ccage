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
    # Session-docs paths default to ~/.claude (under FAKE_HOME); make sure the
    # runner's own ccage env doesn't redirect them elsewhere.
    unset CCAGE_SHARE_FROM CCAGE_HOOKS_DIR
}

@test "round-trip: rc restored; marker + source-loop + rcd .sh files removed; user content kept" {
    local rc="$FAKE_HOME/.bashrc"
    local original=$'# user pre-content\nexport EDITOR=vim\nalias gs=\'git status\'\n'
    printf '%s' "$original" > "$rc"

    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    [ -f "$FAKE_HOME/.bashrc.d/claude-isolation.sh" ]   # installed into rcd
    [ -f "$FAKE_HOME/.bashrc.d/claude-ccusage.sh" ]
    HOME="$FAKE_HOME" "$REPO_ROOT/uninstall.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null

    [ -f "$rc" ]
    # rc restored up to trailing blank lines (install's leading-\n separator leaves
    # a harmless cosmetic remainder).
    local actual_stripped
    actual_stripped="$(sed -e :a -e '/^$/{$d;N;ba' -e '}' "$rc")"
    [ "$actual_stripped" = "${original%$'\n'}" ] || {
        printf '=== original ===\n%s\n=== after roundtrip (raw) ===\n' "$original"; cat "$rc"; false
    }
    # marker comment, source loop, rcd .sh files all gone; pre-content kept
    ! grep -q 'Added by ccage installer' "$rc"
    ! grep -q 'for f in.*\.sh' "$rc"
    ! grep -q "$FAKE_HOME/.bashrc.d" "$rc"
    [ ! -f "$FAKE_HOME/.bashrc.d/claude-isolation.sh" ]
    [ ! -f "$FAKE_HOME/.bashrc.d/claude-ccusage.sh" ]
    grep -qx '# user pre-content' "$rc"
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

@test "install_file: backs up an existing modified target, but not on a fresh or no-op install" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    # Fresh install: no target existed beforehand, so no backup should appear.
    ! ls "$FAKE_HOME/.bashrc.d"/claude-isolation.sh.pre-update-* >/dev/null 2>&1

    # Modify the installed target, then reinstall — must back up the old content.
    printf '# locally modified\n' >> "$FAKE_HOME/.bashrc.d/claude-isolation.sh"
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    local backup
    backup=$(ls "$FAKE_HOME/.bashrc.d"/claude-isolation.sh.pre-update-* 2>/dev/null | head -1)
    [ -n "$backup" ]
    grep -qx '# locally modified' "$backup"

    # Re-running install again (target now byte-identical to source) must not
    # add a second backup — no litter on a no-op reinstall.
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    local n
    n=$(ls "$FAKE_HOME/.bashrc.d"/claude-isolation.sh.pre-update-* 2>/dev/null | wc -l | tr -d '[:space:]')
    [ "$n" -eq 1 ]
}

@test "install --dry-run: nothing written" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --dry-run --prefix "$FAKE_HOME/.local" >/dev/null
    [ ! -e "$FAKE_HOME/.bashrc.d" ]
    [ ! -e "$FAKE_HOME/.bashrc" ]
    [ ! -e "$FAKE_HOME/.local/bin/ccage" ]
}

@test "install: bin/ccage and libraries land at prefix" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    [ -x "$FAKE_HOME/.local/bin/ccage" ]
    [ -f "$FAKE_HOME/.local/share/ccage/ccage-handoff.sh" ]
    [ -f "$FAKE_HOME/.local/share/ccage/ccage-enable-mcp.sh" ]
}

@test "install: circuit-breaker lib and ccb-report land at prefix" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    [ -f "$FAKE_HOME/.local/share/ccage/lib/subagent_watch.py" ]
    [ -f "$FAKE_HOME/.local/share/ccage/lib/ccb_types.py" ]
    [ -x "$FAKE_HOME/.local/bin/ccb-report" ]
}

@test "install --no-cli: bin/ccage and libraries not installed" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --no-cli --prefix "$FAKE_HOME/.local" >/dev/null
    [ ! -e "$FAKE_HOME/.local/bin/ccage" ]
    [ ! -e "$FAKE_HOME/.local/share/ccage/ccage-handoff.sh" ]
    [ ! -e "$FAKE_HOME/.local/share/ccage/ccage-enable-mcp.sh" ]
}

@test "uninstall: bin/ccage and libraries removed" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    HOME="$FAKE_HOME" "$REPO_ROOT/uninstall.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    [ ! -e "$FAKE_HOME/.local/bin/ccage" ]
    [ ! -e "$FAKE_HOME/.local/share/ccage/ccage-handoff.sh" ]
    [ ! -e "$FAKE_HOME/.local/share/ccage/ccage-enable-mcp.sh" ]
}

@test "installed bin/ccage handoff --help works (no source-tree access)" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    run "$FAKE_HOME/.local/bin/ccage" handoff --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

# ---- Phase 7 session-docs assets (hooks + /checkpoint skill + CLAUDE.md anchor) ----

@test "install: session-docs hooks land in ~/.claude/hooks (executable)" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    [ -x "$FAKE_HOME/.claude/hooks/resume_autoload.sh" ]
    [ -x "$FAKE_HOME/.claude/hooks/resume_budget_check.sh" ]
}

@test "install: /checkpoint skill lands in the master skills dir" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    [ -f "$FAKE_HOME/.claude/skills/checkpoint/SKILL.md" ]
    [ -x "$FAKE_HOME/.claude/skills/checkpoint/checkpoint-init.sh" ]
}

@test "install: CLAUDE.md anchor appended once and idempotent on re-run" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    [ "$(grep -c 'ccage:session-docs:start' "$FAKE_HOME/.claude/CLAUDE.md")" -eq 1 ]
}

@test "install: CLAUDE.md anchor preserves pre-existing content" {
    mkdir -p "$FAKE_HOME/.claude"
    printf '%s\n' '# my global instructions' 'be terse' > "$FAKE_HOME/.claude/CLAUDE.md"
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    grep -qx '# my global instructions' "$FAKE_HOME/.claude/CLAUDE.md"
    grep -qx 'be terse' "$FAKE_HOME/.claude/CLAUDE.md"
    grep -q 'ccage:session-docs:start' "$FAKE_HOME/.claude/CLAUDE.md"
}

@test "install --no-session-docs: hooks, skill, anchor all skipped" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --no-session-docs --prefix "$FAKE_HOME/.local" >/dev/null
    [ ! -e "$FAKE_HOME/.claude/hooks/resume_autoload.sh" ]
    [ ! -e "$FAKE_HOME/.claude/skills/checkpoint" ]
    [ ! -e "$FAKE_HOME/.claude/CLAUDE.md" ]
}

@test "install --dry-run: no session-docs files created" {
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --dry-run --prefix "$FAKE_HOME/.local" >/dev/null
    [ ! -e "$FAKE_HOME/.claude/hooks/resume_autoload.sh" ]
    [ ! -e "$FAKE_HOME/.claude/skills/checkpoint" ]
    [ ! -e "$FAKE_HOME/.claude/CLAUDE.md" ]
}

@test "uninstall: removes hooks, skill, and the CLAUDE.md anchor (keeps other content)" {
    mkdir -p "$FAKE_HOME/.claude"
    printf '%s\n' '# keep me' > "$FAKE_HOME/.claude/CLAUDE.md"
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh"   --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    HOME="$FAKE_HOME" "$REPO_ROOT/uninstall.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    [ ! -e "$FAKE_HOME/.claude/hooks/resume_autoload.sh" ]
    [ ! -e "$FAKE_HOME/.claude/hooks/resume_budget_check.sh" ]
    [ ! -e "$FAKE_HOME/.claude/skills/checkpoint/SKILL.md" ]
    ! grep -q 'ccage:session-docs:start' "$FAKE_HOME/.claude/CLAUDE.md"
    grep -qx '# keep me' "$FAKE_HOME/.claude/CLAUDE.md"
}

# F4 regression: the anchor strip must rewrite CLAUDE.md in place WITHOUT
# changing its permission bits. The old cross-filesystem mktemp+mv stamped the
# file with mktemp's 0600; ccage_filter_inplace clones the mode via `cp -p`.
# ls perm string (cut -c1-10) is identical on GNU and BSD, so this is portable.
@test "uninstall: stripping the CLAUDE.md anchor preserves file permissions" {
    mkdir -p "$FAKE_HOME/.claude"
    printf '%s\n' '# keep me' > "$FAKE_HOME/.claude/CLAUDE.md"
    chmod 0640 "$FAKE_HOME/.claude/CLAUDE.md"
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh"   --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    HOME="$FAKE_HOME" "$REPO_ROOT/uninstall.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    [ "$(ls -ld "$FAKE_HOME/.claude/CLAUDE.md" | cut -c1-10)" = "-rw-r-----" ]
}

# Dry-run must never touch the disk — including the rmdir of an empty leftover
# dir, which previously ran unconditionally.
@test "uninstall --dry-run does not rmdir empty leftover dirs" {
    mkdir -p "$FAKE_HOME/.claude/skills/checkpoint"
    mkdir -p "$FAKE_HOME/.local/share/ccage"
    HOME="$FAKE_HOME" "$REPO_ROOT/uninstall.sh" --shell bash --dry-run --prefix "$FAKE_HOME/.local" >/dev/null
    [ -d "$FAKE_HOME/.claude/skills/checkpoint" ]
    [ -d "$FAKE_HOME/.local/share/ccage" ]
}

# A symlinked CLAUDE.md (dotfile managers) must be edited THROUGH the link, not
# replaced by a regular file leaving the real target unstripped.
@test "uninstall: strips the anchor through a symlinked CLAUDE.md, keeping the link" {
    mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/dotfiles"
    printf '%s\n' '# real claude md' > "$FAKE_HOME/dotfiles/CLAUDE.md"
    ln -s "$FAKE_HOME/dotfiles/CLAUDE.md" "$FAKE_HOME/.claude/CLAUDE.md"
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh"   --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    grep -q 'ccage:session-docs:start' "$FAKE_HOME/dotfiles/CLAUDE.md"   # anchor hit the target
    HOME="$FAKE_HOME" "$REPO_ROOT/uninstall.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null
    [ -L "$FAKE_HOME/.claude/CLAUDE.md" ]                                 # link preserved
    ! grep -q 'ccage:session-docs:start' "$FAKE_HOME/dotfiles/CLAUDE.md"  # anchor stripped from target
    grep -qx '# real claude md' "$FAKE_HOME/dotfiles/CLAUDE.md"
}

# ---- unseed a per-cage settings.json on uninstall (F6) --------------------
# uninstall.sh must remove ccage's two hook entries from every cage's
# settings.json BEFORE deleting the hook scripts, or every session start in
# every cage would exec a now-missing script forever after.
@test "uninstall: removes the hook entries from a seeded cage's settings.json" {
    command -v jq >/dev/null 2>&1 || skip "jq required"
    command -v python3 >/dev/null 2>&1 || skip "python3 required"
    HOME="$FAKE_HOME" "$REPO_ROOT/install.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null

    local cage="$FAKE_HOME/.claude-fakecage"
    mkdir -p "$cage"
    printf '%s\n' "$FAKE_HOME/somerepo" > "$cage/.owning_path"
    local hooks_dir="$FAKE_HOME/.claude/hooks"
    printf '%s\n' \
        '{"statusLine":{"type":"command","command":"my-statusline"},' \
        ' "hooks":{"SessionStart":[' \
        "   {\"matcher\":\"startup\",\"hooks\":[{\"type\":\"command\",\"command\":\"bash $hooks_dir/resume_autoload.sh\"}]}," \
        '   {"matcher":"startup","hooks":[{"type":"command","command":"echo foreign"}]}' \
        ' ],"PostToolUse":[' \
        "   {\"matcher\":\"Write|Edit\",\"hooks\":[{\"type\":\"command\",\"command\":\"bash $hooks_dir/resume_budget_check.sh\"}]}" \
        ' ]}}' > "$cage/settings.json"

    HOME="$FAKE_HOME" CCAGE_ROOT="$FAKE_HOME" CCAGE_PREFIX=.claude- \
        "$REPO_ROOT/uninstall.sh" --shell bash --prefix "$FAKE_HOME/.local" >/dev/null

    ! jq -e '[.hooks.SessionStart[]?.hooks[]?.command] | any(test("resume_autoload.sh"))' \
        "$cage/settings.json" >/dev/null
    ! jq -e '.hooks.PostToolUse' "$cage/settings.json" >/dev/null 2>&1
    jq -e '[.hooks.SessionStart[]?.hooks[]?.command] | any(. == "echo foreign")' \
        "$cage/settings.json" >/dev/null
    [ "$(jq -r '.statusLine.command' "$cage/settings.json")" = "my-statusline" ]
}
