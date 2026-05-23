# shellcheck shell=bash
# ccage handoff — produce a Markdown brief from a Claude Code session JSONL.
#
# Zero API calls. Pure jq + shell. Designed for the use case "I want to start
# a fresh `claude` session and not pay -r's structural cache rewrite tax."
#
# Public entry: _ccage_handoff_main "$@"

# ---- pricing table (200K tier; rates per million tokens) --------------------
# Cache-write = 1.25× input. Cache-read = 0.1× input. Refresh `# updated:` and
# add to CHANGELOG when Anthropic publishes new rates.
# updated: 2026-05-16
_ccage_handoff_price_input() {
    case "$1" in
        claude-opus-4-7|claude-opus-4-6)   echo 15 ;;
        claude-sonnet-4-6|claude-sonnet-4-5) echo 3 ;;
        claude-haiku-4-5)                  echo 0.80 ;;
        *)                                 echo 15 ;;
    esac
}
_ccage_handoff_price_output() {
    case "$1" in
        claude-opus-4-7|claude-opus-4-6)   echo 75 ;;
        claude-sonnet-4-6|claude-sonnet-4-5) echo 15 ;;
        claude-haiku-4-5)                  echo 4 ;;
        *)                                 echo 75 ;;
    esac
}
_ccage_handoff_price_cache_write() {
    case "$1" in
        claude-opus-4-7|claude-opus-4-6)   echo 18.75 ;;
        claude-sonnet-4-6|claude-sonnet-4-5) echo 3.75 ;;
        claude-haiku-4-5)                  echo 1.00 ;;
        *)                                 echo 18.75 ;;
    esac
}
_ccage_handoff_price_cache_read() {
    case "$1" in
        claude-opus-4-7|claude-opus-4-6)   echo 1.50 ;;
        claude-sonnet-4-6|claude-sonnet-4-5) echo 0.30 ;;
        claude-haiku-4-5)                  echo 0.08 ;;
        *)                                 echo 1.50 ;;
    esac
}

