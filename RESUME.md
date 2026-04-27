# RESUME — ccage session state

Pointer file for resuming work without blowing up context. Update the "Current state" and "Next action" sections as work progresses. Everything else lives in the referenced files.

## Current state

- **Phase:** Phase 5 (CI) locally validated, pending push. Opus signed off on § 5.1 + § 5.2; § 5.3 (first green run + intentional-red verification) is blocked on a GitHub remote. Phase 6 (nice-to-haves) and Phase 7 (publish) come after.
- **Last session:** 2026-04-23. Phase 5: `.github/workflows/ci.yml` shipped with `os: [ubuntu-latest, macos-latest] × shell: [bash, zsh]` matrix. Two simplify + two Opus review passes.
- **Local validation done** (Docker + local): YAML valid, shellcheck clean, bats 31/31 in ubuntu container + locally, bash smoke test in ubuntu container, **zsh smoke test under real zsh (zshusers/zsh image)** — directly confirms `typeset -f claude >/dev/null` works in both shells. `act` run failed on `apt-get` finding shellcheck in its stripped container; not a workflow bug (GitHub's ubuntu-latest image ships shellcheck pre-installed, so `command -v shellcheck` short-circuits before apt).

## Next action

**User pushes to GitHub** to a new remote, then verifies § 5.3: first run green on all 4 matrix cells, and an intentional-red commit on a branch produces a failing run.

After § 5.3 clears, next phases:
- **Phase 6** (post-v0, queued): `ccage list`, `ccage doctor`, `ccage prune`. Each is its own tests-first phase.
  - Candidate (doctor-adjacent): **stale-session nudge.** If the newest session JSONL under `$CLAUDE_CONFIG_DIR/projects/<slug>/` is older than ~2h on `claude` invocation, print a one-line hint suggesting `/clear` or session-handoff. Motivation: Anthropic prompt cache TTL is 5min (ephemeral) / 1h (extended); overnight idle sessions always cold-miss, and the morning's first message re-writes the full accumulated context at cache-write rates. ccage can't extend the TTL, but it can warn before the user pays for it. Not a fix, just a nudge — gate behind an env var (`CCAGE_STALE_NUDGE=0` to silence) so it can't become noise.
- **Phase 7** (publish): tag `v0.1.0`, move CHANGELOG `Unreleased` → dated section.

## Validation status (2026-04-27)

End-to-end behavior verified via `tests/validate-e2e.sh` — 30 mock-stub checks plus 9 real-`claude` checks (gated behind `--with-real-claude`, ~$0.005 in API spend). Together they cover parallel-session isolation, env defaults, onboarding patch, skill/command/agent symlinking, `CCAGE_DISABLE`, `CCAGE_KEEP_*` opt-outs, idempotency, basename-collision hashing, and confirmation that the real `claude` binary accepts what ccage produces (patched `.claude.json`, symlinked subdirs, etc.). Combined with 31 bats unit tests and shellcheck clean, the wrapper is well-validated. Still unvalidated: cache-hit improvement claim (needs tokenol soak), real GH macOS runner (blocked on § 5.3 push).

## Known bugs

- **`claude` is a function, so `timeout`/`nohup`/`xargs` bypass the wrapper.** Anything that exec's `claude` as an external command (rather than going through the shell) finds the real binary in PATH and skips ccage's bootstrap entirely. Discovered while writing `tests/validate-e2e.sh` (the test wrapped `timeout 60 claude` and silently lost all bootstrap effects). Not a bug per se — that's how shell functions work — but worth one line in README's "limitations" before publish, or shipping an alternate `ccage-run` script entry point that bridges the function for non-shell callers.

- **Wrapper unsafe under `set -u`.** `share/claude-isolation.sh` reads `CCAGE_DISABLE`, `CCAGE_KEEP_ATTRIBUTION`, `CCAGE_KEEP_AUTOUPDATER`, `CCAGE_NO_ONBOARDING_PATCH`, `CCAGE_NO_AUTO_SIGNORE` without `${var:-}` defaults. Sourcing into a strict shell (any user with `set -u` in their shell init) crashes on first `claude` invocation with "unbound variable". Five-line fix; surface before Phase 7 (publish). Found by `tests/validate-e2e.sh` 2026-04-27.

## Known fragilities to watch

- The `command -v shellcheck || sudo apt-get install -y shellcheck` guard assumes shellcheck is pre-installed on `ubuntu-latest` (currently true). If that ever changes upstream, CI will fail because there's no `apt-get update` before the install. Flagged but not worth fixing now (costs ~8s every run for a hypothetical future).
- `shell: 'zsh -e {0}'` uses documented custom-shell template syntax but was not run against a real GitHub Actions runner locally. First push will confirm.

## Where to read

| Question | File |
|---|---|
| What's the build plan? | [docs/PLAN.md](docs/PLAN.md) |
| What does ccage do; every env var & hook? | [docs/FEATURES.md](docs/FEATURES.md) |
| How do the pieces fit internally? | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| What changed in each version? | [CHANGELOG.md](CHANGELOG.md) |
| How do I install and use it? | [README.md](README.md) |

## Active decisions

Locked (see `project_ccage_*` memory notes):
- Keying: **Option A** — basename + sha1-on-collision. No always-suffix, no registry.
- Packaging: **pure shell**. Homebrew deferred until demand.
- Defaults: attribution header + autoupdater both off by default, both opt-outable.
- Doctrine: **UI-only seeding** into per-project `settings.json` — never copy permissions/plugins/state from a master.
- Extension model: two hook stubs (`_ccage_config_dir_override`, `_ccage_pre_exec_hook`), overrides live in `~/.bashrc.d/claude-overrides.sh` (not installed by ccage; user-written).

Open:
- None blocking next phases.

## User personal setup

User's machine setup (separate from ccage repo):
- `~/.bashrc.d/claude-isolation.sh` — ccage portable wrapper.
- `~/.bashrc.d/claude-ccusage.sh` — ccage `ccusage-all`.
- `~/.bashrc.d/claude-overrides.sh` — user-specific: mercor path pinning, telegram per-PWD, statusline seeding.
- `~/.bashrc.pre-ccage-<timestamp>` — backup of pre-refactor `.bashrc`.
- `~/.bashrc` exports `CCAGE_SHARE_FROM="$HOME/.claude"` — activates `_ccage_share_dirs`, symlinking `skills/`, `commands/`, `agents/` from `~/.claude/` into every per-project config dir. Orthogonal to the UI-only settings.json doctrine (directory-sharing, not JSON-key seeding).

User TODOs (Phase 0, not Sonnet's scope):
- Install `claude-code-cache-fix`, run ~1 week, record ccusage deltas in CHANGELOG Unreleased.
- Report any ccage regressions from real-world use.

## Workflow

Sonnet implements; Opus reviews. Each phase follows PLAN.md's TDD rhythm: failing test → minimum code → passing test → refactor → docs + CHANGELOG. Handoff message format is at the bottom of PLAN.md.
