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
# (one per call, last value repeats if the sequence is exhausted) and a fake `sleep` that
# records how many times it was asked to wait, so the retry/backoff behaviour is actually
# exercised rather than assumed. Sequence elements are passed as separate arguments (not a
# single space-joined string) and shell-quoted with `%q`, so an intentionally EMPTY element
# (simulating a failed/empty read) survives - a space-joined string would silently drop it via
# word-splitting.
# idxfile/errfile are created by the CALLER (check(), below) and passed in by path, not
# created here: this function is invoked as `got="$(run_with_sequence ...)"`, a command
# substitution that forks a subshell, and a plain variable assigned inside it (as LAST_STDERR_FILE
# once was here) cannot escape back to check() - the same trap the IDXFILE/gh() comment above
# already works around for a different variable. Creating both files in check()'s own shell
# sidesteps the problem entirely instead of reintroducing it one level up.
run_with_sequence() { # idxfile errfile seq_elem...; "" is a legitimate empty read
  local idxfile="$1" errfile="$2"; shift 2
  echo 0 > "$idxfile"
  local seqlit
  seqlit="$(printf '%q ' "$@")"
  REPO="jonespr1/example" PR_NUMBER="99" IDXFILE="$idxfile" \
  bash -c '
    set -euo pipefail
    '"$SRC"'
    declare -a SEQ=('"$seqlit"')
    SLEEP_CALLS=0
    # gh (and therefore this whole function) is invoked from resolve_head_sha via a $(...)
    # command substitution, which forks a subshell - an in-memory IDX would reset on every
    # call instead of advancing, silently testing only SEQ[0] forever. A file survives the
    # fork, so the sequence actually advances call to call.
    gh() {
      local idx v
      idx="$(cat "$IDXFILE")"
      # Plain "-", not ":-": an in-bounds element that is itself empty (a deliberate empty-read
      # test case) must stay empty. ":-" treats "set but empty" the same as "unset" and would
      # silently replace it with the last element, defeating the whole point of testing a
      # mid-sequence empty read.
      v="${SEQ[$idx]-${SEQ[-1]}}"
      [ "$idx" -lt "$((${#SEQ[@]}-1))" ] && echo "$((idx+1))" > "$IDXFILE"
      printf "%s" "$v"
    }
    sleep() { SLEEP_CALLS=$((SLEEP_CALLS+1)); }
    resolve_head_sha
    echo "|sleeps=$SLEEP_CALLS" >&2
  ' 2>"$errfile"
}

check() { # desc want want_min_sleeps seq_elem...
  local desc="$1" want="$2" want_sleeps="$3"; shift 3
  local got got_sleeps idxfile errfile
  # Fresh files per check(), not a fixed shared path: two concurrent invocations of this script
  # (a developer running it in two shells, or a future CI matrix splitting test files across
  # jobs) would otherwise truncate and read each other's stderr - the same stale-data class the
  # got_sleeps default fix below closed, resurfacing under concurrency instead of a broken marker.
  idxfile="$(mktemp)"; errfile="$(mktemp)"
  got="$(run_with_sequence "$idxfile" "$errfile" "$@")"
  # Default to 0, not empty: an empty got_sleeps (the |sleeps= marker never reaching the file)
  # must fail the comparison below rather than making `[ -lt ]` error out silently and the test
  # print "ok" with the sleep assertion never actually checked.
  got_sleeps="$(grep -o 'sleeps=[0-9]*' "$errfile" | cut -d= -f2)"
  got_sleeps="${got_sleeps:-0}"
  rm -f "$idxfile" "$errfile"
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
      "$SHA_NEW" 1 "$SHA_OLD" "$SHA_NEW" "$SHA_NEW"

# A transient empty read (network blip) between two good-but-differing reads must not be
# mistaken for agreement, and must not derail recovery once real reads resume.
check 'stale, then a dropped read, then correct: still converges on the real head' \
      "$SHA_NEW" 3 "$SHA_OLD" "" "$SHA_NEW" "$SHA_NEW"

# --- Normal behaviour must be preserved -----------------------------------------------------
# The common case: the head is already stable, so two reads agree immediately.
check 'stable from the first read: still confirms with a second read before trusting it' \
      "$SHA_NEW" 1 "$SHA_NEW" "$SHA_NEW"

# --- Bounded retries, never hangs or crashes ------------------------------------------------
# Every read differs (a genuinely fast-moving PR, or a persistent API problem) - must still
# terminate and return something, using its full retry budget rather than giving up early.
check 'never stabilises: exhausts retries and returns the last read rather than hanging' \
      "$SHA_NEW" 3 \
      "$SHA_OLD" "a2222222222222222222222222222222222222" "a3333333333333333333333333333333333333" "$SHA_NEW"

# Every read empty (API fully down) - must not treat two empty reads as agreement.
check 'repeated empty reads are never treated as a confirmed match' \
      "" 3 "" "" "" ""

[ "$fails" -eq 0 ] && echo "All HEAD_SHA resolution tests passed." || echo "Some HEAD_SHA resolution tests FAILED." >&2
exit "$fails"
