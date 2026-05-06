# 428 Positive-control Perturbation Summary

This is a calibration experiment using the known order-428 construction. It does not claim anything about order 668 directly.

## Exact 428 Baseline

- source: `outputs/explorations/20260506_0300_hadamard428_positive_control_perturbation_smoke2/exact_428_sds_candidate.json`
- score: `0`
- l1_error: `0`
- max_abs_error: `0`
- nonzero_defect_count: `0`
- SDS OK: `True`
- moments: `{'T2': 0, 'T4': 0, 'T6': 0, 'T8': 0, 'T10': 0, 'T12': 0}`

## Perturbation Distribution

### distance 1

```json
{
  "count": 50,
  "l1_min": 52,
  "moment_zero_count_3_hist": {
    "0": 50
  },
  "score_median": 96,
  "score_min": 60,
  "score_p1": 60,
  "score_p10": 72,
  "score_p5": 68
}
```

### distance 2

```json
{
  "count": 50,
  "l1_min": 80,
  "moment_zero_count_3_hist": {
    "0": 50
  },
  "score_median": 200,
  "score_min": 108,
  "score_p1": 108,
  "score_p10": 156,
  "score_p5": 156
}
```

## Best Records

```json
{
  "1": [
    {
      "l1_error": 52,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 48,
      "padic_moments": {
        "T10": 24,
        "T12": 34,
        "T2": 25,
        "T4": 86,
        "T6": 15,
        "T8": 4
      },
      "path": "outputs/explorations/20260506_0300_hadamard428_positive_control_perturbation_smoke2/candidates/distance1_rank1_score60.json",
      "score": 60
    },
    {
      "l1_error": 64,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 62,
      "padic_moments": {
        "T10": 25,
        "T12": 85,
        "T2": 24,
        "T4": 71,
        "T6": 79,
        "T8": 65
      },
      "path": "outputs/explorations/20260506_0300_hadamard428_positive_control_perturbation_smoke2/candidates/distance1_rank2_score68.json",
      "score": 68
    },
    {
      "l1_error": 64,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 62,
      "padic_moments": {
        "T10": 64,
        "T12": 32,
        "T2": 83,
        "T4": 69,
        "T6": 100,
        "T8": 55
      },
      "path": "outputs/explorations/20260506_0300_hadamard428_positive_control_perturbation_smoke2/candidates/distance1_rank3_score68.json",
      "score": 68
    },
    {
      "l1_error": 60,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 54,
      "padic_moments": {
        "T10": 4,
        "T12": 75,
        "T2": 75,
        "T4": 11,
        "T6": 33,
        "T8": 20
      },
      "path": "outputs/explorations/20260506_0300_hadamard428_positive_control_perturbation_smoke2/candidates/distance1_rank4_score72.json",
      "score": 72
    },
    {
      "l1_error": 60,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 54,
      "padic_moments": {
        "T10": 16,
        "T12": 52,
        "T2": 3,
        "T4": 100,
        "T6": 1,
        "T8": 21
      },
      "path": "outputs/explorations/20260506_0300_hadamard428_positive_control_perturbation_smoke2/candidates/distance1_rank5_score72.json",
      "score": 72
    }
  ],
  "2": [
    {
      "l1_error": 80,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 66,
      "padic_moments": {
        "T10": 99,
        "T12": 5,
        "T2": 84,
        "T4": 98,
        "T6": 5,
        "T8": 8
      },
      "path": "outputs/explorations/20260506_0300_hadamard428_positive_control_perturbation_smoke2/candidates/distance2_rank1_score108.json",
      "score": 108
    },
    {
      "l1_error": 88,
      "max_abs_error": 3,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 68,
      "padic_moments": {
        "T10": 17,
        "T12": 71,
        "T2": 57,
        "T4": 43,
        "T6": 76,
        "T8": 66
      },
      "path": "outputs/explorations/20260506_0300_hadamard428_positive_control_perturbation_smoke2/candidates/distance2_rank2_score132.json",
      "score": 132
    },
    {
      "l1_error": 92,
      "max_abs_error": 3,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 66,
      "padic_moments": {
        "T10": 86,
        "T12": 88,
        "T2": 53,
        "T4": 104,
        "T6": 97,
        "T8": 24
      },
      "path": "outputs/explorations/20260506_0300_hadamard428_positive_control_perturbation_smoke2/candidates/distance2_rank3_score156.json",
      "score": 156
    },
    {
      "l1_error": 92,
      "max_abs_error": 4,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 68,
      "padic_moments": {
        "T10": 2,
        "T12": 50,
        "T2": 5,
        "T4": 13,
        "T6": 12,
        "T8": 70
      },
      "path": "outputs/explorations/20260506_0300_hadamard428_positive_control_perturbation_smoke2/candidates/distance2_rank4_score156.json",
      "score": 156
    },
    {
      "l1_error": 96,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 66,
      "padic_moments": {
        "T10": 96,
        "T12": 17,
        "T2": 65,
        "T4": 76,
        "T6": 72,
        "T8": 93
      },
      "path": "outputs/explorations/20260506_0300_hadamard428_positive_control_perturbation_smoke2/candidates/distance2_rank5_score156.json",
      "score": 156
    }
  ]
}
```

## Interpretation

- Exact 428 has score 0 and all tested p-adic moments zero, as expected.
- The useful calibration question is whether small swap distance preserves moment compatibility together with low score, or whether moments randomize faster than score.
- Perturbed rows are diagnostics only; only the exact baseline is a verified construction.
