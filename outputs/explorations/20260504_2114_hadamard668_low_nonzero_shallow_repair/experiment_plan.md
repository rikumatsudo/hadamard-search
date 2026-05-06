# Experiment Plan

This exploration performs a shallow-wide repair screen around the current n=668 SDS near-hit frontier.

The previous strong zero-protect run used weight 100000 and repeatedly selected no moves on the low-nonzero branch. This suggests the objective over-protected zero-defect shifts and created fixed points. The current plan lowers the zero-protect weight and compares low_nonzero, mixed, and diverse move pools.

Adoption criteria:

- frontier expands in an isolated run
- score < 164
- l1_error < 112
- nonzero_defect_count < 80
- max_abs_error = 2 with better l1
- selected_moves_count > 0 and the post-ILP repair does not immediately undo the branch change

Failure criteria:

- selected_moves_count = 0 dominates
- no isolated frontier growth
- ILP changes are dominated after beam/steepest
- zero-shift damage increases nonzero without improving l1 or score
- pool modes are indistinguishable

Success safety:

score=0 is not enough. A success candidate must pass exact SDS verification and exact Goethals-Seidel HH^T = 668I over ZZ.
