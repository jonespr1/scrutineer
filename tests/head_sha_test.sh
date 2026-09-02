#!/usr/bin/env bash
# Tests for review.yml's resolve_head_sha() - the issue_comment-path HEAD_SHA resolution.
#
# The function is extracted verbatim from the workflow rather than copied here, so the test
# cannot drift from what ships. Same approach as trigger_test.sh and dedupe_test.sh.
#
# Why this needs tests: on marketing-os#51, an @review comment posted right after a push got
# back the PR's FIRST commit from a single `gh api pulls/{n}` read, while the real head was
# already several commits ahead. All three reviewer slots share one HEAD_SHA variable, so the
# one bad read fanned into all three reviews citing the identical wrong commit and re-raising
# already-fixed findings as still open - a full paid round spent reviewing stale code. The fix
# requires two consecutive reads to agree before trusting the result; these tests drive a fake
# `gh` through the exact stale-then-correct sequence observed, plus the always-correct and
# never-stabilises cases, and pin that `sleep` is actually called between attempts (a version
# that busy-loops without waiting would race the same GitHub read-path lag it exists to avoid).
#
# Usage: tests/head_sha_test.sh     (needs bash)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$HERE/../.github/workflows/review.yml"

# --- Extract resolve_head_sha() verbatim ---------------------------------------------------
SRC="$(awk '/^          resolve_head_sha\(\) \{$/,/^          \}$/' "$WF" | sed 's/^          //')"
bad() { echo "FAIL: bad extraction of resolve_head_sha() from $WF - $1" >&2; exit 1; }
[ -n "$SRC" ]                                 || bad "nothing matched (has the function moved?)"
printf '%s' "$SRC" | grep -q 'gh api'         || bad "no gh api call"
printf '%s' "$SRC" | grep -q 'sleep'          || bad "no sleep between attempts"
[ "$(printf '%s' "$SRC" | tail -n1)" = '}' ]  || bad "does not end at the closing brace (truncated?)"
printf '%s\n' "$SRC" | bash -n 2>/dev/null    || bad "extracted text is not valid bash"

fails=0
ok()  { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=1; }

# Run the SHIPPED function with a fake `gh` returning a caller-supplied sequence of responses
# (one per call, last value repeats if exhausted) and a fake `sleep` that records how many times
# it was asked to wait, so the retry/backoff behaviour is actually exercised rather than assumed.
run_with_sequence() { # sequence (space-separated shas/empties, "" for a failed/empty read)
  local seq="$1" idxfile
  idxfile="$(mktemp)"; echo 0 > "$idxfile"
  REPO="jonespr1/example" PR_NUMBER="99" IDXFILE="$idxfile" \
  bash -c '
    '"$SRC"'
    declare -a SEQ=('"$(printf '"%s" ' $seq)"')
    SLEEP_CALLS=0
    # gh (and therefore this whole function) is invoked from resolve_head_sha via a $(...)
    # command substitution, which forks a subshell - an in-memory IDX would reset on every
    # call instead of advancing, silently testing only SEQ[0] forever. A file survives the
    # fork, so the sequence actually advances call to call.
    gh() {
      local idx v
      idx="$(cat "$IDXFILE")"
      v="${SEQ[$idx]:-${SEQ[-1]}}"
      [ "$idx" -lt "$((${#SEQ[@]}-1))" ] && echo "$((idx+1))" > "$IDXFILE"
      printf "%s" "$v"
    }
    sleep() { SLEEP_CALLS=$((SLEEP_CALLS+1)); }
    resolve_head_sha
    echo "|sleeps=$SLEEP_CALLS" >&2
  ' 2>/tmp/head_sha_test_stderr
  rm -f "$idxfile"
}

check() { # desc sequence want_sha want_min_sleeps
  local desc="$1" seq="$2" want="$3" want_sleeps="$4" got got_sleeps
  got="$(run_with_sequence "$seq")"
  got_sleeps="$(grep -o 'sleeps=[0-9]*' /tmp/head_sha_test_stderr | cut -d= -f2)"
  if [ "$got" != "$want" ]; then
    fail "$desc (got sha='$got' want='$want')"; return
  fi
  if [ "$got_sleeps" -lt "$want_sleeps" ]; then
    fail "$desc (got $got_sleeps sleep(s), want at least $want_sleeps - not actually retrying)"; return
  fi
  ok "$desc"
}

SHA_OLD='01f07682665f31c5606894d20a183aefca29f6ba'
SHA_NEW='e287ed979b87c4c4a3c5abef1f8fda82c93ebb4c'

# --- The regression this guards ------------------------------------------------------------
# Exactly the observed sequence: stale-then-correct. A version that trusts the first read
# (the pre-fix behaviour) returns SHA_OLD here with zero sleeps - this is the case that cost
# marketing-os#51 a full round.
check 'stale-then-correct: waits and returns the real head, not the first (stale) read' \
      "$SHA_OLD $SHA_NEW $SHA_NEW" "$SHA_NEW" 1

# --- Normal behaviour must be preserved -----------------------------------------------------
# The common case: the head is already stable, so two reads agree immediately.
check 'stable from the first read: still confirms with a second read before trusting it' \
      "$SHA_NEW $SHA_NEW" "$SHA_NEW" 1

# --- Bounded retries, never hangs or crashes ------------------------------------------------
# Every read differs (a genuinely fast-moving PR, or a persistent API problem) - must still
# terminate and return something, using its full retry budget rather than giving up early.
check 'never stabilises: exhausts retries and returns the last read rather than hanging' \
      "$SHA_OLD a2222222222222222222222222222222222222 a3333333333333333333333333333333333333 $SHA_NEW" \
      "$SHA_NEW" 3

# Every read empty (API fully down) - must not treat two empty reads as agreement.
check 'repeated empty reads are never treated as a confirmed match' \
      " " "" 3

rm -f /tmp/head_sha_test_stderr

[ "$fails" -eq 0 ] && echo "All HEAD_SHA resolution tests passed." || echo "Some HEAD_SHA resolution tests FAILED." >&2
exit "$fails"
