# Plan: the ARFC paper runs after tonight's state-following trial (17 Nov 2026, evening)
## 0. What this plan supersedes
## 1. What tonight's outcome means for the paper
## 2. Per system and space
### 2a. Ambient (the four PDEs)
### 2b. Latent (the four PDEs)
## 3. Rayleigh-Benard (RB): everything found
## 4. Costs, from measured runs only
## 5. Open questions for the owner
## 6. Preparation steps (each with its done-when check)
- [ ] 1. Read tonight's trial against section 1 and record the branch (good, mixed, bad) as a D-entry. Done when: the D-entry names the branch and the metrics read.
- [ ] 2. Mark `plan_remaining_paper_runs_2026-11-14.md` superseded by this plan (section 0 table). Done when: its first lines point here.
- [ ] 3. Put the three finished 14-15 Nov runs into the team store with the store step (AD64 no term, GS64 term, GS64 no term; names per Q9), checksums verified, README register updated. Done when: the register lists them and `sha256sum -c SHA256SUMS` passes in each folder. (The GS64 term run's scratch folder must be found first.)
- [ ] 4. Let the chain take the overlay: add a pass-through to `submit_c1_arfc_swe64s_w224_chain.sh` (as `--optimizer` was added for D320) that appends `+covariance_form=state_following`, and `++model.processor.term_sizes=input` only for term runs. Not built (shared scripts untouched). Done when: compose-diff of a new-form run against its old-form twin shows only those switches (done by hand on two presets on 17 Nov, section 2a).
- [ ] 5. If GOOD: compose-diff all four ambient presets old against new with `ready_to_submit_2026-11-14/compose_and_diff.py` (extend its run list; it reuses `src/autocast/analysis/config_diff.py`). Done when: four diffs, each exactly the overlay (+ term_sizes where a term is on).
- [ ] 6. Latent: decide Q3/Q4, then fill `r_max` and the TBD markers from `latent_rule_reads_2026-11-15/`; derive the GS64 and GPE64 loading constants (L4); write chain scripts for GS64 and GPE64 latent from the AD64 ones. Done when: each latent preset composes with no `TBD_` variable and the first pass at the real batch fits memory.
- [ ] 7. RB reads on CPU, sized from shapes first: the ambient rule read on RB (`python -m autocast.analysis.rank_by_scale --datamodule rayleigh_benard`, windows subsampled; one 5,000-window matrix of 262,144 float32 values is 5.2 GB) and the latent read (`--cached-latents <RB cache>`, 4,096 values per frame). Done when: r_max, term range and held share files exist beside `latent_rule_reads_2026-11-15/`.
- [x] 8. (DONE 19 Nov: the data refused zero_value on the walls: 'channel 0 is declared zero_value but changes by 3.21 on an edge'; reads use open edges; the true wall kinds stay owner Q8) RB boundary: declare `{y: periodic, x: [...]}` and run setup's `check_boundary` on a few trajectories. Done when: setup accepts it, or the refusal names the field to change.
- [x] 9. (DONE 19 Nov: public main 3937eafe merged (d8d18376, 28eab8b9); spatiotemporal_vit, test64_seed0.yaml, paired_test_windows.py present; tests/nn/test_spatiotemporal_vit.py 24 passed) RB tools: merge public main (at least `41ad943c`) into the private branch if Q5 picks Sam's trunk or his cohort tools. Done when: `spatiotemporal_vit`, `test64_seed0.yaml`, `paired_test_windows.py` are present and their tests pass.
- [ ] 10. RB scorer parity: score Sam's `final.ckpt` with our scorer on his cohort. Done when: vrmse_v2, afcrps, ssr match his `paired/summary.csv` (0.04506, 0.002501, 1.0239).
- [ ] 11. RB presets: only after Q5-Q8 are answered, as presets in the tracked `local_hydra/local_experiment/the_well/rayleigh_benard/` folder inheriting his latent or ambient preset. Done when: each composes with `--cfg job --resolve` and diffs against his matched preset by named settings only.
- [ ] 12. Every submission: gate legs, a `log_gpu_job.py` ledger row at submission, the store step at the end (D291), disk thinning per D322. Done when: each run has a ledger row and a store folder.
## Evidence for what this plan states as fact (checked 17 Nov)
