# Phase 7 — Session Docs / Continuity (Plan v1)

Workflow: **implement each subphase TDD-style (bats first), self-review when a subphase
reports green.** Same rhythm as PLAN.md / PHASE-6.

> **How to use this plan.** This is self-contained — a fresh session with no prior
> context can implement it. Before writing code, read these ccage files so the
> "extend X" steps land in the right place:
> `share/claude-isolation.sh` (the `claude()` wrapper, `_ccage_config_dir_for`,
> `_ccage_bootstrap_dir`, `_ccage_share_dirs`, `_ccage_pre_exec_hook`),
> `install.sh` (the `install_file` / `run` idempotent pattern),
> `bin/ccage` + `share/ccage-handoff.sh` (how a subcommand is dispatched),
> `docs/FEATURES.md` (doc style: `[shipped]`/`[planned]`, numbered rules, Opt-outs/Config),
> `tests/test_slot.bats` + `tests/test_bootstrap.bats` (bats style, `load helpers`).
> All paths in this doc are absolute or repo-relative from `/home/ff235/dev/ccage`.

---

## Why

The session-continuity loop today is manual and lossy. To carry state across a
context boundary you run the `session-handoff` skill, **select + copy** its output,
`/clear`, then **paste** it back. Four steps, two of them fumble-prone. Separately,
`RESUME.md` (a durable per-repo resume file) is maintained by hand and is
**disconnected** from that handoff — so the same information is produced twice, two
different ways.

There is also accumulated drift in the existing setup that needs remediation, not just
forward fixes:

- **The budget-guard hook is dead in every caged session.** It lives in
  `~/.claude/settings.json`, but ccage points every session at
  `~/.claude-<basename>/settings.json` and never shares `settings.json`. Survey on the
  authoring machine: **44 caged config dirs, 0 with a `hooks` block, 0 referencing the
  hook.** It has never fired in a caged session — i.e. never, since everything runs caged.
- Some repos have a **bloated `RESUME.md`** (over its lean budget).
- Some cages have an **unorganized memory dir** (ungrouped `MEMORY.md`, stale/duplicate
  notes, dead index links).

## Goal

One coherent system that:

1. **Unifies the handoff with `RESUME.md`.** A `/checkpoint` skill writes the handoff
   *to `RESUME.md`* (merging it with carried threads), and a `SessionStart` hook
   **auto-reads `RESUME.md` back after `/clear`** — deleting both the copy and the paste.
   New loop: `/checkpoint` → `/clear` → (state auto-loaded). Two commands, zero lossy steps.
2. **Is seamless forward** for all current and future caged projects — no per-repo setup.
3. **Remediates existing drift** (dead hooks, bloated RESUME, messy memory) using the
   *same* machinery, so "new" and "existing" are one code path, not two.
4. **Is slot-safe** for parallel same-directory sessions (`CCAGE_SLOT`).
5. **Ships inside ccage** — version-controlled, installed by `install.sh`, propagated to
   every machine (incl. remote clusters), opt-in and reversible like every ccage feature.

## Non-goals (and reconciliation with PHASE-6)

PHASE-6 lists "auto-paste / auto-clear (too magical; brittle)" and "LLM-quality narrative
synthesis (`/session-handoff` covers it)" as non-goals. This plan stays consistent:

- **Auto-clear remains a non-goal.** `/clear` stays a deliberate user action. There is no
  hook that fires *before* `/clear` (verified — see Harness facts), and a skill cannot
  trigger `/clear`. "Checkpoint then clear" is inherently two user steps. We do not change that.
- **Auto-read is NOT the rejected auto-paste.** Auto-paste meant programmatically driving
  the TUI (brittle). Auto-read is a deterministic `cat RESUME.md` whose stdout the harness
  injects into the post-`/clear` context — a documented `SessionStart` capability, opt-in
  and gated. Different mechanism, not brittle.
- **`/checkpoint` extends, not duplicates, `session-handoff`.** `session-handoff` is
  chat-only and single-shot. `/checkpoint` adds: writes to a persistent file, *merges*
  with carried threads, trims to budget, and rolls detail into `CHANGELOG.md`. It MAY reuse
  the same six-part handoff structure for the "what happened this session" portion.

