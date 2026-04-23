# Changelog

All notable changes to ccage. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
