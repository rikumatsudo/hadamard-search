# Refined Next Candidates

```json
{
  "candidates": [
    {
      "candidate_name": "Active-defect ILP repair on new low-nonzero basin",
      "classification": "heuristic repair",
      "why_now": "shallow repair saturated; new canonical basins need targeted repair",
      "success_condition": "frontier metric improvement, then exact SDS/GS verification if score=0",
      "failure_condition": "selected=0 or dominated outputs",
      "required_compute": "medium",
      "risk": "ILP pool may be too small or too large",
      "rank_reason": "most direct follow-up after canonical new basin generation"
    },
    {
      "candidate_name": "Continue guided new-basin generation",
      "classification": "heuristic search",
      "why_now": "current repair frontier is saturated",
      "success_condition": "new canonical_hash with score/l1/nonzero improvement",
      "failure_condition": "returns to existing canonical classes",
      "required_compute": "high",
      "risk": "long runtime",
      "rank_reason": "best way to escape existing basins"
    },
    {
      "candidate_name": "Constantine [76,76,77,80] one-block completion",
      "classification": "side route",
      "why_now": "if guided search also saturates",
      "success_condition": "new verified SDS route candidate",
      "failure_condition": "no compatible completion",
      "required_compute": "medium-high",
      "risk": "may miss unconstrained solutions",
      "rank_reason": "changes search geometry"
    }
  ]
}
```
