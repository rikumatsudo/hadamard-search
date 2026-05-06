# Coherent Multiswap Escape Summary

This experiment tests whether shallow 1-swap walls around score164/score176 can be escaped by coherent multi-swaps. It is not a Hadamard 668 construction claim.

## Parents

- `score164` path `outputs/candidates/near_hits/near_hit_v167_score164_steepest_swap_descent_round1.json` metrics `{'score': 164, 'l1_error': 116, 'max_abs_error': 3, 'nonzero_defect_count': 96, 'moment_zero_count_3': 0, 'moment_zero_count_6': 0, 'higher_moment_norm': 3861, 'T2': 117, 'T4': 85, 'T6': 49, 'T8': 32, 'T10': 41, 'T12': 34}` metrics_match `True`
- `score176` path `outputs/candidates/near_hits/near_hit_v167_score176_seed101_step8576.json` metrics `{'score': 176, 'l1_error': 112, 'max_abs_error': 3, 'nonzero_defect_count': 86, 'moment_zero_count_3': 0, 'moment_zero_count_6': 0, 'higher_moment_norm': 4691, 'T2': 31, 'T4': 138, 'T6': 20, 'T8': 144, 'T10': 106, 'T12': 21}` metrics_match `True`

## 428 Calibration

- 428 distance1 score48: one-swap return has `min_h=-48`, `D_min_ratio=0`.
- 428 distance2 score80: one-swap returns/improvements exist, `D_min_ratio=0`.

## Results

### score164

- beam mode=target_delta M=1000 depth=3: states `2000`, evaluated `2000`, best `184`, improvements `0`, mismatches `883`
- beam mode=target_delta M=1000 depth=3: states `2000`, evaluated `2000`, best `184`, improvements `0`, mismatches `883`
- beam mode=target_delta M=1000 depth=4: states `2000`, evaluated `2000`, best `180`, improvements `0`, mismatches `1457`

### score176

- beam mode=target_delta M=1000 depth=3: states `2000`, evaluated `2000`, best `192`, improvements `0`, mismatches `1032`
- beam mode=target_delta M=1000 depth=3: states `2000`, evaluated `2000`, best `192`, improvements `0`, mismatches `1032`
- beam mode=target_delta M=1000 depth=4: states `2000`, evaluated `2000`, best `188`, improvements `0`, mismatches `1590`

## Saved Candidates

