# Partial Membership LNS Results

- success_candidate_generated: `False`
- score_zero_reached: `False`

|input|before|after|solver|selected|accepted|reason|
|---|---|---|---|---|---|---|
|outputs/candidates/near_hits/near_hit_v167_score176_seed101_step8576.json|[176, 112, 3, 86]|[236, 144, 3, 104]|solved|2|False|score 236 exceeds before+slack 216|
|outputs/candidates/near_hits/near_hit_v167_score184_ilp_repair_from_near_hit_round1_4.json|[184, 112, 3, 80]|None|solver_error:CBC : The problem or its dual has been proven infeasible!|0|False|selected_count=0 or solver did not return a candidate|
|outputs/candidates/near_hits/near_hit_v167_score164_steepest_swap_descent_round1.json|[164, 116, 3, 96]|[240, 128, 4, 90]|solved|4|False|score 240 exceeds before+slack 204|

These are LNS diagnostics only. They are not SDS solutions and were not sent to Goethals-Seidel verification because score 0 was not reached.
