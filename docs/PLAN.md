# ccage — Build Plan

Workflow: **Sonnet implements each phase TDD-style; Opus reviews when the phase reports green**.

## Status

| Phase | State |
|---|---|
| 0 — User pre-flight | ⏳ ongoing (cache-fix soak) |
| 2 — Repo hygiene | ✅ done |
| 3a — `CCAGE_SLOT` | ✅ done |
| 3b — `CCAGE_SHARE_FROM` | ✅ done |
| 4 — Backfill bats tests | ✅ done (bats vendored as submodule) |
| 5 — CI matrix | ✅ done locally; § 5.3 pending real-runner verification on first push |
| 6 — Nice-to-haves | ⏸ queued |
| 7 — Publish | ⏸ blocked on § 5.3 + two pre-publish bug fixes (see RESUME.md "Known bugs") |

End-to-end behavior is also covered by `tests/validate-e2e.sh` (30 mock + 9 real-claude assertions) — see RESUME.md for details.

## Ground rules

- **TDD, no guesses.** For every phase: write the failing test first, run it, watch it fail for the right reason, write the minimum code to pass, run it, watch it pass, refactor.
- **No AI attribution.** Zero references to Claude/Anthropic/Co-Authored-By in commits, PRs, code comments, or docs.
- **Keep existing users working.** Defaults cannot break the v0 layout on anyone who already runs the pre-v0 bashrc wrapper or the current skeleton.
- **Scope discipline.** Each phase ends when its acceptance criteria are green. Out-of-scope ideas are captured as a PLAN.md PR, not bolted onto the current phase.
- **Always update docs in the same commit as code.** README and FEATURES.md reference source behavior; CHANGELOG gets an entry per change.

## Test harness

- **bats-core** (Bash Automated Testing System). Vendored at `tests/bats/` as a git submodule *or* installed system-wide — Sonnet picks one in Phase 4 setup and documents.
- Tests live at `tests/test_*.bats`. One file per subject (e.g. `test_config_dir_for.bats`, `test_bootstrap.bats`).
- Shared fixtures in `tests/helpers.bash` — `setup()` creates a temp `$HOME`, sources the wrapper with `CCAGE_ROOT=$BATS_TEST_TMPDIR`, stubs `command claude` with a no-op.
- **Every phase that touches behavior must add or update a `.bats` file before code.**

## Phase 0 — User pre-flight (not implementation work)

User-side tasks that run in parallel with development. Not Sonnet's responsibility; listed for session continuity.

- Install `claude-code-cache-fix` globally. Capture `ccusage-all` baseline.
- Use `claude` in normal worktrees for 3–5 days. Note any regressions.
- After 3–5 days, compare `ccusage-all` numbers: did cache_read climb and cache_create drop?

Exit criteria: no ccage regressions reported; before/after cache numbers recorded in `CHANGELOG.md` under Unreleased.

## Phase 2 — Repo hygiene

**Goal:** repo is ready to be shared publicly.

### 2.1 Prerequisites section in README

- Add a "Prerequisites" subsection under Install listing: bash ≥ 4 or zsh ≥ 5; `python3` optional (onboarding-flag patch degrades gracefully without it); `npx` only if you use `ccusage-all`.
- No tests — documentation change. Acceptance: section exists, mentions all three tools, explicitly marks optional ones.

### 2.2 "Multiple sessions in same project" FAQ

- Add FAQ entry pointing to (a) `git worktree add ../repo-name` as the preferred pattern and (b) `CCAGE_SLOT=<name>` as an escape hatch when a worktree isn't practical.
- Acceptance: FAQ entry exists, links to the Anthropic worktree guide, notes `CCAGE_SLOT` is coming in Phase 3a.

### 2.3 License

- Add `LICENSE` file with MIT text, copyright holder = user's name (confirm before commit).
- Update README "License" line to `MIT` (remove "TBD").

### 2.4 Drop the handoff file

- Delete `claude-isolation-handoff.md` — its content now lives in README, FEATURES, ARCHITECTURE, and session memory.
- If the user wants a record, it's already in `.claude-ccage/memory/project_ccage*.md`.

### 2.5 git init + first commit

- `git init`, `git add .`, `git commit -m "initial commit"`.
- Commit message body bullets major pieces; **no AI attribution trailer**.
- Acceptance: `git log --oneline` shows exactly one commit; `git status` is clean.

