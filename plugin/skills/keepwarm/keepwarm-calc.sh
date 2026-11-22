#!/usr/bin/env bash
# /keepwarm helper — deterministic probe of the current project's newest session
# JSONL. Zero API calls (jq only). The skill (SKILL.md alongside this file) uses
# the output to warn before arming the keep-warm loop:
#   transcript=<path|none>     newest session JSONL for this project, by mtime
#   peak_cache_read=<int>      max cache_read_input_tokens seen (≈ prefix size)
#   tier=<1h|5m|unknown>       dominant prompt-cache tier across the session
#
# Usage: keepwarm-calc.sh probe [PROJECT_DIR]
# Exit: 0 on any probe (missing data degrades to none/0/unknown); 2 on usage error.
#
# Deliberately self-contained (no sourcing of ccage libs — must work when the
# CLI is not installed). The slug derivation below is therefore duplicated:
# KEEP IN SYNC with _ccage_handoff_pwd_to_slug in share/ccage-handoff.sh.

set -u

usage() { printf 'usage: %s probe [PROJECT_DIR]\n' "${0##*/}" >&2; exit 2; }

[ "${1:-}" = "probe" ] || usage
proj="${2:-$PWD}"
proj="${proj%/}"   # a trailing slash would put a stray '-' in the slug

config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# Claude Code derives project slugs from CWD by replacing EVERY non-alphanumeric
# character with `-` ("/", "_", "." all convert — KEEP IN SYNC, see prologue).
# tr, not a bracket class: macOS bash 3.2 mishandles ${var//[^…]/}.
slug=$(printf '%s' "$proj" | LC_ALL=C tr -c 'A-Za-z0-9' '-')
session_dir="$config_dir/projects/$slug"

transcript="" ls_err=""
if [ -d "$session_dir" ]; then
    # shellcheck disable=SC2012  # ls -t is fine — session UUIDs have no newlines
    transcript=$(ls -t "$session_dir"/*.jsonl 2>/dev/null | head -1)
else
    # Distinguish "no sessions yet" from "can't read the config dir" (a
    # sandboxed Bash denies reads outside the workspace — surface that instead
    # of a misleading plain `none`).
    ls_err=$(ls "$config_dir" 2>&1 >/dev/null) || true
fi

if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
    case "$ls_err" in
        *[Pp]ermission\ denied*|*[Oo]peration\ not\ permitted*)
            printf 'transcript=none\npeak_cache_read=0\ntier=unknown\nprobe_note=read-denied (sandboxed Bash?)\n' ;;
        *)
            printf 'transcript=none\npeak_cache_read=0\ntier=unknown\n' ;;
    esac
    exit 0
fi

# Single streaming pass (no slurp — transcripts can be tens of MB):
# peak cache_read + per-tier cache-write sums. Malformed lines abort jq; fall
# back to unknown rather than failing the probe.
stats=$(jq -rn '
    reduce inputs as $e ({p:0, h:0, m:0};
        .p = ([.p, ($e.message.usage.cache_read_input_tokens // 0)] | max)
      | .h += ($e.message.usage.cache_creation.ephemeral_1h_input_tokens // 0)
      | .m += ($e.message.usage.cache_creation.ephemeral_5m_input_tokens // 0))
    | "\(.p)\t\(.h)\t\(.m)"' "$transcript" 2>/dev/null) || stats=""

peak=0 h=0 m=0
if [ -n "$stats" ]; then
    IFS=$'\t' read -r peak h m <<< "$stats"
fi

tier=unknown
if [ "$h" -gt 0 ] 2>/dev/null && [ "$h" -ge "$m" ] 2>/dev/null; then
    tier=1h
elif [ "$m" -gt 0 ] 2>/dev/null; then
    tier=5m
fi

printf 'transcript=%s\npeak_cache_read=%s\ntier=%s\n' "$transcript" "$peak" "$tier"
exit 0
