# Pattern sizes that follow the input, on Gray-Scott 32x32: plan (16 Nov 2026)
## Question
## Why this test, and why Gray-Scott 32x32
## Work (one batch, after the owner's go)
## Cost
## Checklist
- [x] G1 data (DONE 16 Nov: ~/autocast_local/datasets/gray_scott_32, 723 MB, scripts/coarsen_dataset.py + src/autocast/data/coarsen.py, 2 tests, both mutation-checked; datamodule config gray_scott_32): Gray-Scott 32x32 written with stats — done when: `test -s $AUTOCAST_DATASETS/gray_scott_32/stats.yml`
- [x] G2 (DONE 16 Nov, Turing 381, 59 s on CPU; `gs32_rule_reads.{md,json}`; its range table's caption and cumulative row predate commit 1ffebf49 and count scale 0, the range itself does not): term over cycles 1-8, all 8 scales kept by the form test (scale 1 a tie, +0.012 [-0.003, +0.027], kept by D319); D310 WARNING: the per-window read gives 1-9 and the largest window's change is 102x the median's (the start-up burst, as on GS64); 195 patterns beside the term (the term holds 63.2% of the change variance), 452 with no term; conditioning inputs 2 and 3 constant in training and dropped (D295), as on GS64. So both arms: term 1-8 + joint rank dropout (D290), 195 patterns. Rule reads on the 32x32 data recorded in this folder — done when: `test -s notes/design/rank_ladder/conditioned_patterns/gs32_rule_reads.md`
- [x] G3 input-following sizes option built, tests green (DONE 16 Nov: 5c715957 worker build + 62ed6886 review simplification; 13 tests pass, 11 mutations red; report input_following_sizes_build_2026-11-16.md) — done when: `CUDA_VISIBLE_DEVICES= timeout 230 .venv/bin/python -m pytest -q -p no:cacheprovider tests -k input_following_sizes`
- [x] G4 pair trained and scored on Turing (DONE: Turing 382/384, scored 386/387 18 Nov; fetched 19 Nov) — done when: `test -d notes/design/rank_ladder/conditioned_patterns/gs32_pair_fetched`
- [x] G5 read written and put to the owner (DONE 19 Nov: read_gs32_input_following_sizes.md) — done when: `test -s notes/design/rank_ladder/conditioned_patterns/read_gs32_input_following_sizes.md`
## Cost check before the pair (16 Nov afternoon; estimate, not a measurement on GS32)
