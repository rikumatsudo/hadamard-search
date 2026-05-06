# Refined Next Candidates

1. Score-capped novelty objective: reward distance only when score is below a cap, e.g. 260, or within slack of current best.
2. Bounded novelty tie-breaker: use score/l1/max_abs as primary constraints, then prefer cluster distance.
3. Constantine one-block completion or block-pair autocorrelation route if bounded novelty does not improve.
