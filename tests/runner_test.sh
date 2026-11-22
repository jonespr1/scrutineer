#!/usr/bin/env bash
# Guards where the review job runs.
#
# review.yml takes its runner from the CALLER's repository variable CI_RUNNER, falling back to
# GitHub-hosted ubuntu-latest. Two regressions matter:
#   1. The fallback goes missing. Every consumer that has not set CI_RUNNER would then get an
#      empty runs-on and the job would never start - a review that silently never runs.
#   2. This public repo's own workflows start reading CI_RUNNER. Setting it here would put fork
#      pull requests on a private machine; nothing in this repo should ever offer that switch.
#
# Usage: tests/runner_test.sh     (needs bash only)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
REVIEW="$ROOT/.github/workflows/review.yml"

fails=0
ok()   { printf 'ok    %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fails=1; }

# The review job's runs-on line: the first runs-on after the "  review:" job key.
line=$(awk '/^  review:$/ {injob=1} injob && /^ *runs-on:/ {print; exit}' "$REVIEW")

if [ -z "$line" ]; then
  bad "review.yml: no runs-on found for the review job"
else
  case "$line" in
    *"vars.CI_RUNNER || 'ubuntu-latest'"*) ok "review.yml: runs-on reads CI_RUNNER with the ubuntu-latest fallback" ;;
    *) bad "review.yml: runs-on is not \"\${{ vars.CI_RUNNER || 'ubuntu-latest' }}\" - got: $line" ;;
  esac
fi

# This repo's own workflows (everything except the reusable review.yml) must not read it.
for f in "$ROOT"/.github/workflows/*.yml; do
  n="${f#"$ROOT/"}"
  [ "$f" = "$REVIEW" ] && continue
  if grep -q 'CI_RUNNER' "$f"; then
    bad "$n: reads CI_RUNNER - this public repo's own jobs must stay on GitHub-hosted runners"
  else
    ok "$n: does not read CI_RUNNER"
  fi
done

exit "$fails"
