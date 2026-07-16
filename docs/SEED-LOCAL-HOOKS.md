# Seeding the user's own hooks into every cage (`CCAGE_SEED_LOCAL_HOOKS`)

**Status: implemented + released in v0.12.0.**
Written 2026-07-15 by the StrategyA session that found the bug. Release is the user's call.

> **2026-07-16 addendum — the user has taken this up for release.** Read
> **"2026-07-16 — the design got tested in the wild, and it was right"** below before
> reviewing: the interim hand-maintained workaround on the author's machine **failed in
> exactly the way this branch is designed to prevent**, which settles the one real design
> question (derive the hook list; never allowlist it). It also lists two things release day
> must handle: the opt-in flag is **already exported** (so the feature arms itself the moment
> this installs), and a **second seeder is currently live** and must be removed at release.
> ✅ **Tests re-verified 2026-07-16 on the author's machine:** `tests/test_seed_local_hooks.bats`
> **13/13 green**, and the **full `bats tests/` suite exits 0** (tests numbered through 253, no
> failures). Run via the repo's **vendored** runner `./tests/bats/bin/bats` — note `which bats`
> finds nothing, so a PATH check reports a false negative. *(Not run: the rest of
> `tests/ci-local.sh` — shellcheck/ruff/pytest — do that in a clean tree before release.)*

---

## The bug, stated plainly

**A hook script under `~/.claude/hooks` does nothing until some `settings.json` registers
it — and every cage has its own `settings.json`.**

ccage seeds only *its own* session-docs hooks (`_ccage_seed_session_docs_hooks`:
`resume_autoload`, `resume_budget_check`). A user's own policy hooks were never seeded. So
they reached a cage **only if somebody hand-edited that cage**, and **every new cage was born
without them**.

That is not a theoretical gap. Measured on the author's machine, 2026-07-15:

| | |
|---|---|
| cages with a `settings.json` | **71** |
| …registering the user's per-turn orchestration gate | **34** |
| cages used within the last 30 days | 37 |
| …with no gate at all | **8** |
| new cages that would get it | **0** |

Meanwhile the policy file those hooks enforce (`~/.claude/CLAUDE.md`) stated:

> *"This gate fires on every turn — a `UserPromptSubmit` hook re-injects it, so it survives
> mid-session drift."* … *"this policy is inherited by every single project."*

**Both false, and nothing could have noticed** — the hook file existed, the rule was written
down, and the registration silently wasn't there. A control that is real in the file and
absent in effect.

---

## What the change does

`_ccage_seed_local_hooks "$CLAUDE_CONFIG_DIR"` — called from the same place as the
session-docs seeder, so it runs **every launch**, self-heals, and backfills existing cages.

It reads the user's real `~/.claude/settings.json` and merges into the cage's
`settings.json` **every hook that registers a script under `~/.claude/hooks`** — judged
**one hook at a time**, not one *entry* at a time. A matcher group carrying N hooks is split
into N single-hook entries on the way in (see "The subtle bug worth keeping" below); two
single-hook entries sharing a matcher behave identically to one entry with two hooks.

### The ownership line this deliberately respects

**ccage owns cage WIRING. The policy CONTENT is the user's.** So:

- registrations are copied **from the user's own settings.json**; **no hook name is
  hardcoded** — exactly as `CCAGE_SHARE_DIRS` shares `commands/agents/skills` without owning
  what is in them;
- **ccage's own hooks are skipped** (`resume_autoload.sh`, `resume_budget_check.sh`,
  `autonomous_ask_guard.sh`). `_ccage_seed_session_docs_hooks` seeds those and has its own
  opt-outs (`CCAGE_NO_AUTOLOAD`, `CCAGE_NO_BUDGET_HOOK`); copying them here would **silently
  override a deliberate `--no-session-docs`**;
- anything **not** under the hooks dir (an inline `curl` notification integration, say) is
  **not ccage's to spread** and is left alone.

This keeps faith with the library's existing principle against *"silently tightening a user's
CLAUDE.md"*: ccage still decides nothing about what the policy says.

### Flags

| Flag | Meaning |
|---|---|
| `CCAGE_SEED_LOCAL_HOOKS=1` | **opt-in.** Off by default — it changes hook behaviour in every cage. |
| `CCAGE_LOCAL_HOOKS_SRC` | source settings (default `$HOME/.claude/settings.json`). |
| `CCAGE_HOOKS_DIR` | which dir counts as "the user's hooks" (default `$HOME/.claude/hooks`). |

### Safety properties (each has a test)

