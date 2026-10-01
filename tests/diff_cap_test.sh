#!/usr/bin/env bash
# Tests for the diff size cap (DIFF_MAX_CHARS) - review.yml's MAX="${DIFF_MAX_CHARS:-200000}"
# block, its validation, and the guard against a cap low enough to truncate a diff to nothing.
#
# The block is extracted verbatim from the workflow rather than copied here, so the test cannot
# drift from what ships. Same approach as the other suites.
#
# Why this needs tests: this cap used to be a hardcoded 200000, which could never be zero. Making
# it a repo Variable opens a config path to MAX=0 (or small enough to truncate a diff to nothing)
# that did not exist before - and without a guard, that silently reaches a paid model call with
# an empty diff, the exact "confidently wrong on a partial payload" failure DIFF_EXCLUDE's own
# all-matched guard already exists to prevent for a different cause.
#
# Usage: tests/diff_cap_test.sh     (needs bash)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$HERE/../.github/workflows/review.yml"

# --- Extract the block verbatim -------------------------------------------------------------
# Three `fi` lines appear in this block (the invalid-value fallback, the truncation itself, and
# the empty-after-truncation guard), so a plain awk range ending at the first bare `fi` would
# stop too early. Buffer from the MAX= line and stop at the first `fi` seen AFTER the guard's
# own message line, which is unique in the file.
SRC="$(awk '
  /^          MAX="\$\{DIFF_MAX_CHARS:-200000\}"$/ { inblk=1 }
  inblk { buf = buf $0 "\n" }
  inblk && /truncated the diff to nothing/ { seenmsg=1 }
  inblk && seenmsg && /^          fi$/ { printf "%s", buf; inblk=0 }
' "$WF" | sed 's/^          //')"
bad() { echo "FAIL: bad extraction of the DIFF_MAX_CHARS block from $WF - $1" >&2; exit 1; }
[ -n "$SRC" ]                                    || bad "nothing matched (has the block moved?)"
printf '%s' "$SRC" | grep -q 'DIFF_MAX_CHARS'     || bad "no DIFF_MAX_CHARS reference"
printf '%s' "$SRC" | grep -q 'TRUNC_NOTE'         || bad "no TRUNC_NOTE"
[ "$(printf '%s' "$SRC" | tail -n1)" = 'fi' ]     || bad "does not end at the closing brace (truncated?)"
printf '%s\n' "$SRC" | bash -n 2>/dev/null        || bad "extracted text is not valid bash"

fails=0
ok()  { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=1; }

# Run the SHIPPED block against a caller-supplied DIFF and DIFF_MAX_CHARS, capturing the
# resulting DIFF, TRUNC_NOTE, any diagnostic, and the exit code together. The diff content is
# passed through a FILE, not an env-var prefix assignment to `bash -c`: a few-hundred-KB value
# passed that way hits "Argument list too long" in this environment well under the nominal
# ARG_MAX (confirmed by direct reproduction) - reading it back inside the nested shell has no
# such limit, since it is then just a variable assignment within one process, not an exec().
run_raw() { # $1 = DIFF_MAX_CHARS, $2 = DIFF -> "<exit code>|<stdout>"
  local diffile out code
  diffile="$(mktemp)"; printf '%s' "$2" > "$diffile"
  out="$(DIFF_MAX_CHARS="$1" DIFFFILE="$diffile" bash -c '
    set -uo pipefail
    DIFF="$(cat "$DIFFFILE")"
    '"$SRC"'
    printf "===DIFF_START===\n%s\n===DIFF_END===\nNOTE=[%s]\nMAX=[%s]\n" "$DIFF" "$TRUNC_NOTE" "$MAX"
  ' 2>&1)"; code=$?
  rm -f "$diffile"
  printf '%s|%s' "$code" "$out"
}
run() { run_raw "$1" "$2" | cut -d'|' -f2-; }      # just the printed fields, for the common case
# Pulls just the (possibly multi-line) diff content back out of run()'s output. A line-anchored
# sed pattern cannot do this - real diffs contain newlines, so "DIFF=[...]" is never one line -
# hence the sentinel markers above instead of inline brackets for this one field.
diff_field() { printf '%s' "$1" | awk '/^===DIFF_START===$/{f=1;next} /^===DIFF_END===$/{f=0} f'; }

