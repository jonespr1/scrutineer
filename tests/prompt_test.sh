#!/usr/bin/env bash
# The reviewer prompt carries the rules that let a review loop end. These are prose, so
# nothing else would notice if an edit dropped one. Each check names the rule it pins.
#
# The rules are looked for in the two printf blocks that BUILD the prompt, not in the whole
# file: a rule that survives only in a comment is not in the prompt. The per-slot functions
# are extracted verbatim (as in dedupe_test.sh), so the test cannot drift from what ships.
#
# Usage: tests/prompt_test.sh     (needs bash + jq)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$HERE/../.github/workflows/review.yml"
fail=0

block() { awk -v start="^          $1=\"\\\\$\\\\(printf" '$0 ~ start { f = 1 } f { print } f && /\)"$/ { exit }' "$WF"; }
INSTRUCTIONS_SRC="$(block INSTRUCTIONS)"
REREVIEW_SRC="$(block REREVIEW)"
[ -n "$INSTRUCTIONS_SRC" ] || { echo "FAIL  bad extraction of the INSTRUCTIONS block from $WF (did its first line or its indent change?)"; exit 1; }
[ -n "$REREVIEW_SRC" ]     || { echo "FAIL  bad extraction of the REREVIEW block from $WF (did its first line or its indent change?)"; exit 1; }

has() { printf '%s' "$1" | grep -qF -- "$2" || { echo "FAIL  prompt lost: $3"; fail=1; }; }
has "$INSTRUCTIONS_SRC" "Do NOT report style" "the no-style rule"
has "$INSTRUCTIONS_SRC" "**Verdict:** BLOCKING" "the blocking verdict line"
has "$INSTRUCTIONS_SRC" "**Verdict:** NOT BLOCKING" "the not-blocking verdict line"
has "$REREVIEW_SRC" "Do NOT raise an issue that another reviewer already raised" "the cross-reviewer de-duplication rule"
has "$REREVIEW_SRC" "raise a new finding only when it is" "the unchanged-code rule for a re-review"
has "$REREVIEW_SRC" "CHANGED SINCE YOUR PREVIOUS REVIEW" "the pointer to the list of changed files"
grep -qF "its first line names the reviewer" "$WF" || { echo "FAIL  prompt lost: the honest label on prior reviews"; fail=1; }
if grep -qF "### Your previous review" "$WF"; then echo "FAIL  prior reviews are again all labelled as the reader's own"; fail=1; fi
if grep -qF "PRIOR CONVERSATION (your earlier reviews" "$WF"; then echo "FAIL  the prior conversation is again described as the reader's own reviews"; fail=1; fi

# --- The per-slot context: who the reviewer is, and what changed since ITS last review. ---
fn() { awk -v start="^          $1\\\\(\\\\) \\\\{$" '$0 ~ start, /^          \}$/' "$WF" | sed 's/^          //'; }
for name in own_review_sha slot_context; do
  SRC="$(fn "$name")"
  [ -n "$SRC" ] && printf '%s\n' "$SRC" | bash -n 2>/dev/null || { echo "FAIL  bad extraction of $name() from $WF"; exit 1; }
  eval "$SRC"
done
grep -qF 'PROMPT="$(slot_context "$label")"' "$WF" || { echo "FAIL  run_slot no longer puts the slot context into the prompt"; fail=1; }

A='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
B='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
H='cccccccccccccccccccccccccccccccccccccccc'
review() { printf '## 🤖 Review - `%s`\n\n%s\n\n<!-- scrutineer sha=%s lat=1s in=1 out=1 cost=na host=na -->' "$1" "${3:-body}" "$2"; }
thread() { local out='[]' b; for b in "$@"; do out="$(jq -n --argjson a "$out" --arg b "$b" '$a + [{user:{type:"Bot"},body:$b}]')"; done; printf '%s' "$out"; }
eq() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1 (got='$2' want='$3')"; fail=1; fi; }
contains() { case "$2" in *"$3"*) echo "ok    $1" ;; *) echo "FAIL  $1 (no '$3' in: $2)"; fail=1 ;; esac; }
lacks() { case "$2" in *"$3"*) echo "FAIL  $1 (found '$3')"; fail=1 ;; *) echo "ok    $1" ;; esac; }

REPO='o/r'; HEAD_SHA="$H"
COMMENTS_JSON="$(thread "$(review glm "$A")" "$(review gemini "$B")" "$(review glm "$B")")"
eq "own_review_sha: the newest review of this slot" "$(own_review_sha glm)" "$B"
eq "own_review_sha: a slot with no review has none" "$(own_review_sha minimax)" ""
# Another model quoted glm's whole review back, header and marker included. It is gemini's.
COMMENTS_JSON="$(thread "$(review gemini "$B" "$(review glm "$A")")")"
eq "own_review_sha: a quoted review is not this slot's own" "$(own_review_sha glm)" ""

# A failed call posts a notice with this slot's header and a marker. It reviewed nothing.
COMMENTS_JSON="$(thread "$(review glm "$A")" "$(review glm "$B" "⚠️ Could not generate review.")")"
eq "own_review_sha: a failure notice is not a review" "$(own_review_sha glm)" "$A"
COMMENTS_JSON="$(thread "$(review glm "$H" "⚠️ Could not generate review.")")"
lacks "slot_context: a retry after a failure is not told that it reviewed this commit" "$(slot_context glm)" "CHANGED SINCE"

