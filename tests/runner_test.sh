#!/usr/bin/env bash
# Guards where the review job runs.
#
# review.yml takes its runner from the CALLER's repository variable CI_RUNNER, but only when the
# caller repo is private, falling back to GitHub-hosted ubuntu-latest. Regressions that matter:
#   1. The fallback goes missing. Every consumer that has not set CI_RUNNER would then get an
#      empty runs-on and the job would never start - a review that silently never runs.
#   2. The private-repo condition goes missing. A public caller that set CI_RUNNER would then put
#      fork pull requests on a private machine.
#   3. The tool preflight goes missing. On a runner without jq the de-dupe fails silently and
#      every "@review" on an unchanged commit spends a paid round.
#   4. Something else in this public repo starts reading CI_RUNNER: its own workflows, the caller
#      template, or setup.ps1. Nothing here but review.yml should offer that switch.
#
# Usage: tests/runner_test.sh     (needs bash only)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
REVIEW="$ROOT/.github/workflows/review.yml"
EXPECTED="(github.event.repository.private && vars.CI_RUNNER) || 'ubuntu-latest'"

fails=0
ok()   { printf 'ok    %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fails=1; }

# 1 and 2. The review job's runs-on line: the first runs-on after the "  review:" job key.
line=$(awk '/^  review:$/ {injob=1} injob && /^ *runs-on:/ {print; exit}' "$REVIEW")
if [ -z "$line" ]; then
  bad "review.yml: no runs-on found for the review job"
elif [[ "$line" == *"$EXPECTED"* ]]; then
  ok "review.yml: runs-on reads CI_RUNNER on private callers only, with the ubuntu-latest fallback"
else
  bad "review.yml: runs-on does not contain: $EXPECTED - got: $line"
fi

# 3. The preflight must check every tool whose absence fails silently or confusingly.
for tool in gh jq curl; do
  if grep -qE "^ *for tool in .*\\b${tool}\\b" "$REVIEW"; then
    ok "review.yml: preflight checks for $tool"
  else
    bad "review.yml: no preflight check for $tool"
  fi
done

# 4. Nothing else in this repo may read it.
shopt -s nullglob
for f in "$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml "$ROOT"/examples/* "$ROOT/setup.ps1"; do
  n="${f#"$ROOT/"}"
  [ "$f" = "$REVIEW" ] && continue
  if grep -q 'CI_RUNNER' "$f"; then
    bad "$n: mentions CI_RUNNER - nothing in this public repo but review.yml may offer the switch"
  else
    ok "$n: does not mention CI_RUNNER"
  fi
done

exit "$fails"
