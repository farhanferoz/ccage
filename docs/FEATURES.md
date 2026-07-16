# ccage — Feature Reference

Exhaustive reference for everything ccage does, every env var it reads, every setting it writes. Keep in sync with `share/claude-isolation.sh`.

Legend: **shipped** = in v0. **planned** = specified but not implemented (see PLAN.md).

---

## Per-project `CLAUDE_CONFIG_DIR` [shipped]

Each `$PWD` resolves to a distinct config dir. Keying rules, in order:

1. If `_ccage_config_dir_override "$PWD"` returns 0 with a non-empty stdout line, that path wins.
2. Else candidate is `$CCAGE_ROOT/$CCAGE_PREFIX<basename $PWD>`.
3. If the candidate exists *and* has a `.owning_path` marker naming a path that isn't the current `$PWD`, append `-<sha1[0:8] of full path>`.
4. If `$CCAGE_SLOT` is set and contains only `[A-Za-z0-9_-]`, append `--<slot>`. Unsafe values are rejected with a stderr warning.

### Opt-outs
- `CCAGE_DISABLE=1` — bypass the wrapper entirely for one call (straight pass-through to the real `claude`).

### Config
- `CCAGE_ROOT` — parent directory for config dirs. Default `$HOME`.
- `CCAGE_PREFIX` — dir name prefix. Default `.claude-`.

### On-disk markers
- `<config-dir>/.owning_path` — plain-text file containing the exact `$PWD` that first claimed the dir. Used for collision detection.

---

## Onboarding-flag patch [shipped]

On first use of a config dir, ccage writes `{"hasCompletedOnboarding": true}` into `<config-dir>/.claude.json` so the user isn't dropped into the login flow when valid credentials exist elsewhere. If the file already exists and is missing the flag, ccage uses `python3` to add it while preserving other keys.

### Opt-out
- `CCAGE_NO_ONBOARDING_PATCH=1` — never touch `.claude.json`.

### Failure modes
- If `python3` is not on PATH and the file exists with other content, the patch is silently skipped. The user sees Claude Code's onboarding flow on first launch; they can proceed through it or set the flag manually.

---

## Baseline `.claudesignore` [shipped]

On any `claude` invocation, if `$PWD/.claudesignore` doesn't exist, ccage writes a baseline list excluding `node_modules`, `.venv`, `venv`, `__pycache__`, `dist`, `build`, common archives and DBs, and tool caches (`.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.cursor`, `.windsurf`). Purpose: keep bulky/generated content out of the Claude Code context window, saving rate-limit budget.

### Opt-out
- `CCAGE_NO_AUTO_SIGNORE=1` — never create the file.

The file is user-editable and ccage will never overwrite an existing one.

---

## Prompt-cache stability via attribution-header suppression [shipped]

Exports `CLAUDE_CODE_ATTRIBUTION_HEADER=0` on every invocation. Suppresses an `x-anthropic-billing-header` whose `cch=<hash>` rotates per request and destabilizes prompt-cache prefixes. Mechanism confirmed as of Claude Code v2.1.104 (April 2026).

