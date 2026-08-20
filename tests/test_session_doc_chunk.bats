#!/usr/bin/env bats
# Tests for session_doc_chunk.sh — part-wise session-doc delivery.
#
# Claude Code caps a single hook's output at 10,000 chars, so RESUME/DECISIONS
# are delivered as N labelled parts. Five properties can actually break here;
# everything else is implied by them, so nothing else is pinned:
#   1. the parts REASSEMBLE to the source byte-for-byte (modulo a final newline:
#      a source file that does not end in one comes back with one, because any
#      line-oriented reassembly terminates its last line — the hook cannot avoid
#      that and a test cannot observe a fix for it);
#   2. no part exceeds the cap;
#   3. every part is SELF-LABELLED with its own framing and index, because parts
#      arrive in completion order, not registration order (measured);
#   4. the part count follows the CURRENT file, so a fixed registration never
#      needs reconciling — and nothing is ever dropped silently;
#   5. the file is resolved at RUN time, never from a path baked in at seed time.
bats_require_minimum_version 1.5.0

HOOK="$BATS_TEST_DIRNAME/../share/hooks/session_doc_chunk.sh"

setup() {
    REPO="$BATS_TEST_TMPDIR/repo"
    CAGE="$BATS_TEST_TMPDIR/cage"
    mkdir -p "$REPO" "$CAGE"
    unset CCAGE_SLOT CCAGE_DOC_CHUNK_CHARS CCAGE_RESUME_BUDGET_LINES
    export CLAUDE_CONFIG_DIR="$CAGE"
    export CLAUDE_PROJECT_DIR="$REPO"
    LOG="$CAGE/session-doc-chunk.log"
}

# All parts of KIND for a seeded count of 12, concatenated.
all_parts() { local k; for k in $(seq 1 12); do "$HOOK" "$1" "$k" 12; done; }
# The same with the === label lines stripped: this must equal the source.
body_of()   { all_parts "$1" | grep -v '^=== ' | grep -v '^\*\*\* '; }

# A DECISIONS.md of at least SIZE chars. Lines are numbered so a gap or a
# duplicate shows up as a diff, not merely as a size mismatch. $2 non-empty
# makes the content multi-byte, which is where gawk (chars) and BWK awk (bytes)
# disagree — a partition exact on only one of them mangles the register on
# exactly one CI leg.
make_decisions() {
    # One awk pass, not a shell loop with a `wc -c` per line: the loop cost more
    # than every assertion in this file put together.
    awk -v target="$1" -v wide="${2:-}" 'BEGIN {
        pad = ""; while (length(pad) < 55) pad = pad "y"
        while (n < target) {
            i++
            if (wide == "")
                line = sprintf("- D%d (2026-08-20) ratified line %d: %s", i, i, pad)
            else
                line = sprintf("- D%d \342\232\240 ratified \342\200\224 \302\253%d\302\273 na\303\257ve caf\303\251 %s", i, i, pad)
            print line
            n += length(line) + 1
        }
    }' > "$REPO/DECISIONS.md"
}

# ===== 1 + 2: reassembly, and the cap that forced the split =====

