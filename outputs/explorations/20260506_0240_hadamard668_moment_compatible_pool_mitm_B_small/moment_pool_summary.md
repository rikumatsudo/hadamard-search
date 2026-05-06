# Moment-compatible Pool MITM Summary

Diagnostic only. `T2=T4=T6=0` is a low-degree necessary condition, not an SDS success certificate.

## Run

- tuple: `B`
- ks/lambda: `[73, 76, 83, 83]` / `148`
- blocks_per_k: `5000`
- pair_samples: `1000000`
- pair_bucket_limit: `100`
- max_candidates_eval: `50000`

## Pool Stats

- pos 0, k=73: count=5000, origins={'mutated_pool_seed': 182, 'mutated_pool': 4818}
- pos 1, k=76: count=5000, origins={'mutated_pool_seed': 187, 'mutated_pool': 4813}
- pos 2, k=83: count=5000, origins={'mutated_pool_seed': 188, 'mutated_pool': 4812}
- pos 3, k=83: count=5000, origins={'mutated_pool_seed': 166, 'mutated_pool': 4834}

## MITM Stats

```json
{
  "evaluated": 50000,
  "left_keys": 900014,
  "left_pair_samples": 1000000,
  "left_pairs_kept": 1000000,
  "matches_seen": 50000,
  "right_pair_samples": 231819,
  "score_quantiles": {
    "count": 50000,
    "median": 4960,
    "min": 1556,
    "p1": 3028,
    "p10": 3864,
    "p5": 3572
  },
  "threshold_counts": {
    "240": 0,
    "280": 0,
    "300": 0,
    "320": 0,
    "360": 0,
    "400": 0,
    "424": 0,
    "450": 0,
    "500": 0
  }
}
```

## Baseline

```json
{
  "count": 5000,
  "median": 4956,
  "min": 2164,
  "p1": 2984,
  "p10": 3880,
  "p5": 3568
}
```

## Best Moment-compatible Candidate

```json
{
  "block_hashes": [
    "fc9ce1ae3ae8524c177f16b13bd2fe0517257c8d5fcaa867dc2269f62e8cf25b",
    "de69ed36b9d2220a9a2e7553db2a6b6a60ffcef4edb7ef348044e49e3fd51c92",
    "ccfdae8ad9a7bfa96d64a4cf4b0e705aa67785d06b66e9a9b2022448faa19ec7",
    "c6940f9dceba3ff87877bebd5d21bf6cf848877e80aeac18f7b49282295a9747"
  ],
  "block_origins": [
    "mutated_pool",
    "mutated_pool",
    "mutated_pool",
    "mutated_pool"
  ],
  "higher_moment_norm": 12748,
  "indices": [
    2060,
    2526,
    2005,
    2358
  ],
  "ks": [
    73,
    76,
    83,
    83
  ],
  "l1_error": 400,
  "lambda": 148,
  "max_abs_error": 7,
  "moment_signature_3": "0,0,0",
  "moment_signature_6": "0,0,0,70,42,89",
  "moment_zero_count_3": 3,
  "moment_zero_count_6": 3,
  "nonzero_defect_count": 146,
  "origin": "moment_pool_mitm",
  "padic_moments": {
    "T10": 42,
    "T12": 89,
    "T2": 0,
    "T4": 0,
    "T6": 0,
    "T8": 70
  },
  "saved_path": "outputs/candidates/near_hits/near_hit_v167_score1556_moment_compatible_pool_mitm_round1_1.json",
  "score": 1556,
  "tuple_id": "B"
}
```

## Best Higher-moment Candidate

```json
{
  "block_hashes": [
    "aea23a89f73d78edb44ccd48438e0bbffec4768b628fce1058289cf479664049",
    "dc7af6702c040ebcefc135bf2790447da5ef9406e04fa87428a6d3b7a3420fb2",
    "bbf3b57d29cf33c1206e550532a1f2b44a213cce4edc8f9fde675f8354d8e481",
    "ee052f8b622c3a95c4ca6f790869bc6b7e1668d1faf84809be0eb496e7a3127e"
  ],
  "block_origins": [
    "mutated_pool",
    "mutated_pool",
    "mutated_pool",
    "mutated_pool"
  ],
  "higher_moment_norm": 5,
  "indices": [
    1436,
    1567,
    2397,
    2527
  ],
  "ks": [
    73,
    76,
    83,
    83
  ],
  "l1_error": 752,
  "lambda": 148,
  "max_abs_error": 13,
  "moment_signature_3": "0,0,0",
  "moment_signature_6": "0,0,0,1,2,0",
  "moment_zero_count_3": 3,
  "moment_zero_count_6": 4,
  "nonzero_defect_count": 158,
  "origin": "moment_pool_mitm",
  "padic_moments": {
    "T10": 2,
    "T12": 0,
    "T2": 0,
    "T4": 0,
    "T6": 0,
    "T8": 1
  },
  "saved_path": "outputs/candidates/near_hits/near_hit_v167_score4784_moment_compatible_pool_mitm_round1.json",
  "score": 4784,
  "tuple_id": "B"
}
```

## Saved Candidate JSON

- `outputs/candidates/near_hits/near_hit_v167_score1556_moment_compatible_pool_mitm_round1.json`
- `outputs/candidates/near_hits/near_hit_v167_score1684_moment_compatible_pool_mitm_round2.json`
- `outputs/candidates/near_hits/near_hit_v167_score1772_moment_compatible_pool_mitm_round3.json`
- `outputs/candidates/near_hits/near_hit_v167_score1556_moment_compatible_pool_mitm_round1_1.json`
- `outputs/candidates/near_hits/near_hit_v167_score1684_moment_compatible_pool_mitm_round2_1.json`
- `outputs/candidates/near_hits/near_hit_v167_score1880_moment_compatible_pool_mitm_round3.json`
- `outputs/candidates/near_hits/near_hit_v167_score4784_moment_compatible_pool_mitm_round1.json`
- `outputs/candidates/near_hits/near_hit_v167_score5704_moment_compatible_pool_mitm_round2.json`
- `outputs/candidates/near_hits/near_hit_v167_score5392_moment_compatible_pool_mitm_round3.json`

## Verdict

Negative for generative use in this run: best score stayed above 424.

No Hadamard 668 construction is claimed unless score 0 plus SDS and GS exact verification pass.
