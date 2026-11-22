# ccage

[![CI](https://github.com/farhanferoz/ccage/actions/workflows/ci.yml/badge.svg)](https://github.com/farhanferoz/ccage/actions/workflows/ci.yml)

ccage gives every working directory its own [Claude Code](https://docs.anthropic.com/en/docs/claude-code) config dir, and adds the tools that keep long sessions cheap and alive: a resume cost prompt, a `/checkpoint` loop, an autonomous context manager (`ccage-auto`), and a watcher that outlives the session (`ccage-watch`).

> Status: early. API and defaults may still change.

## Install

Requirements: bash 3.2 or newer (stock macOS works) or zsh 5 or newer, on Linux or macOS. Native Windows is unsupported and WSL works. `jq` is required (`brew install jq`, `apt install jq`, `dnf install jq`). `python3` is needed by `ccage-auto`, `ccage-watch`, `ccage doctor` and the onboarding patch. `npx` is needed only by `ccusage-all`.

```sh
git clone --recurse-submodules https://github.com/farhanferoz/ccage
cd ccage
./install.sh
```

Open a new shell (or `source ~/.bashrc`) to activate. The installer appends a sourcing loop to your rc file if one is not already there and never edits the rc file in place. It copies:

| Installed file | Purpose |
|---|---|
| `~/.bashrc.d/claude-isolation.sh` (`~/.zshrc.d/` for zsh) | The `claude` wrapper: config-dir pivot, bootstrapping, resume prompt |
| `~/.bashrc.d/claude-ccusage.sh` | `ccusage-all` aggregator |
| `<prefix>/bin/ccage`, `ccage-auto`, `ccage-watch`, `ccb-report` | The command line tools (prefix defaults to `~/.local`) |
| `<prefix>/share/ccage/` | Libraries and prompts the tools load |
| `~/.claude/hooks/` | Session-continuity hooks, the plan-contract guard, the ask guard, the stop guard and the weekly-limit sensor |
| `<share-from>/skills/` | The `/checkpoint`, `/checkpoint-threshold`, `/keepwarm` and `/skill-catalog` skills (`<share-from>` is `$CCAGE_SHARE_FROM`, default `~/.claude`) |
| `~/.claude/CLAUDE.md` | A short marker-guarded session-continuity note, appended once |

An existing, different target is backed up first as `<file>.pre-update-<timestamp>`.

| Install flag | Effect |
|---|---|
| `--dry-run` | Print what would happen |
| `--shell bash\|zsh` | Force the target shell |
| `--prefix DIR` | CLI and library prefix (default `~/.local`) |
| `--no-ccusage` | Skip `ccusage-all` |
| `--no-cli` | Skip `ccage`, `ccage-auto`, `ccage-watch` and their libraries |
| `--no-session-docs` | Skip the hooks, the `/checkpoint` and `/skill-catalog` skills and the `CLAUDE.md` note |
| `--no-keepwarm` | Skip the `/keepwarm` skill |
| `--no-checkpoint-threshold` | Skip the `/checkpoint-threshold` skill |

Uninstall with `./uninstall.sh` (flags `--shell`, `--prefix`, `--dry-run`). It removes the wrapper, `ccage`, `ccage-auto`, the libraries, the hooks, the `/checkpoint`, `/keepwarm` and `/checkpoint-threshold` skills and ccage's hook entries in every cage's `settings.json`. It leaves per-project config dirs, credentials, `claude-overrides.sh`, and any repo's `RESUME.md` and `CHANGELOG.md` alone. It does not remove `ccage-watch`, `ccb-report` or the `/skill-catalog` skill, so delete those by hand.

## Quick use

Work as usual. The wrapper pivots `CLAUDE_CONFIG_DIR` on every `claude` call:

```sh
cd ~/dev/api && claude     # config dir ~/.claude-api
cd ~/dev/web && claude     # config dir ~/.claude-web, independent of the first
```

Each config dir has its own credentials, so run `claude /login` once per project. Common commands:

```sh
ccage handoff             # brief for a fresh session from the latest session JSONL
ccage doctor              # backfill session-docs hooks into every cage, list RESUME bloat
ccage enable-mcp NAME -- CMD ARGS...   # opt this project into an MCP server
ccage plan-report PLAN.md              # plan items with their done-when checks run now
ccage review PLAN.md ID                # independent model review of one plan item
ccage-auto                # claude with automatic checkpoint, clear and resume
ccage-watch arm --cond CMD --note TEXT # report into RESUME.md when CMD exits 0
ccusage-all               # ccusage across every cage
```

Inside a session: `/checkpoint` before `/clear`, `/keepwarm` before stepping away, `/checkpoint-threshold` to retune `ccage-auto`, `/skill-catalog` to find an installed skill the session did not list.

## Configuration

Every setting is an environment variable with the default shown. Set them before launching `claude`, or export them from `~/.bashrc.d/claude-overrides.sh` (see [Overrides file](#overrides-file)). Timings and caps not listed here are in [docs/FEATURES.md](docs/FEATURES.md).

### Wrapper and cages

| Variable | Default | Effect |
|---|---|---|
| `CCAGE_ROOT` | `$HOME` | Parent directory for config dirs |
| `CCAGE_PREFIX` | `.claude-` | Config dir name prefix |
| `CCAGE_SLOT` | unset | Adds `--<slot>` to the config dir name, so two sessions can share one path. Characters `[A-Za-z0-9_-]` |
| `CCAGE_DISABLE=1` | off | Bypass the wrapper for one call |
| `CCAGE_KEEP_ATTRIBUTION=1` | off | Leave `CLAUDE_CODE_ATTRIBUTION_HEADER` alone (ccage otherwise sets it to `0`) |
| `CCAGE_KEEP_AUTOUPDATER=1` | off | Leave `DISABLE_AUTOUPDATER` alone (ccage otherwise sets it to `1`) |
| `CCAGE_NO_AUTO_SIGNORE=1` | off | Do not create a baseline `.claudesignore` |
| `CCAGE_NO_ONBOARDING_PATCH=1` | off | Do not pre-set `hasCompletedOnboarding` |
| `CCAGE_NO_RESUME_PROMPT=1` | off | Skip the cost prompt for `claude -r` and `claude -c` |
| `CCAGE_RESUME_PROMPT_MIN_USD` | `0.25` | Estimated rewrite cost (dollars) below which the prompt is skipped |
| `CCAGE_SHARE_FROM` | unset | Master dir whose `commands`, `agents` and `skills` are symlinked into each new cage |
| `CCAGE_SHARE_DIRS` | `commands agents skills` | Which master subdirectories to share |
| `CCAGE_PLUGINS_FROM` | unset | Folder of plugin dirs loaded into every cage with `--plugin-dir` |
| `CCAGE_HANDOFF_DIR` | `${XDG_DATA_HOME:-~/.local/share}/ccage/handoffs` | Where `ccage handoff` writes briefs |
| `CCAGE_LIB` | `<ccage bin dir>/../share` | Library directory for `ccage` (set only when testing a checkout) |

### Session continuity hooks

| Variable | Default | Effect |
|---|---|---|
| `CCAGE_SESSION_DOCS=1` | off (opt in) | Seed the session-continuity hooks into each cage's `settings.json` |
| `CCAGE_NO_AUTOLOAD=1` | off | Skip the `RESUME.md` auto-read hook and its chunk hooks |
| `CCAGE_NO_BUDGET_HOOK=1` | off | Skip the RESUME budget guard |
| `CCAGE_NO_PLAN_GUARD=1` | off | Skip the plan-contract guard |
| `CCAGE_SEED_LOCAL_HOOKS=1` | off (opt in) | Seed your own hooks from `~/.claude/settings.json` into each cage. See [docs/SEED-LOCAL-HOOKS.md](docs/SEED-LOCAL-HOOKS.md) |
| `CCAGE_HOOKS_DIR` | `~/.claude/hooks` | Where the hook scripts are installed and referenced |
| `CCAGE_RESUME_BUDGET_BYTES` | `14000` | Byte budget for `RESUME.md` |
| `CCAGE_RESUME_BUDGET_BLOCKS` | `3` | Most `## Session` blocks `RESUME.md` may hold |
| `CCAGE_RESUME_BUDGET_LINES` | `250` | Line budget the auto-read hook applies to `RESUME.md` |
| `CCAGE_TIER_BUDGET_BYTES` | `26000` | Byte budget for the always-loaded startup tier (`CLAUDE.md`, `main-session-doctrine.md`, `rules/*.md`). A write that raises the total past it is blocked. Machine-wide |
| `CCAGE_DOC_CHUNKS` | `12` | Hook parts per document (a hook's output is capped at 10,000 characters) |

### `ccage-auto`

| Setting | Flag | Variable | Default |
|---|---|---|---|
| On or off | `--autock` / `--no-autock` | `CCAGE_AUTOCK=0` | on |
| Soft threshold (%) | `--soft N` | `CCAGE_AUTOCK_SOFT` | 40 |
| Hard threshold (%) | `--hard N` | `CCAGE_AUTOCK_HARD` | soft + 20, capped at 100 |
| Context window, forced (tokens) | `--window N` | `CCAGE_AUTOCK_WINDOW` | per model |
| Context window, per-model map | `--window-map 'opus=1000000,haiku=200000'` | `CCAGE_AUTOCK_WINDOWS` | built in |
| Poll interval (s) | `--poll N` | `CCAGE_AUTOCK_POLL` | 12 |
| Silent-stall watchdog (s idle, 0 = off) | none | `CCAGE_AUTOCK_STALL_IDLE` | 600 |
| Idle-session supervisor on or off | none | `CCAGE_AUTOCK_SUPERVISOR=0` | on |
| Supervisor: quiet before it asks (s) | none | `CCAGE_AUTOCK_SUPERVISOR_IDLE` | 300 |
| Supervisor: quiet after asking, before it restarts (s) | none | `CCAGE_AUTOCK_SUPERVISOR_ESCALATE` | 300 |
| Close the session when the work is marked done | `--exit-on-done` / `--no-exit-on-done` | `CCAGE_AUTOCK_EXIT_ON_DONE=0` | on |
| Done-close: transcript quiet before `/exit` (s) | none | `CCAGE_AUTOCK_DONE_GRACE` | 10 |
| Wait for `/clear` to run (s) | `--clear-timeout N` | `CCAGE_AUTOCK_CLEAR_TIMEOUT` | 300 |
| Weekly-limit floor (remaining %, 0 = off) | `--weekly-floor N` | `CCAGE_AUTOCK_WEEKLY_FLOOR` | off |
| Claude-in-Chrome handshake | none | `CCAGE_AUTOCK_CHROME=1` keeps it | off (`--no-chrome`) |
| Keep the prompt cache warm while idle | `--no-keepwarm` | `CCAGE_AUTOCK_KEEPWARM=0` | on |
| Keep-warm: quiet before a ping (min, 1-59) | none | `CCAGE_AUTOCK_KEEPWARM_INTERVAL` | 55 |
| Keep-warm: pings per idle stretch (1-24) | none | `CCAGE_AUTOCK_KEEPWARM_MAX` | 6 |
| Keep-warm: no ping below this context (tokens) | none | `CCAGE_AUTOCK_KEEPWARM_MIN_TOKENS` | 100000 |
| Kickoff prompt typed at startup | none | `CCAGE_AUTOCK_INIT_PROMPT` | none |
| Kickoff fallback delay if the TUI marker never appears (s) | none | `CCAGE_AUTOCK_INIT_DELAY` | 20 |
| Skip the bypass-permissions auto-accept | none | `CCAGE_AUTOCK_NO_BYPASS_ACCEPT=1` | off |
| Skip the `AskUserQuestion` guard | none | `CCAGE_AUTOCK_NO_ASK_GUARD=1` | off |

An out-of-range threshold falls back to its default, and `soft >= hard` raises `hard` above `soft`. `ccage-auto --help` forwards to `claude`, so the flag list above and the header of [bin/ccage-auto](bin/ccage-auto) are the reference.

### `ccage-watch`

| Setting | Flag | Variable | Default |
|---|---|---|---|
| Poll interval (s) | `--interval` | `CCAGE_WATCH_INTERVAL_S` | 600 |
| Expiry (s) | `--ttl` | `CCAGE_WATCH_TTL_S` | 86400 |
| Hold expiry (s) | `--ttl` on `hold` | `CCAGE_WATCH_HOLD_TTL_S` | 259200 (72 h) |

## What ccage does

Claude Code stores session history, settings and OAuth tokens under one config dir (`~/.claude` by default). Two sessions in two repos then share that dir. A setting saved by one session reaches the other and can change the start of its next request, so that request misses the prompt cache and bills its whole context at full price. Both sessions also race to refresh the OAuth token, and the one that loses drops to the login screen. Shell history, MCP registrations and settings blend across unrelated projects.

> Update, 2026-11-20 (Claude Code 2.1.329): the settings problem looks fixed upstream. Claude Code 2.1.323 stopped a running session undoing a settings edit made elsewhere. In a test, a running session had its settings file changed between messages, first with an added permission and then with an added environment variable. The session picked up each change and kept its cache: 78 and 37 tokens newly cached, against about 27,000 read from the cache. Changing the model or effort level was not tested (Claude Code's changelog lists effort changes as cache-safe only on Claude Fable 5.1), and neither were the credential and history points.

Setting `CLAUDE_CONFIG_DIR` by hand for every `cd` fixes all of this, and ccage does it for you. A shell function over `claude`:

1. Computes a config dir from `$PWD`: `~/.claude-<basename>` by default.
2. Appends an 8-character hash of the full path when two different paths share a basename.
3. Writes a `.owning_path` marker the first time a dir is used, so a later call from another path takes the hash fallback instead of silently sharing.
4. Pre-sets `hasCompletedOnboarding` on a fresh config dir, so credentials held elsewhere are not followed by the login flow.
5. Drops a baseline `.claudesignore` in any repo without one, which keeps `node_modules`, virtualenvs and build output out of the context window.
6. Exports `CLAUDE_CODE_ATTRIBUTION_HEADER=0`. Claude Code otherwise sends an `x-anthropic-billing-header` containing a `cch=<hash>` that rotates per request and destabilises prompt-cache keys. Mechanism: [claude-code-router PR #1220](https://github.com/musistudio/claude-code-router/pull/1220), [cc-switch issue #2025](https://github.com/farion1231/cc-switch/issues/2025). This is one cache-invalidation source among several. [anthropics/claude-code#40652](https://github.com/anthropics/claude-code/issues/40652) is an adjacent open bug that ccage does not fix, and [claude-code-cache-fix](https://github.com/cnighswonger/claude-code-cache-fix) is complementary.
7. Exports `DISABLE_AUTOUPDATER=1`, because parallel sessions racing on a self-update can corrupt the install. Bump the CLI manually.

Further tools:

- `ccusage-all` runs [`ccusage`](https://www.npmjs.com/package/ccusage) across every isolated config dir and aggregates the output.
- `ccage handoff` writes an offline Markdown brief from any session JSONL, as a context bootstrap for a fresh session. It uses only `jq` and makes no API calls. See [docs/FEATURES.md](docs/FEATURES.md) and [docs/PHASE-6-HANDOFF-SPEC.md](docs/PHASE-6-HANDOFF-SPEC.md).
- A resume cost prompt for `claude -c` and `claude -r <id>` (below).
- A session-continuity loop: `/checkpoint`, an auto-read hook and `ccage doctor` (below).
- `/keepwarm`, a bounded cache keep-warm loop for planned absences. `/keepwarm [interval] [max]` (defaults 55 minutes and 6 pings) schedules minimal self-wake turns that re-read the cached prefix before the cache expires. While you are active, pending pings are re-anchored on a best-effort basis, and a ping that slips through is a free reset that does not count towards the cap. Costs and limits: [docs/FEATURES.md](docs/FEATURES.md).
- `ccage enable-mcp` and `disable-mcp` for per-project MCP servers (below).
- `CCAGE_PLUGINS_FROM`, which loads one folder of plugins into every cage (below).
- `ccage-auto`, an autonomous context manager (below), and `ccage-watch`, a condition watcher that outlives its session (below).
- `ccage plan-report` and `ccage review`, the plan-contract tools. The plan-contract guard refuses to tick a plan item whose `done when` check fails, and refuses to drop an item without the owner's quoted words. See [docs/FEATURES.md](docs/FEATURES.md).
- A circuit breaker for stuck subagents inside `ccage-auto`, with `ccb-report` for its ledger. See [docs/CIRCUIT-BREAKER.md](docs/CIRCUIT-BREAKER.md).
- A `/skill-catalog` skill that searches every installed skill, including ones outside the session's skill list, and activates one on demand.

Claude Code reads `settings.json` once at startup and flushes its in-memory copy on exit ([issue #51843](https://github.com/anthropics/claude-code/issues/51843)). When two sessions share a config dir, the second to exit overwrites the first one's changes. Per-project config dirs avoid this.

## Overrides file

For per-path config-dir pinning, per-directory environment variables, CLI flag injection or UI-settings seeding (a `statusLine`, for instance), copy the example to `~/.bashrc.d/claude-overrides.sh`:

```sh
cp share/claude-overrides.sh.example ~/.bashrc.d/claude-overrides.sh
```

It loads after `claude-isolation.sh` (alphabetical order) and redefines two hook functions:

- `_ccage_config_dir_override PWD` echoes a dir and returns 0 to override the default choice for specific paths.
- `_ccage_pre_exec_hook PWD CONFIG_DIR` runs just before `command claude`. It can export environment variables, append to `_ccage_extra_args` to inject CLI flags, or seed UI-only keys into `$CONFIG_DIR/settings.json`.

Seed only UI and display keys from the pre-exec hook. Copying permissions, plugins, credentials or other state from a shared master dir re-creates the cross-session cache-busting that ccage exists to prevent. `claude-overrides.sh` is user data and `./uninstall.sh` leaves it alone.

**Pin a path to a named config dir:**

```sh
_ccage_config_dir_override() {
    case "$1" in
        /home/me/dev/project-aabbcc)   echo "$HOME/.claude-project"; return 0 ;;
        /home/me/dev/project-aabbcc/*) echo "$HOME/.claude-project-$(basename "$1")"; return 0 ;;
    esac
    return 1
}
```

**Inject a plugin channel on specific worktrees:**

```sh
_ccage_pre_exec_hook() {
    case "$1" in
        /home/me/dev/work/task-a)
            export TELEGRAM_STATE_DIR="$HOME/.claude/channels/telegram-task-a"
            _ccage_extra_args+=(--channels plugin:telegram@claude-plugins-official)
            ;;
    esac
}
```

**Share slash commands, agents and skills across all projects:**

```sh
# In ~/.bashrc.d/claude-overrides.sh:
export CCAGE_SHARE_FROM="$HOME/.claude-master"
# export CCAGE_SHARE_DIRS="commands agents"   # default: commands agents skills
```

On first bootstrap of a project's config dir, ccage symlinks `commands`, `agents` and `skills` from the master dir into it. Existing entries are left alone and missing master subdirectories are skipped. Keep `memory/`, `projects/`, `settings.json`, `plugins/` and `hooks/` out of the master dir, because they hold per-session state that breaks isolation.

Sharing runs only at bootstrap, and only when the target subdirectory does not exist. Cages created before `CCAGE_SHARE_FROM` was set, or ones with a real `skills/`, `commands/` or `agents/` dir, do not pick up new master skills. To backfill:

```sh
for d in ~/.claude-*/; do
    s="${d%/}/skills"
    [ ! -e "$s" ] && [ ! -L "$s" ] && ln -s "$HOME/.claude/skills" "$s"
done
```

Running sessions load skills and slash commands at startup, so restart them for the new symlink to take effect.

**Seed a statusline into fresh config dirs** (idempotent, overwrites nothing):

```sh
_ccage_pre_exec_hook() {
    local config_dir="$2"
    command -v python3 >/dev/null || return
    python3 - "$config_dir/settings.json" <<'PY' 2>/dev/null
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text()) if p.exists() else {}
if "statusLine" not in d:
    d["statusLine"] = {"type": "command", "command": "bash ~/.claude/statusline-command.sh"}
    p.write_text(json.dumps(d, indent=2) + "\n")
PY
}
```

## Resume cost prompt and `ccage handoff`

A `--resume` or `--continue` is cheap only while the session's prompt cache is alive. Inside the cache lifetime the resume reads the prior conversation from cache. This was measured on 2026-10-05 on Claude Code 2.1.289 for Opus 5.5, Sonnet 5.5 and Haiku 4.5, two minutes after the session, with both `-r` and `-c`. After the cache expires, the whole prefix is rewritten at the cache-write rate, which is real money on a long Opus session. Older Claude Code builds cache-missed on every resume (GitHub [#51764](https://github.com/anthropics/claude-code/issues/51764), [#43657](https://github.com/anthropics/claude-code/issues/43657), [#44045](https://github.com/anthropics/claude-code/issues/44045)).

Idle gaps longer than the cache lifetime also trigger a full rewrite. Claude Code picks the lifetime by authentication method. Claude subscriptions get the 1-hour tier. API key, Bedrock, Vertex and Foundry default to 5 minutes (opt in to 1 hour with `ENABLE_PROMPT_CACHING_1H=1`, force 5 minutes with `FORCE_PROMPT_CACHING_5M=1`, both upstream Claude Code variables). Subagents always use the 5-minute tier. For planned absences, use `/keepwarm`.

When you run `claude -c` or `claude -r <uuid>`, ccage estimates the rewrite cost from the session JSONL and asks before launching:

```
ccage: Continuing most-recent session 4f616b4b · 8h ago · claude-opus-4-7
       Resume will rewrite ~70K tokens. Estimated cost: $1.10–$1.65.
       [r]esume / [h]andoff / [c]ancel?
```

One keypress answers it. The prompt is skipped with `CCAGE_NO_RESUME_PROMPT=1`, below `CCAGE_RESUME_PROMPT_MIN_USD`, on non-tty stdin, and with `CCAGE_DISABLE=1`.

`ccage handoff` turns a session JSONL into a Markdown brief to paste as the first message of a fresh session:

```sh
ccage handoff                 # most-recent session of the current project
ccage handoff 4f616b4b        # a session by UUID prefix
ccage handoff --stdout        # print instead of writing a file
```

Further options: `--output FILE`, `--max-prompts N` (default 20), `--project PATH`, `--config-dir DIR`, `--no-subagents`. The brief holds the user prompts in order, the files read, edited and written, the Bash commands run, the last assistant turn, token totals and a cost estimate. It goes to `$CCAGE_HANDOFF_DIR/<project>-<session>-<timestamp>.md` and is copied to the clipboard when `pbcopy`, `wl-copy`, `xclip` or `xsel` is available. See [docs/FEATURES.md](docs/FEATURES.md).

## Per-project MCP opt-in (`ccage enable-mcp`)

ccage keeps MCP registrations per project, because sharing them across cages is the cross-session cache-busting it exists to prevent. Agents and skills are the shared part, symlinked from `~/.claude`. `ccage enable-mcp` is the per-project opt-in for a stdio MCP server:

```
ccage enable-mcp playwright-test -- npx playwright run-test-mcp-server --headless
```

It writes a project-scoped `.mcp.json` in the current dir (`--dir DIR` overrides), which Claude Code reads at startup. Approve the server once on first launch. The command touches only `<dir>/.mcp.json`, never a cage's `.claude.json` and never the `~/.claude` master. It is idempotent, keeps other servers and other keys on the entry, and `--dry-run` previews. Remove a server with `ccage disable-mcp <name>`. Remote servers (`http` or `sse`) are added by editing `.mcp.json` directly. Full reference: [docs/FEATURES.md](docs/FEATURES.md).

## Shared plugins across cages (`CCAGE_PLUGINS_FROM`)

Plugins normally install per config dir, so each cage would need its own install. Point `CCAGE_PLUGINS_FROM` at one folder of plugin directories (each holding `.claude-plugin/plugin.json`) and the wrapper passes a `--plugin-dir` for each on every launch:

```
export CCAGE_PLUGINS_FROM="$HOME/.claude/plugins-shared"
```

This uses a supported Claude Code launch flag, so nothing is copied into a cage. It is opt-in, a single plugin dir works too, and an unset, missing or empty folder is a no-op that never fails a launch. Loaded plugins are active in every session, so keep the set small. Skip it for one launch with `CCAGE_PLUGINS_FROM= claude ...`. Full reference: [docs/FEATURES.md](docs/FEATURES.md).

## Session continuity (`/checkpoint` and auto-read)

Long sessions end at `/clear`, and the next one starts cold. ccage ships an optional loop that closes the gap:

- **`/checkpoint` skill.** Writes session state into the repo's `RESUME.md` (slot-aware under `CCAGE_SLOT`) and rolls older detail into `CHANGELOG.md`. Both files are excluded from git through `.git/info/exclude`. `--tidy` also reorganises the cage's memory dir, and `--final` marks the work finished (see `ccage-auto`).
- **Auto-read hook.** A `SessionStart` hook re-injects `RESUME.md` on startup, resume, `/clear` and compaction, so the loop is `/checkpoint`, `/clear`, state reloaded.
- **Budget hook.** A `PostToolUse` guard that keeps `RESUME.md` within `CCAGE_RESUME_BUDGET_BYTES` and `CCAGE_RESUME_BUDGET_BLOCKS` and the startup tier within `CCAGE_TIER_BUDGET_BYTES`. A write that grows an over-budget file past its limit is refused with the remedy named, and a write that shrinks it is only advised.
- **Plan-contract guard.** A `PreToolUse` guard on plan documents: a tick needs a passing `done when` check or evidence, and a dropped item needs the owner's quoted words. `ccage plan-report` shows the state of a plan.
- **`ccage doctor`.** Sweeps every existing cage, backfills the hook entries into each `settings.json` (idempotent merge, existing keys preserved), and prints a worklist of bloated `RESUME*.md` files and messy memory dirs. `--dry-run` previews.

`install.sh` deploys the hooks and skills (skip with `--no-session-docs`). Seeding the hook entries into cages is opt-in through `CCAGE_SESSION_DOCS=1`, with per-hook opt-outs listed under [Configuration](#session-continuity-hooks).

> Caveat: the auto-read hook injects `RESUME.md` from whatever repo you are in, including one you just cloned. A malicious repo could ship a crafted `RESUME.md` as a prompt-injection vector (details in [docs/FEATURES.md](docs/FEATURES.md)). Set `CCAGE_NO_AUTOLOAD=1` when you work in untrusted checkouts.

## Autonomous context management (`ccage-auto`)

`/checkpoint`, `/clear`, reload still needs a person to type `/clear`. For an unattended session that otherwise grows until auto-compact (near 100% of the window, which is costly and makes the model duller), `ccage-auto` runs the whole loop:

```sh
ccage-auto            # launch like `claude`, with auto-checkpoint on
ccage-auto --status   # print the resolved transcript and current occupancy, then exit
```

It launches the normal cage session through a pseudo-terminal and runs a small in-process watcher that:

- **Measures** context occupancy from the session's transcript JSONL: `input + cache_read + cache_creation` tokens of the latest turn. It makes no model calls, no estimates and no API calls.
- At the **soft threshold** (default 40%) types a one-line advisory nudge. The model checkpoints at a clean breakpoint and prints a sentinel, and may hold off if checkpointing now would lose in-flight work, such as a running subagent or a mid-edit.
- At the **re-nudge line** (`hard - 5`) re-sends the nudge with the firm wording used at the hard backstop, without interrupting yet.
- Once the checkpoint is confirmed on disk, types `/clear`, which the model cannot do for itself, and then a short resume nudge. The `SessionStart` auto-read hook reloads `RESUME.md`. The resume nudge waits for proof that the clear ran (the transcript rotating on disk) and never for a timer, because Claude Code queues input typed during a running turn. A session is never left cleared but uninstructed: after `/clear` is typed, either the resume follows or the session is closed. If the rotation does not come within `--clear-timeout`, the watcher gives up without resuming.
- At the **hard threshold** (default 60%) sends Escape as the final backstop before auto-compact, if the model still has not checkpointed. The whole ladder depends on occupancy only, never on a wall-clock timer.
- Runs a **silent-stall watchdog**. A nudged session that goes quiet without printing the sentinel gets one firm re-nudge after `CCAGE_AUTOCK_STALL_IDLE` seconds without transcript growth, then rate-limited log entries only.
- Runs a **bounded supervisor** for the opposite stall, a session that goes idle with work outstanding. After `CCAGE_AUTOCK_SUPERVISOR_IDLE` seconds of quiet it asks once and offers four answers: carry on, run `/checkpoint --final` if nothing is left, arm a `ccage-watch` spec if the wait is on a machine, or declare `ccage-watch hold --question '...'` if the wait is on a person. Still quiet `CCAGE_AUTOCK_SUPERVISOR_ESCALATE` seconds later, it converts the session once (checkpoint, `/clear`, resume). After that it stays silent until the session makes a tool call. It never infers that work is finished. It stays quiet while a background job is growing and a watcher is armed for it, and it names the file when a job has landed unread.

Injection writes keystrokes to the pty. It needs no tmux and no API calls. The only model work triggered is the checkpoint and resume you wanted anyway. The watcher is slot-aware (`CCAGE_SLOT`) and logs to `<cage>/ccage-autock.log`.

A watched launch exports `CCAGE_AUTONOMOUS=1` into the session and registers a per-run `PreToolUse` hook that blocks `AskUserQuestion`, because a blocking question would stall an unattended run. The model is told to take the reversible default, log it in `RESUME.md` under `### Decisions`, and batch questions that only a person can answer. Nothing is written to a cage's own `settings.json`. Details and the opt-out are in [docs/FEATURES.md](docs/FEATURES.md).

**Retune it live with `/checkpoint-threshold`.** The thresholds are fixed at launch, and this skill changes them inside a running `ccage-auto` session:

```
/checkpoint-threshold 50        # nudge at 50% instead of 40%
/checkpoint-threshold 50 65     # soft 50%, hard 65%
/checkpoint-threshold pause     # suspend auto-checkpointing during delicate work
/checkpoint-threshold resume    # re-enable it
/checkpoint-threshold status    # show effective thresholds and current occupancy
/checkpoint-threshold reset     # drop the override, back to launch values
```

It writes a git-excluded control file (`.ccage-autock.conf`) in the project dir, which the watcher re-reads on its next poll. The override is per project dir and per run. It survives `ccage-auto`'s own `/clear` cycles and is cleared at the next real session start. For a permanent change use `--soft` and `--hard` or the variables at launch. While paused, the window can grow to auto-compact with no checkpoint. A `/clear` already in flight when the pause lands still finishes and still resumes. The same controls work from another terminal in the same dir: `ccage-auto --set soft=50`, `--pause`, `--resume`, `--reset`. To hand a running session one message, run `ccage-auto --say "text"` in the same dir (with the same `CCAGE_SLOT`, if the session has one). The watcher types it within one poll, once. With no session running, the message waits and the next session in that slot types it after its first prompt, led by when it was queued. A message waits while you have a half-typed prompt.

**Keeping the prompt cache warm while you are away.** A session idle for an hour loses its prompt cache, and the next turn rewrites the conversation at the cache-write rate, where a re-read from cache costs a fraction of it. By default the watcher types one minimal turn after 55 quiet minutes, at most 6 times per idle stretch, only when the context holds at least 100,000 tokens and the cache is on the 1-hour tier. It never types while the last assistant message has a tool call without a result (a permission prompt, question menu or plan approval looks exactly like that), and never when keystrokes have reached the session since your last Enter. Any keystroke of yours starts a new idle stretch. Every ping and every skip reason is logged. Turn it off with `--no-keepwarm`, `CCAGE_AUTOCK_KEEPWARM=0`, `/keepwarm off` or `ccage-auto --keepwarm off`, and back on with `on`. Details: [docs/FEATURES.md](docs/FEATURES.md#keep-warm-pings-for-ccage-auto-ccage_autock_keepwarm-shipped). Without `ccage-auto`, `/keepwarm` still arms the manual loop.

**Per-model context windows.** The transcript does not record which window a session has, since a 1M and a 200K session log the same model id. The window is resolved on every measurement, most specific first: a forced `--window`, the per-model map, a `[1m]` marker in the id, built-in small families (haiku is 200K), then a 1,000,000 default. A 200K or 1M variant of the same family must be pinned with `--window-map` or `--window`. The high default makes the safe failure a late checkpoint rather than an early one.

**Unattended launches.** A permission prompt blocks an unattended session, so pass `--dangerously-skip-permissions`. On a cage that has not accepted bypass mode, Claude opens a "Bypass Permissions mode" screen that defaults to "No, exit", and `ccage-auto` accepts it at startup. Opt out with `CCAGE_AUTOCK_NO_BYPASS_ACCEPT=1`. Do not use `-p` or `--print`, because headless mode runs one turn and exits. `ccage-auto` launches with `--no-chrome` to skip the Claude-in-Chrome handshake (`CCAGE_AUTOCK_CHROME=1` keeps it). The kickoff prompt (`CCAGE_AUTOCK_INIT_PROMPT`) fires when the TUI's ready marker appears in the pty output, typically within 5 to 7 seconds, with `CCAGE_AUTOCK_INIT_DELAY` as the ceiling.

**Standing down when the work is done.** The watcher loops indefinitely, because it knows the context is full and not that the task is finished. When the objective is complete, the model runs `/checkpoint --final`. That writes a `.ccage-session-done` marker, and `ccage-auto` waits for the marker-writing turn to finish, types `/exit`, and falls back to `SIGHUP` then `SIGKILL`. End a hands-off kickoff prompt with an instruction such as "when the objective is fully complete, run `/checkpoint --final`". The marker is cleared at the next session start. Opt out with `--no-exit-on-done`. The watcher also writes the marker itself, but only on facts: a checkpoint confirmed on disk, nothing running, and the supervisor's own escalation cycle having produced it. A session that went quiet and never answered gets no marker.

**Weekly-limit floor.** An unattended run should not burn the account's seven-day capacity. `--weekly-floor N` (remaining percent) arms a guard that reads the rate-limit state Claude Code passes to each statusline render. At floor plus 5 it sends one advisory nudge. At the floor it forces a checkpoint, appends a stand-down note to `RESUME.md`, and stops driving the session. A missing or stale sensor means no action.

**A kickoff prompt that stays on the rails.** An auditable unattended run has a `RESUME.md` that pins one in-scope item, a binding definition of done ("this run is DONE only when ..." with a concrete check) and pre-declared deferrals (every item that needs a person, named out of scope up front). A kickoff prompt that carries or points at those three things lets any end-of-run "waiting on you" claim be checked against a declaration made before the work started.

> Caveat: unattended auto-resume types "resume from `RESUME.md`" with no person in the loop, so a crafted `RESUME.md` in an untrusted checkout is acted on immediately. Do not run `ccage-auto` unattended in untrusted repos. `CCAGE_NO_AUTOLOAD=1` disables the reload.

## Bridging work across sessions (`ccage-watch`)

A session ends with something still running, such as CI on a pushed branch or a queue draining. A watcher started inside the Claude harness does not survive, because the harness kills backgrounded processes shortly after the session's last turn. `ccage-watch` is an operating-system process parented to init. It polls a shell command and, when the command exits 0, appends a marked block to the project's `RESUME.md`, which the auto-read hook loads at the next session start.

```sh
# Arm: bridge a CI verdict into the next session.
ccage-watch arm --cond 'gh pr checks 24 >/dev/null 2>&1; [ $? -ne 8 ]' \
                --note 'PR #24 four-leg CI verdict'

# Hold: the wait is on a person, so there is no condition to poll.
ccage-watch hold --question 'run the attended live-fire, I cannot authenticate'

ccage-watch list       # what is armed or held (status is an alias)
ccage-watch reap       # report armed watchers, and record any that died
ccage-watch disarm ID  # stop one
ccage-watch selftest   # verify every documented behaviour
```

The condition is any shell command and exit 0 means met. Defaults are listed under [Configuration](#ccage-watch).

`hold` covers a wait that no command can express, such as a decision or a credential only a person can supply. It spawns no process. It records the question in `RESUME.md` at once, so the question survives a `/clear`, and keeps the `ccage-auto` supervisor quiet until you type or the TTL lapses. `--question` is mandatory, the session cannot end the hold itself, and an unanswered hold is reported at the next session start as still open.

`ccage-watch` never launches, resumes or relaunches a session, because closing a session is a decision and relaunching would override it. It makes no API or model calls. A watcher killed by a reboot, an out-of-memory kill or a stray `kill` is recorded by `reap` at session start the same way as a firing, and every watcher still pending is named. The outcome is appended at the end of `RESUME.md` and not inserted under `### Next`, because mid-file insertion is a read-modify-write that a concurrent `/checkpoint` could clobber. It needs `python3` and installs as `<prefix>/bin/ccage-watch`.

## FAQ

**Why not set `CLAUDE_CONFIG_DIR` in a `direnv` `.envrc`?**
You can. ccage suits you if you have no per-project shell tooling and want one-command setup.

**What about `git worktree`?**
Each worktree is a distinct `$PWD` and gets its own config dir. If you nest worktrees under a common parent with identical basenames (two repos' `.claude/worktrees/main`, say), the hash fallback applies only after the first dir is claimed, so two fresh parallel sessions can claim the unmarked dir at once. Sibling-directory worktrees (`../repo-featureA`, `../repo-featureB`) avoid this.

**Can I run several sessions in the same directory?**
Yes, in two ways. Preferably use `git worktree add ../myproject-review`, which gives a sibling dir with a different basename that ccage isolates automatically. Alternatively set `CCAGE_SLOT=<name>` before `claude` to force a distinct config dir at the same path:

```
CCAGE_SLOT=review  claude     # ~/.claude-myproject--review
CCAGE_SLOT=bg      claude     # ~/.claude-myproject--bg
```

Each slot has its own credentials and history, so run `claude /login` once per slot.

**Does this work on macOS?**
Yes. The wrapper falls back from `sha1sum` to `shasum -a 1` to `openssl dgst -sha1`, and CI runs the suite under stock bash 3.2.

**What about fish, nushell and xonsh?**
Not yet. The function is straightforward to port, so open an issue.

**What about Windows?**
WSL works. Native Windows does not, and PowerShell would need a separate port.

## Limitations

- `claude` is a shell function, so anything that executes it as an external command bypasses the wrapper. `timeout 60 claude`, `nohup claude` and `xargs claude` find the real binary in `$PATH` and skip ccage's bootstrap. Wrap the call in a subshell: `bash -c 'source ~/.bashrc.d/claude-isolation.sh && claude --print "..."'`.
- Nested-worktree basename collisions in two parallel fresh sessions (see the worktree FAQ). Prefer sibling-directory worktrees, or set `CCAGE_SLOT` per session.

## How it fits the setup

ccage is the runtime layer of a wider Claude Code setup: per-project isolation, the checkpoint and resume loop, the autonomous context manager and the cross-session watcher. [claude-code-setup](https://github.com/farhanferoz/claude-code-setup) maps each practice in that setup to the repository and file that provides it, shows how to install each piece alone or all together, and explains how to add a private layer of your own. Start there if you want more than ccage.

### Companion plugins (claude-skills marketplace)

The skills, agents and hooks that use this runtime live in the [farhanferoz/claude-skills](https://github.com/farhanferoz/claude-skills) marketplace. You do not need it for the cache fix. `/checkpoint` and `/keepwarm` ship with ccage (`share/skills/`), and the marketplace no longer carries a separate session-continuity plugin. Its plugins:

- **orchestration**: write an execution-level plan and run it as autonomous dependency-wave dispatch, with guard hooks that enforce single-writer discipline. This pairs with `ccage-auto` for hours-long unattended runs. Its `writing-plans`, `executing-plans` and `subagent-driven-development` are modified forks of [obra/superpowers](https://github.com/obra/superpowers) (MIT).
- **programme-plan**: keep one plan coherent across weeks, many strands and many agents writing the same files.
- **research-report**: turn work into a self-contained report (contract guard, `pdflatex` build, fresh-reader cold-read gate). Needs `pandoc` and a `pdflatex` install.
- **research-method**: figure workflow, methodology review and pre-training change checks.
- **deep-research-tiered**: cost-tiered deep research with a cited report.
- **review-suite**: tiered local code review, from light to critical.
- **review-panel**: a simulated review panel for your own draft grant application.
- **playwright-agents**: Playwright's test agents with pinned model and effort (hosted in its own repository).
- **guards**, **workers**, **coding-standard**, **session-hooks**: policy guards that refuse or rewrite risky tool calls, model-pinned worker agents with their routing policy, one coding standard loaded at session start, and session conveniences.

```
/plugin marketplace add farhanferoz/claude-skills
/plugin install orchestration@claude-skills
```

To load them in every cage without a per-cage install, point `CCAGE_PLUGINS_FROM` at a folder holding the plugin dirs (see [Shared plugins across cages](#shared-plugins-across-cages-ccage_plugins_from)).

## Related

- [`ccusage`](https://www.npmjs.com/package/ccusage): per-dir usage accounting, which `ccusage-all` wraps.
- Any tool that reads `~/.claude-*/projects/`. ccage creates the multi-dir layout such tools analyse.

## Development

```sh
./tests/bats/bin/bats tests/                    # the full bats suite
./tests/bats/bin/bats tests/test_config_dir_for.bats   # one file
python3 -m pytest tests/ -q                     # the Python unit tests (needs pytest)
shellcheck bin/ccage share/*.sh share/hooks/*.sh share/hooks/lib/*.sh share/skills/checkpoint/*.sh share/skills/keepwarm/*.sh install.sh uninstall.sh
tests/ci-local.sh                               # mirror of the CI steps
```

bats-core is vendored at `tests/bats/` as a git submodule of [bats-core/bats-core](https://github.com/bats-core/bats-core). Clone with `--recurse-submodules`, or run `git submodule update --init` afterwards.

## Licence

MIT. See [LICENSE](LICENSE).
