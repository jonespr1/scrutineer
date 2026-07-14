#!/usr/bin/env bash
# run.sh — run every model in manifest.json against every fixture and save raw output.
#
# Usage:  benchmark/run.sh [run_id] [--only model_id[,model_id...]]
#   run_id defaults to a UTC timestamp. Results land in benchmark/results/<run_id>/raw/.
#
# Env (same secrets/vars as Scrutineer):
#   OPENROUTER_API_KEY, GEMINI_API_KEY          — keys
#   OPENROUTER_HOSTS/SORT/ZDR/MAXPRICE          — routing (recorded into the run metadata)
#
# Slugs flagged "verify" in the manifest are checked against OpenRouter /models first; unknown
# slugs are skipped with a warning so a typo can never masquerade as a model failure.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$HERE/manifest.json"
FIXDIR="$HERE/fixtures"
INSTRUCTIONS="$(cat "$HERE/lib/prompt_instructions.txt")"

RUN_ID=""; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="${2:-}"; shift; [ $# -gt 0 ] && shift ;;   # tolerate a missing value (no infinite loop)
    --*)    shift ;;
    *)      [ -z "$RUN_ID" ] && RUN_ID="$1"; shift ;;
  esac
done
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"

OUT="$HERE/results/$RUN_ID"; RAW="$OUT/raw"; mkdir -p "$RAW"
echo "Run: $RUN_ID  ->  $OUT"

# --- Resolve OpenRouter slugs (best-effort; skips validation if the API is unreachable) ---
AVAILABLE=""
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
  AVAILABLE="$(curl -sS -m 30 https://openrouter.ai/api/v1/models -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
    | jq -r '.data[].id' 2>/dev/null || true)"
fi
slug_ok() { # slug -> 0 if present (or if we couldn't fetch the list at all)
  [ -z "$AVAILABLE" ] && return 0
  printf '%s\n' "$AVAILABLE" | grep -qxF "$1"
}

# --- Build one prompt per fixture (mirrors review.yml: instructions + diff + full file) ---
build_prompt() { # fixture_file -> prompt on stdout
  local f="$1" content diff
  content="$(cat "$FIXDIR/$f")"
  # Present the whole fixture as a freshly-added file so the framing matches a real PR.
  diff="$(printf '%s\n' "diff --git a/$f b/$f" "new file mode 100644" "--- /dev/null" "+++ b/$f"; sed 's/^/+/' "$FIXDIR/$f")"
  printf '%s\n\nCurrent unified diff to review:\n%s\n\nFull current content of the changed files (for context beyond the diff):\n\n===== FILE: %s (full current content) =====\n%s\n' \
    "$INSTRUCTIONS" "$diff" "$f" "$content"
}

# --- Metadata for the run ---
jq -n --arg id "$RUN_ID" \
      --arg hosts "${OPENROUTER_HOSTS:-}" --arg sort "${OPENROUTER_SORT:-price}" \
      --arg zdr "${OPENROUTER_ZDR:-true}" --arg maxp "${OPENROUTER_MAXPRICE:-}" \
      --argjson resolved "$( [ -n "$AVAILABLE" ] && echo true || echo false )" \
      '{run_id:$id, started_at:$id, routing:{openrouter_hosts:$hosts, sort:$sort, zdr:$zdr, max_price:$maxp},
        slugs_validated:$resolved}' > "$OUT/meta.json"

MODELS_JSON="$(jq -c '.models[]' "$MANIFEST")"
FIXTURES="$(jq -r '.fixtures[].file' "$MANIFEST")"

while IFS= read -r m; do
  id="$(jq -r '.id' <<<"$m")"; spec="$(jq -r '.spec' <<<"$m")"; provider="$(jq -r '.provider' <<<"$m")"
  if [ -n "$ONLY" ]; then case ",$ONLY," in *",$id,"*) : ;; *) continue;; esac; fi
  # Validate OpenRouter slugs.
  if [ "$provider" = "openrouter" ] && ! slug_ok "$spec"; then
    echo "  SKIP $id ($spec): not found on OpenRouter."
    printf '%s\n' "$AVAILABLE" | grep -iF "${spec##*/}" | head -3 | sed 's/^/         near-match: /' || true
    continue
  fi
  echo "== Model: $id ($spec) =="
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    pf="$(mktemp)"; build_prompt "$f" > "$pf"
    echo "   - $f"
    res="$(bash "$HERE/lib/call_model.sh" "$spec" "$pf")"
    rm -f "$pf"
    # Never let a crashed call produce a 0-byte file that would later break the scorer.
    [ -z "$res" ] && res='{"text":"","error":"call_model.sh produced no output","prompt_tokens":0,"completion_tokens":0,"total_cost":null,"cost_source":"unknown","latency_ms":0}'
    jq -c --arg model "$id" --arg spec "$spec" --arg fixture "$f" \
       '. + {model:$model, spec:$spec, fixture:$fixture}' <<<"$res" \
       > "$RAW/${id}__${f//\//_}.json"
  done <<<"$FIXTURES"
done <<<"$MODELS_JSON"

echo "Raw output written to $RAW"
echo "Now score with:  python3 $HERE/score.py $RUN_ID"
