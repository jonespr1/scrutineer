#!/usr/bin/env bash
# call_model.sh <spec> <prompt_file>
#
# Calls one model with the prompt in <prompt_file> and prints a single JSON object to stdout:
#   { "text": "...", "latency_ms": 1234, "prompt_tokens": N, "completion_tokens": N,
#     "thinking_tokens": N, "total_cost": 0.0123,
#     "cost_source": "openrouter|estimated|unknown", "error": null }
#
# thinking_tokens is a SUBSET of completion_tokens (thinking bills at the output rate, so it is
# counted there for cost); it is broken out so a reasoning row can be read as "how much of this
# spend was thinking rather than review text". 0 for OpenRouter and for Gemini without a budget.
#
# <spec> matches Scrutineer's REVIEWERS syntax:
#   gemini:<model>          -> Google Gemini API direct
#   <openrouter-model-id>   -> via OpenRouter (e.g. z-ai/glm-5.2)
#
# The call logic mirrors .github/workflows/review.yml so benchmark numbers reflect real behaviour.
# Cost: OpenRouter returns native USD cost inline (usage.include); direct Gemini has no cost field,
# so cost is left null here and estimated by score.py from a documented per-model price map.
set -uo pipefail

SPEC="${1:?spec required}"
PROMPT_FILE="${2:?prompt file required}"
PROMPT="$(cat "$PROMPT_FILE")"

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }  # portable (GNU date %N is not on macOS)
emit() { # text err prompt_tok completion_tok cost cost_source latency [thinking_tok]
  # thinking_tok is a SUBSET of completion_tok, not an addition to it: thinking tokens bill at the
  # output rate, so they belong in the completion count for costing. Recorded separately as well so
  # a thinking row can be broken down - "is the extra spend reasoning or a longer review?" is the
  # question that decides whether GEMINI_THINKING earns its cost, and the sum alone cannot answer it.
  jq -n --arg text "$1" --arg err "$2" --argjson pt "${3:-0}" --argjson ct "${4:-0}" \
        --argjson cost "${5:-null}" --arg cs "$6" --argjson lat "${7:-0}" --argjson tt "${8:-0}" \
        '{text:$text, error:(if $err=="" then null else $err end), prompt_tokens:$pt,
          completion_tokens:$ct, thinking_tokens:$tt, total_cost:$cost, cost_source:$cs,
          latency_ms:$lat}'
}

call_gemini() {
  local model="$1" req resp text http rc pt ct tt start end lat
  if [ -z "${GEMINI_API_KEY:-}" ]; then emit "" "GEMINI_API_KEY not set" 0 0 null unknown 0; return; fi
  # temperature 0 for reproducibility across runs (benchmark, not production).
  #
  # thinkingBudget comes from the manifest entry's optional "thinking" key, passed through by run.sh
  # as GEMINI_THINKING. Two entries can therefore share one spec at different reasoning settings,
  # which is the only way to separate "this model is better" from "reasoning was switched on" - the
  # confound that made the first gemini-3.7-flash run unable to answer the question it was asked.
  # The guard is a regex rather than an is-it-empty test so this stays a TOTAL function: jq's
  # tonumber ABORTS on a non-numeric string, so `GEMINI_THINKING=off` (or a typo'd manifest value)
  # would produce an empty request and a baffling failure. Anything that is not an integer is
  # ignored here; run.sh warns about it, which is where a human would have made the mistake.
  req="$(printf '%s' "$PROMPT" | jq -Rsc --arg gt "${GEMINI_THINKING:-}" '
    {contents:[{parts:[{text:.}]}],
     generationConfig:({temperature:0}
       + (if ($gt | test("^-?[0-9]+$")) then {thinkingConfig:{thinkingBudget:($gt|tonumber)}}
          else {} end))}')"
  start="$(now_ms)"
  rc=0; resp="$(printf '%s' "$req" | curl -sS -m 240 -w '\n__HTTP__%{http_code}' \
    "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${GEMINI_API_KEY}" \
    -H 'Content-Type: application/json' --data-binary @-)" || rc=$?
  end="$(now_ms)"; lat=$(( end - start ))
  http=""; case "$resp" in *__HTTP__*) http="${resp##*__HTTP__}"; resp="${resp%__HTTP__*}"; resp="${resp%$'\n'}";; esac
  text="$(printf '%s' "$resp" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null)"
  pt="$(printf '%s' "$resp" | jq -r '.usageMetadata.promptTokenCount // 0' 2>/dev/null)"
  # Thinking tokens are BILLED AT THE OUTPUT RATE but are reported separately from
  # candidatesTokenCount, so counting only candidates understates the cost of exactly the rows that
  # enable thinking - which would have quietly rigged this benchmark's cost axis in their favour.
  # Summed rather than dropped: total_cost must reflect what the run actually costs.
  ct="$(printf '%s' "$resp" | jq -r '(.usageMetadata.candidatesTokenCount // 0) + (.usageMetadata.thoughtsTokenCount // 0)' 2>/dev/null)"
  tt="$(printf '%s' "$resp" | jq -r '.usageMetadata.thoughtsTokenCount // 0' 2>/dev/null)"
  if [ -z "$text" ]; then
    local err fr
    err="$(printf '%s' "$resp" | jq -r '.error.message // empty' 2>/dev/null)"
    fr="$(printf '%s' "$resp" | jq -r '.candidates[0].finishReason // .promptFeedback.blockReason // empty' 2>/dev/null)"
    [ "$rc" = 28 ] && err="timeout after 240s"
    [ "$rc" != 0 ] && [ -z "$err" ] && err="curl failed with exit code $rc"
    emit "" "${err:-empty response (HTTP ${http:-?}, finishReason=${fr:-?})}" "${pt:-0}" "${ct:-0}" null estimated "$lat" "${tt:-0}"; return
  fi
  emit "$text" "" "${pt:-0}" "${ct:-0}" null estimated "$lat" "${tt:-0}"
}

