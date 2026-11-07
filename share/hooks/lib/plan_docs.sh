# shellcheck shell=bash
# Plan-doc discovery and checkbox counting, shared by hooks/resume_autoload.sh (session start)
# and statusline-command.sh (the live status line), so the two can never disagree about what a
# project's plan is or how much of it is open. Source it; it defines functions only.

# plan_doc_paths RESUME BASE
#   Every `.md` path named in RESUME's `### Plan` section that exists on disk, one per line, in
#   listing order, de-duplicated. `~/` expands to $HOME; a relative path resolves against BASE.
#   No cap here: callers that cap must announce what they drop (resume_autoload does).
plan_doc_paths() {
    local resume="$1" base="$2" ref cand
    [ -f "$resume" ] || return 0
    awk '
            /^###[[:space:]]+Plan[[:space:]]*$/ { inplan=1; next }
            inplan && /^##/                     { inplan=0 }
            inplan
        ' "$resume" 2>/dev/null \
        | grep -oE '[~/A-Za-z0-9._-][A-Za-z0-9._/~-]*\.md' 2>/dev/null \
        | awk '!seen[$0]++' \
        | while IFS= read -r ref; do
            # shellcheck disable=SC2088  # the "~/" pattern matches literal text from RESUME
            case "$ref" in
                "~/"*) cand="$HOME/${ref#\~/}" ;;
                /*)    cand="$ref" ;;
                *)     cand="$base/$ref" ;;
            esac
            [ -f "$cand" ] && printf '%s\n' "$cand"
        done
}

# plan_box_counts DOC
#   Prints "OPEN DONE VAGUE": open `- [ ]` items, done `- [x]` items, and open items that name
#   no file (no backtick and no `/`), i.e. whose write set is unstated.
plan_box_counts() {
    local doc="$1" open_n done_n vague
    open_n="$(grep -cE '^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]' "$doc" 2>/dev/null || true)"
    done_n="$(grep -cE '^[[:space:]]*[-*][[:space:]]+\[[xX]\]' "$doc" 2>/dev/null || true)"
    vague="$(grep -E '^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]' "$doc" 2>/dev/null \
        | grep -cvE '`|/' 2>/dev/null || true)"
    printf '%s %s %s\n' "${open_n:-0}" "${done_n:-0}" "${vague:-0}"
}

# plan_open_unchecked DOC
#   Prints the ID (first word after the box) of every open `- [ ]` item that carries no
#   ` — done when: `command`` check, one per line: items nothing can verify (plan contract,
#   lib/ccage_plan.py).
plan_open_unchecked() {
    # shellcheck disable=SC2016  # literal backticks are the pattern
    grep -E '^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]' "$1" 2>/dev/null \
        | grep -vE ' — done when: `[^`]+`[[:space:]]*$' \
        | sed -E 's/^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\][[:space:]]+([^[:space:]]+).*/\1/'
}

# plan_ticked_missing DOC
#   Prints, one per line, every path-looking backticked token on a DONE (`- [x]`) line that does
#   not exist on disk: a tick whose deliverable is absent. A token is path-looking when it starts
#   with `/`, `~/` or `./`, or contains `/` and ends in an extension. Relative paths resolve
#   against DOC's git root (its own directory when not in a repo); `~` expands to $HOME.
plan_ticked_missing() {
    local doc="$1" root tok p
    [ -f "$doc" ] || return 0
    root="$(git -C "$(dirname "$doc")" rev-parse --show-toplevel 2>/dev/null)" || root="$(dirname "$doc")"
    # shellcheck disable=SC2016  # literal backticks are the pattern
    grep -E '^[[:space:]]*[-*][[:space:]]+\[[xX]\]' "$doc" 2>/dev/null \
        | grep -oE '`[^`]+`' \
        | tr -d '`' \
        | while IFS= read -r tok; do
            # shellcheck disable=SC2088  # "~/" matches literal text from the plan; no expansion intended
            case "$tok" in
                *[[:space:]]*) continue ;;
                /*|"~/"*|./*) ;;
                */*.[A-Za-z0-9]*) ;;
                *) continue ;;
            esac
            # shellcheck disable=SC2088
            case "$tok" in
                "~/"*) p="$HOME/${tok#\~/}" ;;
                /*)    p="$tok" ;;
                *)     p="$root/$tok" ;;
            esac
            [ -e "$p" ] || printf '%s\n' "$tok"
        done
}

# plan_live_files BASE
#   Every git-tracked markdown plan under BASE that still holds an open `- [ ]` box, one path
#   per line (BASE/relative). A plan is a file in a plan/, plans/ or planning/ folder, or whose
#   name has the word "plan", "plans" or "planning" (coverage-plan-2026.md, X_PLAN.md; not
#   explanation.md or plant-care.md). Files under archive/ or records/ folders are left out:
#   that is where superseded plans go (the programme-plan skill). Prints nothing outside git.
plan_live_files() {
    local base="$1"
    # one grep over every candidate, not one per file; quotePath off keeps non-ASCII names plain
    (cd "$base" 2>/dev/null && git -c core.quotePath=false ls-files -- '*.md' 2>/dev/null \
        | grep -iE '(^|/)plan(s|ning)?/|(^|[/_.-])plan(s|ning)?([^/[:alpha:]][^/]*)?\.md$' \
        | grep -viE '(^|/)(archive|archived|records?)/' \
        | xargs -r -d '\n' grep -lE '^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]' -- 2>/dev/null) \
        | while IFS= read -r rel; do printf '%s/%s\n' "$base" "$rel"; done
}
