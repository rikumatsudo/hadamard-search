# Final Summary

## 1. What Was Done

Implemented cluster-aware novelty scoring in `sage/07_guided_sds_search_668.sage` and ran two 30k smoke searches using the medoids from `outputs/explorations/20260505_1457_hadamard668_defect_cluster_lns/raw/defect_cluster_analysis.json`.

Regression status: `06_known_sds_regression.sage` passed before the novelty runs. No score-0 candidate appeared, and no success candidate was generated.

## 2. Novelty Implementation

Added cluster medoid loading, defect-vector distance metrics, novelty-aware JSON fields, novelty/cluster-distance buckets, and two objective schedules: `novelty_soft_l1` and `novelty_score_first`.

The saved near-hit records now include `nearest_cluster_id`, `nearest_cluster_distance`, `dist_l1_to_cluster0`, `support_symdiff_to_cluster0`, `novelty_score`, and `cluster_aware`.

## 3. Guided Results

| target | best metrics | best path | cluster | plateau escapes | dominated by existing frontier |
|---|---:|---|---:|---:|---|
| [73, 78, 79, 81], lambda=144 | 216 / 140 / 3 / 106 | `outputs/candidates/near_hits/near_hit_v167_score216_seed201_step19612.json` | nearest=4, dist0=208 | 3 | True |
| [73, 76, 83, 83], lambda=148 | 208 / 136 / 3 / 104 | `outputs/candidates/near_hits/near_hit_v167_score208_seed201_step17124.json` | nearest=0, dist0=180 | 2 | True |


