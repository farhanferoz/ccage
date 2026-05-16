# RESUME — ccage session state

Pointer file for resuming work without blowing up context. Update the "Current state" and "Next action" sections as work progresses. Everything else lives in the referenced files.

## Current state

- **Phase:** 6a + 6b + 6c **complete and committed locally.** Phase 7 (publish) is blocked only on § 5.3 — the user pushing to a GitHub remote and watching the CI matrix go green (and confirming an intentional-red branch produces a failing run).
- **Latest commits** (most recent first):
  - `ec19861` fix: zsh-compatible read for resume cost prompt (Tier 2 review fix)
  - `380603b` feat: -r/-c cost prompt interception (Phase 6b)
  - `be103f2` fix: ${var:-} defaults for set -u safety in claude-isolation.sh
  - `1191f10` feat: ccage handoff — offline session brief generator (Phase 6a)
  - `c306f8d` fix: uninstall left orphaned source loop in user rc
  - `54fea5b` docs: Phase 6 handoff + resume cost interception spec
- **What works locally**:
  - **118 bats tests pass** across `test_handoff` (42), `test_install_uninstall` (14), `test_resume_interception` (28), `test_set_u_safety` (3), plus the 31 pre-existing wrapper tests.
  - **44 e2e checks pass** in `tests/validate-e2e.sh` (the original 30 mock-stub assertions + 8 new for `ccage handoff` against a real ccage-bootstrapped session + 3 new for `-r`/`-c` interception gates + ~3 baseline).
  - **shellcheck clean** across `install.sh`, `uninstall.sh`, `share/*.sh`, `bin/ccage`, `tests/validate-e2e.sh`.
  - **Phase 6c real-world validation**: produced a 145-line / 11.7KB Markdown brief from a real 91-prompt / 688-assistant-turn session JSONL at `~/.claude-ab-task_a/projects/-home-ff235-dev-mercor-agentic-bench-gh8nb-task-a/69f299d8-1da0-486f-ae99-203642e5fcbe.jsonl`. All four sections (User prompts, Files touched, Commands run, Last assistant turn) populated with substantive content. Cost summary: ~$33 in cache writes paid across 31 days of session activity. Verdict: brief is a usable context bootstrap.
- **What's NOT done by me** (waiting on user):
  - `git push -u origin main` to the GitHub remote (per CLAUDE.md safety rules + explicit "don't push without my approval" from this session). After push, the user verifies § 5.3 acceptance:
    1. First CI run goes green on all 4 matrix cells (`ubuntu-latest`/`macos-latest` × `bash`/`zsh`).
    2. An intentional-red commit on a throwaway branch produces a failing CI run.

## Next action

**User pushes `main` to GitHub remote.** Then verifies § 5.3 (matrix green on first run + intentional-red branch fails). After that, Phase 7 publish is unblocked: tag `v0.1.0`, move CHANGELOG `Unreleased` → dated section.

## Validation status (2026-05-16)

Locally green on every layer:
- `./tests/bats/bin/bats tests/test_*.bats` — 118/118 pass.
- `./tests/validate-e2e.sh` — 44/44 pass (no real-claude run; that scenario remains opt-in via `--with-real-claude`).
- `shellcheck install.sh uninstall.sh share/*.sh bin/ccage tests/validate-e2e.sh` — clean.
- Real-world handoff brief on a 91-prompt session — sections populated correctly, content useful.

Still unvalidated (and out of my scope without push permission):
- First green CI run on real GH runners (§ 5.3).
- Zsh runtime of the `-r`/`-c` interception's interactive prompt (the new `read -k 1` branch). Code was added based on Tier 2 review analysis without a local zsh to verify against; CI's zsh smoke test sources the wrapper but doesn't enter the interactive prompt code path. Worth a manual zsh shell smoke once available.

## Tier 2 review (2026-05-16) — outcome

- Five commits since baseline `39f30c4`. ~2500 line additions across 18 files.
- External review via gemini 0.42.0 (`/home/ff235/.npm-global/bin/gemini`) on the full diff `39f30c4..HEAD`.
- One **high-severity** finding addressed: `read -rn 1 -s` is bash-only — zsh uses `-k N`. Fixed in commit `ec19861`. Gemini missed it; surfaced on a follow-up audit pass.
- Four **false positives** rejected (slug derivation, awk truncation correctness, backtick "injection," uninstall.sh awk regex — the last was already fixed in `c306f8d`).
- No medium-severity defects.
- Verdict: ship-ready pending § 5.3.

