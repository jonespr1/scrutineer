# Scrutineer

**A thorough, self-hosted, model-agnostic AI code reviewer for GitHub pull requests.**

> *A thorough second pair of eyes on every pull request.*

Scrutineer posts a structured review on your PRs (grouped by severity, with concrete fixes)
using **Google Gemini, GLM 5.2, or any model on [OpenRouter](https://openrouter.ai)**. It runs
entirely in GitHub Actions with your own API key(s). No third-party app to install, no data
sent anywhere except the model provider you choose, and you control cost, host, and privacy
down to the routing level.

---

## Set it up with an AI assistant (easiest - no coding needed)

If you use an AI coding assistant like **Claude Code**, you do not need to understand any of
the YAML or scripts below. Open your assistant in the repository you want reviewed and paste
this:

> Set up the Scrutineer code reviewer from https://github.com/jonespr1/scrutineer on this
> repository. Read that repo's README for the exact steps, then:
> 1. Ask me which model(s) I want to review with (Gemini, GLM 5.2, or both), and get any API
>    keys you need from me.
> 2. Add my key(s) as GitHub repository secrets.
> 3. Add the caller workflow and set the `REVIEWERS` configuration variable.
> 4. Open a small test pull request and confirm a review is posted, then clean it up.

The assistant will read this README, walk you through getting a (free-to-create) API key, add
the two small files, and verify it works. Everything it needs is documented below.

---

## What it does

- **It just works.** It does one deterministic thing: fetch the diff, ask a model, post the
  review. No fragile agent tool-loops to break.
- **Reads the whole file, not just the diff.** Each changed file's full current content is sent
  alongside the diff, so the model catches bugs that depend on code the hunk does not show
  (callers, error paths, a value set in one place and misused in another).
- **Your choice of model.** Gemini on its own, Gemini plus a second model, or two models
  entirely via OpenRouter - a genuine second opinion from two independent AIs on the same diff.
- **Bring one key.** Route everything through OpenRouter and you only need a single account.
- **Privacy and cost you control.** For OpenRouter models you pin the exact hosts
  (jurisdiction), forbid training on your code, cap price, and sort by cost or speed.
- **Conversation-aware.** Re-reviews read the prior thread: they acknowledge fixes, accept
  your reasoning, and stop re-raising settled points.

---

## Manual setup

Four steps. (An AI assistant can do all of this for you - see above.)

**1. Get an API key**
- Gemini: <https://aistudio.google.com/> (enable billing for reliable throughput; reviews cost
  cents - the free tier's daily caps are exhausted by a handful of reviews)
- OpenRouter: <https://openrouter.ai/> (one account covers Gemini, GLM, and hundreds of models)

**2. Add the key(s) as repository Secrets**
Settings > Secrets and variables > Actions > Secrets: `GEMINI_API_KEY` and/or `OPENROUTER_API_KEY`.

**3. Add the caller workflow**
Copy [`examples/scrutineer.yml`](examples/scrutineer.yml) into your repo at
`.github/workflows/scrutineer.yml`. That is the only file you add.

**4. (Optional) Choose your model(s)**
Set the `REVIEWERS` repository Variable (defaults to `gemini`). See the next section.

Open a pull request and you get a review. Comment `@review` any time for a fresh pass.

---

## Choosing your model(s)

Set the `REVIEWERS` repository Variable to a comma-separated list of 1 to 2 slots. Each slot is
either `gemini` (direct Google), `gemini:<model>`, or an **OpenRouter model id**.

| Mode | `REVIEWERS` | Keys needed |
|---|---|---|
| Gemini only | `gemini` *(default)* | `GEMINI_API_KEY` |
| Gemini plus GLM (dual) | `gemini, z-ai/glm-5.2` | both |
| Two models, one account | `google/gemini-2.5-flash, z-ai/glm-5.2` | `OPENROUTER_API_KEY` |
| GLM only | `z-ai/glm-5.2` | `OPENROUTER_API_KEY` |

Two slots means two independent reviews posted on the PR. Each can be any model; different
training lineages catch different issues.

---

## Configuration reference

All are **repository Variables** (Settings > Secrets and variables > Actions > Variables)
unless noted.

| Name | Default | Purpose |
|---|---|---|
| `REVIEWERS` | `gemini` | 1 to 2 reviewer slots (see above) |
| `GEMINI_MODEL` | `gemini-pro-latest` | Model for a bare `gemini` slot. Pro is the default (materially fewer false positives); set `gemini-flash-latest` for lower cost. Use a `*-latest` alias to avoid retired-model errors |
| `OPENROUTER_HOSTS` | *(none)* | Allow-list of host slugs for OpenRouter slots, e.g. `novita,fireworks,together,gmicloud` |
| `OPENROUTER_SORT` | `price` | `price` \| `throughput` \| `latency` - how to pick among eligible hosts. `throughput` is a good choice for slower reasoning models |
| `OPENROUTER_MAXPRICE` | *(none)* | Hard ceiling `"$in,$out"` per 1M tokens, e.g. `"2,6"` |
| `OPENROUTER_ZDR` | `true` | Zero-data-retention hosts only (on by default). Set `false` to allow non-ZDR hosts |
| `CONTEXT_BUDGET` | `600000` | Max characters of full changed-file content sent alongside the diff. Both Gemini and GLM have ~1M-token context, so this is a cost/latency guard rather than a context limit; the default fits every changed file in a normal PR. Raise or lower to taste |
| `GEMINI_API_KEY` | - | **Secret** for direct Gemini slots |
| `OPENROUTER_API_KEY` | - | **Secret** for OpenRouter slots |

By default every OpenRouter request sends `data_collection: "deny"` **and** requires zero data
retention, so hosts neither train on nor retain your code. Set `OPENROUTER_ZDR=false` only if
you need a model whose hosts do not offer ZDR.

---

## Privacy, jurisdiction and cost (OpenRouter models)

OpenRouter can route the same model to many hosts at wildly different prices, quality
(quantization), and jurisdictions. Scrutineer gives you the controls:

- **Guarantee the host / jurisdiction** with `OPENROUTER_HOSTS`. This is an allow-list, the only
  reliable way to bound where your code goes. `OPENROUTER_ZDR=true` does **not** guarantee a
  jurisdiction (a host in any country can be zero-retention); use the allow-list for that.
- **Ensure quality.** For open-weight models, some hosts serve lossy 4-bit (`fp4`)
  quantizations that miss bugs. Curate `OPENROUTER_HOSTS` to reputable `fp8`/full-precision hosts.
- **Control cost.** `OPENROUTER_SORT=price` picks the cheapest eligible host; `OPENROUTER_MAXPRICE`
  hard-caps it. Or `OPENROUTER_SORT=throughput` to prioritise speed.
- **Redundancy.** Requests use `allow_fallbacks` and OpenRouter auto-skips hosts with recent
  errors, so no single host is a point of failure.

**Recommended for GLM 5.2** (reputable, non-Chinese, fp8, cheapest-first with failover):
```
OPENROUTER_HOSTS = novita,fireworks,together,gmicloud
OPENROUTER_SORT  = price
```

> **Data residency note.** For strict compliance (for example EU data residency), prefer the
> direct Gemini slot (Google offers residency controls) over routing via OpenRouter, which adds
> an intermediary.

---

## Cost

Reviews are a single API call each. Rough per-review cost (a medium PR):

| Model | approx per review |
|---|---|
| GLM 5.2 (OpenRouter, cheapest host) | ~1 to 2 cents |
| Gemini Pro (`gemini-pro-latest`, default) | ~5 to 8 cents |
| Gemini Flash (`gemini-flash-latest`) | ~2 to 5 cents |

Sending each changed file's full content adds input tokens, which the figures above already
reflect; input tokens are cheap and the quality gain is large. At typical volume this is still a
few dollars a month at most.

---

## Triggers and commands

By default (see the caller workflow):
- **Automatic** review when a PR is **opened** or **reopened** (runs all configured reviewers).
  **Bot-authored PRs (e.g. Dependabot) are skipped** - a full AI review of a routine dependency
  bump rarely earns its cost, and you can still review one on demand with `@review`. To review bot
  PRs automatically too, drop the `github.event.pull_request.user.type != 'Bot'` clause from the caller.
- **On demand** by commenting on the PR, and you can choose which reviewer(s) run:

  | Comment | Runs |
  |---|---|
  | `@review` / `@review both` / `@review all` | every configured reviewer |
  | `@review gemini` | reviewer(s) whose model id contains "gemini" |
  | `@review glm` | the GLM reviewer |
  | `@review <keyword>` | any reviewer whose model id contains `<keyword>` (e.g. `flash`, `pro`) |

Matching is a case-insensitive substring of the model id; an unrecognised keyword safely falls
back to running all reviewers.

**Who can trigger it:** for security, `@review` comment triggers only run for **repo owners,
members, and collaborators** (the caller checks `author_association`). This stops strangers from
triggering reviews - and spending your API credits or runner minutes - on public repos. The
automatic review on PR open is unaffected.

**No duplicate reviews, always green.** Runs for a single PR are serialised and never cancelled. If
the current commit was already reviewed and nothing new has been said since, a repeat trigger exits
as a successful (green) check instead of posting again. So opening a PR and immediately commenting
`@review` produces one review, not two, and the pipeline reads as a clean success throughout -
while pushing a new commit or posting a substantive reply still triggers a fresh review.

It deliberately does **not** review on every push or comment (that reviews half-finished work
and adds noise). To change this, edit the caller's `on:` triggers: add `synchronize` to review
every push, or use `ready_for_review` to review when a draft PR is marked ready.

---

## Conversation-aware re-reviews

Scrutineer is not stateless. On a re-review it reads the PR's prior review plus your replies and
opens with a **Since last review** section: Resolved, Acknowledged (it accepts a sound reason
not to change something and will not re-raise it), and Still open. Reply to a review, push a
fix, comment `@review`, and it carries the whole thread forward - a real back-and-forth rather
than the same list every round.

---

## Custom review style

Drop a `.review/styleguide.md` file in a repo. Its contents are injected into the review prompt,
so you can enforce team conventions in plain English (for example *"require error handling on
all I/O", "prefer composition over inheritance"*).

---

## Rolling out to many repos

Each repo needs the caller file plus its secret and variables. For personal accounts (which
cannot share secrets across repos), the helper script [`setup.ps1`](setup.ps1) sets the secret,
variables, and caller file for any repo in one command, and opens a PR automatically if the
default branch is protected:

```powershell
# Gemini on some repos, GLM on others:
./setup.ps1 -Repos you/app -Reviewers "gemini"
./setup.ps1 -Repos you/side-project -Reviewers "z-ai/glm-5.2" -OpenRouterHosts "novita,fireworks,together,gmicloud"
```

---

## Staying up to date

Callers pin the major tag `@v1`, which moves forward as non-breaking fixes and improvements land -
so you get them automatically on the next review, with nothing to change in your repos. A breaking
change would ship as a new major tag (`@v2`) that you opt into by bumping the `uses:` ref.

To be notified of new versions, **Watch → Custom → Releases** on this repo, or read the
[CHANGELOG](CHANGELOG.md). If you prefer to pin an exact version for reproducibility, reference a
release tag (for example `@v1.1.0`) or a full commit SHA instead of `@v1`, and let Dependabot
(the `github-actions` ecosystem) open update PRs when a newer version is published.

## Example review

A trimmed example of what Scrutineer posts on a PR:

> ## Review - `gemini-flash-latest`
>
> ### Summary
> Adds a user-search helper and a backup utility. The change works but contains a SQL injection,
> a shell command injection, and two runtime bugs that should be fixed before merge.
>
> ### Findings
>
> **Critical**
> - `src/users.ts:5` - SQL injection: `term` is concatenated into the query. Use a parameterised
>   query: `db.query("SELECT * FROM users WHERE name LIKE ?", ["%" + term + "%"])`.
> - `src/users.ts:15` - Command injection: `userId` is passed to `execSync`. Use `execFileSync`
>   with an argument array and validate `userId` against `/^[a-zA-Z0-9_-]+$/`.
>
> **High**
> - `src/users.ts:7` - Off-by-one: `i <= rows.length` reads `rows[rows.length]` (undefined) and
>   throws. Use `i < rows.length`.
>
> ### Positives
> - Clear typing and a helpful file header comment.

---

## FAQ

**Does my Gemini app subscription (Google One AI Premium) work?** No. That is separate from the
Gemini API. You need an API key from [AI Studio](https://aistudio.google.com/).

**Is my code used to train models, or retained?** By default OpenRouter requests send
`data_collection:"deny"` and require zero data retention (no training, no retention), and
Gemini's paid API does not train on your data. Keep secret-scanning on so diffs never carry
live credentials.

**Reviews are not posting?** Check the Actions run log. Usually it is a missing or expired key,
an empty diff, or a retired model id (use `*-latest` aliases). Note that `@review` comment
triggers only work once the caller workflow is on the repository's default branch.

---

## Notes

This is an independent, from-scratch project and is not affiliated with or endorsed by Google,
Z.ai, OpenRouter, or any model provider. "Gemini", "GLM", "OpenRouter" and other names are
trademarks of their respective owners and are used here only to describe compatibility.

You bring your own API keys and are responsible for the providers' terms of service and any
costs incurred.

## License

MIT - see [LICENSE](LICENSE).
