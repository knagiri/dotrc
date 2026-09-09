#!/usr/bin/env bash
# Functional tests for bin/gh-issue-file. A gh stub records its argv (one
# element per bracketed line) so we can assert both what the wrapper asks gh to
# do and -- for the dedup gate -- that it does NOT reach `gh issue create` at
# all. No test framework; run with bash.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
bindir="$here/../bin"
fail=0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A body that satisfies every heading the templates require.
full_body="$tmp/full.md"
cat >"$full_body" <<'BODY'
## やること（WHAT）
something
## 設計（HOW）
somehow
## 受け入れ確認
someproof
## 由来
somewhere
BODY

# Same body with one required heading removed.
missing_body="$tmp/missing.md"
grep -v '^## 受け入れ確認$' "$full_body" >"$missing_body"

# gh stub: records argv, and for `issue list` prints the candidate fixture. The
# stub does not implement --jq, so GH_LIST_TSV holds what gh would print *after*
# its --jq ran -- the tab-separated number/state/kind/title lines the wrapper
# consumes (same convention as the gh-await-reviews stub in gh-wrappers.test.sh).
stubdir="$tmp/stub"; mkdir -p "$stubdir"
cat >"$stubdir/gh" <<'STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$@" >>"$GH_ARGS_FILE"
case "$1 ${2:-}" in
  "issue list") printf '%s' "${GH_LIST_TSV:-}" ;;
  "issue create") echo "https://github.com/o/r/issues/1" ;;
esac
exit 0
STUB
chmod +x "$stubdir/gh"

run() {  # run gh-issue-file with a fresh argv log; echoes nothing, sets $rc
  : >"$tmp/args"
  env GH_ARGS_FILE="$tmp/args" GH_LIST_TSV="${GH_LIST_TSV:-}" \
    PATH="$stubdir:$PATH" "$bindir/gh-issue-file" "$@" >"$tmp/out" 2>"$tmp/err"
  rc=$?
}

# Case G: an unknown --kind is rejected before anything else happens.
run --kind nope --title t --body-file "$full_body"
if [ "$rc" -eq 1 ] && ! grep -q '^\[issue\]$' "$tmp/args"; then
  echo "ok: unknown --kind exits 1 without calling gh"
else echo "FAIL: unknown --kind rc=$rc"; fail=1; fi

# Case F: an unknown flag is rejected rather than passed through to gh.
run --kind task --title t --body-file "$full_body" --label foo
if [ "$rc" -eq 1 ] && ! grep -qxF '[--label]' "$tmp/args"; then
  echo "ok: unknown flag exits 1 and does not leak to gh"
else echo "FAIL: unknown flag rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# Case A: a body missing one required heading is rejected, and the message names
# the heading that is missing (so the caller can fix it without guessing).
run --kind task --title t --body-file "$missing_body"
if [ "$rc" -eq 1 ] && grep -q '受け入れ確認' "$tmp/err"; then
  echo "ok: missing heading exits 1 and names the heading"
else echo "FAIL: missing heading rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

# A complete body passes validation.
run --kind task --title t --body-file "$full_body"
if [ "$rc" -eq 0 ]; then
  echo "ok: complete body passes validation"
else echo "FAIL: complete body rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

# Three existing agent tasks across two kinds. The dedup gate must show all of
# them regardless of the kind being filed: one session filing a harness idea as
# `task` and another as `harness` is exactly the duplication being prevented.
list_tsv="$(printf '%s\t%s\t%s\t%s\n' \
  12 OPEN   kind/harness 'worktree 委譲先で token が届かない' \
  7  CLOSED kind/harness 'rule のロード条件を doc 化する' \
  9  OPEN   kind/task    'picker に filter を足す')"

# The candidate query itself is part of the contract with gh: the scope is every
# agent task (not just this kind), capped at 200, and the projection is what the
# fixture above stands in for.
GH_LIST_TSV="$list_tsv" run --kind task --title t --body-file "$full_body"
if grep -qxF '[list]' "$tmp/args" \
  && grep -qxF '[agent-task]' "$tmp/args" \
  && grep -qxF '[--state]' "$tmp/args" && grep -qxF '[all]' "$tmp/args" \
  && grep -qxF '[200]' "$tmp/args" \
  && grep -qxF '[number,title,state,labels]' "$tmp/args" \
  && grep -qxF '[--jq]' "$tmp/args"; then
  echo "ok: candidate query covers every agent task with the expected projection"
else echo "FAIL: candidate query args=$(cat "$tmp/args")"; fail=1; fi

# Case B: candidates exist and --not-dup-of is absent -> gate, and crucially
# `gh issue create` is never reached.
if [ "$rc" -eq 2 ] \
  && grep -q '12' "$tmp/err" && grep -q '9' "$tmp/err" && grep -q '7' "$tmp/err" \
  && grep -q 'picker に filter' "$tmp/err" \
  && ! grep -qxF '[create]' "$tmp/args"; then
  echo "ok: candidates without --not-dup-of exit 2 and skip issue create"
else echo "FAIL: dedup gate rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

# Case B2: the gate prints a ready-to-paste CSV covering every candidate.
if grep -q -- '--not-dup-of 7,9,12' "$tmp/err"; then
  echo "ok: gate prints the full --not-dup-of CSV"
else echo "FAIL: gate CSV missing from err=$(cat "$tmp/err")"; fail=1; fi

# Case D: --not-dup-of covering only part of the candidates still gates. This is
# the case that catches issues filed after the caller last read the list.
GH_LIST_TSV="$list_tsv" run --kind task --title t --body-file "$full_body" --not-dup-of 7,9
if [ "$rc" -eq 2 ] && ! grep -qxF '[create]' "$tmp/args"; then
  echo "ok: partial --not-dup-of still exits 2"
else echo "FAIL: partial --not-dup-of rc=$rc"; fail=1; fi

# Case C: --not-dup-of covering every candidate passes the gate.
GH_LIST_TSV="$list_tsv" run --kind task --title t --body-file "$full_body" --not-dup-of 7,9,12
if [ "$rc" -eq 0 ]; then
  echo "ok: full --not-dup-of passes the gate"
else echo "FAIL: full --not-dup-of rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

# Case E: with no existing agent task there is nothing to compare against, so
# gating would be an assertion about an absence -- it would pass vacuously on the
# very first issue. No candidates means no gate.
GH_LIST_TSV='' run --kind task --title t --body-file "$full_body"
if [ "$rc" -eq 0 ]; then
  echo "ok: empty candidate list does not gate"
else echo "FAIL: empty list rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

exit "$fail"
