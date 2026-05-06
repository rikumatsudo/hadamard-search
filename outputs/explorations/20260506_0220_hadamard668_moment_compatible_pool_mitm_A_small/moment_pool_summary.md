# Moment-compatible Pool MITM Summary

Diagnostic only. `T2=T4=T6=0` is a low-degree necessary condition, not an SDS success certificate.

## Run

- tuple: `A`
- ks/lambda: `[73, 78, 79, 81]` / `144`
- blocks_per_k: `5000`
- pair_samples: `1000000`
- pair_bucket_limit: `100`
- max_candidates_eval: `50000`

## Pool Stats

- pos 0, k=73: count=5000, origins={'mutated_pool_seed': 217, 'mutated_pool': 4783}
- pos 1, k=78: count=5000, origins={'mutated_pool_seed': 220, 'mutated_pool': 4780}
- pos 2, k=79: count=5000, origins={'mutated_pool_seed': 220, 'mutated_pool': 4780}
- pos 3, k=81: count=5000, origins={'mutated_pool_seed': 224, 'mutated_pool': 4776}

## MITM Stats

```json
{
  "evaluated": 50000,
  "left_keys": 899816,
  "left_pair_samples": 1000000,
  "left_pairs_kept": 1000000,
  "matches_seen": 50000,
  "right_pair_samples": 233872,
  "score_quantiles": {
    "count": 50000,
    "median": 5188,
    "min": 2304,
    "p1": 3456,
    "p10": 4156,
    "p5": 3900
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
  "median": 5172,
  "min": 2744,
  "p1": 3408,
  "p10": 4152,
  "p5": 3884
}
```

## Best Moment-compatible Candidate

```json
{
  "block_hashes": [
    "df27a719291f393d7a884b111d521bc17aca1223ca871069ec4995b1b1b10eb9",
    "361c0650f2335d5175d74cc0b2e5e367c7f3777aac1affbaea75cf69cf0ffeaa",
    "f2faf11f44b2e71c2f4db69b03f2afdd7be80f34b73ea9e519411c5496fb7bb0",
    "c56787eaa4d68bfc84b5b04733b2a3a8245c20babb6d1a26171735e840b75791"
  ],
  "block_origins": [
    "mutated_pool",
    "mutated_pool",
    "mutated_pool",
    "mutated_pool_seed"
  ],
  "higher_moment_norm": 1421,
  "indices": [
    4832,
    3831,
    2506,
    2119
  ],
  "ks": [
    73,
    78,
    79,
    81
  ],
  "l1_error": 500,
  "lambda": 144,
  "max_abs_error": 9,
  "moment_signature_3": "0,0,0",
  "moment_signature_6": "0,0,0,0,35,14",
  "moment_zero_count_3": 3,
  "moment_zero_count_6": 4,
  "nonzero_defect_count": 148,
  "origin": "moment_pool_mitm",
  "padic_moments": {
    "T10": 35,
    "T12": 14,
    "T2": 0,
    "T4": 0,
    "T6": 0,
    "T8": 0
  },
  "saved_path": "outputs/candidates/near_hits/near_hit_v167_score2304_moment_compatible_pool_mitm_round3.json",
  "score": 2304,
  "tuple_id": "A"
}
```

## Best Higher-moment Candidate

```json
{
  "block_hashes": [
    "18855c761bd5c66d826e3020be4e03d46143f2904977faed516679cca35cc7e8",
    "f760b6cfe8e41350968b0bb0729cfbeae632cfbc7b957318f5e400a2449862c1",
    "0c5e45b52092e41b413776172e678215a56d2318250a4f122a9e7d40121a1469",
    "964c11ee445b3724a58b8e0938e7529fdf63a19a15164a554e5e64a8288fcc51"
  ],
  "block_origins": [
    "mutated_pool",
    "mutated_pool",
    "mutated_pool",
    "mutated_pool_seed"
  ],
  "higher_moment_norm": 13,
  "indices": [
    4602,
    2925,
    420,
    4169
  ],
  "ks": [
    73,
    78,
    79,
    81
  ],
  "l1_error": 696,
  "lambda": 144,
  "max_abs_error": 14,
  "moment_signature_3": "0,0,0",
  "moment_signature_6": "0,0,0,165,3,0",
  "moment_zero_count_3": 3,
  "moment_zero_count_6": 4,
  "nonzero_defect_count": 150,
  "origin": "moment_pool_mitm",
  "padic_moments": {
    "T10": 3,
    "T12": 0,
    "T2": 0,
    "T4": 0,
    "T6": 0,
    "T8": 165
  },
  "saved_path": "outputs/candidates/near_hits/near_hit_v167_score4472_moment_compatible_pool_mitm_round1.json",
  "score": 4472,
  "tuple_id": "A"
}
```

## Saved Candidate JSON

- `outputs/candidates/near_hits/near_hit_v167_score2304_moment_compatible_pool_mitm_round1.json`
- `outputs/candidates/near_hits/near_hit_v167_score2456_moment_compatible_pool_mitm_round2.json`
- `outputs/candidates/near_hits/near_hit_v167_score2504_moment_compatible_pool_mitm_round3.json`
- `outputs/candidates/near_hits/near_hit_v167_score2504_moment_compatible_pool_mitm_round1.json`
- `outputs/candidates/near_hits/near_hit_v167_score2804_moment_compatible_pool_mitm_round2.json`
- `outputs/candidates/near_hits/near_hit_v167_score2304_moment_compatible_pool_mitm_round3.json`
- `outputs/candidates/near_hits/near_hit_v167_score4472_moment_compatible_pool_mitm_round1.json`
- `outputs/candidates/near_hits/near_hit_v167_score5812_moment_compatible_pool_mitm_round2.json`
- `outputs/candidates/near_hits/near_hit_v167_score5068_moment_compatible_pool_mitm_round3.json`

## Verdict

Negative for generative use in this run: best score stayed above 424.

No Hadamard 668 construction is claimed unless score 0 plus SDS and GS exact verification pass.
