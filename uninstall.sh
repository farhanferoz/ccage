#!/usr/bin/env bash
# Remove ccage. Leaves per-project config dirs, credentials, and any
# user-written claude-overrides.sh alone — those are user data.
#
# Usage:
#   ./uninstall.sh                   # uninstall for the current shell
#   ./uninstall.sh --shell bash|zsh  # force a specific shell target
#   ./uninstall.sh --prefix DIR      # CLI prefix (default: ~/.local)
#   ./uninstall.sh --dry-run         # print what would be done

set -euo pipefail

here() { cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd; }
# shellcheck source=share/ccage-lib.sh
. "$(here)/share/ccage-lib.sh"

shell=""
dry_run=0
prefix="$HOME/.local"

while [ $# -gt 0 ]; do
    case "$1" in
        --shell)   shell="$2"; shift 2 ;;
        --dry-run) dry_run=1;  shift   ;;
        --prefix)  prefix="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
    esac
done

ccage_resolve_shell

for f in claude-isolation.sh claude-ccusage.sh; do
    if [ -f "$rcd/$f" ]; then
        run rm -f "$rcd/$f"
        printf 'removed %s/%s\n' "$rcd" "$f"
    fi
done

# CLI dispatcher + handoff library.
if [ -f "$prefix/bin/ccage" ]; then
    run rm -f "$prefix/bin/ccage"
    printf 'removed %s/bin/ccage\n' "$prefix"
fi
if [ -f "$prefix/share/ccage/ccage-handoff.sh" ]; then
    run rm -f "$prefix/share/ccage/ccage-handoff.sh"
    printf 'removed %s/share/ccage/ccage-handoff.sh\n' "$prefix"
fi
# rmdir empty share/ccage dir if we left it behind, but don't force.
if [ -d "$prefix/share/ccage" ]; then
    rmdir "$prefix/share/ccage" 2>/dev/null && printf 'removed empty %s/share/ccage\n' "$prefix" || true
fi

[ -f "$rcd/claude-overrides.sh" ] && printf 'left %s/claude-overrides.sh in place (user data)\n' "$rcd"
# User handoff briefs and config dirs are user data — never touched.

if [ -f "$rc" ] && grep -qF 'Added by ccage installer' "$rc"; then
    if [ "$dry_run" = 1 ]; then
        printf '+ strip ccage block from %s\n' "$rc"
    else
        tmp="$(mktemp)"
        # Marker contract (must match install.sh):
        #   line N:    # Added by ccage installer. ...
        #   line N+1:  <source-loop>
        # Remove both lines. The simple "drop one line after the marker"
        # approach is robust to source-loop syntax tweaks; the previous
        # regex-based approach silently failed to match when install.sh's
        # source line was reformatted (left an orphaned `for f in` line).
        awk '
            /^# Added by ccage installer/ { skip=1; next }
            skip { skip=0; next }
            { print }
        ' "$rc" > "$tmp"
        mv "$tmp" "$rc"
        printf 'stripped ccage block from %s\n' "$rc"
    fi
fi

printf 'done. open a new shell for the change to take effect.\n'
printf 'note: per-project config dirs under ~/.claude-* were not touched.\n'
