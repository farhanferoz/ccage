#!/usr/bin/env bash
# Search every skill on disk, including ones not active in this cage, and
# activate one on demand.
#
# WHY THIS EXISTS: a cage's skills/ is normally a symlink to the master dir, so
# every cage lists every skill. Measured 2026-08-10: 150 listed skills cost
# ~9,400 tokens of context at every session start, in all 80 cages, while only
# 27 distinct skills were invoked across 955 sessions and 123 were never
# invoked once. Scoping a cage to a small core recovers that context, but an
# unlisted skill is invisible -- the model cannot suggest what it cannot see.
#
# This restores discoverability at roughly 50 tokens instead of 9,400: the
# catalog is searched on demand, and `--add` symlinks a skill into the live
# cage. VERIFIED 2026-08-10: a skill symlinked in mid-session is immediately
# invocable by the Skill tool (transcript shows TOOL_USE Skill{find-bugs} ->
# "Launching skill: find-bugs"), so activation needs no restart.

set -uo pipefail

# SECOND MECHANISM, added 2026-08-11: a skill can also be switched off in
# settings.json (`skillOverrides: {"name": "off"}`), which is how the 80
# never-invoked skills were culled. That is INDEPENDENT of the symlink: an
# overridden skill stays invisible no matter what this script links in. Without
# the checks below, `--add` would symlink it, print "activated", and the skill
# would still not appear -- a silent false success, which is precisely the
# failure class this tool exists to prevent.
MASTER="${CCAGE_SHARE_FROM:-$HOME/.claude}/skills"
CAGE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CAGE_SKILLS="$CAGE_DIR/skills"
CAGE_SETTINGS="$CAGE_DIR/settings.json"

# Is this skill switched off in settings? Prints the override value, or nothing.
skill_override() {
    [ -r "$CAGE_SETTINGS" ] || return 0
    python3 - "$CAGE_SETTINGS" "$1" <<'PY' 2>/dev/null || true
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
v = (s.get("skillOverrides") or {}).get(sys.argv[2])
if v in ("off", "user-invocable-only"):
    print(v)
PY
}

# Clear the override so an explicitly requested skill can actually appear.
# Asking for it by name IS the intent to re-enable it.
clear_override() {
    python3 - "$CAGE_SETTINGS" "$1" <<'PY'
import json, shutil, sys, time
p, name = sys.argv[1], sys.argv[2]
s = json.load(open(p))
ov = s.get("skillOverrides") or {}
if name not in ov:
    sys.exit(0)
shutil.copy2(p, "%s.bak-%s" % (p, time.strftime("%Y%m%d-%H%M%S")))
del ov[name]
if not ov:
    s.pop("skillOverrides", None)
json.dump(s, open(p, "w"), indent=2)
json.load(open(p))          # re-parse or the cage is broken
PY
}

usage() {
    cat <<'EOF'
usage: skill-catalog.sh <query>...      search all skills on disk
       skill-catalog.sh --list          list every skill, active first
       skill-catalog.sh --add <name>    activate a skill in this cage now
       skill-catalog.sh --selftest      verify the catalog can parse the master dir

--add symlinks the skill in, which is live immediately. If the skill is also
switched OFF in settings.json (shown as [OFF]), --add clears that too, but the
override is read at launch -- so that part needs the next session to take effect.
EOF
}

# Frontmatter `name:` / `description:` of a SKILL.md, as one tab-separated row.
# Descriptions wrap across lines and may be quoted or folded, so join the
# continuation lines rather than reading only the first.
skill_row() {
    local f="$1" dir_name
    dir_name="$(basename "$(dirname "$f")")"
    awk -v dn="$dir_name" '
        /^---[[:space:]]*$/ { fm++; if (fm == 2) exit; next }
        fm != 1 { next }
        /^name:[[:space:]]*/     { sub(/^name:[[:space:]]*/, "");        gsub(/^["'"'"']|["'"'"']$/, ""); name = $0; next }
        /^description:[[:space:]]*/ { sub(/^description:[[:space:]]*/, ""); collecting = 1; desc = $0; next }
        /^[a-zA-Z_-]+:/          { collecting = 0; next }
        collecting               { sub(/^[[:space:]]+/, " "); desc = desc $0 }
        END {
            if (name == "") name = dn
            # A folded/literal block scalar (`description: >` or `|`) leaves the
            # marker as the first token; strip it plus any leading whitespace.
            sub(/^[>|][-+0-9]*[[:space:]]*/, "", desc)
            gsub(/^["'"'"']|["'"'"']$/, "", desc)
            gsub(/\t/, " ", desc)
            sub(/^[[:space:]]+/, "", desc)
            printf "%s\t%s\n", name, desc
        }
    ' "$f"
}

# Every SKILL.md under the master dir (and any plugin skill dirs alongside it).
# -L is load-bearing: 13 of this master dir's 126 entries are SYMLINKS to skill
# directories (plugin skills linked in), and plain `find` does not descend into
# a symlinked dir -- without -L the catalog silently omits them, which is the
# exact failure this tool exists to prevent.
all_skill_files() {
    find -L "$MASTER" -mindepth 2 -maxdepth 2 -name SKILL.md 2>/dev/null | sort
}

is_active() {
    [ -e "$CAGE_SKILLS/$1" ]
}

