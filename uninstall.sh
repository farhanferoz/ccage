#!/usr/bin/env bash
# Remove ccage. Leaves per-project config dirs, credentials, and any
# user-written claude-overrides.sh alone — those are user data. Also removes the
# Phase 7 session-docs assets (hooks, /checkpoint skill, CLAUDE.md anchor) but
# never touches a repo's RESUME.md / CHANGELOG.md, nor per-cage seeded settings.
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
if [ -f "$prefix/share/ccage/ccage-doctor.sh" ]; then
    run rm -f "$prefix/share/ccage/ccage-doctor.sh"
    printf 'removed %s/share/ccage/ccage-doctor.sh\n' "$prefix"
fi
# rmdir empty share/ccage dir if we left it behind, but don't force.
if [ -d "$prefix/share/ccage" ]; then
    if [ "$dry_run" = 1 ]; then
        printf '+ rmdir %s/share/ccage (if empty)\n' "$prefix"
    elif rmdir "$prefix/share/ccage" 2>/dev/null; then
        printf 'removed empty %s/share/ccage\n' "$prefix"
    fi
fi

# Session-docs assets (Phase 7): hooks, /checkpoint skill, CLAUDE.md anchor.
hooks_dir="${CCAGE_HOOKS_DIR:-$HOME/.claude/hooks}"
for f in "$hooks_dir/resume_autoload.sh" "$hooks_dir/resume_budget_check.sh"; do
    if [ -f "$f" ]; then run rm -f "$f"; printf 'removed %s\n' "$f"; fi
done

share_from="${CCAGE_SHARE_FROM:-$HOME/.claude}"
for f in "$share_from/skills/checkpoint/SKILL.md" "$share_from/skills/checkpoint/checkpoint-init.sh"; do
    if [ -f "$f" ]; then run rm -f "$f"; printf 'removed %s\n' "$f"; fi
done
if [ -d "$share_from/skills/checkpoint" ]; then
    if [ "$dry_run" = 1 ]; then
        printf '+ rmdir %s/skills/checkpoint (if empty)\n' "$share_from"
    elif rmdir "$share_from/skills/checkpoint" 2>/dev/null; then
        printf 'removed empty %s/skills/checkpoint\n' "$share_from"
    fi
fi

# CLAUDE.md anchor — strip the marker-delimited block (mirrors the rc strip).
claude_md="$HOME/.claude/CLAUDE.md"
if [ -f "$claude_md" ] && grep -qF 'ccage:session-docs:start' "$claude_md" 2>/dev/null; then
    if [ "$dry_run" = 1 ]; then
        printf '+ strip session-docs anchor from %s\n' "$claude_md"
    else
        # Anchor the marker regexes to whole lines (^…$) so a body line that
        # merely quotes the marker text can't start/stop the skip range.
        ccage_filter_inplace "$claude_md" '
            /^<!-- ccage:session-docs:start -->$/ { skip=1 }
            skip && /^<!-- ccage:session-docs:end -->$/ { skip=0; next }
            skip { next }
            { print }
        '
        printf 'stripped session-docs anchor from %s\n' "$claude_md"
    fi
fi

[ -f "$rcd/claude-overrides.sh" ] && printf 'left %s/claude-overrides.sh in place (user data)\n' "$rcd"
# User handoff briefs and config dirs are user data — never touched.

if [ -f "$rc" ] && grep -qF 'Added by ccage installer' "$rc"; then
    if [ "$dry_run" = 1 ]; then
        printf '+ strip ccage block from %s\n' "$rc"
    else
        # Marker contract (must match install.sh):
        #   line N:    # Added by ccage installer. ...
        #   line N+1:  for f in "<rcd>"/*.sh; do ...; done; unset f
        # Remove both. Pattern-guard the source-loop deletion so a stray
        # marker line (e.g. user pasted twice, or hand-edited the loop away)
        # does NOT silently eat an unrelated following line.
        ccage_filter_inplace "$rc" '
            /^# Added by ccage installer/ { skip=1; next }
            skip && /^for f in .*; done; unset f$/ { skip=0; next }
            skip { skip=0 }
            { print }
        '
        printf 'stripped ccage block from %s\n' "$rc"
    fi
fi

printf 'done. open a new shell for the change to take effect.\n'
printf 'note: per-project config dirs under ~/.claude-* were not touched.\n'
