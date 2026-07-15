# Benchmark run `local-20260714-r2`

Trials: 1 · temperature 0 · routing hosts=`any` sort=`price` quant=`any (test-all)` zdr=`false (test-all)` · slugs validated: False

Scored against 18 planted bugs (3 Critical) across 8 buggy fixtures + 1 clean control. Detection is severity-weighted (Critical 3 / High 2 / Medium 1.5 / Low 1). 

## Per-model

| Rank | Model | Detection | Bugs (maj) | Missed Crit | Flaky | False+ | Avg latency | Cost/run | Notes |
|---|---|---|---|---|---|---|---|---|---|
| 1 | gemini-flash | 100.0% | 18/18 | 0 | - | 0.0 | 11049 ms | ~$0.0182 |  |
| 2 | minimax-m3 | 100.0% | 18/18 | 0 | - | 0.0 | 53616 ms | $0.0484 |  |
| 3 | kimi-2.6 | 100.0% | 18/18 | 0 | - | 0.0 | 157370 ms | $0.2189 |  |
| 4 | gemini-3-flash | 95.8% | 17/18 | 0 | - | 0.0 | 3922 ms | $0.0207 |  |
| 5 | deepseek-v4-pro | 95.8% | 17/18 | 0 | - | 0.0 | 54158 ms | $0.0377 |  |
| 6 | gemini-pro | 95.8% | 17/18 | 0 | - | 0.0 | 40267 ms | ~$0.0602 |  |
| 7 | qwen-3.7-max | 95.8% | 17/18 | 0 | - | 0.0 | 60753 ms | $0.1261 |  |
| 8 | grok-4.5 | 95.8% | 17/18 | 0 | - | 0.0 | 63256 ms | $0.3689 |  |
| 9 | glm-5.2 | 94.4% | 17/18 | 0 | - | 0.0 | 32459 ms | $0.0367 | ⚠️ 1 call error(s) |
| 10 | hy3 | 65.3% | 11/18 | 0 | - | 0.0 | 10147 ms | $0.0028 | ⚠️ 3 call error(s) |

## Best-value combinations (union coverage of 1–3 models)

Coverage is the union across the set; cost is the sum of members. Ranked by missed Criticals, then coverage, then cost.

| Rank | Models | Size | Union detection | Missed Crit | Comb. cost/run | Comb. false+ |
|---|---|---|---|---|---|---|
| 1 | gemini-flash | 1 | 100.0% | 0 | $0.0182 | 0.0 |
| 2 | gemini-flash, hy3 | 2 | 100.0% | 0 | $0.0210 | 0.0 |
| 3 | gemini-3-flash, gemini-flash | 2 | 100.0% | 0 | $0.0390 | 0.0 |
| 4 | glm-5.2, hy3 | 2 | 100.0% | 0 | $0.0395 | 0.0 |
| 5 | gemini-3-flash, gemini-flash, hy3 | 3 | 100.0% | 0 | $0.0418 | 0.0 |
| 6 | minimax-m3 | 1 | 100.0% | 0 | $0.0484 | 0.0 |
| 7 | hy3, minimax-m3 | 2 | 100.0% | 0 | $0.0512 | 0.0 |
| 8 | gemini-flash, glm-5.2 | 2 | 100.0% | 0 | $0.0549 | 0.0 |
| 9 | deepseek-v4-pro, gemini-flash | 2 | 100.0% | 0 | $0.0559 | 0.0 |
| 10 | gemini-3-flash, glm-5.2 | 2 | 100.0% | 0 | $0.0574 | 0.0 |
| 11 | gemini-flash, glm-5.2, hy3 | 3 | 100.0% | 0 | $0.0577 | 0.0 |
| 12 | deepseek-v4-pro, gemini-flash, hy3 | 3 | 100.0% | 0 | $0.0587 | 0.0 |

- **Best 1-model set:** gemini-flash — 100.0% detection, 0 missed Crit, $0.0182/run.

- **Best 2-model set:** gemini-flash, hy3 — 100.0% detection, 0 missed Crit, $0.0210/run.

- **Best 3-model set:** gemini-3-flash, gemini-flash, hy3 — 100.0% detection, 0 missed Crit, $0.0418/run.

`~` = estimated cost (direct-Gemini token estimate); un-prefixed = real OpenRouter USD.

See `scorecard.json` for the per-bug detection matrix and `raw/` for full model output.
