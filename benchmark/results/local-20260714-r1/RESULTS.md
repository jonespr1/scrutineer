# Benchmark run `local-20260714-r1`

Trials: 1 · temperature 0 · routing hosts=`any` sort=`price` quant=`any (test-all)` zdr=`false (test-all)` · slugs validated: False

Scored against 15 planted bugs (3 Critical) across 5 buggy fixtures + 1 clean control. Detection is severity-weighted (Critical 3 / High 2 / Medium 1.5 / Low 1). 

## Per-model

| Rank | Model | Detection | Bugs (maj) | Missed Crit | Flaky | False+ | Avg latency | Cost/run | Notes |
|---|---|---|---|---|---|---|---|---|---|
| 1 | gemini-flash | 100.0% | 15/15 | 0 | - | 0.0 | 9610 ms | ~$0.0132 |  |
| 2 | minimax-m3 | 100.0% | 15/15 | 0 | - | 0.0 | 24644 ms | $0.0186 |  |
| 3 | glm-5.2 | 100.0% | 15/15 | 0 | - | 0.0 | 22413 ms | $0.0200 |  |
| 4 | deepseek-v4-pro | 100.0% | 15/15 | 0 | - | 0.0 | 52372 ms | $0.0242 |  |
| 5 | qwen-3.7-max | 100.0% | 15/15 | 0 | - | 0.0 | 50076 ms | $0.0698 |  |
| 6 | gemini-3-flash | 95.1% | 14/15 | 0 | - | 0.0 | 4492 ms | $0.0132 |  |
| 7 | kimi-2.6 | 95.1% | 14/15 | 0 | - | 0.0 | 106562 ms | $0.0859 |  |
| 8 | grok-4.5 | 77.0% | 11/15 | 0 | - | 0.0 | 8950 ms | $0.0571 |  |
| 9 | hy3 | 63.9% | 9/15 | 0 | - | 0.0 | 11506 ms | $0.0013 | ⚠️ 3 call error(s) |
| 10 | gemini-pro | 63.9% | 10/15 | 2 | - | 0.0 | 18699 ms | ~$0.0325 |  |

## Best-value combinations (union coverage of 1–3 models)

Coverage is the union across the set; cost is the sum of members. Ranked by missed Criticals, then coverage, then cost.

| Rank | Models | Size | Union detection | Missed Crit | Comb. cost/run | Comb. false+ |
|---|---|---|---|---|---|---|
| 1 | gemini-flash | 1 | 100.0% | 0 | $0.0132 | 0.0 |
| 2 | gemini-flash, hy3 | 2 | 100.0% | 0 | $0.0145 | 0.0 |
| 3 | minimax-m3 | 1 | 100.0% | 0 | $0.0186 | 0.0 |
| 4 | hy3, minimax-m3 | 2 | 100.0% | 0 | $0.0199 | 0.0 |
| 5 | glm-5.2 | 1 | 100.0% | 0 | $0.0200 | 0.0 |
| 6 | glm-5.2, hy3 | 2 | 100.0% | 0 | $0.0213 | 0.0 |
| 7 | deepseek-v4-pro | 1 | 100.0% | 0 | $0.0242 | 0.0 |
| 8 | deepseek-v4-pro, hy3 | 2 | 100.0% | 0 | $0.0255 | 0.0 |
| 9 | gemini-3-flash, gemini-flash | 2 | 100.0% | 0 | $0.0264 | 0.0 |
| 10 | gemini-3-flash, gemini-flash, hy3 | 3 | 100.0% | 0 | $0.0277 | 0.0 |
| 11 | gemini-flash, minimax-m3 | 2 | 100.0% | 0 | $0.0318 | 0.0 |
| 12 | gemini-3-flash, minimax-m3 | 2 | 100.0% | 0 | $0.0319 | 0.0 |

- **Best 1-model set:** gemini-flash — 100.0% detection, 0 missed Crit, $0.0132/run.

- **Best 2-model set:** gemini-flash, hy3 — 100.0% detection, 0 missed Crit, $0.0145/run.

- **Best 3-model set:** gemini-3-flash, gemini-flash, hy3 — 100.0% detection, 0 missed Crit, $0.0277/run.

`~` = estimated cost (direct-Gemini token estimate); un-prefixed = real OpenRouter USD.

See `scorecard.json` for the per-bug detection matrix and `raw/` for full model output.
