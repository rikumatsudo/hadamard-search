# New Basin Generation Plan

Primary branch: `[73,76,83,83]`, `lambda=148`.

Comparator branch: `[73,78,79,81]`, `lambda=144`.

Plan:

1. Run guided search with `--canonical-dedup` and bucketed frontier output.
2. Keep top candidates per canonical bucket rather than only global score-best candidates.
3. Prefer candidates with new `canonical_hash`, low `nonzero_defect_count`, low `l1_error`, and `max_abs_error <= 2`.
4. Apply active-defect LNS/ILP repair only to bucket winners that are not already dominated by the existing frontier.
5. Treat all outputs as near-hit unless SDS verification and Goethals-Seidel `HH^T=668I` both pass over integer matrices.

Current status: primary smoke completed; full primary/comparator runs remain open.
