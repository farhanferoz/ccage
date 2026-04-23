# ccage — Feature Reference

Exhaustive reference for everything ccage does, every env var it reads, every setting it writes. Keep in sync with `share/claude-isolation.sh`.

Legend: **shipped** = in v0. **planned** = specified but not implemented (see PLAN.md).

---

## Per-project `CLAUDE_CONFIG_DIR` [shipped]

Each `$PWD` resolves to a distinct config dir. Keying rules, in order:

1. If `_ccage_config_dir_override "$PWD"` returns 0 with a non-empty stdout line, that path wins.
2. Else candidate is `$CCAGE_ROOT/$CCAGE_PREFIX<basename $PWD>`.
3. If the candidate exists *and* has a `.owning_path` marker naming a path that isn't the current `$PWD`, append `-<sha1[0:8] of full path>`.
4. [planned — Phase 3a] If `$CCAGE_SLOT` is set and sanitizes to a non-empty alphanumeric-plus-dash string, append `--<slot>`.

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

## `ccusage-all` [shipped]

Function defined in `share/claude-ccusage.sh`. Iterates every `$CCAGE_ROOT/$CCAGE_PREFIX*` directory with a `projects/` subdir, exports `CLAUDE_CONFIG_DIR`, and runs `npx -y ccusage "$@"` against each.

### Prerequisites
- `npx` (from Node.js) — on PATH.
- Network access for `npx` to fetch `ccusage` on first use.

---

## `CCAGE_SLOT` [planned — Phase 3a]

Suffix on the config-dir name, for running multiple independent sessions in the same `$PWD` (e.g. one interactive, one background review agent). Accepted characters: `[A-Za-z0-9_-]+`. Anything else prints a warning and the variable is ignored.

Example:
```
cd ~/dev/myproject
CCAGE_SLOT=review  claude    # → ~/.claude-myproject--review
CCAGE_SLOT=bg      claude    # → ~/.claude-myproject--bg
```

Each slot requires its own `claude /login` the first time.

---

## `CCAGE_SHARE_FROM` + `CCAGE_SHARE_DIRS` [planned — Phase 3b]

Optional opt-in to share selected subdirectories from a master dir into every per-project config dir via symlinks.

- `CCAGE_SHARE_FROM` — absolute path to the master dir (e.g. `$HOME/.claude-master`). Unset = feature off.
- `CCAGE_SHARE_DIRS` — space-separated list of subdirs to share. Default: `"commands agents skills"`.

Behavior: on bootstrap, for each name in `CCAGE_SHARE_DIRS`, if `<master>/<name>` exists and `<config-dir>/<name>` does not, create a symlink. Existing targets (real dir, file, or different symlink) are left alone.

**Never default-share**: `memory/`, `projects/`, `settings.json`, `plugins/`, `hooks/`, or credentials. These carry state that breaks isolation if shared.

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
