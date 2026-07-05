# ccage

[![CI](https://github.com/farhanferoz/ccage/actions/workflows/ci.yml/badge.svg)](https://github.com/farhanferoz/ccage/actions/workflows/ci.yml)

Per-project isolation for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Every working directory gets its own config dir, so two sessions in two repos stop fighting over one prompt cache, one credential file, and one shell history.

> Status: early. API and defaults may still change.

## The problem

Claude Code stores session history, settings, and OAuth tokens under a single config dir (`~/.claude` by default). If you run two sessions in parallel — one in `~/dev/api`, one in `~/dev/web` — they share that dir. In practice that means:

- Prompt-cache entries from one project evict the other's, so cache hit rate collapses.
- Credential refresh races: if both sessions refresh an OAuth token at the same time, one loses and silently drops to the login screen.
- Shell history, MCP registrations, and settings blend across unrelated projects.
- A long-running agent in one repo corrupts the conversation state of another.

`CLAUDE_CONFIG_DIR` fixes all of this — but managing it by hand for every `cd` is the kind of thing you'll forget exactly once, on the session that mattered.

## What ccage does

Drops a tiny shell function over `claude` that:

1. Computes a config dir from `$PWD` — `~/.claude-<basename>` by default.
2. On basename collisions across different paths (two repos both named `api`, say) appends an 8-char hash of the full path so they don't merge.
3. Writes a `.owning_path` marker the first time a dir is used, so future calls from a different path trigger the hash fallback instead of silently sharing.
4. Pre-sets `hasCompletedOnboarding` on a fresh config dir, so you don't land in the login flow when you already have credentials elsewhere.
5. Drops a baseline `.claudesignore` in any repo that doesn't have one — keeps `node_modules`, virtualenvs, and build output out of the context window.
6. Exports `CLAUDE_CODE_ATTRIBUTION_HEADER=0`. Claude Code otherwise sends an `x-anthropic-billing-header` containing a `cch=<hash>` that rotates per request, destabilizing prompt-cache keys. Suppressing it restores stable prefixes. Mechanism: [claude-code-router PR #1220](https://github.com/musistudio/claude-code-router/pull/1220), [cc-switch issue #2025](https://github.com/farion1231/cc-switch/issues/2025). This is one cache-invalidation source among several — see [anthropics/claude-code#40652](https://github.com/anthropics/claude-code/issues/40652) for an adjacent, still-open bug that ccage does **not** fix; [claude-code-cache-fix](https://github.com/cnighswonger/claude-code-cache-fix) is complementary if you want both.
7. Exports `DISABLE_AUTOUPDATER=1`. Parallel sessions racing on a self-update can corrupt the install; skip the updater and bump the CLI manually.
8. Ships a `ccusage-all` helper that runs [`ccusage`](https://www.npmjs.com/package/ccusage) across every isolated config dir and aggregates the output.
9. Ships a `ccage handoff` CLI that produces an offline Markdown brief from any session JSONL — useful as a context bootstrap for a fresh session when you'd otherwise pay `claude -r`'s structural cache-rewrite tax. Pure jq, zero API calls. See [docs/FEATURES.md](docs/FEATURES.md) and [docs/PHASE-6-HANDOFF-SPEC.md](docs/PHASE-6-HANDOFF-SPEC.md).
10. Intercepts `claude -c` / `claude -r <id>` and shows the estimated cache-rewrite cost before launch, with three choices: resume, switch to a handoff brief, or cancel. Background: Claude Code's resume reliably cache-misses the message prefix even inside the TTL window — a structural request difference at `messages[0]`, isolated by a 1-hour-TTL controlled experiment in [#51764](https://github.com/anthropics/claude-code/issues/51764) (see also [#43657](https://github.com/anthropics/claude-code/issues/43657), [#44045](https://github.com/anthropics/claude-code/issues/44045); one narrow cause was fixed in Claude Code v2.1.90, the rest remain) — so resuming a long Opus session usually costs real money. Silence with `CCAGE_NO_RESUME_PROMPT=1`; tune threshold via `CCAGE_RESUME_PROMPT_MIN_USD` (default $0.25).
11. Ships an optional session-continuity loop — `/checkpoint` skill + auto-read hook + `ccage doctor` — so state survives `/clear` without copy/paste. See [Session continuity](#session-continuity-checkpoint--auto-read).
12. Ships a `/keepwarm` skill — a bounded cache keep-warm loop for planned absences. `/keepwarm [interval] [max]` (defaults 55 min × 6) schedules minimal self-wake turns that re-read the cached conversation prefix before the cache TTL expires, avoiding the full rewrite on return; while you're active it re-anchors pending pings on a best-effort basis (a ping that still slips through is a free reset — it won't consume the cap, though it's still one cheap cache-read). Costs, limits, and the tier caveat: [docs/FEATURES.md](docs/FEATURES.md).
13. Ships `ccage enable-mcp` / `disable-mcp` — opt a single project into an MCP server via a project-scoped `.mcp.json`, the isolation-safe way (MCP registrations stay per-project; only agents/skills are globally shared). Settles "why isn't my MCP-backed tool picked up in this cage?" once. See [Per-project MCP opt-in](#per-project-mcp-opt-in-ccage-enable-mcp).
14. Ships `CCAGE_PLUGINS_FROM` — load a curated folder of plugins into every cage with **no per-project install** (the wrapper passes `--plugin-dir` at launch, so Claude session-loads them). Install once, available everywhere, like your shared skills. See [Shared plugins across cages](#shared-plugins-across-cages-ccage_plugins_from).

### Bonus: dodges the `settings.json` write race

Claude Code reads `settings.json` once at startup and flushes its in-memory copy on exit ([issue #51843](https://github.com/anthropics/claude-code/issues/51843)). When two sessions share a config dir, the second one to exit silently clobbers changes the first made. Per-project config dirs sidestep this entirely — each session owns its own file.

Each worktree gets its own credentials. Run `claude /login` once per project.

## Prerequisites

- **bash ≥ 4** or **zsh ≥ 5**
- **`jq`** — required by `ccage handoff`. Install via `brew install jq`, `apt install jq`, `dnf install jq`, etc. Run `./install.sh --no-cli` if you don't want the CLI/handoff parts and prefer not to install jq.
- **`python3`** (optional) — only used to patch an existing `.claude.json` with `hasCompletedOnboarding=true`. Without it, your first session in a fresh config dir will see Claude Code's onboarding flow; you can proceed through it normally.
- **`npx`** (optional) — only needed if you use `ccusage-all`.
- **Linux or macOS.** Windows native is unsupported; WSL works.

## Install

```sh
git clone https://github.com/farhanferoz/ccage
cd ccage
./install.sh
```

Installs two files to `~/.bashrc.d/` (or `~/.zshrc.d/` for zsh) and appends a sourcing loop to your rc file if one isn't already there. It won't edit your rc in place.

```
~/.bashrc.d/claude-isolation.sh    wrapper (config-dir pivot, bootstrapping)
~/.bashrc.d/claude-ccusage.sh      ccusage-all aggregator (independent)
```

```sh
./install.sh --dry-run    # show what would happen
./install.sh --shell zsh  # force target shell
./install.sh --no-ccusage # skip the ccusage-all helper
```

Open a new shell (or `source ~/.bashrc`) to activate.

### Customizing with an overrides file

For per-path config-dir pinning, per-PWD env vars, CLI flag injection, or UI-settings seeding (e.g. a `statusLine`), drop a file at `~/.bashrc.d/claude-overrides.sh`:

```sh
cp share/claude-overrides.sh.example ~/.bashrc.d/claude-overrides.sh
# edit to taste
```

It loads *after* `claude-isolation.sh` (alphabetical order) and redefines two hook functions:

- `_ccage_config_dir_override PWD` — echo a dir + return 0 to override the default choice for specific paths.
- `_ccage_pre_exec_hook PWD CONFIG_DIR` — runs just before `command claude`. Can export env vars, append to `_ccage_extra_args` to inject CLI flags, or seed UI-only keys (e.g. `statusLine`) into `$CONFIG_DIR/settings.json`.

**One discipline rule for the pre-exec hook:** if you seed into `settings.json`, seed only UI/display keys. Never copy permissions, plugins, credentials, or other state from a shared master dir — that re-creates the cross-session cache-bashing ccage exists to prevent.

`claude-overrides.sh` is user data. `./uninstall.sh` won't touch it.

#### Recipes

**Pin a specific path to a named config dir** (e.g. a long auto-generated worktree basename that you'd rather give a human-friendly config):

```sh
_ccage_config_dir_override() {
    case "$1" in
        /home/me/dev/project-aabbcc)   echo "$HOME/.claude-project"; return 0 ;;
        /home/me/dev/project-aabbcc/*) echo "$HOME/.claude-project-$(basename "$1")"; return 0 ;;
    esac
    return 1
}
```

**Auto-inject a plugin channel on specific worktrees** (the pattern people might otherwise reach for a dedicated tool to get):

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

**Share slash commands, agents, and skills across all projects** (populate once, inherit everywhere):

```sh
# In ~/.bashrc.d/claude-overrides.sh:
export CCAGE_SHARE_FROM="$HOME/.claude-master"
# Optional override — default is "commands agents skills":
# export CCAGE_SHARE_DIRS="commands agents"
```

On first bootstrap of any project's config dir, ccage symlinks `~/.claude-master/commands`, `~/.claude-master/agents`, and `~/.claude-master/skills` into it. Existing entries are left alone; missing master subdirs are silently skipped.

**Never put** `memory/`, `projects/`, `settings.json`, `plugins/`, or `hooks/` in the master dir — these carry per-session state that breaks isolation.

> **Backfilling existing sandboxes.** Sharing only runs at bootstrap, and only when the target subdir doesn't exist. Project sandboxes created before `CCAGE_SHARE_FROM` was set — or ones where a real (even empty) `skills/`, `commands/`, or `agents/` dir was created some other way — will not pick up new master skills. To backfill in one shot:
>
> ```sh
> for d in ~/.claude-*/; do
>     s="${d%/}/skills"
>     [ ! -e "$s" ] && [ ! -L "$s" ] && ln -s "$HOME/.claude/skills" "$s"
> done
> ```
>
> Open Claude Code sessions load skills and slash commands at startup — restart any running session in those projects for the new symlink to take effect.

**Seed a statusline into fresh config dirs** (UI-only — idempotent, doesn't overwrite anything):

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

## Avoiding `-r`/`-c`'s cache rewrite cost

Claude Code's `--resume` / `--continue` reliably cache-misses the message prefix on the first turn after resume — a structural request difference, not TTL expiry (isolated by the 1-hour-TTL controlled experiment in GitHub issue #51764; see also #43657 and #44045; one narrow cause was fixed in Claude Code v2.1.90, the rest remain as of 2.1.13x). On a long Opus session that's $0.50–$2 of cache-write tokens per resume, even seconds after exit — treat ccage's number as a worst-case bound.

> **Separate from the resume bug:** idle gaps longer than the cache TTL also trigger a full rewrite. Claude Code picks the TTL by auth method — Claude subscriptions get the 1-hour tier automatically; API key / Bedrock / Vertex / Foundry default to 5 minutes (opt in to 1 hour with `ENABLE_PROMPT_CACHING_1H=1`, force 5 minutes with `FORCE_PROMPT_CACHING_5M=1`; both upstream Claude Code variables, not ccage's). Subagents always use the 5-minute tier.
>
> For planned absences, ccage ships a `/keepwarm` skill: `/keepwarm [interval] [max]` (defaults 55 min × 6) schedules minimal self-wake turns that re-read the cached prefix before it expires — see `docs/FEATURES.md` for costs and limits.

ccage helps two ways:

### Cost prompt before `-r`/`-c`

When you run `claude -c` or `claude -r <uuid>`, ccage estimates the rewrite cost from the session JSONL and asks before launching:

```
ccage: Continuing most-recent session 4f616b4b · 8h ago · claude-opus-4-7
       Resume will rewrite ~70K tokens. Estimated cost: $1.10–$1.65.
       [r]esume / [h]andoff / [c]ancel?
```

Single keypress, no Enter. Gates: `CCAGE_NO_RESUME_PROMPT=1` to disable; `CCAGE_RESUME_PROMPT_MIN_USD` to raise/lower the threshold (default $0.25); non-tty stdin and `CCAGE_DISABLE=1` also skip the prompt.

### `ccage handoff` — pasteable brief for a fresh session

`ccage handoff` turns a session JSONL into a Markdown brief you can paste as the first message of a fresh `claude` session. Zero API calls — pure shell + jq.

```sh
# Most-recent session for the current project:
ccage handoff

# Specific session (by UUID prefix):
ccage handoff 4f616b4b

# Write to stdout for piping or quick view:
ccage handoff --stdout
```

The brief contains: user prompts (chronological), files Read/Edit/Written, Bash commands run, the last assistant turn, token totals, and a cost estimate. It's written to `~/.local/share/ccage/handoffs/<project>-<session>-<timestamp>.md` and auto-copied to the clipboard if `pbcopy`/`wl-copy`/`xclip`/`xsel` is available.

Requires `jq` (`brew install jq`, `apt install jq`, etc). See `docs/FEATURES.md` for the full reference.

## Per-project MCP opt-in (`ccage enable-mcp`)

ccage keeps MCP registrations **per-project** on purpose — sharing them across cages is the cross-session cache-bashing it exists to prevent. So there's no "global MCP"; agents and skills are the shared part (symlinked from `~/.claude`), and MCP servers are opt-in per project. `ccage enable-mcp` is that opt-in:

```
ccage enable-mcp playwright-test -- npx playwright run-test-mcp-server --headless
```

It writes a project-scoped `.mcp.json` in the current dir (override with `--dir`), which Claude Code reads on startup — approve the server once on first launch. Isolation-safe by construction: it touches **only** `<dir>/.mcp.json`, never a cage's `.claude.json` (no live-session write race) or the `~/.claude` master (no blend into other projects). Idempotent, preserves other servers, `--dry-run` previews. Remove with `ccage disable-mcp <name>`. Full reference: [docs/FEATURES.md](docs/FEATURES.md).

## Shared plugins across cages (`CCAGE_PLUGINS_FROM`)

Plugins normally install **per config dir**, so under ccage you'd reinstall a plugin in every cage. `CCAGE_PLUGINS_FROM` removes that: point it at one folder of plugin directories (each holding `.claude-plugin/plugin.json`) and the wrapper passes a `--plugin-dir` for each on every launch, so Claude session-loads them from that single folder in every cage — present and future.

```
export CCAGE_PLUGINS_FROM="$HOME/.claude/plugins-shared"   # a folder of plugin dirs
```

Install once, available everywhere — the same model as your shared `commands`/`agents`/`skills`. It uses a supported Claude Code launch flag, so nothing is copied into a cage and no cage state is mutated (no dependence on Claude Code's internal plugin store). Opt-in (unset = off); a single plugin dir works too; an unset/missing/empty folder is a no-op that never fails a launch. Loaded plugins are "always on" in every session, so keep the set small and deliberate — though Claude defers tool definitions by default (tool search), so even tool-bringing plugins stay cheap to keep available. Skip it for one launch with `CCAGE_PLUGINS_FROM= claude …`. Full reference: [docs/FEATURES.md](docs/FEATURES.md).

## Session continuity (`/checkpoint` + auto-read)

Long sessions end at `/clear` — and the next one starts cold. ccage ships an optional loop that closes the gap:

- **`/checkpoint` skill** — writes session state into the repo's `RESUME.md` (slot-aware under `CCAGE_SLOT`), rolling older detail into `CHANGELOG.md` to keep it lean. Both files are excluded from git via `.git/info/exclude` — they're personal, not product. `--tidy` also reorganizes the cage's memory dir.
- **Auto-read hook** — a `SessionStart` hook re-injects `RESUME.md` into context on startup, resume, `/clear`, and compaction. The loop becomes `/checkpoint` → `/clear` → state reloaded. No copy, no paste.
- **Budget hook** — a non-blocking `PostToolUse` reminder when a `RESUME` file grows past 3 session blocks.
- **`ccage doctor`** — one-shot sweep across every existing cage: backfills the two hook entries into each `settings.json` (idempotent merge, existing keys preserved) and prints a worklist of bloated `RESUME*.md` files and messy memory dirs. `--dry-run` previews without writing.

`install.sh` deploys the hooks and the skill (skip all of it with `--no-session-docs`). Seeding the hook entries into cages is opt-in via `CCAGE_SESSION_DOCS=1`; per-hook opt-outs are `CCAGE_NO_AUTOLOAD=1` and `CCAGE_NO_BUDGET_HOOK=1`.

> **Caveat:** the auto-read hook injects `RESUME.md` from whatever repo you're in — including one you just cloned. A malicious repo could ship a crafted `RESUME.md` as a prompt-injection vector. Documented in `docs/FEATURES.md`; disable per-cage with `CCAGE_NO_AUTOLOAD=1` if you work in untrusted checkouts.

## Autonomous context management (`ccage-auto`)

`/checkpoint` → `/clear` → reload still needs a human to type `/clear`. For an unattended session that just keeps growing until auto-compact (near 100% of the window — costly, and a long context makes the model duller), `ccage-auto` automates the whole loop:

```sh
ccage-auto            # launch like `claude`, with auto-checkpoint on
ccage-auto --status   # print the resolved transcript + current occupancy, then exit
```

It launches your normal cage session through a pseudo-terminal and runs a tiny in-process watcher that:

- **measures** real context occupancy from the session's transcript JSONL — `input + cache_read + cache_creation` tokens of the latest turn. No LLM, no estimation, no API calls; CPU cost is rounding-error.
- at a **soft threshold** (default 35%) types a one-line nudge so the model itself runs `/checkpoint` at a clean breakpoint and prints a sentinel;
- once the checkpoint is confirmed on disk, types the one thing the model can't do for itself — `/clear` — then a short resume nudge. Your `SessionStart` auto-read hook reloads `RESUME.md`, so work continues from where it left off;
- at a **hard threshold** (default 55%) forces the checkpoint as a backstop if the model blew past the soft nudge in one long turn.

Injection is just writing keystrokes to the pty — no tmux, no API cost. The only model work triggered is the checkpoint + resume you wanted anyway, far cheaper than letting the window balloon. Slot-aware (`CCAGE_SLOT`) and a no-op for slotless cages alike.

| Knob | Flag | Env | Default |
|------|------|-----|---------|
| On/off | `--autock` / `--no-autock` | `CCAGE_AUTOCK=0` | on |
| Soft threshold (%) | `--soft N` | `CCAGE_AUTOCK_SOFT` | 35 |
| Hard threshold (%) | `--hard N` | `CCAGE_AUTOCK_HARD` | 55 |
| Context window — force (tokens) | `--window N` | `CCAGE_AUTOCK_WINDOW` | per-model |
| Context window — per-model map | `--window-map 'opus=1000000,haiku=200000'` | `CCAGE_AUTOCK_WINDOWS` | built-in |
| Poll interval (s) | `--poll N` | `CCAGE_AUTOCK_POLL` | 12 |

Thresholds are validated: an out-of-range value falls back to its default, and `soft ≥ hard` raises `hard` so the backstop always sits above the nudge.

**Per-model context windows.** Windows differ by model, and the transcript doesn't record which one a session has — a 1M and a 200K session log the *same* model id. The window is re-resolved on every measurement (so a mid-session `/model` switch is handled), most specific first: a forced `--window` → the per-model map → a `[1m]` marker in the id → built-in small families (haiku → 200K) → a 1,000,000 default. The one thing the data genuinely can't tell apart — a 200K vs 1M *variant of the same family* — is yours to pin with `--window-map` (or `--window`). Set the default high (1M) so the safe failure is to defer rather than checkpoint too early.

**Unattended launches.** For a truly hands-off session you'll pass `--dangerously-skip-permissions` (otherwise a permission prompt blocks the session and the watcher can't clear it). On a cage that hasn't accepted bypass mode yet, Claude opens on a "Bypass Permissions mode" screen that defaults to *No, exit* — `ccage-auto` auto-accepts it at startup (you already opted in via the flag); opt out with `CCAGE_AUTOCK_NO_BYPASS_ACCEPT=1`. Don't use `-p`/`--print`: headless mode runs one turn and exits, defeating the watcher.

**Standing down when the work is done.** The watcher runs its checkpoint→clear→resume loop indefinitely — it has no way to know the *task* is finished, only that the *context* is full. To let an autonomous run terminate itself, the model runs `/checkpoint --final` when its objective is complete; that writes a `.ccage-session-done` marker and `ccage-auto` stands down on its next poll (stops managing context; the session itself stays up). So for a hands-off run, end your kickoff prompt with an instruction like *"when the objective is fully complete, run `/checkpoint --final`."* Without it the watcher keeps the loop alive until you stop it (Ctrl-C). The marker is cleared automatically at the next session start, so it never carries over.

> **Caveat:** unattended auto-resume types "resume from `RESUME.md`" with no human in the loop, so a crafted `RESUME.md` in a checkout you don't trust is acted on immediately — the same prompt-injection surface as the auto-read hook above, minus the chance to eyeball it. Don't run `ccage-auto` unattended in untrusted repos; `CCAGE_NO_AUTOLOAD=1` disables the reload.

Needs `python3`. Watcher activity is logged to `<cage>/ccage-autock.log`.

## Uninstall

```sh
./uninstall.sh
```

Removes the installed file and strips the installer's source block. Your per-project config dirs under `~/.claude-*` are left alone — they're your data.

## Opt-outs

All off by default. Set any of these before launching `claude`:

| Variable | Effect |
|---|---|
| `CCAGE_DISABLE=1` | Bypass the wrapper for one call. |
| `CCAGE_KEEP_ATTRIBUTION=1` | Don't touch `CLAUDE_CODE_ATTRIBUTION_HEADER`. |
| `CCAGE_KEEP_AUTOUPDATER=1` | Don't touch `DISABLE_AUTOUPDATER`. |
| `CCAGE_NO_AUTO_SIGNORE=1` | Don't create a baseline `.claudesignore`. |
| `CCAGE_NO_ONBOARDING_PATCH=1` | Don't pre-set `hasCompletedOnboarding`. |
| `CCAGE_NO_RESUME_PROMPT=1` | Skip the resume cost prompt for `-r`/`-c`. |
| `CCAGE_RESUME_PROMPT_MIN_USD` | Threshold below which the prompt is skipped (default `0.25`). |
| `CCAGE_SESSION_DOCS=1` | Opt **in**: seed the session-continuity hooks into each cage's `settings.json`. |
| `CCAGE_NO_AUTOLOAD=1` | Don't seed the `RESUME.md` auto-read hook. |
| `CCAGE_NO_BUDGET_HOOK=1` | Don't seed the RESUME-size reminder hook. |
| `CCAGE_ROOT=/some/dir` | Parent directory for isolated configs (default `$HOME`). |
| `CCAGE_PREFIX=.claude-` | Directory name prefix (default `.claude-`). |
| `CCAGE_PLUGINS_FROM=/dir` | Opt **in**: load every plugin dir under `/dir` (or `/dir` itself if it is one) into all cages via `--plugin-dir`. Default unset. |
| `CCAGE_HANDOFF_DIR` | Where `ccage handoff` writes briefs (default `~/.local/share/ccage/handoffs`). |

## FAQ

**Why not just set `CLAUDE_CONFIG_DIR` in a `direnv` `.envrc`?**
You can. ccage is what you want if you don't already have per-project shell tooling and you want one-command setup.

**What about `git worktree`?**
Each worktree is a distinct `$PWD`, so each one gets its own config dir — exactly what you want for parallel sessions on the same repo. Caveat: if you nest worktrees under a common parent with identical basenames (e.g. `repo/.claude/worktrees/main` in two repos, or two branches both named `main` in different locations), the sha1 fallback only triggers *after* the first dir is claimed. If two fresh parallel sessions race on the same basename, they can both claim the unmarked dir simultaneously. Sibling-directory worktrees (`../repo-featureA`, `../repo-featureB`) avoid this.

**Can I run multiple Claude Code sessions in the same directory?**
Yes, with some caveats. Two patterns:

1. **Preferred: use `git worktree`.** `git worktree add ../myproject-review` gives you a sibling dir with a different basename; ccage then isolates it automatically. This is also Anthropic's recommended pattern for parallel-agent work on the same codebase.
2. **`CCAGE_SLOT`.** Set `CCAGE_SLOT=<name>` before invoking `claude` to force a distinct config dir at the same path:
   ```
   CCAGE_SLOT=review  claude     # → ~/.claude-myproject--review
   CCAGE_SLOT=bg      claude     # → ~/.claude-myproject--bg
   ```
   Each slot gets its own credentials and history; you'll need `claude /login` once per slot. Accepted characters: `[A-Za-z0-9_-]+`.

**Does this work on macOS?**
Yes. The wrapper falls back from `sha1sum` to `shasum -a 1` to `openssl dgst -sha1`.

**What about fish, nushell, xonsh?**
Not yet. The function is straightforward to port — open an issue.

**What about Windows / WSL / PowerShell?**
WSL works. Native Windows doesn't; PowerShell support would need a separate port.

## Limitations

- **`claude` is a shell function, so anything that exec's it as an external command bypasses the wrapper.** `timeout 60 claude`, `nohup claude`, `xargs claude`, and similar will find the real binary in `$PATH` and skip ccage's bootstrap (no `CLAUDE_CONFIG_DIR` export, no per-project dir). Inherent to the function-wrapper design. If you need ccage behavior under `timeout` or `nohup`, wrap the call in a subshell: `bash -c 'source ~/.bashrc.d/claude-isolation.sh && claude --print "..."'`.
- ~~**Strict-mode shells (`set -u`).**~~ Fixed: all optional env vars now use `${var:-}` defaults; sourcing under `set -u` no longer crashes. Regression covered by `tests/test_set_u_safety.bats`.
- **Nested-worktree basename collisions** in two parallel fresh sessions — see the worktree FAQ above. Mitigation: prefer sibling-directory worktrees, or set `CCAGE_SLOT` per session.

## Related

- [`ccusage`](https://www.npmjs.com/package/ccusage) — per-dir usage accounting. ccage's `ccusage-all` wraps it.
- Any tool that already reads `~/.claude-*/projects/` — ccage creates the multi-dir world those tools exist to analyze.

## Development

```sh
# Run the full test suite (requires no system dependencies beyond bash):
./tests/bats/bin/bats tests/

# Run a single file:
./tests/bats/bin/bats tests/test_config_dir_for.bats

# Lint all shell files:
shellcheck share/*.sh install.sh uninstall.sh
```

bats-core is vendored at `tests/bats/` as a git submodule pointing at [bats-core/bats-core](https://github.com/bats-core/bats-core). Clone with `--recurse-submodules`, or run `git submodule update --init` after cloning.

## License

MIT — see [LICENSE](LICENSE).
