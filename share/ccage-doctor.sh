# shellcheck shell=bash
# ccage doctor — one-shot cross-cage health sweep + hooks backfill.
#
# For every cage under $CCAGE_ROOT/$CCAGE_PREFIX* that carries a .owning_path:
#   1. Backfill the session-docs hooks block into its settings.json — the safe,
#      idempotent merge (preserves every existing key; only adds a missing
#      SessionStart/PostToolUse entry). This resurrects the budget hook and wires
#      the auto-read hook into cages created before Phase 7.
#   2. Scan the cage's owning repo for a bloated RESUME and the cage's memory dir
#      for "unorganized" signals, and print a prioritized worklist of the
#      judgment fixes (visit those repos and run /checkpoint there).
#
# --dry-run previews everything without writing. Public entry: _ccage_doctor_main.
#
# Zero API calls; pure shell + python3 (for the JSON merge) + grep/find.

# ---------------------------------------------------------------------------
# Hooks-block merge. KEEP IN SYNC with _ccage_seed_session_docs_hooks in
# share/claude-isolation.sh — same shape, plus an apply flag and a changed/
# unchanged signal on stdout so --dry-run can report without writing.
# ---------------------------------------------------------------------------
_ccage_doctor_seed() {
    local settings="$1" hooks_dir="$2" apply="$3" want_autoload="$4" want_budget="$5"
    python3 - "$settings" "$hooks_dir" "$apply" "$want_autoload" "$want_budget" <<'PY' 2>/dev/null
import json, os, sys, tempfile
settings_path, hooks_dir, apply = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
want_autoload, want_budget = sys.argv[4] == "1", sys.argv[5] == "1"
autoload_cmd = "bash " + os.path.join(hooks_dir, "resume_autoload.sh")
budget_cmd   = "bash " + os.path.join(hooks_dir, "resume_budget_check.sh")
# Preserve an existing file's mode; never clobber a present-but-unparseable
# settings.json (report it as unchanged and leave it for the user to fix).
mode = None
if os.path.exists(settings_path):
    try:
        mode = os.stat(settings_path).st_mode & 0o777
    except OSError:
        pass
    try:
        with open(settings_path) as f:
            data = json.load(f)
    except ValueError:
        print("unchanged"); sys.exit(0)
    except OSError:
        data = {}
    if not isinstance(data, dict):
        data = {}
else:
    data = {}
hooks = data.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}
def script_base(cmd):
    return os.path.basename(cmd.split()[-1]) if cmd else ""
def has_cmd(entries, cmd):
    # Dedup on the script BASENAME so a differing CCAGE_HOOKS_DIR never appends
    # a duplicate entry. KEEP IN SYNC with _ccage_seed_session_docs_hooks.
    want = script_base(cmd)
    if not isinstance(entries, list):
        return False
    for e in entries:
        if not isinstance(e, dict):
            continue
        for h in (e.get("hooks") or []):
            if isinstance(h, dict) and script_base(h.get("command") or "") == want:
                return True
    return False
changed = False
if want_autoload and not has_cmd(hooks.get("SessionStart"), autoload_cmd):
    ss = hooks.get("SessionStart"); ss = ss if isinstance(ss, list) else []
    ss.append({"matcher": "startup|resume|clear|compact",
               "hooks": [{"type": "command", "command": autoload_cmd}]})
    hooks["SessionStart"] = ss; changed = True
if want_budget and not has_cmd(hooks.get("PostToolUse"), budget_cmd):
    ptu = hooks.get("PostToolUse"); ptu = ptu if isinstance(ptu, list) else []
    ptu.append({"matcher": "Write|Edit",
                "hooks": [{"type": "command", "command": budget_cmd}]})
    hooks["PostToolUse"] = ptu; changed = True
if changed and apply:
    data["hooks"] = hooks
    d = os.path.dirname(settings_path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings.", suffix=".ccage.tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, settings_path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
print("changed" if changed else "unchanged")
PY
}

