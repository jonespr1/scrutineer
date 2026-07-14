#!/usr/bin/env bash
# call_model.sh <spec> <prompt_file>
#
# Calls one model with the prompt in <prompt_file> and prints a single JSON object to stdout:
#   { "text": "...", "latency_ms": 1234, "prompt_tokens": N, "completion_tokens": N,
#     "total_cost": 0.0123, "cost_source": "openrouter|estimated|unknown", "error": null }
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

now_ms() { date +%s%3N; }
emit() { # text err prompt_tok completion_tok cost cost_source latency
  jq -n --arg text "$1" --arg err "$2" --argjson pt "${3:-0}" --argjson ct "${4:-0}" \
        --argjson cost "${5:-null}" --arg cs "$6" --argjson lat "${7:-0}" \
        '{text:$text, error:(if $err=="" then null else $err end), prompt_tokens:$pt,
          completion_tokens:$ct, total_cost:$cost, cost_source:$cs, latency_ms:$lat}'
}

call_gemini() {
  local model="$1" req resp text http rc pt ct start end lat
  if [ -z "${GEMINI_API_KEY:-}" ]; then emit "" "GEMINI_API_KEY not set" 0 0 null unknown 0; return; fi
  req="$(printf '%s' "$PROMPT" | jq -Rsc '{contents:[{parts:[{text:.}]}]}')"
  start="$(now_ms)"
  rc=0; resp="$(printf '%s' "$req" | curl -sS -m 240 -w '\n__HTTP__%{http_code}' \
    "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${GEMINI_API_KEY}" \
    -H 'Content-Type: application/json' --data-binary @-)" || rc=$?
  end="$(now_ms)"; lat=$(( end - start ))
  http=""; case "$resp" in *__HTTP__*) http="${resp##*__HTTP__}"; resp="${resp%__HTTP__*}"; resp="${resp%$'\n'}";; esac
  text="$(printf '%s' "$resp" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null)"
  pt="$(printf '%s' "$resp" | jq -r '.usageMetadata.promptTokenCount // 0' 2>/dev/null)"
  ct="$(printf '%s' "$resp" | jq -r '.usageMetadata.candidatesTokenCount // 0' 2>/dev/null)"
  if [ -z "$text" ]; then
    local err fr
    err="$(printf '%s' "$resp" | jq -r '.error.message // empty' 2>/dev/null)"
    fr="$(printf '%s' "$resp" | jq -r '.candidates[0].finishReason // .promptFeedback.blockReason // empty' 2>/dev/null)"
    [ "$rc" = 28 ] && err="timeout after 240s"
    emit "" "${err:-empty response (HTTP ${http:-?}, finishReason=${fr:-?})}" "${pt:-0}" "${ct:-0}" null estimated "$lat"; return
  fi
  emit "$text" "" "${pt:-0}" "${ct:-0}" null estimated "$lat"
}

call_openrouter() {
  local model="$1" req resp text http rc pt ct cost start end lat prov sort
  if [ -z "${OPENROUTER_API_KEY:-}" ]; then emit "" "OPENROUTER_API_KEY not set" 0 0 null unknown 0; return; fi
  sort="${OPENROUTER_SORT:-price}"
  prov="$(jq -n --arg s "$sort" '{data_collection:"deny", sort:$s, allow_fallbacks:true}')"
  [ -n "${OPENROUTER_HOSTS:-}" ] && prov="$(printf '%s' "$prov" | jq --arg l "$OPENROUTER_HOSTS" '. + {only:($l|split(",")|map(gsub("^ +| +$";"")))}')"
  [ "${OPENROUTER_ZDR:-true}" != "false" ] && prov="$(printf '%s' "$prov" | jq '. + {zdr:true}')"
  [ -n "${OPENROUTER_MAXPRICE:-}" ] && prov="$(printf '%s' "$prov" | jq --arg m "$OPENROUTER_MAXPRICE" '. + ($m|split(",")|{max_price:{prompt:(.[0]|tonumber), completion:(.[1]|tonumber)}})')"
  # usage.include:true asks OpenRouter to return the native USD cost inline.
  req="$(printf '%s' "$PROMPT" | jq -Rsc --arg m "$model" --argjson prov "$prov" \
    '{model:$m, messages:[{role:"user",content:.}], provider:$prov, usage:{include:true}}')"
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