call_openrouter() {
  local model="$1" req resp text http rc pt ct cost start end lat prov sort
  if [ -z "${OPENROUTER_API_KEY:-}" ]; then emit "" "OPENROUTER_API_KEY not set" 0 0 null unknown 0; return; fi
  sort="${OPENROUTER_SORT:-price}"
  prov="$(jq -n --arg s "$sort" '{data_collection:"deny", sort:$s, allow_fallbacks:true}')"
  [ -n "${OPENROUTER_HOSTS:-}" ] && prov="$(printf '%s' "$prov" | jq --arg l "$OPENROUTER_HOSTS" '. + {only:($l|split(",")|map(gsub("^ +| +$";"")))}')"
  [ "${OPENROUTER_ZDR:-true}" != "false" ] && prov="$(printf '%s' "$prov" | jq '. + {zdr:true}')"
  # Accept "in,out" or a single value (applied to both) so a lone number can't break the jq encode.
  [ -n "${OPENROUTER_MAXPRICE:-}" ] && prov="$(printf '%s' "$prov" | jq --arg m "$OPENROUTER_MAXPRICE" '. + ($m|split(",")|{max_price:{prompt:(.[0]|tonumber), completion:((.[1] // .[0])|tonumber)}})')"
  # Exclude lossy quantisations so the comparison is model-vs-model, not model-vs-cheap-fp4-host.
  # Unset/empty -> the fp8/fp16/bf16 default (empty is what the workflow passes for an unset var, so
  # ":-" not "-"). Set OPENROUTER_QUANT=any to disable. If a model only serves at fp4 it then fails
  # to route, which the run surfaces as an error rather than a silently-degraded score.
  QUANT="${OPENROUTER_QUANT:-fp8,fp16,bf16}"
  case "$QUANT" in any|none|all|off) QUANT="" ;; esac
  [ -n "$QUANT" ] && prov="$(printf '%s' "$prov" | jq --arg q "$QUANT" '. + {quantizations:($q|split(",")|map(gsub("^ +| +$";"")))}')"
  # temperature 0 for reproducibility; usage.include:true returns the native USD cost inline.
  req="$(printf '%s' "$PROMPT" | jq -Rsc --arg m "$model" --argjson prov "$prov" \
    '{model:$m, messages:[{role:"user",content:.}], provider:$prov, temperature:0, usage:{include:true}}')"
  start="$(now_ms)"
  rc=0; resp="$(printf '%s' "$req" | curl -sS -m 300 -w '\n__HTTP__%{http_code}' \
    "https://openrouter.ai/api/v1/chat/completions" \
    -H "Authorization: Bearer ${OPENROUTER_API_KEY}" -H 'Content-Type: application/json' \
    -H 'HTTP-Referer: https://github.com' -H 'X-Title: Scrutineer-Benchmark' --data-binary @-)" || rc=$?
  end="$(now_ms)"; lat=$(( end - start ))
  http=""; case "$resp" in *__HTTP__*) http="${resp##*__HTTP__}"; resp="${resp%__HTTP__*}"; resp="${resp%$'\n'}";; esac
  text="$(printf '%s' "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)"
  pt="$(printf '%s' "$resp" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null)"
  ct="$(printf '%s' "$resp" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)"
  cost="$(printf '%s' "$resp" | jq -r '.usage.cost // empty' 2>/dev/null)"
  if [ -z "$text" ]; then
    local err fr
    err="$(printf '%s' "$resp" | jq -r '.error.message // empty' 2>/dev/null)"
    fr="$(printf '%s' "$resp" | jq -r '.choices[0].finish_reason // empty' 2>/dev/null)"
    [ "$rc" = 28 ] && err="timeout after 300s"
    [ "$rc" != 0 ] && [ -z "$err" ] && err="curl failed with exit code $rc"
    emit "" "${err:-empty response (HTTP ${http:-?}, finish_reason=${fr:-?}) - no host matched routing?}" "${pt:-0}" "${ct:-0}" null unknown "$lat"; return
  fi
  if [ -n "$cost" ]; then emit "$text" "" "${pt:-0}" "${ct:-0}" "$cost" openrouter "$lat"
  else emit "$text" "" "${pt:-0}" "${ct:-0}" null unknown "$lat"; fi
}

case "$SPEC" in
  gemini:*) call_gemini "${SPEC#gemini:}" ;;
  gemini)   call_gemini "gemini-pro-latest" ;;
  *)        call_openrouter "$SPEC" ;;
esac