- **idempotent** — dedups on script basename, same as the session-docs seeder;
- **never clobbers** a present-but-unparseable `settings.json` (Claude Code rejects it too —
  leave it for the user);
- **preserves** every unrelated key and every pre-existing hook;
- **atomic** write via `mkstemp` + `os.replace`, mode preserved;
- **no-op** when the source is missing, or when source == target (uncaged).

---

## The subtle bugs worth keeping

**Both are the same species: a filter that silently skips the thing it exists to propagate,
while every check reports success.** That is this seeder's characteristic failure — it has now
happened twice — so distrust any green result here that you have not dry-run.

**1 — the tilde form.** The first cut **matched the absolute hook path** and therefore
**silently skipped every tilde-form registration** — including the orchestration gate, i.e. the
single most important thing it exists to propagate. The user's `settings.json` writes
`bash ~/.claude/hooks/x.sh`; the cages carry the expanded form. Caught only because the
implementation was **dry-run before being believed**. Regression test: `tilde-form
registrations are expanded, not silently skipped`; commands are normalised on write.

**2 — only the first hook in a matcher group.** The second cut judged each entry by its
**first** hook (`name = script_base(cmds[0])`), so hook #2+ in a group were invisible: never
named, never checked, never seeded. Measured 2026-07-15 — a new `commit_provenance_guard.sh`
registered as a *second* hook on the existing `PreToolUse: Bash` group (beside `xpu-guard.sh`)
reached **zero of 71 cages**, while the companion sync script reported **"already complete:
37"**. It was telling the truth about `xpu-guard` and nothing at all about the new guard. A
false all-clear is worse than a red one: nobody re-checks a control that reported success.
Fixed by splitting each group into single-hook entries at the boundary, so the `[0]` indexing
downstream is correct *by construction* rather than by luck. Regression tests: `EVERY hook in a
multi-hook matcher group is seeded, not just the first` · `a second hook is seeded even when the
first is already present` · `a group mixing a ccage-owned hook with a user hook seeds the user's
half` — all three proven to FAIL before the fix.

⚠️ **The same bug existed independently in `~/.claude/scripts/sync_cage_hooks.py`**, which is
the user's backfill tool for existing cages. Two implementations of one idea, one shared blind
spot. If you change entry-identification here, check there too.

---

## Tests

`tests/test_seed_local_hooks.bats` — 10 tests, all green:

```
ok 1 opt-out (unset): no-op, settings.json not created
ok 2 opt-in: a local hook is seeded into the cage
ok 3 tilde-form registrations are expanded, not silently skipped
ok 4 ccage's own session-docs hooks are NOT copied (they have their own opt-outs)
ok 5 hooks that are not ours (inline commands) are not spread
ok 6 idempotent: second run adds no duplicate
ok 7 preserves existing unrelated keys and existing hooks
ok 8 never clobbers a present-but-unparseable settings.json
ok 9 missing source settings: no-op
ok 10 source == target (uncaged): no-op, never seeds a file from itself
```

---

## What is already done OUTSIDE ccage (so it is not re-done here)

The author's 71 cages were **already backfilled by hand** on 2026-07-15 using a standalone
script (`~/.claude/scripts/sync_cage_hooks.py`, dry-run by default, per-file backups,
JSON re-validated after every write, auto-rollback). Coverage went **29/37 → 37/37** live
cages for the gate, and 1/37 → 37/37 for two new guards.

**Re-measured 2026-07-16: 71/71 cages now carry all 13 policy hooks** (0 unparseable, 0
duplicate registrations), after a second `--apply` sweep that also picked up the 35 cages
which were dormant (>30d) and therefore missed by the `--live-days 30` pass. *(The count was
12 earlier the same day; `poll_loop_guard.sh` was added afterward and reached all 71 by
re-running the sweep with no list edited — the live proof that deriving the list from
`settings.json` works.)*

**So this ccage change is not needed to fix today — it is needed so tomorrow's new cage is
born correct.** That standalone script stays useful as a manual backfill/audit tool and is
deliberately NOT vendored into ccage.

The hooks being propagated (all user-owned, listed for context only — ccage hardcodes none):