# A cage whose skills/ is a symlink is UNSCOPED -- it already sees everything,
# and --add would write into the shared master dir for every other cage.
scoping_enabled() {
    [ -d "$CAGE_SKILLS" ] && [ ! -L "$CAGE_SKILLS" ]
}

cmd_add() {
    local want="$1" f name ov
    # UNSCOPED no longer implies "everything is listed" (2026-08-11): 80 skills
    # are hidden by settings overrides instead of by symlink, and every cage was
    # returned to the plain master symlink. Bailing out here made `--add` a
    # no-op in the ONLY configuration we now run. So in the unscoped case the
    # override IS the whole job -- do it, and only refuse when there is
    # genuinely nothing to change.
    if ! scoping_enabled; then
        ov="$(skill_override "$want")"
        if [ -z "$ov" ]; then
            printf 'skill-catalog: %s is already listed in this cage (%s is the master symlink)\n' \
                "$want" "$CAGE_SKILLS" >&2
            printf '  and carries no override, so there is nothing to activate.\n' >&2
            return 1
        fi
        if clear_override "$want"; then
            printf 'cleared the "%s" override for %s in %s\n' "$ov" "$want" "$CAGE_SETTINGS"
            printf 'It appears at the NEXT session start -- the override is read at launch.\n'
            return 0
        fi
        printf 'skill-catalog: failed to clear the "%s" override for %s\n' "$ov" "$want" >&2
        return 1
    fi
    while IFS= read -r f; do
        name="$(skill_row "$f" | cut -f1)"
        if [ "$name" = "$want" ] || [ "$(basename "$(dirname "$f")")" = "$want" ]; then
            local src
            src="$(dirname "$f")"
            if [ -e "$CAGE_SKILLS/$want" ]; then
                printf 'already active: %s\n' "$want"
                return 0
            fi
            ln -sfn "$src" "$CAGE_SKILLS/$want" || return 1
            printf 'activated: %s -> %s\n' "$want" "$src"
            ov="$(skill_override "$want")"
            if [ -n "$ov" ]; then
                if clear_override "$want"; then
                    printf 'ALSO cleared its "%s" override in %s.\n' "$ov" "$CAGE_SETTINGS"
                    printf 'That part takes effect at the NEXT session start, not now --\n'
                    printf 'the symlink is live immediately but the override is read at launch.\n'
                else
                    printf 'WARNING: it is set to "%s" in %s and clearing that failed.\n' \
                        "$ov" "$CAGE_SETTINGS" >&2
                    printf 'The symlink alone will NOT make it visible. Remove the entry by hand.\n' >&2
                    return 1
                fi
            else
                printf 'It is usable now, in this session -- invoke it with the Skill tool.\n'
            fi
            return 0
        fi
    done < <(all_skill_files)
    printf 'skill-catalog: no skill named %s under %s\n' "$want" "$MASTER" >&2
    return 1
}

cmd_search() {
    local -a terms=("$@")
    local f row name desc hay hit t found=0
    while IFS= read -r f; do
        row="$(skill_row "$f")"
        name="${row%%	*}"
        desc="${row#*	}"
        hay="$(printf '%s %s' "$name" "$desc" | tr '[:upper:]' '[:lower:]')"
        hit=1
        for t in "${terms[@]}"; do
            case "$hay" in
                *"$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')"*) ;;
                *) hit=0; break ;;
            esac
        done
        [ "$hit" = 1 ] || continue
        found=$((found + 1))
        if [ -n "$(skill_override "$name")" ]; then
            printf '%-34s [OFF]     %.120s\n' "$name" "$desc"
        elif is_active "$name"; then
            printf '%-34s [ACTIVE]  %.120s\n' "$name" "$desc"
        else
            printf '%-34s [add]     %.120s\n' "$name" "$desc"
        fi
    done < <(all_skill_files)
    if [ "$found" = 0 ]; then
        printf 'no skill matches: %s\n' "${terms[*]}"
        return 1
    fi
    printf '\n%d match(es). Activate one with: skill-catalog.sh --add <name>\n' "$found"
}

cmd_selftest() {
    local n_files n_parsed
    n_files="$(all_skill_files | wc -l)"
    n_parsed="$(all_skill_files | while IFS= read -r f; do skill_row "$f"; done | grep -c '	')"
    printf 'master dir      : %s\n' "$MASTER"
    printf 'cage skills dir : %s%s\n' "$CAGE_SKILLS" \
        "$(scoping_enabled && printf ' (scoped)' || printf ' (UNSCOPED symlink)')"
    printf 'SKILL.md found  : %s\n' "$n_files"
    printf 'rows parsed     : %s\n' "$n_parsed"
    [ "$n_files" -gt 0 ] && [ "$n_files" = "$n_parsed" ] || {
        printf 'FAIL: %s files but %s parsed\n' "$n_files" "$n_parsed" >&2
        return 1
    }
    printf 'PASS\n'
}

case "${1:-}" in
    ""|-h|--help) usage ;;
    --selftest)   cmd_selftest ;;
    --list)       cmd_search "" ;;
    --add)        [ $# -ge 2 ] || { usage >&2; exit 2; }; cmd_add "$2" ;;
    *)            cmd_search "$@" ;;
esac
