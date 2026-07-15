# shellcheck shell=bash
# ccage — Claude Code per-project isolation wrapper
#
# Gives each working directory its own CLAUDE_CONFIG_DIR so multiple parallel
# Claude Code sessions (different repos or git worktrees) stop bashing each
# other's prompt cache, credentials, and history.
#
# Works in bash and zsh. Safe to source multiple times.
#
# Opt-outs (set before invoking `claude`):
#   CCAGE_DISABLE=1              — bypass the wrapper entirely for one call
#   CCAGE_KEEP_ATTRIBUTION=1     — don't touch CLAUDE_CODE_ATTRIBUTION_HEADER
#   CCAGE_KEEP_AUTOUPDATER=1     — don't touch DISABLE_AUTOUPDATER
#   CCAGE_NO_AUTO_SIGNORE=1      — don't create a baseline .claudesignore
#   CCAGE_NO_ONBOARDING_PATCH=1  — don't pre-set hasCompletedOnboarding
#
# Config:
#   CCAGE_ROOT                   — parent dir for isolated configs (default: $HOME)
#   CCAGE_PREFIX                 — dir name prefix (default: .claude-)
#   CCAGE_PLUGINS_FROM           — folder of plugin dirs to load into every cage
#                                  via --plugin-dir (opt-in; default: unset)
#
# Extension hooks (redefine in a companion file — see Extension model below):
#   _ccage_config_dir_override PWD
#       Echo a config dir and return 0 to override ccage's default choice.
#       Return non-zero to fall through to the default.
#       After redefining, also set: _CCAGE_OVERRIDE_ACTIVE=1
#   _ccage_pre_exec_hook PWD CONFIG_DIR
#       Runs just before `command claude`. Can export env vars, append to the
#       _ccage_extra_args array to inject CLI flags, and write UI-only keys
#       into $CLAUDE_CONFIG_DIR/settings.json (never permissions, plugins, or
#       other state — those cause cross-session cache-bashing).
#
# Extension model:
#   Drop a companion file next to this one that redefines either hook. If you
#   use the default ~/.bashrc.d/ loader, alphabetical order means a file named
#   `claude-overrides.sh` loads after `claude-isolation.sh` and can safely
#   redefine the stubs. An example template ships as claude-overrides.sh.example.

# ---- sha1 tool — resolved once at source time ----
if command -v sha1sum >/dev/null 2>&1; then
    _CCAGE_SHA1_CMD=sha1sum
elif command -v shasum >/dev/null 2>&1; then
    _CCAGE_SHA1_CMD=shasum
else
    _CCAGE_SHA1_CMD=openssl
fi

_ccage_sha1() {
    case "$_CCAGE_SHA1_CMD" in
        sha1sum) printf '%s' "$1" | sha1sum            | cut -c1-8 ;;
        shasum)  printf '%s' "$1" | shasum -a 1        | cut -c1-8 ;;
        openssl) printf '%s' "$1" | openssl dgst -sha1 | awk '{print $NF}' | cut -c1-8 ;;
    esac
}

# ---- extension hook stubs (no-ops; redefine in a companion file) ----
_ccage_config_dir_override() { return 1; }
_ccage_pre_exec_hook() { :; }
_CCAGE_OVERRIDE_ACTIVE=0

# ---- compute the config dir for a given absolute path ----
_ccage_config_dir_for() {
    local pwd_arg="$1"

    if [ "${_CCAGE_OVERRIDE_ACTIVE:-0}" = 1 ]; then
        local override
        if override="$(_ccage_config_dir_override "$pwd_arg")" && [ -n "$override" ]; then
            printf '%s\n' "$override"
            return 0
        fi
    fi

    local root="${CCAGE_ROOT:-$HOME}"
    local prefix="${CCAGE_PREFIX:-.claude-}"
    local base="${pwd_arg##*/}"

    local candidate="$root/${prefix}${base}"
    local marker="$candidate/.owning_path"

    if [ -d "$candidate" ] && [ -f "$marker" ]; then
        local owner=""
        { IFS= read -r owner < "$marker"; } 2>/dev/null
        if [ -n "$owner" ] && [ "$owner" != "$pwd_arg" ]; then
            candidate="$root/${prefix}${base}-$(_ccage_sha1 "$pwd_arg")"
        fi
    fi

    if [ -n "${CCAGE_SLOT:-}" ]; then
        case "$CCAGE_SLOT" in
            *[!A-Za-z0-9_-]*)
                printf 'ccage: CCAGE_SLOT=%s contains unsafe characters (allowed: A-Za-z0-9_-); ignoring\n' \
                    "$CCAGE_SLOT" >&2
                ;;
            *)
                candidate="${candidate}--${CCAGE_SLOT}"
                ;;
        esac
    fi

    printf '%s\n' "$candidate"
}

