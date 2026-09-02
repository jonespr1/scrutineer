# Changelog

All notable changes to Scrutineer. Callers pin `@v1`, which tracks the latest non-breaking release.

Entries below v1.4.6 were not backfilled when this file was resumed; the git history for
`.github/workflows/review.yml` is the record of record for that gap.

## v1.7.1 (pending)

### Fixed
- **A comment-triggered re-review could resolve the wrong commit.** On `marketing-os#51`, an
  `@review` comment posted right after a push got back the PR's *first* commit from
  `gh api pulls/{n} --jq '.head.sha'`, while the real head — cross-checked independently against
  `git/ref/heads/<branch>` — was already several commits ahead. All three reviewer slots share one
  `HEAD_SHA` variable, so the single bad read fanned into all three reviews citing the identical
  wrong commit and re-raising already-fixed findings as still open: a full paid round spent
  reviewing stale code.

  Unlike the diff fetch a few lines below it, which retries on *failure*, this read had no such
  guard — and a stale response is a `200 OK`, indistinguishable from a good one, so retry-on-
  failure alone would not have caught it. `resolve_head_sha()` now requires two consecutive reads
  to agree before trusting the result. Covered by `tests/head_sha_test.sh`, which extracts the
  function verbatim and drives a fake `gh` through the exact stale-then-correct sequence observed,
  plus the always-stable and never-stabilises cases. Mutation-tested: a version that retries but
  trusts the first non-empty read (looks like a fix, isn't) fails the test on the same case that
  cost the round.

  Review of this fix (`#31`) surfaced three more gaps in the same area, all closed here:

  - **An unresolved `HEAD_SHA` degraded silently instead of failing.** If all four reads came back
    empty, the review still ran and posted with a marker reading `sha=none` — a literal string no
    real commit SHA can ever match, so that review could never be recognised as "already reviewed"
    again, for any future commit, ever. Worse than the diff fetch's own failure mode (a red check,
    nothing spent). Now fails the same way the diff fetch does: loud, before any model is called.
  - **The diff fetch could still disagree with the just-resolved `HEAD_SHA`.** It's a separate,
    later call to the same live endpoint, so a push landing in the gap between resolving the SHA
    and fetching the diff would review newer content under an older marker — the same failure
    class this whole fix exists to close, just moved one step down. One extra read after the diff
    fetch now checks for that, and re-resolves and re-fetches once if the head moved.
  - **`tests/head_sha_test.sh` wasn't wired into CI.** `ci.yml` lists each test file explicitly
    rather than globbing `tests/*.sh`, and the new file was missing from that list — so the
    "Unit tests" check that passed on `#31` had never actually run it. Added.

  Three additional test-harness fixes, all mutation-verified: the sequence-encoding helper used
  `:-` instead of `-` for a fallback lookup, which silently replaced a deliberately-empty sequence
  element (simulating a dropped read) with the last element — masking the exact case a mid-sequence
  failure needs to exercise; the sleep-count assertion had no default, so a broken marker capture
  produced a shell error but still reported the test as passing; and the nested test harness didn't
  run under `set -euo pipefail` the way production does.

  Declined, with reasoning: cross-checking the resolved SHA against `git/ref/heads/<branch>` as a
  second, independent source. It would require resolving `.head.repo.full_name` for fork PRs and
  querying a repository our token has no guaranteed read access to — trading a rare residual race
  for a new failure mode on every fork PR. Two agreeing reads 2 seconds apart already converts
  "always wrong on this failure" into "wrong only if the lag exceeds the polling window," which is
  the trade worth making without that risk.

  A second review round on the fix above (glm) found the `fetch_diff()` re-check itself had
  introduced a `set -e` bug: `DIFF="$(fetch_diff)"; drc=$?` looks correct, but a failing command
  substitution inside a plain assignment is what `set -e` treats as the failing command — the
  script aborted on that exact line, so `drc=$?` and the `::error::` diagnostic it gates never
  ran. Confirmed by reproduction before fixing: the pre-fix form silently swallowed the
  diagnostic and exited 1 anyway, which is why nothing red-flagged it in CI. Both call sites now
  use `drc=0; DIFF="$(fetch_diff)" || drc=$?` — the exemption `set -e` grants to `||` is what
  the original `if DIFF="$(...)"; then ... else ... fi` form relied on before this file had a
  named `fetch_diff()` to call twice. `tests/fetch_diff_test.sh` pins both the extracted
  function and the literal call-site pattern in `review.yml` itself (a correct function behind
  an unsafe call site is still the bug), plus a behavioural run under `set -euo pipefail` proving
  the diagnostic is reachable. Mutation-tested: reverting either call site to the unsafe form
  fails two of the three checks.

  Also from that round: the concurrency comment claiming "every trigger ends as a success" was
  already false before this PR (the diff fetch has always had a real `exit 1`) and more so after
  it (a second exit-1 path, for an unresolved `HEAD_SHA`). Corrected.

  A third round (glm again) found one Low, purely in the test harness: `tests/head_sha_test.sh`
  captured a test's `sleep`-count via a fixed shared path, `/tmp/head_sha_test_stderr`, truncated
  and read once per `check()` call. Two concurrent invocations of the script — a developer running
  it in two shells, or a future CI matrix splitting test files across jobs — could truncate
  between another run's marker write and its own grep, or read another run's count into the wrong
  assertion. Flagged as Low since this repo's own CI runs tests serially, so it couldn't fire
  today. Fixed anyway: both temp files (`idxfile` and the new one) are now created per-`check()`
  call rather than a fixed path, mirroring the pattern `idxfile` already used. Proven, not just
  argued: 8 copies of the test run in parallel, 5 rounds — the fixed-path version raced on **every
  single round** (worse than "Low" suggested; the file's own repeated truncation makes this a
  near-certainty under real concurrency, not a rare edge case), the per-call version passed
  cleanly on all 40 runs.

