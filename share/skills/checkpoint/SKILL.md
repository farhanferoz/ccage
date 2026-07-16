---
name: checkpoint
description: >-
  Save session state into RESUME.md (rolling older detail into CHANGELOG.md) so
  it survives /clear — ccage's SessionStart hook auto-reads RESUME.md back on the
  next start, with no copy/paste. Also snapshots the task list and live
  jobs/monitors so they can be re-armed on resume. Use before /clear or a
  compaction, or when the user says "checkpoint", "save progress", "snapshot
  state", or "update RESUME"; bootstraps RESUME.md + CHANGELOG.md in a repo that
  has none. Flags: --final marks the session genuinely done (writes the
  .ccage-session-done marker so /keepwarm and ccage-auto stand down); --tidy also
  tidies this cage's memory dir; --merge-slots collapses parallel
  RESUME.<slot>.md files into the plain trunk.
effort: medium
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

This skill runs at **`medium` effort** (pinned in frontmatter, regardless of the
session's `/effort`). A checkpoint is distillation, not hard reasoning — `medium`
keeps the summary sharp while avoiding the large thinking budgets of
`high`/`xhigh`/`max`. **Efficiency here comes from doing _less work_ (fewer
round-trips, no proactive archival), not from thinking less.** Two use cases:

- **Mid-work** (`/checkpoint`): the lean path in §3 — touches only `$resume` /
  `$changelog`, reuses what's already in context, finishes in ~2–3 tool calls.
- **Close of day** (`/checkpoint --tidy`): the same lean checkpoint **plus** memory
  hygiene (§4). `--tidy` _is_ the close ritual; there is no separate `--close`.

---

## 0. Resolve slot-aware paths

`RESUME`/`CHANGELOG` are **slot-scoped** so parallel same-directory sessions
(`CCAGE_SLOT`) never clobber each other.

**Fast path (the common case):** if `CCAGE_SLOT` is unset, the files are just
`RESUME.md` and `CHANGELOG.md` — use those directly and **skip the shell block
below**. It's one avoidable round-trip at the exact moment context is largest.
Only when `CCAGE_SLOT` is set do you compute the suffix, with the same validation
the ccage wrapper uses (an unsafe slot falls back to the plain file):

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

- **bootstrap** — `$resume` does not exist → create it from the lean template in
  §2 (and `$changelog` too, unless the repo already has a real `CHANGELOG.md` —
  see §2.2), then exclude them locally (§2.3). **Never overwrite.** Keyed on
  `$resume` alone: a repo with a project CHANGELOG but no RESUME still
  bootstraps.
- **checkpoint** (default, mid-work) — `$resume` exists → merge current state into
  `$resume` the **lean** way (§3): reuse the in-context copy, update in place,
  refresh today's session block, and roll to `$changelog` only if over budget.
  Touches only the continuity files, not memory. Also clears any
  `.ccage-session-done` marker (§6) — a plain checkpoint means "still working."
- **`--final`** (work is genuinely done) — do the lean checkpoint, **then** write
  the `.ccage-session-done` marker (§6). This is the only mode that writes it; use
  it when the session's actual task is complete and you're winding down for real,
  not for a routine mid-work save. It's what lets background helpers stop:
  `/keepwarm` self-stops on its next wake and `ccage-auto` stands down instead of
  running its checkpoint→clear loop all night. Combine with `--tidy` when closing
  the day for good (`--final --tidy`): both run, in that order.
- **`--tidy`** (close of day) — do the lean checkpoint, **then** tidy this cage's
  memory dir (§4). This is the session-close ritual; there is no separate
  `--close`. Run it when the user wraps up, asks to tidy, or the SessionStart
  health check printed `NOTE: memory needs tidying`. Cheap when memory is already
  clean (§4 bails early).
- **`--merge-slots`** — fan-in: collapse every parallel `RESUME.<slot>.md` back
  into the plain `RESUME.md` trunk (§5), so a future slotless session reads the
  union. Run when the parallel slotted sessions are done. This mode does **not**
  also checkpoint the current session — checkpoint first if you have unsaved
  state, then merge.

---

## 2. Bootstrap (no RESUME/CHANGELOG yet)

### 2.1 Create `$resume` from this lean template

Fill in the angle-bracket placeholders from the current session. Keep it short —
the budget is **≤ 3 `## Session` blocks, ≤ ~250 lines, and ≤ ~14 KB**; anything
older lives in `$changelog`.

```markdown
# RESUME — <project name>

<!-- ccage budget: keep lean. Update the State sections in place; keep at most
     ~3 ## Session blocks — roll older ones into CHANGELOG. RESUME is auto-read
     into context on every session start, so smaller = cheaper + sharper. -->

## State

### Now
- <the single thing in flight right now>

### Next
- <the very next concrete action — the first thing to do on resume>

### Threads
- <open workstream> — <status>

### Decisions
- <settled choice worth remembering>

### Open questions
- <unresolved question that needs an answer>

### Plan
<!-- Present ONLY when work follows a plan/design doc. Name the doc(s) with
     remaining scope. RESUME is a summary, never the plan: the next session
     must READ the doc before executing its tasks, and an execution-level plan
     with independent remaining tasks puts it in DISPATCHER mode (dependency
     waves), not sequential inline execution. Keep paths exact — the resume
     autoloader detects and re-asserts them. -->
- <full path to plan doc> — <N/M tasks done; next wave: …>

### Live jobs & tasks
<!-- /clear wipes these. On resume: re-arm each job by its command and recreate
     Tasks via TaskCreate. List only in-flight + next tasks (point to the plan doc
     for a long backlog); collapse to "- none" when nothing is live. -->
- Jobs: <purpose — rearm: `cmd`>                  (omit line if none)
- Tasks: <[in_progress] subject; [pending] next>  (omit line if none)

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

The goal is a **merge**, not a rewrite, done in as few tool calls as possible.

1. **Use the `$resume` already in your context.** ccage's SessionStart hook
   injected it at the top of this session, and every `Edit` you've made since is
   reflected there — so the in-context copy is current. **Only `Read` it again if
   it could have changed outside this session** (a parallel session, or you simply
   don't have it). One exception: hook-injected text does **not** satisfy the
   harness's Read-before-Edit check, so if you have not yet touched `$resume` with
   the `Read`/`Edit`/`Write` tools this session, do **one** `Read` before the
   first `Edit` — otherwise that Edit fails and costs more than the read saved.
   Skipping a needless re-read saves a full-context round-trip.
2. **Keep carried state verbatim.** Every thread, decision, and open question this
   session did *not* change stays exactly as written.
3. **Update the structured lines in place** — `### Now / ### Next / ### Threads /
   ### Decisions / ### Open questions / ### Plan / ### Live jobs & tasks` — for
   whatever moved this session. When a plan doc governs the work, fill
   **`### Plan`** with its exact path and remaining scope — measured failure
   (2026-07-16): resumed sessions acted from RESUME's summary bullets without
   opening the plan, silently dropping tasks; the autoloader turns this line
   into a read-and-dispatch directive. Add new decisions and open questions. `### Now` and `### Next` are
   the highest-value lines for resumption: make `### Next` one concrete first
   action, not a vague goal. **`### Live jobs & tasks`** records what `/clear`
   destroys, for rebuild-on-resume: run `TaskList` (skip gracefully if the tool is
   absent or empty) and list only **active** (in_progress/pending) tasks, one line
   each; give each live background job / Monitor a one-line **rearm command** (a
   finished one-shot waiter → where its output landed + the condition to re-check).
   Point to a plan doc instead of dumping a long backlog. Drop done/moot items
   (their detail goes to CHANGELOG).
4. **Refresh the current day's `## Session <YYYY-MM-DD>` block *in place*.** If a
   block for today already exists (you checkpointed earlier today), **edit it** to
   reflect the latest 2–5 sentence state — do **not** prepend another block. Only
   **prepend a fresh block when the date has changed** (or there is no session
   block yet). This keeps repeated same-day checkpoints from growing `$resume`.
   - **Promote before you overwrite.** `$resume` is git-excluded — there is no
     version history to recover from — so anything still load-bearing in the block
     you're about to condense must first move to a durable line (`### Decisions` /
     `### Open questions`) or to `$changelog`. The block's narrative is meant to be
     ephemeral "where things stand"; durable facts must not die in it.
