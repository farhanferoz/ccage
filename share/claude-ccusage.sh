# ccusage-all — aggregate `ccusage` output across every ccage-isolated config dir.
#
# Independent of the isolation wrapper — ships separately so you can install
# one without the other. Honors CCAGE_ROOT and CCAGE_PREFIX if set.

ccusage-all() {
    local root="${CCAGE_ROOT:-$HOME}"
    local prefix="${CCAGE_PREFIX:-.claude-}"
    local dir config_name
    for dir in "$root"/${prefix}*; do
        [ -d "$dir/projects" ] || continue
        config_name="$(basename "$dir")"
        printf '=== %s ===\n' "${config_name#${prefix}}"
        CLAUDE_CONFIG_DIR="$dir" npx -y ccusage "$@"
    done
}
