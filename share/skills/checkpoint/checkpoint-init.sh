#!/usr/bin/env bash
# Bundled helper for the /checkpoint skill — the deterministic, scriptable parts:
# slot-aware path resolution and idempotent bootstrap (create-if-absent +
# .git/info/exclude). The merge / budget-trim / memory-tidy work is judgment and
# lives in SKILL.md (the agent does it), not here.
#
# Usage:
#   checkpoint-init.sh paths       # print  resume=<f>  and  changelog=<f>
#   checkpoint-init.sh bootstrap   # create RESUME/CHANGELOG if absent + exclude
#
# Never overwrites an existing file. Safe to re-run (idempotent). Operates on
# the current working directory.
set -u

cmd="${1:-paths}"

# ---- slot-aware filenames (component G), mirroring the wrapper's validation ---
slot=""
case "${CCAGE_SLOT:-}" in
    "")               ;;
    *[!A-Za-z0-9_-]*) ;;   # unsafe slot → ignore, use plain files
    *)                slot=".${CCAGE_SLOT}" ;;
esac
resume="RESUME${slot}.md"
changelog="CHANGELOG${slot}.md"

case "$cmd" in
    paths)
        printf 'resume=%s\nchangelog=%s\n' "$resume" "$changelog"
        ;;

    bootstrap)
        project="$(basename -- "$PWD")"
        today="$(date +%Y-%m-%d)"
        created=()

        if [ ! -e "$resume" ]; then
            cat > "$resume" <<EOF
# RESUME — $project

<!-- ccage budget: keep lean. Update the State sections in place; keep at most
     ~3 ## Session blocks — roll older ones into CHANGELOG. RESUME is auto-read
     into context on every session start, so smaller = cheaper + sharper. -->

## State

### Now
- (the single thing in flight right now)

### Threads
- (open workstream — status)

### Decisions
- (settled choice worth remembering)

### Open questions
- (unresolved question that needs an answer)

### Live jobs
- none

## Session $today
(2–5 sentences: what happened, where it stands, the obvious next step.)
EOF
            created+=("$resume")
        fi

        if [ ! -e "$changelog" ]; then
            cat > "$changelog" <<EOF
# Changelog

Newest first.

## $today
- (detail rolled out of RESUME, in plain prose)
EOF
            created+=("$changelog")
        fi

        # Exclude ONLY the files we just created, locally (.git/info/exclude,
        # never the shared .gitignore), and only inside a git repo.
        if [ "${#created[@]}" -gt 0 ] && git rev-parse --git-dir >/dev/null 2>&1; then
            ex="$(git rev-parse --git-dir)/info/exclude"
            mkdir -p "$(dirname "$ex")"
            for f in "${created[@]}"; do
                grep -qxF "$f" "$ex" 2>/dev/null || printf '%s\n' "$f" >> "$ex"
            done
        fi

        if [ "${#created[@]}" -gt 0 ]; then
            printf 'created: %s\n' "${created[*]}"
        else
            printf 'nothing to do — %s and %s already exist\n' "$resume" "$changelog"
        fi
        ;;

    *)
        printf 'usage: checkpoint-init.sh [paths|bootstrap]\n' >&2
        exit 2
        ;;
esac
