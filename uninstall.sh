#!/usr/bin/env bash
# Remove ccage. Leaves per-project config dirs, credentials, and any
# user-written claude-overrides.sh alone — those are user data. Also removes the
# Phase 7 session-docs assets (hooks, /checkpoint skill, CLAUDE.md anchor), the
# Phase 8 /keepwarm skill, and the Phase 9 /checkpoint-threshold skill, and
# unseeds ccage's two hook entries from every
# cage's settings.json (all other keys survive) so no cage is left executing a
# deleted hook script on session start. Never touches a repo's RESUME.md /
# CHANGELOG.md.
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
if [ -f "$prefix/bin/ccage-auto" ]; then
    run rm -f "$prefix/bin/ccage-auto"
    printf 'removed %s/bin/ccage-auto\n' "$prefix"
fi
if [ -f "$prefix/share/ccage/ccage-handoff.sh" ]; then
    run rm -f "$prefix/share/ccage/ccage-handoff.sh"
    printf 'removed %s/share/ccage/ccage-handoff.sh\n' "$prefix"
fi
if [ -f "$prefix/share/ccage/ccage-doctor.sh" ]; then
    run rm -f "$prefix/share/ccage/ccage-doctor.sh"
    printf 'removed %s/share/ccage/ccage-doctor.sh\n' "$prefix"
fi
if [ -f "$prefix/share/ccage/ccage-enable-mcp.sh" ]; then
    run rm -f "$prefix/share/ccage/ccage-enable-mcp.sh"
    printf 'removed %s/share/ccage/ccage-enable-mcp.sh\n' "$prefix"
fi
# rmdir empty share/ccage dir if we left it behind, but don't force.
if [ -d "$prefix/share/ccage" ]; then
    if [ "$dry_run" = 1 ]; then
        printf '+ rmdir %s/share/ccage (if empty)\n' "$prefix"
    elif rmdir "$prefix/share/ccage" 2>/dev/null; then
        printf 'removed empty %s/share/ccage\n' "$prefix"
    fi
fi

# Unseed the session-docs hook entries from every cage's settings.json BEFORE
# deleting the hook scripts below — otherwise every session start in every cage
# would execute a missing script (exit 127) forever after. Removes only ccage's
# two entries (matched on script basename); all other settings keys survive.
if command -v python3 >/dev/null 2>&1; then
    # shellcheck source=share/ccage-doctor.sh
    . "$(here)/share/ccage-doctor.sh"
    if [ "$dry_run" = 1 ]; then
        _ccage_doctor_main --unseed --dry-run
    else
        _ccage_doctor_main --unseed
    fi
else
    printf 'warning: python3 not found — per-cage hook entries NOT removed.\n'
    printf '         run "ccage doctor --unseed" before deleting the CLI, or remove the\n'
    printf '         resume_autoload/resume_budget_check entries from each cage settings.json.\n'
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

# /keepwarm skill (Phase 8) — same removal semantics as /checkpoint.
for f in "$share_from/skills/keepwarm/SKILL.md" "$share_from/skills/keepwarm/keepwarm-calc.sh"; do
    if [ -f "$f" ]; then run rm -f "$f"; printf 'removed %s\n' "$f"; fi
done
if [ -d "$share_from/skills/keepwarm" ]; then
    if [ "$dry_run" = 1 ]; then
        printf '+ rmdir %s/skills/keepwarm (if empty)\n' "$share_from"
    elif rmdir "$share_from/skills/keepwarm" 2>/dev/null; then
        printf 'removed empty %s/skills/keepwarm\n' "$share_from"
    fi
fi

# /checkpoint-threshold skill (Phase 9) — same removal semantics.
for f in "$share_from/skills/checkpoint-threshold/SKILL.md"; do
    if [ -f "$f" ]; then run rm -f "$f"; printf 'removed %s\n' "$f"; fi
done
if [ -d "$share_from/skills/checkpoint-threshold" ]; then
    if [ "$dry_run" = 1 ]; then
        printf '+ rmdir %s/skills/checkpoint-threshold (if empty)\n' "$share_from"
    elif rmdir "$share_from/skills/checkpoint-threshold" 2>/dev/null; then
        printf 'removed empty %s/skills/checkpoint-threshold\n' "$share_from"
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
