#!/usr/bin/env bash
# Tests for DIFF_EXCLUDE - the path filter review.yml applies to the diff before the size cap.
#
# Same approach as the other suites: the block is extracted verbatim from the workflow rather than
# copied, so the test cannot drift from what ships. Nothing leaves the machine and no key is needed;
# a synthetic diff goes in and we assert on which sections survive.
#
# Why this needs tests: the filter's whole job is to decide what a paid reviewer never sees. A
# pattern that silently matches too much removes real code from review, and a pattern that silently
# matches too little leaves the truncation bug in place - and BOTH failures look like a normal,
# confident review. Nothing else in the pipeline would notice.
#
# Usage: tests/exclude_test.sh     (needs bash + awk + sed)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$HERE/../.github/workflows/review.yml"

# --- Extract the exclusion block ----------------------------------------------------------------
# Runs from `EXPATS=()` up to (not including) the `MAX=` line that begins the size cap.
SRC="$(awk '/^          EXPATS=\(\)$/,/^          MAX=200000$/' "$WF" | sed '$d' | sed 's/^          //')"
bad() { echo "FAIL: bad extraction of the DIFF_EXCLUDE block from $WF - $1" >&2; exit 1; }
[ -n "$SRC" ]                                     || bad "nothing matched (has the block moved?)"
printf '%s' "$SRC" | grep -q 'path_excluded'      || bad "no path_excluded function"
printf '%s' "$SRC" | grep -q 'EXCLUDED_PATHS'     || bad "no EXCLUDED_PATHS accumulation"
printf '%s\n' "$SRC" | bash -n 2>/dev/null        || bad "extracted text is not valid bash"

# --- A synthetic diff covering the shapes that matter --------------------------------------------
# Deliberately in GitHub's alphabetical order, with a generated file sitting between two code files:
# that ordering is exactly what caused the truncation this filter exists to prevent.
mk_diff() {
  for f in .github/workflows/ci.yml benchmark/results/r1/raw/a.json \
           benchmark/results/r1/raw/b.json package-lock.json src/app.ts tests/app_test.ts; do
    printf 'diff --git a/%s b/%s\nindex 1111111..2222222 100644\n--- a/%s\n+++ b/%s\n@@ -1 +1 @@\n-old line in %s\n+new line in %s\n' \
      "$f" "$f" "$f" "$f" "$f" "$f"
  done
}

run_filter() { # $1 = DIFF_EXCLUDE value -> prints surviving paths, one per line
  DIFF_EXCLUDE="$1" DIFF="$(mk_diff)" bash -c '
    { '"$SRC"'
    } >/dev/null
    printf "%s\n" "$DIFF" | sed -n "s|^diff --git a/.* b/||p"
  ' 2>/dev/null
}
run_note() { # $1 = DIFF_EXCLUDE value -> prints the note text
  DIFF_EXCLUDE="$1" DIFF="$(mk_diff)" bash -c '
    { '"$SRC"'
    } >/dev/null
    printf "%s" "$EXCL_NOTE"
  ' 2>/dev/null
}

fails=0
survives() { # description  exclude  expected_surviving_paths (comma-separated)
  local desc="$1" ex="$2" want="$3" got
  got="$(run_filter "$ex" | paste -sd, -)"
  if [ "$got" = "$want" ]; then printf 'ok    %s\n' "$desc"
  else printf 'FAIL  %s\n        exclude=%s\n        got =%s\n        want=%s\n' "$desc" "$ex" "$got" "$want"; fails=1; fi
}

ALL='.github/workflows/ci.yml,benchmark/results/r1/raw/a.json,benchmark/results/r1/raw/b.json,package-lock.json,src/app.ts,tests/app_test.ts'

# --- Off by default: every repo inherits this workflow, so an unset variable must change nothing --
survives 'unset changes nothing'            ''            "$ALL"
survives 'empty pattern list changes nothing' ',  ,'      "$ALL"

# --- Exact path ------------------------------------------------------------------------------------
survives 'exact path is dropped'            'package-lock.json' \
  '.github/workflows/ci.yml,benchmark/results/r1/raw/a.json,benchmark/results/r1/raw/b.json,src/app.ts,tests/app_test.ts'

# --- `*` crosses `/` - these are case globs, not gitignore ------------------------------------------
# The real-world case: 111 files under one directory. If `*` did not cross `/`, "dir/*" would match
# nothing nested and the filter would appear to work while dropping nothing.
survives 'directory glob covers nested files' 'benchmark/results/*' \
  '.github/workflows/ci.yml,package-lock.json,src/app.ts,tests/app_test.ts'

# --- Extension glob at any depth ---------------------------------------------------------------------
survives 'extension glob matches at any depth' '*.json' \
  '.github/workflows/ci.yml,src/app.ts,tests/app_test.ts'

# --- Several patterns, and whitespace around them ------------------------------------------------------
survives 'multiple patterns combine'        'package-lock.json,benchmark/results/*' \
  '.github/workflows/ci.yml,src/app.ts,tests/app_test.ts'
