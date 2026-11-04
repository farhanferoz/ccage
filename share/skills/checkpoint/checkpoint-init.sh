#!/usr/bin/env bash
# Bundled helper for the /checkpoint skill — the deterministic, scriptable parts:
# slot-aware path resolution and idempotent bootstrap (create-if-absent +
# .git/info/exclude). The merge / budget-trim / memory-tidy work is judgment and
# lives in SKILL.md (the agent does it), not here.
#
# Usage:
#   checkpoint-init.sh paths       # print  resume=<f>  and  changelog=<f>
#   checkpoint-init.sh bootstrap   # create RESUME/CHANGELOG if absent + exclude
#   checkpoint-init.sh mark-done   # write the .ccage-session-done marker (--final)
#   checkpoint-init.sh clear-done  # remove it (any non-final checkpoint)
#
# The .ccage-session-done marker is the "this session's work is really finished"
# signal that outlives /clear (which wipes context, so an in-memory flag can't
# carry it). Background helpers read it: /keepwarm self-stops and ccage-auto
# stands down once it appears. Only a terminal `/checkpoint --final` writes it;
# every ordinary checkpoint clears it (you're saving to keep going), and the
# SessionStart hook clears it on a genuinely new session so a stale marker from
# yesterday can't make today's helpers quit early.
#
# Never overwrites an existing file. Safe to re-run (idempotent). Operates on
# the current working directory.
set -u

cmd="${1:-paths}"

# The done-marker is intentionally NOT slot-scoped: it is a coarse per-directory
# "helpers may stand down" signal, and keeping one fixed name keeps every
# consumer (this script, the SessionStart hook, ccage-auto) trivially simple.
marker=".ccage-session-done"

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
- (pointer only — the rulings themselves live in DECISIONS.md, which is auto-loaded)

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

    mark-done)
        # Terminal done-signal for /checkpoint --final. First the end-of-work
        # audit (scripts/end_of_work_audit.py: git leftovers, junk files, heavy
        # synced folders, superseded images, stale paths). Findings refuse the
        # marker until fixed, or until CHECKPOINT_AUDIT_ACCEPT names why they
        # stay (recorded in the marker). Added 2026-10-17: a session marked done
        # with 12 GB of superseded images and stale data paths left behind.
        audit="$(dirname "$(readlink -f "$0")")/../../scripts/end_of_work_audit.py"
        if [ -f "$audit" ]; then
            python3 "$audit" .
            if [ $? -eq 1 ] && [ -z "${CHECKPOINT_AUDIT_ACCEPT:-}" ]; then
                printf 'NOT marked done: fix the FIX lines above, or re-run with CHECKPOINT_AUDIT_ACCEPT="<why they stay>"\n' >&2
                exit 3
            fi
        fi
        # Write the marker with a UTC timestamp (informational; consumers only
        # test existence/mtime) and keep it out of git — it's transient local
        # state, like RESUME.
        printf 'session marked done: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" > "$marker"
        [ -n "${CHECKPOINT_AUDIT_ACCEPT:-}" ] && printf 'audit findings accepted: %s\n' "$CHECKPOINT_AUDIT_ACCEPT" >> "$marker"
        if git rev-parse --git-dir >/dev/null 2>&1; then
            ex="$(git rev-parse --git-dir)/info/exclude"
            mkdir -p "$(dirname "$ex")"
            grep -qxF "$marker" "$ex" 2>/dev/null || printf '%s\n' "$marker" >> "$ex"
        fi
        printf 'marked done: %s\n' "$marker"
        ;;

    clear-done)
        # Any non-final checkpoint (plain or --tidy) means "still working" — drop
        # the marker so helpers don't stand down. Idempotent; no-op if absent.
        rm -f -- "$marker"
        printf 'cleared: %s\n' "$marker"
        ;;

    *)
        printf 'usage: checkpoint-init.sh [paths|bootstrap|mark-done|clear-done]\n' >&2
        exit 2
        ;;
esac
