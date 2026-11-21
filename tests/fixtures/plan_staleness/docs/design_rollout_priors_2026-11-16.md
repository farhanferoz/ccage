# Remedy 3: priors that keep ARFC rollouts stable (design, 16 Nov 2026)
## 1. The two failures, as measured
## 2. Rulings that bind
## 3. Diagnostics first (scoring only, CPU, data in hand)
## 4. A prior on the per-point variance (independent of C10-C11)
## 5. A prior on the mean map's fine-scale response (only if C10 and C11 allow)
## V5. The six retrains with a fixed per-point variance, read (17 Nov)
## 6. Order of work
- [x] C10 shell-power support diagnostic (read 16 Nov: holding shell power removes the late departure, section 3) — done when: `grep -q 'Exit status: 0' notes/design/low_rank_covariance_model/autoregressive_rollout_sampling/rollout_noise_test_runs/candidate_checks/check10_output.txt`
- [x] C11 one-step fine-scale response at true states (read 16 Nov: no consistent excess at true states, section 3) — done when: `grep -q 'Exit status: 0' notes/design/low_rank_covariance_model/autoregressive_rollout_sampling/rollout_noise_test_runs/candidate_checks/check11_output.txt`
- [x] V0 spread of ln D on the toy runs' training windows — done when: `test -s notes/design/low_rank_covariance_model/autoregressive_rollout_sampling/rollout_noise_test_runs/candidate_checks/v0_log_variance_spread.txt`
- [x] V1 build the log-variance prior as a loss option (off by default; tests: closed-form refresh, stop-gradient in the network's step, off = today's loss to the bit; each mutation-checked) — done when: `grep -rq log_variance_prior src/autocast/losses/gaussian.py`
- [x] V2 retrain the six failing-seed toy runs with the prior — DROPPED (D336, owner 'y' 16 Nov ~19:20): the built prior has no finite optimum and a fixed one flattens the per-point variance everywhere (section 4); replaced by C12 — done when: `grep -q '^- \*\*D336\*\*' DECISIONS.md`
- [x] C12 a per-point variance that does not follow the state, scoring only (D336; read 16 Nov, section 4): on the six failing toy runs, one level per field fitted on the training windows, one-step scores and the 100-step free run with no cap, against the network's variance (`candidate_checks/check12_fixed_point_variance.py`, unit d336-check12) — done when: `grep -q 'Exit status: 0' notes/design/low_rank_covariance_model/autoregressive_rollout_sampling/rollout_noise_test_runs/candidate_checks/check12_output.txt`
- [x] V3 read V2 — DROPPED with V2 (D336) — done when: `grep -q '^- \*\*D336\*\*' DECISIONS.md`
- [x] V4 build `point_variance=fixed` and retrain the six failing toy runs with it (D337): 180e1a3d (pushed, Isambard pulled); compose-diff clean (`rollout_noise_test_runs/fixed_point_variance/compose_diff_verdict.md`); QUEUED Isambard 8521987 (Lorenz-96 s0-s2) and 8522006 (ring s0-s2), ledgered — done when: `grep -q 8522006 /home/ff235/dev/turing/gpu_usage.csv`
- [x] V5 read V4 against tonight's D334 baseline (read 17 Nov, section V5): run `rollout_noise_test_runs/fixed_point_variance/compare_retrains.sh` once both jobs end COMPLETED; one step first (fair CRPS, spread / error, log score, against the seed range), then the retrains with no rule (arm C) against the baseline under D334 (arm F) — done when: a 'V5' section in this note
- [ ] M1 design the mean prior's build — only if C10 removes the drift and C11 shows the excess at true states — done when: a 'M1' section in this note
