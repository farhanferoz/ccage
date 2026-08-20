#!/usr/bin/env bash
# ccage SessionStart hook — emit ONE part of a session doc (RESUME / DECISIONS).
#
# WHY THIS EXISTS. Claude Code caps every hook injection path — plain stdout,
# JSON additionalContext, systemMessage, initialUserMessage — at 10,000 CHARS
# per hook output. Verified in the 2.1.237 binary: `Drp=1e4` feeding
#   async function nvt(e,t,r,n=Drp){ if(e.length<=n) return e; ... }
# called at all four sites. Above the cap the output is persisted to disk and
# only a 2,000-char preview (`$2r=2000`) reaches the model. So a session doc
# larger than ~9 KB can never be delivered whole through a single hook — the
# measured failure was a 76 KB decisions register arriving as a 2 KB preview.
#
# This script is registered N times (one command each). Each invocation emits
# one balanced slice of the file; the slices together reconstruct it.
#
# PARTS ARRIVE OUT OF ORDER — MEASURED, DO NOT "SIMPLIFY" THE LABELS AWAY.
# SessionStart hooks run CONCURRENTLY and their outputs are injected in
# COMPLETION order, not registration order. Measured 2026-08-20 against a real
# `claude -p` session: six hooks registered 1..6 but made to finish 6..1 were
# delivered 6,5,4,3,2,1 — identical result whether registered as six separate
# SessionStart entries or as one entry carrying six commands. Corroborated by
# this cage's own transcripts (autoload registered first, delivered last,
# because it is the slowest). Every part therefore carries its own framing and
# an explicit "part k/n" label, so the model can reassemble the document from
# whatever order it lands in. Ordering is NOT a property this can rely on.
#
# Usage: session_doc_chunk.sh <kind> <k> <n> [maxlines]
#   <kind>     resume | decisions. NOT a path: the file is resolved at RUN time
#              from CLAUDE_PROJECT_DIR + CCAGE_SLOT, exactly as resume_autoload
#              does. Baking an absolute path in at seed time would silently
#              deliver nothing if the repo ever moved.
#   <k>        part index, 1-based.
#   <n>        the SEEDED part count — a fixed constant, never reconciled. It
#              sets capacity (n * window chars). The number of parts actually
#              emitted is computed from the file's CURRENT size, so the file
#              may grow and shrink freely with no re-seeding; parts past the
#              end of the document simply emit nothing.
#   [maxlines] optional line cap applied BEFORE splitting (RESUME runaway
#              guard: the old "truncate at 2x budget" behaviour, preserved).
#
# Env (all optional):
#   CLAUDE_PROJECT_DIR      project root (falls back to $PWD)
#   CCAGE_SLOT              slot suffix for RESUME; validated as in the wrapper
#   CCAGE_DOC_CHUNK_CHARS   chars per part (default 8500; the cap is 10,000)
#   CLAUDE_CONFIG_DIR       cage dir, for the observability log
#
# Unit note: awk's length() counts CHARACTERS in a UTF-8 locale (gawk) and
# BYTES in BWK awk (macOS). Characters is the unit the cap is actually in — it
# is a JavaScript string length — so gawk is exact and macOS awk is
# conservative. The 15% headroom under the cap covers both, plus the one case
# neither counts the way JS does (astral-plane characters, 2 UTF-16 units).
#
# Always exits 0; a SessionStart hook must never block a session from starting.
# No `set -e`; a parse hiccup should no-op, not abort the start.

kind="${1:-}"
k="${2:-}"
n="${3:-}"
maxlines="${4:-}"

# Validated like its sibling CCAGE_DOC_CHUNKS is in the seeder. Unvalidated, a
# 0 or non-numeric value reached awk as a divisor and killed the whole run with
# "division by zero" — the register vanished from context, the hook still exited
# 0, and nothing anywhere reported it. That is the exact silent-total-loss this
# script exists to prevent, reachable from one typo in an env var.
window="${CCAGE_DOC_CHUNK_CHARS:-8500}"
case "$window" in
    ''|*[!0-9]*) window=8500 ;;