## Phase 3a — `CCAGE_SLOT` escape hatch

**Goal:** allow multiple parallel sessions in the same `$PWD` to use distinct config dirs.

### 3a.1 Tests first — `tests/test_slot.bats`

Write failing tests asserting:
1. `CCAGE_SLOT` unset → `_ccage_config_dir_for /some/path` returns `$CCAGE_ROOT/.claude-path`.
2. `CCAGE_SLOT=review` → returns `$CCAGE_ROOT/.claude-path--review`.
3. `CCAGE_SLOT=bg` in a path with an existing basename-collision owner → returns `$CCAGE_ROOT/.claude-<base>-<sha>--bg` (slot suffix applied *after* collision resolution).
4. `CCAGE_SLOT` with unsafe chars (`/`, spaces, `..`) → function errors or sanitizes to alphanumeric+dash; pick one, document the choice.
5. Override hook still takes precedence — `_ccage_config_dir_override` returning a path bypasses slot.

Run `bats tests/test_slot.bats` — expect all 5 failing.

### 3a.2 Implementation

- In `share/claude-isolation.sh`, after the existing override-hook short-circuit and collision-resolution block, append slot suffix if `$CCAGE_SLOT` is non-empty. Sanitize to `[A-Za-z0-9_-]+`; reject otherwise with a stderr warning and ignore the var.
- Separator is `--` (double-dash) so slot suffix is visually distinct from basename.

### 3a.3 Docs + CHANGELOG

- FEATURES.md: new `CCAGE_SLOT` entry.
- README: mention in the multi-session FAQ (replace "coming in Phase 3a" with a real pointer).
- CHANGELOG: Unreleased → Added → "`CCAGE_SLOT` env var for running multiple isolated sessions in the same directory."

### 3a.4 Acceptance

- All 5 bats tests green.
- `shellcheck share/claude-isolation.sh` clean.
- Manual smoke: in a throwaway dir, run with `CCAGE_SLOT=a` and `CCAGE_SLOT=b` and confirm two distinct config dirs get created.

## Phase 3b — Selective sharing

**Goal:** let users share slash commands, skills, and agents across isolated config dirs from one master location, without compromising isolation of credentials/cache/history.

### 3b.1 Tests first — `tests/test_share.bats`

Fixtures: a fake master at `$BATS_TEST_TMPDIR/master/` containing `commands/foo.md`, `skills/bar/`, `agents/baz.md`.

Assert:
1. `CCAGE_SHARE_FROM` unset → no symlinks created after bootstrap.
2. `CCAGE_SHARE_FROM=$master` (defaults) → `$CLAUDE_CONFIG_DIR/commands`, `/skills`, `/agents` are symlinks pointing to `$master/commands`, etc.
3. `CCAGE_SHARE_DIRS="commands"` → only `commands` is linked; `skills` and `agents` are not.
4. Target dir already exists as a real dir → left alone, no symlink created, warning logged to stderr once.
5. Target is a symlink to a *different* path → left alone.
6. Master subdir missing → skipped silently, no error.
7. Re-running bootstrap is idempotent (no duplicate links, no errors).

Run `bats tests/test_share.bats` — expect 7 failures.

### 3b.2 Implementation

- New function `_ccage_share_dirs` in `share/claude-isolation.sh`. Called from `_ccage_bootstrap_dir` after `hasCompletedOnboarding` patch.
- Reads `CCAGE_SHARE_FROM` (path) and `CCAGE_SHARE_DIRS` (space-separated list; default `"commands agents skills"`).
- For each name: if master/name exists and target doesn't, `ln -s`. If target exists, leave alone.
- Guard: if `CCAGE_SHARE_FROM` is equal to the current `CLAUDE_CONFIG_DIR`, error and return (would create a loop).

### 3b.3 Docs + CHANGELOG

- FEATURES.md: `CCAGE_SHARE_FROM`, `CCAGE_SHARE_DIRS` entries with safety notes (read-mostly assumption, never ship shared `memory/` or `projects/` by default).
- README: "Sharing skills and commands across projects" recipe under the overrides section.
- CHANGELOG entry.

### 3b.4 Acceptance

- All 7 bats tests green.
- `shellcheck` clean.
- Manual smoke: point `CCAGE_SHARE_FROM` at `~/.claude-master`, run `claude` in two different project dirs, confirm slash commands appear in both.

