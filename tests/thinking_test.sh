#!/usr/bin/env bash
# Tests for the GEMINI_THINKING reasoning budget built by review.yml's call_gemini().
#
# Same approach as tests/routing_test.sh: the function is extracted verbatim from the workflow
# rather than copied, so the test cannot drift from what ships. curl is stubbed, so nothing leaves
# the machine and no API key is needed; we assert on the JSON request body that WOULD be sent.
#
# Why this file exists: GEMINI_THINKING has several distinct branches - end-trimming, the
# off/none/any sentinels, the integer check, and the jq guard that keeps the filter total - and each
# one silently disables reasoning when it misfires. A regression there is invisible except as a
# quietly cheaper, quietly worse review, which is precisely the kind of failure nobody notices.
#
# Usage: tests/thinking_test.sh     (needs bash + jq)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$HERE/../.github/workflows/review.yml"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- Extract call_gemini() ----------------------------------------------------------------------
SRC="$(awk '/^          call_gemini\(\) \{$/,/^          \}$/' "$WF" | sed 's/^          //')"
bad() { echo "FAIL: bad extraction of call_gemini() from $WF - $1" >&2; exit 1; }
[ -n "$SRC" ]                                        || bad "nothing matched (indentation changed?)"
printf '%s' "$SRC" | grep -q 'generativelanguage'    || bad "no Gemini endpoint reference"
printf '%s' "$SRC" | grep -q 'GEMINI_THINKING'       || bad "no GEMINI_THINKING handling"
[ "$(printf '%s' "$SRC" | tail -n1)" = '}' ]         || bad "does not end at the closing brace"
printf '%s\n' "$SRC" | bash -n 2>/dev/null           || bad "extracted text is not valid bash"

# --- Harness ------------------------------------------------------------------------------------
capture() { # [GEMINI_THINKING value, or omit for unset] -> request JSON on stdout
  local req="$TMP/req.json"; rm -f "$req"
  local -a envs=()
  [ "$#" -gt 0 ] && envs=("GEMINI_THINKING=$1")
  env "${envs[@]+"${envs[@]}"}" bash -c '
    PROMPT="review this"; GEMINI_API_KEY="test-key"; SLOT_META=""
    curl() { cat > "'"$req"'"; printf "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"ok\"}]}}]}\n__HTTP__200"; }
    '"$SRC"'
    call_gemini "gemini-flash-latest" >/dev/null 2>&1
  ' >/dev/null 2>&1
  [ -s "$req" ] || { echo '{}'; return; }
  cat "$req"
}

fails=0
check() { # description  jq_filter  expected  [GEMINI_THINKING value]
  local desc="$1" filter="$2" want="$3"; shift 3
  local got; got="$(capture "$@" | jq -c "$filter" 2>/dev/null)"
  if [ "$got" = "$want" ]; then
    printf 'ok    %s\n' "$desc"
  else
    printf 'FAIL  %s\n        filter=%s\n        got=%s\n        want=%s\n' "$desc" "$filter" "$got" "$want"; fails=1
  fi
}

# --- Off by default -------------------------------------------------------------------------------
# The whole estate inherits this workflow. An unset variable must produce the byte-for-byte request
# that shipped before the feature existed - no generationConfig key at all, not an empty one.
check 'unset sends no generationConfig'   '.generationConfig'  'null'
check 'unset still sends the prompt'      '.contents[0].parts[0].text' '"review this"'
check 'empty string sends none'           '.generationConfig'  'null' ''

# --- Sentinels ------------------------------------------------------------------------------------
for word in off none any; do
  check "\"$word\" sends no generationConfig" '.generationConfig' 'null' "$word"
done

# --- Valid budgets --------------------------------------------------------------------------------
check 'dynamic (-1) is passed through'    '.generationConfig.thinkingConfig.thinkingBudget' '-1'   '-1'
check 'an explicit budget is passed'      '.generationConfig.thinkingConfig.thinkingBudget' '1024' '1024'
# 0 is NOT a sentinel: it sends an explicit "disable thinking" budget, which is a different request
# from sending no thinkingConfig. Documented in the header; asserted here so it stays deliberate.
check '0 sends an explicit zero budget'   '.generationConfig.thinkingConfig.thinkingBudget' '0'    '0'

# --- Trimming -------------------------------------------------------------------------------------
check 'surrounding whitespace is trimmed' '.generationConfig.thinkingConfig.thinkingBudget' '2048' '  2048  '
# Trimming the ENDS only. Stripping all whitespace would turn "1 2" into 12 - a value the caller
# never wrote - so an internally-spaced value must be rejected, not silently repaired.
check 'internal whitespace is rejected'   '.generationConfig' 'null' '1 2'

# --- Malformed falls back to off, never fails open ------------------------------------------------
# Each of these previously risked aborting jq (tonumber on a non-number), which would have produced
# an EMPTY request body rather than a review.
for v in high HIGH 1.5 -- - -abc abc +5 5- 1e3; do
  check "malformed '$v' falls back to off" '.generationConfig' 'null' "$v"
done

# --- The request stays valid whatever the input ----------------------------------------------------
# The point of the regex guard: the filter must be TOTAL. A request missing its contents is the
# failure mode that would be hardest to diagnose from a PR comment.
for v in '' -1 0 high 1.5 -abc '  512  '; do
  check "prompt survives input '$v'" '.contents[0].parts[0].text' '"review this"' "$v"
done

[ "$fails" -eq 0 ] && echo "All thinking tests passed." || echo "Some thinking tests FAILED." >&2
exit "$fails"
