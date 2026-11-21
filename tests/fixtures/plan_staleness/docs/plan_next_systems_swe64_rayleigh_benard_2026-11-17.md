# Plan: the rollout study's next systems, 64x64 shallow water and Rayleigh-Benard (17 Nov 2026)
## 0. Answers in short
## 1. Inventory
### 1.1 64x64 shallow water
### 1.2 Rayleigh-Benard
## 2. What the 32x32 design needs, and where it stands at 64x64 and Rayleigh-Benard
## 3. Options and costs (measured runs only)
### 3.1 Measured runs
### 3.2 64x64 shallow water
### 3.3 Rayleigh-Benard
### 3.4 ARFC: the model form is not final
### 3.5 Scheduler and configuration (what to reuse)
## 4. Questions for the owner (in this order)
## 5. Isambard store for the rollout models
## 6. Preparation steps (each with its done-when)
- [ ] P0 Owner answers Q1-Q11. Done when: each answer is in `DECISIONS.md` with the owner's words.
- [ ] P1 Build the 64x64 8-lead truth ensemble with the preserved generator (`generation_source/autosim-source.tar.gz`) and the 32x32 reference script, 16 anchors per Q7, 64 members, 9 frames. Done when: its manifest says `validated`, each anchor has shape `[64, 9, 64, 64, 3]`, forcing-off repeats are identical, and its leads 1-4 match Sam's `conditional-redraws-20261009/reference` in law (member standard deviation per channel within 1%, as the 32x32 build checked).
- [ ] P2 Make the scorer take the truth directory, arm table and grid from a setup record, not module constants (`score_swe_rollout.py:131`, `:210`). Done when: re-scoring one existing 32x32 arm reproduces its published table by value, and a test goes red when the directory is wrong.
- [ ] P3 Add the setup record (preset, data folder, output subfolder `shallow_water_64_field`, backbone overrides, update budget) to `swe_rollout_cells.py` and key the chain generator on it. Done when: `python -m autocast.rollout_study.chain_generation` regenerates every tracked chain byte for byte (the existing test), and a compose-diff of a 64x64 cell against its 32x32 twin shows only grid, backbone and name keys.
- [ ] P4 Write `src/autocast/configs/jobs/settings/swe64_rollout_runs.yaml` from the owner's choices (Q1-Q3, Q8): models, seeds, Isambard, `score_wall`, gate declarations. Done when: the generator writes the chain and the gate accepts it in check-only mode.
- [ ] P5 15-epoch smoke of each new 64x64 cell on Isambard (one GPU), recording seconds per epoch and peak memory. Done when: section 3.2's analogues are replaced by these numbers and each cell's `wall` is set from them.
- [ ] P6 Time the scorer on one 64x64 arm (CPU, Isambard). Done when: `score_wall` per arm is a measured figure.
- [ ] P7 Train CRPS autoregressive; queue the ES warm start after it with `--after`; queue the other cells and each scoring dependent in the same session. Done when: every cell has a `run_outcome.json` and a scored table, or a stated stop reason.
- [ ] P8 FM at 64x64 per Q3: either score Sam's ambient FM through `score_flow_matching.py` (Heun 100, best-on-validation contract) after checking that its residual-coordinate checkpoint loads in the study's driver, or retrain. Done when: the FM row has the same tables as every other row.
- [ ] P9 ARFC rows, only after the D340/D352 trial is read (Q4). Done when: the chosen form's run (or the interim existing run) has a `rollout_support.pt` and a scored table.
- [ ] P10 Fix the protocol (Q5, Q6): leads and free-run length, cohort (`test64_seed0.yaml` from start 16, or study-style starts with 8 leads), metrics (accuracy only; no realism). Done when: one paragraph in STUDY names them and the scorer's input list is written.
- [ ] P11 Score Sam's latent FM and CRPS by that protocol (R0), using the autoencoder and checkpoints at the paths in section 1.2. Done when: two scored tables exist and the vrmse values Sam reports (0.550 and 0.605 over leads 1-84) are reproduced within seed noise.
- [ ] P12 If R1 or R2: a 15-epoch smoke of the ARFC (or study-scheme) cell on 512x128 reporting memory and seconds per epoch. Done when: it either fits with a measured memory or the failure is recorded.
- [ ] P13 Add `RolloutSetup` swe64 (and rb) and each model's `swe_system` entry to `scripts/rollout_registry.py`, then run `scripts/rebuild_pages.py`. Done when: the registry test passes and the pages show the new setup with every model present or marked "not run" with a reason.
- [ ] P14 Create `/projects/u6eo/autocast/outputs/rollout_paper/` per section 5, copy the scored checkpoints, write the register. Done when: `sha256sum -c` passes in every model folder and the README lists every row.
- [ ] P15 Ledger and record: `python3 /home/ff235/dev/turing/log_gpu_job.py <job_id> autocast-private <workstream> <run>` inside each submission script, `--reconcile` after the last job, one `DECISIONS.md` entry, one `RESUME.md` line. Done when: `gpu_usage.csv` has a row per job with hours filled.
## 7. Not verified
## 8. Checks of 19 Nov (owner: "have some of these jobs already been run?" and "is the design changing?")
## 9. Job list after D364, checked for one story across the ladder (19 Nov, PROPOSED, waits for the owner's go)