esac
{ [ "$window" -ge 500 ] && [ "$window" -le 9000 ]; } 2>/dev/null || window=8500
base="${CLAUDE_PROJECT_DIR:-$PWD}"
logf="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-doc-chunk.log"
# awk aborts a `print >> file` it cannot open and complains on stderr; a hook has
# no business writing to stderr over a log it merely wanted. Resolve an
# unwritable destination to /dev/null once, here, instead.
[ -d "${logf%/*}" ] && [ -w "${logf%/*}" ] || logf=/dev/null

# ---- observability (ratified D14/D16: a hook that logs no ALLOW path cannot
# be shown to have fired at all). Every invocation writes exactly one line,
# including the no-ops — "did all 9 parts arrive?" has to be a one-line grep,
# not transcript archaeology. Best-effort; never blocks the start.
_log() {
    printf '%s  kind=%s k=%s/%s %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "${kind:-<none>}" "${k:-?}" "${n:-?}" "$1" \
        >> "$logf" 2>/dev/null
}

# CCAGE_NO_AUTOLOAD is an opt-out from session-doc delivery. The seeder honours
# it by not REGISTERING these hooks — which does nothing for a cage that was
# already seeded, where 24 registrations keep firing and keep injecting. Checked
# here too so the opt-out actually takes effect in the cage the user set it for.
if [ -n "${CCAGE_NO_AUTOLOAD:-}" ]; then
    _log "status=noop reason=opted-out"
    exit 0
fi

# Validate k and n are positive integers, and that k is IN RANGE. A stale or
# hand-edited registration with k > n would otherwise fall through the window
# arithmetic below and re-emit content that belongs to another part.
case "${k}_${n}" in
    *[!0-9_]*|_*|*_) _log "status=noop reason=malformed-args"; exit 0 ;;
esac
if ! { [ "$k" -ge 1 ] && [ "$n" -ge 1 ] && [ "$k" -le "$n" ]; } 2>/dev/null; then
    _log "status=noop reason=index-out-of-range"
    exit 0
fi

# ---- resolve the file at RUN time (kind -> path) ----
# Closed set of variants, so it is a case with an explicit unknown arm, not a
# string comparison scattered through the script. RESUME is slot-aware and
# mirrors the wrapper's CCAGE_SLOT validation: an unsafe slot is ignored and we
# fall back to the plain file, exactly as _ccage_config_dir_for does.
case "$kind" in
    resume)
        slot=""
        case "${CCAGE_SLOT:-}" in
            "")               ;;
            *[!A-Za-z0-9_-]*) ;;   # unsafe → ignore, use plain RESUME.md
            *)                slot=".${CCAGE_SLOT}" ;;
        esac
        file="$base/RESUME${slot}.md"
        framing='RESUME — the state this session carries across /clear.'
        # RESUME runaway guard, preserved from the hook this replaced: a file
        # that has escaped its line budget degrades instead of flooding every
        # session start. Resolved HERE, at run time, from the same env var the
        # budget NOTE reads — never baked into the registration, which would
        # freeze a live setting at seed time.
        [ -n "$maxlines" ] || maxlines=$(( ${CCAGE_RESUME_BUDGET_LINES:-250} * 2 ))
        ;;
    decisions)
        file="$base/DECISIONS.md"
        framing='RATIFIED DECISIONS — in force. Do NOT re-derive or re-open one; cite what changed instead.'
        ;;
    *)
        _log "status=noop reason=unknown-kind"
        exit 0
        ;;
esac

# Missing file → silent no-op, so a repo without the doc pays nothing and a
# deleted doc stops cleanly.
if [ ! -f "$file" ]; then
    _log "status=noop reason=absent file=$file"
    exit 0
fi

# There is deliberately NO byte pre-check here to skip forking awk for parts past
# the end of a short document. There was one, keyed on `window`, and it was wrong
# the moment the per-part size stopped being `window`: parts are sized on
# `window - longest_line - 400` (see the awk below), which is SMALLER, so a
# document needs more parts than the pre-check assumed and it skipped real ones.
# Caught by the reassembly test — the register came back one part short. The
# pre-check saved ~1.2 ms per no-op part on a path that runs 24 hooks
# concurrently in ~25 ms total, so it was never worth a second, independent
# statement of how big a part is. awk decides, alone.

