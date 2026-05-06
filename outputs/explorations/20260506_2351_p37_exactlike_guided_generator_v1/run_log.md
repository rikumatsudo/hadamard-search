# Run Log

- script: `62_exactlike_guided_generator_validation`
- config: `configs/experiments/p37_exactlike_generator.yaml`
- score=0 only is success
- initial candidates: `40`
- trajectory runs: `20`
- diagnostic candidates: `108`
- frontier candidates: `55`
- archived false-like candidates: `16`
- repair routed candidates: `2`
- repair attempts: `8`
- score0 candidate files: `4`
- `sage/06_known_sds_regression.sage`: passed
- p37 exact external validation: `08_analyze_sds_candidate`, `05_validate_candidate_json`, and `04_build_gs_from_sds` passed
- generated score=0 external validation: `08_analyze_sds_candidate`, `05_validate_candidate_json`, and `04_build_gs_from_sds` passed for all four saved score0 files