@test "parts reassemble byte-for-byte and none exceeds the 10,000-char cap" {
    make_decisions 90000
    body_of decisions > "$BATS_TEST_TMPDIR/recon"
    cmp "$BATS_TEST_TMPDIR/recon" "$REPO/DECISIONS.md"
    local k chars
    for k in $(seq 1 12); do
        chars=$("$HOOK" decisions "$k" 12 | wc -m)
        [ "$chars" -lt 9500 ]     # real headroom, not a part sitting on the cap
    done

    # LONG LINES. A part is built from whole lines, so it overshoots its window
    # by up to one line — and a register written one-long-line-per-decision (the
    # house style; ccage's own has a 1,677-char line) makes that overshoot big.
    # MEASURED before the fix: 102,372 chars of 1,911-char lines produced a
    # 10,246-char part, which Claude Code replaces with a 2,000-char preview.
    # Silently. That is the failure this whole hook exists to prevent, so the
    # long-line shape is pinned here rather than left to the short-line fixture.
    # 60,000 chars, not 102,000: long lines SHRINK usable capacity (a part is
    # sized window - longest_line - overhead), so 1,900-char lines take 12 parts
    # from ~102,000 chars down to ~74,000. Staying inside that is the point —
    # this case pins "no part breaches the cap", and the over-capacity path is
    # pinned separately by the truncation test below.
    awk 'BEGIN{ pad=""; while (length(pad) < 1900) pad = pad "x"
                short=""; while (length(short) < 80) short = short "y"
                n = 0; i = 0
                while (n < 60000) { i++
                  if (i % 7 == 0) { print "- **D" i "** " pad; n += length(pad) + 13 }
                  else            { print "- D" i " " short;  n += length(short) + 10 } } }' > "$REPO/DECISIONS.md"
    for k in $(seq 1 12); do
        chars=$("$HOOK" decisions "$k" 12 | wc -m)
        [ "$chars" -lt 10000 ]
    done
    body_of decisions > "$BATS_TEST_TMPDIR/recon2"
    cmp "$BATS_TEST_TMPDIR/recon2" "$REPO/DECISIONS.md"
}

@test "a line too long to fit any part warns FIRST, so the loss survives truncation" {
    # A line is atomic: one longer than a whole part lands whole and takes that
    # part past the cap, whatever the window arithmetic does. Claude Code then
    # keeps only the first 2,000 chars — so the warning has to come BEFORE the
    # content or it is truncated away with it, and the loss becomes silent.
    printf -- '- D1 %s\n' "$(awk 'BEGIN{ while (length(s) < 19980) s = s "y"; print s }')" > "$REPO/DECISIONS.md"
    run "$HOOK" decisions 3 3
    [ "$status" -eq 0 ]
    [[ "${output:0:2000}" == *"WARNING"* ]]
    [[ "$output" == *"cannot be split"* ]]
}

@test "reassembly is exact for multi-byte content too" {
    make_decisions 40000 wide
    body_of decisions > "$BATS_TEST_TMPDIR/recon"
    cmp "$BATS_TEST_TMPDIR/recon" "$REPO/DECISIONS.md"
}

# ===== 3: self-labelling, because parts arrive out of order =====

@test "every part carries its own framing and index, not just the first" {
    # A framing that rode only on part 1 would, as often as not, be read after
    # the content it frames: hook outputs are injected in COMPLETION order, so
    # part 1 arriving last is a normal case, not a corner one.
    make_decisions 30000
    local k out
    for k in 1 2 3 4; do
        out=$("$HOOK" decisions "$k" 12)
        [[ "$out" == *"RATIFIED DECISIONS"* ]]
        [[ "$out" == *"NOT re-derive or re-open"* ]]
        [[ "$out" == *"DECISIONS.md part $k/4"* ]]
        [[ "$out" == *"OUT OF ORDER"* ]]
        [[ "$out" == *"=== end DECISIONS.md part $k/4 ===" ]]
    done
}

# ===== 4: the count follows the file; loss is never silent =====

@test "the part count tracks the CURRENT file, so a fixed registration needs no reseeding" {
    make_decisions 10000
    run "$HOOK" decisions 1 12
    [[ "$output" == *"part 1/2"* ]]          # actual count, not the seeded 12
    make_decisions 60000
    run "$HOOK" decisions 1 12
    [[ "$output" == *"part 1/8"* ]]          # grew, same registration
    run "$HOOK" decisions 9 12
    [ -z "$output" ]                         # parts past the end stay silent
}

@test "outgrowing capacity warns loudly on the last part, inside the cap" {
    make_decisions 40000
    # n=2 x the default 8500-char window = 17,000 chars of capacity.
    run "$HOOK" decisions 2 2
    [[ "$output" == *"WARNING"* ]]
    [[ "$output" == *"NOT delivered this session"* ]]
    # A warning that pushed its own part over 10,000 chars would itself be cut
    # to a 2 KB preview — the exact failure this hook exists to prevent.
    [ "$(printf '%s' "$output" | wc -m)" -lt 10000 ]
}

