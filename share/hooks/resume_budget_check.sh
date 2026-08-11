#!/usr/bin/env bash
# ccage PostToolUse(Write|Edit) guard — keep RESUME lean.
#
# Vendored into ccage (was a loose ~/.claude/hooks file with no repo home).
# install.sh deploys it to ~/.claude/hooks/resume_budget_check.sh; the seeded
# hooks block (see _ccage_seed_session_docs_hooks in claude-isolation.sh)
# references it by absolute path.
#
# ENFORCES as of 2026-08-10 (was advisory-only since inception).
#
# WHY THE CHANGE: this hook checks a purely MECHANICAL fact — a file's size
# against a number — and used to only print about it. Measured that day: it
# fired three times in one session and was ignored twice, while RESUME sat 38%
# over budget. An advisory hook enforcing a mechanical rule is the worst of both
# worlds; it costs tokens every time and binds nothing. The pattern that does
# work is code_hygiene_check.sh's: exit 2 so stderr is fed back to the model as
# a blocking error it must handle before moving on.
#
# PostToolUse fires AFTER the write, so this cannot prevent one. It makes the
# breach impossible to walk past, which is the available lever at this event.
#
# PROGRESS IS NEVER PUNISHED. Blocking every write to an over-budget file would
# also block the trimming that fixes it — training exactly the "ignore the hook"
# reflex this change exists to break. So a write that SHRINKS the file is only
# ever advised, never blocked; the last-seen size is kept in a small state file.
#
# Escape hatch: CCAGE_RESUME_BUDGET_MODE=observe restores advisory-only.
# Deliberately no `set -e`: a hook that aborts on a parse hiccup is worse than
# one that no-ops.
MAX=3

# Advisory note as PostToolUse JSON. jq when it is there; a hand-rolled fallback
# when it is not, because the whole point of the jq handling below is that this
# guard degrades loudly instead of disappearing. Newlines are folded — a note is
# one line by construction, and an unescaped one would produce invalid JSON.
emit_note() {
    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg m "$1" \
          '{systemMessage:$m, hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$m}}'
    else
        esc="$(printf '%s' "$1" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g')"
        printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' \
            "$esc" "$esc"
    fi
}

# Record every decision, ALLOWs included (D14). Only reached after the basename
# filter below, so this logs RESUME/DECISIONS writes and nothing else — a hook
# that exits 0 sends stderr to the debug log only, so without this an inert or
# mis-scoped guard leaves no trace anywhere. Never fails the hook.
_log() {
    d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/resume_budget_check.log"
    printf '%s %-16s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" "${2:-}" >> "$d" 2>/dev/null || true
}

input="$(cat)"
# jq FIRST, sed as the fallback — not the other way round: jq parses JSON
# correctly, sed only pattern-matches it. But stock macOS ships no jq, and
# without the fallback this guard SWITCHED ITSELF OFF SILENTLY there: no path,
# no check, no word about either (found 2026-08-11 by running it with jq off the
# PATH). A guard that is absent must never look like a guard that passed.
fp=""
command -v jq >/dev/null 2>&1 && \
    fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
if [ -z "$fp" ]; then
    fp="$(printf '%s' "$input" \
        | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi
[ -n "$fp" ] || exit 0
kind=resume
case "$(basename -- "$fp")" in
    RESUME.md|RESUME.*.md) ;;
    DECISIONS.md)          kind=decisions ;;
    *) exit 0 ;;
esac
[ -f "$fp" ] || exit 0

# Read via stdin redirection so a file_path beginning with '-' can't be parsed
# as a grep option (Claude Code supplies absolute paths, but be defensive).
n="$(grep -c '^## Session' < "$fp" 2>/dev/null)"
bytes="$(wc -c < "$fp" 2>/dev/null | tr -d '[:space:]')"
[ -n "$n" ] || n=0
[ -n "$bytes" ] || bytes=0
budget_bytes="${CCAGE_RESUME_BUDGET_BYTES:-14000}"

# Counted BEFORE the state write below, which records it.
#
# The pattern must match what a READER counts as an item, or the guard defends a
# different list from the one people maintain. `^[0-9]+\.` — the original — saw 8
# of the 11 items in this repo's own RESUME: `7b.` and `7c.` (letter suffixes,
# the normal way an item is split) and `1–3.` (an en-dash range) were invisible,
# so deleting one of them passed silently. That is precisely the silent drop this
# check exists to catch. Now: a line starting with a digit, then any non-space
# run, then a dot and a space. Verified against the live file — 11 of 11.
next_n="$(awk '/^### Next/{f=1;next} /^### /{f=0} f && /^[0-9][^[:space:]]*\.[[:space:]]/{c++} END{print c+0}' "$fp" 2>/dev/null)"

