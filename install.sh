#!/usr/bin/env bash
# ccage installer. Idempotent. Installs the isolation wrapper into the
# current user's shell rc directory without editing the main rc file.
#
# Files installed:
#   <rcd>/claude-isolation.sh     — wrapper (config-dir pivot, bootstrapping)
#   <rcd>/claude-ccusage.sh       — ccusage-all aggregator (independent)
#   <prefix>/share/ccage/ccage-handoff.sh — handoff brief generator library
#   <prefix>/share/ccage/ccage-doctor.sh  — doctor (backfill + worklist) library
#   <prefix>/share/ccage/ccage-enable-mcp.sh — enable-mcp/disable-mcp library
#   <prefix>/bin/ccage            — CLI dispatcher (uses the libraries)
#   <prefix>/bin/ccage-auto       — autonomous context manager (python3 pty wrapper)
#   <prefix>/share/ccage/lib/ccb_types.py      — circuit-breaker types/config lib
#   <prefix>/share/ccage/lib/subagent_watch.py — circuit-breaker watcher lib
#   <prefix>/bin/ccb-report       — circuit-breaker ledger evaluation report CLI
#   ~/.claude/hooks/resume_autoload.sh      — SessionStart auto-read hook
#   ~/.claude/hooks/resume_budget_check.sh  — PostToolUse RESUME budget guard
#   <share-from>/skills/checkpoint/         — /checkpoint skill (reaches cages
#                                             via the existing skills symlink)
#   ~/.claude/CLAUDE.md                     — short session-continuity anchor
#     (the last group is the Phase 7 "session docs" feature; skip with
#      --no-session-docs. Auto-wiring into cages stays opt-in at runtime via
#      CCAGE_SESSION_DOCS.)
#   <share-from>/skills/keepwarm/           — /keepwarm skill (Phase 8; skip
#                                             with --no-keepwarm; per-session,
#                                             user-invoked, inert otherwise)
#   <share-from>/skills/checkpoint-threshold/ — /checkpoint-threshold skill
#                                             (Phase 9; skip with
#                                             --no-checkpoint-threshold; retunes
#                                             ccage-auto live, inert otherwise)
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
#   ./install.sh --no-cli              # skip bin/ccage + handoff/doctor library
#   ./install.sh --no-session-docs     # skip hooks + /checkpoint skill + anchor
#   ./install.sh --no-keepwarm         # skip the /keepwarm skill
#   ./install.sh --no-checkpoint-threshold # skip the /checkpoint-threshold skill
#   ./install.sh --prefix DIR          # CLI/lib prefix (default: ~/.local)
#   ./install.sh --dry-run             # print what would be done, do nothing
#
# Locations:
#   bash: ~/.bashrc.d/, sourced from ~/.bashrc
#   zsh:  ~/.zshrc.d/,  sourced from ~/.zshrc
#   CLI:  <prefix>/bin/ccage, <prefix>/share/ccage/ (default prefix: ~/.local)
#
# Dependencies: bash 3.2+ or zsh 5+ (the wrapper is written bash-3.2-safe for
# stock macOS; not checked at install time), plus jq for `ccage handoff` and
# the session-docs budget hook (checked — errors with a hint if missing).

set -euo pipefail

here() { cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd; }
REPO_ROOT="$(here)"
# shellcheck source=share/ccage-lib.sh
. "$REPO_ROOT/share/ccage-lib.sh"

shell=""
dry_run=0
install_ccusage=1
install_cli=1
install_session_docs=1
install_keepwarm=1
install_checkpoint_threshold=1
prefix="$HOME/.local"

while [ $# -gt 0 ]; do
    case "$1" in
        --shell)            shell="$2"; shift 2 ;;
        --dry-run)          dry_run=1;  shift   ;;
        --no-ccusage)       install_ccusage=0; shift ;;
        --no-cli)           install_cli=0; shift ;;
        --no-session-docs)  install_session_docs=0; shift ;;
        --no-keepwarm)      install_keepwarm=0; shift ;;
        --no-checkpoint-threshold) install_checkpoint_threshold=0; shift ;;
        --prefix)           prefix="$2"; shift 2 ;;
        -h|--help)          awk '/^#/{print; next} {exit}' "$0" | sed '1d'; exit 0 ;;
        *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# ---- dependency check ------------------------------------------------------
# jq backs two parts: `ccage handoff` (CLI) and the session-docs budget hook
# (resume_budget_check.sh). Require it if EITHER is being installed — otherwise
# `--no-cli` alone would skip the check yet still deploy the jq-dependent hook.
if { [ "$install_cli" = 1 ] || [ "$install_session_docs" = 1 ]; } && ! command -v jq >/dev/null 2>&1; then
    cat >&2 <<EOF
