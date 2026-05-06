# Moment-preserving Score Repair Summary

Diagnostic only. Low-degree p-adic moment compatibility is a necessary
condition for an SDS over `Z_167`; it is not a success certificate.

## Implemented

- Added `sage/45_moment_preserving_score_repair.sage`.
- Updated `sage/43_padic_moment_basin_diagnostics.py` to also summarize
  `T2,T4,T6,T8,T10,T12`.
- The new repair script builds one-swap candidates, records
  `Delta T2/Delta T4/Delta T6/Delta T8/Delta T10/Delta T12`, combines swaps
  by beam search, then exactly reapplies each candidate and recomputes true
  metrics before saving.

## Main Results

### Experiment 1: score284 to all-zero closure

Input:

`outputs/candidates/near_hits/near_hit_v167_score284_moment_balanced_multiswap_repair_round2.json`

Initial metrics:

- score/l1/max/nonzero: `284 / 164 / 3 / 112`
- low moment signature: `T2,T4,T6 = 0,0,6`

Runs:

- score cap `340`, max_abs cap `6`: best all-zero low moment candidate had
  score `660`, so it did not meet the cap.
- score cap `420`, max_abs cap `6`: same best all-zero low moment candidate,
  score `660`; still outside cap.

Conclusion: score284 can close to `T2=T4=T6=0`, but not within score `<=340`
or `<=420` under this beam/LNS setup.

### Experiment 2: score436 all-zero score repair

Input:

`outputs/candidates/near_hits/near_hit_v167_score436_moment_balanced_multiswap_repair_round1.json`

Initial metrics:

- score/l1/max/nonzero: `436 / 220 / 6 / 140`
- low moment signature: `T2,T4,T6 = 0,0,0`

Best result:

`outputs/candidates/near_hits/near_hit_v167_score424_moment_preserving_score_repair_round1.json`

- score/l1/max/nonzero: `424 / 208 / 4 / 128`
- low moment signature: `0,0,0`
- extended signature: `0,0,0,112,51,39`
- `verify_sds=false`, `generated_hadamard=false`, `hh_t=false`

Conclusion: Stage A succeeded. The search lowered score while preserving
`T2=T4=T6=0`.

## Dataset After This Experiment

From `outputs/explorations/20260506_0200_hadamard668_moment_preserving_score_repair_diagnostics`:

- valid near-hits: `31538`
- low moment zero-count histogram: `{0: 30925, 1: 602, 2: 4, 3: 7}`
- all `T2,T4,T6` zero: `7`
- extended zero-count histogram: `{0: 30354, 1: 1158, 2: 18, 3: 8}`
- all `T2,T4,T6,T8,T10,T12` zero: `0`
- best low all-zero candidate by score:
  `outputs/candidates/near_hits/near_hit_v167_score424_moment_preserving_score_repair_round1.json`

## Interpretation

The moment route advanced from diagnosis to candidate generation:

- `T2=T4=T6=0` candidates can be generated deliberately.
- The best low all-zero score improved from `436` to `424`.
- The gap to the ordinary score frontier remains large: the best score-only
  branch is still around `164`.
- High moments are not aligned yet; the best low all-zero candidate has
  `T8,T10,T12 = 112,51,39`.

This supports the interpretation that low p-adic moment compatibility and low
SDS score currently pull in different directions, but the all-zero low-moment
surface is not completely rigid.

## Verification Status

- No score `0` candidate was generated.
- No Hadamard 668 construction was claimed.
- `06_known_sds_regression.sage` passed.
- Best new near-hit was checked with `08_analyze_sds_candidate.sage`.

Success remains defined only as:

1. score `0`;
2. explicit SDS verification;
3. Goethals-Seidel construction;
4. exact integer `H * H.transpose() == 668 * identity_matrix(ZZ, 668)`.
