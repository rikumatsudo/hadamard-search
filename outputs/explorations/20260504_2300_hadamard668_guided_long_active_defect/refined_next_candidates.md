# Refined Next Candidates

```json
[
  {
    "candidate_name": "Comparator long run on [73,78,79,81]",
    "classification": "heuristic new-basin generation",
    "why_now": "The primary [73,76,83,83] slice stayed weak; comparator branch still owns best score=164.",
    "input": "ks=[73,78,79,81], lambda=144",
    "expected_output": "bucketed canonical frontier",
    "success_condition": "new non-dominated canonical basin or score<164",
    "failure_condition": "all bucket winners dominated by current frontier",
    "required_compute": "long-running guided search",
    "risk": "same canonical basin saturation",
    "rank_reason": "highest immediate comparator value"
  },
  {
    "candidate_name": "Primary long run continuation with altered schedule",
    "classification": "heuristic new-basin generation",
    "why_now": "Primary branch still has low-nonzero frontier, but this slice was weak.",
    "input": "ks=[73,76,83,83], lambda=148 with nonzero/l1 objective schedule",
    "expected_output": "new bucket winners with nonzero<=90",
    "success_condition": "nonzero<80 or l1<112",
    "failure_condition": "best remains around score>220",
    "required_compute": "long-running guided search",
    "risk": "slow progress",
    "rank_reason": "keeps primary route alive but needs schedule change"
  },
  {
    "candidate_name": "Active-defect repair on existing low-nonzero branch",
    "classification": "heuristic repair",
    "why_now": "No new guided target qualified; existing low-nonzero branch remains the best nonzero object.",
    "input": "near_hit_v167_score184_ilp_repair_from_near_hit_round1_4.json",
    "expected_output": "repair attempt with active_defect_lns",
    "success_condition": "l1<112 or nonzero<80",
    "failure_condition": "selected=0 or dominated output",
    "required_compute": "medium ILP",
    "risk": "repair framework saturation",
    "rank_reason": "uses best available low-nonzero state"
  }
]
```
