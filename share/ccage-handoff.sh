# shellcheck shell=bash
# ccage handoff — produce a Markdown brief from a Claude Code session JSONL.
#
# Zero API calls. Pure jq + shell. Designed for the use case "I want to start
# a fresh `claude` session and not pay -r's structural cache rewrite tax."
#
# Public entry: _ccage_handoff_main "$@"

# ---- pricing (rates per million tokens) -------------------------------------
# ONE hand-maintained table: input and output. Every cache rate is DERIVED from
# input, never typed out separately:
#
#   cache-write (5-minute TTL) = 1.25 × input
#   cache-write (1-hour TTL)   = 2.00 × input
#   cache-read                 = 0.10 × input
#
# Four parallel hand-maintained tables is how the previous version drifted: by
# 2026-07-20 its opus row said $15/$75 against an actual $5/$25 (3× over), and
# every model released after 2026-05-16 fell through to the opus default — so a
# Sonnet 5 session was costed at 5× reality. Deriving removes that failure mode:
# correct the input rate and the cache rates follow.
#
# Patterns are globs so a suffixed id (e.g. `claude-opus-4-8[1m]`, which is how
# a 1M-context session reports itself) matches its family instead of falling to
# the default.
#
# Refresh `# updated:` and add a CHANGELOG entry when Anthropic publishes new
# rates. Verified against the bundled claude-api model table.
# updated: 2026-07-20
# ONE pattern list, resolved to a family. Both price lookups and the
# is-this-model-known check read it, so a new model cannot be added to pricing
# while silently staying "unknown" to the caller — the same anti-drift move the
# rest of this section makes, one level up.
# Echoes: fable | opus | sonnet | haiku | unknown
_ccage_handoff_model_family() {
    case "$1" in
        claude-fable-5*|claude-mythos-5*)                    echo fable ;;
        claude-opus-4-8*|claude-opus-4-7*|claude-opus-4-6*)  echo opus ;;
        # Sonnet 5 has an introductory $2/$10 rate through 2026-08-31. The list
        # rate is deliberately used: the intro rate expires, and an expired
        # discount silently UNDER-reports cost, which is the worse error here.
        # sonnet-4-5 is unverified and carried unchanged from the old table.
        claude-sonnet-5*|claude-sonnet-4-6*|claude-sonnet-4-5*) echo sonnet ;;
        claude-haiku-4-5*)                                   echo haiku ;;
        *)                                                   echo unknown ;;
    esac
}
_ccage_handoff_price_input() {
    case "$(_ccage_handoff_model_family "$1")" in
        fable)         echo 10 ;;
        sonnet)        echo 3 ;;
        haiku)         echo 1 ;;
        opus|unknown)  echo 5 ;;   # unknown falls back to the current Opus tier
    esac
}
_ccage_handoff_price_output() {
    case "$(_ccage_handoff_model_family "$1")" in
        fable)         echo 50 ;;
        sonnet)        echo 15 ;;
        haiku)         echo 5 ;;
        opus|unknown)  echo 25 ;;
    esac
}

# Cache-rate multipliers, applied to the input rate. Kept as named constants so
# the ratios appear exactly once.
_CCAGE_CW_5M_MULT=1.25
_CCAGE_CW_1H_MULT=2.00
_CCAGE_CR_MULT=0.10

# Retained as thin derived wrappers: they were part of this file's surface, and
# expressing them in terms of the input rate is what stops them drifting.
_ccage_handoff_price_cache_write() {   # 5-minute TTL (the historical meaning)
    awk -v i="$(_ccage_handoff_price_input "$1")" -v m="$_CCAGE_CW_5M_MULT" \
        'BEGIN { printf "%g\n", i * m }'
}
_ccage_handoff_price_cache_write_1h() {
    awk -v i="$(_ccage_handoff_price_input "$1")" -v m="$_CCAGE_CW_1H_MULT" \
        'BEGIN { printf "%g\n", i * m }'
}
_ccage_handoff_price_cache_read() {
    awk -v i="$(_ccage_handoff_price_input "$1")" -v m="$_CCAGE_CR_MULT" \
        'BEGIN { printf "%g\n", i * m }'
}

# ---- pwd-to-slug ------------------------------------------------------------
# Claude Code derives project slugs from CWD by replacing EVERY non-alphanumeric
# character with `-` (not just `/`: "_" and "." convert too). Verified
# empirically across real projects/ directories — a `_`-containing project kept
# both the old `/`-only slug and the current fully-converted one on disk.
# tr keeps this bash-3.2 safe (macOS mishandles a ${var//[^…]/} bracket class).
_ccage_handoff_pwd_to_slug() {
    local p="${1:-$PWD}"
    printf '%s\n' "$p" | LC_ALL=C tr -c 'A-Za-z0-9\n' '-'
}

# ---- locate session JSONL ---------------------------------------------------
# Args: SESSION_DIR [PREFIX]
# Echoes the chosen .jsonl path; exit 2 with stderr msg on failure.
_ccage_handoff_locate() {
    local session_dir="$1" prefix="${2:-}"

    if [ ! -d "$session_dir" ]; then
        printf 'ccage: no sessions found at %s\n' "$session_dir" >&2
        return 2
    fi

    if [ -z "$prefix" ]; then
        local newest
        # shellcheck disable=SC2012  # ls -t is fine here — session UUIDs don't contain newlines/quotes
        newest=$(ls -t "$session_dir"/*.jsonl 2>/dev/null | head -1)
        if [ -z "$newest" ] || [ ! -f "$newest" ]; then
            printf 'ccage: no .jsonl files in %s\n' "$session_dir" >&2
            return 2
        fi
        printf '%s\n' "$newest"
        return 0
    fi

    local matches=()
    local f
    for f in "$session_dir/$prefix"*.jsonl; do
        [ -f "$f" ] && matches+=("$f")
    done

    case ${#matches[@]} in
        0)
            printf 'ccage: no sessions matching "%s" in %s\n' "$prefix" "$session_dir" >&2
            return 2
            ;;
        1)
            printf '%s\n' "${matches[0]}"
            return 0
            ;;
        *)
            printf 'ccage: ambiguous session prefix "%s" — %d matches:\n' "$prefix" "${#matches[@]}" >&2
            for f in "${matches[@]}"; do
                printf '  %s\n' "${f##*/}" >&2
            done
            return 2
            ;;
    esac
}

# Streamed per-record preamble — `fromjson?` drops malformed lines silently
# (preserves partial-write resilience). Memory stays constant per record.
_CCAGE_HANDOFF_JQ_PREAMBLE='split("\n") | .[] | select(length > 0) | fromjson? // empty'

# Harness-injected notifications masquerading as user prompts.
#
# A teammate's idle notification and a background-task completion arrive as
# `type: "user"` records with plain-string content, no isMeta and no
# toolUseResult — structurally identical to something the human typed, so every
# structural filter passes them. Only the payload distinguishes them. Measured
# on one fan-out session: 5 of 8 extracted "prompts" were idle notifications,
# 5650 of the brief's 9430 bytes, and `Turns: N user` was inflated to match.
#
# Matched shapes, all verified against real transcripts:
#   "Another Claude session sent a message:\n<teammate-message …>{json}"
#   "<task-notification><task-id>…"
#
# EVERY test is anchored at the start of the record. An unanchored
# `contains("<teammate-message ")` also matched a human who merely QUOTED the
# marker — pasting a transcript excerpt, or asking about this very code — and
# the prompt was then removed from the brief entirely. That is the wrong
# failure direction for a state-recovery tool: it trades a cosmetic turn-count
# inflation for silent loss of the human's own words, in the one artifact whose
# job is to recover them. Over-counting a notification is recoverable by
# reading; a deleted prompt is not.
#
# jq `def`s must lead a program, so this prefixes rather than pipes.
_CCAGE_HANDOFF_JQ_DEFS='
def is_harness_notification:
    startswith("<teammate-message ")
    or startswith("Another Claude session sent a message:\n<teammate-message ")
    or startswith("<task-notification>");
# Type coercions for fields read out of a transcript. A transcript is not a
# schema-checked artifact, and jq raises a type error — which aborts an entire
# reduce, not just the offending record — the moment a field holds the wrong
# type. The // operator does not help: it only substitutes for null and false.
def num: if type == "number" then . else 0 end;
def obj: if type == "object" then . else {} end;
'

