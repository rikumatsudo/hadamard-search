# Refined Next Candidates

[
  {
    "candidate_name": "Run partial membership LNS on score176 and low-nonzero branches",
    "classification": "heuristic repair",
    "success_condition": "exact score improvement or score=0 with full verification",
    "failure_condition": "selected=0, timeout, or exact post-validation rejects outputs"
  },
  {
    "candidate_name": "Cluster-specific LNS objective tuning",
    "classification": "diagnostic/heuristic",
    "success_condition": "cluster medoid improves without returning to old basin",
    "failure_condition": "same cluster and dominated output"
  }
]