## v1.7.0 (pending)

### Changed
- **The `@review` matcher moves out of the caller and into `review.yml`, so it ships via `@v1`.**
  This is the important change, and it is a correction of a design mistake rather than a feature.

  Scrutineer replaced a Gemini agent and was meant to be seamless: install one file, forget it,
  reviews get quietly better. Putting the command matcher in the caller broke that promise —
  every refinement to it needed a pull request in all fifteen consumer repos. Adding three
  delimiters cost **15 PRs, ~45 paid review rounds and 40 replies**, for a change that is one tag
  under the correct design.

  The caller now carries only a cheap prefilter, `contains(body, '@review')`, which fires on any
  comment containing the command anywhere. The precise rule — line-anchored, whole-word, with its
  delimiter set and documented limitations — is `is_review_command()` in `review.yml`.

  **The caller should never need changing again.** Only four things genuinely cannot be
  centralised: the `on:` triggers (GitHub requires the file in-repo), `permissions:` (a called
  workflow cannot grant itself any), `secrets:` (must be passed explicitly), and the `uses:` pin.
  None has changed in the product's life. A guard in `caller_test.sh` now fails if the matcher
  creeps back.

  **The cost, stated plainly:** a comment merely discussing `@review` now starts a runner, which
  exits within seconds without calling any model. Runner seconds instead of zero — but no API
  spend, and no consumer ever has to touch the file again. Four reviewers proposed moving the gate
  out of `if:`; I declined on the grounds that it would spin a runner on *every* comment. That was
  true only of the version where the caller has no gate at all. They were right and I had argued
  against a weaker proposal than the one they made.

  Also simpler: `grep` matches line by line, so `^` gives the line anchoring the caller had to
  fake by wrapping the body in newlines. Ten `contains(format(...))` clauses become one regex.

### Fixed
- **`already_reviewed()` can no longer drift from the command rule undetected.** The two have
  diverged twice — once silently skipping a requested round, once silently spending one.
  `trigger_test.sh` now asserts they carry the same delimiter set, so the next divergence fails CI
  rather than reaching an invoice.

## v1.6.2 (pending)

### Fixed
- **`@review!`, `@review?` and `@review;` now fire.** v1.6.1 justified the `,` `:` `.` delimiters by
  "natural phrasing" and then omitted three of the most natural endings, so those comments were a
  **silent no-op** — no run, no feedback. Raised independently on seven of the fifteen rollout PRs
  by `minimax/minimax-m3` and `z-ai/glm-5.3-flash`; the asymmetry was theirs to spot and it was real.

- **Truncation advice no longer tells you to trim a payload that is already tiny.** `cap_advice()`
  chose between "raise the cap" and "reduce the payload" purely from throughput against the
  timeout, never asking whether the payload was actually large. On `brand-assure-screen-api#108` it
  advised trimming a **7,698-token** prompt — against a ceiling of roughly 200,000 — because the
  model had emitted 32,000 tokens reviewing a single workflow file. There was nothing to trim; the
  model over-generated. Below 20,000 input tokens the advice now says so and recommends a re-run or
  a different slot, since output length varies widely between hosts and between runs on one host.

  This is the same wrong-remedy failure `cap_advice()` was written to prevent, arriving from the
  input side rather than the output side. Scrutineer found it in its own error message while
  reviewing its own rollout.

