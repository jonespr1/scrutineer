#!/usr/bin/env bash
# Tests for the OpenRouter routing/provider block built by review.yml's call_openrouter().
#
# Like tests/dedupe_test.sh, the function is extracted verbatim from the workflow rather than
# copied, so the test cannot drift from what ships. curl is stubbed, so nothing leaves the
# machine and no API key is needed; we assert on the JSON request body that WOULD be sent.
#
# Usage: tests/routing_test.sh     (needs bash + jq + python3)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$HERE/../.github/workflows/review.yml"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- Extract call_openrouter() ---------------------------------------------------------------
# The `run:` block is indented 10 spaces; the function ends at the first line that is exactly
# 10 spaces + "}". The guards below make a truncated or mis-indented extract fail loudly rather
# than silently testing the wrong thing (see tests/dedupe_test.sh for the same rationale).
SRC="$(awk '/^          call_openrouter\(\) \{$/,/^          \}$/' "$WF" | sed 's/^          //')"
bad() { echo "FAIL: bad extraction of call_openrouter() from $WF - $1" >&2; exit 1; }
[ -n "$SRC" ]                                  || bad "nothing matched (indentation changed?)"
printf '%s' "$SRC" | grep -q 'openrouter.ai'   || bad "no openrouter.ai reference"
[ "$(printf '%s' "$SRC" | tail -n1)" = '}' ]   || bad "does not end at the closing brace (truncated?)"
printf '%s\n' "$SRC" | bash -n 2>/dev/null     || bad "extracted text is not valid bash (truncated?)"

# --- Harness ----------------------------------------------------------------------------------
# Run call_openrouter in a subshell with curl stubbed, and emit the request body it built.
capture() { # env assignments passed as VAR=VAL ... -> request JSON on stdout
  local req="$TMP/req.json"; rm -f "$req"
  env "$@" bash -c '
    PROMPT="review this"; OPENROUTER_API_KEY="test-key"; SLOT_META=""
    curl() { cat > "'"$req"'"; printf "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}\n__HTTP__200"; }
    '"$SRC"'
    call_openrouter "minimax/minimax-m3" >/dev/null 2>&1
  ' >/dev/null 2>&1
  [ -s "$req" ] || { echo '{}'; return; }
  cat "$req"
}

fails=0
check() { # description  jq_filter  expected  [env assignments...]
  local desc="$1" filter="$2" want="$3"; shift 3
  local got; got="$(capture "$@" | jq -c "$filter" 2>/dev/null)"
  if [ "$got" = "$want" ]; then
    printf 'ok    %s\n' "$desc"
  else
    printf 'FAIL  %s\n        filter=%s\n        got=%s\n        want=%s\n' "$desc" "$filter" "$got" "$want"; fails=1
  fi
}

# --- Privacy posture is unconditional ----------------------------------------------------------
# These do not come from any host list, which is the whole argument for dropping the allow-list.
check 'data_collection is always deny'  '.provider.data_collection' '"deny"'
check 'zdr on by default'               '.provider.zdr'             'true'
check 'zdr can be disabled explicitly'  '.provider.zdr'             'null' OPENROUTER_ZDR=false

# --- Host allow-list / deny-list ----------------------------------------------------------------
check 'no allow-list by default'            '.provider.only'   'null'
check 'no deny-list by default'             '.provider.ignore' 'null'
check 'OPENROUTER_HOSTS sets only'          '.provider.only'   '["together","gmicloud"]' OPENROUTER_HOSTS='together,gmicloud'
check 'OPENROUTER_HOSTS trims whitespace'   '.provider.only'   '["together","gmicloud"]' OPENROUTER_HOSTS=' together , gmicloud '
check 'HOSTS=any means no allow-list'       '.provider.only'   'null'                    OPENROUTER_HOSTS=any
check 'OPENROUTER_IGNORE sets ignore'       '.provider.ignore' '["deepinfra","venice"]'  OPENROUTER_IGNORE='deepinfra,venice'
check 'OPENROUTER_IGNORE trims whitespace'  '.provider.ignore' '["deepinfra","venice"]'  OPENROUTER_IGNORE=' deepinfra , venice '
check 'allow-list and deny-list coexist'    '[.provider.only,.provider.ignore]' '[["together"],["venice"]]' OPENROUTER_HOSTS=together OPENROUTER_IGNORE=venice

# --- Output ceiling ------------------------------------------------------------------------------
# Latency is ~output_tokens/host_throughput, so this is the guard against timeouts. A malformed
# value must fall back to the default, never fail open (no cap).
check 'max_tokens defaults to 32000'   '.max_tokens' '32000'
check 'explicit value honoured'        '.max_tokens' '500'   OPENROUTER_MAXTOKENS=500
check 'whitespace tolerated'           '.max_tokens' '8000'  OPENROUTER_MAXTOKENS=' 8000 '
check 'none removes the cap'           '.max_tokens' 'null'  OPENROUTER_MAXTOKENS=none
check 'zero rejected (empty response)' '.max_tokens' '32000' OPENROUTER_MAXTOKENS=0
check 'negative rejected'              '.max_tokens' '32000' OPENROUTER_MAXTOKENS=-5
check 'non-numeric rejected'           '.max_tokens' '32000' OPENROUTER_MAXTOKENS=12k
check 'leading zeros normalised to base 10' '.max_tokens' '500'   OPENROUTER_MAXTOKENS=0500