longdiff() { # $1 = target length -> a diff-shaped string of roughly that many chars, real lines
  local out="" chunk
  chunk="diff --git a/f.txt b/f.txt
index 1111111..2222222 100644
--- a/f.txt
+++ b/f.txt
@@ -1 +1 @@
-old line filler filler filler
+new line filler filler filler
"
  # Doubling beats repeated concatenation of a fixed-size chunk: O(log n) appends instead of
  # O(n), which matters once $1 reaches hundreds of thousands of characters.
  while [ "${#out}" -lt "$1" ]; do out="${out}${out:-$chunk}"; done
  printf '%s' "${out:0:$1}"
}

# --- Normal behaviour: default cap, diff under it ---------------------------------------------
short="$(longdiff 500)"
out="$(run '' "$short")"
case "$(diff_field "$out")" in "$short") ;; *) fail "unset DIFF_MAX_CHARS, short diff: content altered" ;; esac
case "$out" in *'NOTE=[]'*) ok 'unset DIFF_MAX_CHARS: a diff under the default cap is untouched' ;;
  *) fail "unset DIFF_MAX_CHARS, short diff: unexpected TRUNC_NOTE ($out)" ;; esac

# --- Default cap actually truncates an over-size diff ------------------------------------------
long="$(longdiff 250000)"
out="$(run '' "$long")"
case "$out" in *'NOTE=[]'*) fail 'unset DIFF_MAX_CHARS: a 250000-char diff was NOT truncated at the 200000 default' ;;
  *) ok 'unset DIFF_MAX_CHARS: a diff over the default cap is truncated, with a note' ;; esac

# --- THE feature: DIFF_MAX_CHARS raises the cap, so the same diff survives intact --------------
out="$(run '500000' "$long")"
case "$out" in *'NOTE=[]'*) ok 'DIFF_MAX_CHARS=500000: the same 250000-char diff now survives untruncated' ;;
  *) fail "DIFF_MAX_CHARS=500000 did not raise the cap ($out)" ;; esac

# --- DIFF_MAX_CHARS also lowers the cap, truncating a diff the default would not touch ----------
out="$(run '100' "$short")"
case "$out" in *'NOTE=[]'*) fail 'DIFF_MAX_CHARS=100: a 500-char diff was NOT truncated' ;;
  *) ok 'DIFF_MAX_CHARS=100: a diff the default cap would leave alone is truncated' ;; esac

# --- Truncation lands on a line boundary, never mid-line ----------------------------------------
# diff_field() reads back through $(...) command substitution, which strips ALL trailing
# newlines unconditionally - so a prior version of this check (fail if the result ends with a
# literal \n) could never fire regardless of where the shipped code actually cut: a vacuous
# assertion that passed even on a mid-line truncation. Assert the exact expected content
# instead, computed independently from the $short fixture above: the last newline before byte
# 100 falls right after "@@ -1 +1 @@".
expected_boundary="diff --git a/f.txt b/f.txt
index 1111111..2222222 100644
--- a/f.txt
+++ b/f.txt
@@ -1 +1 @@"
diffout="$(diff_field "$out")"
case "$diffout" in "$expected_boundary") ok 'DIFF_MAX_CHARS=100 truncation lands exactly on the expected line boundary' ;;
  *) fail "DIFF_MAX_CHARS=100 truncation does not match the expected line-boundary cut (got: $diffout)" ;; esac