## Known bugs (still open, low priority)

- **Zsh `nomatch` on empty `.sh` glob in the installed rc source loop.** When ccage is uninstalled or all `.sh` files are removed from `~/.zshrc.d/`, zsh's default `nomatch` would error on the source loop. The uninstall regex fix in `c306f8d` closes the main vector (uninstall used to leave an orphan loop). Defense-in-depth fix would wrap the loop in a function with `setopt local_options null_glob`, but it can't be locally verified without zsh installed on this machine. Documented as a known limitation. Won't fix for v0; revisit if reported.

## Where to read

| Question | File |
|---|---|
| What's the build plan? | [docs/PLAN.md](docs/PLAN.md) |
| What does ccage do; every env var & hook? | [docs/FEATURES.md](docs/FEATURES.md) |
| How do the pieces fit internally? | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| What's the Phase 6 design rationale? | [docs/PHASE-6-HANDOFF-SPEC.md](docs/PHASE-6-HANDOFF-SPEC.md) |
| What changed in each version? | [CHANGELOG.md](CHANGELOG.md) |
| How do I install and use it? | [README.md](README.md) |

## Active decisions

Locked (see `project_ccage_*` memory notes + `docs/PHASE-6-HANDOFF-SPEC.md` decisions log):
- Keying: **Option A** — basename + sha1-on-collision. No always-suffix, no registry.
- Packaging: **pure shell**. Homebrew deferred until demand.
- Defaults: attribution header + autoupdater both off by default, both opt-outable.
- Doctrine: **UI-only seeding** into per-project `settings.json` — never copy permissions/plugins/state from a master.
- Extension model: two hook stubs (`_ccage_config_dir_override`, `_ccage_pre_exec_hook`), overrides live in `~/.bashrc.d/claude-overrides.sh`.
- **Phase 6 design** (locked at spec commit `54fea5b`): zero API calls in `ccage handoff` (jq-only), global flat handoff retention at `~/.local/share/ccage/handoffs/`, no git assumptions, single-template `-c` vs `-r <id>` prompt copy, clipboard order `pbcopy → wl-copy → xclip → xsel`. Resume interceptor lives inline in `share/claude-isolation.sh` (deviation from spec — spec suggested separate `ccage-resume.sh` — pragmatic to keep rc sourcing to one file; pricing table duplicated and tagged for synchronized refresh).

Open:
- None blocking Phase 7.

## User personal setup

User's machine setup (separate from ccage repo):
- `~/.bashrc.d/claude-isolation.sh` — ccage portable wrapper.
- `~/.bashrc.d/claude-ccusage.sh` — ccage `ccusage-all`.
- `~/.bashrc.d/claude-overrides.sh` — user-specific: mercor path pinning, telegram per-PWD, statusline seeding.
- `~/.bashrc.pre-ccage-<timestamp>` — backup of pre-refactor `.bashrc`.
- `~/.bashrc` exports `CCAGE_SHARE_FROM="$HOME/.claude"` — activates `_ccage_share_dirs`, symlinking `skills/`, `commands/`, `agents/` from `~/.claude/` into every per-project config dir.

User TODOs (Phase 0, not Sonnet's scope):
- Install `claude-code-cache-fix`, run ~1 week, record ccusage deltas in CHANGELOG Unreleased.
- Report any ccage regressions from real-world use.

After v0 ships, suggested follow-ups (not blocking):
- Re-source `~/.bashrc.d/claude-isolation.sh` in any already-open shell to pick up the new interception and handoff features (the existing function in those shells is from before this work).
- Try `claude -c` on a known-stale session; confirm the prompt fires and shows a reasonable cost range.
- Try `ccage handoff` against any project's most-recent session; check the brief.

## Workflow

Sonnet implements; Opus reviews. Tier 2 final review done at end of Phase 6c (per CLAUDE.md's `tiered-review` skill). Handoff message format is at the bottom of PLAN.md.
