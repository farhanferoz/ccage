# RESUME — ccage session state

Pointer file for resuming work without blowing up context. Update the "Current state" and "Next action" sections as work progresses. Everything else lives in the referenced files.

## Current state

- **Phase:** between Phase 2 and Phase 3a (repo hygiene pending, CCAGE_SLOT next).
- **Last session ended:** 2026-04-23. Skeleton written + reviewed; `~/.bashrc` refactored into `~/.bashrc.d/`; decisions locked (Option A keying, pure-shell packaging); docs written (PLAN/FEATURES/ARCHITECTURE/CHANGELOG/this file).
- **Not yet done:** `git init`, LICENSE file, Phase 2 README updates, and everything from Phase 3a onward.

## Next action

Run **Phase 2 — Repo hygiene** per [docs/PLAN.md](docs/PLAN.md#phase-2--repo-hygiene). Then Phase 3a (`CCAGE_SLOT`). Both are Sonnet-implementable; Opus reviews each before handing to the next.

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
- LICENSE copyright holder name — confirm before first commit.
- Whether to delete or archive `claude-isolation-handoff.md` at the repo root.

## User personal setup

User's machine setup (separate from ccage repo):
- `~/.bashrc.d/claude-isolation.sh` — ccage portable wrapper.
- `~/.bashrc.d/claude-ccusage.sh` — ccage `ccusage-all`.
- `~/.bashrc.d/claude-overrides.sh` — user-specific: mercor path pinning, telegram per-PWD, statusline seeding.
- `~/.bashrc.pre-ccage-<timestamp>` — backup of pre-refactor `.bashrc`.

User TODOs (Phase 0, not Sonnet's scope):
- Install `claude-code-cache-fix`, run ~1 week, record ccusage deltas in CHANGELOG Unreleased.
- Report any ccage regressions from real-world use.

## Workflow

Sonnet implements; Opus reviews. Each phase follows PLAN.md's TDD rhythm: failing test → minimum code → passing test → refactor → docs + CHANGELOG. Handoff message format is at the bottom of PLAN.md.