Still out of scope: daemonized idle detection; fixing Claude Code's structural resume cache
miss (PHASE-6's job); forcing per-turn writes via a `Stop` hook (rejected — too noisy).

---

## Harness facts (verified — do not re-derive or contradict)

From current Claude Code hooks docs (https://code.claude.com/docs/en/hooks.md), confirmed:

1. **`SessionStart` injects context.** A `SessionStart` hook's plain **stdout (exit 0)** is
   added to the model's context for the next request (not shown as a chat message).
   Alternatively, JSON `{"hookSpecificOutput":{"hookEventName":"SessionStart",
   "additionalContext":"..."}}` injects as a system reminder. Either works; **plain `cat`
   to stdout is simplest** and is what this plan uses.
2. **`SessionStart` matchers:** `startup` (fresh `claude`), `resume` (`-r`/`-c`),
   `clear` (after `/clear` wipes context), `compact` (after `/compact`). The `clear` matcher
   fires **after** the wipe — exactly the re-injection point we want.
3. **Auto-loading `RESUME.md` after `/clear` is supported and is the intended use of the
   `clear` matcher.** Minimal: `"command": "[ -f RESUME.md ] && cat RESUME.md || true"`.
4. **`PreCompact` cannot inject context** the agent will act on (no `additionalContext` in
   its schema) — it can only run a command or block. So we cannot use it to make the agent
   "write RESUME before compaction."
5. **No hook fires *before* `/clear`.** `SessionEnd` fires *after* the wipe and is
   observation-only (no agent turn after it). Therefore the write must be a deliberate
   pre-`/clear` step (the `/checkpoint` skill).
6. **`Stop` fires after every assistant turn**; can inject `additionalContext` (read next
   turn) or `block` to force more work. Per-turn forced writes are noisy/costly — not used.
7. **Skills/slash-commands cannot invoke built-in `/clear` or `/compact`.** "Checkpoint then
   clear" is two user actions, by construction.

---

## ccage-specific constraints (discovered on the authoring machine)

- **Per-project config dir.** Each `$PWD` → `~/.claude-<basename>` (sha1 fallback on
  basename collision; `--<slot>` suffix when `CCAGE_SLOT` set). See `_ccage_config_dir_for`
  in `share/claude-isolation.sh`.
- **`settings.json` and `hooks/` are NEVER shared.** Only `commands agents skills` are
  symlinked from `CCAGE_SHARE_FROM` (default unset; on this machine `=$HOME/.claude`) into
  each cage by `_ccage_share_dirs`. So:
  - A **skill** dropped in the master skills dir (`$CCAGE_SHARE_FROM/skills`, i.e.
    `~/.claude/skills/`) is live in every cage via the existing `skills` symlink — **install
    once, everywhere.**
  - A **hook** in `settings.json` is **per-cage** and must be seeded into each cage; it
    cannot live only in `~/.claude/settings.json`.
- **`~/.claude/CLAUDE.md` is read in caged sessions** (verified: loaded this session though
  `CLAUDE_CONFIG_DIR=~/.claude-autocast-private` has no `CLAUDE.md`). So the CLAUDE.md anchor
  can live there.
- **`_ccage_pre_exec_hook "$PWD" "$CONFIG_DIR"`** runs on **every** `claude` launch, after
  bootstrap, before `command claude` — the natural seeding point. It already seeds UI keys
  (e.g. `statusLine`) idempotently; ccage's rule is "seed only UI keys, never cache-bashing
  state." A `hooks` entry pointing at a **fixed script path** is static (doesn't rotate per
  request), so it does not bash the cache — a safe, documented exception to record.
- **`CCAGE_SLOT` is visible to hooks/skills.** It is a user-set env var inherited by the
  `claude` process and its hook subprocesses, so both the auto-read hook and the skill can
  read `$CCAGE_SLOT` directly.
- **Bypass caveat:** `timeout claude`, `nohup claude`, `xargs claude` skip the wrapper (run
  the real binary, no `CLAUDE_CONFIG_DIR`, no seeding). Acceptable — document it.

---

## Design

Seven components. Letters are referenced by the implementation phases.

### A. `/checkpoint` skill  → master skills dir (`$CCAGE_SHARE_FROM/skills/checkpoint/`)

A Claude Code skill (SKILL.md + optional bundled helper script). Vendored in the repo at
`share/skills/checkpoint/` and installed to the master skills dir by `install.sh`.

Auto-detects mode from repo state when invoked:

- **bootstrap** (no `RESUME.md`/`CHANGELOG.md` in repo root): create both from lean
  templates; add both to `.git/info/exclude` (NOT `.gitignore`); never overwrite.
- **checkpoint** (default; files exist): **merge** current state into `RESUME.md` —
  - read existing `RESUME.md`; **preserve carried/untouched threads** verbatim;
  - update threads that moved this session; add new decisions / open questions / live job IDs;
  - move completed or superseded detail into a dated `CHANGELOG.md` entry (newest-first,
    plain prose, **no AI/tool provenance**);
  - enforce the lean budget (cap ~3 session blocks / the budget header); overflow → CHANGELOG.
  - End by telling the user: "RESUME.md updated, CHANGELOG appended — safe to `/clear`."
- **`--tidy`** (deep clean; also implied when the health check flagged issues): the
  checkpoint **plus** memory hygiene for this cage — group `MEMORY.md` into sections, flag/
  prune stale or duplicate notes, fix dead index links. This part is **judgment** (agent
  work guided by the skill), not scripted; the skill describes the procedure.

**Slot-aware paths (component G).** All file paths are slot-scoped: write/read
`RESUME${CCAGE_SLOT:+.$CCAGE_SLOT}.md` and `CHANGELOG${CCAGE_SLOT:+.$CCAGE_SLOT}.md`.
No slot → plain `RESUME.md` / `CHANGELOG.md`.

Name: **`/checkpoint`** (decided). Templates and the budget definition live with the skill.

### B. Auto-read + health-check hook → `~/.claude/hooks/resume_autoload.sh`

A `SessionStart` hook (matchers `clear compact startup resume`). On every session (re)entry:

1. Compute the slot-aware RESUME path (component G).
2. If it exists, `cat` it to stdout (→ injected into context). If absent, print nothing.
3. **Health check (cheap, stdout one-liner only if something is wrong):**
   - RESUME over budget (line count > threshold, default ~250, or > ~3 session blocks) →
     `NOTE: RESUME is over budget — run /checkpoint to trim.`
   - Memory unorganized in this cage's memory dir
     (`$CLAUDE_CONFIG_DIR/projects/<pwd-slug>/memory/`): `MEMORY.md` missing `## ` section
     headers, OR memory file count exceeds index line count by > N (orphans), OR `MEMORY.md`
     references a missing file → `NOTE: memory needs tidying — run /checkpoint --tidy.`
   - Conservative heuristics — prefer a missed flag over a false nag.

Exit 0 always (never block a session start). Keep stdout small (RESUME is lean by budget).

### C. Budget-guard hook → vendor existing script into `share/hooks/resume_budget_check.sh`

The existing `~/.claude/hooks/resume_budget_check.sh` (PostToolUse, warns when RESUME exceeds
budget) is currently a loose file in no repo. **Vendor it into `share/hooks/`** so it ships +
is version-controlled, and have `install.sh` deploy it to `~/.claude/hooks/`. Make it
slot-aware (component G) to match B.

### D. Hook seeding → core ccage function in `share/claude-isolation.sh`

Add `_ccage_seed_session_docs_hooks "$CLAUDE_CONFIG_DIR"`, called from the `claude()` wrapper
(near `_ccage_bootstrap_dir`), **gated by opt-in `CCAGE_SESSION_DOCS`** (off by default, like
every ccage feature). It **idempotently merges** a `hooks` block into the cage's
`settings.json` (preserving existing keys — `statusLine`, `enabledPlugins`, `effortLevel`,
etc.) referencing the fixed scripts:

- `SessionStart` (matchers `clear compact startup resume`) → `~/.claude/hooks/resume_autoload.sh`
- `PostToolUse` (Write|Edit matcher) → `~/.claude/hooks/resume_budget_check.sh`

Merge in python3 (mirror `_ccage_patch_onboarding` / the statusLine seeding example): only
add the entry if absent; never clobber other keys. Runs every launch → **self-heals and
backfills** (existing cages pick it up on their next launch). Provide `CCAGE_NO_AUTOLOAD` /
`CCAGE_NO_BUDGET_HOOK` sub-opt-outs.

### E. CLAUDE.md anchor → `~/.claude/CLAUDE.md` (appended by `install.sh`, idempotent)

`install.sh` idempotently appends (guarded by a marker comment so re-runs are safe) a short
always-on block stating: the two files are local-only (excluded via `.git/info/exclude`),
read RESUME first on resume, run `/checkpoint` to maintain them, `--tidy` for memory hygiene.
Keep it short (a few lines) — CLAUDE.md must stay lean.

### F. `ccage doctor` → `bin/ccage` subcommand + `share/ccage-doctor.sh`

Mirror the `handoff` dispatch (`bin/ccage` → `share/ccage-handoff.sh`). A one-shot cross-cage
sweep that:

1. Iterates all `~/.claude-*/` config dirs: ensures the `hooks` block is seeded
   (deterministic, safe auto-fix) — this is the immediate **backfill** for the 44 existing cages.
2. Scans each cage's owning repo (`.owning_path`) for a bloated slot-aware `RESUME.md`, and
   each cage's memory dir for the "unorganized" heuristics from B.
3. Prints a **prioritized worklist**: which repos need `/checkpoint` (trim), which cages need
   `/checkpoint --tidy` (memory). Detection + safe auto-fix here; judgment fixes become a list
   you clear by visiting those repos. Support `--dry-run` (use `ccage-lib.sh`'s `run`).

### G. Slot-aware path rule (shared convention)

`RESUME.md` / `CHANGELOG.md` when `CCAGE_SLOT` unset; `RESUME.<slot>.md` /
`CHANGELOG.<slot>.md` when set. Implement identically in B, C, F, and the skill (A). It is a
one-liner each place (`${CCAGE_SLOT:+.$CCAGE_SLOT}`); do not over-engineer a shared runtime
lib (the hook/skill run as `claude` subprocesses and cannot easily source the wrapper).
Worktrees (different `$PWD`) already get distinct files for free — slot suffixing covers the
same-directory `CCAGE_SLOT` case.

---

## File / location map

| Component | Repo source | Installed to | Reaches every cage via |
|---|---|---|---|
| A `/checkpoint` skill | `share/skills/checkpoint/` | `$CCAGE_SHARE_FROM/skills/checkpoint/` | existing `skills` share-symlink |
| B auto-read hook | `share/hooks/resume_autoload.sh` | `~/.claude/hooks/resume_autoload.sh` | absolute path in seeded settings.json |
| C budget hook | `share/hooks/resume_budget_check.sh` | `~/.claude/hooks/resume_budget_check.sh` | absolute path in seeded settings.json |
| D seeding fn | `share/claude-isolation.sh` | `<rcd>/claude-isolation.sh` | runs per launch (gated by `CCAGE_SESSION_DOCS`) |
| E CLAUDE.md anchor | (text in `install.sh`) | `~/.claude/CLAUDE.md` | read directly in caged sessions |
| F `ccage doctor` | `bin/ccage` + `share/ccage-doctor.sh` | `<prefix>/bin/ccage` + `<prefix>/share/ccage/` | invoked manually |
| (per-repo) RESUME/CHANGELOG | n/a (created on demand) | `<repo>/RESUME[.slot].md` etc. | created by skill A |

---

## Implementation phases (TDD; bats first per subphase)

**P0 — Vendor + scaffold.** Move `resume_budget_check.sh` into `share/hooks/`; create
`share/hooks/resume_autoload.sh`; create `share/skills/checkpoint/SKILL.md` skeleton. No
behavior yet. Acceptance: files exist; `shellcheck` clean on the hooks.

**P1 — Slot-aware path helper + auto-read hook (B, G).** `resume_autoload.sh` cats the
slot-aware RESUME and emits health notes. Bats: temp repo with/without RESUME, with/without
`CCAGE_SLOT`, over/under budget, messy/clean memory dir → assert exact stdout. Mirror
`tests/test_slot.bats`.

**P2 — Seeding function (D).** `_ccage_seed_session_docs_hooks`, gated by `CCAGE_SESSION_DOCS`,
idempotent json merge preserving existing keys. Bats: empty settings.json, settings.json with
`statusLine`+plugins (assert preserved), already-seeded (assert no-op/no dup),
`CCAGE_SESSION_DOCS` unset (assert no-op), sub-opt-outs. Mirror `tests/test_bootstrap.bats`.

**P3 — `/checkpoint` skill (A).** SKILL.md: bootstrap (templates + `.git/info/exclude`,
no overwrite), checkpoint (merge + CHANGELOG roll + budget), `--tidy` (memory hygiene
procedure), slot-aware paths, no-AI-provenance in everything it writes. Bats where scriptable
(bootstrap creates files + exclude entries; idempotent re-run). Manually verify the merge/
trim judgment on a real bloated RESUME.

**P4 — install.sh wiring (B, C, E) + CLAUDE.md anchor.** Install hooks to `~/.claude/hooks/`;
install skill to master skills dir (resolve `CCAGE_SHARE_FROM`, default `~/.claude`);
idempotently append the CLAUDE.md anchor with a marker. Extend `tests/test_install_uninstall.bats`.
Honor `--dry-run`. Uninstall removes what it added (anchor block by marker; hooks; skill).

**P5 — `ccage doctor` (F).** Subcommand + `share/ccage-doctor.sh`: backfill seeding across all
cages, scan, print worklist; `--dry-run`. New `tests/test_doctor.bats`.

**P6 — Docs + opt-out table.** `docs/FEATURES.md` `[shipped]` entry (mirror its rule/Opt-out/
Config style); README opt-out rows; `CHANGELOG.md` entry (no AI provenance). Update
`docs/PLAN.md` status if it tracks phases.

**P7 — End-to-end validation.** With `CCAGE_SESSION_DOCS=1`, in a scratch repo: `/checkpoint`
(bootstrap) → edit → `/checkpoint` (merge) → `/clear` → confirm RESUME auto-loaded into the
fresh context. Run `ccage doctor` and confirm the 44 cages get the hooks block. Extend
`tests/validate-e2e.sh`.

---

## Opt-out / config env vars (add to FEATURES.md + README table)

- `CCAGE_SESSION_DOCS=1` — **master opt-in** for the whole feature (seeding). Off by default.
- `CCAGE_NO_AUTOLOAD=1` — seed the budget hook but not the SessionStart auto-read.
- `CCAGE_NO_BUDGET_HOOK=1` — seed auto-read but not the budget guard.
- `CCAGE_RESUME_BUDGET_LINES` — RESUME budget threshold (default ~250) for B/C/F.
- Slot behavior follows existing `CCAGE_SLOT`.

## Conventions to follow (ccage bar)

- bash/zsh compatible; `shellcheck` clean; `set -u`-safe array idioms (see the wrapper's
  `${arr[@]+"${arr[@]}"}`); idempotent; `--dry-run` via `ccage-lib.sh`'s `run`.
- Every settings.json write **merges**, never overwrites — preserve `statusLine`,
  `enabledPlugins`, `effortLevel`, `skipDangerousModePermissionPrompt`, etc.
- bats test per component, mirroring `tests/*.bats` (`load helpers`, `BATS_TEST_TMPDIR`).
- **No AI/tool provenance** in any committed text, the CHANGELOG, the CLAUDE.md anchor, or
  anything the skill writes into user repos. Author as the repo owner.
- Don't put `memory/`, `projects/`, `settings.json`, `plugins/`, `hooks/` in the master
  share dir (breaks isolation) — hooks reach cages via seeding, not sharing.

## Risks / edge cases

- **Slot same-dir CHANGELOG concurrency.** Two slots in one dir append to distinct
  `CHANGELOG.<slot>.md`, so no interleave. If a shared CHANGELOG is ever wanted, guard appends
  with `flock`. RESUME is slot-scoped → no clobber.
- **Health-check false nags.** Tune thresholds conservatively; gate memory checks behind clear
  signals (missing headers / dead links), not vague counts alone.
- **Seeding must merge.** A naive overwrite would wipe `statusLine`/plugins/effort. Test this
  explicitly (P2).
- **Non-caged fallback.** Keep the same hooks in `~/.claude/settings.json` too (for
  `CCAGE_DISABLE` / `timeout claude` paths); both reference the same `~/.claude/hooks/*` scripts.
- **SessionStart stdout size.** The budget keeps RESUME small enough to inject every start
  cheaply; the health check adds at most a couple of lines.

## Definition of done

- `/checkpoint` → `/clear` → state auto-loaded, with **no copy and no paste**, in a caged repo.
- `ccage doctor` backfills the hooks block into all existing cages (resurrecting the budget
  hook) and prints a correct bloat/memory worklist.
- Worktree and `CCAGE_SLOT` same-dir parallel sessions keep separate, non-clobbering
  RESUME/CHANGELOG.
- All bats green; `validate-e2e.sh` extended; FEATURES/README/CHANGELOG updated; everything
  opt-in via `CCAGE_SESSION_DOCS`; uninstall reverses cleanly.

## Decisions already settled (from scoping)

- Build **in ccage** (portable, versioned, ships everywhere) — not loose `~/.claude` files.
- Command name **`/checkpoint`**. **No** `Stop`-hook nudge (rejected as noise).
- **Auto-read, not auto-clear**; `/clear` stays manual (two-step is the floor).
- Memory hygiene is **detected-and-routed** (health check → `/checkpoint --tidy`), not
  fully automated — grouping/pruning is judgment.
- Feature is **opt-in** via `CCAGE_SESSION_DOCS`, consistent with ccage's everything-opt-in ethos.
