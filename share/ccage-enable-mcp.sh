# shellcheck shell=bash
# ccage enable-mcp / disable-mcp — opt a single project into an MCP server,
# isolation-safely.
#
# WHY THIS EXISTS
#   ccage gives every project its own CLAUDE_CONFIG_DIR and DELIBERATELY keeps
#   MCP registrations per-project: sharing them across cages re-creates the
#   cross-session cache-bashing ccage exists to prevent (see docs/FEATURES.md
#   "UI-only seeding discipline" — never seed mcpServers from a shared master).
#   So there is no "global MCP", on purpose. The supported, isolation-clean way
#   to give ONE project an MCP server is a project-scoped `.mcp.json` in its
#   launch dir, which Claude Code reads on startup (prompting once to approve).
#
#   This command writes exactly that file and nothing else. It never touches a
#   cage's .claude.json (so it can't lose the live-session write race) nor the
#   ~/.claude master (so it can't blend the server into other projects). Agents
#   and skills ARE shared (symlinked from ~/.claude) — drop an agent .md in
#   ~/.claude/agents to make it global; MCP is the part that stays opt-in per
#   project, and this is that opt-in.
#
# Public entries: _ccage_enable_mcp_main, _ccage_disable_mcp_main.
# Pure shell + python3 (JSON merge + atomic write). Zero API calls.

# ---------------------------------------------------------------------------
# Merge/remove an mcpServers entry in a project-scoped .mcp.json.
#   $1 verb  : add | remove
#   $2 file  : path to .mcp.json
#   $3 name  : server name
#   $4 apply : 1 = write, 0 = preview only
#   $5..     : server command + args (add only)
# Prints a one-word status on stdout: enabled | updated | unchanged (add) /
# disabled | absent (remove). Exit 3 + a message on a hard error.
# ---------------------------------------------------------------------------
_ccage_mcp_edit() {
    local verb="$1" file="$2" name="$3" apply="$4"; shift 4
    python3 - "$verb" "$file" "$name" "$apply" "$@" <<'PY' 2>/dev/null
import json, os, sys, tempfile
verb, path, name, apply = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
cmd = sys.argv[5:]

mode, data = None, {}
if os.path.exists(path):
    try:
        mode = os.stat(path).st_mode & 0o777
    except OSError:
        pass
    try:
        with open(path) as f:
            data = json.load(f)
    except ValueError:
        print("not valid JSON: %s" % path); sys.exit(3)
    except OSError:
        print("cannot read %s" % path); sys.exit(3)
    if not isinstance(data, dict):
        data = {}

servers = data.get("mcpServers")
if not isinstance(servers, dict):
    servers = {}

if verb == "add":
    existing = servers.get(name)
    # Merge command+args INTO the existing entry rather than replacing it, so a
    # hand-added key on that server (e.g. "env", "type") survives a re-enable.
    entry = dict(existing) if isinstance(existing, dict) else {}
    entry["command"] = cmd[0]
    entry["args"] = cmd[1:]
    if entry == existing:
        print("unchanged"); sys.exit(0)
    status = "updated" if isinstance(existing, dict) else "enabled"
    servers[name] = entry
else:  # remove
    if name not in servers:
        print("absent"); sys.exit(0)
    status = "disabled"
    del servers[name]

# Keep mcpServers only while non-empty so a removal can leave a tidy file (and,
# if nothing else is in the doc, drop the file entirely below).
if servers:
    data["mcpServers"] = servers
else:
    data.pop("mcpServers", None)

if apply:
    if verb == "remove" and not data and os.path.exists(path):
        try:
            os.unlink(path)
        except OSError as e:
            print("write failed: %s" % e); sys.exit(3)
    else:
        d = os.path.dirname(path) or "."
        tmp = None
        try:
            os.makedirs(d, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=d, prefix=".mcp.", suffix=".ccage.tmp")
            with os.fdopen(fd, "w") as f:
                json.dump(data, f, indent=2); f.write("\n")
            os.chmod(tmp, mode if mode is not None else 0o644)
            os.replace(tmp, path)
        except OSError as e:
            if tmp:
                try: os.unlink(tmp)
                except OSError: pass
            print("write failed: %s" % e); sys.exit(3)

print(status)
PY
}

