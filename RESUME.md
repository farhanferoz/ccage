# RESUME — ccage session state

Pointer file for resuming work without blowing up context. Update the "Current state" and "Next action" sections as work progresses. Everything else lives in the referenced files.

## Current state

- **Phase:** Phase 2 complete. Phase 3a (`CCAGE_SLOT`) is next.
- **Last session:** 2026-04-23. Phase 2 (repo hygiene) done: LICENSE, first commit (`740b5a7`), handoff file deleted. Simplify pass done: extracted `share/ccage-lib.sh`, hot-path optimisations to `claude-isolation.sh` (`${##*/}`, `read` builtin, sha1 caching, `_CCAGE_OVERRIDE_ACTIVE` guard), deduped `install.sh`/`uninstall.sh`.
- **User's installed files** (`~/.bashrc.d/`) synced to repo HEAD. `claude-overrides.sh` updated with `_CCAGE_OVERRIDE_ACTIVE=1` and `${##*/}` basename opt.

## Next action

Implement **Phase 3a — `CCAGE_SLOT`** per [docs/PLAN.md § Phase 3a](docs/PLAN.md#phase-3a--ccage_slot-escape-hatch). Write failing `tests/test_slot.bats` first, then implement, then Opus reviews.

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
- None blocking Phase 3a.

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
