# Changelog

All notable changes to Scrutineer. Callers pin `@v1`, which tracks the latest non-breaking release.

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