5. **Roll to CHANGELOG only when over budget — don't archive proactively.** After
   the update, if `$resume` now has more than **3** `## Session` blocks, exceeds
   ~250 lines, **or exceeds ~14 KB** (`wc -c` — a dense file bloats under the line
   cap), move the **oldest** block(s) into `$changelog` as a dated, newest-first
   prose entry. Otherwise leave `$changelog` untouched. The roll is a lossless
   *move*, so deferring it loses nothing — older days still reach CHANGELOG as
   they age out, whether here or at `--tidy`/close.

   **Density pruning (same trigger):** when the byte budget is what tripped,
   session blocks alone won't fix it — prune the structured sections too: (a) a
   `### Threads` bullet whose work has **shipped/closed** moves to `$changelog`
   as a dated prose line (lossless move, keep any still-open sub-question in
   `### Next`/`### Open questions`); (b) a `### Decisions` bullet already
   captured in a memory note collapses to its one-line `[[memory-slug]]`
   pointer; (c) never prune a bullet that is the only record of something
   still open.
6. **Apply everything surgically — `Edit`, never a full rewrite.** The in-place line
   updates plus the single same-day block edit are a handful of targeted `Edit`s; a
   CHANGELOG roll is one more. Only fall back to a full `Write` when bootstrapping
   (§2) or when a budget-overflow trim genuinely restructures most of the file.
   Regenerating a ~150-line RESUME every checkpoint is the main avoidable cost — and
   the slow part.