survives 'whitespace around patterns is trimmed' '  package-lock.json ,  benchmark/results/*  ' \
  '.github/workflows/ci.yml,src/app.ts,tests/app_test.ts'

# --- A pattern that matches nothing must drop nothing ------------------------------------------------
survives 'non-matching pattern is inert'    'does/not/exist/*' "$ALL"

# --- Excluding EVERYTHING must stop the run, not call the model with nothing --------------------------
# The workflow's "Empty diff" guard runs BEFORE this block, so it cannot catch this case: a pattern
# broad enough to match every changed file would otherwise leave an empty diff and continue into a
# paid model call, posting a baffled "I see no changes" review. The block exits 0 instead - nothing
# to review is a success. Note this means the `survives` helper sees no output for '*', so assert on
# the exit code and message rather than inferring it from an empty path list.
run_raw() { # $1 = DIFF_EXCLUDE -> prints "<exit code>|<stdout>"
  local out code
  out="$(DIFF_EXCLUDE="$1" DIFF="$(mk_diff)" bash -c '{ '"$SRC"'
    } 2>/dev/null' 2>/dev/null)"; code=$?
  printf '%s|%s' "$code" "$out"
}
raw_all="$(run_raw '*')"
case "$raw_all" in
  0\|*'nothing left to review'*) printf 'ok    %s\n' 'excluding everything exits 0 and says so' ;;
  *) printf 'FAIL  %s\n        got=%s\n' 'excluding everything exits 0 and says so' "$raw_all"; fails=1 ;;
esac
raw_some="$(run_raw 'package-lock.json')"
case "$raw_some" in
  *'nothing left to review'*) printf 'FAIL  %s\n' 'partial exclusion does not trip the guard'; fails=1 ;;
  *) printf 'ok    %s\n' 'partial exclusion does not trip the guard' ;;
esac

# --- The note: excluding files silently would be the same failure in a new coat ----------------------
note_has() { # description  exclude  substring
  local desc="$1" ex="$2" want="$3" got
  got="$(run_note "$ex")"
  case "$got" in *"$want"*) printf 'ok    %s\n' "$desc" ;;
    *) printf 'FAIL  %s\n        want substring=%s\n        got=%s\n' "$desc" "$want" "$got"; fails=1 ;;
  esac
}
note_has 'note counts the excluded files'   'benchmark/results/*' '2 changed file(s) were excluded'
note_has 'note names the variable'          'package-lock.json'   'DIFF_EXCLUDE'
[ -z "$(run_note '')" ] && printf 'ok    %s\n' 'no note when nothing is excluded' \
  || { printf 'FAIL  %s\n' 'no note when nothing is excluded'; fails=1; }

# --- Surviving sections must stay intact, not just their headers ---------------------------------------
body="$(DIFF_EXCLUDE='package-lock.json' DIFF="$(mk_diff)" bash -c '{ '"$SRC"'
  } >/dev/null
  printf "%s" "$DIFF"' 2>/dev/null)"
case "$body" in *'+new line in src/app.ts'*) printf 'ok    %s\n' 'kept sections retain their hunks' ;;
  *) printf 'FAIL  %s\n' 'kept sections retain their hunks'; fails=1 ;;
esac
case "$body" in *'package-lock.json'*) printf 'FAIL  %s\n' 'excluded section fully removed'; fails=1 ;;
  *) printf 'ok    %s\n' 'excluded section fully removed' ;;
esac

# --- The FULL-FILE CONTEXT side ------------------------------------------------------------------
# Excluding a file from the diff while still sending its full content would only half-fix the
# problem - and for a lockfile the content dwarfs the diff. The context loop calls the same
# path_excluded, so test the function directly, and separately assert the call site still exists:
# the function could keep passing its own tests while the loop quietly stopped calling it.
pe() { # $1 = DIFF_EXCLUDE, $2 = path -> "yes"/"no"
  DIFF_EXCLUDE="$1" DIFF="" bash -c '{ '"$SRC"'
    } >/dev/null 2>&1
    path_excluded "'"$2"'" && echo yes || echo no' 2>/dev/null
}
pe_is() { # description  exclude  path  expected
  local got; got="$(pe "$2" "$3")"
  if [ "$got" = "$4" ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n        path=%s exclude=%s got=%s want=%s\n' "$1" "$3" "$2" "$got" "$4"; fails=1; fi
}
pe_is 'context: lockfile excluded'      'package-lock.json'   'package-lock.json'            yes
pe_is 'context: nested under a dir glob' 'benchmark/results/*' 'benchmark/results/r1/raw/a.json' yes
pe_is 'context: code file kept'         'package-lock.json'   'src/app.ts'                   no
pe_is 'context: nothing excluded when unset' ''               'package-lock.json'            no

if grep -q 'path_excluded "$f" && continue' "$WF"; then
  printf 'ok    %s\n' 'context loop still calls path_excluded'
else
  printf 'FAIL  %s\n' 'context loop no longer calls path_excluded - exclusions would not reach CONTEXT_BUDGET'; fails=1
fi

[ "$fails" -eq 0 ] && echo "All exclude tests passed." || echo "Some exclude tests FAILED." >&2
exit "$fails"
