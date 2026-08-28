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

# The range ends at the first line that is exactly 10 spaces + "}". If a future refactor puts
# another such line INSIDE the function, the extract truncates - and the guards below turn that
# into a loud "bad extraction" error rather than a silent wrong answer. That is the intended
# behaviour: don't "fix" it by loosening the guards.
SRC="$(awk '/^          already_reviewed\(\) \{$/,/^          \}$/' "$WF" | sed 's/^          //')"
# Validate the extraction itself, so a broken extract reports as a broken extract rather than
# as ten confusing assertion failures. These check that we got a WHOLE, parseable function -
# deliberately not that it is implemented any particular way, so the assertions below remain
# what actually judges the behaviour.
extract_failed() { echo "FAIL: bad extraction of already_reviewed() from $WF - $1" >&2; exit 1; }
[ -n "$SRC" ]                                      || extract_failed "nothing matched (indentation changed?)"
printf '%s' "$SRC" | grep -q 'COMMENTS_JSON'       || extract_failed "no COMMENTS_JSON reference"
[ "$(printf '%s' "$SRC" | tail -n1)" = '}' ]       || extract_failed "does not end at the closing brace (truncated?)"
printf '%s\n' "$SRC" | bash -n 2>/dev/null         || extract_failed "extracted text is not valid bash (truncated?)"
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

# A null body anywhere in the thread must not abort the filter. jq errors on null for both
# split and contains, and because the jq failure is swallowed the slot would otherwise
# re-review on every run.
check 'null comment body does not break the filter' yes 'gemini-flash-latest' \
      "$(jq -n --arg g "$GENUINE" '[{user:{type:"Bot"},created_at:"2026-07-30T16:00:00Z",body:null},
                                    {user:{type:"User"},created_at:"2026-07-30T16:30:00Z",body:null},
                                    {user:{type:"Bot"},created_at:"2026-07-30T17:00:00Z",body:$g}]')"

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
check '@review with a slot filter does not re-open it'  yes 'gemini-flash-latest' \
      "$(printf '%s' "$AFTER" | jq --arg b "$GENUINE" '.[0].body=$b | .[1].body="@review glm"')"
check '@review, ... is a trigger, not activity'         yes 'gemini-flash-latest' \
      "$(printf '%s' "$AFTER" | jq --arg b "$GENUINE" '.[0].body=$b | .[1].body="@review, please look again"')"
check '@review: ... is a trigger, not activity'         yes 'gemini-flash-latest' \
      "$(printf '%s' "$AFTER" | jq --arg b "$GENUINE" '.[0].body=$b | .[1].body="@review: please look again"')"
check '@review. is a trigger, not activity'             yes 'gemini-flash-latest' \
      "$(printf '%s' "$AFTER" | jq --arg b "$GENUINE" '.[0].body=$b | .[1].body="@review."')"
check '@review! is a trigger, not activity'             yes 'gemini-flash-latest' \
      "$(printf '%s' "$AFTER" | jq --arg b "$GENUINE" '.[0].body=$b | .[1].body="@review!"')"
check '@review? is a trigger, not activity'             yes 'gemini-flash-latest' \
      "$(printf '%s' "$AFTER" | jq --arg b "$GENUINE" '.[0].body=$b | .[1].body="@review?"')"
check '@review; is a trigger, not activity'             yes 'gemini-flash-latest' \
      "$(printf '%s' "$AFTER" | jq --arg b "$GENUINE" '.[0].body=$b | .[1].body="@review; focus on auth"')"
# A reply that merely STARTS with the word "@reviewer" is substantive developer activity, not a
# trigger. startswith("@review") swallowed it, so the round the developer then asked for was
# skipped as "already reviewed" and their counter-argument never reached the model.
check '@reviewer... reply re-opens the review'          no  'gemini-flash-latest' \
      "$(printf '%s' "$AFTER" | jq --arg b "$GENUINE" '.[0].body=$b | .[1].body="@reviewer'"'"'s timeout point is wrong, I fixed X"')"
check '@reviews... reply re-opens the review'           no  'gemini-flash-latest' \
      "$(printf '%s' "$AFTER" | jq --arg b "$GENUINE" '.[0].body=$b | .[1].body="@reviews of this keep missing the point"')"

[ "$fails" -eq 0 ] && echo "All de-dupe tests passed." || echo "Some de-dupe tests FAILED." >&2
exit "$fails"
