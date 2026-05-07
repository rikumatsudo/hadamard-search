# p167 Near-Hit Trap Catalog Validation

This is a catalog / analysis run, not a Hadamard 668 construction run.

## Counts

- p167 near-hit candidates analyzed: `113`
- score164 analyzed: `3`
- score176 analyzed: `4`
- tuple [73,78,79,81], lambda=144 candidates: `102`

## Hypotheses

```json
{
  "H_P167_1": "supported",
  "H_P167_2": "supported",
  "H_P167_3": "supported",
  "H_P167_4": "supported",
  "H_P167_5": "supported",
  "method_summary_groups": 6,
  "p167_candidate_count": 113,
  "score164_176_closer_to": "p37_false_like",
  "score164_176_exact_like_rate": 0.2857142857142857,
  "score164_176_false_like_rate": 0.7142857142857143,
  "score164_count": 3,
  "score176_count": 4,
  "tuple_A_73_78_79_81_lambda144_count": 102
}
```

## Required Answers

1. p167 near-hit は何件収集できたか: `113` unique candidates.
2. score164 / score176 は何件分析できたか: score164 `3`, score176 `4`.
3. tuple [73,78,79,81], lambda=144 の候補は何件か: `102`.
4. p167 score164/176 は p37 false-basin trap に近いか、exact-derived 側に近いか: `p37_false_like`.
5. score164 と score176 は同じ trap family に見えるか: `supported`.
6. p167 near-hit は D_min/S, P_tau, kappa 的に false-like か exact-like か: false-like rate `0.7142857142857143`, exact-like rate `0.2857142857142857` for score164/176.
7. steepest / beam / ILP / seed など source method ごとに signature 差はあるか: `supported`.
8. p37 trap catalog は p167 near-hit 解釈に使えそうか: `supported`.
9. 668 探索で score164/176 を archive / repair target / deep search target のどれにすべきか: use as repair/deep-search targets only when exact-like route indicators improve; archive repeated false-like signatures early.
10. 次に見るべき operator / generator は何か: route score164/176 through exactlike-guided repair and compare against fresh exactlike-guided generator frontier, using p167 rank-normalized P_tau/kappa.

## Validation

- `sage sage/06_known_sds_regression.sage`: OK
