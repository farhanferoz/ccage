# Plan: one command for every toy model comparison (17 Nov 2026)
## The problem (measured)
## What exists to build on (read 17 Nov)
## Design
## Decision: (b), settled by the coding standard (17 Nov)
## Order of work
- [ ] M1 move the data layer to `src/autocast/rollout_study/` (verbatim, tests), notes scripts import it — done when: `test -f src/autocast/rollout_study/rollout_registry.py` and the page data CSVs rebuild byte-identical
- [ ] C1 registry entries for the ARFC versions (non-final) + coherence rows for them — done when: `grep -q arfc notes/design/rollouts/four_rollout_models_with_layer_norm_noise/scripts/rollout_registry.py`
- [ ] C2 `compare` command, md + csv, same-starts check, every column — done when: its output for lorenz96_mlp reproduces the 17 Nov one-off table's numbers
- [ ] C3 toy scoring step calls it — done when: a scoring job's folder holds its comparison table
- [ ] C4 one-off table scripts removed or reduced to calls — done when: none of the eight builds a table itself
