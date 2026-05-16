# Changelog

All notable changes to ccage. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **`claude -r` / `claude -c` cost interception (Phase 6b).** When the wrapper detects a resume invocation (`-c`, `--continue`, `-r <uuid-prefix>`, `--resume <uuid-prefix>`), it sums per-turn `cache_creation_input_tokens` from the session JSONL, subtracts an estimated 19K tools+system prefix that survives resume, computes a ±25% dollar range using the model's cache-write rate, and prompts `[r]esume / [h]andoff / [c]ancel`. Bare `-r` / `--resume` (no id) passes through because Claude Code may launch its own session picker we can't predict. Gates: `CCAGE_DISABLE=1`, `CCAGE_NO_RESUME_PROMPT=1`, non-tty stdin, or estimated cost below `CCAGE_RESUME_PROMPT_MIN_USD` (default `0.25`). `h` branch delegates to `ccage handoff` (installed by `install.sh`). Spec at `docs/PHASE-6-HANDOFF-SPEC.md`. 28 bats tests in `tests/test_resume_interception.bats` plus 3 e2e gate-assertions in `tests/validate-e2e.sh`.
- **`ccage handoff` — offline session brief generator.** Turns any session JSONL into a Markdown brief with user prompts, files touched, bash commands, last assistant turn, token totals, and a cost estimate. Zero API calls (pure shell + jq). Output is written to `${CCAGE_HANDOFF_DIR:-~/.local/share/ccage/handoffs}/<project-slug>-<session-prefix>-<timestamp>.md`; auto-copies to clipboard if `pbcopy`/`wl-copy`/`xclip`/`xsel` is available. Motivation: Claude Code's `claude -r`/`-c` always cache-miss the message prefix on resume (structural diff at `messages[0]`, not TTL — see GitHub #42309, #43657), so a fresh-session + handoff-brief workflow avoids the $0.50–$2 cache-rewrite tax per resume on long Opus sessions. New `bin/ccage` POSIX-sh dispatcher; library at `share/ccage-handoff.sh`. `install.sh` gained `--prefix`, `--no-cli`, plus a `jq` dependency check with platform-specific install hints. New `tests/test_handoff.bats` (42 tests) + `tests/test_install_uninstall.bats` (14 tests; also covers a pre-existing uninstall regex bug, see Fixed). Spec at `docs/PHASE-6-HANDOFF-SPEC.md`.
- `CCAGE_SLOT` env var: append `--<slot>` to the config dir name, letting multiple sessions share the same `$PWD` without clobbering each other. Slot suffix is applied after collision-hash resolution; unsafe characters (`/`, spaces, etc.) emit a stderr warning and are ignored. Override hook still takes precedence.
- `CCAGE_SHARE_FROM` + `CCAGE_SHARE_DIRS`: opt-in symlink-sharing of `commands`, `agents`, and `skills` from a master config dir into every per-project config dir on bootstrap. Existing entries are left alone; missing master subdirs are silently skipped; real-dir conflicts warn to stderr.
- Backfill test suite: `tests/test_config_dir_for.bats`, `tests/test_bootstrap.bats`, `tests/test_signore.bats`, `tests/test_env_defaults.bats` (31 tests total). bats-core vendored at `tests/bats/`.
- GitHub Actions CI: `.github/workflows/ci.yml` — matrix of `os: [ubuntu-latest, macos-latest]` × `shell: [bash, zsh]`; bash cells run shellcheck (ubuntu only — OS-independent) + source smoke test + bats; zsh cells run source smoke test only (bats requires bash). Deviates from PLAN.md § 5.1 which implied bats and shellcheck run on all cells — both restrictions are intentional.

### Fixed
- `ccage handoff`: user-prompt extraction now drops synthetic slash-command echoes (`<command-name>`, `<local-command-stdout>`, `<command-message>`, `<command-args>`, `<system-reminder>`). These appear in real Claude Code transcripts whenever a user invokes a slash command and were polluting the User prompts section of the brief. Surfaced via Phase 6c real-world validation against a 505-line `~/.claude-ab-task_a/projects/...` session — the unfiltered brief showed 10 "prompts" of which 4 were `/effort` invocation noise.
- `_ccage_patch_onboarding`: python3 failure now silently swallowed (`|| true`) rather than propagating under `set -e`. Previously a failing python3 invocation would abort the bootstrap call with a non-zero exit.
- `uninstall.sh`: awk pattern that stripped the installer's source-loop required a literal space before `.sh` that install.sh never wrote, so the source line survived uninstall as orphaned rc clutter. Replaced with a simpler "drop one line after the `# Added by ccage installer` marker" rule that is robust to future changes in the source-line syntax. Caught by the new `tests/test_install_uninstall.bats` round-trip suite (10 tests).
- `share/claude-isolation.sh`: five optional env vars (`CCAGE_DISABLE`, `CCAGE_KEEP_ATTRIBUTION`, `CCAGE_KEEP_AUTOUPDATER`, `CCAGE_NO_ONBOARDING_PATCH`, `CCAGE_NO_AUTO_SIGNORE`) were read without `${var:-}` defaults, so the wrapper crashed with "unbound variable" the first time a strict-mode shell (`set -u`) invoked `claude`. All reads now use the default-empty pattern. Regression covered by `tests/test_set_u_safety.bats` (3 tests).
- Resume cost prompt's single-keypress read: bash uses `read -n N`, zsh uses `read -k N`. The first implementation used `-rn 1` unconditionally — would have broken or hung the prompt for zsh users. Branched on `$ZSH_VERSION`. Found in Tier 2 review (gemini missed it; surfaced by an audit pass after gemini's findings were triaged).