7. **Update the done-marker (one Bash call).** After RESUME is written, reconcile
   the `.ccage-session-done` marker (§6). The rule is decided by **one thing only —
   whether `--final` is present**, never by the other flags:
   - **`--final` in the invocation** (alone or with `--tidy`) → run
     `bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/checkpoint/checkpoint-init.sh" mark-done`.
     `--final` always wins: `--final --tidy` marks done **and** tidies.
   - **no `--final`** (plain, `--tidy` alone, `--merge-slots`) → run the same
     helper with `clear-done`.

   This is what makes `/keepwarm` and `ccage-auto` stand down on `--final` and keep
   going otherwise. Skip gracefully if the helper is missing.
8. **End by telling the user:** `RESUME updated — safe to /clear.` (append
   `, CHANGELOG rolled` only if step 5 actually moved a block; append
   `, marked done` on `--final`).

Use the same six-part structure as a `session-handoff` brief for the per-session
narrative if helpful — but `/checkpoint` differs in that it writes a persistent,
merged, budget-trimmed file rather than a one-shot chat message.

---

## 4. `--tidy` — memory hygiene (judgment, not a script)

This runs **after** the lean checkpoint (§3) and is the close-of-day ritual. It
operates on a **different file set** from `$resume`/`$changelog`: this cage's
auto-memory directory.

```bash
# Claude Code encodes the project dir by replacing EVERY non-alphanumeric
# character with "-" ("/", "_", "." all convert). tr, not a bracket character
# class — macOS bash 3.2 mishandles ${var//[^…]/}, so tidy would silently no-op.
slug=$(printf '%s' "$PWD" | LC_ALL=C tr -c 'A-Za-z0-9' '-')
memdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$slug/memory"
```

**Bail early when it's already clean.** Glance at `MEMORY.md` and the note files
first; if the index is well-sectioned, every link resolves, and there are no
obvious duplicate/stale notes (and the SessionStart check did **not** flag `memory
needs tidying`), say so and stop — don't spend tokens reorganizing a tidy dir.
Only do the work below when there is real disorganization.

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

## 5. `--merge-slots` — fan-in (collapse parallel slots into the trunk)

When several slotted sessions (`CCAGE_SLOT=gen`, …) run in parallel, their state
is fanned out across `RESUME.<slot>.md` / `CHANGELOG.<slot>.md`. A future
**slotless** session reads only the plain `RESUME.md`, so it would miss them.
`--merge-slots` collapses every slot file back into the plain trunk, once, so a
slotless start sees the union.

This mode **always targets the plain files** (`RESUME.md`, `CHANGELOG.md`),
regardless of the running session's own slot. Run it only when the parallel
sessions are **idle** — a slot file checkpointed *after* the merge is stranded
again. It does not checkpoint the caller; do that first if you have unsaved state.

1. **Discover the inputs** (the plain trunk is the merge target, the slot files
   are overlays):
   ```bash
   shopt -s nullglob
   slot_resumes=(RESUME.*.md); slot_logs=(CHANGELOG.*.md)
   printf 'merging %d slot RESUME(s): %s\n' "${#slot_resumes[@]}" "${slot_resumes[*]:-none}"
   ```
   If there are no slot files, report `nothing to merge` and stop (idempotent).
