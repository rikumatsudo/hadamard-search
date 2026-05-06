# Moment-compatible Pool MITM Overall Summary

This is a diagnostic exploration only. `T2=T4=T6=0` is a low-degree p-adic necessary condition, not an SDS certificate and not a Hadamard 668 construction.

## Implementation

- Added `sage/46_moment_compatible_pool_mitm.sage`.
- It builds centered block pools by size, computes block features `(g2,g4,g6)`, and uses a sampled meet-in-the-middle join to generate candidates satisfying `T2=T4=T6=0`.
- Each matched 4-block candidate is re-evaluated by true difference counts before saving score, l1, max_abs, nonzero, and moments `T2,T4,T6,T8,T10,T12`.
- It also samples an unconstrained random baseline from the same block pools.

## Runs

| run | tuple | evaluated moment candidates | best score | best l1 | best max_abs | best nonzero | baseline best | threshold <=424 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| A small | `[73,78,79,81]`, lambda 144 | 50,000 | 2304 | 500 | 9 | 148 | 2744 | 0 |
| A medium | `[73,78,79,81]`, lambda 144 | 200,000 | 2256 | 460 | 12 | 134 | 2760 | 0 |
| B small | `[73,76,83,83]`, lambda 148 | 50,000 | 1556 | 400 | 7 | 146 | 2164 | 0 |
| C small | `[76,76,77,80]`, lambda 142 | 50,000 | 2388 | 496 | 9 | 140 | 2472 | 0 |

## Key Comparison

Existing best low-degree all-zero moment candidate before this run:

- score `424`
- l1 `208`
- max_abs `4`
- nonzero `128`
- `T2,T4,T6 = 0,0,0`

Best MITM-generated low-degree all-zero candidate in this run:

- tuple B
- score `1556`
- l1 `400`
- max_abs `7`
- nonzero `146`
- `T2,T4,T6 = 0,0,0`

No generated MITM candidate reached score `< 424`, `<= 360`, `<= 320`, or `<= 300`.

## Higher Moments

Some candidates had good higher-moment residues, for example A medium found `T2,T4,T6,T8,T10 = 0,0,0,0,0` with `T12=1`, but that candidate had score `6192`. This suggests low and higher p-adic moment compatibility alone does not naturally imply low SDS score under this block-pool MITM generator.

## Baseline Comparison

The moment-compatible pool did not improve the score distribution relative to the unconstrained random baseline in a way useful for low-score search. In A medium:

- moment pool min score: `2256`
- unconstrained baseline min score: `2760`
- moment pool median score: `5164`
- unconstrained baseline median score: `5168`

So the low-degree moment constraint shifts the best tail slightly in this sampled setup, but not remotely toward the existing score-only frontier or the existing score `424` all-zero moment candidate.

## Verdict

Negative for using this block feature pool + sampled MITM as a main generative route in its current form.

The p-adic moment route remains useful as a diagnostic and as a structured repair target, but broad independent block-pool recombination appears to destroy the delicate low-score defect cancellation. The low score candidates seem to require coherence across all four blocks that is not captured by individual block features `(g2,g4,g6)` alone.

No Hadamard 668 construction was found. No success candidate was generated. All saved outputs are near-hits or diagnostic candidates only.

## Next Direction

The next promising move is not larger random MITM with the same features. A better follow-up would preserve pair or quartet coherence:

- pair-level autocorrelation feature pools `(X1,X2)` and `(X3,X4)` using partial defect vectors, not only `(g2,g4,g6)`;
- MITM on low-dimensional projections of the full defect vector;
- or moment-preserving descent from the existing score `424` all-zero candidate, where block coherence is already present.