# A real review that QUOTES the notice (a review of this workflow does) is still a review.
COMMENTS_JSON="$(thread "$(review glm "$A")" "$(review glm "$B" 'The filter contains("⚠️ Could not generate review") is too wide.')")"
eq "own_review_sha: a review that quotes the failure notice is still a review" "$(own_review_sha glm)" "$B"
# A bot comment with this slot's header and no marker is passed over; it does not hide the reviews before it.
COMMENTS_JSON="$(thread "$(review glm "$A")" "$(jq -n --arg b '## 🤖 Review - `glm`

no marker here' '$b' -r)")"
eq "own_review_sha: a headed comment with no marker does not hide an earlier review" "$(own_review_sha glm)" "$A"

# --- The history cut: newest 20000 characters, starting at a whole entry. ---
CUT_SRC="$(awk '/^          if \[ "\$\{#HISTORY\}" -gt 20000 \]; then$/, /^          fi$/' "$WF" | sed 's/^          //')"
[ -n "$CUT_SRC" ] && printf '%s\n' "$CUT_SRC" | bash -n 2>/dev/null || { echo "FAIL  bad extraction of the history cut from $WF"; exit 1; }
pad() { head -c "$1" /dev/zero | tr '\0' 'x'; }
HISTORY="### Previous review (its first line names the reviewer: you or another one):
$(pad 15000)

---

### Developer response (someone):
$(pad 9000)

---

### Previous review (its first line names the reviewer: you or another one):
LAST"
eval "$CUT_SRC"
eq "history cut: the result starts at a whole entry" "$(printf '%s' "$HISTORY" | head -1)" "### Developer response (someone):"
contains "history cut: the newest entry is kept" "$HISTORY" "LAST"
HISTORY="### Previous review (its first line names the reviewer: you or another one):
$(pad 30000)"
eval "$CUT_SRC"
eq "history cut: one entry longer than the window keeps the raw cut" "${#HISTORY}" "20000"
HISTORY="### Developer response (someone):
$(pad 15000)

---

### Previous review (its first line names the reviewer: you or another one):
$(pad 9000)

---

### Developer response (someone):
LAST"
eval "$CUT_SRC"
eq "history cut: a review entry is a whole entry too" "$(printf '%s' "$HISTORY" | head -1)" "### Previous review (its first line names the reviewer: you or another one):"
HISTORY="short"
eval "$CUT_SRC"
eq "history cut: a short history is not touched" "$HISTORY" "short"
# The cut finds an entry by the two labels that the history builder writes. If a label changes, the cut must change too.
grep -qF '"### Previous review (' "$WF" && grep -qF '"### Developer response (' "$WF" || { echo "FAIL  the history labels changed; the cut pattern depends on them"; fail=1; }

# gh is replaced, so the test needs no network: it records the call and returns $GH_OUT.
gh() { GH_CALL="$*"; echo "$*" > "$CALLS"; [ -n "${GH_OUT:-}" ] && printf '%s\n' "$GH_OUT"; return "${GH_RC:-0}"; }
CALLS="$(mktemp)"

COMMENTS_JSON='[]'; : > "$CALLS"
out="$(slot_context glm)"
contains "slot_context: names the reviewer" "$out" 'You are the reviewer named `glm`'
lacks    "slot_context: does not show the header for the model to copy" "$out" '## 🤖 Review'
lacks    "slot_context: a first review has no changed-files line" "$out" "CHANGED SINCE"
eq       "slot_context: a first review makes no API call" "$(cat "$CALLS")" ""

COMMENTS_JSON="$(thread "$(review glm "$A")" "$(review gemini "$B")")"; : > "$CALLS"
out="$(GH_OUT=$'src/a.ts\nsrc/b.ts' slot_context glm)"
contains "slot_context: compares from this slot's own last commit" "$(cat "$CALLS")" "compare/${A}...${H}"
contains "slot_context: lists the changed files" "$out" $'aaaaaaa), by file. Every file that is not in this list is unchanged code:\nsrc/a.ts\nsrc/b.ts'

out="$(GH_OUT='' GH_RC=1 slot_context glm)"
contains "slot_context: a failed comparison says so and does not narrow the review" "$out" "not known"

out="$(GH_OUT="$(seq -f "f%g.ts" 300)" slot_context glm)"
contains "slot_context: a full page of 300 files may be cut, so it is not known" "$out" "not known"
lacks    "slot_context: a full page is not presented as the list" "$out" "f1.ts"
out="$(GH_OUT="$(seq -f "f%g.ts" 299)" slot_context glm)"
contains "slot_context: 299 files are listed" "$out" "f299.ts"

COMMENTS_JSON="$(thread "$(review glm "$H")")"; : > "$CALLS"
out="$(slot_context glm)"
contains "slot_context: the same commit means no code changed" "$out" "CHANGED SINCE YOUR PREVIOUS REVIEW: no code"
eq       "slot_context: the same commit makes no API call" "$(cat "$CALLS")" ""
rm -f "$CALLS"

[ "$fail" = 0 ] && echo "All prompt tests passed." || { echo "Some prompt tests FAILED."; exit 1; }
