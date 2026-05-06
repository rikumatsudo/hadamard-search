# Small-p SDS Pipeline Design

This file documents the config-driven pipeline used by `56_small_p_pipeline_framework.sage`.
The p=37 target is a validation case with a known exact SDS and observed low-score false basins.

## Stage 1: tuple registry / target registry

- Input: `p`, `ks`, `lambda`, optional `exact_json`.
- Output: `target_registry.json`.
- Hypothesis: tuple choice is an upstream experimental variable, not a byproduct of best score.
- Metrics: row sums, parameter equation status, known-exact availability.

## Stage 2: exact validation

- Input: known exact candidate JSON.
- Output: `exact_validation.json`.
- Hypothesis: pipeline validation should start from a verified SDS/GS baseline.
- Metrics: score, l1, max defect, SDS OK, `HH^T = 4pI`.

## Stage 3: initialization factory

- Input: target registry, random seed, optional exact and near-hit pools.
- Output: `initial_candidates.jsonl`, `initialization_summary.json`.
- Families: pure random, low-energy random, score-biased random, energy-regularized, mixed-diversity, near-hit perturbation, exact perturbation.
- Hypothesis: below-random score plus near-random hardness and local entropy proxies should produce better starts.
- Metrics: score, E/AP, Q_tot, Q ratio, InitHardness, defect pattern, canonical hash.

## Stage 4: trajectory runner

- Input: target and initialization policy.
- Output: `trajectory_runs.jsonl`.
- Modes: score-only, escapability-aware, energy-regularized init, mixed-diversity, threshold accepting.
- Hypothesis: score-only over-selects low-score false basins; return-like dynamics should separate modes.
- Metrics: accepted moves, best score, final score, score0 success, hard-basin flag.

## Stage 5: diagnostic engine

- Input: initial candidates, trajectory bests, exact candidate, discovered low-score candidates.
- Output: `diagnostic_candidates.jsonl`.
- Hypothesis: h_min, D_min/S, P_tau, kappa and Q_ratio expose landscape shape better than score alone.
- Metrics: score, l1, max_abs, nonzero, h_min, D_min, P thresholds, kappa quantiles, Q, E/AP, p-adic moments.

## Stage 6: false-basin classifier / labeler

- Input: diagnostic candidate rows and optional exact candidate.
- Output: `candidate_labels.jsonl`, `false_basin_classifier_features.csv`.
- Hypothesis: exact-derived and search-derived false basins differ in return radius proxy and local escapability.
- Metrics: return radius proxy, D_min/S, P_tau, kappa_max, h_min, score, defect pattern.

## Stage 7: repair / LNS hooks

- Input: selected low-score or hard-basin diagnostic candidates.
- Output: `repair_attempts.jsonl`, `repair_summary.json`.
- Hooks: exact-joint r-swap LNS, negative-cross pair search, sparse vector cancellation beam, pair-level partial defect repair, moment-late repair.
- Hypothesis: repair API should be uniform before heavy search is added.
- Metrics: score before/after, h_min before/after, D_min before/after, P_tau, true score, linearized score, interaction gap.

## Stage 8: report generator

- Input: all stage outputs.
- Output: `pipeline_framework_summary.md`, `comparison_summary.csv`, `comparison_summary.json`.
- Hypothesis: each smoke run should explain what to run next without reading raw JSONL.

## p=37 validation plan

- Target: p=37, ks=[13, 16, 18, 18], lambda=28.
- Exact JSON: `outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json`.
- Run `pipeline_smoke` with 10 seeds, 1000 steps and 20 initial candidates per family.
- Confirm exact SDS/GS validation and compare search-derived score4 false-basin features against exact-derived perturbations.

## Returning to 668

- Use this pipeline first to label tuple and candidate families by return-like dynamics.
- Treat score164/176 as diagnostic near-hits, not as solution progress by itself.
- Run moment-late only after score and local repair diagnostics indicate a closure-like state.
- Prefer config changes over new one-off scripts.
