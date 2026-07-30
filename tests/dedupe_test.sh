#!/usr/bin/env bash
# Tests for review.yml's already_reviewed() de-dupe.
#
# The function is extracted verbatim from the workflow rather than copied here, so the test
# cannot drift from what actually ships. Extraction is plain awk/sed (no YAML parser) to keep
# the runner dependency-free: the function is indented 10 spaces inside the `run:` block.
#
# Usage: tests/dedupe_test.sh     (needs bash + jq)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$HERE/../.github/workflows/review.yml"

SRC="$(awk '/^          already_reviewed\(\) \{$/,/^          \}$/' "$WF" | sed 's/^          //')"
# Guard only that extraction worked at all - deliberately NOT a check for any particular
# implementation detail, so the assertions below are what actually judge the behaviour.
if ! printf '%s' "$SRC" | grep -q 'COMMENTS_JSON'; then
  echo "FAIL: could not extract already_reviewed() from $WF (has the indentation changed?)" >&2
  exit 1
fi
eval "$SRC"

SHA='8a67d205983c6e8a4e82e47911c6b88af859c2fc'
OTHER='1111111111111111111111111111111111111111'
fails=0

# one Bot comment -> COMMENTS_JSON
mk() { jq -n --arg b "$1" '[{user:{type:"Bot"},created_at:"2026-07-30T17:00:00Z",body:$b}]'; }

check() { # description want label comments_json [head_sha]
  local desc="$1" want="$2" label="$3" got
  COMMENTS_JSON="$4"; HEAD_SHA="${5:-$SHA}"
  already_reviewed "$label" && got=yes || got=no
  if [ "$got" = "$want" ]; then
    printf 'ok    %s\n' "$desc"
  else
    printf 'FAIL  %s (got=%s want=%s)\n' "$desc" "$got" "$want"; fails=1
  fi
}

# --- The regression this guards ------------------------------------------------------------
# A reviewer is shown the prior review thread and may quote another reviewer's comment back
# verbatim, hidden marker included. Attribution must be anchored (header = first line, own
# marker = last line), or the quoted reviewer is credited with a review it never ran and is
# silently skipped for that commit.
QUOTER="$(printf '%s\n' \
  '## 🤖 Review - `minimax/minimax-m3 (via OpenRouter)`' '' \
  '## 🤖 Review - `gemini-flash-latest`' '' \
  'Quoted body from the other reviewer.' '' \
  "<!-- scrutineer sha=$SHA lat=12s in=19640 out=372 cost=na -->" '' \
  "<!-- scrutineer sha=$SHA lat=134s in=19301 out=7351 cost=0.0146115 -->")"

check 'quoted header+marker does not credit the quoted reviewer' \
      no 'gemini-flash-latest' "$(mk "$QUOTER")"
check 'the quoting reviewer is still credited for its own review' \
      yes 'minimax/minimax-m3 (via OpenRouter)' "$(mk "$QUOTER")"

# --- Normal behaviour must be preserved -----------------------------------------------------
GENUINE="$(printf '%s\n' '## 🤖 Review - `gemini-flash-latest`' '' 'Body.' '' \
  "<!-- scrutineer sha=$SHA lat=1s in=1 out=1 cost=na host=novita -->")"

check 'genuine review for this commit is de-duped'      yes 'gemini-flash-latest' "$(mk "$GENUINE")"
check 'a review of a different commit is not'           no  'gemini-flash-latest' "$(mk "$GENUINE")" "$OTHER"
check 'trailing blank lines after the marker tolerated' yes 'gemini-flash-latest' \
      "$(mk "$(printf '%s\n\n\n' "$GENUINE")")"
check 'legacy marker without host= still matches'       yes 'gemini-flash-latest' \
      "$(mk "$(printf '%s\n' '## 🤖 Review - `gemini-flash-latest`' '' 'Body.' '' \
              "<!-- scrutineer sha=$SHA lat=1s in=1 out=1 cost=na -->")")"
check 'label with / and () compared literally, not as regex' yes 'minimax/minimax-m3 (via OpenRouter)' \
      "$(mk "$(printf '%s\n' '## 🤖 Review - `minimax/minimax-m3 (via OpenRouter)`' '' 'Body.' '' \
              "<!-- scrutineer sha=$SHA lat=1s -->")")"

# A failed review must NOT count as reviewed, so the slot retries on the next trigger.
check 'failed review is not treated as reviewed' no 'gemini-flash-latest' \
      "$(mk "$(printf '%s\n' '## 🤖 Review - `gemini-flash-latest`' '' \
              '⚠️ Could not generate review.' '' \
              "<!-- scrutineer sha=$SHA lat=300s in=0 out=0 cost=na -->")")"

# Developer activity after the review re-opens it; a bare "@review" does not.
AFTER='[{"user":{"type":"Bot"},"created_at":"2026-07-30T17:00:00Z","body":"BODY"},
        {"user":{"type":"User"},"created_at":"2026-07-30T17:05:00Z","body":"COMMENT"}]'
check 'substantive developer reply re-opens the review' no 'gemini-flash-latest' \
      "$(printf '%s' "$AFTER" | jq --arg b "$GENUINE" '.[0].body=$b | .[1].body="please also check X"')"
check 'a bare @review does not re-open it'              yes 'gemini-flash-latest' \
      "$(printf '%s' "$AFTER" | jq --arg b "$GENUINE" '.[0].body=$b | .[1].body="@review"')"

[ "$fails" -eq 0 ] && echo "All de-dupe tests passed." || echo "Some de-dupe tests FAILED." >&2
exit "$fails"
