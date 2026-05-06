# Cluster Distance Analysis

Useful candidates remain close to existing cluster structure. `[73,78,79,81]` produced a best candidate whose nearest medoid is cluster 4, but its metrics are weak compared with the existing frontier. `[73,76,83,83]` remained nearest to cluster 0 for its useful candidates.

The novelty and cluster_distance buckets are currently dominated by high-score early states. Distance is therefore informative but must be bounded by score/l1 to be useful.
