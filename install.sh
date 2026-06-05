#!/usr/bin/env bash
# ccage installer. Idempotent. Installs the isolation wrapper into the
# current user's shell rc directory without editing the main rc file.
#
# Files installed:
#   <rcd>/claude-isolation.sh     — wrapper (config-dir pivot, bootstrapping)
#   <rcd>/claude-ccusage.sh       — ccusage-all aggregator (independent)
#   <prefix>/share/ccage/ccage-handoff.sh — handoff brief generator library
#   <prefix>/share/ccage/ccage-doctor.sh  — doctor (backfill + worklist) library
#   <prefix>/bin/ccage            — CLI dispatcher (uses the libraries)
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
#   ./install.sh --prefix DIR          # CLI/lib prefix (default: ~/.local)
#   ./install.sh --dry-run             # print what would be done, do nothing
#
# Locations:
#   bash: ~/.bashrc.d/, sourced from ~/.bashrc
#   zsh:  ~/.zshrc.d/,  sourced from ~/.zshrc
#   CLI:  <prefix>/bin/ccage, <prefix>/share/ccage/ (default prefix: ~/.local)
#
# Dependencies (the installer checks these and errors with a hint if missing):
#   bash 4+ or zsh 5+, plus jq (for `ccage handoff`).

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
prefix="$HOME/.local"

while [ $# -gt 0 ]; do
    case "$1" in
        --shell)            shell="$2"; shift 2 ;;
        --dry-run)          dry_run=1;  shift   ;;
        --no-ccusage)       install_ccusage=0; shift ;;
        --no-cli)           install_cli=0; shift ;;
        --no-session-docs)  install_session_docs=0; shift ;;
        --no-keepwarm)      install_keepwarm=0; shift ;;
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
    run mkdir -p "$(dirname "$dest")"
    run cp "$src" "$dest"
    run chmod "$mode" "$dest"
    printf 'installed %s\n' "$dest"
}

install_file "$REPO_ROOT/share/claude-isolation.sh" "$rcd/claude-isolation.sh"
[ "$install_ccusage" = 1 ] && install_file "$REPO_ROOT/share/claude-ccusage.sh" "$rcd/claude-ccusage.sh"

if [ "$install_cli" = 1 ]; then
    install_file "$REPO_ROOT/share/ccage-handoff.sh" "$prefix/share/ccage/ccage-handoff.sh"
    install_file "$REPO_ROOT/share/ccage-doctor.sh"  "$prefix/share/ccage/ccage-doctor.sh"
    install_file "$REPO_ROOT/bin/ccage"              "$prefix/bin/ccage"  0755

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

if [ -f "$rc" ] && grep -qF 'Added by ccage installer' "$rc" 2>/dev/null; then
    printf 'note: %s already has the ccage source block — not modifying rc\n' "$rc"
elif [ "$dry_run" = 1 ]; then
    printf '+ append ccage source block to %s\n' "$rc"
else
    printf '\n# Added by ccage installer. Sources every *.sh in %s.\n%s\n' "$rcd" "$source_line" >> "$rc"
fi

[ -f "$rcd/claude-overrides.sh" ] || printf 'tip: cp %s/share/claude-overrides.sh.example %s/claude-overrides.sh\n     to customize per-path config dirs, per-PWD env, or settings seeding.\n' "$REPO_ROOT" "$rcd"
printf 'done. open a new shell (or: source %s) to activate.\n' "$rc"