# ---- patch hasCompletedOnboarding into an existing .claude.json ----
_ccage_patch_onboarding() {
    local cj="$1"
    if [ ! -f "$cj" ]; then
        printf '%s\n' '{"hasCompletedOnboarding":true}' > "$cj" 2>/dev/null
        return
    fi
    if ! grep -q '"hasCompletedOnboarding"' "$cj" 2>/dev/null; then
        command -v python3 >/dev/null 2>&1 || return 0
        python3 - "$cj" <<'PY' 2>/dev/null || true
import json, sys
p = sys.argv[1]
try:
    with open(p) as f: d = json.load(f)
except Exception:
    d = {}
d["hasCompletedOnboarding"] = True
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
    fi
}

# ---- optional symlink-sharing from a master config dir ----
_ccage_share_dirs() {
    local dir="$1"
    [ -n "${CCAGE_SHARE_FROM:-}" ] || return 0

    local master="$CCAGE_SHARE_FROM"
    [ "$master" = "$dir" ] && return 0   # sharing from self is a no-op

    local names="${CCAGE_SHARE_DIRS:-commands agents skills}"

    local name
    for name in $names; do
        [ -d "$master/$name" ] || continue
        local target="$dir/$name"
        if [ -e "$target" ] || [ -L "$target" ]; then
            [ -L "$target" ] || printf 'ccage: %s already exists; skipping share of %s\n' \
                "$target" "$name" >&2
            continue
        fi
        ln -s "$master/$name" "$target" || \
            printf 'ccage: failed to create symlink %s → %s\n' "$target" "$master/$name" >&2
    done
}

# ---- one-shot claim + bootstrap for a config dir ----
_ccage_bootstrap_dir() {
    local dir="$1" pwd_arg="$2"

    if ! mkdir -p "$dir" 2>/dev/null; then
        printf 'ccage: cannot create config dir %s\n' "$dir" >&2
        return 1
    fi
    # Atomic first-claim: noclobber write so two parallel fresh launches with
    # the same basename can't both claim the dir (the -f test alone races).
    # Loser falls through; the caller's owner check handles the mismatch.
    if [ ! -f "$dir/.owning_path" ]; then
        (set -C; printf '%s\n' "$pwd_arg" > "$dir/.owning_path") 2>/dev/null || true
    fi

    [ -n "${CCAGE_NO_ONBOARDING_PATCH:-}" ] && return 0
    _ccage_patch_onboarding "$dir/.claude.json"
    _ccage_share_dirs "$dir"
}

