# Novelty Design

Implemented cluster-aware scoring using defect vector distances to medoids. The first pass uses L1 distance to cluster 0 and support symmetric difference diagnostics. Novelty is diagnostic only and is not a success criterion.

Current issue: pure novelty rank selects high-distance high-score initial states, so the next iteration should score-cap novelty or use it only as a tie-breaker under score/l1 bounds.
