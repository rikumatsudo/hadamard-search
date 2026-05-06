# Moment-compatible Pool MITM Summary

Diagnostic only. `T2=T4=T6=0` is a low-degree necessary condition, not an SDS success certificate.

## Run

- tuple: `C`
- ks/lambda: `[76, 76, 77, 80]` / `142`
- blocks_per_k: `5000`
- pair_samples: `1000000`
- pair_bucket_limit: `100`
- max_candidates_eval: `50000`

## Pool Stats

- pos 0, k=76: count=5000, origins={'mutated_pool_seed': 176, 'mutated_pool': 4824}
- pos 1, k=76: count=5000, origins={'mutated_pool_seed': 173, 'mutated_pool': 4827}
- pos 2, k=77: count=5000, origins={'mutated_pool_seed': 187, 'mutated_pool': 4813}
- pos 3, k=80: count=5000, origins={'mutated_pool_seed': 173, 'mutated_pool': 4827}

## MITM Stats

```json
{
  "evaluated": 50000,
  "left_keys": 899682,
  "left_pair_samples": 1000000,
  "left_pairs_kept": 1000000,
  "matches_seen": 50000,
  "right_pair_samples": 232698,
  "score_quantiles": {
    "count": 50000,
    "median": 5184,
    "min": 2388,
    "p1": 3376,
    "p10": 4120,
    "p5": 3844
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
  "median": 5204,
  "min": 2472,
  "p1": 3300,
  "p10": 4116,
  "p5": 3824
}
```

## Best Moment-compatible Candidate

```json
{
  "block_hashes": [
    "4322dc71a340204c888c680bec782c5918c7eb7b2cba4f0215a9e29474090d53",
    "ce26748ce3e557451ae053c95daa3771dfc2d0e7e53346655d00d253f4f26200",
    "2ef1c6631806384186da989961fa88c2fe22a031559835b58a9df6e25e44b6ed",
    "a7d2d27945f70748072941a748186619bf3ade445fac679f808de8916fcd75dc"
  ],
  "block_origins": [
    "mutated_pool",
    "mutated_pool",
    "mutated_pool",
    "mutated_pool"
  ],
  "higher_moment_norm": 5205,
  "indices": [
    1545,
    1023,
    3798,
    2781
  ],
  "ks": [
    76,
    76,
    77,
    80
  ],
  "l1_error": 496,
  "lambda": 142,
  "max_abs_error": 9,
  "moment_signature_3": "0,0,0",
  "moment_signature_6": "0,0,0,10,159,71",
  "moment_zero_count_3": 3,
  "moment_zero_count_6": 3,
  "nonzero_defect_count": 140,
  "origin": "moment_pool_mitm",
  "padic_moments": {
    "T10": 159,
    "T12": 71,
    "T2": 0,
    "T4": 0,
    "T6": 0,
    "T8": 10
  },
  "saved_path": "outputs/candidates/near_hits/near_hit_v167_score2388_moment_compatible_pool_mitm_round1.json",
  "score": 2388,
  "tuple_id": "C"
}
```

## Best Higher-moment Candidate

```json
{
  "block_hashes": [
    "bc7a9f06f5aacd7ef3956d2431c04c461ccad61dd30e3aa706e0c9a3ac7c81de",
    "0fa7ba47e58307cc37c0a449cd074dbbac1609a640b6a89b5e82d8f7b2b83901",
    "48cdd4e9fe703abc7164c7544ff6280208caedb03c81c66fb957808c3613b1da",
    "014dde8afac9f41f4047c3d65c2bc09f36d3ad1632055fe023a159eae90c1f70"
  ],
  "block_origins": [
    "mutated_pool",
    "mutated_pool",
    "mutated_pool",
    "mutated_pool"
  ],
  "higher_moment_norm": 5,
  "indices": [
    127,
    4537,
    197,
    4461
  ],
  "ks": [
    76,
    76,
    77,
    80
  ],
  "l1_error": 684,
  "lambda": 142,
  "max_abs_error": 16,
  "moment_signature_3": "0,0,0",
  "moment_signature_6": "0,0,0,1,2,0",
  "moment_zero_count_3": 3,
  "moment_zero_count_6": 4,
  "nonzero_defect_count": 160,
  "origin": "moment_pool_mitm",
  "padic_moments": {
    "T10": 2,
    "T12": 0,
    "T2": 0,
    "T4": 0,
    "T6": 0,
    "T8": 1
  },
  "saved_path": "outputs/candidates/near_hits/near_hit_v167_score4664_moment_compatible_pool_mitm_round1.json",
  "score": 4664,
  "tuple_id": "C"
}
```

## Saved Candidate JSON

- `outputs/candidates/near_hits/near_hit_v167_score2388_moment_compatible_pool_mitm_round1.json`
- `outputs/candidates/near_hits/near_hit_v167_score2428_moment_compatible_pool_mitm_round2.json`
- `outputs/candidates/near_hits/near_hit_v167_score2460_moment_compatible_pool_mitm_round3.json`
- `outputs/candidates/near_hits/near_hit_v167_score2428_moment_compatible_pool_mitm_round1.json`
- `outputs/candidates/near_hits/near_hit_v167_score2524_moment_compatible_pool_mitm_round2.json`
- `outputs/candidates/near_hits/near_hit_v167_score2592_moment_compatible_pool_mitm_round3.json`
- `outputs/candidates/near_hits/near_hit_v167_score4664_moment_compatible_pool_mitm_round1.json`
- `outputs/candidates/near_hits/near_hit_v167_score5488_moment_compatible_pool_mitm_round2.json`
- `outputs/candidates/near_hits/near_hit_v167_score5280_moment_compatible_pool_mitm_round3.json`

## Verdict

Negative for generative use in this run: best score stayed above 424.

No Hadamard 668 construction is claimed unless score 0 plus SDS and GS exact verification pass.