### Documentation
- README "Limitations" section: documents the `timeout`/`nohup` function-bypass, `set -u` unsafety, and nested-worktree race. The first two surfaced via `tests/validate-e2e.sh` validation pass; both are scheduled to be fixed (or, in the function-bypass case, made tolerable) before v0.1.0.
- PLAN.md: added a Status block summarizing which phases are done.

### Changed
- **Extension contract**: `_ccage_config_dir_override` is now only invoked when `_CCAGE_OVERRIDE_ACTIVE=1`. Users whose existing overrides redefine the function must add `_CCAGE_OVERRIDE_ACTIVE=1` after the function definition, or the override will be silently skipped. The shipped `claude-overrides.sh.example` sets the flag; copy from it. Rationale: saves a subshell fork on every `claude` invocation when no override is installed. Documented in `docs/FEATURES.md` and `docs/ARCHITECTURE.md`.
- Hot-path simplifications in `share/claude-isolation.sh`: sha1 tool resolved once at source time (no `command -v` probe per collision); `basename` fork replaced with `${pwd_arg##*/}`; `.owning_path` read via `read` builtin instead of `$(cat ...)`; `_ccage_patch_onboarding` split out of `_ccage_bootstrap_dir`; `_ccage_write_signore` takes an explicit directory argument. Behavior identical; fewer forks per invocation.
- `install.sh` / `uninstall.sh`: shared `run()` helper and shell-resolution moved into `share/ccage-lib.sh`; `run()` no longer uses `eval`.

### Added
- Per-project `CLAUDE_CONFIG_DIR` wrapper keyed on `basename $PWD` with 8-char sha1 disambiguation on collisions (see `share/claude-isolation.sh`).
- `.owning_path` marker written to each config dir on first claim; used for collision detection.
- Baseline `.claudesignore` auto-written to any project that doesn't have one, excluding `node_modules`, virtualenvs, build dirs, tool caches, and common binary artifacts.
- Onboarding-gate patch: ccage writes `hasCompletedOnboarding=true` into new config dirs so fresh dirs don't force the login flow when valid creds exist elsewhere.
- Default export of `CLAUDE_CODE_ATTRIBUTION_HEADER=0` to suppress the rotating `cch=<hash>` in the billing header (restores prompt-cache key stability). Mechanism references: [claude-code-router#1220](https://github.com/musistudio/claude-code-router/pull/1220), [cc-switch#2025](https://github.com/farion1231/cc-switch/issues/2025).
- Default export of `DISABLE_AUTOUPDATER=1` to prevent parallel sessions from corrupting the install via a self-update race.
- Extension hooks `_ccage_config_dir_override` and `_ccage_pre_exec_hook`, redefinable from a sibling overrides file loaded after the wrapper.
- `_ccage_extra_args` array for injecting CLI flags from the pre-exec hook (e.g. per-PWD plugin channels).
- `ccusage-all` aggregator (independent file `share/claude-ccusage.sh`) that runs `ccusage` across every ccage-isolated config dir.
- Portable sha1 implementation with fallback order `sha1sum` → `shasum -a 1` → `openssl dgst -sha1` for macOS support.
- Opt-out env vars: `CCAGE_DISABLE`, `CCAGE_KEEP_ATTRIBUTION`, `CCAGE_KEEP_AUTOUPDATER`, `CCAGE_NO_AUTO_SIGNORE`, `CCAGE_NO_ONBOARDING_PATCH`.
- Configuration env vars: `CCAGE_ROOT`, `CCAGE_PREFIX`.
- `install.sh` — idempotent installer that writes to `~/.bashrc.d/` or `~/.zshrc.d/` without editing the main rc file.
- `uninstall.sh` — removes installed files, strips the installer-added sourcing block, preserves user data (per-project config dirs, `claude-overrides.sh`).
- `share/claude-overrides.sh.example` — template users copy for per-path config pinning, per-PWD env vars, CLI-flag injection, and UI-only settings seeding.
- Docs: `docs/PLAN.md` (TDD-structured phased work plan), `docs/FEATURES.md` (exhaustive reference), `docs/ARCHITECTURE.md` (internal wiring), `RESUME.md` (session pointer).
- README recipes for the three most common overrides patterns (path-pinning, plugin-channel injection, statusline seeding).

### Notes
- Keying strategy locked to **Option A** (basename + hash-on-collision). Always-suffix and registry-based alternatives considered and deferred. See `project_ccage_v0_choices` memory for reasoning.
- Attribution-header suppression does **not** fix the separate `cch=`-in-tool_results cache bug tracked at [anthropics/claude-code#40652](https://github.com/anthropics/claude-code/issues/40652). Users with heavy tool-use sessions should also install [`claude-code-cache-fix`](https://github.com/cnighswonger/claude-code-cache-fix).
- No AI attribution anywhere per project preference.

---

<!--
When cutting a release:
1. Replace the [Unreleased] header with the new version + date (e.g. ## [0.1.0] - 2026-MM-DD).
2. Insert a fresh empty [Unreleased] section above it.
3. Tag the commit: `git tag v0.1.0`.
-->