# Deliver the file VERBATIM (no comment stripping): the register's content is
# what the session must not re-derive, and stripping buys ~nothing (258 chars
# on the largest real file) while making "reconstruction == source" inexact.
awk -v k="$k" -v n="$n" -v window="$window" -v maxlines="${maxlines:-0}" \
    -v framing="$framing" -v kind="$kind" -v docname="${file##*/}" -v logf="$logf" -v now="$(date '+%Y-%m-%d %H:%M:%S')" '
    # maxlines caps the STORED line count, so the split must run over the capped
    # count (nlines), never awk NR (which keeps counting skipped records) — else
    # the character windows would span empty tail slots and the cap would be wrong.
    { if (maxlines > 0 && NR > maxlines) { cut_lines++; next }
      nlines++; line[nlines] = $0; lens[nlines] = length($0) + 1; total += lens[nlines]
      if (lens[nlines] > maxlen) maxlen = lens[nlines] }
    END {
        status = "emit"
        if (total == 0) { printf "%s  kind=%s k=%d/%d status=noop reason=empty\n", now, kind, k, n >> logf; close(logf); exit 0 }

        # ---- capacity: n parts * window chars. A document that outgrows it is
        # TRUNCATED AT THE END and says so, loudly, on the last part it does
        # deliver. This is the only lossy path in the script and it is the one
        # the whole design exists to make impossible to miss.
        # A part is assembled from WHOLE lines, so it overshoots its window by up
        # to one line. Sizing on the window alone lets a part reach window +
        # longest-line: MEASURED, a 102,372-char register with 1,911-char lines
        # produced a 10,246-char part — past the 10,000 cap, so that part gets
        # replaced by a 2,000-char preview, silently, which is the exact failure
        # this script exists to prevent. Not an exotic shape either: the ccage
        # DECISIONS.md register has a 1,677-char line, because its house style
        # is one long line per decision. Size on the room a part can actually
        # occupy; 400 covers the label, end marker and any warning.
        # (No apostrophes in this awk program: it is single-quoted in the shell.)
        # Cap how much ONE outlier line is allowed to shrink the window. Sizing
        # on the raw maximum lets a single pathological line destroy delivery of
        # the entire document: MEASURED on a 57,729-char register containing one
        # 9,555-char line, eff collapsed to its 500 floor, capacity to 6,000, and
        # 11 of 12 parts emitted a label and no content at all while ~52,000
        # chars were truncated away. Bounding the outlier keeps the rest of the
        # document deliverable; the part that actually holds the long line still
        # breaches the cap and still says so.
        capline = maxlen
        if (capline > int(window / 2)) capline = int(window / 2)
        eff = window - capline - 400
        if (eff < 500) eff = 500
        capacity = n * eff
        dropped = 0
        if (total > capacity) {
            # One pass: when the loop breaks at line i, acc is the cumulative
            # sum THROUGH i, so the sum through cut = i-1 is acc - lens[i]. No
            # second pass needed. The clamp is the one case that has to be
            # spelled out: if line 1 alone busts capacity we keep it anyway, and
            # the kept sum is lens[1], not zero.
            acc = 0; cut = nlines
            for (i = 1; i <= nlines; i++) {
                acc += lens[i]
                if (acc > capacity) { cut = i - 1; acc -= lens[i]; break }
            }
            if (cut < 1) { cut = 1; acc = lens[1] }
            dropped = total - acc
            nlines = cut; total = acc
            status = "emit-truncated"
        }

        # ---- how many parts this document ACTUALLY needs right now. Fixed n is
        # the seeded capacity; parts is what the current file fills, so growth
        # and shrinkage need no re-seeding and the labels never lie about the
        # count. k > parts means this part sits past the end of the document.
        parts = int((total + eff - 1) / eff)
        if (parts < 1) parts = 1
        if (parts > n) parts = n
        if (k > parts) { printf "%s  kind=%s k=%d/%d status=noop reason=past-eof parts=%d\n", now, kind, k, n, parts >> logf; close(logf); exit 0 }

        # Character window for part k of parts: a line belongs to exactly ONE
        # part. Line i (cumulative chars cum(i)) goes to part k iff
        #   (k-1)*W < cum(i) <= k*W,  W = total/parts.
        # begin_line = first line with cum > (k-1)*W; end_line = last line with
        # cum <= k*W. This is the partition that cannot overlap or gap even when
        # a window boundary falls strictly inside a single line.
        # (k-1)*W <= k*W, so the lower bound is always crossed no later than the
        # upper one in the SAME forward scan — one pass finds both.
        lo = (k - 1) * total / parts; hi = k * total / parts
        begin_line = 0; end_line = nlines; acc = 0
        for (i = 1; i <= nlines; i++) {
            acc += lens[i]
            if (begin_line == 0 && acc > lo) begin_line = i
            if (acc > hi) { end_line = i - 1; break }
        }
        if (begin_line == 0) begin_line = 1

        part_bytes = 0
        for (i = begin_line; i <= end_line && i <= nlines; i++) part_bytes += lens[i]
        # A part with no lines in its window has nothing to say. Emitting a label
        # and an end marker around nothing is 200 chars of noise per part, and it
        # invites the reader to hunt for content that was never there — parts
        # already arrive out of order, so an empty one reads like a loss.
        if (part_bytes == 0) { printf "%s  kind=%s k=%d/%d status=noop reason=empty-window parts=%d\n", now, kind, k, n, parts >> logf; close(logf); exit 0 }
        # EVERY loss notice goes BEFORE the content, never after it. A notice
        # printed at the end of a part is only read if the part survives whole —
        # and a part that reports loss is exactly the kind that may be over the
        # cap and get replaced by its first 2,000 chars, taking the notice with
        # it. I could not construct that at the shipped defaults, so this is
        # hardening against a shape rather than a fix for a reproduced case; it
        # costs two lines and removes the class.
        if (cut_lines > 0 && k == parts) {
            printf "*** NOTE: %s was truncated at %d lines for injection (%d more on disk) — run /checkpoint to trim it. ***\n",
                   docname, maxlines, cut_lines
        }
        if (dropped > 0 && k == parts) {
            printf "*** WARNING: %s is %d chars and this cage delivers at most %d (%d parts x %d). The LAST %d chars of the document were NOT delivered this session. Retire spent entries to CHANGELOG.md, or raise CCAGE_DOC_CHUNKS. ***\n",
                   docname, total + dropped, capacity, n, eff, dropped
        }
        if (part_bytes + 400 > 10000) {
            printf "*** WARNING: %s part %d/%d is %d chars, past the 10,000-char limit on what one hook can deliver, because it contains a single line of %d chars that cannot be split. Claude Code will keep only the first 2,000 chars of this part. Wrap that line in %s to fix it. ***\n",
                   docname, k, parts, part_bytes, maxlen - 1, docname
        }

        # ---- the label. Carried on EVERY part, not just the first: parts
        # arrive out of order, so a framing that rode only on part 1 would as
        # often as not be read after the content it frames.
        printf "=== %s  [%s part %d/%d — parts arrive OUT OF ORDER; reassemble by number] ===\n",
               framing, docname, k, parts

        # A line is atomic, so a line LONGER than a whole part cannot be made to
        # fit by any window arithmetic — it lands whole in one part and takes
        # that part past the cap. MEASURED: a single 20,000-char line produced a
        # 20,194-char part. Claude Code then keeps only the first 2,000 chars,
        # so the WARNING goes FIRST, before the content: emitted after it, it
        # would be truncated away with everything else and the loss would be
        # silent — which is the one thing this script must never be. Wrapping
        # the offending line in the source file is the actual remedy.
        emitted = 0
        for (i = begin_line; i <= end_line && i <= nlines; i++) { print line[i]; emitted += lens[i] }

        printf "=== end %s part %d/%d ===\n", docname, k, parts

        printf "%s  kind=%s k=%d/%d status=%s parts=%d chars=%d lines=%d-%d dropped=%d linecut=%d\n",
               now, kind, k, n, status, parts, emitted, begin_line, end_line, dropped, cut_lines >> logf
        close(logf)
    }
' "$file"

exit 0