- **Bot-authored comments can no longer trigger a paid round.** The `pull_request` path already
  skipped bot authors; the `issue_comment` path did not, so a bot holding COLLABORATOR could spend
  credits — including by quoting a previous review that contained the command, which the anchoring
  made *more* likely, not less. `github.event.comment.user.type != 'Bot'` now guards it. This was
  already carried as a local customisation in `orange_france`; the template has adopted it.

- **The space delimiter is no longer an invisible trailing space.** It was written as
  `format('{0}@review ', ...)` — a space inside a quoted string, invisible in diffs, blame and
  review. `z-ai/glm-5.3-flash` pointed out on `Sell-Faster-on-eBay#103` that a reformatter or a
  careless edit dropping it degrades the needle to `\n@review`, which is a prefix of
  `\n@reviewer` — silently reintroducing the exact bug this work exists to fix. It is now
  `fromJson('" "')`, consistent with the CR and tab clauses and visible to a reader.

- **The de-dupe's activity rule now carries the same delimiter set as the trigger.** Adding `!` `?`
  `;` to the trigger without adding them here made the two layers disagree: `@review!` was a valid
  command to the trigger but *developer activity* to `already_reviewed()`, so it bypassed the skip
  and spent a full paid round on an already-reviewed, unchanged commit — where a plain `@review`
  correctly exits green. Caught by `minimax/minimax-m3` on the PR that introduced it, before merge.

  This is the second time these two layers have drifted in opposite directions. The comment in
  `review.yml` now says explicitly that they must move together, and `dedupe_test.sh` pins all six
  punctuation forms (`,` `:` `.` `!` `?` `;`).

### Documented
- **The `author_association` comment was wrong.** It claimed the check "stops strangers from
  triggering reviews (and spending your API credits / runner minutes) on public repos". It gates
  the **comment path only** — the PR-open path fires for any non-bot author. Raised on six of the
  fifteen rollout PRs by `z-ai/glm-5.3-flash`. The behaviour is deliberate (auto-review is the
  point); the claim was not true, and is now stated accurately along with the fork consequence.

- **Four limitations**, now stated in the README and the caller comment. Three follow from the
  matcher having no regex, and all three are pinned by `tests/trigger_test.sh` so they stay
  deliberate: `@review` flush-left inside a fenced code block **does** fire (found by
  `z-ai/glm-5.3-flash`), a line **starting** with `@review ` fires even as prose about the command,
  and indented `@review` does **not** fire. The fourth — opening a draft PR fires a review — is a
  trigger-design choice rather than a matching limit, and cannot be pinned by that test.

- **Corrected the case-insensitivity note.** It claimed "contains/format are case-insensitive".
  Only `contains()` is a comparison; `format()` is a string builder. Two reviewers disagreed about
  this — one asserting `contains()` is case-*sensitive*. It is not, per GitHub's documentation, so
  the behaviour is unchanged and only the wording was wrong.

## v1.6.1 (pending)

### Fixed
- **The `@review` command is now anchored at both ends, not just the start.** `startsWith(body,
  '@review')` also matched `@reviewer`, `@reviews` and `@reviewership`, so a member mentioning any
  such handle spent a full paid review round. Found by `z-ai/glm-5.3-flash` reviewing the caller on
  `jonespr1/buildingsaas#1` — the only slot of three to catch it.

  GitHub expressions have no regex, so rather than test the character following the command, the
  body is wrapped in newlines — `format('{0}{1}{0}', "\n", body)`. That turns "starts a line" into a
  plain `contains()` and, unlike `startsWith`, makes the *final* line testable too. What follows the
  command must then be LF, CR (the web UI submits CRLF), a space or a tab, so `@review glm` and
  `@review<TAB>glm` both still work.

  The de-dupe bounded the cost but did not remove it: it discounts comments starting with `@review`
  as developer activity, so `@reviewer` on an already-reviewed commit exited 0 for free — but on a
  commit not yet reviewed it spent a real round.

  Accepted delimiters after the command are a space, tab, LF, CR and `,` `:` `.` — the punctuation
  forms are deliberate: anchoring the end without them regressed `@review, please look` from
  working to a **silent no-op**, which is the worst failure mode this trigger has (the commenter
  gets no feedback at all). Raised by `minimax/minimax-m3` on the PR.

  **The trigger lives in the caller, so this does not ship via `@v1`.** Onboarded repos keep the
  old trigger until their `.github/workflows/scrutineer.yml` is refreshed from
  `examples/scrutineer.yml`. The de-dupe fix below *does* ship via `@v1`.

