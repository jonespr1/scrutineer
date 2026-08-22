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

# --- The built-in binary/generated skip list -------------------------------------------------------
# Separate from DIFF_EXCLUDE: this list ships on by default and is what stops a lockfile's FULL
# CONTENT reaching the model. It read as "lockfiles are handled" while missing npm's - which is named
# package-lock.json and so does not match *.lock. The estate is npm, so in practice the most common
# lockfile of all was being sent in full on every dependency PR, exhausting CONTEXT_BUDGET (dropping
# real changed files from context) and driving reviewers into timeouts and output-limit failures.
# Extracted from the workflow so the list under test is the one that ships.
SKIP_CASE="$(grep -o 'case "\$f" in [^)]*)' "$WF" | head -1)"
[ -n "$SKIP_CASE" ] || { echo "FAIL: could not extract the context skip list from $WF" >&2; exit 1; }
skips() { # $1 = path -> "skip"/"send"
  eval "case \"$1\" in ${SKIP_CASE#case \"\$f\" in } echo skip ;; *) echo send ;; esac"
}
skip_is() { # description  path  expected
  local got; got="$(skips "$2")"
  if [ "$got" = "$3" ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n        path=%s got=%s want=%s\n' "$1" "$2" "$got" "$3"; fails=1; fi
}
skip_is 'npm lockfile is not sent in full'    package-lock.json    skip
skip_is 'pnpm lockfile is not sent in full'   pnpm-lock.yaml       skip
skip_is 'npm shrinkwrap is not sent in full'  npm-shrinkwrap.json  skip
skip_is 'yarn lockfile still skipped'         yarn.lock            skip
skip_is 'cargo lockfile still skipped'        Cargo.lock           skip
skip_is 'binary assets still skipped'         logo.png             skip
# The guard that matters most: the list must not start swallowing source.
skip_is 'source is still sent'                src/app.ts           send
skip_is 'config json is still sent'           tsconfig.json        send
skip_is 'a file merely containing "lock"'     src/lockManager.ts   send

# --- The withheld-paths PROMPT block -------------------------------------------------------------
# Extracted separately, because it lives further down the workflow than the filter block above.
#
# Why it needs its own coverage: this block is the ONLY thing that tells the MODEL a file was
# withheld. Before it existed, EXCL_NOTE reached the posted comment and the reviewer was told
# nothing - it saw a diff with no lockfile in it and had to infer, which is the "misled by absence"
# failure the whole feature exists to close, aimed at the reviewer instead of the reader. The filter
# tests above pass whether or not this block is present, so without this the fix for that finding
# was itself unguarded. (minimax-m3, #26.)
# There are TWO `if [ -n "$EXCLUDED_PATHS" ]` blocks in the workflow - the earlier one logs the
# filter result - so a plain awk range would concatenate both and drag a log line into the prompt.
# Buffer each range and keep only the one that builds the prompt.
PSRC="$(awk '
  /^          if \[ -n "\$EXCLUDED_PATHS" \]; then$/ { inblk = 1; buf = ""; }
  inblk { buf = buf $0 "\n" }
  inblk && /^          fi$/ { if (buf ~ /deliberately withheld/) printf "%s", buf; inblk = 0 }
' "$WF" | sed 's/^          //')"
[ -n "$PSRC" ]                                       || bad "no EXCLUDED_PATHS prompt block"
printf '%s' "$PSRC" | grep -q 'DID change'           || bad "prompt block missing the 'DID change' claim"
printf '%s\n' "$PSRC" | bash -n 2>/dev/null          || bad "prompt block is not valid bash"

prompt_with() { # $1 = EXCLUDED_PATHS value -> the resulting PROMPT
  EXCLUDED_PATHS="$1" bash -c '
    PROMPT="BASE PROMPT TEXT"
    '"$PSRC"'
    printf "%s" "$PROMPT"'
}
p_has() { # description  excluded_paths  substring_that_must_appear
  local got; got="$(prompt_with "$2")"
  case "$got" in *"$3"*) printf 'ok    %s\n' "$1" ;;
    *) printf 'FAIL  %s\n        want substring=%s\n        got=%s\n' "$1" "$3" "$got"; fails=1 ;;
  esac
}
p_hasnot() { # description  excluded_paths  substring_that_must_NOT_appear
  local got; got="$(prompt_with "$2")"
  case "$got" in *"$3"*) printf 'FAIL  %s\n        unwanted substring=%s\n        got=%s\n' "$1" "$3" "$got"; fails=1 ;;
    *) printf 'ok    %s\n' "$1" ;;
  esac
}

EXCL_TWO='package-lock.json
benchmark/results/r1/raw/a.json'

# The paths themselves must reach the model - a note saying "some files were withheld" without
# naming them would leave the model unable to tell WHICH absences are meaningful.
p_has    'withheld paths are named in the prompt'    "$EXCL_TWO" 'package-lock.json'
p_has    'every withheld path is named, not just one' "$EXCL_TWO" 'benchmark/results/r1/raw/a.json'
p_has    'the base prompt survives'                  "$EXCL_TWO" 'BASE PROMPT TEXT'

# The three load-bearing phrases. A future edit that softens any of them re-opens the finding this
# block was written for, and nothing else in the suite would notice.
p_has    'states the files DID change'               "$EXCL_TWO" 'They DID change in'
p_has    'and that the claim is about THIS PR'        "$EXCL_TWO" 'this PR. Do not infer'
p_has    'forbids inferring from absence'            "$EXCL_TWO" 'Do not infer anything from their absence'
p_has    'forbids reporting them as unchanged'       "$EXCL_TWO" 'do not report them as unchanged'

# Off by default: with nothing excluded the prompt must be byte-identical to what it was before this
# feature existed, or every repo on @v1 pays for tokens describing an empty list.
p_hasnot 'no exclusions: no withheld block at all'   ''          'deliberately withheld'
if [ "$(prompt_with '')" = "BASE PROMPT TEXT" ]; then
  ok_unchanged=1; printf 'ok    %s\n' 'no exclusions: prompt is unchanged'
else
  printf 'FAIL  %s\n        got=%s\n' 'no exclusions: prompt is unchanged' "$(prompt_with '')"; fails=1
fi

[ "$fails" -eq 0 ] && echo "All exclude tests passed." || echo "Some exclude tests FAILED." >&2
exit "$fails"
