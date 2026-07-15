# Seeding the user's own hooks into every cage (`CCAGE_SEED_LOCAL_HOOKS`)

**Status: implemented on branch `feat/seed-local-policy-hooks`, tests green, NOT released.**
Written 2026-07-15 by the StrategyA session that found the bug. Release is the user's call.

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
`settings.json` every hook entry that **registers a script under `~/.claude/hooks`**.

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

## The subtle bug worth keeping

The first cut of this logic **matched the absolute hook path** and therefore **silently
skipped every tilde-form registration** — including the orchestration gate, i.e. the single
most important thing it exists to propagate. The user's `settings.json` writes
`bash ~/.claude/hooks/x.sh`; the cages carry the expanded form.

It was caught only because the implementation was **dry-run before being believed**. There is
a regression test for exactly this (`tilde-form registrations are expanded, not silently
skipped`), and commands are normalised to absolute paths on write.

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

**So this ccage change is not needed to fix today — it is needed so tomorrow's new cage is
born correct.** That standalone script stays useful as a manual backfill/audit tool and is
deliberately NOT vendored into ccage.

The hooks being propagated (all user-owned, listed for context only — ccage hardcodes none):

| hook | event | what it does |
|---|---|---|
| `orchestrator_check.sh` | UserPromptSubmit | re-injects the orchestration gate each turn |
| `agent_reaper.sh` | PreCompact, SessionEnd | names agents left running at a context boundary (a `/clear` orphaned 8 agents; `SessionEnd` **cannot block**, so it records names into RESUME instead) |
| `write_set_guard.sh` | PreToolUse Write\|Edit | blocks a 2nd subagent writing another's file, and blocks any subagent writing an artifact listed in `.claude-single-writer` |
| `teammate_idle_guard.sh` | TeammateIdle | nags a teammate only about work already assigned to it |
| `task_completed_guard.sh`, `code_hygiene_check.sh`, `clutter_guard.sh`, `xpu-guard.sh` | various | pre-existing local guards |

---

## What ccage needs to do

1. **Review** `share/claude-isolation.sh` (`_ccage_seed_local_hooks` + its one call site) and
   `tests/test_seed_local_hooks.bats`.
2. **Run `tests/ci-local.sh`** (was green here; re-run in a clean tree).
3. **Decide the default.** It is currently **opt-in**, matching `CCAGE_SESSION_DOCS`. Given
   the evidence above, consider whether opt-in is right, or whether it should follow
   `CCAGE_SESSION_DOCS` — a policy the user believes is global being live in half their
   projects is precisely the failure this fixes, and an opt-in flag they forget to set
   reproduces it.
4. **Docs:** add to `FEATURES.md` and the env-var table wherever `CCAGE_SESSION_DOCS` is
   documented.
5. **Release** via the normal branch → PR → `ci-local` → merge → tag → GitHub release flow.
6. Consider whether `ccage doctor` should **report** cages whose registrations drift from the
   user's `settings.json` — the standalone script's dry-run already prints exactly that, and
   `_ccage_doctor_seed` in `share/ccage-doctor.sh` is the existing precedent (**note its
   "KEEP IN SYNC" comment — this change may need a doctor-side twin**).