# --- Malformed and non-positive values fall back to the default, loudly -----------------------
# review.yml's own warning (matching OPENROUTER_MAXTOKENS's existing precedent) is a plain
# `echo`, i.e. STDOUT - not stderr - so this checks the same combined output `run` already
# captures, rather than assuming a stream the shipped code never writes to.
out="$(run 'abc' "$short")"
case "$out" in *'MAX=[200000]'*) ok "malformed DIFF_MAX_CHARS='abc' falls back to 200000" ;;
  *) fail "malformed DIFF_MAX_CHARS did not fall back ($out)" ;; esac
case "$out" in *"Invalid DIFF_MAX_CHARS='abc'"*) ok 'malformed DIFF_MAX_CHARS warns, naming the bad value' ;;
  *) fail "no warning for malformed DIFF_MAX_CHARS (got: $out)" ;; esac

out="$(run '0' "$short")"
case "$out" in *'MAX=[200000]'*) ok 'DIFF_MAX_CHARS=0 falls back to 200000, not MAX=0' ;;
  *) fail "DIFF_MAX_CHARS=0 was accepted ($out)" ;; esac

# --- Whitespace around the value is stripped before validation, not rejected as malformed -------
# review.yml does this explicitly (MAX="${MAX//[[:space:]]/}") before the digit check, matching
# OPENROUTER_MAXTOKENS's own tolerance for " 2, 6 ". Without this case, a future edit dropping
# that strip would start rejecting " 100 " as malformed (the digit check fails on the space) and
# nothing here would notice - it would just silently fall back to 200000 instead of honouring it.
out="$(run ' 100 ' "$short")"
case "$out" in *'MAX=[100]'*) ok "whitespace around DIFF_MAX_CHARS (' 100 ') is stripped, not rejected" ;;
  *) fail "whitespace-padded DIFF_MAX_CHARS was not honoured ($out)" ;; esac
out="$(run "$(printf '\t100\n')" "$short")"
case "$out" in *'MAX=[100]'*) ok 'a tab/newline around DIFF_MAX_CHARS is also stripped' ;;
  *) fail "tab/newline-padded DIFF_MAX_CHARS was not honoured ($out)" ;; esac

out="$(run '-5' "$short")"
case "$out" in *'MAX=[200000]'*) ok 'DIFF_MAX_CHARS=-5 falls back to 200000' ;;
  *) fail "DIFF_MAX_CHARS=-5 was accepted ($out)" ;; esac

# --- A leading zero is decimal everywhere $MAX is used, not just where it was validated ---------
# [ -lt ]/[ -gt ] (the test builtin, used for validation above) always read $MAX as decimal, but
# "${DIFF:0:$MAX}" a few lines down is a bash ARITHMETIC substring length, which reads a leading
# zero as OCTAL. Without forcing base 10 once validation accepts the value, DIFF_MAX_CHARS=0200000
# would pass validation as (decimal) 200000 but actually truncate at 65536 - 0200000 read as octal
# - with no warning that the configured value was misread, and DIFF_MAX_CHARS=08 would abort the
# whole run ("08: value too great for base", 8 not being a valid octal digit) after the diff fetch
# already succeeded.
out="$(run '0200000' "$long")"
case "$out" in *'MAX=[200000]'*) ok "DIFF_MAX_CHARS='0200000' is read as decimal 200000, not octal 65536" ;;
  *) fail "DIFF_MAX_CHARS='0200000' was not normalized to decimal (got: $out)" ;; esac
# The 250000-char diff still gets truncated (200000 < 250000) - what matters is WHERE. Truncated
# at the correct decimal cap the result is 199976 chars (last newline below 200000); truncated at
# the octal misreading (65536) it would be only 65533. Assert the decimal-length result so this
# would catch a regression to the octal interpretation, not just the absence of truncation.
diffout="$(diff_field "$out")"
case "${#diffout}" in 199976) ok "DIFF_MAX_CHARS='0200000' truncates at the decimal length (199976 chars), not the octal one (65533)" ;;
  *) fail "DIFF_MAX_CHARS='0200000' truncated to ${#diffout} chars, not the expected decimal length 199976 ($out)" ;; esac