| hook | event | what it does |
|---|---|---|
| `orchestrator_check.sh` | UserPromptSubmit | re-injects the orchestration gate each turn |
| `agent_reaper.sh` | PreCompact, SessionEnd | names agents left running at a context boundary (a `/clear` orphaned 8 agents; `SessionEnd` **cannot block**, so it records names into RESUME instead) |
| `write_set_guard.sh` | PreToolUse Write\|Edit | blocks a 2nd subagent writing another's file, and blocks any subagent writing an artifact listed in `.claude-single-writer` |
| `subagent_foreground_guard.sh` | PreToolUse Bash | **denies `run_in_background: true` to a subagent** (fires on `agent_id`, which is subagent-only; the main thread is never blocked). A subagent's turn ENDS when it stops making tool calls, so a background task's completion notification has no idle agent to wake — it "waits" forever and its artifact is never written. Destroyed four workers' output in one session, two of which carried an explicit "do not idle" clause in their brief. **Added 2026-07-15 18:04 — i.e. AFTER this doc's table was first written, which is exactly the drift described below.** |
| `commit_provenance_guard.sh` | PreToolUse Bash | strips/blocks AI provenance in commits |
| `poll_loop_guard.sh` | PreToolUse Bash | logs (observe mode; denies nothing yet) foreground `until … sleep … done` poll-loops that freeze the session — the measured cause of "background job started in foreground, session blocked." **Added 2026-07-16, later than the two guards above — again reaching all 71 cages with no list edit, because the seeder derives from `settings.json`.** |
| `task_completed_guard.sh`, `code_hygiene_check.sh`, `clutter_guard.sh`, `xpu-guard.sh` | various | pre-existing local guards (⚠️ `task_completed_guard.sh` was found broken + fixed 2026-07-16 — see §3 below) |

---

## 2026-07-16 — the design got tested in the wild, and it was right

Three findings from the author's machine the day after this branch was written. The first is
**direct empirical support for the central design decision** (hardcode no hook names); the
other two are things **release day must account for**.

### 1. The hardcoded-list failure mode actually happened — this is why "derive, never list" is load-bearing

