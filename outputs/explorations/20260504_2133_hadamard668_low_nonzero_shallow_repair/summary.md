# Final Summary

1. This run performed Hadamard 668 SDS low-nonzero shallow-wide repair exploration.
2. It inherited the current near-hit frontier and tested weak zero-protect / pool-mode variants.
3. The run output is diagnostic. It is not a proof or construction certificate.
4. Success requires SDS verification plus Goethals-Seidel HH^T = 668I over ZZ.

## Aggregate Results

- run_count: `11`
- row_count: `44`
- success_rows: `0`
- selected_zero_rate: `0.5`
- best_score: `{'score': 164, 'l1_error': 116, 'max_abs_error': 3, 'nonzero_defect_count': 96, 'final_path': 'outputs/candidates/near_hits/near_hit_v167_score164_steepest_swap_descent_round1.json', 'candidate': 'outputs/candidates/near_hits/near_hit_v167_score164_steepest_swap_descent_round1.json', 'objective': 'l1', 'acceptance': 'l1_then_score'}`
- best_l1: `{'score': 184, 'l1_error': 112, 'max_abs_error': 3, 'nonzero_defect_count': 80, 'final_path': 'outputs/candidates/near_hits/near_hit_v167_score184_ilp_repair_from_near_hit_round1_4.json', 'candidate': 'outputs/candidates/near_hits/near_hit_v167_score184_ilp_repair_from_near_hit_round1_4.json', 'objective': 'score_zero_protect', 'acceptance': 'lex'}`
- best_nonzero: `{'score': 184, 'l1_error': 112, 'max_abs_error': 3, 'nonzero_defect_count': 80, 'final_path': 'outputs/candidates/near_hits/near_hit_v167_score184_ilp_repair_from_near_hit_round1_4.json', 'candidate': 'outputs/candidates/near_hits/near_hit_v167_score184_ilp_repair_from_near_hit_round1_4.json', 'objective': 'score_zero_protect', 'acceptance': 'lex'}`
- best_max_abs: `{'score': 172, 'l1_error': 128, 'max_abs_error': 2, 'nonzero_defect_count': 106, 'final_path': 'outputs/candidates/near_hits/near_hit_v167_score172_steepest_swap_descent_round1_7.json', 'candidate': 'outputs/candidates/near_hits/near_hit_v167_score172_beam_two_swap_repair_round2.json', 'objective': 'l1', 'acceptance': 'l1_then_score'}`
- route_verdict: `repair_framework_still_saturated`

The near-hit frontier remains research log material unless exact SDS and HH^T verification pass.
