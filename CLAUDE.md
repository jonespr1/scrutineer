# Working in this repository

## What this product is for

Scrutineer **replaced a Gemini agent, and was meant to be seamless**. That is the product
requirement, not a nice-to-have. A repo installs one file, once, and from then on reviews simply
happen and quietly get better. The owner should never have to think about Scrutineer again.

Judge every change against that:

- **A change that requires consumer repos to act is a product failure**, not a chore. If a fix
  needs 15 pull requests, the design is wrong — fix the design, do not grind out the PRs.
- **"Seamless" includes the failure modes.** A command that silently does nothing, a review that
  is skipped without saying so, an error telling you to fix the wrong thing — each breaks the
  promise as surely as a crash.
- **The owner's attention is the scarce resource.** Fifteen PRs, forty-five review rounds and
  forty replies to move one delimiter is a failure even if every individual step was competent.

It is a reusable workflow consumed by ~15 repos. Fixes ship centrally, or they do not ship.

## The rule that matters most

**Anything that can live in `review.yml` MUST live in `review.yml`.**

`review.yml` ships via the `@v1` tag: change it, cut a tag, every consumer has it. The caller
(`examples/scrutineer.yml`, copied into each repo) does NOT ship that way — changing it means a
pull request in every consumer repo, a review round in each, and a reply owed on each.

Only four things genuinely have to be in the caller, and none of them have ever needed to change:

| In the caller | Why it must be |
|---|---|
| `on:` triggers | GitHub requires the workflow file in the repo |
| `permissions:` | A called workflow cannot grant itself permissions |
| `secrets:` | Must be passed explicitly by the caller |
| `uses:` pin | It is the reference |

Everything else — command matching, de-dupe, routing, advice — belongs in `review.yml`.

**This was learned expensively.** The `@review` command matcher was put in the caller's `if:`.
Fixing it took 15 pull requests, ~45 paid review rounds, and 40 replies, for a change that is one
tag under the correct design. If you find yourself opening a PR in more than one consumer repo,
stop and ask whether the thing you are changing should have been central.

## Do not fan out across repos without asking

A change touching every consumer is a large, expensive, outward-facing action. Put it to the repo
owner with the cost before doing it — not after. Fifteen draft PRs is not a neutral act: each one
fires a paid three-model round on open, and **each reply you post fires another**, because a
maintainer comment correctly counts as new developer activity in `already_reviewed()`.

## Engaging reviewers

Scrutineer exists to produce review findings and get them acted on. Extracting findings and fixing
them somewhere else is not engagement.

- **A review round ends with a reply on the PR where it was raised** — including when it is clean,
  and including when you fixed the finding upstream. "Acted on in another repo" is not an answer
  to a reviewer looking at this file.
- **Do not describe upstream state as branch state.** Saying "the docs are corrected" when they are
  corrected in a different PR is wrong, and reviewers have caught it.
- **Verify a finding before accepting or rejecting it.** Several have been confidently wrong
  (`contains()` is case-insensitive; `see @review this PR` does not fire). Several have been right
  when the instinct was to dismiss them. Run the case.
- **Do not reply just to acknowledge a clean round.** It costs a paid round to say nothing.

## Two layers that must move together

`review.yml`'s `already_reviewed()` decides whether a comment is "just a command" or real developer
activity. It has drifted from the command matcher **twice**, in opposite directions:

- one drift silently **skipped** a round the developer asked for;
- the other silently **spent** one they did not.

If you touch either, touch both, and extend `tests/dedupe_test.sh`.

## Comments and prose

The explanatory comments here are load-bearing — the trigger has regressed three times and each
time the reasoning that would have prevented it existed only in someone's head. But:

- **Never write a count in prose next to a list.** "Three limitations" beside four bullets has
  happened; so has "seven delimiters" beside ten. Nothing enforces it and it is wrong the moment
  the list changes. Name the thing, do not count it.
- **A confidently wrong comment is worse than none.** One claimed `author_association` stopped
  strangers spending credits; it gates the comment path only. It shipped verbatim into 15 repos.

## Verification

- Every behavioural fix gets a test, and **the test gets mutation-tested**: break the fix, show the
  test fails, then restore. A truth table in a chat transcript is not verification anyone can rely
  on — that was raised as a finding and it was right.
- Tests extract functions verbatim from the workflow (`awk` in `tests/*_test.sh`) so they cannot
  drift from what ships.

## Things only the repo owner can do

- **Push tags.** The proxy returns 403. A merged fix reaches nobody until a tag exists — say so
  plainly rather than reporting the work as delivered.
- **Merge.** Never merge without explicit authorisation, per PR.
- **Change repo settings**, e.g. `android-hdmi-camera`'s default branch is a leftover working
  branch, which is where its `issue_comment` triggers resolve from.

## Keep PR bodies true

A PR body describing an earlier revision is a stale artifact the owner reads before merging. If you
push nine commits, the body describes nine commits. Check it before saying a PR is ready — and
check the PR is actually out of draft before saying so.
