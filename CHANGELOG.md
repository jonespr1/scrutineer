# Changelog

All notable changes to Scrutineer. Callers pin `@v1`, which tracks the latest non-breaking release.

Entries below v1.4.6 were not backfilled when this file was resumed; the git history for
`.github/workflows/review.yml` is the record of record for that gap.

## Unreleased

### Changed
- **Every third-party action is now SHA-pinned, and a test enforces it.** `ci.yml`'s header has
  claimed *"Third-party actions are SHA-pinned"* for months, but only `ci.yml` actually was —
  `review.yml` and `benchmark.yml` sat on bare `@v4` tags. That gap matters most in `review.yml`,
  which all 14 consumer repos execute: a moving tag means its owner can change what the whole estate
  runs, with no PR and no diff. `actions/checkout` and `actions/upload-artifact` are pinned at
  v7.0.1, with the SHAs resolved from upstream rather than taken from the bump PRs. `tests/caller_test.sh`
  now fails the build on any un-pinned reference, so the policy is asserted rather than assumed.

  Supersedes Dependabot #21 and #22, which bumped the versions but left the two tag pins as tags.

  The guard matches *every* `uses:` line and then subtracts the forms that cannot carry a SHA
  (`./local` paths, `docker://` images, setup.ps1's `{{REF}}` placeholder, commented-out lines), so
  a reference in a shape nobody anticipated fails loudly instead of going unexamined. It covers
  `.github/workflows/`, `examples/` and `setup.ps1`, and fails if it ever stops seeing `review.yml`
  — a scan that silently matches nothing is worse than no scan. `release.yml` uses no third-party
  actions at all, so the estate's entire action surface is now pinned.

  The one deliberate exception is scrutineer's own dogfood caller, which stays on
  `jonespr1/scrutineer/...@v1` — the moving major alias *is* the distribution mechanism, and pinning
  it to a SHA is precisely the failure the estate's Dependabot ignore rules exist to prevent.

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
