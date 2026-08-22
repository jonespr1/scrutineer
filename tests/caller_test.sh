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

# --- Third-party actions must be SHA-pinned ------------------------------------------------------
# ci.yml's header states "Third-party actions are SHA-pinned", but that was only true of ci.yml:
# review.yml and benchmark.yml sat on bare @v4 tags for months without anything noticing. A tag is
# repointable by its owner, so a moving tag on review.yml means a third party can change what all
# 14 consumer repos execute, with no PR and no diff. This asserts the stated policy rather than
# trusting it.
#
# EVERY `uses:` line is matched, then the non-pinnable forms are exempted by name. An earlier
# version matched only `uses: owner/...`, which silently skipped `uses: docker://image:tag` - a
# reference with no SHA to check would have sailed through unexamined rather than failing. Matching
# everything and subtracting is the safer direction: a form nobody anticipated fails loudly.
#
# Exemptions, each deliberate:
#   jonespr1/scrutineer/...@v1  the moving major alias IS the distribution mechanism here; pinning
#                               it to a SHA is the exact failure the estate's Dependabot ignore
#                               rules exist to prevent.
#   ./path                      local references have no version to pin.
#   docker://image:tag          not a git ref - pinned by image digest, a separate concern.
#   {{REF}}                     setup.ps1's template placeholder, substituted at write time with
#                               the alias above.
#   commented-out lines         never executed, so never a supply-chain risk. Detected by a `#`
#                               BEFORE the `uses:`, so trailing `# v7.0.1` version comments (which
#                               are the whole point of a readable SHA pin) still scan normally.
#
# Scope is every caller surface this repo ships - .github/workflows/, examples/, and setup.ps1 -
# so the pass message below can be read literally.
unpinned=0 scanned=0 saw_review=0
while IFS= read -r line; do
  file="${line%%:*}"; rest="${line#*:}"; lineno="${rest%%:*}"; ref="${rest#*:}"

  # A `#` anywhere ahead of the `uses:` keyword means the line is commented out.
  case "${ref%%uses:*}" in *"#"*) continue ;; esac

  # Isolate the ref itself: strip through `uses:`, trim, drop surrounding quotes, and stop at the
  # first quote/space so a trailing version comment is not mistaken for part of the SHA.
  target="${ref#*uses:}"
  target="${target#"${target%%[![:space:]]*}"}"
  target="${target#[\'\"]}"
  target="${target%%[\'\" ]*}"
  [ -n "$target" ] || continue

  case "$target" in
    "jonespr1/scrutineer/.github/workflows/"*) continue ;;
    ./*|docker://*|*"{{REF}}"*)                continue ;;
  esac

  scanned=$((scanned + 1))
  case "$file" in *review.yml) saw_review=1 ;; esac

  sha="${target##*@}"
  if ! printf '%s' "$sha" | grep -qE '^[0-9a-f]{40}$'; then
    printf 'FAIL  %s:%s is not SHA-pinned (@%s)\n' "$file" "$lineno" "$sha"; unpinned=1; fails=1
  fi
done < <(grep -rn "uses:" "$ROOT/.github/workflows/" "$ROOT/examples/" "$ROOT/setup.ps1" 2>/dev/null \
         | sed "s|^$ROOT/||")

# Without this, a scan that matched nothing - renamed directory, moved workflows, a broken grep -
# would report a clean pass. review.yml is named specifically because it is the file the whole
# estate executes: if the check ever stops covering it, that must be a failure, not a silent green.
if [ "$scanned" -eq 0 ] || [ "$saw_review" -eq 0 ]; then
  bad "SHA-pin scan covered no review.yml refs (scanned=$scanned) - the check is not running"
elif [ "$unpinned" -eq 0 ]; then
  ok "every action ref in .github/workflows/, examples/ and setup.ps1 is SHA-pinned ($scanned checked)"
fi

[ "$fails" -eq 0 ] && echo "All caller tests passed." || echo "Some caller tests FAILED." >&2
exit "$fails"