- **README now states the latency trade-off of the default GLM slot.** The cost table advertised
  GLM 5.3 Flash at ~2 cents with no mention that it is ~6x slower than 5.2 (298s vs 48s measured),
  making it the default slot most likely to hit the 600s call ceiling on a large diff. That was
  documented in the v1.6.0 changelog entry but not where someone choosing a panel would see it.

- **A reply beginning "@reviewer…" no longer silences the round the developer then asks for.**
  `already_reviewed()` decided whether a comment counted as new developer activity with
  `startswith("@review")`, which also swallowed `@reviewer` and `@reviews`. Concrete path: the bot
  reviews commit A → a member replies *"@reviewer's timeout point is wrong, I fixed X"* → the member
  comments `@review` → the trigger fires, but the de-dupe finds no qualifying activity since the
  last review at A, skips every slot and exits green. **The requested re-review silently did not
  happen and the counter-argument never reached the model.** The activity test now uses the same
  whole-word rule as the trigger. Found by `z-ai/glm-5.3-flash`.

  Note this hole was *masked* until now: before the trigger was anchored, such a reply
  accidentally fired a round of its own.

- **README no longer documents defaults the code abandoned.** The configuration table claimed
  `REVIEWERS` defaults to `gemini` ("1 to 2 slots") and `GEMINI_MODEL` to `gemini-pro-latest`.
  Both were true until `4c2e257` moved the central default to the three-slot panel and the bare
  `gemini` slot back to Flash; the docs were never updated. Verified against the git history rather
  than assumed — the code is right and the docs were stale, not the reverse. Also raised by
  `z-ai/glm-5.3-flash`.

## v1.6.0 (pending)

### Changed
- **The default GLM slot moves from `z-ai/glm-5.2` to `z-ai/glm-5.3-flash`.** 5.3-flash is the
  graduated form of the `stealth/ox-alpha` model that reviewed across this estate during its testing
  period, where it repeatedly found issues the rest of the panel missed. It is substantially cheaper
  — list price **$0.075/$0.25 per 1M tokens against 5.2's $1.19/$3.74**, roughly 15x — though the
  realised saving is smaller because it writes more: measured on `Sell-Faster-on-eBay#96`,
  **$0.019 against $0.093**, about 5x.

  **It is markedly slower.** On that same PR: 298s against 5.2's 48s, at roughly 87 tok/s. That
  consumes half the 600s per-call window, so on a diff much larger than ~37,000 input tokens it is
  the slot most likely to hit the timeout. Repos with consistently large PRs may prefer to pin
  `REVIEWERS` to `z-ai/glm-5.2`, which remains available.

  Verified to serve under the default privacy posture (`zdr: true`, `data_collection: deny`) before
  this change was made — the stealth endpoint did not, and that turned out to be a property of the
  stealth infrastructure rather than of the model.

  Only affects repos that inherit the default. A repo pinning `REVIEWERS` keeps whatever it names.

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

### Fixed
- **Failure messages named the wrong remedy when a review was cut off.** `finish_reason=length`
  always said *"raise `OPENROUTER_MAXTOKENS`"*. That advice is actively harmful when the **call
  timeout**, not the cap, is what stopped the model: at the ~49 tok/s these hosts publish, the 600s
  ceiling only buys ~29,000 tokens, which is *below* the 32,000 default. Raising the cap there does
  not buy a longer review — it buys a **timeout, which posts nothing**, replacing a partial review
  that at least arrived with a banner. Both ceilings are now compared against the throughput the
  host just demonstrated, and the message names whichever one actually bound.

  Measured on `ba-verify-line#320`: minimax hit the cap while ox-alpha timed out on the *same*
  commit and the same 205k-token payload. The two failures differ only by host speed, and no static
  string can tell them apart.

- **No failure message stated the payload size**, which is the one number that decides what to do
  about it. Output-limit failures now report prompt tokens; timeouts report the prompt in characters
  (a timed-out call returns no usage block, so token counts are unavailable). Timeout messages also
  say plainly that they are a **speed** limit that `OPENROUTER_MAXTOKENS` cannot fix.

- **Gemini's timeout message blamed the diff**, naming neither `CONTEXT_BUDGET` nor `DIFF_EXCLUDE` —
  yet full-file context is the larger term (600,000 chars against the diff's 200,000 cap). It now
  points at the bigger half first.

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