# ---- pwd-to-slug ------------------------------------------------------------
# Claude Code derives project slugs from CWD by replacing `/` with `-`.
# Verified empirically across ~/.claude/projects/ directories.
_ccage_handoff_pwd_to_slug() {
    local p="${1:-$PWD}"
    printf '%s\n' "${p//\//-}"
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
    jq -Rrs '
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
    jq -Rs '
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
        | map(select(
            (startswith("<command-name>") | not)
            and (startswith("<local-command-stdout>") | not)
            and (startswith("<system-reminder>") | not)
            and (startswith("<command-message>") | not)
            and (startswith("<command-args>") | not)
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
_ccage_handoff_collect() {
    local jsonl="$1"
    [ -f "$jsonl" ] || {
        printf '%s\n' '{"session_id":null,"first_ts":null,"last_ts":null,"last_model":null,"assistant_count":0,"in":0,"out":0,"cw":0,"cr":0,"prompts":[],"files":{},"bash_commands":[],"last_text":null}'
        return 0
    }
    jq -cRn '
        reduce (inputs | fromjson? // empty) as $r (
            { session_id: null, first_ts: null, last_ts: null, last_model: null,
              assistant_count: 0, in: 0, out: 0, cw: 0, cr: 0,
              prompts: [], files: {}, bash_commands: [], last_text: null };
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
                  | ( if ($r.message.model // null) != null
                        and $r.message.model != "<synthetic>"
                      then .last_model = $r.message.model else . end )
                  | .in += ($r.message.usage.input_tokens // 0)
                  | .out += ($r.message.usage.output_tokens // 0)
                  | .cw  += ($r.message.usage.cache_creation_input_tokens // 0)
                  | .cr  += ($r.message.usage.cache_read_input_tokens // 0)
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
            # user prompts: filter meta + tool-result + synthetic slash-command echoes
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
                      then .prompts += [$text] else . end )
                else . end )
        )
    ' "$jsonl" 2>/dev/null
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
# Args: input_tokens output_tokens cache_write_tokens cache_read_tokens model
# Echoes a dollar amount like "$9.25" representing the cumulative spend across
# all four billing components: input + output + cache-write + cache-read.
_ccage_handoff_cost() {
    local in_tok="$1" out_tok="$2" cw_tok="$3" cr_tok="$4" model="$5"
    local in_rate out_rate cw_rate cr_rate
    in_rate=$(_ccage_handoff_price_input "$model")
    out_rate=$(_ccage_handoff_price_output "$model")
    cw_rate=$(_ccage_handoff_price_cache_write "$model")
    cr_rate=$(_ccage_handoff_price_cache_read "$model")
    # Note: gawk reserves `or` as a builtin — use `outr` instead.
    awk -v i="$in_tok" -v o="$out_tok" -v cw="$cw_tok" -v cr="$cr_tok" \
        -v ir="$in_rate" -v outr="$out_rate" -v cwr="$cw_rate" -v crr="$cr_rate" \
        'BEGIN {
            total = i*ir + o*outr + cw*cwr + cr*crr
            printf "$%.2f\n", total / 1000000
        }'
}

# ---- clipboard helpers -----------------------------------------------------
# Try pbcopy → wl-copy → xclip → xsel. First found wins. Silent skip if none.
# Returns 0 on success (clipboard set), 1 if no tool found.
_ccage_handoff_copy_to_clipboard() {
    local content="$1"
    if command -v pbcopy >/dev/null 2>&1; then
        printf '%s' "$content" | pbcopy && return 0
    elif command -v wl-copy >/dev/null 2>&1; then
        printf '%s' "$content" | wl-copy && return 0
    elif command -v xclip >/dev/null 2>&1; then
        printf '%s' "$content" | xclip -selection clipboard && return 0
    elif command -v xsel >/dev/null 2>&1; then
        printf '%s' "$content" | xsel --clipboard --input && return 0
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
_ccage_handoff_compose_brief() {
    local handoff_data="$1"
    local cost_so_far="$2"
    local age_sec="$3"
    local max_prompts="$4"
    local jsonl_label="$5"

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

    printf '# Handoff: %s\n\n' "$session_id"
    printf '**Project:** %s\n' "${PWD:-unknown}"
    printf '**Started:** %s\n' "${first_ts:-unknown}"
    if [ -n "$age_sec" ]; then
        printf '**Last activity:** %s (%s)\n' "$last_ts" "$(_ccage_handoff_age_human "$age_sec")"
    else
        printf '**Last activity:** %s\n' "${last_ts:-unknown}"
    fi
    printf '**Turns:** %s user / %s assistant\n' "$prompt_count" "$assistant_count"
    printf '**Tokens billed so far:** %s input · %s output · %s cache-write · %s cache-read\n' \
        "$in_tok" "$out_tok" "$cw_tok" "$cr_tok"
    printf '**Estimated cost so far:** ~%s (%s, 200K tier)\n' "$cost_so_far" "$model"
    printf '**Last model used:** %s\n' "$model"
    printf '\n'

    # User prompts section
    local total_prompts="$prompt_count"
    local shown_n="$max_prompts"
    [ "$shown_n" -gt "$total_prompts" ] && shown_n="$total_prompts"
    if [ "$total_prompts" -le "$max_prompts" ]; then
        printf '## User prompts\n\n'
    else
        printf '## User prompts (last %s of %s)\n\n' "$shown_n" "$total_prompts"
    fi

    if [ "$total_prompts" -gt 0 ]; then
        jq -r --argjson n "$shown_n" --argjson start "$((total_prompts - shown_n))" '
            .prompts[$start:] | to_entries | .[] | "\($start + .key + 1). \(.value)\n"
        ' <<<"$handoff_data"
        if [ "$total_prompts" -gt "$max_prompts" ]; then
            printf '\n_(%d earlier prompt(s) elided — see raw JSONL for full history)_\n' \
                $((total_prompts - shown_n))
        fi
    else
        printf '_(no user prompts recorded in this session)_\n'
    fi

    # Files touched section — sort by total touches desc.
    printf '\n## Files touched\n\n'
    local files_table
    files_table=$(jq -r '
        .files | to_entries
        | map(. + {total: (.value.Read + .value.Edit + .value.Write)})
        | sort_by(-.total)
        | .[] | "\(.key)\t\(.value.Read)\t\(.value.Edit)\t\(.value.Write)"
    ' <<<"$handoff_data")
    if [ -n "$files_table" ]; then
        printf '| Path | Read | Edit | Write |\n'
        printf '|---|---:|---:|---:|\n'
        printf '%s\n' "$files_table" | head -30 | awk -F'\t' '{ printf "| %s | %d | %d | %d |\n", $1, $2, $3, $4 }'
    else
        printf '_(no files touched via Read/Edit/Write in this session)_\n'
    fi

    # Commands section — dedup + trivial-filter (same as the standalone helper).
    printf '\n## Commands run\n\n'
    local commands
    commands=$(jq -r '.bash_commands[]?' <<<"$handoff_data" | awk '
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

    # Last assistant turn
    printf '\n## Last assistant turn\n\n'
    local last_text
    last_text=$(jq -r '.last_text // ""' <<<"$handoff_data")
    if [ -n "$last_text" ]; then
        local words
        words=$(printf '%s' "$last_text" | wc -w)
        if [ "$words" -gt 600 ]; then
            _ccage_handoff_truncate_words 600 "$last_text"
        else
            printf '%s\n' "$last_text"
        fi
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

    while [ $# -gt 0 ]; do
        case "$1" in
            --stdout)       out_mode=stdout; shift ;;
            --output)       out_mode=explicit; out_path="$2"; shift 2 ;;
            --max-prompts)  max_prompts="$2"; shift 2 ;;
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
    local session_id last_ts model in_tok out_tok cw_tok cr_tok
    IFS=$'\t' read -r session_id last_ts model in_tok out_tok cw_tok cr_tok < <(
        jq -r '[
            (.session_id // "unknown"),
            (.last_ts // ""),
            (.last_model // "unknown"),
            .in, .out, .cw, .cr
        ] | @tsv' <<<"$handoff_data"
    )
    : "${session_id:=unknown}"; : "${model:=unknown}"
    : "${in_tok:=0}"; : "${out_tok:=0}"; : "${cw_tok:=0}"; : "${cr_tok:=0}"

    local cost_so_far
    cost_so_far=$(_ccage_handoff_cost "$in_tok" "$out_tok" "$cw_tok" "$cr_tok" "$model")

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
        _ccage_handoff_compose_brief "$handoff_data" "$cost_so_far" "$age_sec" "$max_prompts" "$jsonl"
    else
        _ccage_handoff_compose_brief "$handoff_data" "$cost_so_far" "$age_sec" "$max_prompts" "$jsonl" > "$final_path"
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

# ---- main entry — exposed via bin/ccage handoff ----------------------------
# Args mirror ccage handoff subcommand:
#   ccage handoff [<session-id-prefix>] [--output FILE | --stdout]
#                 [--project PATH] [--max-prompts N]
_ccage_handoff_main() {
    local prefix=""
    local project="$PWD"
    local pass_args=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --project)     project="$2"; shift 2 ;;
            --output|--max-prompts) pass_args+=("$1" "$2"); shift 2 ;;
            --stdout)      pass_args+=("$1"); shift ;;
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
  -h, --help           This message.

Defaults: writes to \${CCAGE_HANDOFF_DIR:-~/.local/share/ccage/handoffs}/
          <slug>-<session-prefix>-<timestamp>.md.
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

    local config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    local slug
    slug=$(_ccage_handoff_pwd_to_slug "$project")
    local session_dir="$config_dir/projects/$slug"

    local jsonl
    jsonl=$(_ccage_handoff_locate "$session_dir" "$prefix") || return $?

    PWD="$project" _ccage_handoff_generate "$jsonl" "${pass_args[@]}"
}
