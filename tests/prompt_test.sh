#!/usr/bin/env bash
# The reviewer prompt carries the rules that let a review loop end. These are prose, so
# nothing else would notice if an edit dropped one. Each check names the rule it pins.
set -u
WF=".github/workflows/review.yml"
fail=0
has() { grep -qF -- "$1" "$WF" || { echo "FAIL  prompt lost: $2"; fail=1; }; }
has "Do NOT report style" "the no-style rule"
has "**Verdict:** BLOCKING" "the blocking verdict line"
has "**Verdict:** NOT BLOCKING" "the not-blocking verdict line"
has "Do NOT raise an issue that another reviewer already raised" "the cross-reviewer de-duplication rule"
has "raise a new finding only when it is" "the unchanged-code rule for a re-review"
has "its first line names the reviewer" "the honest label on prior reviews"
if grep -qF "### Your previous review" "$WF"; then echo "FAIL  prior reviews are again all labelled as the reader's own"; fail=1; fi
[ "$fail" = 0 ] && echo "All prompt tests passed." || { echo "Some prompt tests FAILED."; exit 1; }
