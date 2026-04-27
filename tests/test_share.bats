#!/usr/bin/env bats
# Tests for CCAGE_SHARE_FROM / CCAGE_SHARE_DIRS selective sharing — Phase 3b.
bats_require_minimum_version 1.5.0

load helpers

setup() {
    load_ccage
    unset CCAGE_SHARE_FROM
    unset CCAGE_SHARE_DIRS

    # Fake master dir with all three default share targets.
    master="$BATS_TEST_TMPDIR/master"
    mkdir -p "$master/commands" "$master/skills/bar" "$master/agents"
    touch "$master/commands/foo.md" "$master/agents/baz.md"

    # Config dir the tests bootstrap into.
    config_dir="$BATS_TEST_TMPDIR/.claude-proj"
    mkdir -p "$config_dir"
}

@test "CCAGE_SHARE_FROM unset: no symlinks created" {
    unset CCAGE_SHARE_FROM
    _ccage_share_dirs "$config_dir"
    [ ! -e "$config_dir/commands" ]
    [ ! -e "$config_dir/skills"   ]
    [ ! -e "$config_dir/agents"   ]
}

@test "CCAGE_SHARE_FROM set (defaults): commands/skills/agents symlinked" {
    CCAGE_SHARE_FROM="$master"
    _ccage_share_dirs "$config_dir"
    [ -L "$config_dir/commands" ]
    [ -L "$config_dir/skills"   ]
    [ -L "$config_dir/agents"   ]
    [ "$(readlink "$config_dir/commands")" = "$master/commands" ]
    [ "$(readlink "$config_dir/skills")"   = "$master/skills"   ]
    [ "$(readlink "$config_dir/agents")"   = "$master/agents"   ]
}

@test "CCAGE_SHARE_DIRS=commands: only commands linked" {
    CCAGE_SHARE_FROM="$master"
    CCAGE_SHARE_DIRS="commands"
    _ccage_share_dirs "$config_dir"
    [ -L "$config_dir/commands" ]
    [ ! -e "$config_dir/skills" ]
    [ ! -e "$config_dir/agents" ]
}

@test "target already exists as real dir: left alone, warning on stderr" {
    mkdir -p "$config_dir/commands"
    CCAGE_SHARE_FROM="$master"
    run --separate-stderr _ccage_share_dirs "$config_dir"
    [ "$status" -eq 0 ]
    # Real dir must be untouched — not a symlink.
    [ -d "$config_dir/commands" ]
    [ ! -L "$config_dir/commands" ]
    # Other targets still get linked.
    [ -L "$config_dir/skills" ]
    [ -L "$config_dir/agents" ]
    # Warning mentions the conflicting name.
    [[ "$stderr" == *"commands"* ]]
}

@test "target is symlink to different path: left alone" {
    ln -s /tmp "$config_dir/commands"
    CCAGE_SHARE_FROM="$master"
    _ccage_share_dirs "$config_dir"
    # Symlink target must remain /tmp, not the master.
    [ "$(readlink "$config_dir/commands")" = "/tmp" ]
}

@test "master subdir missing: skipped silently, no error" {
    # Remove skills from master to simulate missing subdir.
    rm -rf "$master/skills"
    CCAGE_SHARE_FROM="$master"
    run _ccage_share_dirs "$config_dir"
    [ "$status" -eq 0 ]
    [ -L "$config_dir/commands" ]
    [ ! -e "$config_dir/skills" ]
    [ -L "$config_dir/agents"   ]
}

@test "master == config dir: silent no-op, no spurious warnings" {
    CCAGE_SHARE_FROM="$master"
    run --separate-stderr _ccage_share_dirs "$master"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    # Master's own subdirs are untouched (not turned into symlinks to themselves).
    [ -d "$master/commands" ] && [ ! -L "$master/commands" ]
    [ -d "$master/agents"   ] && [ ! -L "$master/agents"   ]
    [ -d "$master/skills"   ] && [ ! -L "$master/skills"   ]
}

@test "re-running share_dirs is idempotent" {
    CCAGE_SHARE_FROM="$master"
    _ccage_share_dirs "$config_dir"
    run _ccage_share_dirs "$config_dir"
    [ "$status" -eq 0 ]
    [ -L "$config_dir/commands" ]
    [ -L "$config_dir/skills"   ]
    [ -L "$config_dir/agents"   ]
    [ "$(readlink "$config_dir/commands")" = "$master/commands" ]
}
