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


## 4. Cluster Distance Reading

For `[73,78,79,81]`, the best record by objective/score reached nearest cluster 4, not cluster 0, but only at `score=216, l1=140, nonzero=106`, which is weaker than the existing frontier.

For `[73,76,83,83]`, the useful best records stayed nearest to cluster 0. Its best was `score=208, l1=136, nonzero=104`, also weaker than the existing frontier.

Pure `novelty` and `cluster_distance` buckets mostly selected very early high-score states, e.g. scores in the thousands. That means raw distance is working mechanically but is not yet useful without a score/l1 cap.

## 5. Verdict

Route verdict: cluster-aware novelty smoke did not produce a useful new basin. The implementation works, but the current novelty reward is too permissive and lets bad high-distance states dominate novelty buckets.

## 6. Next Candidates

1. Add score-capped novelty: only reward cluster distance when `score <= 260` or within a controlled slack of current best.
2. Use bounded novelty objectives: keep score/l1/max_abs as primary constraints and use cluster distance only as a tie-breaker.
3. If bounded novelty also fails, pivot to Constantine one-block completion or block-pair/autocorrelation hashing.

## 7. Safety Status

This exploration did not construct a Hadamard matrix of order 668. The outputs are near-hit/frontier diagnostics only. A success candidate requires exact SDS verification and Goethals-Seidel integer verification of `H * H.transpose() == 668 * identity_matrix(ZZ, 668)`.
