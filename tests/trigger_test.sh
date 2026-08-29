#!/usr/bin/env bash
# Behavioural test for the @review command rule.
#
# The rule lives in review.yml, NOT in the caller. That placement is the point: it ships via the
# @v1 tag, so tightening it is a release rather than a pull request in every consumer repo. It
# was in the caller once, and moving a single delimiter cost fifteen PRs (see CLAUDE.md).
#
# This extracts the shipped function VERBATIM and drives real comment bodies through it, so the
# test cannot drift from what actually runs - a reimplementation could pass while the workflow
# was broken, which is exactly the gap a reviewer caught in the previous version of this file.
#
# Usage: tests/trigger_test.sh     (needs bash + grep)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
WF="$ROOT/.github/workflows/review.yml"

fails=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=1; }

SRC="$(awk '/^          is_review_command\(\) \{$/,/^          \}$/' "$WF" | sed 's/^          //')"
if [ -n "$SRC" ]; then ok "extracted is_review_command from review.yml"
else bad "no is_review_command in review.yml"; echo "Some trigger tests FAILED." >&2; exit 1; fi
printf '%s\n' "$SRC" | bash -n 2>/dev/null || bad "is_review_command is not valid bash"

# Run the SHIPPED function against a body.
fires() { BODY="$1" bash -c "$SRC"$'\nis_review_command "$BODY"' 2>/dev/null; }

# body | expected | why. Every legitimate invocation, and every collision that has cost a paid
# round. Changing the delimiter set in review.yml means adding a case here.
CASES=(
  "@review|yes|bare command"
  "@Review|yes|case-insensitive, via grep -i"
  "@REVIEW|yes|case-insensitive"
  "@review glm|yes|slot filter argument"
  "@review	glm|yes|tab-separated argument"
  "@review, please look|yes|comma - regressed to a silent no-op once"
  "@review: please look|yes|colon"
  "@review.|yes|sentence-ending period"
  "@review!|yes|exclamation - omitted at first, raised on seven of fifteen rollout PRs"
  "@review?|yes|question mark"
  "@review; ping me|yes|semicolon"
  "@reviewer please look|no|handle collision - the original bug"
  "@reviews are broken|no|handle collision"
  "@reviewership|no|handle collision"
  "@review2|no|digit continuation"
  "@review-bot|no|hyphen continuation"
  "I am not asking for @review|no|mention later in a line is inert"
  "@review is the only command|yes|KNOWN - prose STARTING a line still fires"
  " @review|no|indented is inert - must be flush left"
)

for c in "${CASES[@]}"; do
  body="${c%%|*}"; rest="${c#*|}"; want="${rest%%|*}"; why="${rest#*|}"
  if fires "$body"; then got=yes; else got=no; fi
  if [ "$got" = "$want" ]; then ok "'${body}' -> $got ($why)"
  else bad "'${body}' -> $got, expected $want ($why)"; fi
done

# Multi-line bodies, kept out of the table because | and newlines do not mix in it.
fires "$(printf '@review\r\nplease look')"  && ok "CRLF after the command fires" \
                                            || bad "CRLF after the command does not fire"
fires "$(printf 'thanks all\r\n@review')"   && ok "sign-off on the last line fires" \
                                            || bad "sign-off on the last line does not fire"
fires "$(printf 'thanks\n@review\nta')"     && ok "command on a middle line fires" \
                                            || bad "command on a middle line does not fire"
fires "$(printf 'see @review here\nok')"    && bad "mention mid-line on a wrapped body fires" \
                                            || ok "mention mid-line on a wrapped body is inert"

# Documented limitations, pinned in BOTH directions so they stay deliberate rather than being
# rediscovered as bugs. A fenced block DOES fire - the fence lines are just newlines, and no
# amount of matching can tell a demonstration from an invocation. An indented one does NOT.
fires "$(printf 'like this:\n```\n@review\n```')" && ok "KNOWN - @review in a code fence fires" \
                                            || bad "code-fence behaviour changed - update the docs"
fires "$(printf 'a\n  @review')"            && bad "indented @review fires - it should not" \
                                            || ok "KNOWN - indented @review is inert"

# The de-dupe in already_reviewed() decides what counts as a bare command rather than developer
# activity, and it must carry the same delimiter set. These two have drifted twice, in opposite
# directions - once silently skipping a requested round, once silently spending one.
DEDUPE="$(grep -o 'test("\^@review(\[[^"]*)")' "$WF" | head -1)"
case "$DEDUPE" in
  *'[[:space:],:.!?;]'*) ok "already_reviewed() carries the same delimiter set" ;;
  '')                    bad "could not find the already_reviewed() command test in review.yml" ;;
  *)                     bad "already_reviewed() delimiter set differs from the trigger: $DEDUPE" ;;
esac

[ "$fails" -eq 0 ] && echo "All trigger tests passed." || echo "Some trigger tests FAILED." >&2
exit "$fails"