# ---------------------------------------------------------------------------
# Hooks-block removal — the inverse of _ccage_doctor_seed, for uninstall.
# Removes only OUR two hook entries (matched on script basename, mirroring the
# seed dedup), preserves every other key and hook, prunes emptied lists, and
# never clobbers a present-but-unparseable settings.json.
# ---------------------------------------------------------------------------
_ccage_doctor_unseed() {
    local settings="$1" apply="$2"
    python3 - "$settings" "$apply" <<'PY' 2>/dev/null
import json, os, sys, tempfile
settings_path, apply = sys.argv[1], sys.argv[2] == "1"
targets = {"resume_autoload.sh", "resume_budget_check.sh"}
if not os.path.exists(settings_path):
    print("unchanged"); sys.exit(0)
try:
    mode = os.stat(settings_path).st_mode & 0o777
except OSError:
    mode = None
try:
    with open(settings_path) as f:
        data = json.load(f)
except (ValueError, OSError):
    print("unchanged"); sys.exit(0)
if not isinstance(data, dict) or not isinstance(data.get("hooks"), dict):
    print("unchanged"); sys.exit(0)
hooks = data["hooks"]
def script_base(cmd):
    return os.path.basename(cmd.split()[-1]) if cmd else ""
changed = False
for event in ("SessionStart", "PostToolUse"):
    entries = hooks.get(event)
    if not isinstance(entries, list):
        continue
    kept = []
    for e in entries:
        if isinstance(e, dict):
            inner = e.get("hooks") or []
            pruned = [h for h in inner
                      if not (isinstance(h, dict)
                              and script_base(h.get("command") or "") in targets)]
            if len(pruned) != len(inner):
                if not pruned:
                    continue          # whole entry was ours — drop it
                e = dict(e); e["hooks"] = pruned
        kept.append(e)
    if kept != entries:
        changed = True
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
if changed and not hooks:
    del data["hooks"]
if changed and apply:
    d = os.path.dirname(settings_path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings.", suffix=".ccage.tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, settings_path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
print("changed" if changed else "unchanged")
PY
}

# Bloated RESUME?  lines > budget OR more than 3 "## Session" blocks.
# KEEP IN SYNC with the health check in share/hooks/resume_autoload.sh.
_ccage_doctor_resume_bloated() {
    local f="$1" budget="$2"
    [ -f "$f" ] || return 1
    local lines blocks
    lines=$(wc -l < "$f" 2>/dev/null | tr -d '[:space:]'); [ -n "$lines" ] || lines=0
    blocks=$(grep -c '^## Session' "$f" 2>/dev/null); [ -n "$blocks" ] || blocks=0
    { [ "$lines" -gt "$budget" ] || [ "$blocks" -gt 3 ]; } 2>/dev/null
}

# Messy memory dir?  dead index link OR many orphan files OR large flat index.
# KEEP IN SYNC with the health check in share/hooks/resume_autoload.sh.
_ccage_doctor_memory_messy() {
    local memdir="$1"
    local index="$memdir/MEMORY.md"
    [ -f "$index" ] || return 1
    local orphan_max="${CCAGE_MEMORY_ORPHAN_MAX:-3}"

    local ref
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        [ -f "$memdir/$ref" ] || return 0
    done < <(grep -oE '\]\([^)]+\.md\)' "$index" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//')

    local files idx
    files=$(find "$memdir" -maxdepth 1 -type f -name '*.md' ! -name 'MEMORY.md' 2>/dev/null | wc -l | tr -d '[:space:]')
    idx=$(grep -cE '^[[:space:]]*-[[:space:]]*\[' "$index" 2>/dev/null)
    [ -n "$files" ] || files=0
    [ -n "$idx" ] || idx=0
    [ "$((files - idx))" -gt "$orphan_max" ] && return 0
    [ "$files" -gt 8 ] && ! grep -q '^## ' "$index" 2>/dev/null && return 0
    return 1
}

_ccage_doctor_help() {
    cat <<EOF
Usage: ccage doctor [--dry-run] [--unseed]

Sweep every cage under \${CCAGE_ROOT:-\$HOME}/\${CCAGE_PREFIX:-.claude-}* and:
  1. backfill the session-docs hooks block into its settings.json (safe,
     idempotent merge — preserves all existing keys);
  2. report repos with a bloated RESUME (run /checkpoint to trim) and cages
     with an unorganized memory dir (run /checkpoint --tidy).

Options:
  --dry-run   Preview seeding + the worklist without writing anything.
  --unseed    Inverse of the backfill: remove ccage's two hook entries from
              every cage's settings.json (used by uninstall.sh so no cage is
              left pointing at deleted hook scripts). Preserves all other keys.
  -h, --help  This message.

Backfill targets only directories that carry a .owning_path marker (real cages).
EOF
}

# ---- main ------------------------------------------------------------------
_ccage_doctor_main() {
    local dry_run=0 unseed=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry_run=1; shift ;;
            --unseed)  unseed=1;  shift ;;
            -h|--help) _ccage_doctor_help; return 0 ;;
            *) printf 'ccage doctor: unknown flag: %s\n' "$1" >&2; return 2 ;;
        esac
    done

    command -v python3 >/dev/null 2>&1 || {
        printf 'ccage doctor: python3 is required for the settings.json merge\n' >&2
        return 2
    }

    local root="${CCAGE_ROOT:-$HOME}"
    local prefix="${CCAGE_PREFIX:-.claude-}"
    local hooks_dir="${CCAGE_HOOKS_DIR:-$HOME/.claude/hooks}"
    local budget="${CCAGE_RESUME_BUDGET_LINES:-250}"

    # Honor the same sub-opt-outs the wrapper does, so `ccage doctor` never
    # backfills a hook the user disabled via CCAGE_NO_AUTOLOAD/CCAGE_NO_BUDGET_HOOK.
    local want_autoload=1 want_budget=1
    [ -n "${CCAGE_NO_AUTOLOAD:-}" ] && want_autoload=0
    [ -n "${CCAGE_NO_BUDGET_HOOK:-}" ] && want_budget=0

    local scanned=0 seeded=0
    local trim_list="" tidy_list=""
    local apply=1; [ "$dry_run" = 1 ] && apply=0

    local d owner result rf pm proj_slug label
    for d in "$root/$prefix"*/; do
        [ -d "$d" ] || continue
        d="${d%/}"
        [ -f "$d/.owning_path" ] || continue   # only real cages
        scanned=$((scanned + 1))

        # 1. backfill (or, with --unseed, remove) the hooks block
        if [ "$unseed" = 1 ]; then
            result=$(_ccage_doctor_unseed "$d/settings.json" "$apply")
            if [ "$result" = changed ]; then
                seeded=$((seeded + 1))
                if [ "$dry_run" = 1 ]; then
                    printf '+ would unseed hooks ← %s/settings.json\n' "$d"
                else
                    printf 'unseeded hooks ← %s/settings.json\n' "$d"
                fi
            fi
            continue   # unseed mode: no worklist scan
        fi
        result=$(_ccage_doctor_seed "$d/settings.json" "$hooks_dir" "$apply" "$want_autoload" "$want_budget")
        if [ "$result" = changed ]; then
            seeded=$((seeded + 1))
            if [ "$dry_run" = 1 ]; then
                printf '+ would seed hooks → %s/settings.json\n' "$d"
            else
                printf 'seeded hooks → %s/settings.json\n' "$d"
            fi
        fi

        owner=""
        { IFS= read -r owner < "$d/.owning_path"; } 2>/dev/null

        # 2a. bloated RESUME — slot-aware: check RESUME.md AND every
        #     RESUME.<slot>.md a slotted session may have written.
        if [ -n "$owner" ]; then
            for rf in "$owner"/RESUME*.md; do
                _ccage_doctor_resume_bloated "$rf" "$budget" \
                    && trim_list="${trim_list}  ${rf}"$'\n'
            done
        fi

        # 2b. messy memory — scan EVERY project under the cage rather than a
        #     single slug rebuilt from .owning_path (which yields projects//memory
        #     for an empty marker and silently skips extra projects in a
        #     multi-project cage). Label with the owning repo when its slug
        #     matches this project, else the full memory-dir path.
        for pm in "$d"/projects/*/memory; do
            [ -d "$pm" ] || continue
            _ccage_doctor_memory_messy "$pm" || continue
            proj_slug="${pm%/memory}"; proj_slug="${proj_slug##*/projects/}"
            if [ -n "$owner" ] && [ "$proj_slug" = "$(printf '%s' "$owner" | LC_ALL=C tr -c 'A-Za-z0-9' '-')" ]; then
                label="$owner"
            else
                label="$pm"
            fi
            tidy_list="${tidy_list}  ${label}   (cage: ${d})"$'\n'
        done
    done

    printf '\nccage doctor — scanned %d cage(s) under %s/%s*\n' "$scanned" "$root" "$prefix"
    if [ "$unseed" = 1 ]; then
        if [ "$dry_run" = 1 ]; then
            printf '%d cage(s) would have the session-docs hooks block removed.\n' "$seeded"
        else
            printf '%d cage(s) had the session-docs hooks block removed.\n' "$seeded"
        fi
        return 0
    fi
    if [ "$dry_run" = 1 ]; then
        printf '%d cage(s) would be seeded with the session-docs hooks block.\n' "$seeded"
    else
        printf '%d cage(s) seeded with the session-docs hooks block.\n' "$seeded"
    fi

    printf '\nRepos with a bloated RESUME (run /checkpoint there to trim):\n'
    if [ -n "$trim_list" ]; then printf '%s' "$trim_list"; else printf '  (none)\n'; fi

    printf '\nCages with an unorganized memory dir (run /checkpoint --tidy there):\n'
    if [ -n "$tidy_list" ]; then printf '%s' "$tidy_list"; else printf '  (none)\n'; fi
}
