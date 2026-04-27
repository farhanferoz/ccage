# ccage — Architecture

How the pieces fit. Intended for contributors and for anyone debugging why an invocation didn't do what they expected.

## File layout

```
ccage/
├── README.md                         user-facing: problem, install, FAQ
├── CHANGELOG.md                      keep-a-changelog log of released + unreleased work
├── LICENSE                           MIT
├── install.sh                        writes share/*.sh → ~/.bashrc.d/ (or ~/.zshrc.d/)
├── uninstall.sh                      removes installed files; preserves user data
├── share/
│   ├── claude-isolation.sh           the wrapper + bootstrap helpers + hook stubs
│   ├── claude-ccusage.sh             independent: ccusage-all aggregator
│   └── claude-overrides.sh.example   template copied by users into ~/.bashrc.d/
├── docs/
│   ├── PLAN.md                       phased work plan (TDD)
│   ├── FEATURES.md                   feature/env-var reference
│   └── ARCHITECTURE.md               this file
├── tests/
│   ├── helpers.bash                  shared bats fixtures
│   └── test_*.bats                   one file per subject
└── RESUME.md                         lean session-resume pointer
```

## Shell-rc integration

ccage does **not** edit the user's `.bashrc` or `.zshrc` in place. Instead:

1. `install.sh` creates `~/.bashrc.d/` (or `~/.zshrc.d/`) if missing.
2. Copies `share/claude-isolation.sh` and `share/claude-ccusage.sh` into it.
3. Appends a sourcing loop to `.bashrc`/`.zshrc` **only if** one isn't already present. The loop pattern matches what most distros already use.
4. User-specific overrides live in `~/.bashrc.d/claude-overrides.sh`, which the user writes from the shipped `.example` template. ccage never writes or overwrites the overrides file.

### Load order matters

`~/.bashrc.d/` is sourced alphabetically. File names are chosen so the stub-defining file (`claude-isolation.sh`) loads *before* the overrides file (`claude-overrides.sh`). The overrides file redefines the stub hook functions; if it loaded earlier, the stubs would clobber the user's hooks.

## Runtime flow — one `claude` invocation

```
User types `claude ...`
   │
   ▼
Bash function `claude()` in claude-isolation.sh runs:
   │
   ├─ If CCAGE_DISABLE=1 → call `command claude "$@"` and return. No side effects.
   │
   ├─ CLAUDE_CONFIG_DIR=$(_ccage_config_dir_for "$PWD")
   │     │
   │     ├─ If _CCAGE_OVERRIDE_ACTIVE=1, call _ccage_config_dir_override;
   │     │   on a returned path, short-circuit with it
   │     ├─ Else compute $root/$prefix$base (basename via ${##*/}, no fork)
   │     ├─ Else on collision, append -<sha1[:8] of PWD>
   │     └─ If CCAGE_SLOT set (and safe chars), append --<slot>
   │
   ├─ _ccage_bootstrap_dir "$CLAUDE_CONFIG_DIR" "$PWD":
   │     ├─ mkdir -p
   │     ├─ Write .owning_path if absent
   │     └─ Patch hasCompletedOnboarding=true into .claude.json (unless opt-out)
   │     └─ _ccage_share_dirs (if CCAGE_SHARE_FROM set)
   │
   ├─ _ccage_write_signore (unless opt-out): writes baseline .claudesignore if missing
   │
   ├─ export CLAUDE_CODE_ATTRIBUTION_HEADER=0 (unless opt-out)
   ├─ export DISABLE_AUTOUPDATER=1 (unless opt-out)
   │
   ├─ _ccage_extra_args=()
   ├─ _ccage_pre_exec_hook "$PWD" "$CLAUDE_CONFIG_DIR"
   │     (user hook may export env, append to _ccage_extra_args, seed UI-only settings)
   │
   └─ exec: command claude "${_ccage_extra_args[@]}" "$@"
```

## What lives where — state map

