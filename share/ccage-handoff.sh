# shellcheck shell=bash
# ccage handoff — produce a Markdown brief from a Claude Code session JSONL.
#
# Zero API calls. Pure jq + shell. Designed for the use case "I want to start
# a fresh `claude` session and not pay -r's structural cache rewrite tax."
#
# Public entry: _ccage_handoff_main "$@"

# ---- pricing table (200K tier, cache-write = 1.25× input) -------------------
# Refresh `# updated:` and add to CHANGELOG when Anthropic publishes new rates.
# updated: 2026-05-16
_ccage_handoff_price_input() {
    case "$1" in
        claude-opus-4-7|claude-opus-4-6)   echo 15 ;;
        claude-sonnet-4-6|claude-sonnet-4-5) echo 3 ;;
        claude-haiku-4-5)                  echo 0.80 ;;
        *)                                 echo 15 ;;  # default to opus rate as conservative upper bound
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

# All jq invocations below use raw-input + slurp + `fromjson?` to tolerate
# malformed lines in the JSONL (live session files occasionally contain
# partial writes). Plain `jq -r` aborts at the first parse error — that
# would silently drop every record after a single bad line.
_CCAGE_HANDOFF_JQ_PREAMBLE='split("\n") | .[] | select(length > 0) | fromjson? // empty'

