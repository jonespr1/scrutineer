#!/usr/bin/env bash
# Behavioural test for the @review trigger.
#
# tests/caller_test.sh asserts the ten delimiter PATTERNS are present in each caller. That
# catches a dropped alternative, but not a typo INSIDE one: `format('{0}@rewiew ', ...)` still
# looks like a pattern and still counts. Only a real Actions run would catch that - or this,
# which recovers the delimiter set from the shipped expression and then drives real comment
# bodies through the same matching rule GitHub applies.
#
# The rule, mirrored from the caller: the body is wrapped in newlines, so "@review starts a
# line" becomes a plain substring test for "\n@review<delimiter>". GitHub's contains() is
# case-insensitive, so both sides are lowercased here.
#
# Usage: tests/trigger_test.sh     (needs bash only)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
FILES=(
  "$ROOT/.github/workflows/scrutineer.yml"
  "$ROOT/examples/scrutineer.yml"
  "$ROOT/setup.ps1"
)

fails=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=1; }

# Recover the delimiter set from the file rather than hardcoding it, so a typo inside a
# format(...) call changes what this test runs and the truth table below fails loudly.
recover_delims() {
  local f="$1" line tok
  DELIMS=()
  while IFS= read -r line; do
    tok="$(printf '%s' "$line" | sed -E "s/.*@review([^']*)'.*/\1/")"
    case "$tok" in
      '{0}') DELIMS+=($'\n') ;;                       # the padding newline itself
      '{1}')                                          # second placeholder: CR or tab
        case "$line" in
          *'"\r"'*) DELIMS+=($'\r') ;;
          *'"\t"'*) DELIMS+=($'\t') ;;
          *'" "'*)   DELIMS+=(' ') ;;
          *)        bad "unrecognised {1} placeholder: $line" ;;
        esac ;;
      ?) DELIMS+=("$tok") ;;                          # a single literal char: , : . ! ? ;
      *) bad "unrecognised delimiter token '$tok'" ;;
    esac
  done < <(grep -F 'contains(format' "$f" | grep -F '@review')
}

# The caller's rule, applied to a real comment body.
fires() {
  local pad d
  pad=$'\n'"${1,,}"$'\n'
  for d in "${DELIMS[@]}"; do
    case "$pad" in *$'\n'"@review$d"*) return 0 ;; esac
  done
  return 1
}

# body <TAB> expected. Every legitimate invocation, and every collision that used to cost a
# paid round. Adding a delimiter to the caller means adding a case here.
CASES=(
  "@review|yes|bare command"
  "@Review|yes|case-insensitive"
  "@review glm|yes|slot filter argument"
  "@review	glm|yes|tab-separated argument"
  "@review, please look|yes|comma - regressed to a silent no-op once"
  "@review: please look|yes|colon"
  "@review.|yes|sentence-ending period"
  "@review!|yes|exclamation - added after seven reviewers flagged the omission"
  "@review?|yes|question mark"
  "@review; ping me|yes|semicolon"
  "@reviewer please look|no|handle collision - the original bug"
  "@reviews are broken|no|handle collision"
  "@reviewership|no|handle collision"
  "@review2|no|digit continuation"
  "@review-bot|no|hyphen continuation"
  "I am not asking for @review|no|inline prose mention"
  "@review is the only command|yes|KNOWN - prose starting a line still fires"
  " @review|no|leading space is documented as inert"
)

for f in "${FILES[@]}"; do
  n="${f#"$ROOT/"}"
  [ -f "$f" ] || { bad "$n: missing"; continue; }

  recover_delims "$f"
  if [ "${#DELIMS[@]}" -eq 10 ]; then
    ok "$n: recovered 10 delimiters from the shipped expression"
  else
    bad "$n: recovered ${#DELIMS[@]} delimiters, expected 10 - the trigger changed shape"
    continue
  fi

  for c in "${CASES[@]}"; do
    body="${c%%|*}"; rest="${c#*|}"; want="${rest%%|*}"; why="${rest#*|}"
    if fires "$body"; then got=yes; else got=no; fi
    if [ "$got" = "$want" ]; then
      ok "$n: '${body}' -> $got ($why)"
    else
      bad "$n: '${body}' -> $got, expected $want ($why)"
    fi
  done

  # Multi-line bodies, kept out of the table because | and newlines do not mix in it.
  fires "$(printf '@review\r\nplease look')"  && ok "$n: CRLF after the command fires" \
                                              || bad "$n: CRLF after the command does not fire"
  fires "$(printf 'thanks all\r\n@review')"   && ok "$n: sign-off on the last line fires" \
                                              || bad "$n: sign-off on the last line does not fire"
  fires "$(printf 'thanks\n@review\nta')"     && ok "$n: command on a middle line fires" \
                                              || bad "$n: command on a middle line does not fire"
  fires "$(printf 'see @review here\nok')"    && bad "$n: inline mention on a wrapped line fires" \
                                              || ok "$n: inline mention on a wrapped line is inert"

  # Documented limitations, pinned so they are deliberate rather than forgotten. A fenced code
  # block DOES fire: the fence lines are just newlines, so a comment demonstrating the command
  # spends a round. There is no way to strip fences in a GitHub expression. Indented @review
  # does NOT fire - it must be flush left.
  fires "$(printf 'like this:\n```\n@review\n```')" && ok "$n: KNOWN - @review in a code fence fires" \
                                              || bad "$n: code-fence behaviour changed - update the docs"
  fires "$(printf 'a\n  @review')"            && bad "$n: indented @review fires - it should not" \
                                              || ok "$n: KNOWN - indented @review is inert"
done

[ "$fails" -eq 0 ] && echo "All trigger tests passed." || echo "Some trigger tests FAILED." >&2
exit "$fails"