While this branch sat unreleased, the same job was being done on the author's machine by a
**hand-maintained list** inside `_ccage_pre_exec_hook` (`~/.bashrc.d/claude-overrides.sh`,
the personal companion file this repo's extension model sanctions). It seeded a hardcoded
list of **6** hooks.

By 2026-07-16 the user's `~/.claude/settings.json` had grown to **12** policy-hook registrations
(11 distinct scripts — `agent_reaper.sh` is registered on two events, `SessionEnd` and
`PreCompact`; counts here are **registrations**, which is what a seeder actually copies). The
list still said 6. **Nobody updated it, and nothing could notice.**

The six registrations it missed, exactly:

| event | script |
|---|---|
| `PreToolUse` | `subagent_foreground_guard.sh` ← **the one that mattered** |
| `PreToolUse` | `write_set_guard.sh` |
| `PreToolUse` | `commit_provenance_guard.sh` |
| `PreToolUse` | `xpu-guard.sh` |
| `SessionEnd` | `agent_reaper.sh` |
| `PreCompact` | `agent_reaper.sh` |

Among the six it silently missed: **`subagent_foreground_guard.sh`** — written the previous
evening, *after* the failure it prevents had destroyed four workers' output in a single
session. The guard existed. It was registered in the user's own `settings.json`. It was
correct, tested, and enforcing. **And it reached zero new cages**, because the thing that
copies hooks into cages had never heard of it.

That is this document's own thesis, one level in: *a control that is real in the file and
absent in effect*. The lesson generalises past hooks:

> **A hand-maintained list is not a mechanism. It drifts, and it drifts toward less safety** —
> because the list is updated by whoever remembers, while the thing being listed is added by
> whoever is fixing an incident at the time. The safest hook is the newest one, and the newest
> one is exactly the one the list lacks.

`_ccage_seed_local_hooks` hardcodes no hook names and copies whatever the user's
`settings.json` registers. **Do not "simplify" that into an allowlist at review.** The
allowlist is the bug.

*(Interim fix on the author's machine, pending this release: the hardcoded list was deleted
and `_ccage_pre_exec_hook` now shells out to `sync_cage_hooks.py --cage "$CLAUDE_CONFIG_DIR"
--apply --quiet`, which derives the list the same way this branch does. See item 2.)*

### 2. Release-day: `CCAGE_SEED_LOCAL_HOOKS=1` is ALREADY EXPORTED, and a second seeder is live

Two things are already true on the author's machine **before** this branch ships:

- **`export CCAGE_SEED_LOCAL_HOOKS=1` is already in `~/.bashrc`.** It is a **no-op today** —
  the installed `~/.bashrc.d/claude-isolation.sh` predates this branch and defines no such
  function (verified by grep across `~/.bashrc.d`, `~/.local/{bin,share}`, `~/.claude`: zero
  readers). **The moment this branch is installed, the feature activates with no further
  action.** That is fine, but it means "opt-in" is not a meaningful safety margin *here* — the
  opt-in is pre-set. Weigh that in step 3 below.
- **A second seeder will exist**: `_ccage_pre_exec_hook` calls `sync_cage_hooks.py --cage ...`
  on every launch. Post-release both run. **This is safe** — both are idempotent, both dedup
  on the script basename, and both skip the ccage-owned hooks — so the second simply finds
  nothing missing. But it is redundant work on every launch. **At release, delete the
  `sync_cage_hooks.py --cage` call from `~/.bashrc.d/claude-overrides.sh`** and let ccage own
  it. The standalone script stays for manual backfill/audit.
- `sync_cage_hooks.py` gained `--cage DIR` (one cage, creates `settings.json` if absent) and
  `--quiet` (print only changes/failures) to serve that per-launch call. If ccage takes over
  the launch path, those flags remain useful for `ccage doctor`-style auditing.

### 3. Propagation amplifies a broken guard — the ownership line cuts both ways

`task_completed_guard.sh` (row 5 of the table above, "pre-existing local guard") **was broken
the whole time it was being propagated.** It decided whether a dependency was still open by
asking *does its file exist* — but completed task files **persist on disk carrying
`{"status": "completed"}`** (verified 2026-07-16 across every cage). So once a blocker
finished, any task with a `blockedBy` edge became **permanently uncompletable**, and the
refusal read like a legitimate dependency error. Fixed 2026-07-16 to read `status`; 7/7
regression tests.

No action for ccage's code — the hook is user content, and **ccage owning wiring but not
content is the right line**. But it is worth stating plainly in the release notes: **seeding
is an amplifier.** It makes a good guard universal and a broken guard universal on the same
day, with the same silence. That is an argument *for* shipping this (a fix now propagates
too) and *for* `ccage doctor` reporting drift (step 6) — not against it.

---

## What ccage needs to do

1. **Review** `share/claude-isolation.sh` (`_ccage_seed_local_hooks` + its one call site) and
   `tests/test_seed_local_hooks.bats`. ✅ Re-verified 2026-07-16: **13/13 green** via the
   repo's **vendored** runner, `./tests/bats/bin/bats tests/test_seed_local_hooks.bats`.
   *(Worth knowing: `which bats` finds nothing on this machine — the runner is vendored at
   `tests/bats/`, exactly as `tests/ci-local.sh:63` invokes it. A `which bats` check reports a
   false negative and will tell you the suite is unrunnable when it is not.)* ✅ **Done.**
2. **Run `tests/ci-local.sh`** (was green here; re-run in a clean tree).
3. **Decide the default.** It is currently **opt-in**, matching `CCAGE_SESSION_DOCS`. Given
   the evidence above, consider whether opt-in is right, or whether it should follow
   `CCAGE_SESSION_DOCS` — a policy the user believes is global being live in half their
   projects is precisely the failure this fixes, and an opt-in flag they forget to set
   reproduces it.
4. **Docs:** add to `FEATURES.md` and the env-var table wherever `CCAGE_SESSION_DOCS` is
   documented. ✅ **Done.**
5. **Release** via the normal branch → PR → `ci-local` → merge → tag → GitHub release flow.
6. Consider whether `ccage doctor` should **report** cages whose registrations drift from the
   user's `settings.json` — the standalone script's dry-run already prints exactly that, and
   `_ccage_doctor_seed` in `share/ccage-doctor.sh` is the existing precedent (**note its
   "KEEP IN SYNC" comment — this change may need a doctor-side twin**). The 2026-07-16 drift
   incident is the argument for it: the gap was invisible for a day precisely because nothing
   reported it. ✅ **Done.**
7. ✅ **DONE at release (v0.12.0, 2026-07-16): the interim second seeder was removed.** Delete the
   `sync_cage_hooks.py --cage "$config_dir" --apply --quiet` call from
   `~/.bashrc.d/claude-overrides.sh` (`_ccage_pre_exec_hook`) — ccage takes over that job.
   Harmless if forgotten (both seeders are idempotent and dedup on basename), just redundant
   work on every launch. **Do not also delete the `statusLine`/`env` seeding in that same
   function — that is unrelated and still needed.**
8. **Sanity-check the install path.** `install.sh`'s `install_file()` is a bare `cp` with **no
   backup** — it overwrites `~/.bashrc.d/claude-isolation.sh` in place. For a file sourced by
   every interactive shell, consider writing a `.pre-update-<stamp>` backup first (there is
   precedent on the author's machine: `claude-isolation.sh.pre-update-20260523-125144`, so
   *something* did this once). A syntax error shipped here breaks every new shell, not just
   Claude Code. ✅ **Done.**
