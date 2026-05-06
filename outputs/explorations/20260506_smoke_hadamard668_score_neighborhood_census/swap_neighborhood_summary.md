# 668 Score-neighborhood Census Summary

This is a local-neighborhood diagnostic for n=668 near-hits. No score-nonzero row is a Hadamard construction.

## 428 Calibration

| distance | score min | score median | note |
|---:|---:|---:|---|
| 1 | 48 | 104 | exact 428 after one swap; moments mostly nonzero |
| 2 | 80 | 200 | excluding exact-return degeneracy |
| 3 | 120 | 300 | sampled perturbations |
| 4 | 168 | 392 | sampled perturbations |

## Parents

- `score164`: path `outputs/candidates/near_hits/near_hit_v167_score164_steepest_swap_descent_round1.json`, metrics `{'score': 164, 'l1_error': 116, 'max_abs_error': 3, 'nonzero_defect_count': 96, 'T2': 117, 'T4': 85, 'T6': 49, 'T8': 32, 'T10': 41, 'T12': 34, 'moment_zero_count_3': 0, 'moment_zero_count_6': 0, 'higher_moment_norm': 3861}`, moments `{'T2': 117, 'T4': 85, 'T6': 49, 'T8': 32, 'T10': 41, 'T12': 34}`, metrics_match `True`
- `score176`: path `outputs/candidates/near_hits/near_hit_v167_score176_seed101_step8576.json`, metrics `{'score': 176, 'l1_error': 112, 'max_abs_error': 3, 'nonzero_defect_count': 86, 'T2': 31, 'T4': 138, 'T6': 20, 'T8': 144, 'T10': 106, 'T12': 21, 'moment_zero_count_3': 0, 'moment_zero_count_6': 0, 'higher_moment_norm': 4691}`, moments `{'T2': 31, 'T4': 138, 'T6': 20, 'T8': 144, 'T10': 106, 'T12': 21}`, metrics_match `True`

## Main Results

### score164

- full 1-swap local minimum: `True`
- full 1-swap count score < parent: `0`
- full 1-swap best score: `168`
- full 1-swap quantiles: min `168`, p1 `232`, p5 `256`, p10 `272`, median `324`
- full 1-swap threshold counts: `{'160': 0, '140': 0, '120': 0, '100': 0, '80': 0, '48': 0, '0': 0}`
- 2-swap M=30: best `176`, count score < parent `0`, thresholds `{'160': 0, '140': 0, '120': 0, '100': 0, '80': 0, '48': 0, '0': 0}`

### score176

- full 1-swap local minimum: `True`
- full 1-swap count score < parent: `0`
- full 1-swap best score: `184`
- full 1-swap quantiles: min `184`, p1 `240`, p5 `268`, p10 `280`, median `332`
- full 1-swap threshold counts: `{'160': 0, '140': 0, '120': 0, '100': 0, '80': 0, '48': 0, '0': 0}`
- 2-swap M=30: best `176`, count score < parent `0`, thresholds `{'160': 0, '140': 0, '120': 0, '100': 0, '80': 0, '48': 0, '0': 0}`

## Saved Candidates

