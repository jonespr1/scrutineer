# Changelog

All notable changes to Scrutineer. Callers pin `@v1`, which tracks the latest non-breaking release.

Entries below v1.4.6 were not backfilled when this file was resumed; the git history for
`.github/workflows/review.yml` is the record of record for that gap.

## v1.5.0 (pending)

### Fixed
- **npm's lockfile was being sent to the model in full, on every dependency PR.** The full-file
  context skips lockfiles by extension — `*.lock` catches yarn, Cargo, poetry and composer — but
  **`package-lock.json` ends in `.json`, so it never matched.** The estate is npm, so in practice the
  most common lockfile of all was handed to every reviewer in its entirety. Two consequences, both
  observed: it exhausted `CONTEXT_BUDGET`, so genuinely changed source files were dropped from the
  context with only a footnote; and the resulting prompt was large enough to push reviewers into
  timeouts (`SimplerHR-Stour#44`, GLM at 600s) and output-limit failures (`finish_reason=length`,
  where the whole budget goes on reasoning and you are billed for an empty review). Now also skips
  `*-lock.json`, `*-lock.yaml`, `npm-shrinkwrap.json` and `bun.lockb`. **This affects every repo on
  upgrade and needs no configuration.**

### Added
- **`DIFF_EXCLUDE`** — comma-separated globs of paths to keep out of the review, e.g.
  `"package-lock.json,*.lock,benchmark/results/*"`. **Empty by default**, so nothing changes until a
  repo opts in. Also applies to the full-file context. The excluded paths are named in the prompt,
  so the model is told those files changed and were withheld rather than inferring from silence, and
  the posted review reports how many were held back — a reviewer misled by absence is the same class
  of failure this fixes, so neither the model nor the reader is left to guess.

  **Why it exists.** The diff is capped at 200,000 characters and truncated in GitHub's
  *alphabetical* file order, so one large generated file pushes real code past the end. The reviewer
  notes the truncation in a single line of small print and then reviews confidently on a partial
  payload, while you pay for every token it did read. Measured on this repo's own PR #24: a 353,605
  character diff against the cap, with 111 committed benchmark artifacts sitting alphabetically
  between `manifest.json` and `run.sh` — so `run.sh`, both test suites and `scorecard.json` were
  never in the payload, across a round costing ~$0.36. Lockfiles are the common case: `package-lock`
  sorts before `src` and `tests`.

  Raising the cap would only move the problem and cost more. `setup.ps1 -DiffExclude` sets it across
  repos.

## v1.4.8 (pending)

### Added
- **`GEMINI_THINKING`** — an optional reasoning budget for Gemini slots, in tokens (`-1` lets the
  model decide). **Unset by default**: the request is byte-identical to before, so nothing changes
  and nothing extra is billed unless you opt in. Malformed values warn and fall back to off rather
  than failing the review.

### Fixed
- **Gemini cost reporting was understating your bill, and still is until you take this release.**
  Thinking tokens are billed at the output rate but Gemini reports them in `thoughtsTokenCount`,
  separately from `candidatesTokenCount` — and only the latter was counted. This is not hypothetical
  and not limited to the new variable: measured on `gemini-flash-latest` with *no* reasoning config
  at all, a review call spends **~1,167 thinking tokens against ~524 tokens of actual review**, so
  roughly three quarters of the output spend was invisible. Current Gemini models think whether or
  not you ask them to; `GEMINI_THINKING` only sets the budget for something already happening. The
  reported figure in each review footer will rise on upgrade — the underlying spend does not
  change, it was always this.

## v1.4.7 (pending)

### Fixed
- **Reasoning models no longer publish their chain-of-thought into your pull requests.** `minimax-m3`
  emits its working inside `message.content` rather than a separate field, so reviews were being
  posted with pages of "Let me analyze this carefully..." above the actual findings. A leading
  `<...think>` block is now stripped. A block that never closes means the response was cut off
  mid-thought, so there is no review underneath — that is now reported as an output-limit failure
  instead of posting a wall of reasoning.
- **A review cut off partway through is no longer posted as though it were complete.** `finish_reason`
  / `finishReason` was only consulted when the response was *empty*, so a truncated-but-non-empty
  review looked finished. A reviewer cut off before reaching its Findings section silently lost
  findings you were billed for. The partial review is still posted — it has value — but now carries
  an explicit "this was cut off" banner. Fixed on both the OpenRouter and Gemini paths.

## v1.4.6 (pending)

### Changed
- **`setup.ps1 -Reviewers` now defaults to `"default"`**, which *deletes* the repo's `REVIEWERS`
  variable so it inherits `review.yml`'s panel, instead of pinning it to `'gemini'` (the old
  default). **Re-running `setup.ps1` on an already-onboarded repo with no `-Reviewers` flag will
  remove its existing `REVIEWERS` pin** and upgrade it to the full default panel, which may include
  paid OpenRouter models. Pass an explicit `-Reviewers` value to keep a repo pinned. The script now
  prints a notice at the point of removal so this isn't silent.

## v1.1.0

### Added
- **Full-file context.** The full current content of each changed file is sent alongside the diff
  (largest change first, bounded by the new `CONTEXT_BUDGET` variable), so reviewers can catch
  issues that depend on code outside the diff hunks - callers, error paths, and values set in one
  place but misused in another.
- **Calibrated review prompt.** Steers toward high-value bug classes (state written but never
  cleared or invalidated, misbehaving defaults such as a `-1` index that wraps, callback/signal
  wiring, stale fallback paths) and requires each finding to be tied to a specific line with a
  stated failure path - cutting false positives.

### Changed
- **Gemini Pro is now the default** for a bare `gemini` slot (previously Flash). Pro produces
  materially fewer false positives. Set `GEMINI_MODEL=gemini-flash-latest` to restore the cheaper
  model.
- **Reviewers run in parallel** instead of sequentially; wall-clock is now the slowest single model
  call rather than the sum. Job `timeout-minutes` reduced from 15 to 8.
- **Per-call timeouts raised** to 300s (OpenRouter) and 240s (Gemini). Reasoning models on large
  diffs were hitting the old 180s ceiling.

### Fixed
- **Failure messages are now specific**, never a bare "no response": timeout, HTTP error,
  output-limit (`finish_reason=length`/`MAX_TOKENS`), safety block, and "no host matched routing
  constraints" are each reported distinctly.
- **`@review <model>` filtering now works.** The triggering comment body was never passed into the
  job, so the keyword filter (e.g. `@review glm`) silently ran every reviewer; the body is now
  wired through.
- **Clean, all-green pipeline.** Runs for a PR are serialised and never cancelled; a redundant
  trigger on an already-reviewed commit exits as a successful check instead of showing "Cancelled"
  or posting a duplicate review.

## v1.0.0

- Initial release: self-hosted, model-agnostic pull-request reviewer using Google Gemini and/or any
  OpenRouter model. Conversation-aware re-reviews, per-repo model/routing/privacy configuration,
  zero-data-retention by default for OpenRouter, optional per-repo style guide, and multi-repo
  rollout via `setup.ps1`.
