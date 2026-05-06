# p-adic Moment Basin Diagnostics

Diagnostic only. These moment conditions are necessary conditions for SDS, not success certificates.

## Dataset

- valid near-hits: 31538
- unique canonical hashes: 8178
- metrics mismatch count: 0
- moment powers: [2, 4, 6]
- extended moment powers: [2, 4, 6, 8, 10, 12]
- moment zero-count histogram: {0: 30925, 1: 602, 2: 4, 3: 7}
- extended moment zero-count histogram: {0: 30354, 1: 1158, 2: 18, 3: 8}
- all three moments zero: 7
- all six moments zero: 0

## Best Records

Best by score:
```json
{
  "canonical_hash": "",
  "ks": [
    73,
    78,
    79,
    81
  ],
  "l1_error": 116,
  "lambda": 144,
  "max_abs_error": 3,
  "moment_abs_sum": 181,
  "moment_all_zero": false,
  "moment_signature": "117,85,49",
  "moment_zero_count": 0,
  "nonzero_defect_count": 96,
  "objective_schedule": "score_then_l1",
  "p_adic_moments": {
    "modulus": 167,
    "moment_abs_sum": 181,
    "moment_all_zero": false,
    "moment_signature": "117,85,49",
    "moment_zero_count": 0,
    "moments": [
      {
        "balanced_abs": 50,
        "power": 2,
        "residue": 117,
        "zero": false
      },
      {
        "balanced_abs": 82,
        "power": 4,
        "residue": 85,
        "zero": false
      },
      {
        "balanced_abs": 49,
        "power": 6,
        "residue": 49,
        "zero": false
      }
    ],
    "powers": [
      2,
      4,
      6
    ]
  },
  "path": "outputs/candidates/near_hits/frontier/near_hit_v167_score164_ilp_repair_from_near_hit_round1.json",
  "score": 164,
  "seed": null,
  "source_type": "ilp",
  "step": 1
}
```

Best by moment then score:
```json
{
  "canonical_hash": "f1805085267cb9b619a6af40060b14433130aea22a1674b2cfd0aede3f814435",
  "ks": [
    73,
    78,
    79,
    81
  ],
  "l1_error": 208,
  "lambda": 144,
  "max_abs_error": 4,
  "moment_abs_sum": 0,
  "moment_all_zero": true,
  "moment_signature": "0,0,0",
  "moment_zero_count": 3,
  "nonzero_defect_count": 128,
  "objective_schedule": "",
  "p_adic_moments": {
    "modulus": 167,
    "moment_abs_sum": 0,
    "moment_all_zero": true,
    "moment_signature": "0,0,0",
    "moment_zero_count": 3,
    "moments": [
      {
        "balanced_abs": 0,
        "power": 2,
        "residue": 0,
        "zero": true
      },
      {
        "balanced_abs": 0,
        "power": 4,
        "residue": 0,
        "zero": true
      },
      {
        "balanced_abs": 0,
        "power": 6,
        "residue": 0,
        "zero": true
      }
    ],
    "powers": [
      2,
      4,
      6
    ]
  },
  "path": "outputs/candidates/near_hits/near_hit_v167_score424_moment_preserving_score_repair_round1.json",
  "score": 424,
  "seed": null,
  "source_type": "unknown",
  "step": 3
}
```

Best all-moment-zero by score:
```json
{
  "canonical_hash": "f1805085267cb9b619a6af40060b14433130aea22a1674b2cfd0aede3f814435",
  "ks": [
    73,
    78,
    79,
    81
  ],
  "l1_error": 208,
  "lambda": 144,
  "max_abs_error": 4,
  "moment_abs_sum": 0,
  "moment_all_zero": true,
  "moment_signature": "0,0,0",
  "moment_zero_count": 3,
  "nonzero_defect_count": 128,
  "objective_schedule": "",
  "p_adic_moments": {
    "modulus": 167,
    "moment_abs_sum": 0,
    "moment_all_zero": true,
    "moment_signature": "0,0,0",
    "moment_zero_count": 3,
    "moments": [
      {
        "balanced_abs": 0,
        "power": 2,
        "residue": 0,
        "zero": true
      },
      {
        "balanced_abs": 0,
        "power": 4,
        "residue": 0,
        "zero": true
      },
      {
        "balanced_abs": 0,
        "power": 6,
        "residue": 0,
        "zero": true
      }
    ],
    "powers": [
      2,
      4,
      6
    ]
  },
  "path": "outputs/candidates/near_hits/near_hit_v167_score424_moment_preserving_score_repair_round1.json",
  "score": 424,
  "seed": null,
  "source_type": "unknown",
  "step": 3
}
```

Best six-moment-zero by score:
```json
null
```

## Known Branch Moment Signatures

- score164: metrics=(164, 116, 3, 96), signature=117,85,49, zero_count=0, abs_sum=181, path=outputs/candidates/near_hits/frontier/near_hit_v167_score164_ilp_repair_from_near_hit_round1.json
- score176: metrics=(176, 112, 3, 86), signature=31,138,20, zero_count=0, abs_sum=80, path=outputs/candidates/near_hits/fourier_capped_smoke_tiny_step0_score176.json
- low_nonzero184: metrics=(184, 112, 3, 80), signature=26,146,51, zero_count=0, abs_sum=98, path=outputs/candidates/near_hits/frontier/near_hit_v167_score184_ilp_repair_from_near_hit_round1_4.json
- maxabs2_172: metrics=(172, 128, 2, 106), signature=101,73,163, zero_count=0, abs_sum=143, path=outputs/candidates/near_hits/frontier/near_hit_v167_score172_ilp_repair_from_near_hit_round1.json
- maxabs2_184: metrics=(184, 124, 2, 94), signature=44,40,142, zero_count=0, abs_sum=109, path=outputs/candidates/near_hits/frontier/near_hit_v167_score184_ilp_repair_from_near_hit_round1.json
- maxabs2_nonzero86: metrics=(200, 124, 2, 86), signature=41,119,119, zero_count=0, abs_sum=137, path=outputs/candidates/near_hits/frontier/near_hit_v167_score200_ilp_repair_from_near_hit_round1_1.json

## Interpretation

Use `moment_zero_count` as a basin classification filter. A near-hit with low score but nonzero low-degree p-adic moments is still outside the exact SDS p-adic shadow.
If all known frontier branches fail `T2=T4=T6=0`, the current frontier should not be treated as privileged solely because of score.