# ---- enable-mcp ------------------------------------------------------------
_ccage_enable_mcp_help() {
    cat <<EOF
Usage: ccage enable-mcp <name> [--dir DIR] [--dry-run] -- <command> [args...]

Register a stdio MCP server named <name> (command + args) into a project-scoped
.mcp.json so the next Claude session launched in that project picks it up. Remote
servers (\"type\": \"http\"/\"sse\") aren't expressible here — add those by editing
.mcp.json directly. Re-enabling updates command+args in place and keeps any other
keys you added to that entry (e.g. \"env\").

Isolation-safe by construction: writes ONLY DIR/.mcp.json (default: \$PWD) — never
a cage's .claude.json (no live-session write race) and never ~/.claude (no blend
into other projects). MCP servers stay opt-in per project on purpose; agents and
skills are the shared part (drop an agent .md in ~/.claude/agents to make it
global). Claude prompts once per project to approve a .mcp.json server — approve
it on the first launch. Remove with: ccage disable-mcp <name> [--dir DIR].

Options:
  --dir DIR    Project dir whose .mcp.json to edit (default: current dir).
  --dry-run    Preview the change without writing.
  -h, --help   This message.

Example:
  ccage enable-mcp playwright-test -- npx playwright run-test-mcp-server --headless
EOF
}

_ccage_enable_mcp_main() {
    local dir="$PWD" dry_run=0 name=""
    local -a cmd=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --dir)     [ $# -ge 2 ] || { printf 'ccage enable-mcp: --dir needs a value\n' >&2; return 2; }
                       dir="$2"; shift 2 ;;
            --dir=*)   dir="${1#--dir=}"; shift ;;
            --dry-run) dry_run=1; shift ;;
            -h|--help) _ccage_enable_mcp_help; return 0 ;;
            --)        shift; cmd=("$@"); break ;;
            -*)        printf 'ccage enable-mcp: unknown flag: %s\n' "$1" >&2; return 2 ;;
            *)         if [ -z "$name" ]; then name="$1"; shift
                       else printf 'ccage enable-mcp: unexpected argument: %s (put the command after --)\n' "$1" >&2; return 2; fi ;;
        esac
    done

    [ -n "$name" ] || { printf 'ccage enable-mcp: missing <name>\n\n' >&2; _ccage_enable_mcp_help >&2; return 2; }
    case "$name" in
        -*|*[!A-Za-z0-9_.-]*) printf 'ccage enable-mcp: invalid server name: %s (allowed: A-Za-z0-9_.-)\n' "$name" >&2; return 2 ;;
    esac
    [ "${#cmd[@]}" -gt 0 ] || { printf 'ccage enable-mcp: missing command — put it after --, e.g. -- npx playwright run-test-mcp-server\n' >&2; return 2; }
    [ -d "$dir" ] || { printf 'ccage enable-mcp: no such directory: %s\n' "$dir" >&2; return 2; }
    command -v python3 >/dev/null 2>&1 || { printf 'ccage enable-mcp: python3 is required for the .mcp.json merge\n' >&2; return 2; }

    local file="$dir/.mcp.json" apply=1 out
    [ "$dry_run" = 1 ] && apply=0
    out=$(_ccage_mcp_edit add "$file" "$name" "$apply" "${cmd[@]}") || {
        printf 'ccage enable-mcp: %s\n' "${out:-write failed}" >&2; return 3; }

    case "$out" in
        unchanged) printf '%s already enabled in %s (unchanged)\n' "$name" "$file" ;;
        enabled|updated)
            if [ "$dry_run" = 1 ]; then
                local verb=enable; [ "$out" = updated ] && verb=update
                printf '+ would %s %s → %s\n    %s\n' "$verb" "$name" "$file" "${cmd[*]}"
            else
                printf '%s %s → %s\n    %s\nNext Claude session launched in %s will prompt once to approve it.\n' \
                    "$out" "$name" "$file" "${cmd[*]}" "$dir"
            fi ;;
        *) printf 'ccage enable-mcp: %s\n' "$out" >&2; return 3 ;;
    esac
}

# ---- disable-mcp -----------------------------------------------------------
_ccage_disable_mcp_help() {
    cat <<EOF
Usage: ccage disable-mcp <name> [--dir DIR] [--dry-run]

Remove the MCP server <name> from a project-scoped .mcp.json (the inverse of
ccage enable-mcp). Touches only DIR/.mcp.json (default: \$PWD); if that leaves
the file empty it is deleted.

Options:
  --dir DIR    Project dir whose .mcp.json to edit (default: current dir).
  --dry-run    Preview the change without writing.
  -h, --help   This message.
EOF
}

_ccage_disable_mcp_main() {
    local dir="$PWD" dry_run=0 name=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dir)     [ $# -ge 2 ] || { printf 'ccage disable-mcp: --dir needs a value\n' >&2; return 2; }
                       dir="$2"; shift 2 ;;
            --dir=*)   dir="${1#--dir=}"; shift ;;
            --dry-run) dry_run=1; shift ;;
            -h|--help) _ccage_disable_mcp_help; return 0 ;;
            -*)        printf 'ccage disable-mcp: unknown flag: %s\n' "$1" >&2; return 2 ;;
            *)         if [ -z "$name" ]; then name="$1"; shift
                       else printf 'ccage disable-mcp: unexpected argument: %s\n' "$1" >&2; return 2; fi ;;
        esac
    done

    [ -n "$name" ] || { printf 'ccage disable-mcp: missing <name>\n\n' >&2; _ccage_disable_mcp_help >&2; return 2; }
    command -v python3 >/dev/null 2>&1 || { printf 'ccage disable-mcp: python3 is required\n' >&2; return 2; }

    local file="$dir/.mcp.json" apply=1 out
    [ "$dry_run" = 1 ] && apply=0
    if [ ! -f "$file" ]; then
        printf '%s not enabled (no %s)\n' "$name" "$file"; return 0
    fi
    out=$(_ccage_mcp_edit remove "$file" "$name" "$apply") || {
        printf 'ccage disable-mcp: %s\n' "${out:-write failed}" >&2; return 3; }

    case "$out" in
        absent)   printf '%s not enabled in %s (no change)\n' "$name" "$file" ;;
        disabled)
            if [ "$dry_run" = 1 ]; then printf '+ would disable %s → %s\n' "$name" "$file"
            else printf 'disabled %s → %s\n' "$name" "$file"; fi ;;
        *) printf 'ccage disable-mcp: %s\n' "$out" >&2; return 3 ;;
    esac
}
