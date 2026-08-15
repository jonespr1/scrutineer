# Benchmark run `20260815T001550Z`

Trials: 1 · temperature 0 · routing hosts=`any` sort=`throughput` quant=`fp8,fp16,bf16` zdr=`true` · slugs validated: True

Scored against 18 planted bugs (3 Critical) across 8 buggy fixtures + 1 clean control. Detection is severity-weighted (Critical 3 / High 2 / Medium 1.5 / Low 1). 

## Per-model

| Rank | Model | Detection | Bugs (maj) | Missed Crit | Flaky | False+ | Avg latency | Cost/run | Notes |
|---|---|---|---|---|---|---|---|---|---|
| 1 | gemini-flash | 95.8% | 17/18 | 0 | - | 0.0 | 6629 ms | ~$0.0158 |  |
| 2 | gemini-3.7-flash | 91.7% | 16/18 | 0 | - | 0.0 | 6664 ms | ~$0.0270 |  |

## Best-value combinations (union coverage of 1–3 models)

Coverage is the union across the set; cost is the sum of members. Ranked by missed Criticals, then coverage, then cost.

| Rank | Models | Size | Union detection | Missed Crit | Comb. cost/run | Comb. false+ |
|---|---|---|---|---|---|---|
| 1 | gemini-flash | 1 | 95.8% | 0 | $0.0158 | 0.0 |
| 2 | gemini-3.7-flash, gemini-flash | 2 | 95.8% | 0 | $0.0428 | 0.0 |
| 3 | gemini-3.7-flash | 1 | 91.7% | 0 | $0.0270 | 0.0 |

- **Best 1-model set:** gemini-flash — 95.8% detection, 0 missed Crit, $0.0158/run.

- **Best 2-model set:** gemini-3.7-flash, gemini-flash — 95.8% detection, 0 missed Crit, $0.0428/run.

`~` = estimated cost (direct-Gemini token estimate); un-prefixed = real OpenRouter USD.

See `scorecard.json` for the per-bug detection matrix and `raw/` for full model output.
