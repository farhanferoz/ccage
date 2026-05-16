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

The `claude()` shell function intercepts resume invocations to surface the cache-rewrite cost before launch. Motivation: Claude Code's `--resume` / `--continue` always cache-miss the message prefix (structural diff at `messages[0]`, not TTL — see GitHub #42309, #43657). On long sessions this is real money ($0.50–$2/resume on Opus).

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
       (Claude Code resume always misses cache; not a TTL issue — see GitHub #42309, #43657.)
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

Generates a Markdown handoff brief from a Claude Code session JSONL. **Zero API calls** — pure shell + jq. Use case: avoid `claude -r`/`-c`'s structural prompt-cache rewrite tax (Claude Code resumes always cache-miss on the message prefix — see GitHub issues #42309, #43657). Generate a brief from the prior session, start a fresh `claude`, paste the brief as the first message.

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

## Resume cost interception [shipped — Phase 6b]

When you invoke `claude -c` (continue) or `claude -r <session-id>` (resume), the wrapper computes the cache-rewrite cost from the session's on-disk `usage` history and prompts before launch. Background: Claude Code's resume always misses the message-prefix cache, regardless of TTL (GitHub anthropics/claude-code #42309, #43657 — `processSessionStartHooks` and `reorderAttachmentsForAPI` shuffle bytes at `messages[0]`). Each cold resume pays ~1.25× input rate on the rewritten prefix; on a long Opus session that's $0.50–$2+ per resume.

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
       (Claude Code resume always misses cache; not a TTL issue — see GitHub #42309, #43657.)
       [r]esume / [h]andoff / [c]ancel?
```

Cost is a range (±25% empirical uncertainty band), computed as `peak_cache_read − ~19K tools+system prefix`, times the model's cache-write rate from the inline pricing table.

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