@test "a RESUME over its line budget is cut at the budget, with a NOTE, read at run time" {
    seq 1 600 > "$REPO/RESUME.md"
    # A non-default budget: the cap must come from the environment at run time,
    # never from a value baked into the registration.
    CCAGE_RESUME_BUDGET_LINES=100 run bash -c 'for k in $(seq 1 12); do "$0" resume "$k" 12; done' "$HOOK"
    [[ "$output" == *"truncated at 200 lines"* ]]
    [[ "$output" == *$'\n200\n'* ]]
    [[ "$output" != *$'\n201\n'* ]]
}

# ===== 5: run-time resolution, never a seed-time path =====

@test "the doc is resolved from CLAUDE_PROJECT_DIR and CCAGE_SLOT at run time" {
    printf 'PLAIN FILE\n' > "$REPO/RESUME.md"
    printf 'SLOT FILE\n'  > "$REPO/RESUME.review.md"

    CCAGE_SLOT=review run "$HOOK" resume 1 12
    [[ "$output" == *"SLOT FILE"* ]]
    [[ "$output" != *"PLAIN FILE"* ]]

    CCAGE_SLOT='../evil' run "$HOOK" resume 1 12      # unsafe slot → plain file
    [[ "$output" == *"PLAIN FILE"* ]]

    # Found even when Claude has cd'd elsewhere — the regression a path baked in
    # at seed time would reintroduce, silently delivering nothing.
    mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
    run bash -c 'cd "$1" && "$0" resume 1 12' "$HOOK" "$BATS_TEST_TMPDIR/elsewhere"
    [[ "$output" == *"PLAIN FILE"* ]]
}

# ===== no-ops and observability =====

@test "a malformed CCAGE_DOC_CHUNK_CHARS falls back instead of destroying the payload" {
    # Unvalidated, a 0 or non-numeric value reached awk as a divisor: "division
    # by zero", the whole register gone from context, exit status still 0, and
    # nothing anywhere reporting it — reachable from one typo in an env var.
    make_decisions 20000
    local v out
    for v in 0 abc -5 999999 ""; do
        out=$(CCAGE_DOC_CHUNK_CHARS="$v" "$HOOK" decisions 1 12 2>&1)
        [[ "$out" == *"RATIFIED DECISIONS"* ]]
        [[ "$out" != *"division by zero"* ]]
        [ "$(printf '%s' "$out" | wc -m)" -gt 1000 ]
    done
}

@test "CCAGE_NO_AUTOLOAD is honoured at RUN time, not only when seeding" {
    # The seeder honours the opt-out by not REGISTERING these hooks, which does
    # nothing for a cage already seeded — 24 registrations keep firing and keep
    # injecting, and the user gets no sign their opt-out did nothing.
    make_decisions 20000
    CCAGE_NO_AUTOLOAD=1 run "$HOOK" decisions 1 12
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "every bad or empty invocation no-ops silently, and all of them log" {
    make_decisions 20000
    local case_
    for case_ in "decisions 13 12" "decisions 0 12" "decisions x 12" "plans 1 12" "resume 1 12"; do
        # shellcheck disable=SC2086
        run "$HOOK" $case_
        [ "$status" -eq 0 ]
        [ -z "$output" ]     # k>n never re-emits another part's content
    done
    "$HOOK" decisions 1 12 >/dev/null
    # Ratified D14/D16: a hook that logs no ALLOW path cannot be shown to have
    # fired, so "did all 3 parts arrive?" must be a one-line grep.
    grep -q 'k=1/12 status=emit parts=3'                    "$LOG"
    grep -q 'k=13/12 status=noop reason=index-out-of-range' "$LOG"
    grep -q 'kind=resume k=1/12 status=noop reason=absent'  "$LOG"
    grep -q 'status=noop reason=unknown-kind'               "$LOG"
}

@test "an unwritable log destination breaks neither delivery nor stderr" {
    make_decisions 20000
    CLAUDE_CONFIG_DIR=/nonexistent/nope run --separate-stderr "$HOOK" decisions 1 12
    [ "$status" -eq 0 ]
    [[ "$output" == *"RATIFIED DECISIONS"* ]]
    [ -z "$stderr" ]
}
