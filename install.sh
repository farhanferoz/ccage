#!/usr/bin/env bash
# ccage installer. Idempotent. Installs the isolation wrapper into the
# current user's shell rc directory without editing the main rc file.
#
# Files installed:
#   <rcd>/claude-isolation.sh     — wrapper (config-dir pivot, bootstrapping)
#   <rcd>/claude-ccusage.sh       — ccusage-all aggregator (independent)
#
# An example overrides file lives in the repo at share/claude-overrides.sh.example.
# Copy it to <rcd>/claude-overrides.sh if you want user-specific behavior
# (per-path config dirs, per-PWD env vars, statusline seeding, etc).
# ccage will never overwrite your overrides file.
#
# Usage:
#   ./install.sh                       # install for the current shell
#   ./install.sh --shell bash|zsh      # force a specific shell target
#   ./install.sh --no-ccusage          # skip claude-ccusage.sh
#   ./install.sh --dry-run             # print what would be done, do nothing
#
# Locations:
#   bash: ~/.bashrc.d/, sourced from ~/.bashrc
#   zsh:  ~/.zshrc.d/,  sourced from ~/.zshrc

set -euo pipefail

here() { cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd; }
REPO_ROOT="$(here)"
# shellcheck source=share/ccage-lib.sh
. "$REPO_ROOT/share/ccage-lib.sh"

shell=""
dry_run=0
install_ccusage=1

while [ $# -gt 0 ]; do
    case "$1" in
        --shell)      shell="$2"; shift 2 ;;
        --dry-run)    dry_run=1;  shift   ;;
        --no-ccusage) install_ccusage=0; shift ;;
        -h|--help)    sed -n '2,22p' "$0"; exit 0 ;;
        *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
    esac
done

ccage_resolve_shell
source_line="for f in \"$rcd\"/*.sh; do [ -r \"\$f\" ] && . \"\$f\"; done; unset f"

install_file() {
    local src="$1" dest="$2"
    [ -f "$src" ] || { printf 'source file not found: %s\n' "$src" >&2; exit 1; }
    run mkdir -p "$(dirname "$dest")"
    run cp "$src" "$dest"
    run chmod 0644 "$dest"
    printf 'installed %s\n' "$dest"
}

install_file "$REPO_ROOT/share/claude-isolation.sh" "$rcd/claude-isolation.sh"
[ "$install_ccusage" = 1 ] && install_file "$REPO_ROOT/share/claude-ccusage.sh" "$rcd/claude-ccusage.sh"

if [ -f "$rc" ] && grep -qF "$rcd" "$rc" 2>/dev/null; then
    printf 'note: %s already references %s — not modifying rc\n' "$rc" "$rcd"
elif [ "$dry_run" = 1 ]; then
    printf '+ append ccage source block to %s\n' "$rc"
else
    printf '\n# Added by ccage installer. Sources every *.sh in %s.\n%s\n' "$rcd" "$source_line" >> "$rc"
fi

[ -f "$rcd/claude-overrides.sh" ] || printf 'tip: cp %s/share/claude-overrides.sh.example %s/claude-overrides.sh\n     to customize per-path config dirs, per-PWD env, or settings seeding.\n' "$REPO_ROOT" "$rcd"
printf 'done. open a new shell (or: source %s) to activate.\n' "$rc"
