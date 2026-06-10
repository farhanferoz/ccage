#!/usr/bin/env bats
# Tests for _ccage_collect_plugin_dirs — CCAGE_PLUGINS_FROM → --plugin-dir flags.
# A "plugin dir" holds .claude-plugin/plugin.json. The collector loads a shared
# folder of plugins into every cage at launch by appending --plugin-dir flags to
# the launch's _ccage_extra_args array — no per-project install.
bats_require_minimum_version 1.5.0

load helpers

setup() {
    load_ccage
    unset CCAGE_PLUGINS_FROM
    LIB="$BATS_TEST_DIRNAME/../share/claude-isolation.sh"
    PLUG="$BATS_TEST_TMPDIR/plugins"
    mkdir -p "$PLUG"
}

make_plugin() {
    mkdir -p "$1/.claude-plugin"
    printf '%s\n' '{"name":"x","version":"0.0.1"}' > "$1/.claude-plugin/plugin.json"
}
joined() { printf '%s ' ${_ccage_extra_args[@]+"${_ccage_extra_args[@]}"}; }

@test "unset CCAGE_PLUGINS_FROM: no args" {
    _ccage_extra_args=()
    _ccage_collect_plugin_dirs
    [ "${#_ccage_extra_args[@]}" -eq 0 ]
}

@test "missing dir and empty library are both clean no-ops (no failure)" {
    CCAGE_PLUGINS_FROM="$PLUG/nope"; _ccage_extra_args=(); _ccage_collect_plugin_dirs
    [ "${#_ccage_extra_args[@]}" -eq 0 ]
    mkdir -p "$PLUG/emptylib"
    CCAGE_PLUGINS_FROM="$PLUG/emptylib"; _ccage_extra_args=(); _ccage_collect_plugin_dirs
    [ "${#_ccage_extra_args[@]}" -eq 0 ]
}

@test "library: one --plugin-dir per plugin; non-plugins skipped; spaces preserved" {
    make_plugin "$PLUG/alpha"
    make_plugin "$PLUG/with space"
    mkdir -p "$PLUG/notaplugin"            # no .claude-plugin/plugin.json
    CCAGE_PLUGINS_FROM="$PLUG"; _ccage_extra_args=(); _ccage_collect_plugin_dirs
    # count 4 (not 5) also proves "with space" stayed one argument, not two
    [ "${#_ccage_extra_args[@]}" -eq 4 ]
    [ "${_ccage_extra_args[0]}" = "--plugin-dir" ]
    [[ "$(joined)" == *"--plugin-dir $PLUG/alpha"* ]]
    [[ "$(joined)" == *"--plugin-dir $PLUG/with space"* ]]
    [[ "$(joined)" != *"notaplugin"* ]]
}

@test "single plugin dir loads just that one" {
    make_plugin "$PLUG/solo"
    CCAGE_PLUGINS_FROM="$PLUG/solo"; _ccage_extra_args=(); _ccage_collect_plugin_dirs
    [ "${#_ccage_extra_args[@]}" -eq 2 ]
    [ "${_ccage_extra_args[0]}" = "--plugin-dir" ]
    [ "${_ccage_extra_args[1]}" = "$PLUG/solo" ]
}

@test "appends to pre-existing _ccage_extra_args (does not clobber hook args)" {
    make_plugin "$PLUG/alpha"
    CCAGE_PLUGINS_FROM="$PLUG"; _ccage_extra_args=(--from-hook); _ccage_collect_plugin_dirs
    [ "${_ccage_extra_args[0]}" = "--from-hook" ]
    [ "${#_ccage_extra_args[@]}" -eq 3 ]   # --from-hook --plugin-dir <alpha>
}

# zsh aborts a function on a no-match glob by default (NOMATCH); the collector
# disables nomatch locally, so both empty and populated libraries work there too.
@test "works under zsh: empty library no-op; populated library loads all" {
    command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
    mkdir -p "$PLUG/emptyz"
    run zsh -c "source '$LIB'; CCAGE_PLUGINS_FROM='$PLUG/emptyz'; _ccage_extra_args=(); _ccage_collect_plugin_dirs; printf 'rc=%s count=%s\n' \"\$?\" \"\${#_ccage_extra_args[@]}\""
    [ "$status" -eq 0 ] && [[ "$output" == *"rc=0 count=0"* ]]
    make_plugin "$PLUG/za"
    make_plugin "$PLUG/zb"
    run zsh -c "source '$LIB'; CCAGE_PLUGINS_FROM='$PLUG'; _ccage_extra_args=(); _ccage_collect_plugin_dirs; printf 'count=%s\n' \"\${#_ccage_extra_args[@]}\""
    [ "$status" -eq 0 ] && [[ "$output" == *"count=4"* ]]
}