Saved candidate JSON count: `64`
- `outputs/candidates/near_hits/near_hit_v167_score408_full_1swap_score164_1.json` score `408` l1 `192` max `5` nonzero `114` reason `frontier_moment`
- `outputs/candidates/near_hits/near_hit_v167_score340_full_1swap_score164_2.json` score `340` l1 `180` max `3` nonzero `114` reason `frontier_moment`
- `outputs/candidates/near_hits/near_hit_v167_score312_full_1swap_score164_3.json` score `312` l1 `184` max `3` nonzero `126` reason `frontier_moment`
- `outputs/candidates/near_hits/near_hit_v167_score344_full_1swap_score164_4.json` score `344` l1 `180` max `4` nonzero `120` reason `frontier_moment`
- `outputs/candidates/near_hits/near_hit_v167_score248_filtered_2swap_M30_score164_5.json` score `248` l1 `136` max `3` nonzero `92` reason `frontier_nonzero`
- `outputs/candidates/near_hits/near_hit_v167_score176_filtered_2swap_M30_score164_6.json` score `176` l1 `124` max `3` nonzero `100` reason `frontier_max_abs`
- `outputs/candidates/near_hits/near_hit_v167_score184_filtered_2swap_M30_score164_7.json` score `184` l1 `128` max `3` nonzero `104` reason `frontier_max_abs`
- `outputs/candidates/near_hits/near_hit_v167_score232_filtered_2swap_M30_score164_8.json` score `232` l1 `132` max `4` nonzero `92` reason `frontier_nonzero`
- `outputs/candidates/near_hits/near_hit_v167_score216_filtered_2swap_M30_score164_9.json` score `216` l1 `132` max `3` nonzero `96` reason `frontier_nonzero`
- `outputs/candidates/near_hits/near_hit_v167_score212_filtered_2swap_M30_score164_10.json` score `212` l1 `132` max `3` nonzero `94` reason `frontier_nonzero`
- `outputs/candidates/near_hits/near_hit_v167_score196_filtered_2swap_M30_score164_11.json` score `196` l1 `132` max `3` nonzero `102` reason `frontier_max_abs`
- `outputs/candidates/near_hits/near_hit_v167_score236_filtered_2swap_M30_score164_12.json` score `236` l1 `152` max `2` nonzero `110` reason `frontier_max_abs`
- `outputs/candidates/near_hits/near_hit_v167_score208_filtered_2swap_M30_score164_13.json` score `208` l1 `136` max `3` nonzero `106` reason `frontier_l1`
- `outputs/candidates/near_hits/near_hit_v167_score244_filtered_2swap_M30_score164_14.json` score `244` l1 `136` max `4` nonzero `94` reason `frontier_nonzero`
- `outputs/candidates/near_hits/near_hit_v167_score216_filtered_2swap_M30_score164_15.json` score `216` l1 `136` max `3` nonzero `98` reason `frontier_nonzero`
- `outputs/candidates/near_hits/near_hit_v167_score192_filtered_2swap_M30_score164_16.json` score `192` l1 `132` max `3` nonzero `106` reason `frontier_max_abs`
- `outputs/candidates/near_hits/near_hit_v167_score192_filtered_2swap_M30_score164_17.json` score `192` l1 `124` max `3` nonzero `92` reason `frontier_nonzero`
- `outputs/candidates/near_hits/near_hit_v167_score200_filtered_2swap_M30_score164_18.json` score `200` l1 `140` max `3` nonzero `112` reason `frontier_score`
- `outputs/candidates/near_hits/near_hit_v167_score272_filtered_2swap_M30_score164_19.json` score `272` l1 `144` max `4` nonzero `100` reason `frontier_moment`
- `outputs/candidates/near_hits/near_hit_v167_score252_filtered_2swap_M30_score164_20.json` score `252` l1 `144` max `3` nonzero `96` reason `frontier_nonzero`
- `outputs/candidates/near_hits/near_hit_v167_score256_filtered_2swap_M30_score164_21.json` score `256` l1 `140` max `3` nonzero `92` reason `frontier_nonzero`
- `outputs/candidates/near_hits/near_hit_v167_score252_filtered_2swap_M30_score164_22.json` score `252` l1 `140` max `4` nonzero `96` reason `frontier_nonzero`
- `outputs/candidates/near_hits/near_hit_v167_score200_filtered_2swap_M30_score164_23.json` score `200` l1 `128` max `3` nonzero `94` reason `frontier_nonzero`
- `outputs/candidates/near_hits/near_hit_v167_score236_filtered_2swap_M30_score164_24.json` score `236` l1 `136` max `3` nonzero `94` reason `frontier_nonzero`
- `outputs/candidates/near_hits/near_hit_v167_score248_filtered_2swap_M30_score164_25.json` score `248` l1 `136` max `5` nonzero `94` reason `frontier_nonzero`
- `outputs/candidates/near_hits/near_hit_v167_score204_filtered_2swap_M30_score164_26.json` score `204` l1 `136` max `3` nonzero `106` reason `frontier_l1`
- `outputs/candidates/near_hits/near_hit_v167_score244_filtered_2swap_M30_score164_27.json` score `244` l1 `148` max `3` nonzero `106` reason `frontier_moment`
- `outputs/candidates/near_hits/near_hit_v167_score220_filtered_2swap_M30_score164_28.json` score `220` l1 `148` max `2` nonzero `112` reason `frontier_max_abs`
- `outputs/candidates/near_hits/near_hit_v167_score228_filtered_2swap_M30_score164_29.json` score `228` l1 `124` max `3` nonzero `82` reason `frontier_nonzero`
- `outputs/candidates/near_hits/near_hit_v167_score204_filtered_2swap_M30_score164_30.json` score `204` l1 `136` max `3` nonzero `104` reason `frontier_l1`

## Required Answers

- `score164`: 1-swap local min `True`; 2-swap improvement `False`; 3-swap improvement `False`; best searched score `168`.
- `score176`: 1-swap local min `True`; 2-swap improvement `False`; 3-swap improvement `False`; best searched score `176`.

Threshold interpretation: score <=120/80/48 would match the 428 3/2/1-swap positive-control low-end scale. score=0 would trigger exact SDS and GS HH^T verification.

## Safety

- No Hadamard 668 construction is claimed here unless a score=0 candidate also passes exact SDS validation and Goethals-Seidel HH^T=668I over ZZ.
- p-adic moments are diagnostics; 428 perturbation shows they are not a smooth proximity metric under ordinary swaps.
