#!/usr/bin/env bash
# Tests for review.yml's fetch_diff() and its set -e-safe call-site pattern.
#
# Found in review of #31 (glm): `DIFF="$(fetch_diff)"; drc=$?` looks correct but is NOT set -e
# safe. Under this run block's `set -euo pipefail`, a failing command substitution inside a
# plain assignment aborts the script on that exact line - "drc=$?" on the next line never runs,
# and the ::error:: diagnostic that depends on it becomes unreachable dead code on the one path
# it exists to explain. The fix is "drc=0; DIFF=\"\$(fetch_diff)\" || drc=\$?", where the "||"
# is what set -e exempts. This test extracts fetch_diff() verbatim, drives it under set -e
# through the SHIPPED call-site pattern with a `gh` that always fails, and separately greps
# review.yml itself for the unsafe pattern - a correct function behind an unsafe call site is
# still the bug glm found.
#
# Usage: tests/fetch_diff_test.sh     (needs bash)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$HERE/../.github/workflows/review.yml"

SRC="$(awk '/^          fetch_diff\(\) \{$/,/^          \}$/' "$WF" | sed 's/^          //')"
bad() { echo "FAIL: bad extraction of fetch_diff() from $WF - $1" >&2; exit 1; }
[ -n "$SRC" ]                                 || bad "nothing matched (has the function moved?)"
printf '%s' "$SRC" | grep -q 'gh api'         || bad "no gh api call"
[ "$(printf '%s' "$SRC" | tail -n1)" = '}' ]  || bad "does not end at the closing brace (truncated?)"
printf '%s\n' "$SRC" | bash -n 2>/dev/null    || bad "extracted text is not valid bash"

fails=0
ok()  { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=1; }

# --- Pin the call sites, not just the function -----------------------------------------------
# A correct fetch_diff() behind an unsafe call site is still the bug: this greps the shipped
# file itself for the pattern that broke, so a regression is caught even if someone "fixes" the
# call site back to the unsafe form without touching the function. Comment lines are excluded -
# the explanatory comment above the fix quotes the old unsafe form as prose, which would
# otherwise self-match and false-fail this check.
UNSAFE_SITES="$(grep -v '^\s*#' "$WF" | grep -c '"\$(fetch_diff)"; drc=\$?' || true)"
if [ "$UNSAFE_SITES" -eq 0 ]; then
  ok "no unsafe ';  drc=\$?' call-site pattern in review.yml"
else
  fail "found $UNSAFE_SITES unsafe 'DIFF=\"\$(fetch_diff)\"; drc=\$?' call site(s) - fetch_diff's error path is unreachable dead code under this file's own set -e"
fi

CALL_SITES="$(grep -v '^\s*#' "$WF" | grep -c 'DIFF="\$(fetch_diff)" || drc=\$?' || true)"
if [ "$CALL_SITES" -ge 2 ]; then
  ok "both fetch_diff call sites use the set -e-safe '|| drc=\$?' form"
else
  fail "expected at least 2 safe call sites, found $CALL_SITES - has one reverted to the unsafe form?"
fi

# --- Behavioural: the shipped pattern actually reaches the error branch -----------------------
# Drive the extracted function, under set -e, through the SHIPPED call-site pattern with a fake
# `gh` that always fails - proving the diagnostic runs rather than the script silently aborting
# one line early (which prints nothing beyond the retry echoes and exits 1 anyway, so this bug
# is invisible unless you go looking for the missing ::error:: line).
run_call_site() {
  REPO="jonespr1/example" PR_NUMBER="99" \
  bash -c '
    set -euo pipefail
    '"$SRC"'
    gh() { return 1; }
    sleep() { :; }
    drc=0; DIFF="$(fetch_diff)" || drc=$?
    echo "reached:drc=$drc"
    if [ "$drc" -ne 0 ]; then
      echo "error_block_ran"
      exit 7
    fi
    echo "unexpected_success"
  ' 2>/dev/null
}

out="$(run_call_site)"; rc=$?
if printf '%s' "$out" | grep -q '^reached:drc=1$' \
   && printf '%s' "$out" | grep -q '^error_block_ran$' \
   && [ "$rc" -eq 7 ]; then
  ok 'shipped call-site pattern survives a failing fetch_diff under set -e and reaches the error branch'
else
  fail "shipped call-site pattern did not behave as expected (out='$out' rc=$rc)"
fi

[ "$fails" -eq 0 ] && echo "All fetch_diff tests passed." || echo "Some fetch_diff tests FAILED." >&2
exit "$fails"
