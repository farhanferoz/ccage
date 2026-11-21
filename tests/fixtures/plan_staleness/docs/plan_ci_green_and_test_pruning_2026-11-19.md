# Plan: private CI green, test suite cut back (D387)
## Where it stands (measured 19 Nov)
## Rules this follows
## Order
- [ ] P1 Audit the three largest private-only folders (`tests/scripts`, `tests/processors`, `tests/rollout_study`):
  per file, the behaviours it tests, its verdict (keep / merge into another file / cut) with the reason, its pyright error
  count, and whether it imports untracked `notes/` code. Read-only; no deletions. Done when:
  `test -s notes/design/project_admin/ci_lint_checks/test_audit_part1_2026-11-19.csv`
- [ ] P2 Owner sees the audit's totals (tests and lines to cut, what stays and why) before any deletion.
- [ ] P3 Cut and merge P1's verdicts, one folder per commit, each commit stating the count and why; the folder's
  remaining tests pass, and each kept guard is broken once to see it fail. Done when: the three folders' kept tests
  pass in one run within the pytest budget.
- [ ] P4 Audit and cut the remaining private-only folders the same way (losses, analysis, scripts_model_comparison,
  models, metrics, nn, benchmarking, data, scripts_campaign2, the rest).
- [ ] P5 Tests that import untracked `notes/` code: the code moves to a tracked module (standard 1: reusable code lives
  in tracked, tested modules) or the test is cut with its study. Clears the 83 missing-import errors.
- [ ] P6 Pyright on what remains, area by area (`src/autocast` first, then `scripts/`, then tests): real types, not
  `# type: ignore`; a fake passed where a model class is typed gets a Protocol the code accepts (standard 2).
  Done when: `uv run prek run --stage manual --all-files` exits 0 locally.
- [ ] P7 CI green on a pull request to private main (D376), the whole suite run once there; slow tests opt-in.
## Not in scope