Saved candidate JSON count: `105`
- `outputs/candidates/near_hits/near_hit_v167_score200_coherent_multiswap_escape_score164_1_1.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `200` l1 `140` max `3` nonzero `112` reason `frontier_h_total` mismatch `16`
- `outputs/candidates/near_hits/near_hit_v167_score208_coherent_multiswap_escape_score164_2.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `208` l1 `124` max `3` nonzero `86` reason `frontier_nonzero` mismatch `0`
- `outputs/candidates/near_hits/near_hit_v167_score188_coherent_multiswap_escape_score164_3.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `188` l1 `140` max `3` nonzero `118` reason `frontier_h_total` mismatch `0`
- `outputs/candidates/near_hits/near_hit_v167_score212_coherent_multiswap_escape_score164_4.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `212` l1 `124` max `4` nonzero `90` reason `frontier_l1` mismatch `0`
- `outputs/candidates/near_hits/near_hit_v167_score236_coherent_multiswap_escape_score164_5.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `236` l1 `156` max `3` nonzero `122` reason `frontier_moment` mismatch `4`
- `outputs/candidates/near_hits/near_hit_v167_score236_coherent_multiswap_escape_score164_6.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `236` l1 `132` max `4` nonzero `88` reason `frontier_nonzero` mismatch `0`
- `outputs/candidates/near_hits/near_hit_v167_score220_coherent_multiswap_escape_score164_7.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `220` l1 `124` max `4` nonzero `88` reason `frontier_nonzero` mismatch `0`
- `outputs/candidates/near_hits/near_hit_v167_score244_coherent_multiswap_escape_score164_8.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `244` l1 `152` max `3` nonzero `114` reason `frontier_moment` mismatch `0`
- `outputs/candidates/near_hits/near_hit_v167_score192_coherent_multiswap_escape_score164_9_1.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `192` l1 `132` max `2` nonzero `102` reason `frontier_max_abs` mismatch `-4`
- `outputs/candidates/near_hits/near_hit_v167_score192_coherent_multiswap_escape_score164_10_1.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `192` l1 `132` max `2` nonzero `102` reason `frontier_max_abs` mismatch `-16`
- `outputs/candidates/near_hits/near_hit_v167_score192_coherent_multiswap_escape_score164_11.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `192` l1 `128` max `3` nonzero `100` reason `frontier_l1` mismatch `0`
- `outputs/candidates/near_hits/near_hit_v167_score184_coherent_multiswap_escape_score164_12_1.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `184` l1 `124` max `2` nonzero `94` reason `frontier_max_abs` mismatch `-4`
- `outputs/candidates/near_hits/near_hit_v167_score184_coherent_multiswap_escape_score164_13_1.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `184` l1 `124` max `2` nonzero `94` reason `frontier_max_abs` mismatch `-24`
- `outputs/candidates/near_hits/near_hit_v167_score232_coherent_multiswap_escape_score164_14_1.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `232` l1 `148` max `3` nonzero `112` reason `frontier_moment` mismatch `0`
- `outputs/candidates/near_hits/near_hit_v167_score204_coherent_multiswap_escape_score164_15.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `204` l1 `144` max `2` nonzero `114` reason `frontier_max_abs` mismatch `-12`
- `outputs/candidates/near_hits/near_hit_v167_score184_coherent_multiswap_escape_score164_16.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `184` l1 `132` max `3` nonzero `108` reason `frontier_h_total` mismatch `4`
- `outputs/candidates/near_hits/near_hit_v167_score188_coherent_multiswap_escape_score164_17.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `188` l1 `132` max `3` nonzero `108` reason `frontier_h_total` mismatch `0`
- `outputs/candidates/near_hits/near_hit_v167_score248_coherent_multiswap_escape_score164_18.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `248` l1 `132` max `4` nonzero `88` reason `frontier_nonzero` mismatch `0`
- `outputs/candidates/near_hits/near_hit_v167_score204_coherent_multiswap_escape_score164_19.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `204` l1 `140` max `2` nonzero `108` reason `frontier_max_abs` mismatch `-4`
- `outputs/candidates/near_hits/near_hit_v167_score224_coherent_multiswap_escape_score164_20.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `224` l1 `136` max `3` nonzero `100` reason `frontier_moment` mismatch `-4`
- `outputs/candidates/near_hits/near_hit_v167_score232_coherent_multiswap_escape_score164_21.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `232` l1 `128` max `3` nonzero `86` reason `frontier_nonzero` mismatch `12`
- `outputs/candidates/near_hits/near_hit_v167_score192_coherent_multiswap_escape_score164_22.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `192` l1 `128` max `3` nonzero `98` reason `frontier_l1` mismatch `-12`
- `outputs/candidates/near_hits/near_hit_v167_score192_coherent_multiswap_escape_score164_23_1.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `192` l1 `128` max `3` nonzero `98` reason `frontier_l1` mismatch `-12`
- `outputs/candidates/near_hits/near_hit_v167_score228_coherent_multiswap_escape_score164_24.json` parent `score164` depth `3` method `beam_target_delta_M1000_D3` score `228` l1 `144` max `3` nonzero `104` reason `frontier_moment` mismatch `-12`
- `outputs/candidates/near_hits/near_hit_v167_score200_coherent_multiswap_escape_score164_25.json` parent `score164` depth `3` method `beam_target_delta_M1000_D4` score `200` l1 `140` max `3` nonzero `112` reason `frontier_h_total` mismatch `16`
- `outputs/candidates/near_hits/near_hit_v167_score208_coherent_multiswap_escape_score164_26.json` parent `score164` depth `3` method `beam_target_delta_M1000_D4` score `208` l1 `124` max `3` nonzero `86` reason `frontier_nonzero` mismatch `0`
- `outputs/candidates/near_hits/near_hit_v167_score188_coherent_multiswap_escape_score164_27.json` parent `score164` depth `3` method `beam_target_delta_M1000_D4` score `188` l1 `140` max `3` nonzero `118` reason `frontier_h_total` mismatch `0`
- `outputs/candidates/near_hits/near_hit_v167_score212_coherent_multiswap_escape_score164_28.json` parent `score164` depth `3` method `beam_target_delta_M1000_D4` score `212` l1 `124` max `4` nonzero `90` reason `frontier_l1` mismatch `0`
- `outputs/candidates/near_hits/near_hit_v167_score236_coherent_multiswap_escape_score164_29.json` parent `score164` depth `3` method `beam_target_delta_M1000_D4` score `236` l1 `156` max `3` nonzero `122` reason `frontier_moment` mismatch `4`
- `outputs/candidates/near_hits/near_hit_v167_score236_coherent_multiswap_escape_score164_30.json` parent `score164` depth `3` method `beam_target_delta_M1000_D4` score `236` l1 `132` max `4` nonzero `88` reason `frontier_nonzero` mismatch `0`
- `outputs/candidates/near_hits/near_hit_v167_score220_coherent_multiswap_escape_score164_31.json` parent `score164` depth `3` method `beam_target_delta_M1000_D4` score `220` l1 `124` max `4` nonzero `88` reason `frontier_nonzero` mismatch `0`
- `outputs/candidates/near_hits/near_hit_v167_score244_coherent_multiswap_escape_score164_32.json` parent `score164` depth `3` method `beam_target_delta_M1000_D4` score `244` l1 `152` max `3` nonzero `114` reason `frontier_moment` mismatch `0`
- `outputs/candidates/near_hits/near_hit_v167_score192_coherent_multiswap_escape_score164_33.json` parent `score164` depth `3` method `beam_target_delta_M1000_D4` score `192` l1 `132` max `2` nonzero `102` reason `frontier_max_abs` mismatch `-4`
- `outputs/candidates/near_hits/near_hit_v167_score192_coherent_multiswap_escape_score164_34.json` parent `score164` depth `3` method `beam_target_delta_M1000_D4` score `192` l1 `132` max `2` nonzero `102` reason `frontier_max_abs` mismatch `-16`
- `outputs/candidates/near_hits/near_hit_v167_score184_coherent_multiswap_escape_score164_35_1.json` parent `score164` depth `3` method `beam_target_delta_M1000_D4` score `184` l1 `124` max `2` nonzero `94` reason `frontier_max_abs` mismatch `-4`
- `outputs/candidates/near_hits/near_hit_v167_score184_coherent_multiswap_escape_score164_36.json` parent `score164` depth `3` method `beam_target_delta_M1000_D4` score `184` l1 `124` max `2` nonzero `94` reason `frontier_max_abs` mismatch `-24`
- `outputs/candidates/near_hits/near_hit_v167_score232_coherent_multiswap_escape_score164_37.json` parent `score164` depth `3` method `beam_target_delta_M1000_D4` score `232` l1 `148` max `3` nonzero `112` reason `frontier_moment` mismatch `0`
- `outputs/candidates/near_hits/near_hit_v167_score204_coherent_multiswap_escape_score164_38.json` parent `score164` depth `3` method `beam_target_delta_M1000_D4` score `204` l1 `144` max `2` nonzero `114` reason `frontier_max_abs` mismatch `-12`
- `outputs/candidates/near_hits/near_hit_v167_score184_coherent_multiswap_escape_score164_39.json` parent `score164` depth `3` method `beam_target_delta_M1000_D4` score `184` l1 `132` max `3` nonzero `108` reason `frontier_h_total` mismatch `4`
- `outputs/candidates/near_hits/near_hit_v167_score188_coherent_multiswap_escape_score164_40.json` parent `score164` depth `3` method `beam_target_delta_M1000_D4` score `188` l1 `132` max `3` nonzero `108` reason `frontier_h_total` mismatch `0`

## Required Answers

1/2. `score164` true_score < parent: `False`; best score `180` from `target_delta depth 4`.
1/2. `score176` true_score < parent: `False`; best score `188` from `target_delta depth 4`.
3. score <=120 / 80 / 48 / 0 reached: `False` / `False` / `False` / `False`.
4. Best depth is shown per parent above.
5. Cross-cancellation is recorded in all saved candidate JSON and `frontier_best_by_cross.jsonl`.
6. Individual-h-bad but combined-improving examples exist iff any saved row has `score < parent_score` and depth > 1.
7. Moment diagnostics are saved, but they are not the main objective.
8. If no improvement appears through tested depths, these basins remain hard under coherent multi-swap at this search scale.
9. Next direction should be based on whether improvement was found: continue depth/LNS if yes; otherwise move to pair-level defect repair or new basin.

## Safety

- No score-nonzero candidate is a success candidate.
- score=0 would still require exact SDS validation and Goethals-Seidel HH^T=668I over ZZ.
- Approximate delta scores are always checked against true recomputation for retained/evaluated candidates.
