# Benchmark run `20260815T013107Z`

Trials: 3 · temperature 0 · routing hosts=`any` sort=`throughput` quant=`fp8,fp16,bf16` zdr=`true` · slugs validated: True

Scored against 18 planted bugs (3 Critical) across 8 buggy fixtures + 1 clean control. Detection is severity-weighted (Critical 3 / High 2 / Medium 1.5 / Low 1). `Flaky` = bugs found in some but not all trials.

> **Targeted run — 4 of 13 manifest models scored** (`gemini-flash-high`, `gemini-flash`, `gemini-3.7-flash-high`, `gemini-3.7-flash`). Rankings below compare only these; this is not a full-panel result.

## Per-model

| Rank | Model | Detection | Bugs (maj) | Missed Crit | Flaky | False+ | Avg latency | Cost/run | Notes |
|---|---|---|---|---|---|---|---|---|---|
| 1 | gemini-flash-high | 98.6% | 18/18 | 0 | 1 | 0.0 | 11801 ms | ~$0.0813 |  |
| 2 | gemini-flash | 95.8% | 17/18 | 0 | 2 | 0.0 | 6897 ms | ~$0.0421 |  |
| 3 | gemini-3.7-flash-high | 95.8% | 17/18 | 0 | 2 | 0.0 | 11400 ms | ~$0.1331 |  |
| 4 | gemini-3.7-flash | 94.4% | 17/18 | 0 | 1 | 0.0 | 6980 ms | ~$0.0654 |  |

## Best-value combinations (union coverage of 1–3 models)

Coverage is the union across the set; cost is the sum of members. Ranked by missed Criticals, then coverage, then cost.

| Rank | Models | Size | Union detection | Missed Crit | Comb. cost/run | Comb. false+ |
|---|---|---|---|---|---|---|
| 1 | gemini-flash-high | 1 | 98.6% | 0 | $0.0813 | 0.0 |
| 2 | gemini-flash-high, gemini-flash | 2 | 98.6% | 0 | $0.1234 | 0.0 |
| 3 | gemini-3.7-flash, gemini-flash-high | 2 | 98.6% | 0 | $0.1468 | 0.0 |
| 4 | gemini-3.7-flash, gemini-flash-high, gemini-flash | 3 | 98.6% | 0 | $0.1888 | 0.0 |
| 5 | gemini-3.7-flash-high, gemini-flash-high | 2 | 98.6% | 0 | $0.2145 | 0.0 |
| 6 | gemini-3.7-flash-high, gemini-flash-high, gemini-flash | 3 | 98.6% | 0 | $0.2565 | 0.0 |
| 7 | gemini-3.7-flash-high, gemini-3.7-flash, gemini-flash-high | 3 | 98.6% | 0 | $0.2799 | 0.0 |
| 8 | gemini-3.7-flash-high, gemini-flash | 2 | 97.2% | 0 | $0.1752 | 0.0 |
| 9 | gemini-3.7-flash-high, gemini-3.7-flash | 2 | 97.2% | 0 | $0.1986 | 0.0 |
| 10 | gemini-3.7-flash-high, gemini-3.7-flash, gemini-flash | 3 | 97.2% | 0 | $0.2406 | 0.0 |
| 11 | gemini-flash | 1 | 95.8% | 0 | $0.0421 | 0.0 |
| 12 | gemini-3.7-flash, gemini-flash | 2 | 95.8% | 0 | $0.1075 | 0.0 |

- **Best 1-model set:** gemini-flash-high — 98.6% detection, 0 missed Crit, $0.0813/run.

- **Best 2-model set:** gemini-flash-high, gemini-flash — 98.6% detection, 0 missed Crit, $0.1234/run.

- **Best 3-model set:** gemini-3.7-flash, gemini-flash-high, gemini-flash — 98.6% detection, 0 missed Crit, $0.1888/run.

`~` = estimated cost (direct-Gemini token estimate); un-prefixed = real OpenRouter USD.

See `scorecard.json` for the per-bug detection matrix and `raw/` for full model output.
