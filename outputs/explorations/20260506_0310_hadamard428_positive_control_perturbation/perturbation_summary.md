# 428 Positive-control Perturbation Summary

This is a calibration experiment using the known order-428 construction. It does not claim anything about order 668 directly.

## Exact 428 Baseline

- source: `outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/exact_428_sds_candidate.json`
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
  "count": 13342,
  "l1_min": 44,
  "moment_zero_count_3_hist": {
    "0": 12953,
    "1": 386,
    "2": 3
  },
  "score_median": 104,
  "score_min": 48,
  "score_p1": 64,
  "score_p10": 80,
  "score_p5": 76
}
```

### distance 2

```json
{
  "count": 2000,
  "l1_min": 0,
  "moment_zero_count_3_hist": {
    "0": 1938,
    "1": 60,
    "2": 1,
    "3": 1
  },
  "score_median": 200,
  "score_min": 0,
  "score_p1": 112,
  "score_p10": 156,
  "score_p5": 140
}
```

### distance 3

```json
{
  "count": 2000,
  "l1_min": 84,
  "moment_zero_count_3_hist": {
    "0": 1939,
    "1": 61
  },
  "score_median": 300,
  "score_min": 120,
  "score_p1": 168,
  "score_p10": 228,
  "score_p5": 208
}
```

### distance 4

```json
{
  "count": 2000,
  "l1_min": 100,
  "moment_zero_count_3_hist": {
    "0": 1959,
    "1": 41
  },
  "score_median": 392,
  "score_min": 168,
  "score_p1": 228,
  "score_p10": 300,
  "score_p5": 276
}
```

## Best Records

```json
{
  "1": [
    {
      "l1_error": 44,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 42,
      "padic_moments": {
        "T10": 9,
        "T12": 88,
        "T2": 46,
        "T4": 106,
        "T6": 68,
        "T8": 15
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance1_rank1_score48.json",
      "score": 48
    },
    {
      "l1_error": 44,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 42,
      "padic_moments": {
        "T10": 25,
        "T12": 30,
        "T2": 54,
        "T4": 84,
        "T6": 20,
        "T8": 4
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance1_rank2_score48.json",
      "score": 48
    },
    {
      "l1_error": 48,
      "max_abs_error": 1,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 48,
      "padic_moments": {
        "T10": 48,
        "T12": 63,
        "T2": 21,
        "T4": 85,
        "T6": 84,
        "T8": 19
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance1_rank3_score48.json",
      "score": 48
    },
    {
      "l1_error": 44,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 40,
      "padic_moments": {
        "T10": 8,
        "T12": 4,
        "T2": 6,
        "T4": 86,
        "T6": 11,
        "T8": 77
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance1_rank4_score52.json",
      "score": 52
    },
    {
      "l1_error": 48,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 46,
      "padic_moments": {
        "T10": 16,
        "T12": 20,
        "T2": 92,
        "T4": 36,
        "T6": 61,
        "T8": 99
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance1_rank5_score52.json",
      "score": 52
    },
    {
      "l1_error": 48,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 46,
      "padic_moments": {
        "T10": 44,
        "T12": 101,
        "T2": 25,
        "T4": 75,
        "T6": 102,
        "T8": 40
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance1_rank6_score52.json",
      "score": 52
    },
    {
      "l1_error": 48,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 46,
      "padic_moments": {
        "T10": 78,
        "T12": 45,
        "T2": 78,
        "T4": 20,
        "T6": 19,
        "T8": 99
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance1_rank7_score52.json",
      "score": 52
    },
    {
      "l1_error": 48,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 46,
      "padic_moments": {
        "T10": 55,
        "T12": 52,
        "T2": 25,
        "T4": 93,
        "T6": 9,
        "T8": 57
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance1_rank8_score52.json",
      "score": 52
    }
  ],
  "2": [
    {
      "l1_error": 0,
      "max_abs_error": 0,
      "moment_zero_count_3": 3,
      "moment_zero_count_6": 6,
      "nonzero_defect_count": 0,
      "padic_moments": {
        "T10": 0,
        "T12": 0,
        "T2": 0,
        "T4": 0,
        "T6": 0,
        "T8": 0
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance2_rank1_score0.json",
      "score": 0
    },
    {
      "l1_error": 60,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 50,
      "padic_moments": {
        "T10": 54,
        "T12": 15,
        "T2": 8,
        "T4": 7,
        "T6": 37,
        "T8": 59
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance2_rank2_score80.json",
      "score": 80
    },
    {
      "l1_error": 64,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 54,
      "padic_moments": {
        "T10": 66,
        "T12": 82,
        "T2": 55,
        "T4": 64,
        "T6": 2,
        "T8": 52
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance2_rank3_score84.json",
      "score": 84
    },
    {
      "l1_error": 72,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 66,
      "padic_moments": {
        "T10": 36,
        "T12": 71,
        "T2": 15,
        "T4": 27,
        "T6": 82,
        "T8": 72
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance2_rank4_score84.json",
      "score": 84
    },
    {
      "l1_error": 68,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 58,
      "padic_moments": {
        "T10": 54,
        "T12": 55,
        "T2": 67,
        "T4": 85,
        "T6": 19,
        "T8": 68
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance2_rank5_score88.json",
      "score": 88
    },
    {
      "l1_error": 72,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 64,
      "padic_moments": {
        "T10": 104,
        "T12": 61,
        "T2": 91,
        "T4": 96,
        "T6": 2,
        "T8": 66
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance2_rank6_score88.json",
      "score": 88
    },
    {
      "l1_error": 76,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 68,
      "padic_moments": {
        "T10": 72,
        "T12": 89,
        "T2": 94,
        "T4": 72,
        "T6": 42,
        "T8": 59
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance2_rank7_score92.json",
      "score": 92
    },
    {
      "l1_error": 72,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 60,
      "padic_moments": {
        "T10": 94,
        "T12": 7,
        "T2": 9,
        "T4": 30,
        "T6": 33,
        "T8": 93
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance2_rank8_score96.json",
      "score": 96
    }
  ],
  "3": [
    {
      "l1_error": 88,
      "max_abs_error": 3,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 74,
      "padic_moments": {
        "T10": 12,
        "T12": 39,
        "T2": 88,
        "T4": 87,
        "T6": 105,
        "T8": 104
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance3_rank1_score120.json",
      "score": 120
    },
    {
      "l1_error": 92,
      "max_abs_error": 2,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 76,
      "padic_moments": {
        "T10": 44,
        "T12": 58,
        "T2": 55,
        "T4": 8,
        "T6": 3,
        "T8": 53
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance3_rank2_score124.json",
      "score": 124
    },
    {
      "l1_error": 84,
      "max_abs_error": 3,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 64,
      "padic_moments": {
        "T10": 23,
        "T12": 13,
        "T2": 8,
        "T4": 69,
        "T6": 62,
        "T8": 78
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance3_rank3_score128.json",
      "score": 128
    },
    {
      "l1_error": 96,
      "max_abs_error": 3,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 74,
      "padic_moments": {
        "T10": 3,
        "T12": 53,
        "T2": 23,
        "T4": 67,
        "T6": 101,
        "T8": 26
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance3_rank4_score144.json",
      "score": 144
    },
    {
      "l1_error": 96,
      "max_abs_error": 3,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 70,
      "padic_moments": {
        "T10": 94,
        "T12": 34,
        "T2": 89,
        "T4": 14,
        "T6": 50,
        "T8": 68
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance3_rank5_score152.json",
      "score": 152
    },
    {
      "l1_error": 88,
      "max_abs_error": 3,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 58,
      "padic_moments": {
        "T10": 28,
        "T12": 59,
        "T2": 63,
        "T4": 71,
        "T6": 82,
        "T8": 12
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance3_rank6_score160.json",
      "score": 160
    },
    {
      "l1_error": 96,
      "max_abs_error": 3,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 70,
      "padic_moments": {
        "T10": 4,
        "T12": 65,
        "T2": 96,
        "T4": 7,
        "T6": 94,
        "T8": 15
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance3_rank7_score160.json",
      "score": 160
    },
    {
      "l1_error": 104,
      "max_abs_error": 3,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 80,
      "padic_moments": {
        "T10": 95,
        "T12": 15,
        "T2": 34,
        "T4": 59,
        "T6": 67,
        "T8": 45
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance3_rank8_score160.json",
      "score": 160
    }
  ],
  "4": [
    {
      "l1_error": 108,
      "max_abs_error": 3,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 80,
      "padic_moments": {
        "T10": 88,
        "T12": 63,
        "T2": 70,
        "T4": 18,
        "T6": 58,
        "T8": 26
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance4_rank1_score168.json",
      "score": 168
    },
    {
      "l1_error": 112,
      "max_abs_error": 3,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 82,
      "padic_moments": {
        "T10": 15,
        "T12": 4,
        "T2": 53,
        "T4": 96,
        "T6": 24,
        "T8": 24
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance4_rank2_score184.json",
      "score": 184
    },
    {
      "l1_error": 100,
      "max_abs_error": 3,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 60,
      "padic_moments": {
        "T10": 73,
        "T12": 89,
        "T2": 64,
        "T4": 90,
        "T6": 78,
        "T8": 96
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance4_rank3_score200.json",
      "score": 200
    },
    {
      "l1_error": 104,
      "max_abs_error": 3,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 66,
      "padic_moments": {
        "T10": 85,
        "T12": 43,
        "T2": 85,
        "T4": 1,
        "T6": 17,
        "T8": 89
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance4_rank4_score200.json",
      "score": 200
    },
    {
      "l1_error": 120,
      "max_abs_error": 3,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 82,
      "padic_moments": {
        "T10": 68,
        "T12": 68,
        "T2": 56,
        "T4": 51,
        "T6": 47,
        "T8": 47
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance4_rank5_score208.json",
      "score": 208
    },
    {
      "l1_error": 120,
      "max_abs_error": 4,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 84,
      "padic_moments": {
        "T10": 11,
        "T12": 42,
        "T2": 104,
        "T4": 84,
        "T6": 49,
        "T8": 106
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance4_rank6_score208.json",
      "score": 208
    },
    {
      "l1_error": 104,
      "max_abs_error": 3,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 62,
      "padic_moments": {
        "T10": 68,
        "T12": 8,
        "T2": 64,
        "T4": 33,
        "T6": 41,
        "T8": 14
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance4_rank7_score212.json",
      "score": 212
    },
    {
      "l1_error": 104,
      "max_abs_error": 4,
      "moment_zero_count_3": 0,
      "moment_zero_count_6": 0,
      "nonzero_defect_count": 70,
      "padic_moments": {
        "T10": 15,
        "T12": 4,
        "T2": 100,
        "T4": 53,
        "T6": 81,
        "T8": 93
      },
      "path": "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance4_rank8_score212.json",
      "score": 212
    }
  ]
}
```

## Interpretation

- Exact 428 has score 0 and all tested p-adic moments zero, as expected.
- The useful calibration question is whether small swap distance preserves moment compatibility together with low score, or whether moments randomize faster than score.
- Perturbed rows are diagnostics only; only the exact baseline is a verified construction.

## Filtered Reading

The distance-2 sample contains one degenerate score-0 row where two random swaps returned to the exact solution. Ignoring score-0 perturbed rows:

| distance | rows | score min | score median | low moment zero-count distribution |
| --- | ---: | ---: | ---: | --- |
| 1 | 13,342 | 48 | 104 | `{0: 12953, 1: 386, 2: 3}` |
| 2 | 1,999 | 80 | 200 | `{0: 1938, 1: 60, 2: 1}` |
| 3 | 2,000 | 120 | 300 | `{0: 1939, 1: 61}` |
| 4 | 2,000 | 168 | 392 | `{0: 1959, 1: 41}` |

The strongest calibration signal is that true solution neighborhoods can have very low score while `T2,T4,T6` are usually nonzero. One swap from a true solution already makes low-degree p-adic moments look almost random, even though the SDS score remains tiny by 668 standards. Thus moment-zero is a strict necessary condition at the exact point, but it is not a smooth proximity indicator under ordinary swap distance.