ccage: jq is required for \`ccage handoff\` and the session-docs budget hook,
       but was not found. Install it via your package manager:
         macOS:        brew install jq
         Debian/Ubuntu: sudo apt install jq
         Fedora:       sudo dnf install jq
         Arch:         sudo pacman -S jq
       Or re-run with --no-cli --no-session-docs to skip the jq-dependent parts.
EOF
    exit 1
fi

ccage_resolve_shell
source_line="for f in \"$rcd\"/*.sh; do [ -r \"\$f\" ] && . \"\$f\"; done; unset f"

install_file() {
    local src="$1" dest="$2" mode="${3:-0644}"
    [ -f "$src" ] || { printf 'source file not found: %s\n' "$src" >&2; exit 1; }
    # Back up an existing, different target before overwriting it — a file
    # like claude-isolation.sh is sourced by every interactive shell, so a bad
    # overwrite (syntax error, unwanted downgrade) breaks every new shell, not
    # just Claude Code. Skipped when the target doesn't exist yet (fresh
    # install) or is byte-identical to what we're about to install (no-op
    # reinstall) — otherwise every re-run would litter a fresh backup.
    if [ -f "$dest" ]; then
        if cmp -s "$src" "$dest"; then
            :
        else
            local backup
            backup="$dest.pre-update-$(date +%Y%m%d-%H%M%S)"
            run cp "$dest" "$backup"
            printf 'backed up %s -> %s\n' "$dest" "$backup"
        fi
    fi
    run mkdir -p "$(dirname "$dest")"
    run cp "$src" "$dest"
    run chmod "$mode" "$dest"
    printf 'installed %s\n' "$dest"
}

install_file "$REPO_ROOT/share/claude-isolation.sh" "$rcd/claude-isolation.sh"
[ "$install_ccusage" = 1 ] && install_file "$REPO_ROOT/share/claude-ccusage.sh" "$rcd/claude-ccusage.sh"

if [ "$install_cli" = 1 ]; then
    install_file "$REPO_ROOT/share/ccage-handoff.sh"    "$prefix/share/ccage/ccage-handoff.sh"
    # Second copy of the isolation lib, beside the CLI's other libs. bin/ccage
    # sources it to reuse _ccage_config_dir_for, which is how `ccage handoff`
    # finds a project's cage from a plain shell. The <rcd> copy above is for
    # interactive shells and is not on the CLI's search path in every layout.
    install_file "$REPO_ROOT/share/claude-isolation.sh" "$prefix/share/ccage/claude-isolation.sh"
    install_file "$REPO_ROOT/share/ccage-doctor.sh"     "$prefix/share/ccage/ccage-doctor.sh"
    install_file "$REPO_ROOT/share/ccage-enable-mcp.sh" "$prefix/share/ccage/ccage-enable-mcp.sh"
    install_file "$REPO_ROOT/bin/ccage"                 "$prefix/bin/ccage"  0755
    install_file "$REPO_ROOT/bin/ccage-auto"            "$prefix/bin/ccage-auto" 0755

    # Circuit-breaker (subagent watchdog) lib + report tool. ccage-auto's
    # _load_ccb() finds the lib at share/ccage/lib in an installed layout;
    # absent (e.g. --no-cli) it degrades to a no-op, never affecting the core
    # auto-checkpointing loop.
    install_file "$REPO_ROOT/lib/ccb_types.py"      "$prefix/share/ccage/lib/ccb_types.py"
    install_file "$REPO_ROOT/lib/subagent_watch.py" "$prefix/share/ccage/lib/subagent_watch.py"
    install_file "$REPO_ROOT/bin/ccb-report"         "$prefix/bin/ccb-report" 0755

    # ccage-auto's AskUserQuestion guard goes to the fixed hooks path (like the
    # session-docs hooks) — the installed ccage-auto resolves it there, since
    # $prefix/bin/../share/hooks does not exist in an installed layout. Inert
    # unless a watched ccage-auto run registers it via a per-run --settings file.
    install_file "$REPO_ROOT/share/hooks/autonomous_ask_guard.sh" \
        "${CCAGE_HOOKS_DIR:-$HOME/.claude/hooks}/autonomous_ask_guard.sh" 0755

    # Weekly-limit floor sensor (CCAGE_AUTOCK_WEEKLY_FLOOR) — same fixed-path
    # treatment as the ask-guard above. Inert until a cage's statusLine is
    # wrapped by _ccage_seed_statusline_tee (share/claude-isolation.sh), which
    # only happens when CCAGE_AUTOCK_WEEKLY_FLOOR arms it.
    install_file "$REPO_ROOT/share/hooks/ccage-statusline-tee.sh" \
        "${CCAGE_HOOKS_DIR:-$HOME/.claude/hooks}/ccage-statusline-tee.sh" 0755

    # ccage-auto (autonomous context manager) is a python3 script. The rest of
    # ccage works without python3, so warn rather than fail.
    if ! command -v python3 >/dev/null 2>&1; then
        # shellcheck disable=SC2016  # literal `ccage-auto` in the user-facing note
        printf 'note: python3 not found — `ccage-auto` needs it; the rest of ccage is unaffected.\n'
    fi

    # PATH check — warn if $prefix/bin isn't on PATH (don't fail; just hint).
    # shellcheck disable=SC2016  # the printf below contains literal '$PATH' for the user
    case ":$PATH:" in
        *":$prefix/bin:"*) ;;
        *) printf 'note: %s/bin is not on $PATH — add it so `ccage` is callable.\n' "$prefix" ;;
    esac
fi

# ---- Phase 7 session-docs: hooks, /checkpoint skill, CLAUDE.md anchor -------
# The hook scripts go to a FIXED path (~/.claude/hooks) referenced by the seeded
# settings.json; the skill goes to the master skills dir so the existing skills
# symlink carries it into every cage. All inert until a cage opts in at runtime
# via CCAGE_SESSION_DOCS — installing them is safe and reversible.
if [ "$install_session_docs" = 1 ]; then
    hooks_dir="${CCAGE_HOOKS_DIR:-$HOME/.claude/hooks}"
    install_file "$REPO_ROOT/share/hooks/resume_autoload.sh"     "$hooks_dir/resume_autoload.sh"     0755
    install_file "$REPO_ROOT/share/hooks/resume_budget_check.sh" "$hooks_dir/resume_budget_check.sh" 0755

    share_from="${CCAGE_SHARE_FROM:-$HOME/.claude}"
    install_file "$REPO_ROOT/share/skills/checkpoint/SKILL.md"           "$share_from/skills/checkpoint/SKILL.md"
    install_file "$REPO_ROOT/share/skills/checkpoint/checkpoint-init.sh" "$share_from/skills/checkpoint/checkpoint-init.sh" 0755

    # CLAUDE.md anchor — short always-on note, marker-guarded so re-runs are safe.
    claude_md="$HOME/.claude/CLAUDE.md"
    if [ -f "$claude_md" ] && grep -qF 'ccage:session-docs:start' "$claude_md" 2>/dev/null; then
        printf 'note: %s already has the ccage session-docs anchor — not modifying\n' "$claude_md"
    elif [ "$dry_run" = 1 ]; then
        printf '+ append session-docs anchor to %s\n' "$claude_md"
    else
        mkdir -p "$(dirname "$claude_md")"
        cat >> "$claude_md" <<'ANCHOR'

<!-- ccage:session-docs:start -->
## Session continuity (ccage)
- `RESUME.md` / `CHANGELOG.md` in a repo are personal continuity files, excluded via `.git/info/exclude`. On resume, read `RESUME.md` first.
- Run `/checkpoint` before `/clear` to save state into `RESUME.md` (older detail rolls into `CHANGELOG.md`). With `CCAGE_SESSION_DOCS=1`, ccage auto-reads `RESUME.md` back after `/clear`. Use `/checkpoint --tidy` for memory hygiene.
- When the session's work is genuinely finished (not a mid-work save), run `/checkpoint --final` — it writes a `.ccage-session-done` marker so a running `/keepwarm` self-stops and an autonomous `ccage-auto` run stands down. Add `--tidy` (`/checkpoint --final --tidy`) to also tidy memory at end of day. A plain `/checkpoint` clears the marker again ("still working").
<!-- ccage:session-docs:end -->
ANCHOR
        printf 'appended session-docs anchor to %s\n' "$claude_md"
    fi
fi

# ---- Phase 8: /keepwarm skill ------------------------------------------------
# Per-session, user-invoked cache keep-warm. Reaches cages via the existing
# skills symlink, same as /checkpoint. Inert until invoked — no hooks, no
# settings.json seeding.
if [ "$install_keepwarm" = 1 ]; then
    share_from="${CCAGE_SHARE_FROM:-$HOME/.claude}"
    install_file "$REPO_ROOT/share/skills/keepwarm/SKILL.md"         "$share_from/skills/keepwarm/SKILL.md"
    install_file "$REPO_ROOT/share/skills/keepwarm/keepwarm-calc.sh" "$share_from/skills/keepwarm/keepwarm-calc.sh" 0755
fi

# ---- Phase 9: /checkpoint-threshold skill ------------------------------------
# Live retune of ccage-auto's soft/hard thresholds + pause, mid-session. A
# SKILL.md-only skill (it shells out to the `ccage-auto` CLI for all logic);
# reaches cages via the existing skills symlink. Inert until invoked.
if [ "$install_checkpoint_threshold" = 1 ]; then
    share_from="${CCAGE_SHARE_FROM:-$HOME/.claude}"
    install_file "$REPO_ROOT/share/skills/checkpoint-threshold/SKILL.md" "$share_from/skills/checkpoint-threshold/SKILL.md"
fi

if [ -f "$rc" ] && grep -qF 'Added by ccage installer' "$rc" 2>/dev/null; then
    printf 'note: %s already has the ccage source block — not modifying rc\n' "$rc"
elif [ "$dry_run" = 1 ]; then
    printf '+ append ccage source block to %s\n' "$rc"
else
    printf '\n# Added by ccage installer. Sources every *.sh in %s.\n%s\n' "$rcd" "$source_line" >> "$rc"
fi

[ -f "$rcd/claude-overrides.sh" ] || printf 'tip: cp %s/share/claude-overrides.sh.example %s/claude-overrides.sh\n     to customize per-path config dirs, per-PWD env, or settings seeding.\n' "$REPO_ROOT" "$rcd"
printf 'done. open a new shell (or: source %s) to activate.\n' "$rc"