# ---- token totals -----------------------------------------------------------
# Echoes one line: "input=N output=N cache_write=N cache_read=N"
_ccage_handoff_token_totals() {
    local jsonl="$1"
    jq -Rrs "$_CCAGE_HANDOFF_JQ_PREAMBLE"'
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
    m=$(jq -Rr "$_CCAGE_HANDOFF_JQ_PREAMBLE"'
        | select(.type == "assistant" and .message.model != null and .message.model != "<synthetic>")
        | .message.model
    ' "$jsonl" 2>/dev/null | tail -1)
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
    ' "$jsonl" 2>/dev/null
}

# ---- files touched ----------------------------------------------------------
# Output: TSV — path<TAB>read_count<TAB>edit_count<TAB>write_count
_ccage_handoff_files_touched() {
    local jsonl="$1"
    jq -Rrs "$_CCAGE_HANDOFF_JQ_PREAMBLE"'
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
    jq -Rrs "$_CCAGE_HANDOFF_JQ_PREAMBLE"'
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
    jq -Rrs "$_CCAGE_HANDOFF_JQ_PREAMBLE"'
        | select(.type == "assistant")
        | .message.content[]?
        | select(.type == "text")
        | .text
        | select(length > 0)
    ' "$jsonl" 2>/dev/null | tail -1
}

# ---- timestamps -------------------------------------------------------------
_ccage_handoff_first_timestamp() {
    local jsonl="$1"
    jq -Rrs "$_CCAGE_HANDOFF_JQ_PREAMBLE"'
        | select(.timestamp != null) | .timestamp
    ' "$jsonl" 2>/dev/null | head -1
}
_ccage_handoff_last_timestamp() {
    local jsonl="$1"
    jq -Rrs "$_CCAGE_HANDOFF_JQ_PREAMBLE"'
        | select(.timestamp != null) | .timestamp
    ' "$jsonl" 2>/dev/null | tail -1
}

_ccage_handoff_session_id() {
    local jsonl="$1"
    jq -Rrs "$_CCAGE_HANDOFF_JQ_PREAMBLE"'
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
_ccage_handoff_truncate_words() {
    local max="$1" text="$2"
    local n
    n=$(printf '%s' "$text" | awk '{n+=NF} END {print n+0}')
    if [ "$n" -le "$max" ]; then
        printf '%s\n' "$text"
        return
    fi
    local half=$((max / 2))
    local first last
    first=$(printf '%s' "$text" | awk -v h="$half" 'BEGIN{c=0} {for(i=1;i<=NF;i++){c++; printf "%s%s", $i, (c==h?ORS:OFS); if(c==h) exit}}')
    last=$(printf '%s' "$text" | awk -v h="$half" '{for(i=1;i<=NF;i++) buf[NR"-"i]=$i; tot+=NF} END{from=tot-h+1; printed=0; for(j=1;j<=NR;j++) for(i=1;i<=NF && (j"-"i in buf);i++){if(++c>=from){printf "%s%s", buf[j"-"i], (c==tot?ORS:OFS)}}}')
    printf '%s\n…(%d words elided)…\n%s\n' "$first" $((n - max)) "$last"
}

# ---- compute estimated cost (dollars, 2 decimal) ----------------------------
# Args: tokens model
# Echoes a dollar amount like "$0.08"
_ccage_handoff_cost() {
    local tokens="$1" model="$2"
    local rate
    rate=$(_ccage_handoff_price_cache_write "$model")
    awk -v t="$tokens" -v r="$rate" 'BEGIN { printf "$%.2f\n", t / 1000000 * r }'
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

    # ---- collect data ----
    local session_id first_ts last_ts model
    session_id=$(_ccage_handoff_session_id "$jsonl")
    first_ts=$(_ccage_handoff_first_timestamp "$jsonl")
    last_ts=$(_ccage_handoff_last_timestamp "$jsonl")
    model=$(_ccage_handoff_last_model "$jsonl")

    local prompt_count assistant_count
    prompt_count=$(_ccage_handoff_count_prompts "$jsonl")
    assistant_count=$(_ccage_handoff_count_assistants "$jsonl")

    local totals
    totals=$(_ccage_handoff_token_totals "$jsonl")
    # parse totals into vars
    local in_tok out_tok cw_tok cr_tok
    in_tok=$(printf '%s\n' "$totals" | sed -n 's/.*input=\([0-9]*\).*/\1/p')
    out_tok=$(printf '%s\n' "$totals" | sed -n 's/.*output=\([0-9]*\).*/\1/p')
    cw_tok=$(printf '%s\n' "$totals" | sed -n 's/.*cache_write=\([0-9]*\).*/\1/p')
    cr_tok=$(printf '%s\n' "$totals" | sed -n 's/.*cache_read=\([0-9]*\).*/\1/p')

    local cost_so_far
    cost_so_far=$(_ccage_handoff_cost "${cw_tok:-0}" "$model")

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
    # Bats runs tests with `set -ET` (errtrace + functrace), which causes
    # RETURN traps in this function to fire on every sub-function return
    # too — making a `mktemp` + `trap RETURN rm` pattern unsafe (the temp
    # would be deleted mid-write). Instead, decide destination up front and
    # stream directly into it.
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

    _ccage_handoff_compose_brief() {
        printf '# Handoff: %s\n\n' "${session_id:-unknown}"
        printf '**Project:** %s\n' "${PWD:-unknown}"
        printf '**Started:** %s\n' "${first_ts:-unknown}"
        if [ -n "$age_sec" ]; then
            printf '**Last activity:** %s (%s)\n' "$last_ts" "$(_ccage_handoff_age_human "$age_sec")"
        else
            printf '**Last activity:** %s\n' "${last_ts:-unknown}"
        fi
        printf '**Turns:** %s user / %s assistant\n' "$prompt_count" "$assistant_count"
        printf '**Tokens billed so far:** %s input · %s output · %s cache-write · %s cache-read\n' \
            "${in_tok:-0}" "${out_tok:-0}" "${cw_tok:-0}" "${cr_tok:-0}"
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
            local prompts_json
            prompts_json=$(_ccage_handoff_prompts_json "$jsonl")
            # extract last N prompts from JSON array, numbered
            printf '%s' "$prompts_json" | jq -r --argjson n "$shown_n" --argjson start "$((total_prompts - shown_n))" '
                .[$start:] | to_entries | .[] | "\($start + .key + 1). \(.value)\n"
            '
            if [ "$total_prompts" -gt "$max_prompts" ]; then
                printf '\n_(%d earlier prompt(s) elided — see raw JSONL for full history)_\n' \
                    $((total_prompts - shown_n))
            fi
        else
            printf '_(no user prompts recorded in this session)_\n'
        fi

        # Files touched section
        printf '\n## Files touched\n\n'
        local files_table
        files_table=$(_ccage_handoff_files_touched "$jsonl")
        if [ -n "$files_table" ]; then
            printf '| Path | Read | Edit | Write |\n'
            printf '|---|---:|---:|---:|\n'
            # cap at 30 rows
            printf '%s\n' "$files_table" | head -30 | awk -F'\t' '{ printf "| %s | %d | %d | %d |\n", $1, $2, $3, $4 }'
        else
            printf '_(no files touched via Read/Edit/Write in this session)_\n'
        fi

        # Commands section
        printf '\n## Commands run\n\n'
        local commands
        commands=$(_ccage_handoff_bash_commands "$jsonl")
        if [ -n "$commands" ]; then
            # cap at 40
            printf '%s\n' "$commands" | head -40 | awk '{ print "- `" $0 "`" }'
        else
            printf '_(no Bash commands recorded)_\n'
        fi

        # Last assistant turn
        printf '\n## Last assistant turn\n\n'
        local last_text
        last_text=$(_ccage_handoff_last_assistant_text "$jsonl")
        if [ -n "$last_text" ]; then
            local words
            words=$(printf '%s' "$last_text" | awk '{n+=NF} END {print n+0}')
            if [ "$words" -gt 600 ]; then
                _ccage_handoff_truncate_words 600 "$last_text"
            else
                printf '%s\n' "$last_text"
            fi
        else
            printf '_(no assistant text content)_\n'
        fi

        printf '\n---\n'
        # shellcheck disable=SC2016  # literal `ccage handoff` in user-facing footer
        # shellcheck disable=SC2016  # backticks inside the literal are markdown, not shell expansion
        printf 'Generated by `ccage handoff` from %s on %s\n' "$jsonl" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    }

    if [ -z "$final_path" ]; then
        _ccage_handoff_compose_brief
    else
        _ccage_handoff_compose_brief > "$final_path"
        printf '%s\n' "$final_path"
        if [ "$out_mode" = file ]; then
            # Paste hint + clipboard auto-copy (file mode only — stdout/explicit
            # are presumed scripted contexts).
            # shellcheck disable=SC2016  # literal `claude` in user-facing hint
            # shellcheck disable=SC2016  # backticks are markdown literals
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
