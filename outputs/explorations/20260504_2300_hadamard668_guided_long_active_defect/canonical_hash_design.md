# Canonical Hash Design

```json
{
  "allowed_equivalences": [
    "independent cyclic translation per block",
    "simultaneous unit multiplier in Z_v^*",
    "same-size block permutation only"
  ],
  "excluded_equivalences": [
    "complement transformation",
    "unequal-size block permutation"
  ],
  "hash": "SHA256(JSON(v,ks,canonical_blocks))",
  "purpose": "discovery and dedup only; not a mathematical success condition"
}
```