# ---- token totals -----------------------------------------------------------
# Echoes one line: "input=N output=N cache_write=N cache_read=N"
_ccage_handoff_token_totals() {
    local jsonl="$1"
    jq -Rr "$_CCAGE_HANDOFF_JQ_PREAMBLE"'
        | select(.type == "assistant") | .message.usage // {} |
        [
            (.input_tokens // 0),
            (.output_tokens // 0),
            (.cache_creation_input_tokens // 0),
            (.cache_read_input_tokens // 0)
        ] | @tsv
    ' "$jsonl" 2>/dev/null | awk '
        { i+=$1; o+=$2; cw+=$3; cr+=$4 }
        END { printf "input=%d output=%d cache_write=%d cache_read=%d\n", i+0, o+0, cw+0, cr+0 }
    '
}

# ---- peak cache_read --------------------------------------------------------
# Max cache_read across all assistant turns where it exceeds 1000 tokens
# ("substantive" — filters out the metadata turn near session start).
_ccage_handoff_peak_cache_read() {
    local jsonl="$1"
    local peak
    peak=$(jq -Rr "$_CCAGE_HANDOFF_JQ_PREAMBLE"'
        | select(.type == "assistant")
        | .message.usage.cache_read_input_tokens // 0
        | select(. > 1000)
    ' "$jsonl" 2>/dev/null | sort -rn | head -1)
    printf '%s\n' "${peak:-0}"
}

# ---- last model -------------------------------------------------------------
_ccage_handoff_last_model() {
    local jsonl="$1"
    local m
    # `tr -d '\n'` defends against the (hypothetical) case of a model name
    # containing an embedded newline — `tail -1` alone would keep only the
    # post-newline fragment and feed a bogus model string into the pricing
    # lookup. Production callers route through _ccage_handoff_collect
    # (jq-side extraction); this helper is kept for unit-test coverage.
    m=$(jq -Rr "$_CCAGE_HANDOFF_JQ_PREAMBLE"'
        | select(.type == "assistant" and .message.model != null and .message.model != "<synthetic>")
        | .message.model
    ' "$jsonl" 2>/dev/null | tail -1 | tr -d '\n')
    printf '%s\n' "${m:-unknown}"
}

# ---- user prompt counting ---------------------------------------------------
# Slurp helpers use jq's raw-input mode (-R) + split on newlines + `fromjson?`
# to tolerate malformed lines. Plain `jq -s` aborts the whole pipeline on the
# first parse error; that's bad for live session JSONLs which occasionally
# contain partial writes.
_ccage_handoff_count_prompts() {
    local jsonl="$1"
    jq -Rrs "$_CCAGE_HANDOFF_JQ_DEFS"'
        split("\n")
        | map(select(length > 0) | fromjson?)
        | map(select(
            .type == "user"
            and (.isMeta // false) == false
            and (.toolUseResult // null) == null
        ))
        | map(
            .message.content as $c
            | if ($c | type) == "string" then $c
              elif ($c | type) == "array" then
                ([$c[]? | select(.type == "text") | .text] | join("\n"))
              else "" end
        )
        | map(select(
            length > 0
            and (startswith("<command-name>") | not)
            and (startswith("<local-command-stdout>") | not)
            and (startswith("<system-reminder>") | not)
            and (startswith("<command-message>") | not)
            and (startswith("<command-args>") | not)
            and (is_harness_notification | not)
        ))
        | length
    ' "$jsonl" 2>/dev/null || echo 0
}

_ccage_handoff_count_assistants() {
    local jsonl="$1"
    jq -Rrs '
        split("\n")
        | map(select(length > 0) | fromjson?)
        | map(select(.type == "assistant"))
        | length
    ' "$jsonl" 2>/dev/null || echo 0
}

# ---- extract user prompts (returns JSON array of strings) -------------------
# Output: jq array — one element per real human prompt, in chronological order.
_ccage_handoff_prompts_json() {
    local jsonl="$1"
    # Map every user record that is NOT meta and NOT a tool result.
    # Content can be a string (most common) or an array of {type,text} blocks.
    # For array content, concatenate all type=="text" elements.
    jq -Rs "$_CCAGE_HANDOFF_JQ_DEFS"'
        split("\n")
        | map(select(length > 0) | fromjson?)
        | map(
            select(
                .type == "user"
                and (.isMeta // false) == false
                and (.toolUseResult // null) == null
            )
            | .message.content as $c
            | if ($c | type) == "string" then $c
              elif ($c | type) == "array" then
                ([$c[]? | select(.type == "text") | .text] | join("\n"))
              else "" end
        )
        | map(select(length > 0))
        # Drop synthetic slash-command echoes (`<command-name>`, `<local-command-stdout>`,
        # `<system-reminder>`, etc.). These appear in real Claude Code transcripts
        # whenever a user invokes a slash command — the visible "prompt" is the
        # auto-emitted command-info block, not human intent.
        # Harness-injected notifications (teammate idle, background task done)
        # are not human intent either — see _CCAGE_HANDOFF_JQ_DEFS.
        | map(select(
            (startswith("<command-name>") | not)
            and (startswith("<local-command-stdout>") | not)
            and (startswith("<system-reminder>") | not)
            and (startswith("<command-message>") | not)
            and (startswith("<command-args>") | not)
            and (is_harness_notification | not)
        ))
    ' "$jsonl" 2>/dev/null
}

# ---- files touched ----------------------------------------------------------
# Output: TSV — path<TAB>read_count<TAB>edit_count<TAB>write_count
_ccage_handoff_files_touched() {
    local jsonl="$1"
    jq -Rr "$_CCAGE_HANDOFF_JQ_PREAMBLE"'
        | select(.type == "assistant")
        | .message.content[]?
        | select(.type == "tool_use" and (.name == "Read" or .name == "Edit" or .name == "Write"))
        | "\(.name)\t\(.input.file_path // .input.path // "")"
    ' "$jsonl" 2>/dev/null | awk -F'\t' '
        $2 != "" {
            paths[$2] = 1
            counts[$2 "\t" $1]++
        }
        END {
            for (p in paths) {
                r = counts[p "\tRead"] + 0
                e = counts[p "\tEdit"] + 0
                w = counts[p "\tWrite"] + 0
                printf "%s\t%d\t%d\t%d\n", p, r, e, w
            }
        }
    ' | sort -k2,4 -rn
}

# ---- bash commands ----------------------------------------------------------
# Output: deduplicated, trivial-filtered, one per line.
# Trivials: pwd, ls (no args), true, clear, exit, cd (no args)
_ccage_handoff_bash_commands() {
    local jsonl="$1"
    jq -Rr "$_CCAGE_HANDOFF_JQ_PREAMBLE"'
        | select(.type == "assistant")
        | .message.content[]?
        | select(.type == "tool_use" and .name == "Bash")
        | .input.command
        | select(length > 0)
    ' "$jsonl" 2>/dev/null | awk '
        # filter trivials
        {
            cmd = $0
            trimmed = cmd
            gsub(/^[ \t]+|[ \t]+$/, "", trimmed)
            if (trimmed == "pwd" || trimmed == "ls" || trimmed == "true" || \
                trimmed == "clear" || trimmed == "exit" || trimmed == "cd") next
            print cmd
        }
    ' | awk '!seen[$0]++'  # dedup, preserve first-seen order
}

# ---- last assistant text ----------------------------------------------------
_ccage_handoff_last_assistant_text() {
    local jsonl="$1"
    jq -Rr "$_CCAGE_HANDOFF_JQ_PREAMBLE"'
        | select(.type == "assistant")
        | .message.content[]?
        | select(.type == "text")
        | .text
        | select(length > 0)
    ' "$jsonl" 2>/dev/null | tail -1
}

# ---- single-pass collector --------------------------------------------------
# Walks the JSONL ONCE via streaming `reduce inputs`, accumulating every field
# the brief needs into one JSON object. Replaces 11 separate file-scans on the
# generate hot path. The 11 small per-section helpers above are kept intact
# for unit-test coverage; only the production caller uses this fast path.
#
# Echoes one compact JSON object. Empty / missing file → object of defaults.
# The skeleton emitted whenever a real blob cannot be produced. Defined once so
# the missing-file branch and the jq-failure fallback cannot drift apart — the
# latter matters because a jq abort used to yield NOTHING, and downstream a
# missing blob composes into a confident, entirely empty brief.
_CCAGE_HANDOFF_COLLECT_DEFAULTS='{"session_id":null,"first_ts":null,"last_ts":null,"last_model":null,"assistant_count":0,"in":0,"out":0,"cw":0,"cw5":0,"cw1":0,"cr":0,"prompts":[],"notifications":[],"files":{},"bash_commands":[],"last_text":null,"last_is_error":false}'

_ccage_handoff_collect() {
    local jsonl="$1"
    [ -f "$jsonl" ] || {
        printf '%s\n' "$_CCAGE_HANDOFF_COLLECT_DEFAULTS"
        return 0
    }
    jq -cRn "$_CCAGE_HANDOFF_JQ_DEFS"'
        reduce (inputs | fromjson? // empty) as $r (
            { session_id: null, first_ts: null, last_ts: null, last_model: null,
              assistant_count: 0, in: 0, out: 0, cw: 0, cw5: 0, cw1: 0, cr: 0,
              prompts: [], notifications: [], files: {}, bash_commands: [],
              last_text: null, last_is_error: false };
            # session id: first non-null
            ( if .session_id == null and ($r.sessionId // null) != null
              then .session_id = $r.sessionId else . end )
            # timestamps: first + last seen
            | ( if ($r.timestamp // null) != null then
                  ( if .first_ts == null then .first_ts = $r.timestamp else . end )
                  | .last_ts = $r.timestamp
                else . end )
            # assistant turns: model, counts, tokens, files/commands/last-text from content
            | ( if $r.type == "assistant" then
                  .assistant_count += 1
                  # Terminal state. A transcript records no explicit
                  # termination, so the honest signal is whether the LAST
                  # assistant record was a synthetic API-error message —
                  # verified shape: isApiErrorMessage true, model "<synthetic>",
                  # text e.g. "You have hit your weekly limit - resets 2am".
                  # Overwritten on every assistant record, so it reflects the
                  # last one, not any earlier transient error.
                  # (No apostrophes here: the whole program is single-quoted.)
                  | .last_is_error = ($r.isApiErrorMessage // false)
                  | ( if ($r.message.model // null) != null
                        and $r.message.model != "<synthetic>"
                      then .last_model = $r.message.model else . end )
                  # Every usage field goes through num/obj rather than `// 0`.
                  # `//` only defends against null: a `usage` that is a string,
                  # or a `cache_creation` that is a number, raises a jq type
                  # error, and a type error ANYWHERE aborts the whole reduce —
                  # so one malformed record erased the entire transcript and
                  # the brief rendered as a plausible-looking empty session
                  # (no prompts, no files, $0.00) for a session that really
                  # happened. For a recovery tool that silent lie is worse
                  # than a crash. Guarding per field keeps the data from every
                  # well-formed record instead.
                  # (No apostrophes here: the whole program is single-quoted.)
                  | ($r.message | obj | .usage | obj) as $u
                  | ($u.cache_creation | obj) as $cc
                  | .in  += ($u.input_tokens | num)
                  | .out += ($u.output_tokens | num)
                  | .cw  += ($u.cache_creation_input_tokens | num)
                  # Cache-write split by TTL — priced differently (1.25x vs 2x
                  # input). Absent on transcripts written before Claude Code
                  # reported the split; the caller falls back to attributing an
                  # unsplit total to the 5-minute bucket.
                  | .cw5 += ($cc.ephemeral_5m_input_tokens | num)
                  | .cw1 += ($cc.ephemeral_1h_input_tokens | num)
                  | .cr  += ($u.cache_read_input_tokens | num)
                  | reduce ($r.message.content[]?
                            | select(.type == "text" or .type == "tool_use")) as $c (.;
                      if $c.type == "text" and (($c.text // "") | length) > 0 then
                          .last_text = $c.text
                      elif $c.type == "tool_use" then
                          if ($c.name == "Read" or $c.name == "Edit" or $c.name == "Write") then
                              ( ($c.input.file_path // $c.input.path // "") as $p
                                | if $p != "" then
                                    .files[$p] = (.files[$p] // {Read: 0, Edit: 0, Write: 0})
                                    | .files[$p][$c.name] += 1
                                  else . end )
                          elif $c.name == "Bash" then
                              ( ($c.input.command // "") as $cmd
                                | if $cmd != "" then .bash_commands += [$cmd] else . end )
                          else . end
                      else . end
                    )
                else . end )
            # user prompts: filter meta + tool-result + synthetic slash-command
            # echoes, and split harness notifications out into their own bucket
            # rather than dropping them — they are terminal-state evidence for
            # the delegated-work section.
            | ( if $r.type == "user"
                  and ($r.isMeta // false) == false
                  and ($r.toolUseResult // null) == null then
                  ( $r.message.content
                    | if type == "string" then .
                      elif type == "array" then
                          ([.[]? | select(.type == "text") | .text] | join("\n"))
                      else "" end ) as $text
                  | ( if ($text | length) > 0
                        and (($text | startswith("<command-name>")) | not)
                        and (($text | startswith("<local-command-stdout>")) | not)
                        and (($text | startswith("<system-reminder>")) | not)
                        and (($text | startswith("<command-message>")) | not)
                        and (($text | startswith("<command-args>")) | not)
                      then
                        ( if ($text | is_harness_notification)
                            then .notifications += [$text]
                            else .prompts += [$text] end )
                      else . end )
                else . end )
        )
    ' "$jsonl" 2>/dev/null || printf '%s\n' "$_CCAGE_HANDOFF_COLLECT_DEFAULTS"
}

# ---- delegated (subagent) work ----------------------------------------------
# A fan-out session's real work — and its real spend — lives in the subagents'
# own transcripts, which the brief used to ignore entirely. Measured on one
# session: 800 KB of main transcript against 7.4 MB across four subagents, so
# the header under-reported cost by an order of magnitude of activity.
#
# Layout (verified on disk, not assumed):
#   <cage>/projects/<slug>/<session-id>/subagents/agent-<id>.jsonl
#                                                 agent-<id>.meta.json
# The meta carries {agentType, customAgentType, description, name, model,
# teamName, parentAgentId, spawnDepth, taskKind}. The .jsonl uses the same
# record schema as the main transcript, so _ccage_handoff_collect works on it
# unmodified.
#
# Perf: measured 0.08 s across 7.4 MB, so this is one collect pass per agent
# with no caching.

# Size discipline: the brief is the input to a paid turn (/checkpoint
# --from-session), so the agent list is capped rather than allowed to grow with
# the fan-out. Target for the whole brief is under 15 KB.
_CCAGE_HANDOFF_MAX_AGENTS=12
# Width cap for a single command line in the "Commands run" listing.
_CCAGE_HANDOFF_MAX_CMD_CHARS=140
# Per-prompt character cap, and a byte budget for the whole prompts section.
# Every other section is bounded; prompts were not, and on real data they were
# the only thing that ever blew the 15 KB whole-brief target.
_CCAGE_HANDOFF_MAX_PROMPT_CHARS=600
_CCAGE_HANDOFF_PROMPT_BUDGET=9000
# Hard size bound for a free-text block, applied before any word-based cap.
# Whitespace-free text is one "word" at any length, so the word cap alone let a
# single blob carry the whole brief past its target.
_CCAGE_HANDOFF_MAX_TEXT_BYTES=8000

# Shared by every section that interpolates free text into the brief: escape a
# line-leading Markdown heading so pasted text cannot forge one of the brief's
# own sections. Prompts are not the only such section — assistant text ends
# its turns with headings routinely (13 of 120 real sessions), so a brief that
# neutralized only prompts still had a forgeable neighbour.
#
# jq's `^` anchors at STRING start only (verified on jq 1.8.1), so the
# per-line case is matched via an explicit \n rather than relying on a (?m)
# flag whose meaning varies between regex flavours.
_CCAGE_HANDOFF_JQ_NEUTRALIZE='
    def neutralize:
        gsub("^(?<h>#{1,6} )"; "\\\(.h)")
        | gsub("\n(?<h>#{1,6} )"; "\n\\\(.h)");
'

# Pipe-escape for any value interpolated into a Markdown table cell. Both
# tables need it and for different reasons: an agent's terminal state is free
# text from the server, and a file path may legally contain `|` on both Linux
# and macOS. An unescaped pipe silently splits one row into extra columns, so
# the row no longer lines up with its header.
_CCAGE_HANDOFF_JQ_CELL='
    def cell: tostring
        # A newline in a cell ends the Markdown ROW, fabricating a phantom
        # all-zero row plus one whose "path" is filesystem-controlled text — in
        # a document a fresh session is told to trust. A tab additionally
        # collides with the TSV that feeds the Files-touched awk pass, silently
        # shifting every count into the wrong column. Both are legal in a path
        # on Linux and macOS. Same defect the Commands section already fixed.
        | gsub("[\\n\\t\\r]"; " ")
        | gsub("\\|"; "\\|");
'

_ccage_handoff_subagents_dir() {
    printf '%s\n' "${1%.jsonl}/subagents"
}

# Echoes a JSON array, one object per subagent, newest activity last. Empty
# array when the session delegated nothing.
_ccage_handoff_subagents_json() {
    local jsonl="$1"
    local dir
    dir=$(_ccage_handoff_subagents_dir "$jsonl")
    if [ ! -d "$dir" ]; then
        printf '[]\n'
        return 0
    fi

    # Two layouts, not one. A plain subagent lands in <session>/subagents/;
    # a Workflow-spawned agent lands one level deeper, in
    # <session>/subagents/workflows/wf_<id>/. Globbing only the first missed
    # every workflow agent — the exact under-reporting this section exists to
    # prevent, and worst where it matters most: a session whose delegation was
    # entirely workflow-driven has no top-level agents at all, so the brief
    # rendered no delegated section and silently stated it delegated nothing.
    # Measured on one real session: 122 agents and $15.04 uncounted against a
    # reported $70.90.
    local files=()
    local f meta name agent_data cost wf
    for f in "$dir"/agent-*.jsonl; do
        [ -f "$f" ] && files+=("$f")
    done
    for f in "$dir"/workflows/wf_*/agent-*.jsonl; do
        [ -f "$f" ] && files+=("$f")
    done

    local rows=()
    for f in ${files[@]+"${files[@]}"}; do
        # Workflow membership, from the path: "" for a plain subagent, the
        # wf_<id> directory name for a workflow one. The brief groups by this
        # so 166 workflow agents cannot swamp a size-budgeted table.
        wf=""
        case "$f" in
            "$dir"/workflows/*)
                wf="${f#"$dir"/workflows/}"
                wf="${wf%%/*}"
                ;;
        esac
        meta="${f%.jsonl}.meta.json"
        # Fall back to the filename when there is no meta sidecar: the id is
        # `agent-<name>-<hash>`, so strip the prefix and the trailing hash.
        name="${f##*/agent-}"
        name="${name%.jsonl}"
        name="${name%-*}"

        agent_data=$(_ccage_handoff_collect "$f")
        # Per-agent cost: agents run on different tiers, so a single session-wide
        # rate would be wrong in both directions.
        local a_model a_in a_out a_cw5 a_cw1 a_cr
        IFS=$'\t' read -r a_model a_in a_out a_cw5 a_cw1 a_cr < <(
            jq -r '[
                (.last_model // "unknown"), .in, .out,
                (if ((.cw5 + .cw1) == 0 and .cw > 0) then .cw else .cw5 end),
                .cw1, .cr
            ] | @tsv' <<<"$agent_data"
        )
        cost=$(_ccage_handoff_cost "$a_in" "$a_out" "$a_cw5" "$a_cw1" "$a_cr" "$a_model")

        # Pull the small pieces out of the blob with heredocs rather than
        # passing the whole thing as an argument: a busy agent's collect blob
        # carries every prompt and Bash command it issued, which is exactly the
        # shape that overflows ARG_MAX on the one session that matters.
        local a_files a_ended a_turns
        a_files=$(jq -c '.files' <<<"$agent_data")
        a_turns=$(jq -r '.assistant_count' <<<"$agent_data")
        # Honest wording: a transcript carries no explicit termination record,
        # so "ok" means the last turn completed normally, not that the agent
        # finished its task.
        a_ended=$(jq -r '
            if .last_is_error
            then "api error: " + ((.last_text // "") | split("\n")[0] | .[0:60])
            else "ok" end' <<<"$agent_data")

        # --slurpfile on a missing sidecar would abort jq; /dev/null slurps to
        # [], which the filter below folds to {}.
        local meta_src=/dev/null
        if [ -f "$meta" ]; then
            meta_src="$meta"
        fi

        rows+=("$(
            jq -c -n \
                --arg fallback_name "$name" \
                --arg model "$a_model" \
                --arg ended "$a_ended" \
                --arg turns "$a_turns" \
                --arg cost "${cost#\$}" \
                --arg wf "$wf" \
                --arg in "$a_in" --arg out "$a_out" --arg cr "$a_cr" \
                --arg cw "$((a_cw5 + a_cw1))" \
                --argjson files "$a_files" \
                --slurpfile meta "$meta_src" '
                ($meta[0] // {}) as $m |
                {
                    name:  ($m.name // $fallback_name),
                    type:  ($m.customAgentType // $m.agentType // "unknown"),
                    # The transcript records what actually served the turns; the
                    # meta only records what was requested ("opus", "sonnet").
                    # Prefer the former, and it is what cost was priced from.
                    model: (if $model != "unknown" then $model else ($m.model // "unknown") end),
                    turns: ($turns | tonumber),
                    cost:  ($cost | tonumber),
                    in:    ($in | tonumber),
                    out:   ($out | tonumber),
                    cw:    ($cw | tonumber),
                    cr:    ($cr | tonumber),
                    files: $files,
                    ended: $ended,
                    wf:    $wf
                }'
        )")
    done

    if [ ${#rows[@]} -eq 0 ]; then
        printf '[]\n'
        return 0
    fi
    printf '%s\n' "${rows[@]}" | jq -cs '.'
}

# ---- timestamps -------------------------------------------------------------
_ccage_handoff_first_timestamp() {
    local jsonl="$1"
    jq -Rr "$_CCAGE_HANDOFF_JQ_PREAMBLE"'
        | select(.timestamp != null) | .timestamp
    ' "$jsonl" 2>/dev/null | head -1
}
_ccage_handoff_last_timestamp() {
    local jsonl="$1"
    jq -Rr "$_CCAGE_HANDOFF_JQ_PREAMBLE"'
        | select(.timestamp != null) | .timestamp
    ' "$jsonl" 2>/dev/null | tail -1
}

_ccage_handoff_session_id() {
    local jsonl="$1"
    jq -Rr "$_CCAGE_HANDOFF_JQ_PREAMBLE"'
        | select(.sessionId != null) | .sessionId
    ' "$jsonl" 2>/dev/null | head -1
}

# ---- format age (seconds → human) -------------------------------------------
_ccage_handoff_age_human() {
    local seconds="$1"
    if [ "$seconds" -lt 60 ]; then
        printf '%ds ago\n' "$seconds"
    elif [ "$seconds" -lt 3600 ]; then
        printf '%dm ago\n' $((seconds / 60))
    elif [ "$seconds" -lt 86400 ]; then
        printf '%dh %dm ago\n' $((seconds / 3600)) $(((seconds % 3600) / 60))
    else
        printf '%dd %dh ago\n' $((seconds / 86400)) $(((seconds % 86400) / 3600))
    fi
}

# ---- truncate long text (first/last N words) --------------------------------
# `tr -s '[:space:]' '\n'` squeezes any whitespace run into a single newline,
# giving one word per line. Then head/tail pick the halves and `tr '\n' ' '`
# stitches each half back into a single space-separated line. Replaces three
# opaque awk passes with three trivial pipelines.
_ccage_handoff_truncate_words() {
    local max="$1" text="$2"
    local n
    # A WORD cap is not a SIZE cap. A base64 blob, a minified line or a long
    # hash carries no whitespace, so it is one "word" however many megabytes it
    # is — a 50 MB single-token last turn composed a 52 MB brief against this
    # file's 15 KB target. Bound the bytes first; the word logic below then
    # operates on something already known to be small.
    local bytes
    bytes=$(printf '%s' "$text" | wc -c)
    if [ "$bytes" -gt "$_CCAGE_HANDOFF_MAX_TEXT_BYTES" ]; then
        # Cut on a character boundary via the shell rather than byte-slicing,
        # so a multibyte sequence is never split in half.
        text="${text:0:$_CCAGE_HANDOFF_MAX_TEXT_BYTES}"
        printf '%s\n…(truncated — %d bytes of unbroken text elided)…\n' \
            "$text" $((bytes - _CCAGE_HANDOFF_MAX_TEXT_BYTES))
        return
    fi
    n=$(printf '%s' "$text" | wc -w)
    if [ "$n" -le "$max" ]; then
        printf '%s\n' "$text"
        return
    fi
    local half=$((max / 2))
    local first last
    first=$(printf '%s' "$text" | tr -s '[:space:]' '\n' | head -n "$half" | tr '\n' ' ')
    last=$(printf '%s' "$text" | tr -s '[:space:]' '\n' | tail -n "$half" | tr '\n' ' ')
    printf '%s\n…(%d words elided)…\n%s\n' "$first" $((n - max)) "$last"
}

# ---- compute estimated total session cost (dollars, 2 decimal) --------------
# Args: input_tokens output_tokens cw5m_tokens cw1h_tokens cache_read_tokens model
#
# Cache-write is split by TTL because the two are priced differently (1.25× vs
# 2× input) and the difference is large: the same tokens cost 60% more at the
# 1-hour TTL. Transcripts record the split under
# `usage.cache_creation.{ephemeral_5m,ephemeral_1h}_input_tokens`, so this is
# measured, not assumed — the previous version charged everything at 1.25×.
#
# Echoes a dollar amount like "$9.25" covering input + output + both cache-write
# buckets + cache-read.
_ccage_handoff_cost() {
    local in_tok="$1" out_tok="$2" cw5_tok="$3" cw1_tok="$4" cr_tok="$5" model="$6"
    local in_rate out_rate
    in_rate=$(_ccage_handoff_price_input "$model")
    out_rate=$(_ccage_handoff_price_output "$model")
    # Note: gawk reserves `or` as a builtin — use `outr` instead.
    awk -v i="$in_tok" -v o="$out_tok" -v cw5="$cw5_tok" -v cw1="$cw1_tok" \
        -v cr="$cr_tok" -v ir="$in_rate" -v outr="$out_rate" \
        -v m5="$_CCAGE_CW_5M_MULT" -v m1="$_CCAGE_CW_1H_MULT" -v mr="$_CCAGE_CR_MULT" \
        'BEGIN {
            total = i*ir + o*outr + cw5*(ir*m5) + cw1*(ir*m1) + cr*(ir*mr)
            printf "$%.2f\n", total / 1000000
        }'
}

# ---- clipboard helpers -----------------------------------------------------
# Try pbcopy → wl-copy → xclip → xsel. First found wins. Silent skip if none.
# Returns 0 on success (clipboard set), 1 if no tool found.
#
# Each copier is wrapped in `timeout 5` when GNU coreutils' `timeout` is on
# PATH: with WAYLAND_DISPLAY set but the socket unanswering (sandboxed shells,
# SSH with a stale env), wl-copy blocks in the FOREGROUND before daemonizing,
# so the pipeline never completes and the handoff call hangs forever (observed
# live, 23 minutes, 2026-07-16). `timeout` is absent on stock macOS, so the
# bare (untimed) call is kept there — pbcopy doesn't share this failure mode.
_ccage_handoff_copy_to_clipboard() {
    local content="$1"
    local runner=""
    if command -v timeout >/dev/null 2>&1; then
        runner="timeout 5"
    fi
    if command -v pbcopy >/dev/null 2>&1; then
        printf '%s' "$content" | $runner pbcopy && return 0
    elif command -v wl-copy >/dev/null 2>&1; then
        printf '%s' "$content" | $runner wl-copy && return 0
    elif command -v xclip >/dev/null 2>&1; then
        printf '%s' "$content" | $runner xclip -selection clipboard && return 0
    elif command -v xsel >/dev/null 2>&1; then
        printf '%s' "$content" | $runner xsel --clipboard --input && return 0
    fi
    return 1
}

# ---- Markdown brief composer ------------------------------------------------
# Top-level function (was nested inside _ccage_handoff_generate before the
# 2026-05-23 hoist). Takes the cached collect blob + the three derived values
# generate has to compute outside; re-extracts the rest of the scalars from
# the blob with one cheap jq call. The Bats `set -ET` constraint that made
# `mktemp + trap RETURN` unsafe still applies — caller redirects to file.
#
# Args:
#   $1 — handoff_data: JSON blob from _ccage_handoff_collect
#   $2 — cost_so_far:  pre-computed dollar string (e.g. "$9.25")
#   $3 — age_sec:      seconds since last activity ("" if date couldn't parse)
#   $4 — max_prompts:  cap on user-prompt list
#   $5 — jsonl_label:  path printed in the footer ("Generated by … from …")
#   $6 — subagents:    JSON array from _ccage_handoff_subagents_json ("[]" if none)
#   $7 — main_cost:    cost of the main transcript alone, for the "of which
#                      delegated" split ($2 is the combined figure)
_ccage_handoff_compose_brief() {
    local handoff_data="$1"
    local cost_so_far="$2"
    local age_sec="$3"
    local max_prompts="$4"
    local jsonl_label="$5"
    local subagents="${6:-[]}"
    local main_cost="${7:-$2}"

    local session_id first_ts last_ts model assistant_count prompt_count
    local in_tok out_tok cw_tok cr_tok
    IFS=$'\t' read -r session_id first_ts last_ts model \
                       assistant_count prompt_count \
                       in_tok out_tok cw_tok cr_tok < <(
        jq -r '[
            (.session_id // "unknown"),
            (.first_ts // ""),
            (.last_ts // ""),
            (.last_model // "unknown"),
            .assistant_count, (.prompts | length),
            .in, .out, .cw, .cr
        ] | @tsv' <<<"$handoff_data"
    )
    : "${session_id:=unknown}"; : "${model:=unknown}"
    : "${in_tok:=0}"; : "${out_tok:=0}"; : "${cw_tok:=0}"; : "${cr_tok:=0}"
    # These two were the only numerics without a default, so an empty collect
    # blob reached `[ "$shown_n" -gt "$total_prompts" ]` as an empty string and
    # printed `[: : integer expected` into the middle of the brief.
    : "${assistant_count:=0}"; : "${prompt_count:=0}"

    printf '# Handoff: %s\n\n' "$session_id"
    printf '**Project:** %s\n' "${PWD:-unknown}"
    printf '**Started:** %s\n' "${first_ts:-unknown}"
    if [ -n "$age_sec" ]; then
        printf '**Last activity:** %s (%s)\n' "$last_ts" "$(_ccage_handoff_age_human "$age_sec")"
    else
        printf '**Last activity:** %s\n' "${last_ts:-unknown}"
    fi
    local delegated_turns
    delegated_turns=$(jq -r '[.[].turns] | add // 0' <<<"$subagents")
    if [ "${delegated_turns:-0}" -gt 0 ]; then
        printf '**Turns:** %s user / %s assistant (+%s delegated)\n' \
            "$prompt_count" "$assistant_count" "$delegated_turns"
    else
        printf '**Turns:** %s user / %s assistant\n' "$prompt_count" "$assistant_count"
    fi
    # Token totals fold in every subagent: a fan-out session that reports only
    # its orchestrator's usage under-states the real work by an order of
    # magnitude (measured: 800 KB main against 7.4 MB delegated).
    local d_in d_out d_cw d_cr
    IFS=$'\t' read -r d_in d_out d_cw d_cr < <(
        jq -r '[([.[].in] | add // 0), ([.[].out] | add // 0),
                ([.[].cw] | add // 0), ([.[].cr] | add // 0)] | @tsv' <<<"$subagents"
    )
    printf '**Tokens billed so far:** %s input · %s output · %s cache-write · %s cache-read\n' \
        "$((in_tok + d_in))" "$((out_tok + d_out))" "$((cw_tok + d_cw))" "$((cr_tok + d_cr))"
    # An unknown model is priced at the current Opus tier. Say so, rather than
    # printing "standard rates" — which reads as an assertion that ccage knows
    # this model's price when it does not, so a wrong guess stays invisible.
    if [ "$(_ccage_handoff_model_family "$model")" = unknown ]; then
        printf '**Estimated cost so far:** ~%s (%s is NOT in the rate table — priced at current Opus rates, so treat this as a guess)\n' \
            "$cost_so_far" "$model"
    elif [ "$(jq -r 'length' <<<"$subagents")" -gt 0 ]; then
        # A delegating session's total spans tiers, so naming one model beside
        # it implied the whole figure was priced at that rate. It was not —
        # each agent is priced at its own model.
        printf '**Estimated cost so far:** ~%s (main thread on %s; each agent priced at its own model)\n' \
            "$cost_so_far" "$model"
    else
        printf '**Estimated cost so far:** ~%s (%s, standard rates)\n' "$cost_so_far" "$model"
    fi
    local agent_count
    agent_count=$(jq -r 'length' <<<"$subagents")
    if [ "${agent_count:-0}" -gt 0 ]; then
        printf '**of which delegated:** ~$%s across %s subagent(s); main thread ~%s\n' \
            "$(jq -r '[.[].cost] | add // 0 | .*100 | round / 100 | tostring' <<<"$subagents")" \
            "$agent_count" "$main_cost"
    fi
    printf '**Last model used:** %s\n' "$model"
    printf '\n'

    # User prompts section
    local total_prompts="$prompt_count"
    local shown_n="$max_prompts"
    [ "$shown_n" -gt "$total_prompts" ] && shown_n="$total_prompts"

    if [ "$total_prompts" -gt 0 ]; then
        # Prompts were capped by COUNT but never by LENGTH, and were
        # interpolated verbatim. Two consequences, both measured on real
        # sessions: (a) 2 of 25 briefs blew the 15 KB target, one reaching
        # 77 KB, almost entirely pasted prompt text; (b) a pasted prompt
        # carrying its own `## ` headings produced 30 bogus sections
        # interleaved with the 4 real ones, so the model reading the brief
        # cannot tell prompt text from the brief's own structure.
        #
        # Per-prompt character cap, then a byte budget across the section
        # (newest kept — they are the ones that matter for resuming), then
        # line-leading `#` escaped (see _CCAGE_HANDOFF_JQ_NEUTRALIZE) so prompt
        # text cannot forge a heading.
        #
        # The heading is emitted AFTER this pass, not before it: the count it
        # promises is only known once the byte budget has decided what fits.
        # Printed ahead of time it read "(last 20 of 50)" above 14 rendered
        # prompts. The count travels back on a sentinel first line.
        local prompts_out kept_n
        prompts_out=$(jq -r --argjson start "$((total_prompts - shown_n))" \
              --argjson cap "$_CCAGE_HANDOFF_MAX_PROMPT_CHARS" \
              --argjson budget "$_CCAGE_HANDOFF_PROMPT_BUDGET" \
              "$_CCAGE_HANDOFF_JQ_NEUTRALIZE"'
            def cap: if length > $cap then .[0:$cap] + "\n…(prompt truncated)" else . end;
            (.prompts[$start:] | to_entries | map(.key = .key + $start + 1)
               | map(.value |= (cap | neutralize))) as $items
            | ($items | reverse
               | reduce .[] as $e ({keep: [], used: 0, done: false};
                   if .done then .
                   elif (.used + ($e.value | utf8bytelength)) > $budget and (.keep | length) > 0
                   then (.done = true)
                   else {keep: (.keep + [$e]), used: (.used + ($e.value | utf8bytelength)), done: false}
                   end)
               | .keep | reverse) as $kept
            | "\($kept | length)",
              ($kept[] | "\(.key). \(.value)\n"),
              (if ($kept | length) < ($items | length)
               then "_(\(($items | length) - ($kept | length)) of the last \($items | length) prompt(s) dropped for size)_\n"
               else empty end)
        ' <<<"$handoff_data")
        kept_n=${prompts_out%%$'\n'*}
        if [ "$kept_n" -ge "$total_prompts" ]; then
            printf '## User prompts\n\n'
        else
            printf '## User prompts (last %s of %s)\n\n' "$kept_n" "$total_prompts"
        fi
        printf '%s\n' "${prompts_out#*$'\n'}"
        if [ "$total_prompts" -gt "$max_prompts" ]; then
            printf '\n_(%d earlier prompt(s) elided — see raw JSONL for full history)_\n' \
                $((total_prompts - shown_n))
        fi
    else
        printf '## User prompts\n\n'
        printf '_(no user prompts recorded in this session)_\n'
    fi

    # Delegated work — one line per agent. Capped, because this brief is the
    # input to a paid turn (/checkpoint --from-session) and must stay small.
    if [ "${agent_count:-0}" -gt 0 ]; then
        printf '\n## Delegated work\n\n'
        printf '| Agent | Type | Model | Turns | Cost | Files | Ended |\n'
        printf '|---|---|---|---:|---:|---:|---|\n'
        # Every cell is pipe-escaped (see _CCAGE_HANDOFF_JQ_CELL): an API-error
        # message containing `|` — free text from the server — would otherwise
        # split the row into extra columns. Newlines are already handled
        # upstream by the split("\n")[0] on `ended`.
        #
        # Workflow agents collapse to ONE row per workflow. A workflow fans out
        # by construction — 166 agents in one real session — so a row each
        # would swamp a brief that has to stay small, and the useful unit is
        # the workflow anyway. Plain subagents still get a row each.
        jq -r --argjson n "$_CCAGE_HANDOFF_MAX_AGENTS" "$_CCAGE_HANDOFF_JQ_CELL"'
            def row: "| \(.name|cell) | \(.type|cell) | \(.model|cell) | \(.turns) | $\(.cost) | \(.files|length) | \(.ended|cell) |";
            ([.[] | select(.wf == "")] | sort_by(-.cost) | .[0:$n] | .[] | row),
            ([.[] | select(.wf != "")] | group_by(.wf) | sort_by(-(map(.cost) | add)) | .[]
             | {
                 name:  "\(.[0].wf) (\(length) agent(s))",
                 type:  "workflow",
                 # One tier named when they agree, "mixed" when they do not —
                 # a workflow commonly pins cheap tiers per stage.
                 model: ((map(.model) | unique) as $m
                         | if ($m | length) == 1 then $m[0] else "mixed" end),
                 turns: (map(.turns) | add),
                 cost:  (map(.cost) | add | .*100 | round / 100),
                 files: (map(.files | keys) | add // [] | unique),
                 ended: ((map(select(.ended != "ok")) | length) as $bad
                         | if $bad == 0 then "ok" else "\($bad) ended in error" end)
               } | row)
        ' <<<"$subagents"
        local plain_count wf_count
        plain_count=$(jq -r '[.[] | select(.wf == "")] | length' <<<"$subagents")
        wf_count=$(jq -r '[.[] | select(.wf != "")] | length' <<<"$subagents")
        if [ "$plain_count" -gt "$_CCAGE_HANDOFF_MAX_AGENTS" ]; then
            printf '\n_(%d further agent(s) elided — costliest %d shown)_\n' \
                $((plain_count - _CCAGE_HANDOFF_MAX_AGENTS)) "$_CCAGE_HANDOFF_MAX_AGENTS"
        fi
        if [ "$wf_count" -gt 0 ]; then
            printf '\n_(%d workflow agent(s) summarised by workflow rather than listed)_\n' \
                "$wf_count"
        fi
        printf '\n_"ok" means the last turn completed normally; a transcript records no\nexplicit termination, so it does not mean the agent finished its task._\n'
    fi

    # Files touched section — sort by total touches desc. Rows merge the main
    # thread and every subagent, with `By` naming who touched the path.
    printf '\n## Files touched\n\n'
    local files_table
    files_table=$(jq -r --argjson subagents "$subagents" "$_CCAGE_HANDOFF_JQ_CELL"'
        ([{by: "main", files: .files}] + [$subagents[] | {by: .name, files: .files}])
        | map(.by as $b | .files | to_entries
              | map({path: .key, by: $b, r: .value.Read, e: .value.Edit, w: .value.Write}))
        | add // []
        | group_by(.path)
        | map({
            path:  .[0].path,
            r:     (map(.r) | add), e: (map(.e) | add), w: (map(.w) | add),
            # One toucher is always named, however long the agent name; a
            # crowd collapses to a count so the column cannot run away.
            by:    ((map(.by) | unique) as $names
                    | if ($names | length) == 1 then $names[0]
                      elif ($names | join("+") | length) <= 28 then ($names | join("+"))
                      else "\($names | length) sources" end)
          })
        | sort_by(-(.r + .e + .w))
        | .[] | "\(.path|cell)\t\(.r)\t\(.e)\t\(.w)\t\(.by|cell)"
    ' <<<"$handoff_data")
    if [ -n "$files_table" ]; then
        printf '| Path | Read | Edit | Write | By |\n'
        printf '|---|---:|---:|---:|---|\n'
        printf '%s\n' "$files_table" | head -30 | awk -F'\t' '{ printf "| %s | %d | %d | %d | %s |\n", $1, $2, $3, $4, $5 }'
    else
        printf '_(no files touched via Read/Edit/Write in this session)_\n'
    fi

    # Commands section — dedup + trivial-filter (same as the standalone helper).
    #
    # Flattened to ONE line per command and capped in width. A heredoc or a
    # multi-line python block used to arrive with its newlines intact, so the
    # awk pipeline below turned each of its LINES into a separate bullet — the
    # listing was both wrong and the single largest section of the brief (8.3 KB
    # of a 17 KB brief, against a 15 KB target for the whole thing).
    printf '\n## Commands run\n\n'
    local commands
    commands=$(jq -r --argjson w "$_CCAGE_HANDOFF_MAX_CMD_CHARS" '
        .bash_commands[]?
        | (split("\n") | map(select(length > 0)) | join(" ; "))
        | if length > $w then .[0:$w] + " …" else . end
    ' <<<"$handoff_data" | awk '
        {
            trimmed = $0
            gsub(/^[ \t]+|[ \t]+$/, "", trimmed)
            if (trimmed == "pwd" || trimmed == "ls" || trimmed == "true" || \
                trimmed == "clear" || trimmed == "exit" || trimmed == "cd") next
            print
        }
    ' | awk '!seen[$0]++')
    if [ -n "$commands" ]; then
        printf '%s\n' "$commands" | head -40 | awk '{ print "- `" $0 "`" }'
    else
        printf '_(no Bash commands recorded)_\n'
    fi

    # Last assistant turn. Neutralized like the prompts section: assistant
    # turns routinely sign off with their own `## ` headings, which are
    # otherwise indistinguishable from the brief's real sections.
    printf '\n## Last assistant turn\n\n'
    local last_text
    last_text=$(jq -r "$_CCAGE_HANDOFF_JQ_NEUTRALIZE"'.last_text // "" | neutralize' <<<"$handoff_data")
    if [ -n "$last_text" ]; then
        # Always route through the truncator. It returns short text unchanged,
        # and it owns the BYTE bound as well as the word one — gating the call
        # on a word count here meant a whitespace-free blob (one "word" at any
        # size) bypassed both, and a 50 MB last turn composed a 52 MB brief.
        _ccage_handoff_truncate_words 600 "$last_text"
    else
        printf '_(no assistant text content)_\n'
    fi

    printf '\n---\n'
    # shellcheck disable=SC2016  # literal `ccage handoff` + backticks are markdown in the user-facing footer
    printf 'Generated by `ccage handoff` from %s on %s\n' "$jsonl_label" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# ---- the main brief generator ----------------------------------------------
# Args: JSONL [--stdout | --output FILE] [--max-prompts N]
#
# Default: writes file to $CCAGE_HANDOFF_DIR (defaults to XDG location);
# prints path + paste hint to stdout. Optional clipboard copy.
_ccage_handoff_generate() {
    local jsonl=""
    local out_mode="file"   # file | stdout | explicit
    local out_path=""
    local max_prompts=20
    local include_subagents=1

    while [ $# -gt 0 ]; do
        case "$1" in
            --stdout)       out_mode=stdout; shift ;;
            --output)       out_mode=explicit; out_path="$2"; shift 2 ;;
            --max-prompts)  max_prompts="$2"; shift 2 ;;
            --no-subagents) include_subagents=0; shift ;;
            -*)             printf 'ccage handoff: unknown flag: %s\n' "$1" >&2; return 2 ;;
            *)              if [ -z "$jsonl" ]; then jsonl="$1"; else printf 'ccage handoff: too many positional args\n' >&2; return 2; fi; shift ;;
        esac
    done

    [ -n "$jsonl" ] || { printf 'ccage handoff: missing JSONL path\n' >&2; return 2; }
    [ -f "$jsonl" ] || { printf 'ccage handoff: not a file: %s\n' "$jsonl" >&2; return 2; }

    # ---- collect data (ONE jq pass over the JSONL) ----
    local handoff_data
    handoff_data=$(_ccage_handoff_collect "$jsonl")

    # Generate needs only the scalars driving the file path, age, and cost;
    # compose_brief re-extracts the full set from the same blob.
    local session_id last_ts model in_tok out_tok cw_tok cw5_tok cw1_tok cr_tok
    # cw5/cw1 fall back to attributing an unsplit cache-write total to the
    # 5-minute bucket: transcripts predating the per-TTL breakdown carry only
    # `cache_creation_input_tokens`, and 1.25x is the cheaper of the two rates,
    # so an old transcript under-states rather than inventing a premium.
    IFS=$'\t' read -r session_id last_ts model in_tok out_tok cw_tok cw5_tok cw1_tok cr_tok < <(
        jq -r '[
            (.session_id // "unknown"),
            (.last_ts // ""),
            (.last_model // "unknown"),
            .in, .out, .cw,
            (if ((.cw5 + .cw1) == 0 and .cw > 0) then .cw else .cw5 end),
            .cw1,
            .cr
        ] | @tsv' <<<"$handoff_data"
    )
    : "${session_id:=unknown}"; : "${model:=unknown}"
    : "${in_tok:=0}"; : "${out_tok:=0}"; : "${cw_tok:=0}"; : "${cr_tok:=0}"
    : "${cw5_tok:=0}"; : "${cw1_tok:=0}"

    local cost_so_far
    cost_so_far=$(_ccage_handoff_cost "$in_tok" "$out_tok" "$cw5_tok" "$cw1_tok" "$cr_tok" "$model")

    # ---- delegated work ----
    # Priced per agent (they run on different tiers) and added to the main
    # figure, so a fan-out session no longer reports only its orchestrator's
    # spend. --no-subagents restores the old main-transcript-only view.
    local subagents='[]' delegated_cost=0
    if [ "$include_subagents" = 1 ]; then
        subagents=$(_ccage_handoff_subagents_json "$jsonl")
        delegated_cost=$(jq -r '[.[].cost] | add // 0' <<<"$subagents")
    fi
    local total_cost
    total_cost=$(awk -v m="${cost_so_far#\$}" -v d="$delegated_cost" \
        'BEGIN { printf "$%.2f\n", m + d }')

    # age in seconds
    local age_sec=""
    if [ -n "$last_ts" ] && command -v date >/dev/null 2>&1; then
        local last_epoch now_epoch
        last_epoch=$(date -d "$last_ts" +%s 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%S' "${last_ts%.*}" +%s 2>/dev/null || echo "")
        now_epoch=$(date +%s)
        if [ -n "$last_epoch" ]; then
            age_sec=$((now_epoch - last_epoch))
        fi
    fi

    # ---- determine destination before composing ----
    local final_path=""
    case "$out_mode" in
        file)
            local handoff_dir
            handoff_dir="${CCAGE_HANDOFF_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ccage/handoffs}"
            mkdir -p "$handoff_dir"
            local slug session_prefix ts
            slug=$(_ccage_handoff_pwd_to_slug "$PWD")
            session_prefix="${session_id:0:8}"
            ts=$(date -u +%Y%m%d-%H%M%S)
            final_path="$handoff_dir/${slug}-${session_prefix:-unknown}-${ts}.md"
            ;;
        explicit)
            mkdir -p "$(dirname "$out_path")"
            final_path="$out_path"
            ;;
        stdout)
            final_path=""  # write directly to stdout
            ;;
    esac

    if [ -z "$final_path" ]; then
        _ccage_handoff_compose_brief "$handoff_data" "$total_cost" "$age_sec" "$max_prompts" "$jsonl" "$subagents" "$cost_so_far"
    else
        _ccage_handoff_compose_brief "$handoff_data" "$total_cost" "$age_sec" "$max_prompts" "$jsonl" "$subagents" "$cost_so_far" > "$final_path"
        printf '%s\n' "$final_path"
        if [ "$out_mode" = file ]; then
            # Paste hint + clipboard auto-copy (file mode only — stdout/explicit
            # are presumed scripted contexts).
            # shellcheck disable=SC2016  # literal `claude` and backticks are markdown in the hint
            printf '\nnext: run `claude` (fresh session) and paste this file as your first message' >&2
            if _ccage_handoff_copy_to_clipboard "$(cat "$final_path")" 2>/dev/null; then
                printf ' (also copied to clipboard)\n' >&2
            else
                printf '\n' >&2
            fi
        fi
    fi
}

# ---- cage resolution -------------------------------------------------------
# `ccage handoff` runs from a plain shell, where CLAUDE_CONFIG_DIR is unset: the
# claude() wrapper exports it with `local -x` precisely so it never leaks out.
# Defaulting to ~/.claude therefore looked in the one directory that holds no
# cage sessions. Resolution order, most explicit first:
#
#   1. --config-dir DIR
#   2. $CLAUDE_CONFIG_DIR                       (unchanged behaviour when set)
#   3. _ccage_config_dir_for from the isolation lib, when bin/ccage managed to
#      source it — the real keying rule, so CCAGE_ROOT/CCAGE_PREFIX/CCAGE_SLOT
#      and a user's _ccage_config_dir_override are all honoured
#   4. scan every cage for an .owning_path naming this project
#   5. give up, naming what was actually searched
#
# Rules 3 and 4 both require the cage to hold sessions for this project's slug;
# a cage that exists but has never run here is not an answer, and falling
# through to the scan finds the sibling slot that does. 76 cages exist on the
# author's machine and three project paths own several each (CCAGE_SLOT), so
# rule 4 must disambiguate rather than take the first hit.

# Newest .jsonl in a session dir, or nothing. `ls -t` rather than `stat`: BSD
# stat takes -f, GNU takes -c, and ordering is all we need.
_ccage_handoff_newest_session() {
    local dir="$1"
    [ -d "$dir" ] || return 1
    local newest
    # shellcheck disable=SC2012  # ls -t is fine here — session UUIDs are hex+dashes
    newest=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)
    [ -n "$newest" ] && [ -f "$newest" ] || return 1
    printf '%s\n' "$newest"
}

# _ccage_handoff_resolve_config_dir PROJECT SLUG [EXPLICIT_DIR]
_ccage_handoff_resolve_config_dir() {
    local project="$1" slug="$2" explicit="${3:-}"

    if [ -n "$explicit" ]; then
        printf '%s\n' "$explicit"
        return 0
    fi
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
        printf '%s\n' "$CLAUDE_CONFIG_DIR"
        return 0
    fi

    local keyed=""
    if command -v _ccage_config_dir_for >/dev/null 2>&1; then
        keyed=$(_ccage_config_dir_for "$project" 2>/dev/null)
        if [ -n "$keyed" ] && _ccage_handoff_newest_session "$keyed/projects/$slug" >/dev/null; then
            printf '%s\n' "$keyed"
            return 0
        fi
    fi

    # Rule 4 — .owning_path scan.
    local root="${CCAGE_ROOT:-$HOME}"
    local cage_prefix="${CCAGE_PREFIX:-.claude-}"
    local matched=() newests=()
    local cand owner newest
    for cand in "$root/$cage_prefix"*; do
        [ -d "$cand" ] || continue
        [ -f "$cand/.owning_path" ] || continue
        owner=""
        { IFS= read -r owner < "$cand/.owning_path"; } 2>/dev/null
        [ "$owner" = "$project" ] || continue
        matched+=("$cand")
        if newest=$(_ccage_handoff_newest_session "$cand/projects/$slug"); then
            newests+=("$newest")
        fi
    done

    if [ ${#newests[@]} -gt 0 ]; then
        local best chosen
        # shellcheck disable=SC2012  # ordering only; these are ccage-generated paths
        best=$(ls -t ${newests[@]+"${newests[@]}"} 2>/dev/null | head -1)
        chosen="${best%/projects/*}"
        if [ ${#matched[@]} -gt 1 ]; then
            printf 'ccage handoff: %s cages own %s:\n' "${#matched[@]}" "$project" >&2
            for cand in ${matched[@]+"${matched[@]}"}; do
                printf '  %s\n' "$cand" >&2
            done
            printf 'ccage handoff: using %s (most recent session)\n' "$chosen" >&2
        fi
        printf '%s\n' "$chosen"
        return 0
    fi

    # Rule 5 — name what was searched, never the misleading ~/.claude.
    printf 'ccage handoff: no cage with sessions for %s\n' "$project" >&2
    if [ -n "$keyed" ]; then
        local keyed_note=' (does not exist)'
        if [ -d "$keyed" ]; then
            keyed_note=' (exists, but holds no sessions for this project)'
        fi
        printf '  keyed cage:  %s%s\n' "$keyed" "$keyed_note" >&2
    fi
    if [ ${#matched[@]} -gt 0 ]; then
        printf '  cages owning this path but holding no sessions for it:\n' >&2
        for cand in ${matched[@]+"${matched[@]}"}; do
            printf '    %s\n' "$cand" >&2
        done
    else
        printf '  scanned:     %s%s* (no .owning_path matched)\n' "$root/" "$cage_prefix" >&2
    fi
    printf 'ccage handoff: pass --config-dir DIR to name the cage explicitly.\n' >&2
    return 2
}

# ---- main entry — exposed via bin/ccage handoff ----------------------------
# Args mirror ccage handoff subcommand:
#   ccage handoff [<session-id-prefix>] [--output FILE | --stdout]
#                 [--project PATH] [--config-dir DIR] [--max-prompts N]
_ccage_handoff_main() {
    local prefix=""
    local project="$PWD"
    local config_dir_flag=""
    local pass_args=()

    while [ $# -gt 0 ]; do
        # A value-taking flag given as the LAST argument used to `shift 2` with
        # only one argument left. That shift fails, nothing is consumed, and the
        # loop spins forever at 100% CPU — a typo (`ccage handoff --config-dir`)
        # hung the terminal rather than printing usage.
        case "$1" in
            --project|--config-dir|--output|--max-prompts)
                if [ $# -lt 2 ]; then
                    printf 'ccage handoff: %s needs a value\n' "$1" >&2
                    return 2
                fi
                ;;
        esac
        case "$1" in
            --project)     project="$2"; shift 2 ;;
            --config-dir)  config_dir_flag="$2"; shift 2 ;;
            --output|--max-prompts) pass_args+=("$1" "$2"); shift 2 ;;
            --stdout|--no-subagents) pass_args+=("$1"); shift ;;
            -h|--help)
                cat <<EOF
Usage: ccage handoff [<session-id-prefix>] [options]

Produce a Markdown handoff brief from a Claude Code session JSONL.
Zero API calls; reads only on-disk session history.

Options:
  --stdout             Write brief to stdout instead of a file.
  --output FILE        Write brief to FILE.
  --max-prompts N      Cap user-prompt list at N most-recent (default 20).
  --project PATH       Use PATH (not PWD) when deriving the project slug.
  --config-dir DIR     Read sessions from cage DIR instead of resolving it.
  --no-subagents       Skip delegated work; report the main transcript only.
  -h, --help           This message.

Defaults: writes to \${CCAGE_HANDOFF_DIR:-~/.local/share/ccage/handoffs}/
          <slug>-<session-prefix>-<timestamp>.md.

The cage is resolved without \$CLAUDE_CONFIG_DIR: --config-dir, then
\$CLAUDE_CONFIG_DIR, then ccage's own keying rule, then a scan of every
cage's .owning_path for one naming this project.
EOF
                return 0
                ;;
            -*)            printf 'ccage handoff: unknown flag: %s\n' "$1" >&2; return 2 ;;
            *)
                if [ -z "$prefix" ]; then prefix="$1"
                else printf 'ccage handoff: too many positional args\n' >&2; return 2
                fi
                shift
                ;;
        esac
    done

    local slug
    slug=$(_ccage_handoff_pwd_to_slug "$project")
    local config_dir
    config_dir=$(_ccage_handoff_resolve_config_dir "$project" "$slug" "$config_dir_flag") || return $?
    local session_dir="$config_dir/projects/$slug"

    local jsonl
    jsonl=$(_ccage_handoff_locate "$session_dir" "$prefix") || return $?

    PWD="$project" _ccage_handoff_generate "$jsonl" ${pass_args[@]+"${pass_args[@]}"}
}