# The LABELS too, not just how many. A count can only say "you lost one"; the
# labels say WHICH — and since RESUME is git-excluded, that difference is the
# difference between a recoverable mistake and a lost one. Comma-joined; item
# labels never contain a comma or a tab.
next_labels="$(awk '/^### Next/{f=1;next} /^### /{f=0}
    f && /^[0-9][^[:space:]]*\.[[:space:]]/ { out = out (out ? "," : "") $1 }
    END { print out }' "$fp" 2>/dev/null)"

# DECISIONS.md is the same SHAPE of problem as RESUME's '### Next' — a durable,
# git-excluded list whose entries must not vanish silently — so it reuses the
# machinery below (state file, previous labels, shrink block) with a different
# item pattern. It has no byte budget and no session blocks: it is meant to grow
# when a constraint is added, and it shrinks by RETIRING entries, not by trimming.
# Ids come from `- **D<n>**` lines, which is exactly what a reader counts.
if [ "$kind" = decisions ]; then
    n=0
    budget_bytes=2147483647
    # FORMAT-TOLERANT. The first version counted only `- **D<n>**`, this repo's
    # convention. Measured 2026-08-11: two other projects created a DECISIONS.md
    # within two hours of the doctrine going machine-wide, and one of them uses a
    # different layout — so it matched zero entries and had NO protection at all,
    # while appearing guarded. Any top-level bullet is an entry; the label is its
    # D-number when there is one, otherwise a slug of its opening words, which is
    # enough to name what went missing.
    next_n="$(awk '/^- / { c++ } END { print c+0 }' "$fp" 2>/dev/null)"
    next_labels="$(awk '/^- / {
            if (match($0, /\*\*D[0-9]+\*\*/)) {
                id = substr($0, RSTART + 2, RLENGTH - 4)
            } else {
                s = $0; sub(/^- +/, "", s); gsub(/[^A-Za-z0-9]/, "", s)
                id = substr(s, 1, 12)
            }
            if (id != "") out = out (out ? "," : "") id
        } END { print out }' "$fp" 2>/dev/null)"
fi

over=0
{ [ "$n" -gt "$MAX" ] || [ "$bytes" -gt "$budget_bytes" ]; } 2>/dev/null && over=1

# --- last-seen size, so a shrinking write is recognised as progress ----------
state_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
state="$state_dir/.resume_budget_state"
prev=""; prev_next=""; prev_labels=""
if [ -r "$state" ]; then
    # ALL previous values must be read BEFORE the rewrite below — reading
    # prev_next afterwards compares the new value against itself, which silently
    # disabled the shrink check entirely (caught by the behavioural test).
    prev="$(awk -F'\t' -v p="$fp" '$1 == p { v = $2 } END { print v }' "$state" 2>/dev/null)"
    prev_next="$(awk -F'\t' -v p="$fp" '$1 == p { v = $3 } END { print v }' "$state" 2>/dev/null)"
    prev_labels="$(awk -F'\t' -v p="$fp" '$1 == p { v = $4 } END { print v }' "$state" 2>/dev/null)"
