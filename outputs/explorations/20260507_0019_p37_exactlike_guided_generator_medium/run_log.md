# Run Log

- script: `62_exactlike_guided_generator_validation`
- config: `configs/experiments/p37_exactlike_generator_medium.yaml`
- score=0 only is success
- initial candidates: `60`
- trajectory runs: `200`
- diagnostic candidates: `720`
- frontier candidates: `93`
- archived false-like candidates: `192`
- repair routed candidates: `5`
- repair attempts: `20`
- score0 candidate files: `4`

## External validation

- `sage sage/06_known_sds_regression.sage`: OK, all known SDS regressions passed.
- `sage sage/08_analyze_sds_candidate.sage outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json`: OK, computed score=0 and SDS metrics matched.
- `sage sage/05_validate_candidate_json.sage outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json`: OK, candidate JSON validates as SDS.
- `sage sage/04_build_gs_from_sds.sage outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json`: OK, HH^T = 148I.
- `score0_candidate_score_only_5f50c5e7835e.json`: 08/05/04 OK, SDS OK, HH^T = 148I.
- `score0_candidate_sparse_vector_cancellation_beam_5f50c5e7835e.json`: 08/05/04 OK, SDS OK, HH^T = 148I.
- `score0_candidate_pair_level_partial_defect_repair_5f50c5e7835e.json`: 08/05/04 OK, SDS OK, HH^T = 148I.
- `score0_candidate_moment_late_repair_5f50c5e7835e.json`: 08/05/04 OK, SDS OK, HH^T = 148I.
