# Moment-compatible Pool MITM Summary

Diagnostic only. `T2=T4=T6=0` is a low-degree necessary condition, not an SDS success certificate.

## Run

- tuple: `A`
- ks/lambda: `[73, 78, 79, 81]` / `144`
- blocks_per_k: `200`
- pair_samples: `20000`
- pair_bucket_limit: `20`
- max_candidates_eval: `200`

## Pool Stats

- pos 0, k=73: count=200, origins={'random_pool': 200}
- pos 1, k=78: count=200, origins={'random_pool': 200}
- pos 2, k=79: count=200, origins={'random_pool': 200}
- pos 3, k=81: count=200, origins={'random_pool': 200}

## MITM Stats

```json
{
  "evaluated": 95,
  "left_keys": 19967,
  "left_pair_samples": 20000,
  "left_pairs_kept": 20000,
  "matches_seen": 95,
  "right_pair_samples": 20000,
  "score_quantiles": {
    "count": 95,
    "median": 6900,
    "min": 4688,
    "p1": 4688,
    "p10": 5252,
    "p5": 5100
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
  "count": 200,
  "median": 6640,
  "min": 4284,
  "p1": 4536,
  "p10": 5304,
  "p5": 4912
}
```

## Best Moment-compatible Candidate

```json
{
  "block_hashes": [
    "c0d3258b38f785d45f3548d57dae5d8aedef8c46eeed00d38e0af065d773d19f",
    "fdf802fdfd137912ecdd3ffc764bb53b5e677820ce3181d1d435ce4c3c3da7f2",
    "e17d21303377b728c36132ec7588f6870ba9f207297a31320a0d0611e02f8302",
    "2fce74f95f5ae0a1f774839bdfd8e0c8c73f9097ade1b5a639937510eebc2e68"
  ],
  "block_origins": [
    "random_pool",
    "random_pool",
    "random_pool",
    "random_pool"
  ],
  "higher_moment_norm": 4574,
  "indices": [
    98,
    116,
    187,
    195
  ],
  "ks": [
    73,
    78,
    79,
    81
  ],
  "l1_error": 728,
  "lambda": 144,
  "max_abs_error": 12,
  "moment_signature_3": "0,0,0",
  "moment_signature_6": "0,0,0,124,49,18",
  "moment_zero_count_3": 3,
  "moment_zero_count_6": 3,
  "nonzero_defect_count": 158,
  "origin": "moment_pool_mitm",
  "padic_moments": {
    "T10": 49,
    "T12": 18,
    "T2": 0,
    "T4": 0,
    "T6": 0,
    "T8": 124
  },
  "saved_path": "outputs/candidates/near_hits/near_hit_v167_score4688_moment_compatible_pool_mitm_round1_1.json",
  "score": 4688,
  "tuple_id": "A"
}
```

## Best Higher-moment Candidate

```json
{
  "block_hashes": [
    "21c98d1a0a60901a3eb5f29d922c5dd7f69d3f8fe1966d55e8300c45815335ab",
    "20ae23bd0f7829cf59bf1b1dc5c7ee202238c49552ef14202aa8d3c2fcb7a3cd",
    "b7af4a3896b11bef9d18f97ea9724932de77a5b16f31ea058a711590cf942dd8",
    "9e6ed889cd0ddfd33367ec8d0c99783fa61c75e0cf157d550369a979c8cb39c1"
  ],
  "block_origins": [
    "random_pool",
    "random_pool",
    "random_pool",
    "random_pool"
  ],
  "higher_moment_norm": 405,
  "indices": [
    69,
    86,
    178,
    110
  ],
  "ks": [
    73,
    78,
    79,
    81
  ],
  "l1_error": 860,
  "lambda": 144,
  "max_abs_error": 24,
  "moment_signature_3": "0,0,0",
  "moment_signature_6": "0,0,0,157,7,16",
  "moment_zero_count_3": 3,
  "moment_zero_count_6": 3,
  "nonzero_defect_count": 160,
  "origin": "moment_pool_mitm",
  "padic_moments": {
    "T10": 7,
    "T12": 16,
    "T2": 0,
    "T4": 0,
    "T6": 0,
    "T8": 157
  },
  "saved_path": "outputs/candidates/near_hits/near_hit_v167_score7260_moment_compatible_pool_mitm_round1_1.json",
  "score": 7260,
  "tuple_id": "A"
}
```

## Saved Candidate JSON

- `outputs/candidates/near_hits/near_hit_v167_score4688_moment_compatible_pool_mitm_round1_1.json`
- `outputs/candidates/near_hits/near_hit_v167_score4788_moment_compatible_pool_mitm_round1_1.json`
- `outputs/candidates/near_hits/near_hit_v167_score7260_moment_compatible_pool_mitm_round1_1.json`

## Verdict

Negative for generative use in this run: best score stayed above 424.

No Hadamard 668 construction is claimed unless score 0 plus SDS and GS exact verification pass.