# ---- seed session-docs hooks into a cage's settings.json (opt-in) -----------
# Phase 7. Gated by CCAGE_SESSION_DOCS. Idempotently MERGES a `hooks` block into
# the cage's settings.json (preserving statusLine, enabledPlugins, effortLevel,
# and any other keys) referencing the fixed scripts in ~/.claude/hooks/:
#   SessionStart (startup|resume|clear|compact) → resume_autoload.sh
#   PostToolUse  (Write|Edit)                   → resume_budget_check.sh
# Because the scripts live at a FIXED path (they don't rotate per request) this
# does NOT bash the prompt cache — a documented exception to ccage's "UI-only
# seeding" rule. Runs every launch, so it self-heals and backfills existing
# cages on their next `claude`.
#
# Sub-opt-outs: CCAGE_NO_AUTOLOAD=1 (skip the auto-read), CCAGE_NO_BUDGET_HOOK=1
# (skip the budget guard). CCAGE_HOOKS_DIR overrides the script dir.
_ccage_seed_session_docs_hooks() {
    [ -n "${CCAGE_SESSION_DOCS:-}" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0

    local dir="$1"
    local hooks_dir="${CCAGE_HOOKS_DIR:-$HOME/.claude/hooks}"

    local want_autoload=1 want_budget=1
    [ -n "${CCAGE_NO_AUTOLOAD:-}" ] && want_autoload=0
    [ -n "${CCAGE_NO_BUDGET_HOOK:-}" ] && want_budget=0
    [ "$want_autoload" = 0 ] && [ "$want_budget" = 0 ] && return 0

    # Fast path: this runs on EVERY caged launch (once opted in), so skip the
    # python fork when the wanted hooks are already present — the steady state.
    # Mirrors how _ccage_patch_onboarding greps before forking python.
    local settings="$dir/settings.json"
    if [ -f "$settings" ]; then
        local need=0
        { [ "$want_autoload" = 1 ] && ! grep -q 'resume_autoload.sh'     "$settings" 2>/dev/null; } && need=1
        { [ "$want_budget"   = 1 ] && ! grep -q 'resume_budget_check.sh' "$settings" 2>/dev/null; } && need=1
        [ "$need" = 0 ] && return 0
    fi

    python3 - "$settings" "$hooks_dir" "$want_autoload" "$want_budget" <<'PY' 2>/dev/null || true
import json, os, sys, tempfile
# KEEP IN SYNC with _ccage_doctor_seed in share/ccage-doctor.sh (same merge;
# the doctor copy adds an apply flag + a changed/unchanged stdout signal).
settings_path, hooks_dir = sys.argv[1], sys.argv[2]
want_autoload, want_budget = sys.argv[3] == "1", sys.argv[4] == "1"
autoload_cmd = "bash " + os.path.join(hooks_dir, "resume_autoload.sh")
budget_cmd   = "bash " + os.path.join(hooks_dir, "resume_budget_check.sh")

# Preserve an existing file's mode; never clobber a present-but-unparseable
# settings.json (Claude Code rejects it too — leave it for the user to fix).
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
        sys.exit(0)
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
    # Dedup on the hook script's BASENAME, not the full path, so a differing
    # CCAGE_HOOKS_DIR never appends a duplicate entry (matches the basename
    # semantics of the wrapper's grep fast-path and the doctor copy).
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
    ss = hooks.get("SessionStart")
    if not isinstance(ss, list):
        ss = []
    ss.append({"matcher": "startup|resume|clear|compact",
               "hooks": [{"type": "command", "command": autoload_cmd}]})
    hooks["SessionStart"] = ss
    changed = True

if want_budget and not has_cmd(hooks.get("PostToolUse"), budget_cmd):
    ptu = hooks.get("PostToolUse")
    if not isinstance(ptu, list):
        ptu = []
    ptu.append({"matcher": "Write|Edit",
                "hooks": [{"type": "command", "command": budget_cmd}]})
    hooks["PostToolUse"] = ptu
    changed = True

if changed:
    data["hooks"] = hooks
    d = os.path.dirname(settings_path) or "."
    os.makedirs(d, exist_ok=True)
    # mkstemp gives a unique name on the target's filesystem, so two concurrent
    # same-cage launches can't collide on a fixed temp path or race os.replace.
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
PY
}

# ---- seed the USER's own local hooks into a cage's settings.json (opt-in) ---
# Gated by CCAGE_SEED_LOCAL_HOOKS. Idempotently merges the hook registrations
# the user already has in their real ~/.claude/settings.json into this cage's
# settings.json, so a policy they maintain globally actually applies inside
# every cage.
#
# WHY THIS EXISTS. A hook script under ~/.claude/hooks is inert until some
# settings.json REGISTERS it, and every cage has its OWN settings.json. ccage
# seeds only its own session-docs hooks, so a user's local policy hooks reached
# a cage only if someone hand-edited that cage. Measured on one machine
# (2026-07-15): the user's per-turn orchestration gate was registered in 34 of
# 71 cages, 8 cages used within the last month had it nowhere, and EVERY NEW
# CAGE WAS BORN WITHOUT IT — while the policy file itself claimed it "fires on
# every turn" in "every single project". The claim was false and nothing could
# have noticed.
#
# OWNERSHIP: ccage owns cage WIRING; the policy CONTENT is the user's. So this
# copies registrations FROM the user's own settings.json and hardcodes no hook
# names, exactly as CCAGE_SHARE_DIRS shares commands/agents/skills without
# owning what is in them. ccage's own session-docs hooks are SKIPPED here --
# _ccage_seed_session_docs_hooks seeds those and has its own opt-outs
# (CCAGE_NO_AUTOLOAD / CCAGE_NO_BUDGET_HOOK), which forcing them in would
# silently override.
#
# Like the session-docs seeder this runs every launch, so it self-heals and
# backfills existing cages, and it references fixed script paths so it does not
# bash the prompt cache.
_ccage_seed_local_hooks() {
    [ -n "${CCAGE_SEED_LOCAL_HOOKS:-}" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0

    local dir="$1"
    local hooks_dir="${CCAGE_HOOKS_DIR:-$HOME/.claude/hooks}"
    local src="${CCAGE_LOCAL_HOOKS_SRC:-$HOME/.claude/settings.json}"
    local settings="$dir/settings.json"

    [ -f "$src" ] || return 0
    # A cage IS the user's config dir when uncaged; never seed a file from itself.
    [ "$src" = "$settings" ] && return 0

    python3 - "$settings" "$src" "$hooks_dir" <<'PY' 2>/dev/null || true
import json, os, sys, tempfile

settings_path, src_path, hooks_dir = sys.argv[1], sys.argv[2], sys.argv[3]

# ccage seeds these itself, with their own opt-out flags. Copying them here
# would override a deliberate --no-session-docs.
CCAGE_OWNED = {"resume_autoload.sh", "resume_budget_check.sh", "autonomous_ask_guard.sh"}


def expand(cmd):
    """Expand `~` before matching or writing.

    The user's settings.json may register `bash ~/.claude/hooks/x.sh` while cages
    carry the absolute form; matching the literal absolute path silently skips
    every tilde-form hook -- including, on the machine this was written for, the
    single most important one.
    """
    return " ".join(os.path.expanduser(t) for t in cmd.split()) if cmd else ""


def script_base(cmd):
    return os.path.basename(expand(cmd).split()[-1]) if cmd else ""


def has_cmd(entries, name):
    # Dedup on basename, matching _ccage_seed_session_docs_hooks.
    if not isinstance(entries, list):
        return False
    for e in entries:
        if not isinstance(e, dict):
            continue
        for h in (e.get("hooks") or []):
            if isinstance(h, dict) and script_base(h.get("command") or "") == name:
                return True
    return False


def load(path, default):
    if not os.path.exists(path):
        return default
    try:
        with open(path) as f:
            data = json.load(f)
    except ValueError:
        return None          # present but unparseable: caller decides
    except OSError:
        return default
    return data if isinstance(data, dict) else default


src = load(src_path, {})
if not src:
    sys.exit(0)

data = load(settings_path, {})
if data is None:
    sys.exit(0)              # never clobber a present-but-broken settings.json

mode = None
if os.path.exists(settings_path):
    try:
        mode = os.stat(settings_path).st_mode & 0o777
    except OSError:
        pass

hooks = data.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}

changed = False
for event, entries in (src.get("hooks") or {}).items():
    if not isinstance(entries, list):
        continue
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        # ONE HOOK AT A TIME, seeded as its own single-hook entry.
        #
        # This loop used to judge an entry by its FIRST hook only
        # (`name = script_base(cmds[0])`), which silently dropped every hook
        # after the first in a matcher group: the group was identified by hook
        # #1, and if hook #1 was already in the cage the whole group was
        # skipped. Measured 2026-07-15 -- registering a second guard on the
        # existing `PreToolUse: Bash` group (beside an already-seeded one) left
        # it in ZERO cages while every check reported success. That is the exact
        # defect this seeder exists to fix, one level up: a control that is real
        # in the file and absent in effect.
        #
        # Splitting also avoids re-seeding hook #1 as a duplicate when hook #2 is
        # the one that is missing, and lets a group that MIXES a ccage-owned hook
        # with a user hook seed the user's half instead of being skipped whole.
        # Two single-hook entries sharing a matcher behave identically to one
        # entry with two hooks.
        for hook in (entry.get("hooks") or []):
            if not isinstance(hook, dict):
                continue
            cmd = hook.get("command") or ""
            # Ours = registers a script under the user's hooks dir. Anything else
            # (an inline curl, a third-party integration) is not ccage's to spread.
            if not cmd or hooks_dir not in expand(cmd):
                continue
            name = script_base(cmd)
            # ccage seeds these itself, with their own opt-outs.
            if not name or name in CCAGE_OWNED:
                continue
            if has_cmd(hooks.get(event), name):
                continue
            new = json.loads(json.dumps(entry))     # copy, preserving matcher
            new["hooks"] = [json.loads(json.dumps(hook))]
            new["hooks"][0]["command"] = expand(cmd)
            arr = hooks.get(event)
            if not isinstance(arr, list):
                arr = []
            arr.append(new)
            hooks[event] = arr
            changed = True

if changed:
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
PY
}

# ---- baseline .claudesignore (only if the project has none) ----
_ccage_write_signore() {
    local target_dir="$1"
    [ -n "${CCAGE_NO_AUTO_SIGNORE:-}" ] && return 0
    [ -f "$target_dir/.claudesignore" ] && return 0
    [ -w "$target_dir" ] || return 0   # silent skip on read-only project
    cat > "$target_dir/.claudesignore" 2>/dev/null <<'SIGNORE'
# Auto-generated by ccage. Edit freely — ccage won't overwrite this file.
node_modules/
.venv/
venv/
__pycache__/
dist/
build/
*.tar.gz
*.zip
*.sqlite
*.db
.pytest_cache/
.mypy_cache/
.ruff_cache/
.cursor/
.windsurf/
.obsidian/
SIGNORE
}

# ============================================================================
# Resume cost interception (Phase 6b)
#
# claude -r / claude -c trigger a structural cache miss on the message prefix
# even inside the TTL window (Claude Code's processSessionStartHooks +
# reorderAttachmentsForAPI shuffle bytes at messages[0]; isolated by the
# 1-hour-TTL controlled experiment in anthropics/claude-code #51764; see also
# #43657, #44045 — one narrow cause was fixed in CC v2.1.90, the rest remain).
# A cold resume rewrites the accumulated prefix at the cache-write rate
# (1.25× input on the 5m tier, 2× on the 1h tier). On a long Opus session
# that's real money — $0.50 to $2+ per resume. Treat the estimate as a
# worst-case bound.
#
# The interceptor:
#   1. Detects -c / --continue / -r <uuid> / --resume <uuid> in args
#   2. Estimates rewrite cost from the session JSONL's peak cache_read
#   3. Prompts the user [r]esume / [h]andoff / [c]ancel
#
# Gates: CCAGE_DISABLE=1, CCAGE_NO_RESUME_PROMPT=1, non-tty stdin, or
# estimated cost below CCAGE_RESUME_PROMPT_MIN_USD (default 0.25) all
# pass-through without prompting.
# ============================================================================

# Pricing — 200K tier, cache-write = 1.25× input. Refresh `# updated:` below
# when Anthropic publishes new rates and add a CHANGELOG entry.
# Kept inline rather than in a separate ccage-pricing.sh so the wrapper has
# zero external sourcing dependency (the rc loader handles only one file).
# Duplicated in share/ccage-handoff.sh — keep both in sync.
# updated: 2026-05-16
_ccage_resume_price_cache_write() {
    case "$1" in
        claude-opus-4-7|claude-opus-4-6)     echo 18.75 ;;
        claude-sonnet-4-6|claude-sonnet-4-5) echo 3.75 ;;
        claude-haiku-4-5)                    echo 1.00 ;;
        *)                                   echo 18.75 ;;  # conservative default
    esac
}