fi
if [ -d "$state_dir" ] && [ -w "$state_dir" ]; then
    tmp="$state.$$"
    # Entries for files that no longer exist are dropped on every rewrite. The
    # file otherwise only grows: this cage's held 8 entries, 7 of them dead
    # /tmp paths from old test runs (2026-08-11). Cheap, and it keeps the one
    # line that matters readable when someone inspects the state by hand.
    { if [ -r "$state" ]; then
          while IFS='	' read -r sp sb sn sl; do
              [ -n "$sp" ] || continue
              [ "$sp" = "$fp" ] && continue
              [ -e "$sp" ] || continue
              printf '%s\t%s\t%s\t%s\n' "$sp" "$sb" "$sn" "$sl"
          done < "$state"
      fi
      printf '%s\t%s\t%s\t%s\n' "$fp" "$bytes" "$next_n" "$next_labels"
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$state" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
fi

# ---- ### Next must not silently SHRINK ------------------------------------
# WHY: RESUME's `### Next` is the source of truth for pending work, and the
# measured failure (2026-08-10) is enumerating that work from MEMORY instead of
# reading it — which silently dropped 4 live items from a next-session plan.
# A checkpoint that rewrites `### Next` can drop items the same way, and RESUME
# is git-excluded, so there is no history to recover them from.
#
# The check is mechanical: count the numbered items, and block a write that
# reduces the count. It does NOT judge whether the removal was right — it forces
# one conscious look. The state is updated BEFORE the block, so an immediate
# re-issue of the same write passes: this is a confirm-once speed bump, never a
# deadlock. Legitimately finished items should be rolled to CHANGELOG.
#
# WHICH items went, not just how many. The count alone left the reader to diff a
# file they no longer have (PostToolUse fires after the write, and these files are
# git-excluded), so "unrecoverable" was literally true. Naming them makes restoring
# a copy-paste. Labels are recorded from the previous write.
missing=""
if [ -n "$prev_labels" ]; then
    for lbl in $(printf '%s' "$prev_labels" | tr ',' ' '); do
        case ",${next_labels}," in
            *",$lbl,"*) ;;
            *) missing="${missing}${missing:+ }$lbl" ;;
        esac
    done
fi

# DECISIONS gates on the LABELS, not the count — deliberately stricter than RESUME
# below. Counting alone lets a same-size swap through (drop D1, add D5: still one
# entry, and the dropped decision is gone in silence), which for a decisions ledger
# is the whole failure. Caught live-firing this guard, 2026-08-11.
if [ "$kind" = decisions ] && [ -n "$missing" ] \
   && [ "${CCAGE_RESUME_BUDGET_MODE:-}" != "observe" ]; then
    # ---- DECISIONS: a LIVE entry may not be dropped; a RETIRED one must be ----
    # The two legitimate exits are SUPERSEDED (its revisit condition fired) and
    # EMBODIED (the work landed, so the code or design doc now carries it). Both
    # leave one line in CHANGELOG.md saying which. That is the check: an id may
    # leave the resident file once it exists in the archive, and not before.
    # Without the archive half this guard would make every decision immortal —
    # the opposite failure to re-opening one, and the reason the file would
    # otherwise become a context disaster that every session pays for.
    # ANY CHANGELOG*.md sibling counts as the archive. A slot session writes
    # CHANGELOG.<slot>.md, and refusing its own archive would be a guard bug
    # rather than a save. Found 2026-08-11 while auditing this guard against the
    # standard it was written under (D14): it looked only at CHANGELOG.md.
    dir="$(dirname -- "$fp")"
    archives=""
    for a in "$dir"/CHANGELOG*.md; do
        [ -f "$a" ] && archives="${archives}${archives:+ }$a"
    done

    # NO archive file at all — the 28 projects due to migrate may have none. The
    # block is still right (a decision must not vanish unrecorded), but saying
    # "NOT ARCHIVED" there reads as a malfunction and leaves only the escape
    # hatch as a way forward, which is the failure mode being fixed elsewhere
    # today. Name the exact remedy instead.
    if [ -z "$archives" ]; then
        _log "DENY-noarchive" "$missing"
        cat >&2 <<MSG
DECISIONS lost a LIVE entry ($prev_next -> ${next_n:-0} in force): $missing
There is no CHANGELOG.md in $dir to retire it into.

A decision may leave DECISIONS.md only once its retirement is recorded somewhere
that survives. Create $dir/CHANGELOG.md with a '## Retired decisions' section and
one line per departing id, saying which route it took:
  SUPERSEDED — its revisit condition fired; say what changed.
  EMBODIED   — the work landed; name the code or doc that now carries it.
Then re-issue this same write.
MSG
        exit 2
    fi

    unarchived=""
    for lbl in $missing; do
        found=0
        for a in $archives; do
            if grep -qE "(^|[^A-Za-z0-9])${lbl}([^0-9A-Za-z]|$)" "$a" 2>/dev/null; then
                found=1
                break
            fi
        done
        [ "$found" -eq 0 ] && unarchived="${unarchived}${unarchived:+ }$lbl"
    done
    if [ -z "$unarchived" ]; then
        _log "ALLOW-retired" "$missing archived"
        emit_note "DECISIONS: ${missing} retired and found in CHANGELOG.md — allowed."
        exit 0
    fi
    _log "DENY-unarchived" "$unarchived"
    cat >&2 <<MSG
DECISIONS lost a LIVE entry ($prev_next -> ${next_n:-0} in force). Blocked once, deliberately.
NOT ARCHIVED: $unarchived