## Phase 4 — Backfill tests for existing behavior

**Goal:** test coverage for everything merged in v0 that currently has none.

### 4.1 `tests/test_config_dir_for.bats`

- Plain basename mapping for a path with no collision.
- Basename collision where `.owning_path` matches current PWD → no hash suffix (re-entry on the same dir).
- Basename collision where `.owning_path` points to a *different* path → hash suffix applied, 8 chars of sha1.
- Missing marker file on an existing dir → current PWD claims it (unmarked-dir backward compat).
- `_ccage_config_dir_override` returning zero-length stdout → treated as "no override."
- Respect for `CCAGE_ROOT` and `CCAGE_PREFIX`.

### 4.2 `tests/test_bootstrap.bats`

- Fresh dir: creates, stamps `.owning_path`, writes minimal `.claude.json` with `hasCompletedOnboarding=true`.
- Existing `.claude.json` without the flag and with `python3` available → flag gets added; other keys preserved.
- Existing `.claude.json` already with the flag → file unchanged.
- `CCAGE_NO_ONBOARDING_PATCH=1` → no modification to `.claude.json`.
- Missing `python3` → no crash, onboarding patch silently skipped.

### 4.3 `tests/test_signore.bats`

- No `.claudesignore` in PWD → baseline written.
- Existing `.claudesignore` → not touched.
- `CCAGE_NO_AUTO_SIGNORE=1` → nothing written, even if absent.

### 4.4 `tests/test_env_defaults.bats`

- Default invocation exports `CLAUDE_CODE_ATTRIBUTION_HEADER=0` and `DISABLE_AUTOUPDATER=1`.
- `CCAGE_KEEP_ATTRIBUTION=1` → header env var not exported (use `env -u` + subshell to assert).
- `CCAGE_KEEP_AUTOUPDATER=1` → autoupdater var not exported.
- `CCAGE_DISABLE=1` → wrapper is a pure pass-through: none of the ccage env vars get touched.

### 4.5 Acceptance

- All tests in `tests/` green.
- `shellcheck share/*.sh install.sh uninstall.sh` clean.
- README "Development" subsection added: how to run tests locally.

## Phase 5 — CI

**Goal:** every PR runs the test matrix before merge.

### 5.1 `.github/workflows/ci.yml`

- Matrix: `os: [ubuntu-latest, macos-latest]`, `shell: [bash, zsh]`.
- Steps: checkout, install bats, install shellcheck, run `shellcheck share/*.sh install.sh uninstall.sh`, run `bats tests/`.
- Cache-key the bats install to keep runs fast.

### 5.2 README badge

- CI status badge at the top of README.

### 5.3 Acceptance

- First CI run green on both OSes and both shells.
- Intentional broken commit on a branch reproduces a red CI status — verify the pipeline can actually fail.

## Phase 6 — Nice-to-haves (post-v0; queued)

Not in scope for v0. Each is a separate future phase with its own tests-first spec.

- **`ccage list`** — print isolated dirs with owner, size, last-touched.
- **`ccage doctor`** — diagnose missing markers, orphaned dirs, missing `claude-code-cache-fix`, stale `.claude.json`.
- **`ccage prune`** — remove dirs whose owning path is gone (dry-run default, `--yes` to execute).
- **Full multi-session solve** — lockfile-based slot auto-assignment with credential symlink + refresh-race mitigation. Hard; needs design doc first.

## Phase 7 — Publish

**Goal:** public GitHub repo, installable from clone.

- Push to GitHub under the user's account.
- Tag `v0.1.0`. Release notes copied from CHANGELOG Unreleased → move to a dated section.
- Optional: announce. User's call whether/where.
- Homebrew formula and `pipx` package are explicitly deferred until someone asks.

## Handoff notes — Sonnet → Opus

When Sonnet finishes a phase, the handoff message should include:

1. List of files changed.
2. Output of `bats tests/` (full).
3. Output of `shellcheck share/*.sh install.sh uninstall.sh`.
4. CHANGELOG diff for the phase.
5. Any decisions made that weren't in PLAN.md (and why).
6. Any skipped test cases (and why) — skipped cases must be justified or re-added.

Opus reviews against acceptance criteria. If a criterion is partially met, Opus writes a follow-up item onto the phase and hands back to Sonnet. Phase is not done until Opus signs off.
