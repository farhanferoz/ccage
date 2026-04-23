# Shared helpers for install.sh and uninstall.sh. Not installed to ~/.bashrc.d.

# dry_run must be set by the sourcing script before calling run().
run() {
    if [ "${dry_run:-0}" = 1 ]; then
        printf '+ %s\n' "$*"
    else
        "$@"
    fi
}

# Sets shell, rc, rcd in the caller's scope.
ccage_resolve_shell() {
    if [ -z "${shell:-}" ]; then
        case "${SHELL:-}" in
            */zsh) shell=zsh ;;
            *)     shell=bash ;;
        esac
    fi
    case "$shell" in
        bash) rc="$HOME/.bashrc"; rcd="$HOME/.bashrc.d" ;;
        zsh)  rc="$HOME/.zshrc";  rcd="$HOME/.zshrc.d"  ;;
        *) printf 'unsupported shell: %s\n' "$shell" >&2; exit 2 ;;
    esac
}