# A diff no longer than 8 chars stays under MAX, so the truncation/empty-diff branches never fire
# here - this isolates the normalization itself from the (already-covered) guard behaviour.
got="$(run_raw '08' 'ab')"
code="${got%%|*}"
case "$code" in 0) ;; *) fail "DIFF_MAX_CHARS='08' aborted the run (exit $code): $got" ;; esac
case "$got" in *'value too great for base'*) fail "DIFF_MAX_CHARS='08' crashed on an invalid octal digit (got: $got)" ;;
  *'MAX=[8]'*) ok "DIFF_MAX_CHARS='08' does not crash and resolves to decimal 8" ;;
  *) fail "DIFF_MAX_CHARS='08' did not resolve to MAX=[8] (got: $got)" ;; esac

# --- The guard this change exists for: a cap that truncates to NOTHING must not reach a paid call
# Constructed directly rather than hunting for a MAX/diff pair that happens to truncate to empty
# (only a narrow byte-boundary case does, e.g. a diff starting with a newline at MAX=1): the guard
# does not care WHY DIFF ended up empty, only that it is, so this tests that logic on its own
# terms, and the second case below proves a real truncation can actually reach it.
run_exit() { # $1 = DIFF_MAX_CHARS, $2 = DIFF -> "<exit code>|<stdout>"
  local diffile out code
  diffile="$(mktemp)"; printf '%s' "$2" > "$diffile"
  out="$(DIFF_MAX_CHARS="$1" DIFFFILE="$diffile" bash -c '
    set -uo pipefail
    DIFF="$(cat "$DIFFFILE")"
    '"$SRC"'
    echo "REACHED_PAST_GUARD"
  ' 2>/dev/null)"; code=$?
  rm -f "$diffile"
  printf '%s|%s' "$code" "$out"
}
got="$(run_exit '200000' '')"
case "$got" in 0\|*'DIFF_MAX_CHARS truncated the diff to nothing'*)
    ok 'an already-empty diff exits 0 with the diagnostic, never reaching REACHED_PAST_GUARD' ;;
  *) fail "empty-diff guard did not fire as expected (got=$got)" ;; esac
case "$got" in *REACHED_PAST_GUARD*) fail 'execution continued past the empty-diff guard' ;; esac

# A real truncation that empties the diff: a leading newline is the only character within a
# MAX=1 window, and the trailing-newline strip then removes it too, leaving "".
leading_nl="$(printf '\n%s' "$(longdiff 5000)")"
got="$(run_exit '1' "$leading_nl")"
case "$got" in 0\|*'DIFF_MAX_CHARS truncated the diff to nothing'*)
    ok 'a genuine truncation-to-empty (DIFF_MAX_CHARS=1) also hits the guard, not just a pre-empty DIFF' ;;
  *) fail "truncation-caused emptiness did not hit the guard (got=$got)" ;; esac

# The other way to empty a diff via truncation, and the one that actually surfaces in practice:
# DIFF_MAX_CHARS set smaller than the diff's OWN first line, with no leading newline at all. A
# real "diff --git a/... b/..." header alone is ~30-60 chars, so this is well within reach of an
# operator's typo (one digit short), not just a constructed edge case. Without the no-newline
# branch in the truncation block, this used to leave a non-empty, mid-line garbage fragment that
# the empty-diff guard could not see (it is not empty) and that still reached a paid model call.
realdiff="diff --git a/f.txt b/f.txt
index 1111111..2222222 100644
--- a/f.txt
+++ b/f.txt
@@ -1 +1 @@
-old
+new"
got="$(run_exit '20' "$realdiff")"
case "$got" in 0\|*'DIFF_MAX_CHARS truncated the diff to nothing'*)
    ok 'DIFF_MAX_CHARS smaller than the first line empties the diff instead of a mid-line fragment' ;;
  *) fail "a cap cutting mid-first-line reached the model with a garbage fragment (got=$got)" ;; esac

[ "$fails" -eq 0 ] && echo "All diff-cap tests passed." || echo "Some diff-cap tests FAILED." >&2
exit "$fails"
