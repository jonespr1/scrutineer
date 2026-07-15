# Note on Run 2 (local exploratory, +3 hard fixtures)

Local runner, 1 trial, temp 0, unfiltered. Adds three **buried-bug** fixtures (XFF spoofing,
SSR hydration mismatch, JSON-LD data-loss) to test whether burying a subtle bug in a realistic,
mostly-correct file discriminates the strong models.

**Result: it mostly does NOT.** Every model except the broken `hy3` scored >=94%, and **every strong
model caught all three buried bugs** (XFF, hydration, JSON-LD). Even hidden in realistic single
files, decent reviewers find these. The only misses among the good models were scattered *Medium*
bugs (B6 broad-except, B9 upload validation). This reinforces the core conclusion: a single-file
planted-bug benchmark saturates - the discrimination that matters lives in **real multi-file PR
context** (see the divergence sweep in scrutineer-observations.md), which this cannot reproduce.

Two specific verified findings:
- **The gemini-pro refusal did NOT reproduce.** In Run 1 Pro refused `user_search.js` (dragging it
  to last); in Run 2 it reviewed it normally (2641 chars) and caught the criticals -> 95.8%,
  0 missed Critical. So that refusal was a **one-off / non-deterministic**, not reliable behaviour
  (Gemini isn't fully deterministic even at temp 0). Downgrade it from "a flaw" to "occasional."
- **glm-5.2's one call hung** (OpenRouter held the connection open past the 300s client timeout on
  `hard_app_sidebar.tsx`). Recorded as an error and EXCLUDED - its 94.4% / "hydration missed" is
  that hang, not a genuine miss. A latency/reliability data point, not a quality one.

Bottom line: synthetic benchmark = regression floor (catches only `hy3`-class breakage here);
model selection should be driven by the real-PR divergence analysis, not synthetic detection %.
