# Moment-compatible Pool MITM Summary

Diagnostic only. `T2=T4=T6=0` is a low-degree necessary condition, not an SDS success certificate.

## Run

- tuple: `A`
- ks/lambda: `[73, 78, 79, 81]` / `144`
- blocks_per_k: `50000`
- pair_samples: `2000000`
- pair_bucket_limit: `200`
- max_candidates_eval: `200000`

## Pool Stats

- pos 0, k=73: count=50000, origins={'mutated_pool_seed': 1348, 'mutated_pool': 48652}
- pos 1, k=78: count=50000, origins={'mutated_pool_seed': 1328, 'mutated_pool': 48672}
- pos 2, k=79: count=50000, origins={'mutated_pool_seed': 1366, 'mutated_pool': 48634}
- pos 3, k=81: count=50000, origins={'mutated_pool_seed': 1338, 'mutated_pool': 48662}

## MITM Stats

```json
{
  "evaluated": 200000,
  "left_keys": 1626235,
  "left_pair_samples": 2000000,
  "left_pairs_kept": 2000000,
  "matches_seen": 200000,
  "right_pair_samples": 463732,
  "score_quantiles": {
    "count": 200000,
    "median": 5164,
    "min": 2256,
    "p1": 3440,
    "p10": 4144,
    "p5": 3888
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
  "count": 10000,
  "median": 5168,
  "min": 2760,
  "p1": 3452,
  "p10": 4136,
  "p5": 3892
}
```

## Best Moment-compatible Candidate

```json
{
  "block_hashes": [
    "764b7d6ee42826eb9937fd6182cc83685e87b38ca66011805c86885b4e3ceebb",
    "ffa21c6f1fe8634cee9617bf4d7843a22d84b199965b23760113bb93d6970310",
    "f5122ee517a4b3b7ab03e857e9d375eb787ec5c82090faab50308ae1681b0264",
    "fa67e6ead312755a639b5201955a5c331073f76bc8c9a9de13e3c6b0769c4a16"
  ],
  "block_origins": [
    "mutated_pool",
    "mutated_pool",
    "mutated_pool",
    "mutated_pool"
  ],
  "higher_moment_norm": 11786,
  "indices": [
    17665,
    46326,
    11527,
    11013
  ],
  "ks": [
    73,
    78,
    79,
    81
  ],
  "l1_error": 460,
  "lambda": 144,
  "max_abs_error": 12,
  "moment_signature_3": "0,0,0",
  "moment_signature_6": "0,0,0,69,25,87",
  "moment_zero_count_3": 3,
  "moment_zero_count_6": 3,
  "nonzero_defect_count": 134,
  "origin": "moment_pool_mitm",
  "padic_moments": {
    "T10": 25,
    "T12": 87,
    "T2": 0,
    "T4": 0,
    "T6": 0,
    "T8": 69
  },
  "saved_path": "outputs/candidates/near_hits/near_hit_v167_score2256_moment_compatible_pool_mitm_round1_1.json",
  "score": 2256,
  "tuple_id": "A"
}
```

## Best Higher-moment Candidate

```json
{
  "block_hashes": [
    "0d345ee868999ac9493085f7c9e0d28564df4b1423f2743a956130392024c9ec",
    "038e39f6a74669209cb9e92bae9ea3b5e30de603472c1f3c92ac387395905dab",
    "762e73e65c0d3a55ccc451fb8a12cc9e53f3de95823cf61b119ad99299887e1d",
    "b23cb468bad8d9b8073524dba3f5dc2aa805fc93c86e10ea7fd5e9832ce055f0"
  ],
  "block_origins": [
    "mutated_pool",
    "mutated_pool",
    "mutated_pool",
    "mutated_pool"
  ],
  "higher_moment_norm": 1,
  "indices": [
    19052,
    49134,
    36626,
    27540
  ],
  "ks": [
    73,
    78,
    79,
    81
  ],
  "l1_error": 796,
  "lambda": 144,
  "max_abs_error": 19,
  "moment_signature_3": "0,0,0",
  "moment_signature_6": "0,0,0,0,0,1",
  "moment_zero_count_3": 3,
  "moment_zero_count_6": 5,
  "nonzero_defect_count": 148,
  "origin": "moment_pool_mitm",
  "padic_moments": {
    "T10": 0,
    "T12": 1,
    "T2": 0,
    "T4": 0,
    "T6": 0,
    "T8": 0
  },
  "saved_path": "outputs/candidates/near_hits/near_hit_v167_score6192_moment_compatible_pool_mitm_round1.json",
  "score": 6192,
  "tuple_id": "A"
}
```

## Saved Candidate JSON

- `outputs/candidates/near_hits/near_hit_v167_score2256_moment_compatible_pool_mitm_round1.json`
- `outputs/candidates/near_hits/near_hit_v167_score2340_moment_compatible_pool_mitm_round2.json`
- `outputs/candidates/near_hits/near_hit_v167_score2344_moment_compatible_pool_mitm_round3.json`
- `outputs/candidates/near_hits/near_hit_v167_score2256_moment_compatible_pool_mitm_round1_1.json`
- `outputs/candidates/near_hits/near_hit_v167_score2416_moment_compatible_pool_mitm_round2.json`
- `outputs/candidates/near_hits/near_hit_v167_score2704_moment_compatible_pool_mitm_round3.json`
- `outputs/candidates/near_hits/near_hit_v167_score6192_moment_compatible_pool_mitm_round1.json`
- `outputs/candidates/near_hits/near_hit_v167_score4672_moment_compatible_pool_mitm_round2.json`
- `outputs/candidates/near_hits/near_hit_v167_score5004_moment_compatible_pool_mitm_round3.json`

## Verdict

Negative for generative use in this run: best score stayed above 424.

No Hadamard 668 construction is claimed unless score 0 plus SDS and GS exact verification pass.