# --- Price ceiling --------------------------------------------------------------------------------
check 'max_price defaults to 3,10'     '.provider.max_price' '{"prompt":3,"completion":10}'
check 'single value applies to both'   '.provider.max_price' '{"prompt":4,"completion":4}' OPENROUTER_MAXPRICE=4
check 'none removes the ceiling'       '.provider.max_price' 'null'                        OPENROUTER_MAXPRICE=none
check 'malformed falls back, not open' '.provider.max_price' '{"prompt":3,"completion":10}' OPENROUTER_MAXPRICE='2.'

# --- Sort -----------------------------------------------------------------------------------------
check 'sort defaults to throughput'    '.provider.sort' '"throughput"'
check 'sort is overridable'            '.provider.sort' '"price"' OPENROUTER_SORT=price

# --- Response handling: reasoning leakage and truncation -------------------------------------------
# A different axis from everything above: these assert on what call_openrouter RETURNS for a given
# response, not on the request it builds. Both behaviours were found in production on scrutineer#23,
# where minimax-m3 posted its chain-of-thought into the PR and then got cut off mid-sentence while
# still looking like a finished review.
respond() { # response_json -> the text call_openrouter returns
  STUB_BODY="$1" bash -c '
    PROMPT="review this"; OPENROUTER_API_KEY="test-key"; SLOT_META=""
    curl() { cat >/dev/null; printf "%s\n__HTTP__200" "$STUB_BODY"; }
    '"$SRC"'
    call_openrouter "minimax/minimax-m3" 2>/dev/null
  ' 2>/dev/null
}
has() { # description  response_json  substring_that_must_appear
  local desc="$1" body="$2" want="$3" got
  got="$(respond "$body")"
  case "$got" in *"$want"*) printf 'ok    %s\n' "$desc" ;;
    *) printf 'FAIL  %s\n        want substring=%s\n        got=%s\n' "$desc" "$want" "$got"; fails=1 ;;
  esac
}
hasnot() { # description  response_json  substring_that_must_NOT_appear
  local desc="$1" body="$2" bad="$3" got
  got="$(respond "$body")"
  case "$got" in *"$bad"*) printf 'FAIL  %s\n        unwanted substring=%s\n        got=%s\n' "$desc" "$bad" "$got"; fails=1 ;;
    *) printf 'ok    %s\n' "$desc" ;;
  esac
}

THINK='{"choices":[{"finish_reason":"stop","message":{"content":"<mm:think>Let me analyze this carefully. Hmm.</mm:think>## Summary\nthe real review"}}]}'
has    'leading think block: review survives'      "$THINK" 'the real review'
hasnot 'leading think block: reasoning stripped'   "$THINK" 'Let me analyze'

# Cut off mid-thought: there is no review under the reasoning, so posting the reasoning would be
# worse than reporting the failure.
UNCLOSED='{"choices":[{"finish_reason":"length","message":{"content":"<mm:think>Let me analyze this carefully and at great"}}]}'
has    'unclosed think block: reports the limit'   "$UNCLOSED" 'finish_reason=length'
hasnot 'unclosed think block: no reasoning posted' "$UNCLOSED" 'Let me analyze'

# A review that merely QUOTES a think tag (e.g. one reviewing this very code) must be left alone -
# stripping to the last closing tag unconditionally would eat the review above it.
QUOTED='{"choices":[{"finish_reason":"stop","message":{"content":"## Summary\nStrip `<mm:think>` blocks like </mm:think> here.\nkeep this line"}}]}'
has    'quoted think tag mid-body is not stripped' "$QUOTED" 'keep this line'
has    'quoted think tag keeps preceding text'     "$QUOTED" '## Summary'

# Truncated but non-empty: the partial review is kept AND flagged. Before this, finish_reason was
# only consulted when content was empty, so this posted looking complete.
CUT='{"choices":[{"finish_reason":"length","message":{"content":"## Findings\nfound one bug so f"}}]}'
has    'truncated review is kept'                  "$CUT" 'found one bug so f'
has    'truncated review is flagged'               "$CUT" 'cut off before it finished'

WHOLE='{"choices":[{"finish_reason":"stop","message":{"content":"## Findings\nall good"}}]}'
hasnot 'complete review gets no cut-off banner'    "$WHOLE" 'cut off before it finished'

[ "$fails" -eq 0 ] && echo "All routing tests passed." || echo "Some routing tests FAILED." >&2
exit "$fails"
