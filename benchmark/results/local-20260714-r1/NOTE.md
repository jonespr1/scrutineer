# Note on this run (local exploratory)

Produced by a **local urllib runner** (not the committed workflow), 1 trial, temperature 0, routing
**unfiltered** (test-all: no quantisation or ZDR gate) so every model ran regardless of host.

**Read with care - this run does not discriminate the top models.** 5 of 10 models scored a perfect
100% and 7 scored >=95%, including on the "hard" `device_bridge.py` fixture (detections verified
genuine). The reason is methodological: an isolated, small planted-bug fixture makes any bug easy to
find, unlike a real PR where the same bug classes get missed because they are buried in a large,
mostly-correct change. So this run is reliable for catching **gross** failures, not for finely
ranking good models.

Notable, real signals (not artifacts):
- **gemini-pro** ranked last only because it **refused** to review `user_search.js` (the blatant
  injection fixture) with a safety message - a false-refusal, not weak detection. On the other four
  fixtures it was strong. On real (non-toy) PRs it has not refused.
- **hy3** errored on 3/6 fixtures (unreliable here); **grok-4.5** genuinely underperformed (77%).
- Zero false positives from any model on the clean control.

Next: fixtures are being redesigned to bury subtle bugs in large, realistic files so the benchmark
can actually separate the strong cheap models.