# Pure decision function — tested directly. r/R/<enter> → resume,
# h/H → handoff, anything else → cancel (safe default for unrecognized input).
_ccage_resume_decide() {
    case "$1" in
        r|R|"") echo resume ;;
        h|H)    echo handoff ;;
        *)      echo cancel ;;
    esac
}

# Detect a resume invocation that we can confidently intercept.
#
# In scope (deterministic — we know which session):
#   -c, --continue                  → most-recent session
#   -r <uuid-prefix>                → specific session
#   --resume <uuid-prefix>          → specific session
#
# Out of scope (Claude Code may show its own picker — we can't predict):
#   bare -r / bare --resume (no arg, or next arg is another flag)
_ccage_is_resume_invocation() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -c|--continue) return 0 ;;
            -r|--resume)
                # Need the next token to look like a session id (UUID prefix).
                local next="${2:-}"
                if [ -n "$next" ] && [[ "$next" =~ ^[0-9a-fA-F][0-9a-fA-F-]{4,}$ ]]; then
                    return 0
                fi
                return 1
                ;;
        esac
        shift
    done
    return 1
}

# Single-pass session summary — folds peak cache_read, last model, session id,
# and last timestamp out of one streaming jq invocation. Replaces 4-6 jq
# slurps on the interceptor hot path.
# Echoes tab-separated: peak<TAB>model<TAB>session_id<TAB>last_ts.
# Empty / missing file → "0\tunknown\t\t".
_ccage_resume_session_summary() {
    local jsonl="$1"
    [ -f "$jsonl" ] || { printf '0\tunknown\t\t\n'; return 0; }
    jq -Rrn '
        reduce (inputs | fromjson? // empty) as $r (
            {peak: 0, model: "unknown", session_id: "", last_ts: ""};
            ( if .session_id == "" and ($r.sessionId // null) != null
              then .session_id = $r.sessionId else . end )
            | ( if ($r.timestamp // null) != null
                then .last_ts = $r.timestamp else . end )
            | ( if $r.type == "assistant" then
                  ( if ($r.message.model // null) != null
                      and $r.message.model != "<synthetic>"
                    then .model = $r.message.model else . end )
                  | ( ($r.message.usage.cache_read_input_tokens // 0) as $cur
                      | if $cur > 1000 and $cur > .peak
                        then .peak = $cur else . end )
                else . end )
        )
        | "\(.peak)\t\(.model)\t\(.session_id)\t\(.last_ts)"
    ' "$jsonl" 2>/dev/null || printf '0\tunknown\t\t\n'
}

# Pure shell + awk: given (peak_cache_read, model), compute the cost range.
# Echoes "<lo>\t<hi>\t<rewrite_tokens>" with the ±25% band.
_ccage_resume_compute_cost() {
    local peak="$1" model="$2"
    local rewrite=$((peak - 19000))     # subtract ~19K tools+system prefix
    [ "$rewrite" -lt 0 ] && rewrite=0
    if [ "$rewrite" -eq 0 ]; then
        printf '0.00\t0.00\t0\n'
        return 0
    fi
    local rate
    rate=$(_ccage_resume_price_cache_write "$model")
    awk -v r="$rewrite" -v p="$rate" 'BEGIN {
        mid = r / 1000000 * p
        printf "%.2f\t%.2f\t%d\n", mid * 0.75, mid * 1.25, r
    }'
}

# Back-compat shim — preserves the public TSV signature
# (lo<TAB>hi<TAB>model<TAB>rewrite) for tests and any external callers.
# Internally now one jq pass via _ccage_resume_session_summary.
_ccage_resume_estimate_cost_usd() {
    local jsonl="$1"
    [ -f "$jsonl" ] || { printf '0.00\t0.00\tunknown\t0\n'; return 0; }
    local peak model
    IFS=$'\t' read -r peak model _ _ < <(_ccage_resume_session_summary "$jsonl")
    : "${peak:=0}"; : "${model:=unknown}"
    local lo hi rewrite
    IFS=$'\t' read -r lo hi rewrite < <(_ccage_resume_compute_cost "$peak" "$model")
    printf '%s\t%s\t%s\t%s\n' "$lo" "$hi" "$model" "$rewrite"
}

# Should we prompt? Returns 0 if yes, non-zero if cost is below the threshold
# (or the JSONL has no signal). Threshold is dollar-denominated:
# CCAGE_RESUME_PROMPT_MIN_USD (default 0.25).
_ccage_resume_should_prompt() {
    local jsonl="$1"
    local threshold="${CCAGE_RESUME_PROMPT_MIN_USD:-0.25}"
    local lo hi
    IFS=$'\t' read -r lo hi _ _ < <(_ccage_resume_estimate_cost_usd "$jsonl")
    # Use the upper bound for the threshold comparison — be loud rather than quiet.
    awk -v hi="$hi" -v t="$threshold" 'BEGIN { exit (hi >= t) ? 0 : 1 }'
}

# Format a session-age string from an ISO 8601 timestamp.
_ccage_resume_age_human() {
    local ts="$1"
    [ -n "$ts" ] || { echo "unknown"; return; }
    local last_epoch now_epoch sec
    last_epoch=$(date -d "$ts" +%s 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%S' "${ts%.*}" +%s 2>/dev/null || echo "")
    [ -n "$last_epoch" ] || { echo "unknown"; return; }
    now_epoch=$(date +%s)
    sec=$((now_epoch - last_epoch))
    if [ "$sec" -lt 60 ]; then echo "${sec}s ago"
    elif [ "$sec" -lt 3600 ]; then echo "$((sec / 60))m ago"
    elif [ "$sec" -lt 86400 ]; then echo "$((sec / 3600))h $((sec % 3600 / 60))m ago"
    else echo "$((sec / 86400))d ago"
    fi
}

# Resolve session JSONL for current PWD + CLAUDE_CONFIG_DIR + optional id.
# Echoes path; returns 1 on miss (no error — interceptor will pass through).
_ccage_resume_locate_jsonl() {
    local id_prefix="${1:-}"
    # Claude Code's project slug: every non-alphanumeric character in the cwd
    # becomes "-" (verified against real projects/ dirs: "_" and "." convert
    # too, not just "/"). tr keeps this bash-3.2/zsh safe — a ${var//[^…]/}
    # bracket class is mishandled by macOS bash 3.2.
    local slug
    slug=$(printf '%s' "$PWD" | LC_ALL=C tr -c 'A-Za-z0-9' '-')
    local session_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$slug"
    [ -d "$session_dir" ] || return 1

    if [ -n "$id_prefix" ]; then
        local matches=()
        local f
        # zsh aborts a function on a no-match glob (NOMATCH default); disable it
        # locally so "id matches nothing" returns cleanly in both shells (bash
        # leaves the pattern literal, rejected by the -f test).
        if [ -n "${ZSH_VERSION:-}" ]; then setopt local_options no_nomatch 2>/dev/null; fi
        for f in "$session_dir/$id_prefix"*.jsonl; do
            [ -f "$f" ] && matches+=("$f")
        done
        case ${#matches[@]} in
            0) return 1 ;;
            # "${matches[@]}" not [0]: zsh arrays are 1-indexed, so [0] is
            # empty there and the prompt would silently compute a $0 session.
            1) printf '%s\n' "${matches[@]}"; return 0 ;;
            *)
                # Ambiguous — warn and pass through; let claude do its own picking.
                printf 'ccage: resume id "%s" matches %d sessions; passing through (claude will pick or prompt).\n' \
                    "$id_prefix" "${#matches[@]}" >&2
                return 1
                ;;
        esac
    fi

    # Most-recent by mtime.
    local newest
    # shellcheck disable=SC2012  # mtime sort; find -printf isn't portable to macOS
    newest=$(ls -t "$session_dir"/*.jsonl 2>/dev/null | head -1)
    [ -n "$newest" ] && [ -f "$newest" ] || return 1
    printf '%s\n' "$newest"
}

# Extract the session id (or empty) from positional resume args.
_ccage_resume_extract_id() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -r|--resume)
                local next="${2:-}"
                if [ -n "$next" ] && [[ "$next" =~ ^[0-9a-fA-F][0-9a-fA-F-]{4,}$ ]]; then
                    printf '%s\n' "$next"
                    return 0
                fi
                ;;
        esac
        shift
    done
    return 1
}

# Main interceptor. Returns 0 to "continue to claude as normal," non-zero to
# "cancel the claude invocation" (user picked cancel or handoff).
#
# Gates (all return 0 = pass-through):
#   - args don't look like a deterministic resume
#   - CCAGE_DISABLE=1                  (the wrapper's outer guard takes over)
#   - CCAGE_NO_RESUME_PROMPT=1
#   - non-tty stdin                    (can't prompt; user is scripting)
#   - estimated cost below threshold
_ccage_intercept_resume() {
    if [ -n "${CCAGE_DISABLE:-}" ]; then return 0; fi
    if [ -n "${CCAGE_NO_RESUME_PROMPT:-}" ]; then return 0; fi
    if ! _ccage_is_resume_invocation "$@"; then return 0; fi
    if [ ! -t 0 ]; then return 0; fi   # scripted; no tty to prompt on

    local id
    id=$(_ccage_resume_extract_id "$@" || true)

    local jsonl
    if ! jsonl=$(_ccage_resume_locate_jsonl "$id"); then
        # No session found — let claude itself report the error.
        return 0
    fi

    # ONE jq pass over the JSONL — peak, model, session id, last timestamp.
    local peak model session_id last_ts
    IFS=$'\t' read -r peak model session_id last_ts \
        < <(_ccage_resume_session_summary "$jsonl")
    : "${peak:=0}"; : "${model:=unknown}"; : "${session_id:=unknown}"

    # Pure-shell cost computation from the cached peak.
    local lo hi rewrite
    IFS=$'\t' read -r lo hi rewrite \
        < <(_ccage_resume_compute_cost "$peak" "$model")

    # Threshold gate (inline — same logic as _ccage_resume_should_prompt).
    local threshold="${CCAGE_RESUME_PROMPT_MIN_USD:-0.25}"
    awk -v hi="$hi" -v t="$threshold" 'BEGIN { exit (hi >= t) ? 0 : 1 }' || return 0

    local age
    age=$(_ccage_resume_age_human "$last_ts")

    # Pick the verb based on -c vs -r<id>.
    local verb="Resuming"
    case " $* " in *" -c "*|*" --continue "*) verb="Continuing most-recent" ;; esac

    {
        printf 'ccage: %s session %s · %s · %s\n' "$verb" "${session_id:0:8}" "$age" "$model"
        printf '       Resume will rewrite ~%dK tokens (message prefix). Estimated cost: $%s–$%s.\n' \
            $((rewrite / 1000)) "$lo" "$hi"
        printf '       (Resume cache misses are structural, not TTL — see GitHub #51764, #43657. Worst-case estimate.)\n'
        printf '       [r]esume / [h]andoff / [c]ancel? '
    } >&2

    local response decision
    # bash uses `-n N` for "read N chars"; zsh uses `-k N`. Branch on shell so
    # the prompt's single-keypress UX works in both. Discovered in Tier 2 review.
    if [ -n "${ZSH_VERSION:-}" ]; then
        # shellcheck disable=SC3045,SC2162  # -k is zsh-only; -r doesn't apply to zsh's -k
        read -k 1 -s response < /dev/tty
    else
        read -rn 1 -s response < /dev/tty
    fi
    printf '%s\n' "$response" >&2
    decision=$(_ccage_resume_decide "$response")

    case "$decision" in
        resume)  return 0 ;;
        handoff)
            # Find the installed ccage CLI on PATH and dispatch to it for the
            # actual brief generation. If not on PATH, point at the source-tree
            # location via $CCAGE_LIB-style env override.
            if command -v ccage >/dev/null 2>&1; then
                ccage handoff ${id:+"$id"} >&2
            else
                # shellcheck disable=SC2016  # literal `ccage` and `./install.sh` in user hint
                printf 'ccage: handoff path requires `ccage` on PATH — install with ./install.sh\n' >&2
            fi
            return 1
            ;;
        cancel|*)
            printf 'ccage: cancelled\n' >&2
            return 1
            ;;
    esac
}

# ---- shared plugins (launch-time --plugin-dir injection) ----
# Opt-in: point CCAGE_PLUGINS_FROM at a folder of plugin directories (each a dir
# holding .claude-plugin/plugin.json) and ccage loads them into EVERY cage via
# `--plugin-dir`, with no per-project install. CCAGE_PLUGINS_FROM may itself be a
# single plugin dir. Unlike commands/agents/skills (symlink-shared into the cage),
# plugins are session-loaded at launch — Claude reads the dir directly, so there is
# nothing to copy and no cage state to mutate. Unset / missing / empty → no-op; it
# never fails the launch. Appends to the already-initialized _ccage_extra_args array.
_ccage_collect_plugin_dirs() {
    local root="${CCAGE_PLUGINS_FROM:-}"
    [ -n "$root" ] || return 0
    [ -d "$root" ] || return 0

    # CCAGE_PLUGINS_FROM given as a single plugin dir.
    if [ -f "$root/.claude-plugin/plugin.json" ]; then
        _ccage_extra_args+=(--plugin-dir "$root")
        return 0
    fi

    # Otherwise a library: each immediate child that is itself a plugin. zsh aborts
    # a function on a no-match glob (NOMATCH is default-on); bash leaves the pattern
    # literal (rejected by the -d test). Disable nomatch locally in zsh so an empty
    # library is a clean no-op in both shells.
    if [ -n "${ZSH_VERSION:-}" ]; then setopt local_options no_nomatch 2>/dev/null; fi
    local d
    for d in "$root"/*; do
        if [ -d "$d" ] && [ -f "$d/.claude-plugin/plugin.json" ]; then
            _ccage_extra_args+=(--plugin-dir "$d")
        fi
    done
}

# ---- the wrapper ----
claude() {
    if [ -n "${CCAGE_DISABLE:-}" ]; then
        command claude "$@"
        return
    fi

    local dir
    dir="$(_ccage_config_dir_for "$PWD")"
    # `local -x`, not `export`: dynamically scoped so the helpers below and the
    # final `command claude` still see it in their environment, but it is unset
    # when this function returns — so it never leaks into the interactive shell
    # and cannot bleed into an unrelated tool run after a later `cd`. (Every
    # `claude` invocation re-resolves it, so the wrapper never relies on it
    # persisting.) Works identically under bash 3.2 and zsh (both dynamically
    # scope `local` and honor the `-x` export flag).
    local -x CLAUDE_CONFIG_DIR="$dir"
    _ccage_bootstrap_dir "$CLAUDE_CONFIG_DIR" "$PWD"
    _ccage_seed_session_docs_hooks "$CLAUDE_CONFIG_DIR"
    _ccage_seed_local_hooks "$CLAUDE_CONFIG_DIR"
    _ccage_write_signore "$PWD"

    # local -x for the same reason as CLAUDE_CONFIG_DIR above: configure the caged
    # claude process without leaking these into the interactive shell.
    [ -z "${CCAGE_KEEP_ATTRIBUTION:-}" ] && local -x CLAUDE_CODE_ATTRIBUTION_HEADER=0
    [ -z "${CCAGE_KEEP_AUTOUPDATER:-}" ] && local -x DISABLE_AUTOUPDATER=1

    # Resume cost prompt — passes through silently for non-resume args, gates,
    # and below-threshold cases. Returns non-zero only when user cancels or
    # picks handoff (in which case we don't exec claude).
    _ccage_intercept_resume "$@" || return $?

    _ccage_extra_args=()
    _ccage_pre_exec_hook "$PWD" "$CLAUDE_CONFIG_DIR"
    _ccage_collect_plugin_dirs   # opt-in: --plugin-dir flags for CCAGE_PLUGINS_FROM

    # ${arr[@]+"${arr[@]}"} is the bash-3.2-safe idiom for expanding a possibly-
    # empty array under `set -u`. On bash 3.2 (macos default), expanding a
    # declared-empty array as "${arr[@]}" errors as "unbound variable"; bash 4.4+
    # treats it as empty. The pre-exec hook may have appended to extra_args, or not.
    command claude ${_ccage_extra_args[@]+"${_ccage_extra_args[@]}"} "$@"
}