References: [musistudio/claude-code-router#1220](https://github.com/musistudio/claude-code-router/pull/1220), [farion1231/cc-switch#2025](https://github.com/farion1231/cc-switch/issues/2025). Does **not** fix the separate `cch=` mutation bug in stored tool_results ([anthropics/claude-code#40652](https://github.com/anthropics/claude-code/issues/40652)); use [claude-code-cache-fix](https://github.com/cnighswonger/claude-code-cache-fix) for that.

### Opt-out
- `CCAGE_KEEP_ATTRIBUTION=1` — don't touch `CLAUDE_CODE_ATTRIBUTION_HEADER`.

---

## Autoupdater disabled [shipped]

Exports `DISABLE_AUTOUPDATER=1` on every invocation. Prevents parallel sessions from racing on a self-update and corrupting the install. Users are expected to update manually: `npm i -g @anthropic-ai/claude-code`.

### Opt-out
- `CCAGE_KEEP_AUTOUPDATER=1` — don't touch `DISABLE_AUTOUPDATER`.

---

## Extension hooks [shipped]

Two stub functions defined in `claude-isolation.sh`; any file loaded after it (e.g. `~/.bashrc.d/claude-overrides.sh`) can redefine them.

### `_ccage_config_dir_override <pwd>` → int + stdout

- Return 0 with stdout containing an absolute path to pin that path to a specific config dir.
- Return non-zero (default stub) to fall through to basename keying.
- Runs before collision detection and the slot suffix — overrides always win.

**After redefining this function, set `_CCAGE_OVERRIDE_ACTIVE=1`.** Without the flag, ccage skips the hook entirely (saves a subshell fork on every `claude` invocation when no override is installed). The default stub file sets `_CCAGE_OVERRIDE_ACTIVE=0`; your overrides file should flip it to `1` after the function definition. The shipped `claude-overrides.sh.example` does this — copy that template rather than writing from scratch.

### `_ccage_pre_exec_hook <pwd> <config-dir>`

- Runs after config-dir bootstrap, immediately before `command claude`.
- May export environment variables.
- May append CLI flags to the `_ccage_extra_args` array (declared fresh by the wrapper each call).
- May seed **UI-only** keys into `<config-dir>/settings.json` (e.g. `statusLine`, `theme`). See "UI-only seeding" below.

### UI-only seeding discipline

When seeding into a per-project `settings.json`, seed only display keys. Never seed `permissions`, `plugins`, `mcpServers`, `hooks`, or any state-bearing key from a shared master — that re-creates the cross-session cache-bashing ccage exists to prevent.

Idempotency is the contract: hooks must only add missing keys, never overwrite existing values.

---

## Resume cost interception (`-r` / `-c`) [shipped]

The `claude()` shell function intercepts resume invocations to surface the cache-rewrite cost before launch. Motivation: Claude Code's `--resume` / `--continue` reliably cache-miss the message prefix even inside the TTL window (structural diff at `messages[0]` — isolated by the 1-hour-TTL controlled experiment in GitHub #51764; see also #43657, #44045; one narrow cause fixed in Claude Code v2.1.90). On long sessions this is real money ($0.50–$2/resume on Opus).

### Detection

| Args | Behavior |
|---|---|
| `-c`, `--continue` | Intercept. Use most-recent session JSONL by mtime. |
| `-r <uuid-prefix>`, `--resume <uuid-prefix>` | Intercept. Look up the specific session by UUID prefix. |
| Bare `-r` / `--resume` (no id, or next arg is another flag) | **Pass through.** Claude Code's own session picker may run; we can't predict the user's choice. |
| Any other invocation | Pass through silently. |

### Prompt UX

```
ccage: Continuing most-recent session 4f616b4b · 8h ago · claude-opus-4-7
       Resume will rewrite ~70K tokens (message prefix). Estimated cost: $1.10–$1.65.
       (Resume cache misses are structural, not TTL — see GitHub #51764, #43657. Worst-case estimate.)
       [r]esume / [h]andoff / [c]ancel?
```

Single keypress, no Enter needed. Reads from `/dev/tty` so it works even when stdin is piped.

### Branch actions

- `r` / `R` / Enter → resume normally (claude proceeds).
- `h` / `H` → invokes `ccage handoff <session-prefix>` and cancels the resume.
- Any other key → cancel.

### Cost estimation

Reads the session JSONL's per-turn `message.usage.cache_read_input_tokens`, takes the max value across substantive turns (>1000 tokens), subtracts an estimated 19,000-token tools+system prefix that survives resume at the account level, applies the model's cache-write rate, and reports a ±25% range:

```
rewrite_estimate = max(cache_read_input_tokens across substantive turns) - 19000
cost_lo = rewrite_estimate * 0.75 * cache_write_rate / 1e6
cost_hi = rewrite_estimate * 1.25 * cache_write_rate / 1e6
```

±25% reflects empirical drift between predicted and actual rewrite size (sample-based, two JSONLs at 2-min and 3-hour gaps).

### Env vars

| Var | Default | Effect |
|---|---|---|
| `CCAGE_NO_RESUME_PROMPT` | unset | If set to any non-empty value, skips the interceptor entirely. Pure pass-through. |
| `CCAGE_RESUME_PROMPT_MIN_USD` | `0.25` | Skip the prompt when the high-end estimate is below this dollar amount. Default $0.25 ≈ noisy enough to be worth showing on Opus, quiet enough to avoid prompt-fatigue on small sessions. |
| `CCAGE_DISABLE` | unset | Pre-existing global opt-out — the wrapper's outer `CCAGE_DISABLE` branch short-circuits before reaching the interceptor. |

### Gates that pass through silently (no prompt)

- `CCAGE_DISABLE=1` (already documented above)
- `CCAGE_NO_RESUME_PROMPT=1`
- Stdin is not a tty (`[ ! -t 0 ]`) — common in scripted/piped contexts.
- Estimated cost below `CCAGE_RESUME_PROMPT_MIN_USD`.
- No session JSONL found for the current project (claude itself will error appropriately).
- Bare `-r` / `--resume` with no UUID-shaped following arg.

### Pricing table

Hardcoded in `share/claude-isolation.sh`. Refresh the `# updated:` header and bump CHANGELOG on rate changes:

| Model | Cache-write $/MTok (200K tier) |
|---|---:|
| claude-opus-4-7, claude-opus-4-6 | 18.75 |
| claude-sonnet-4-6, claude-sonnet-4-5 | 3.75 |
| claude-haiku-4-5 | 1.00 |
| (unknown) | 18.75 (conservative upper bound) |

---

## `ccage handoff` — offline session brief [shipped]

Generates a Markdown handoff brief from a Claude Code session JSONL. **Zero API calls** — pure shell + jq. Use case: avoid `claude -r`/`-c`'s structural prompt-cache rewrite tax (Claude Code resumes reliably cache-miss the message prefix — see GitHub issues #51764, #43657). Generate a brief from the prior session, start a fresh `claude`, paste the brief as the first message.

### Usage

```
ccage handoff                          # most-recent session for $PWD
ccage handoff <session-id-prefix>      # specific session (UUID, prefix-match)
ccage handoff --stdout                 # write to stdout instead of file
ccage handoff --output FILE            # explicit output path
ccage handoff --project /abs/path      # use that path's slug, not $PWD's
ccage handoff --max-prompts N          # cap user-prompt list (default 20)
```

### What's in the brief

- Session metadata (id, started/last-activity, turn counts, last model used).
- Tokens billed so far (input · output · cache-write · cache-read) and an estimated cost in dollars based on the pricing table in `share/ccage-handoff.sh`.
- User prompts (verbatim, chronological, last N up to `--max-prompts`).
- Files touched, aggregated from Read/Edit/Write tool_use records — top 30 by frequency.
- Bash commands, deduplicated and with trivials (`pwd`, `ls`, `true`, `clear`, `exit`, `cd`) filtered out.
- The last assistant text turn (truncated to first/last 300 words if longer than 600).

### Output path

`${CCAGE_HANDOFF_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ccage/handoffs}/<project-slug>-<session-prefix>-<timestamp>.md`

Filename embeds the project slug so cross-project listing is easy.

### Clipboard auto-copy

In default file mode, if one of `pbcopy` (macOS), `wl-copy` (Wayland), `xclip`, or `xsel` is available, the brief is also copied to the clipboard. Skipped silently if none found. Suppressed in `--stdout` and `--output` modes.

### Filtering rules

User-prompt extraction excludes:
- Records where `toolUseResult != null` (tool result echoes, not prompts).
- Records where `isMeta == true` (synthetic system reminders).
- Records with empty/whitespace-only content.

Resilient to malformed JSONL lines — every jq invocation uses raw-input + `fromjson?` so a partial-write line in the middle of a session file doesn't kill the rest of the extraction.

### Env vars

- `CCAGE_HANDOFF_DIR` — override the default output directory.
- `CCAGE_LIB` — override library lookup path (used by `bin/ccage`). Default: auto-detected from `bin/ccage`'s location.

### Dependencies

- `jq` (any version with `fromjson?` support — jq 1.5+).
- Standard coreutils: `awk`, `sed`, `sort`, `mktemp`, `date`.
- `python3` is NOT required for this feature.

---

## `ccage enable-mcp` — per-project MCP opt-in [shipped]

ccage gives every project its own `CLAUDE_CONFIG_DIR`, and MCP registrations live in that cage's `.claude.json`. They are **deliberately not shared** across cages — sharing them re-creates the cross-session cache-bashing ccage exists to prevent (see [UI-only seeding discipline](#ui-only-seeding-discipline): never seed `mcpServers` from a shared master). So there is no "global MCP", on purpose.

That leaves a recurring question: *"I shipped an agent/tool that needs an MCP server — why isn't it picked up in this cage?"* The answer splits in two:

- **Agents and skills ARE shared.** Each cage symlinks `agents/`, `skills/`, `commands/` from the master (`CCAGE_SHARE_FROM`, default `~/.claude`). Drop an agent `.md` in `~/.claude/agents/` and it appears in every cage.
- **MCP servers stay opt-in per project.** `ccage enable-mcp` is that opt-in: it writes a project-scoped `.mcp.json` in the project's launch dir, which Claude Code reads on startup (prompting once to approve the server).

### Usage

```
ccage enable-mcp <name> [--dir DIR] [--dry-run] -- <command> [args...]
ccage disable-mcp <name> [--dir DIR] [--dry-run]
```

```
# enable a Playwright test-runner MCP for the current project
ccage enable-mcp playwright-test -- npx playwright run-test-mcp-server --headless
```

### Why it can't break isolation

The command writes **only** `DIR/.mcp.json` (default `$PWD`):

- It never touches a cage's `.claude.json`, so it can't lose the live-session `.claude.json` write race against a running session.
- It never touches the `~/.claude` master, so the server can't blend into other projects.
- A project `.mcp.json` is scoped to that one directory; another project elsewhere has its own (or none).

It is idempotent (re-enabling an identical entry is a no-op; a changed command updates in place), and `--dry-run` previews without writing. The merge is conservative: it preserves any other servers and unrelated top-level keys, and re-enabling an existing server rewrites only its `command`/`args` — any other keys you added to that entry (e.g. `env`) survive. `disable-mcp` removes the server and deletes the file if that leaves it empty.

### Scope

Registers **stdio** servers only (`command` + `args`). Remote MCP servers (`"type": "http"` / `"sse"` with a `url`) can't be expressed through this command — add those by editing `.mcp.json` directly; `disable-mcp <name>` still removes them.

### Dependencies

- `python3` (atomic JSON merge + write). No `jq` needed at runtime.

---

## Shared plugins across cages (`CCAGE_PLUGINS_FROM`) [shipped]

Claude Code stores installed plugins under the active `CLAUDE_CONFIG_DIR`, so each cage has its own plugin store — install a plugin in one cage and it is absent in the others. ccage symlink-shares `commands`/`agents`/`skills` from the master but **not** plugins (their store carries mutable per-session state; see [UI-only seeding discipline](#ui-only-seeding-discipline)). `CCAGE_PLUGINS_FROM` closes that gap without sharing the store.

### How it works

Point `CCAGE_PLUGINS_FROM` at a folder of plugin directories. On every launch the wrapper appends a `--plugin-dir <dir>` for each one, and Claude Code **session-loads** the plugin straight from that directory — no install into the cage's plugin store.

```
export CCAGE_PLUGINS_FROM="$HOME/.claude/plugins-shared"
# plugins-shared/
#   my-plugin/.claude-plugin/plugin.json    ← each immediate child that is a plugin
#   another/.claude-plugin/plugin.json
```

`CCAGE_PLUGINS_FROM` may also be a single plugin dir (one holding `.claude-plugin/plugin.json` directly). Unset / missing / empty is a clean no-op that never fails a launch. Populate the folder once (clone or unpack plugins) and every cage — current and future — loads them.

### Why it doesn't break isolation (or depend on Claude internals)

- It uses `--plugin-dir`, a **supported Claude Code launch flag**, not a reach into the plugin store. Nothing is copied into a cage and no cage state is mutated, so there is no dependence on Claude Code's internal store layout (which can change between versions).
- Plugins load fresh from the shared folder each session, so activity in one cage cannot mutate what another sees.
- The only trust interaction is the standard once-per-workspace folder-trust dialog Claude already shows; `--plugin-dir` adds no separate per-plugin prompt.

### Cost — keep the set deliberate

A loaded plugin is "always on" in every session, so its commands/skills/tools are available everywhere. That standing cost is small: Claude loads only a one-line description per command/skill (the body loads on use), and **tool definitions are deferred by default** (MCP tool search, `ENABLE_TOOL_SEARCH=auto`), so even a plugin that bundles a tool server adds only its name upfront and its schema on demand. Still, prefer a small, curated set — the plugins you genuinely want everywhere. Skip them for one launch with `CCAGE_PLUGINS_FROM= claude …`, or globally by leaving the variable unset.

### Plugins vs. the rest

| What | How it reaches a cage | Shared? |
|---|---|---|
| commands / agents / skills | symlinked from the master (`CCAGE_SHARE_FROM`) | yes, by default |
| MCP servers | `ccage enable-mcp` → project `.mcp.json` | opt-in per project |
| plugins | `--plugin-dir` at launch (`CCAGE_PLUGINS_FROM`) | opt-in, all cages |

### Requirements

- Claude Code with `--plugin-dir` support (Claude Code 2.x; verified on 2.1.170).

---

## Resume cost interception [shipped — Phase 6b]

When you invoke `claude -c` (continue) or `claude -r <session-id>` (resume), the wrapper computes the cache-rewrite cost from the session's on-disk `usage` history and prompts before launch. Background: Claude Code's resume reliably misses the message-prefix cache even inside the TTL window (GitHub anthropics/claude-code #51764 — a 1-hour-TTL controlled experiment isolating the resume event; see also #43657, #44045 — `processSessionStartHooks` and `reorderAttachmentsForAPI` shuffle bytes at `messages[0]`; one narrow cause fixed in Claude Code v2.1.90). Each cold resume pays the cache-write rate (1.25× input on the 5-minute tier, 2× on the 1-hour tier) on the rewritten prefix; on a long Opus session that's $0.50–$2+ per resume. Treat the estimate as a worst-case bound.

### When the prompt fires

| Args | Action |
|---|---|
| `-c`, `--continue` | Intercept, use most-recent session by mtime |
| `-r <uuid-prefix>`, `--resume <uuid-prefix>` | Intercept, use the named session |
| Bare `-r` / bare `--resume` (no id) | Pass through (Claude Code may show its own picker — we can't predict the choice) |
| Anything else | Pass through |

### Gates that suppress the prompt

| Condition | Effect |
|---|---|
| `CCAGE_DISABLE=1` | Wrapper bypassed entirely |
| `CCAGE_NO_RESUME_PROMPT=1` | Interception skipped |
| Stdin is not a tty (`[ ! -t 0 ]`) | Skipped (no way to prompt) |
| No session JSONL found for current `$PWD` | Skipped (Claude Code will report the error itself) |
| Estimated rewrite cost below `CCAGE_RESUME_PROMPT_MIN_USD` (default `0.25`) | Skipped |

### What the prompt shows

```
ccage: Continuing most-recent session 4f616b4b · 4h 12m ago · claude-opus-4-7
       Resume will rewrite ~70K tokens (message prefix). Estimated cost: $1.10–$1.65.
       (Resume cache misses are structural, not TTL — see GitHub #51764, #43657. Worst-case estimate.)
       [r]esume / [h]andoff / [c]ancel?
```

Cost is a range (±25% empirical uncertainty band), computed as `peak_cache_read − ~19K tools+system prefix`, times the model's cache-write rate from the inline pricing table. The table uses the 5-minute-tier write rate (1.25× input); on the 1-hour tier (the default for Claude-subscription auth) writes cost 2×, so true worst-case is ~1.6× the shown range. For subscription auth the dollar figure is notional — usage is plan-included — but still tracks quota weight.

### Cache lifetime (upstream Claude Code variables — ccage does not set these)

Claude Code picks the prompt-cache TTL by auth method: **Claude subscriptions get the 1-hour tier automatically**; API key / Bedrock / Vertex / Foundry default to 5 minutes. `ENABLE_PROMPT_CACHING_1H=1` opts into 1 hour (Claude Code ≥ 2.1.108; the older `ENABLE_PROMPT_CACHING_1H_BEDROCK` is deprecated but honored); `FORCE_PROMPT_CACHING_5M=1` forces 5 minutes. Subagents always use the 5-minute tier. Which tier a request actually got is recorded in the session JSONL under `message.usage.cache_creation` (`ephemeral_1h_input_tokens` / `ephemeral_5m_input_tokens`).

### Decisions

- `r` / `R` / Enter → resume as normal.
- `h` / `H` → exec `ccage handoff` against the same session, then cancel the resume so the user can paste the brief into a fresh `claude`.
- Any other key → cancel.

### Env

| Var | Default | Effect |
|---|---|---|
| `CCAGE_NO_RESUME_PROMPT` | unset | If `1`, never prompt — always pass through. |
| `CCAGE_RESUME_PROMPT_MIN_USD` | `0.25` | Skip prompt when estimated cost falls below this dollar threshold. |

### Limitations

- Cost is an estimate. The ±25% band reflects empirical precision from sampled JSONLs; rare sessions may fall outside.
- 1M-context-tier sessions use a different rate that this table doesn't track — estimates can be ~2× low on those.
- Pricing data is hardcoded inline in `share/claude-isolation.sh` (mirrored in `share/ccage-handoff.sh`). The `# updated:` header notes the last refresh date.
- If Anthropic ever fixes the structural resume cache miss, the prompt becomes noise — silence it with `CCAGE_NO_RESUME_PROMPT=1`. A future `ccage doctor` check is planned to auto-detect and hint at this.

---

## `ccage handoff` [shipped — Phase 6a]

Standalone CLI that produces a Markdown handoff brief from a Claude Code session JSONL. Designed for the workflow "I want to start a fresh `claude` session instead of paying `claude -r`'s structural cache-rewrite tax."

**Zero API calls.** Pure jq + shell. Reads only on-disk session history.

### Usage

```sh
ccage handoff                                # most-recent session for $PWD
ccage handoff <session-id-prefix>            # specific session by UUID prefix
ccage handoff --stdout                       # brief to stdout (no file)
ccage handoff --output PATH                  # explicit output path
ccage handoff --project /abs/path            # other project's sessions
ccage handoff --max-prompts N                # cap user-prompt list (default 20)
```

### What's in the brief

- Session metadata: id, project, start/last-activity timestamps, turn counts.
- **Tokens billed so far** (input / output / cache-write / cache-read), summed from per-turn `message.usage` fields.
- **Estimated cost so far** in dollars (using the model recorded on the last assistant turn against a hardcoded pricing table).
- **User prompts** verbatim, chronological, last N (default 20). Earlier prompts get an elided-count marker.
- **Files touched** table from `tool_use` records (Read / Edit / Write), top 30 by frequency.
- **Commands run**, deduplicated, with trivial commands (`pwd`, `ls`, `cd`, `clear`, `exit`, `true`) filtered out. Cap 40 unique.
- **Last assistant turn** verbatim, with first-300/last-300-word truncation if longer than 600 words.

### Where the file lands

Default location: `${CCAGE_HANDOFF_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ccage/handoffs}/<project-slug>-<session-prefix>-<YYYYMMDD-HHMMSS>.md`.

After write, prints the path to stdout, hints the next step on stderr, and copies to clipboard if available. Clipboard detection order: `pbcopy` → `wl-copy` → `xclip` → `xsel`. Silent skip if none.

### Env

| Var | Default | Effect |
|---|---|---|
| `CCAGE_HANDOFF_DIR` | `~/.local/share/ccage/handoffs/` | Override the handoff output directory. |

### Limitations

- Best-effort JSONL parsing. If Anthropic changes session field names, extraction will degrade loudly (jq returns nulls; missing fields show as 0). Test fixtures pin the current schema.
- Cost estimate uses a hardcoded pricing table (200K tier). 1M-context-tier sessions are under-estimated by ~2×. The pricing file (`share/ccage-handoff.sh`) has a `# updated:` header for tracking rate refreshes.
- The handoff brief is structural (facts, no synthesis). For LLM-quality narrative summaries, use the in-session `/session-handoff` skill while the session is still warm.

### Dependencies

`jq` (any 1.6+). `install.sh` checks for it.

---

## Session continuity — `/checkpoint`, auto-read, `ccage doctor` [shipped — Phase 7]

Closes the loop between the structural `ccage handoff` brief and a repo's durable `RESUME.md`. The old continuity loop was four fumble-prone steps (run the handoff skill → select → copy → `/clear` → paste). The new loop is two commands with zero copy/paste: **`/checkpoint` → `/clear`** (state auto-loads on the next request). Everything here is inert until a cage opts in with `CCAGE_SESSION_DOCS=1`, and every piece is reversible.

### `/checkpoint` skill

`share/skills/checkpoint/SKILL.md` (+ deterministic `checkpoint-init.sh`). Writes the session state **into `RESUME.md`** (slot-aware: `RESUME.<slot>.md` when `CCAGE_SLOT` is set), merging it with any threads carried in, and rolls older detail down into `CHANGELOG.md` so `RESUME.md` stays lean. `/checkpoint --tidy` additionally runs memory hygiene (regroup `MEMORY.md`, prune dead index links / orphan notes). `checkpoint-init.sh` is idempotent and adds `RESUME.md` / `CHANGELOG.md` to `.git/info/exclude` so continuity files never get committed.

### Auto-read hook (SessionStart)

`share/hooks/resume_autoload.sh`, registered on `SessionStart` for `startup|resume|clear|compact`. A SessionStart hook's stdout is injected into the model's context, so after `/clear` the prior `RESUME.md` is reloaded automatically — that is the whole point of the `clear` source. The hook is slot-aware (mirrors the wrapper's `CCAGE_SLOT` validation), always exits 0, and emits at most two one-line health NOTEs: *RESUME over budget → run `/checkpoint`* and *memory dir messy → run `/checkpoint --tidy`*.

> Auto-read, **not** auto-clear. `/clear` stays a deliberate user action (consistent with the PHASE-6 non-goal). The hook only re-injects state; it never clears for you.

> **Trust note.** `RESUME.md` is normally a *personal, locally-authored* file (it's added to `.git/info/exclude`, so it never travels with the repo). But if you clone a repo that ships a `RESUME.md`, the auto-read hook will inject that attacker-authored text into your session context at every `SessionStart` — a prompt-injection surface. This is no worse than Claude Code already reading repo files, but it happens automatically; treat an inherited `RESUME.md` as untrusted repo content.

### Budget guard hook (PostToolUse)

`share/hooks/resume_budget_check.sh`, registered on `PostToolUse(Write|Edit)`. When a `RESUME.md` / `RESUME.<slot>.md` grows past `MAX` (3) `## Session` blocks it surfaces a non-blocking reminder to archive old blocks into `CHANGELOG`. Silent + exit 0 in every other case. Needs `jq`.

### Per-cage seeding (merge, never share)

`_ccage_seed_session_docs_hooks` in `share/claude-isolation.sh` merges the two hook entries into the cage's own `settings.json` on bootstrap when `CCAGE_SESSION_DOCS=1`. It is a **merge** — every pre-existing key (`statusLine`, `theme`, `plugins`, `effortLevel`, …) is preserved; only a missing `SessionStart`/`PostToolUse` entry is added. `settings.json` is never symlink-shared between cages (consistent with the UI-only-seeding discipline). A grep fast-path skips the python merge once a cage is already seeded.

### `ccage doctor` — one-shot cross-cage sweep

`share/ccage-doctor.sh` (dispatched by `bin/ccage doctor`). For every cage under `${CCAGE_ROOT:-$HOME}/${CCAGE_PREFIX:-.claude-}*` that carries a `.owning_path`:

1. **Backfill** the session-docs hooks block into its `settings.json` (the same safe, idempotent merge), resurrecting the budget hook and wiring the auto-read hook into cages created before Phase 7.
2. **Report** a worklist: owning repos with a bloated `RESUME*.md` (slot-aware glob — every `RESUME.md` and `RESUME.<slot>.md` is checked) to trim with `/checkpoint`, and every `projects/*/memory` dir that looks unorganized to clean with `/checkpoint --tidy`.

`--dry-run` previews both without writing. Zero API calls (shell + `python3` for the JSON merge). Run it once after upgrading to retrofit existing cages.

### Opt-outs

- `CCAGE_SESSION_DOCS` unset → none of the above is seeded (full opt-out; the default).
- `CCAGE_NO_AUTOLOAD=1` → seed only the budget hook, not the auto-read hook.
- `CCAGE_NO_BUDGET_HOOK=1` → seed only the auto-read hook, not the budget guard.
- `install.sh --no-session-docs` → don't install the hooks, the `/checkpoint` skill, or the `~/.claude/CLAUDE.md` anchor at all.
- `uninstall.sh` removes all session-docs assets and strips the marker-delimited `CLAUDE.md` anchor (never touching a repo's `RESUME.md`/`CHANGELOG.md` or a cage's seeded `settings.json`).

### Config

| Var | Default | Effect |
|---|---|---|
| `CCAGE_SESSION_DOCS` | unset | Master opt-in. Seed the hooks block into a cage's `settings.json` on bootstrap. |
| `CCAGE_NO_AUTOLOAD` | unset | Skip seeding the SessionStart auto-read hook. |
| `CCAGE_NO_BUDGET_HOOK` | unset | Skip seeding the PostToolUse budget hook. |
| `CCAGE_RESUME_BUDGET_LINES` | `250` | Line budget before the auto-read hook / doctor flag a bloated RESUME. |
| `CCAGE_RESUME_BUDGET_BYTES` | `14000` | Byte budget (alongside the line/block budgets) — a dense file can bloat well under the line cap. |
| `CCAGE_MEMORY_ORPHAN_MAX` | `3` | Un-indexed memory files tolerated before flagging the dir as messy. |
| `CCAGE_HOOKS_DIR` | `~/.claude/hooks` | Where the hook scripts are installed and referenced from. |

### Dependencies

`python3` (for the settings.json merge in seeding + `ccage doctor`) and `jq` (for the budget hook). `install.sh` requires `jq` whenever the CLI **or** the session-docs assets are installed.

---

## Seeding the user's own local hooks (`CCAGE_SEED_LOCAL_HOOKS`) [shipped]

A hook script under `~/.claude/hooks` is inert until some `settings.json` registers it, and every cage has its own — so a policy hook the user maintains globally (an orchestration gate, a write-set guard, …) reached a cage only if someone hand-edited that cage's `settings.json`. `_ccage_seed_local_hooks` in `share/claude-isolation.sh` closes that gap: on every bootstrap it reads the user's real `~/.claude/settings.json` and merges into the cage's `settings.json` **every hook that registers a script under `~/.claude/hooks`**, judged one hook at a time — a matcher group carrying N hooks is split into N single-hook entries on the way in, so hook #2+ in a group is never invisible to the seeder the way it would be if the group were judged by its first hook alone.

Ownership line: **ccage owns cage wiring, the policy content is the user's.** Registrations are copied from the user's own `settings.json` — no hook name is hardcoded, the same principle as `CCAGE_SHARE_DIRS` sharing `commands`/`agents`/`skills` without owning their content. ccage's own hooks (`resume_autoload.sh`, `resume_budget_check.sh`, `autonomous_ask_guard.sh`) are always skipped — `_ccage_seed_session_docs_hooks` seeds those and they have their own opt-outs (`CCAGE_NO_AUTOLOAD`, `CCAGE_NO_BUDGET_HOOK`); copying them here would silently override a deliberate opt-out. Anything not under the hooks dir (an inline `curl` notification integration, say) is left alone — not ccage's to spread.

Idempotent (dedups on script basename), preserves every unrelated key and every pre-existing hook, tilde-form (`bash ~/.claude/hooks/x.sh`) and absolute-form registrations are treated as the same hook, atomic write (`mkstemp` + `os.replace`, mode preserved), and never clobbers a present-but-unparseable `settings.json`.

### Opt-in
- `CCAGE_SEED_LOCAL_HOOKS=1` — off by default, mirroring `CCAGE_SESSION_DOCS`: it changes hook behavior in every cage, so it stays opt-in.

### Config

| Var | Default | Effect |
|---|---|---|
| `CCAGE_SEED_LOCAL_HOOKS` | unset | Master opt-in. Seed the user's local policy hooks into a cage's `settings.json` on bootstrap. |
| `CCAGE_LOCAL_HOOKS_SRC` | `~/.claude/settings.json` | Source settings file to read hook registrations from. |
| `CCAGE_HOOKS_DIR` | `~/.claude/hooks` | Which dir counts as "the user's hooks" (shared with the session-docs seeder above). |

Full design rationale, the two bugs found while building it (tilde-form registrations silently skipped; only the first hook in a matcher group seeded), and the field evidence for why "derive the list, never hardcode it" is load-bearing: [`docs/SEED-LOCAL-HOOKS.md`](SEED-LOCAL-HOOKS.md).

---

## Autonomous `AskUserQuestion` guard [in ccage-auto]

A watched `ccage-auto` launch exports `CCAGE_AUTONOMOUS=1` into the launched session and registers a per-run `PreToolUse` hook (`share/hooks/autonomous_ask_guard.sh`) via a generated `--settings` file passed as `claude --settings <file>` — nothing is ever seeded into a cage's own `settings.json` for this; the registration lives and dies with the run. While the marker is set, the hook blocks (exit 2) any `AskUserQuestion` call and feeds guidance back to the model over stderr: check the ratified plan/design doc first, otherwise take the reversible default and log it in `RESUME.md` under `### Decisions`, and batch genuinely user-only questions for the end of the run — halt mid-run only for irreversible/destructive/outward-facing actions.

**Documented limitation: the guard arms for the WHOLE session, off a single env var, with no user-presence signal.** `CCAGE_AUTONOMOUS=1` is set once at launch and stays set for the life of the process, so if the user comes back and starts typing mid-run, the guard still blocks `AskUserQuestion` exactly as it would for a genuinely unattended run — it has no mechanism to distinguish "the user stepped away" from "the user is right here." The guard's own message accounts for this by telling the model that if the user appears to be present (recent genuine user turns in the conversation, not just tool output), it should ask them in prose instead of calling the blocked tool. There is deliberately no presence-detection logic in the guard itself — its value is staying trivially correct (one flag check, one fixed message), not inferring attendance.

### Opt-out
- `CCAGE_AUTOCK_NO_ASK_GUARD=1` — skip registering the guard for one `ccage-auto` run. The run is still marked `CCAGE_AUTONOMOUS=1`; only the hook registration is skipped. A missing hook script degrades to a warning, never a failed launch.

---

## `/keepwarm` — bounded cache keep-warm loop [shipped — Phase 8]

Skill at `share/skills/keepwarm/` (installed to the master skills dir; reaches every
cage via the skills symlink, like `/checkpoint`). Invoke before stepping away:

```
/keepwarm                   # ping every 55 min, max 6 pings (defaults)
/keepwarm <interval> <max>  # custom; interval clamped [1,59] min, max [1,24]
```

The session schedules itself a minimal wake turn each interval; the wake re-reads the
cached conversation prefix (a ~0.1× cache read) and resets the cache TTL clock. The
arming announcement always states interval, cap, per-ping cost, projected auto-stop
time, and that "stop" cancels — defaults are never silent.

**Activity handling is best-effort.** While you're active, the loop tries to re-anchor
each pending ping past your turn so it never fires — but that re-anchoring is
model-driven (not a hook), so once you're deep in other work a pending ping can still
fire at its original time. When it does, it's treated as a free counter-reset: it does
**not** consume the cap, but it **still costs one cache read** — being active lowers a
slipped ping to a single cheap read, it does not make it zero. The cap bounds
consecutive *unattended* pings.

Before arming, the bundled `keepwarm-calc.sh probe` (jq-only, zero API calls) reads
the newest session JSONL and warns when: the session is on the **5-minute tier** with
an interval > 4 (cache would die before the first ping — fix with interval 4 or
`ENABLE_PROMPT_CACHING_1H=1`), or the prefix is small enough (< ~20K tokens) that a
rewrite costs pennies.

**Economics.** Ping ≈ 0.1× of the prefix; an expired return ≈ 2× (1h-tier write).
Break-even ≈ 20 pings; the default cap of 6 bounds worst-case waste at ≈ 30% of one
rewrite while covering ~5.5 h. On subscription plans a ping can also **open a fresh
5-hour usage window** while you're away — armed long absences trade cache warmth for
window time.

**Limits.** Only helps when returning to the *same live session* — a warm cache never
survives `claude -r` (structural miss, GitHub #51764; use `/checkpoint` or
`ccage handoff` before exiting instead). The schedule dies with the session. Requires
a Claude Code build with self-scheduling wake-ups (the mechanism behind the bundled
`/loop`). Skip installing with `./install.sh --no-keepwarm`.

---

## Subagent circuit breaker [in ccage-auto; observe-mode]

A second daemon thread inside `ccage-auto` (`SubagentWatcher`) that watches every
teammate transcript for a *runaway* subagent — one running far past its expected
budget with a quiet transcript, or churning past the hard ceiling — and climbs a
reversible ladder: **alert → nudge → stop → kill**. All decision logic lives in the
unit-tested `lib/subagent_watch.py`; the thread owns only the poll loop and the two
side effects (inject a message into the orchestrator's pty; SIGTERM the session as a
last resort when the orchestrator itself is wedged). The orchestrator talks back
with `CCB-VOUCH agent=<id> extend=<min>` (extend a legitimately long teammate) and
`CCB-STOPPED agent=<id>` (confirm a stop). Every decision is appended to a durable
JSONL ledger that `bin/ccb-report` turns into a false-positive/true-positive +
threshold-tuning report.

**Full reference:** [`docs/CIRCUIT-BREAKER.md`](CIRCUIT-BREAKER.md) — the ladder,
config table, marker grammar, ledger schema, scope limits, and the rollout/enable
procedure.

- **Inert unless the lib is deployed.** `ccage-auto`'s `_load_ccb()` looks for
  `lib/` beside the binary (repo layout, or `share/ccage/lib` when installed); if
  it isn't there the watcher is never constructed and core auto-checkpointing is
  untouched.
- **Teams sessions only, `observe` by default.** Non-teams sessions are forced to
  alert-only (they lack the completion signal the higher tiers need). Config is all
  `CCB_*` env vars (see the reference); `CCB_NOTIFY_CMD` reuses the same Telegram
  hook wiring as the context watcher (user config, machine-specific — not in the
  repo).

---

## `ccusage-all` [shipped]

Function defined in `share/claude-ccusage.sh`. Iterates every `$CCAGE_ROOT/$CCAGE_PREFIX*` directory with a `projects/` subdir, exports `CLAUDE_CONFIG_DIR`, and runs `npx -y ccusage "$@"` against each.

### Prerequisites
- `npx` (from Node.js) — on PATH.
- Network access for `npx` to fetch `ccusage` on first use.

---

## `CCAGE_SLOT` [shipped]

Suffix on the config-dir name, for running multiple independent sessions in the same `$PWD` (e.g. one interactive, one background review agent).

- Accepted characters: `[A-Za-z0-9_-]+`. Anything else prints a warning to stderr and the variable is ignored (slot is dropped; normal path is used).
- Separator is `--` (double-dash) to be visually distinct from the collision-disambiguation separator (`-`).
- Slot suffix is applied **after** collision resolution, so a colliding path with a slot gets `<base>-<sha8>--<slot>`.
- Takes no effect when `_ccage_config_dir_override` returns a path — overrides always win.

Example:
```
cd ~/dev/myproject
CCAGE_SLOT=review  claude    # → ~/.claude-myproject--review
CCAGE_SLOT=bg      claude    # → ~/.claude-myproject--bg
```

Each slot gets its own config dir and requires its own `claude /login` the first time.

---

## `CCAGE_SHARE_FROM` + `CCAGE_SHARE_DIRS` [shipped]

Optional opt-in to share selected subdirectories from a master dir into every per-project config dir via symlinks.

- `CCAGE_SHARE_FROM` — absolute path to the master dir (e.g. `$HOME/.claude-master`). Unset = feature off.
- `CCAGE_SHARE_DIRS` — space-separated list of subdirs to share. Default: `"commands agents skills"`.

Behavior: on bootstrap, for each name in `CCAGE_SHARE_DIRS`, if `<master>/<name>` exists and `<config-dir>/<name>` does not exist at all, create a symlink. Existing entries (real dir, file, or symlink to any target) are left alone. Real dirs/files get a stderr warning; symlinks (even to wrong targets) are silently skipped.

**Never default-share**: `memory/`, `projects/`, `settings.json`, `plugins/`, `hooks/`, or credentials. These carry state that breaks isolation if shared.

### Opt-out
There is no explicit opt-out env var — simply leave `CCAGE_SHARE_FROM` unset (the default).

### Example
```bash
# In ~/.bashrc.d/claude-overrides.sh:
export CCAGE_SHARE_FROM="$HOME/.claude-master"
# Optional — default is "commands agents skills":
# export CCAGE_SHARE_DIRS="commands agents"
```

Create `~/.claude-master/commands/`, `~/.claude-master/agents/`, `~/.claude-master/skills/` and populate them. Each project's config dir will get symlinks on first bootstrap.

---

## Claude-side env vars we touch

| Var | Direction | When |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | export | every invocation |
| `CLAUDE_CODE_ATTRIBUTION_HEADER` | export (unless opt-out) | every invocation |
| `DISABLE_AUTOUPDATER` | export (unless opt-out) | every invocation |

We deliberately do not touch `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BETAS`, `ANTHROPIC_MODEL`, `ANTHROPIC_BASE_URL`. These are user-configured.

Other Claude env vars surveyed but intentionally *not* defaulted by ccage (users can set them in overrides or shell rc):

| Var | Why we didn't set a default |
|---|---|
| `CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS` | Saves ~1800 tokens/session, but changes behavior (loses git awareness). Should be opt-in per user. |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | User-preference on telemetry; shouldn't be silent. |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`, `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, `CLAUDE_CODE_DISABLE_1M_CONTEXT` | Knobs for edge cases; defaults are fine for most. |
| `CLAUDE_CODE_SKIP_PROMPT_HISTORY` | Ephemeral-session opt-in; hostile to debuggability if silent. |

---

## Compatibility notes

- **Shells**: bash ≥ 4, zsh ≥ 5.
- **OS**: Linux, macOS. Windows native is unsupported; WSL works.
- **`sha1sum` fallback order**: `sha1sum` → `shasum -a 1` → `openssl dgst -sha1`.
- **`python3`**: optional; onboarding patch degrades to "first session sees onboarding flow" without it.
- **`npx`**: only needed for `ccusage-all`.
