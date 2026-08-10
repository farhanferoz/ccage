---
name: skill-catalog
description: Search every skill installed on this machine, including ones NOT in your current available-skills list, and activate one on demand for immediate use. Use whenever you want a capability that no listed skill covers, before concluding "there is no skill for this" or writing the functionality yourself — this cage may be scoped to a small core while the rest sit on disk, unlisted. Also use when the user asks what skills exist, whether a skill exists for some task, or names a skill you cannot see. Triggers, "is there a skill for", "what skills do I have", "search skills", "find a skill", "activate a skill", "that skill isn't listed".
allowed-tools: Bash
---

# Skill catalog

A scoped cage lists only a small core of skills; the rest are on disk but invisible. **An
unlisted skill is not a missing skill.** This searches all of them and turns one on.

Activation takes effect **immediately, in the running session** — no restart. (Verified
2026-08-10: a skill symlinked in mid-session was accepted by the Skill tool on the next call.)

## Use it

The script sits next to this file. Resolve its path from this skill's own directory.

```bash
# search — all terms must match, case-insensitive, over name + description
skill-catalog.sh fuzzing rust
skill-catalog.sh security review

# everything on disk, active ones marked
skill-catalog.sh --list

# activate; usable straight away
skill-catalog.sh --add find-bugs

# diagnose: master dir, whether this cage is scoped, parse coverage
skill-catalog.sh --selftest
```

Output marks each hit `[ACTIVE]` (already listed, just invoke it) or `[add]` (on disk, needs
activating).

## When to reach for this

- You are about to write code or a helper for something that sounds like a solved, packaged task.
- You are about to tell the user no skill covers something. **Check before saying it** — in a
  scoped cage that claim is unverifiable from the listing alone.
- The user names a skill you cannot see.

## Notes

- `--add` refuses in an **unscoped** cage — one whose `skills/` is a symlink to the master dir.
  There, everything is already listed, and writing into the symlink would alter every other cage.
- Activation is a symlink into this cage's `skills/`. It persists for future sessions in this cage;
  remove the symlink to deactivate.
- The catalog reads the master dir (`$CCAGE_SHARE_FROM/skills`, default `~/.claude/skills`) and
  follows symlinked skill directories, so plugin-provided skills are included.
