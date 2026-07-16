# Scrutineer benchmark

A reproducible, stored comparison of review models for Scrutineer. It runs each model against a
fixed set of files with **deliberately planted bugs** (known ground truth) and records, per model:

- **Detection** — which planted bugs it found, severity-weighted (Critical 3 / High 2 / Medium 1.5 / Low 1)
- **Missed criticals** — planted 🔴 bugs it did not find
- **False positives** — Critical/High/Medium findings raised against a **clean** control file
- **Cost** — real USD for OpenRouter models (from the API); an editable estimate for direct Gemini
- **Latency** — wall-clock per call
- **Routing metadata** — the OpenRouter hosts / sort / ZDR used (data residency and zero-retention
  are *routing configuration*, not a per-model property, so they're recorded, not scored)

Results are committed under `benchmark/results/<run_id>/` and indexed in [`RESULTS.md`](RESULTS.md),
so the comparison is a standing asset you can re-run and diff over time — our own benchmark.

## How to run

**In GitHub Actions (recommended — this is where the API keys and network access live):**
Actions → **Scrutineer benchmark** → *Run workflow*. Optionally set `only` (a subset of model ids)
and `strict`. It runs, scores, writes to `$GITHUB_STEP_SUMMARY`, commits results, and uploads them
as an artifact. Needs the repo secrets `OPENROUTER_API_KEY` and/or `GEMINI_API_KEY`.

**Locally** (needs the same env vars exported, and network access to the providers):

```bash
export OPENROUTER_API_KEY=... GEMINI_API_KEY=...
benchmark/run.sh                       # runs all models -> benchmark/results/<timestamp>/raw/
python3 benchmark/score.py <run_id>    # scores that run; add --strict for line-exact matching
benchmark/run.sh <id> --only glm-5.2,gemini-3-flash   # a subset
```

## What's in here

| Path | Purpose |
|---|---|
| `manifest.json` | Ground truth: the model list, the fixtures, and every planted bug with its line anchor + detection regexes |
| `fixtures/` | The code under review. Four buggy files + one clean control (`string_utils.js`) |
| `lib/call_model.sh` | Calls one model (Gemini-direct or OpenRouter), mirroring `review.yml`; captures cost/latency/tokens |
| `lib/prompt_instructions.txt` | The review prompt — kept identical to `review.yml` so results reflect real behaviour |
| `run.sh` | Runs every model × fixture, saves raw JSON output |
| `score.py` | Scores raw output vs `manifest.json`; writes `scorecard.json`, per-run and rolled-up `RESULTS.md` |
| `results/` | Committed run outputs |

## Adding a model

Append to `models[]` in `manifest.json`. `spec` uses Scrutineer's own syntax: `gemini:<model>` for
direct Google, or an OpenRouter id (e.g. `z-ai/glm-5.2`). Slugs flagged `"verify": true` are
best-guesses — `run.sh` validates every OpenRouter slug against `/api/v1/models` and skips unknown
ones with near-match suggestions, so a typo never looks like a model failure.

## Adding a fixture / bug

1. Drop a file in `fixtures/` with one or more planted defects (or a clean file with `"clean": true`).
2. Add the fixture to `fixtures[]` and each bug to `bugs[]` in `manifest.json`, with a `line` anchor,
   `severity`, and `patterns` (case-insensitive regexes that a correct finding would contain). Keep
   patterns specific enough to distinguish bugs that share a file.

## Honesty notes (read before trusting a number)

- **Scoring is a transparent heuristic, not an oracle.** A bug counts as detected when the review
  matches one of its regexes *and* cites a nearby line (or the filename). Raw output is always kept
  in `raw/` so you can adjudicate any call; `--strict` requires the line match. Tune `patterns` if a
  real detection is being missed or over-credited.
- **Direct-Gemini cost is an estimate.** Google's API returns tokens, not USD, so `score.py` applies
  an editable price map (marked `~` in the table). OpenRouter costs are the real billed figures.
  Update `PRICES` in `score.py` to your actual Google rates for an apples-to-apples total.
- **Data residency / zero-retention are recorded, not scored** — they depend on `OPENROUTER_HOSTS`
  and `OPENROUTER_ZDR`, which apply equally to every OpenRouter model in a run.
- **One review per file.** Real PRs vary; this measures relative bug-finding on a controlled set,
  which is what a fair model comparison needs. Add more/larger fixtures to probe different sizes.
