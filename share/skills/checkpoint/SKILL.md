---
name: checkpoint
description: >-
  Write a session checkpoint into RESUME.md (and roll older detail into
  CHANGELOG.md) so state survives /clear — ccage's SessionStart hook auto-reads
  RESUME.md back into the next context, so the loop becomes /checkpoint → /clear
  → (state reloaded), with no copy and no paste. Use before /clear, before a
  context boundary or compaction, when the user says "checkpoint", "save
  progress", "snapshot state", "update RESUME", or "hand off"; to bootstrap
  RESUME.md + CHANGELOG.md in a repo that has none; or with --tidy to also
  reorganize this cage's memory directory.
---

# /checkpoint

One command that keeps a durable, lean `RESUME.md` so a session's state survives
`/clear`. ccage seeds a `SessionStart` hook (`resume_autoload.sh`) that `cat`s
`RESUME.md` into the model's context on every (re)entry — including right after
`/clear`. So the workflow is just:

```
/checkpoint      # write current state into RESUME.md, roll detail into CHANGELOG.md
/clear           # deliberate; wipes context
                 # → RESUME.md is auto-read back into the fresh context
```

You (the agent) do the writing. This skill tells you exactly what to write and
where. **Two commands, zero lossy copy/paste.**

---

## 0. Resolve slot-aware paths (always do this first)

`RESUME`/`CHANGELOG` are **slot-scoped** so parallel same-directory sessions
(`CCAGE_SLOT`) never clobber each other. Compute the filenames with the same
validation the ccage wrapper uses (an unsafe slot falls back to the plain file):

```bash
slot=""
case "${CCAGE_SLOT:-}" in
  "" ) ;;
  *[!A-Za-z0-9_-]* ) ;;          # unsafe → ignore, use plain files
  * ) slot=".${CCAGE_SLOT}" ;;
esac
resume="RESUME${slot}.md"
changelog="CHANGELOG${slot}.md"
```

Use `$resume` and `$changelog` everywhere below. Worktrees already get distinct
files for free (different working directory); the slot suffix covers the
same-directory case.

---

## 1. Pick the mode

- **bootstrap** — neither `$resume` nor `$changelog` exists → create both from
  the lean templates in §2, then exclude them locally (§2.3). **Never overwrite.**
- **checkpoint** (default) — files exist → merge current state into `$resume`
  and roll superseded detail into `$changelog` (§3).
- **`--tidy`** — do the checkpoint, then also tidy this cage's memory dir (§4).
  Run `--tidy` when the user asks, or when the SessionStart health check printed
  `NOTE: memory needs tidying`.

---

## 2. Bootstrap (no RESUME/CHANGELOG yet)

### 2.1 Create `$resume` from this lean template

Fill in the angle-bracket placeholders from the current session. Keep it short —
the budget is **≤ 3 `## Session` blocks and ≤ ~250 lines**; anything older lives
in `$changelog`.

```markdown
# RESUME — <project name>

<!-- ccage budget: keep lean. Update the State sections in place; keep at most
     ~3 ## Session blocks — roll older ones into CHANGELOG. RESUME is auto-read
     into context on every session start, so smaller = cheaper + sharper. -->

## State

### Now
- <the single thing in flight right now>

### Threads
- <open workstream> — <status>

### Decisions
- <settled choice worth remembering>

### Open questions
- <unresolved question that needs an answer>

### Live jobs
- <background job id / PR # / CI run, or "none">

## Session <YYYY-MM-DD>
<2–5 sentences: what happened, where it stands, the obvious next step.>
```

### 2.2 Create `$changelog` from this template (only if absent)

If a real project `CHANGELOG.md` already exists (a user-facing changelog), do
**not** clobber it — append your dated entry under its newest section instead.
Only create one when there is none:

```markdown
# Changelog

Newest first.

## <YYYY-MM-DD>
- <detail rolled out of RESUME, in plain prose>
```

### 2.3 Exclude both locally — `.git/info/exclude`, NOT `.gitignore`

These are personal continuity files; keep them out of the repo without editing
the shared `.gitignore`. Only in a git repo, and only if not already excluded:

```bash
if git rev-parse --git-dir >/dev/null 2>&1; then
  ex="$(git rev-parse --git-dir)/info/exclude"
  for f in "$resume" "$changelog"; do
    grep -qxF "$f" "$ex" 2>/dev/null || printf '%s\n' "$f" >> "$ex"
  done
fi
```

(If `$changelog` is a pre-existing tracked project changelog, do not exclude it.)

Then tell the user the files were created and they are safe to `/clear`.

---

## 3. Checkpoint (merge — the common case)

The goal is a **merge**, not a rewrite. Read `$resume` first and preserve what is
still true.

1. **Read `$resume`.** Keep every carried/untouched thread, decision, and open
   question **verbatim** unless this session changed it.
2. **Update in place** the `### Now / ### Threads / ### Decisions /
   ### Open questions / ### Live jobs` lines that moved this session. Add new
   decisions, new open questions, and new live job IDs (PRs, CI runs, background
   tasks). Remove items that are now done or moot (their detail goes to CHANGELOG).
3. **Prepend a new `## Session <YYYY-MM-DD>` block** with a 2–5 sentence
   narrative of what happened this session and the next obvious step. Put it
   directly below the `## State` section, above older session blocks.
4. **Enforce the budget.** If there are now more than **3** `## Session` blocks
   (or `$resume` exceeds ~250 lines), move the **oldest** session block(s) and
   any superseded detail into `$changelog` as a dated entry (newest-first, plain
   prose). RESUME stays lean; history accumulates in CHANGELOG.
5. **Write `$resume` and append to `$changelog`.**
6. **End by telling the user:** `RESUME updated, CHANGELOG appended — safe to /clear.`

Use the same six-part structure as a `session-handoff` brief for the per-session
narrative if helpful — but `/checkpoint` differs in that it writes a persistent,
merged, budget-trimmed file rather than a one-shot chat message.

---

## 4. `--tidy` — memory hygiene (judgment, not a script)

After the checkpoint, tidy **this cage's** memory directory:

```bash
memdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/${PWD//\//-}/memory"
```

Then, using judgment:

- **Group `MEMORY.md` into `## ` sections** (e.g. by topic: user, feedback,
  project, reference) instead of one flat list, if it has grown unwieldy.
- **Prune stale or duplicate notes** — if two files cover the same fact, merge
  them and delete the loser; delete notes that are now wrong.
- **Fix dead index links** — every `[Title](file.md)` in `MEMORY.md` must point
  at a file that exists; every memory file should be linked from the index
  (no orphans).

Only touch the **current cage's** memory dir — never another cage's. Do not
invent facts; reorganize and prune what is there.

---

## Rules for everything this skill writes

- **No AI / tool provenance.** RESUME, CHANGELOG, memory notes, and exclude
  entries are authored **as the repo owner**. Never mention AI, assistants,
  agents, "generated with", or co-authoring anywhere.
- **Never overwrite blindly.** Bootstrap only creates absent files; checkpoint
  merges, preserving carried state.
- **Slot-scoped paths always** (§0). Plain `RESUME.md`/`CHANGELOG.md` when
  `CCAGE_SLOT` is unset.
- **Lean is the point.** RESUME is injected into context on every session start;
  every line costs tokens on every start. When in doubt, move detail to CHANGELOG.
