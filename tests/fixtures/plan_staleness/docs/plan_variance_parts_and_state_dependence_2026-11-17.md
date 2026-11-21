# Plan: how much of ARFC's uncertainty can follow the input, and does the truth need it to (17 Nov 2026)
## Why
## The idea: one pass over the test windows, no members drawn
## Systems
## Build (reuse first)
## Cost and site
## Order of work
- [x] P1 build (52a065eb, reviewed) `autocast.analysis.variance_parts` + script + tests (worker, reviewed) — done when: `test -f src/autocast/analysis/variance_parts.py`
- [x] P2 run on the toys (read: read_variance_parts_toys_swe32_2026-11-17.md) and 32x32 shallow water (data on disk) — done when: `test -s notes/design/low_rank_covariance_model/state_dependent_uncertainty/results/variance_parts_toys_swe32.json`
- [ ] P3 run on AD64, GPE64 (on disk) and GS64, CNS64, 64x64 shallow water (fetched) — done when: `test -s notes/design/low_rank_covariance_model/state_dependent_uncertainty/results/variance_parts_pdes.json`
- [ ] P4 read: one table per question (R1, R2, R3) across systems, plain numbers, no cut-offs; what it says for fix 3 and for the current model — done when: `test -s notes/design/low_rank_covariance_model/state_dependent_uncertainty/read_variance_parts.md`
## What the read can and cannot say