A ratified decision may leave this file by exactly two routes, and both write one
line to CHANGELOG.md first:
  SUPERSEDED — its revisit condition fired; say what changed.
  EMBODIED   — the work landed; name the code or doc that now carries it.
Anything else is how a ratified decision gets re-opened next session, which is the
failure this file exists to stop. Archive it, then re-issue this same write.
MSG
    exit 2
fi

if [ -n "$prev_next" ] && [ "${next_n:-0}" -lt "$prev_next" ] 2>/dev/null \
   && [ "${CCAGE_RESUME_BUDGET_MODE:-}" != "observe" ]; then
    _log "DENY-nextshrank" "$prev_next -> ${next_n:-0}; gone: ${missing:-?}"
    cat >&2 <<MSG
RESUME '### Next' SHRANK: $prev_next items -> ${next_n:-0}. Blocked once, deliberately.
${missing:+GONE: $missing}

'### Next' is the only durable record of pending work, and RESUME is git-excluded
— dropped items are unrecoverable. Confirm each removed item is genuinely done
(roll it to CHANGELOG.md) rather than forgotten, then re-issue this same write:
the count is already recorded, so the retry goes through.
MSG
    exit 2
fi

# ---- first write for this file: say so, do not go quiet ---------------------
# The shrink check above needs a previous count, so on a fresh cage — no state
# file — it cannot fire at all, and the FIRST checkpoint could drop every item
# in silence (live-fired 2026-08-11: rc=0, no output). The check cannot be made
# retroactive, but its absence can be made visible: announce the baseline once,
# so "the guard has nothing to compare against yet" is never mistaken for "the
# guard looked and was happy".
if [ -z "$prev_next" ] && [ "${next_n:-0}" -gt 0 ]; then
    if [ "$kind" = decisions ]; then
        emit_note "DECISIONS baseline recorded: ${next_n} in-force entries ($next_labels). No previous count existed in this cage, so nothing could be compared this time — a later write that drops one without archiving it will be blocked."
    else
        emit_note "RESUME baseline recorded: ${next_n} items in '### Next' ($next_labels). No previous count existed in this cage, so nothing could be compared this time — a later write that drops any of them will be blocked."
    fi
fi

if [ "$over" != 1 ]; then
    _log "ALLOW-underbudget" "$kind ${bytes}B, ${next_n:-0} items"
    exit 0
fi

# NOTE THE ASYMMETRY, added 2026-08-11: shipped Threads go to CHANGELOG, but a
# DECISION never does — it moves to DECISIONS.md, which is injected at session
# start. Telling the model to roll decisions into CHANGELOG is what caused a
# ratified decision to be re-opened the next day: CHANGELOG is not read at
# session start, so the advice below was itself the eviction mechanism.
msg="RESUME is ${bytes} bytes / $n session blocks (budgets: ${budget_bytes} bytes, ${MAX} blocks). Roll shipped ### Threads into CHANGELOG and move any ### Decisions to DECISIONS.md (create it; it is auto-loaded) — keep RESUME lean."

# Advisory when: explicitly in observe mode, OR this write made the file smaller
# (trimming in progress — never block the fix).
shrinking=0
if [ -n "$prev" ] && [ "$bytes" -lt "$prev" ] 2>/dev/null; then shrinking=1; fi
if [ "${CCAGE_RESUME_BUDGET_MODE:-}" = "observe" ] || [ "$shrinking" = 1 ]; then
    note="$msg"
    [ "$shrinking" = 1 ] && note="$msg (was ${prev} B — shrinking, keep going)"
    _log "ALLOW-shrinking" "${prev:-?}B -> ${bytes}B"
    emit_note "$note"
    exit 0
fi

# ENFORCE: the file is over budget and this write did not reduce it.
_log "DENY-overbudget" "${bytes}B / $n blocks"
cat >&2 <<MSG
$msg

This is a blocking error because the write did not reduce the file. Bring RESUME
back under budget now, before continuing:
  - move shipped ### Threads into CHANGELOG.md
  - move ### Decisions to DECISIONS.md — NEVER to CHANGELOG.md, which nothing
    reads at session start; DECISIONS.md is injected into every session
  - collapse handled ### Stuck-subagent alerts / agent snapshots
  - keep at most ${MAX} '## Session' blocks; older detail belongs in git history
A write that SHRINKS the file is never blocked, so trimming will go through.
MSG
exit 2