| State | Location | Scope | Shared across ccage dirs? |
|---|---|---|---|
| Credentials (`.claude.json` OAuth fields) | `<config-dir>/.claude.json` | per dir | No — each dir needs its own `/login` |
| Onboarding flag | `<config-dir>/.claude.json` | per dir | N/A — ccage sets it everywhere |
| Session history | `<config-dir>/projects/<encoded-path>/` | per dir | No |
| `settings.json` | `<config-dir>/settings.json` | per dir | UI keys only (by doctrine) |
| Skills / commands / agents | `<config-dir>/{skills,commands,agents}/` | per dir by default | Opt-in symlinks via `CCAGE_SHARE_FROM` |
| Plugins | `<config-dir>/plugins/` | per dir | No — plugins carry state |
| Prompt cache (server-side) | N/A (Anthropic infra) | keyed on prefix stability | N/A — ccage stabilizes the prefix |
| `.owning_path` marker | `<config-dir>/.owning_path` | per dir | Never |
| Baseline `.claudesignore` | `$PWD/.claudesignore` (project) | per project | N/A — project file |

## Hot-path costs

The wrapper runs on every `claude` invocation, including interactive shell sessions. A few decisions fall out of that:

- **sha1 tool resolved once at source time** (`_CCAGE_SHA1_CMD`). No `command -v` probe on collision.
- **Basename via `${pwd_arg##*/}`**, not `$(basename ...)`. No fork on the main path.
- **Marker file read via the `read` builtin**, not `$(cat "$marker")`. No fork on collision.
- **Override hook skipped unless `_CCAGE_OVERRIDE_ACTIVE=1`.** Running `$(_ccage_config_dir_override ...)` unconditionally is a ~1–2 ms subshell fork per invocation. The guard flag lets the no-override case cost nothing. The overrides file is expected to flip the flag after defining the function; the shipped `.example` template does this.

Worth noting: if a user redefines `_ccage_config_dir_override` *without* setting the flag, the override is silently inactive. The `.example` template makes the pattern obvious; FEATURES.md documents it explicitly.

## Why the shell wrapper, not a hook

`CLAUDE_CONFIG_DIR` must be set *before* Claude Code starts — it decides where to look for credentials and state. Claude Code's hook surface (SessionStart, etc.) fires after startup, too late to pivot the config dir. The shell wrapper is the only place this works.

SessionStart and PreToolUse hooks can handle secondary concerns (maintaining `.claudesignore`, logging usage), but ccage intentionally uses the shell layer for the primary concern because that's the only layer that can solve it.

## Collision algebra

Two paths `P1`, `P2` with `basename(P1) == basename(P2)`:

- **First invocation in P1**: candidate dir didn't exist, ccage creates it, stamps `.owning_path=P1`.
- **First invocation in P2**: candidate dir exists, `.owning_path=P1 ≠ P2`, ccage disambiguates to `<base>-<sha1(P2)>`, creates it, stamps `.owning_path=P2`.
- **Subsequent invocations in P1**: candidate dir exists, marker matches, no disambiguation.
- **Subsequent invocations in P2**: candidate for P2's basename is `<base>`, marker says `P1` — disambiguation to `<base>-<sha1(P2)>` is deterministic; ccage finds its own previously-created dir.

### Known race

If two parallel processes in two different paths with the same basename both call `claude` before either writes `.owning_path`, they can both create and claim `<base>`. Then neither triggers the disambiguation fallback, and they share silently.

Mitigations v0 offers:
- Rare in practice — requires identical basenames *and* both being fresh sessions *and* within a sub-second window.
- `CCAGE_SLOT` gives the user an explicit escape hatch.

Proper fix (registry-based, post-v0) is listed in PLAN.md Phase 6.

## Dependencies

| Dependency | Why | Fallback if missing |
|---|---|---|
| bash 4+ or zsh 5+ | wrapper syntax | none — install on the shell, not both |
| `sha1sum` | collision disambiguation | `shasum -a 1`, then `openssl dgst -sha1` |
| `python3` | onboarding-flag patch on existing `.claude.json` | silently skip; first session sees onboarding UI |
| `npx` | only for `ccusage-all` | `ccusage-all` fails; nothing else affected |
| `command` builtin | dispatching to real `claude` binary | — |

## What ccage is not

- Not an account manager. For multiple Anthropic accounts, use `cc-switch` alongside ccage.
- Not a proxy. For the orthogonal `cch=`-in-tool_results cache bug, use `claude-code-cache-fix`.
- Not a worktree orchestrator. For spawning parallel agents across branches, see `claude --worktree` or `parallel-cc`.
- Not a session scheduler. ccage runs when you run `claude`; it doesn't decide when to run anything.
