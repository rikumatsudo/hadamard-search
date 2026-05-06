# Route Verdict

```json
{
  "success_candidate_generated": false,
  "score_zero_reached": false,
  "verdict": "open_pending_guided_long_run",
  "notes": [
    "Canonical dedup is implemented and validated as a diagnostic layer.",
    "Existing frontier has 9 entries and 9 canonical classes, so it does not collapse under the current canonical equivalences.",
    "Primary guided smoke produced a valid bucketed frontier file, but did not improve existing frontier metrics.",
    "Active-defect smoke selected 3 moves and improved a weak guided near-hit from score=220 to score=192, but the output is dominated by existing frontier entries.",
    "Full guided new-basin generation may be long-running and should be evaluated from bucketed frontier files."
  ]
}
```
