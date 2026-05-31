# shellcheck shell=bash
# Shared helpers for install.sh and uninstall.sh. Not installed to ~/.bashrc.d.

# dry_run must be set by the sourcing script before calling run().
run() {
    if [ "${dry_run:-0}" = 1 ]; then
        printf '+ %s\n' "$*"
    else
        "$@"
    fi
}

# Filter a file in place with an awk program ($2), preserving the file's
# permission bits and keeping the replacement atomic + on the same filesystem.
# A bare `mktemp` lands in $TMPDIR, so the follow-up `mv` is a cross-filesystem
# copy that (a) isn't atomic and (b) stamps the destination with mktemp's 0600
# mode — silently tightening a user's CLAUDE.md / rc. Instead: scratch file in
# the target's own directory, clone the target's mode onto it via `cp -p`, then
# rename. Caller handles dry-run gating; this always writes. Portable to BSD awk.
ccage_filter_inplace() {
    local target="$1" prog="$2" dir tmp link
    # If the target is a symlink (dotfile managers like stow/chezmoi/yadm do
    # this for ~/.bashrc, ~/.claude/CLAUDE.md), edit the file it points AT —
    # otherwise mv would replace the link with a regular file and leave the real
    # file unstripped. Resolve one level via POSIX readlink (no GNU readlink -f).
    if [ -L "$target" ]; then
        link=$(readlink -- "$target")
        case "$link" in
            /*) target="$link" ;;
            *)  target="$(dirname -- "$target")/$link" ;;
        esac
    fi
    dir=$(dirname -- "$target")
    tmp=$(mktemp "$dir/.ccage.XXXXXX") || return 1
    if cp -p -- "$target" "$tmp" && awk "$prog" "$target" > "$tmp"; then
        mv -f -- "$tmp" "$target"
    else
        rm -f -- "$tmp"
        return 1
    fi
}

# Sets shell, rc, rcd in the caller's scope.
# shellcheck disable=SC2034  # rc and rcd are consumed by the sourcing script
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