2. **Read the plain `RESUME.md` and every `RESUME.<slot>.md`.** The plain file is
   the base; each slot file is an overlay.
3. **Merge into the plain `RESUME.md` — a judgment merge, never a `cat`:**
   - **Threads / Decisions / Open questions:** the **union** across all files,
     with overlaps **deduped** (the same workstream often appears in two slots);
     when two versions disagree, keep the most-recent wording.
   - **`### Now`:** combine into one — a line per still-active workstream, newest
     first; drop any item another file marks done.
   - **`### Live jobs & tasks`:** union of still-running jobs (keep their rearm
     commands) + active tasks; drop finished ones.
   - **`## Session` blocks:** keep the **3 newest across all files**; tag each
     kept block with its origin slot so provenance survives
     (e.g. `## Session 2026-06-13 (gen)`). Everything older rolls to CHANGELOG.
4. **Fold the slot CHANGELOGs in.** Append each `CHANGELOG.<slot>.md`'s entries
   into the plain `CHANGELOG.md` (newest-first, dated, dedup identical lines).
5. **Write the merged plain files first, then delete the slot files** — order
   matters so a failed write never loses data:
   ```bash
   # only after RESUME.md + CHANGELOG.md are written and verified non-empty:
   for f in "${slot_resumes[@]}" "${slot_logs[@]}"; do rm -- "$f"; done
   ```
   If any write failed, leave **every** slot file in place and stop.
6. **Enforce the budget** on the merged trunk exactly as in §3 step 5 (≤3
   `## Session` blocks, ~250 lines, ~14 KB; overflow → CHANGELOG).
7. **Tell the user:**
   `Merged <N> slot(s) into RESUME.md (+ CHANGELOG). Slot files removed — safe to start slotless.`

Idempotent: a second run finds no slot files and no-ops. Re-running after a slot
session checkpoints again simply folds that one in too.

---

## 6. `--final` — the `.ccage-session-done` completion marker

`/clear` wipes the conversation, so an in-memory "we're done" flag can't survive
to tell background helpers to stop. `.ccage-session-done` is that flag made
durable: a small file at the project root, written **only** by `/checkpoint
--final`, that two helpers poll:

- **`/keepwarm`** checks it on every scheduled wake and self-stops when it's
  present — so an away-loop that's still pinging quits once the work is finished.
- **`ccage-auto`** (the autonomous context manager) checks it each poll and stands
  down — stops its checkpoint→clear→resume loop instead of running all night after
  the task is actually complete.

**Why a plain checkpoint must clear it (§3 step 7).** `ccage-auto` drives ordinary
`/checkpoint` calls as *maintenance* (save RESUME, then `/clear`, then keep
working) — those are **not** "done." If a stale marker lingered, the very next
maintenance checkpoint would look terminal and everything would stop early. So the
rule is strict: **`--final` writes the marker; every other checkpoint clears it;
the SessionStart hook clears it on a genuinely new session.** The marker is present
if and only if the last checkpoint was a `--final`.

You never write or delete this file by hand — §3 step 7 calls
`checkpoint-init.sh mark-done` / `clear-done`, which also keeps it out of git. It
is deliberately **not** slot-scoped: it's a coarse per-directory "helpers may stand
down" signal, and one fixed name keeps every consumer trivially simple.

**When to reach for `--final`:** the session's actual task is done and you're
winding down — the human is wrapping up for the day, or an autonomous `ccage-auto`
run has finished its objective. Not for routine mid-work saves (that's plain
`/checkpoint`), and not merely because you're about to `/clear` to free context
(that's also plain — you're continuing). Pair with `--tidy` (`--final --tidy`) at a
true end-of-day.

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
- **Pinned to `medium` effort.** Frontmatter fixes the effort regardless of the
  session's `/effort`; don't escalate your own reasoning for a checkpoint. Get
  speed and cost from fewer round-trips and deferred archival, not from thinking
  less — a vague checkpoint just moves the cost to a more expensive re-discovery
  on resume.
- **Rebuild-on-resume state** lives only in `### Live jobs & tasks`: the task list
  and any background jobs/Monitors (all wiped by `/clear`). Record active tasks +
  per-job rearm commands; omit when empty; never dump a long backlog.
