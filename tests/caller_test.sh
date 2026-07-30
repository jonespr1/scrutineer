#!/usr/bin/env bash
# Guards the three caller surfaces that the bash suites cannot otherwise reach.
#
# tests/dedupe_test.sh and tests/routing_test.sh extract functions from review.yml, but the
# @review trigger and the permission grants live in the CALLER files - the in-repo dogfood
# caller, the copy-paste example, and the template setup.ps1 writes into every onboarded repo.
# Those three must stay in step, and the most likely regression is someone "simplifying" the
# trigger back to a bare contains(), which is what fired a spurious paid review round.
#
# Usage: tests/caller_test.sh     (needs bash only)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
FILES=(
  "$ROOT/.github/workflows/scrutineer.yml"
  "$ROOT/examples/scrutineer.yml"
  "$ROOT/setup.ps1"
)

fails=0
ok()   { printf 'ok    %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fails=1; }

for f in "${FILES[@]}"; do
  n="${f#"$ROOT/"}"
  [ -f "$f" ] || { bad "$n: missing"; continue; }

  # 1. The trigger must be anchored. A bare contains(body, '@review') fires on any comment that
  #    merely mentions @review in prose - including one saying it is NOT requesting a review.
  #    -F: match the parens literally, not as a regex group - a reformat (extra whitespace inside
  #    the call) would otherwise still satisfy a regex pattern and silently stop guarding anything.
  if grep -qF "startsWith(github.event.comment.body, '@review')" "$f"; then
    ok "$n: trigger anchored with startsWith"
  else
    bad "$n: trigger is not anchored - a bare contains() fires on prose mentions"
  fi

  # 2. ...and must also match @review at the start of any LINE, so signing off a long reply with
  #    @review on its own line still works. Without this the anchoring above breaks normal use.
  #    Pinned to the current format(...)+fromJson('"\n"') implementation rather than the weaker
  #    "contains a newline+@review somewhere" behaviour, deliberately: if this is ever rewritten
  #    (e.g. a plain contains(body, '\n@review')), update this pattern in the same commit so the
  #    test keeps testing what actually ships, not a stale implementation detail.
  if grep -qF "format('{0}@review'" "$f"; then
    ok "$n: also matches @review at line start"
  else
    bad "$n: missing the line-start alternative - sign-off on its own line would not trigger"
  fi

  # 3. The naked form must not reappear alongside them. -E + \s* so a spacing variant (no space
  #    after the comma) can't slip past an exact-string match.
  if grep -qE "contains\(github\.event\.comment\.body,\s*'@review'\)" "$f"; then
    bad "$n: still contains the unanchored contains(body, '@review') form"
  else
    ok "$n: no unanchored trigger form"
  fi

  # 4. The caller is the single least-privilege control point: review.yml declares NO permissions
  #    and inherits these. Losing a grant here silently degrades or breaks the review.
  #    Matches the current single-quoted YAML style (contents: 'read'). A reformat to unquoted
  #    or double-quoted values is a deliberate change - update these strings in the same commit
  #    rather than loosening the match (same trade-off as the other pinned-string checks above).
  for scope in "contents: 'read'" "issues: 'write'" "pull-requests: 'write'"; do
    grep -qF "$scope" "$f" && ok "$n: grants $scope" || bad "$n: missing grant $scope"
  done
done

# review.yml must NOT declare job permissions - doing so caps them at what it asks for and any
# scope added there fails every existing caller at startup (the outage that #15 fixed).
# The awk range assumes the review job is indented 2 spaces and its steps: key 4 - true today;
# if the file is ever reformatted, update the pattern here rather than loosen what it checks for.
RV="$ROOT/.github/workflows/review.yml"
if [ ! -f "$RV" ]; then
  bad "review.yml: missing at $RV"
elif awk '/^  review:/,/^    steps:/' "$RV" | grep -q '^    permissions:'; then
  bad "review.yml: declares job permissions - this breaks callers that grant less (see #15)"
else
  ok "review.yml: declares no job permissions (inherits the caller's)"
fi

[ "$fails" -eq 0 ] && echo "All caller tests passed." || echo "Some caller tests FAILED." >&2
exit "$fails"
