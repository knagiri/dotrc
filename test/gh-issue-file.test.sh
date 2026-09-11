#!/usr/bin/env bash
# Functional tests for bin/gh-issue-file. A gh stub records its argv (one
# element per bracketed line) so we can assert both what the wrapper asks gh to
# do and -- for the dedup gate -- that it does NOT reach `gh issue create` at
# all. No test framework; run with bash.
#
# gh is reached through `mise exec -C <root> -- gh` (bin/lib/gh-mise.sh), so a
# mise stub sits next to the gh stub and moves gh's cwd the same way mise does.
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
  "issue list")
    [ -z "${GH_EXIT_LIST:-}" ] || exit "$GH_EXIT_LIST"
    printf '%s' "${GH_LIST_TSV:-}" ;;
  "issue create")
    # Read the body through the path gh was actually handed, from the cwd gh was
    # actually run in -- that is the whole point of the relative --body-file
    # case below, so the stub must not shortcut it.
    if [ -n "${GH_BODY_OUT:-}" ]; then
      prev=""
      for a in "$@"; do
        [ "$prev" != "--body-file" ] || cat -- "$a" >"$GH_BODY_OUT" 2>/dev/null || echo UNREADABLE >"$GH_BODY_OUT"
        prev="$a"
      done
    fi
    [ -z "${GH_EXIT_CREATE:-}" ] || exit "$GH_EXIT_CREATE"
    echo "https://github.com/o/r/issues/1" ;;
esac
exit 0
STUB
chmod +x "$stubdir/gh"

# Stands in for `mise exec -C <dir> -- <cmd> [args...]`, which every gh call now
# goes through (bin/lib/gh-mise.sh). Without it these tests would fall through
# to the real mise on PATH. It moves gh's cwd exactly as mise does, which is
# what the relative --body-file case below depends on.
cat >"$stubdir/mise" <<'STUB'
#!/usr/bin/env bash
dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    -C) dir="$2"; shift 2 ;;
    --) shift; break ;;
    *)  shift ;;
  esac
done
cd "${dir:-.}" && exec "$@"
STUB
chmod +x "$stubdir/mise"

run() {  # run gh-issue-file with a fresh argv log; echoes nothing, sets $rc
  : >"$tmp/args"
  env GH_ARGS_FILE="$tmp/args" GH_LIST_TSV="${GH_LIST_TSV:-}" \
    PATH="$stubdir:$PATH" "$bindir/gh-issue-file" "$@" >"$tmp/out" 2>"$tmp/err"
  rc=$?
}

# Case G: an unknown --kind is rejected before anything else happens. The
# message is asserted (not just rc/no-gh-call) because rc=1-without-a-gh-call
# is also what an unrelated failure path yields (e.g. the whitelist itself
# missing) -- asserting the wrapper's own text is what actually pins the
# whitelist check down to this case (it is not just falling through to the
# template-file-not-found branch, which also ends at rc=1 with no gh call).
run --kind nope --title t --body-file "$full_body"
if [ "$rc" -eq 1 ] && ! grep -q '^\[issue\]$' "$tmp/args" \
  && grep -q 'must be harness, bug or task' "$tmp/err"; then
  echo "ok: unknown --kind exits 1 without calling gh"
else echo "FAIL: unknown --kind rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

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

# Case C: --not-dup-of covering every candidate passes the gate and files the
# issue with exactly the three fixed labels -- nothing more, nothing less.
GH_LIST_TSV="$list_tsv" run --kind harness --title "t" --body-file "$full_body" --not-dup-of 7,9,12
if [ "$rc" -eq 0 ] \
  && grep -qxF '[create]' "$tmp/args" \
  && grep -qxF '[agent-task]' "$tmp/args" \
  && grep -qxF '[kind/harness]' "$tmp/args" \
  && grep -qxF '[status/triage]' "$tmp/args" \
  && ! grep -qxF '[status/ready]' "$tmp/args" \
  && grep -q 'issues/1' "$tmp/out"; then
  echo "ok: full --not-dup-of files the issue with the three fixed labels"
else echo "FAIL: create rc=$rc args=$(cat "$tmp/args") out=$(cat "$tmp/out")"; fail=1; fi

# Case E: with no existing agent task there is nothing to compare against, so
# gating would be an assertion about an absence -- it would pass vacuously on the
# very first issue. No candidates means no gate.
GH_LIST_TSV='' run --kind task --title t --body-file "$full_body"
if [ "$rc" -eq 0 ]; then
  echo "ok: empty candidate list does not gate"
else echo "FAIL: empty list rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

# Case H: a body whose heading lines carry trailing whitespace still passes.
# The wrapper strips trailing whitespace off body lines before comparing
# against the template's headings (`sed -e 's/[ \t]*$//'`); without that strip
# a stray trailing space would be misread as a missing section.
trailing_ws_body="$tmp/trailing_ws.md"
sed 's/^## .*/&  /' "$full_body" >"$trailing_ws_body"
run --kind task --title t --body-file "$trailing_ws_body"
if [ "$rc" -eq 0 ]; then
  echo "ok: trailing whitespace on body heading lines does not fail validation"
else echo "FAIL: trailing ws body rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

# Case I: same guard, but on the *template* side. required_headings() strips
# trailing whitespace off template heading lines with `sub(/[ \t]+$/, "")`
# before printing them; without that strip a trailing space baked into the
# template would make every real body -- which naturally has none -- look like
# it is missing that heading. This needs its own throwaway git repo, since the
# wrapper locates the template via `git rev-parse --show-toplevel` run from the
# caller's cwd (same convention as the fixture repos in git-reap-gone.test.sh).
tmpl_repo="$tmp/tmplrepo"
mkdir -p "$tmpl_repo/.github/ISSUE_TEMPLATE"
git init -q "$tmpl_repo"
cat >"$tmpl_repo/.github/ISSUE_TEMPLATE/task.md" <<'TMPL'
---
name: task
---
## やること（WHAT）
body
TMPL
# Written via a temp file + mv rather than `sed -i`, for portability with
# BSD/macOS sed (which requires a suffix argument to -i) -- matches the Case H
# pattern above. Not writing the trailing whitespace as a source literal keeps
# the same intent as Case H's sed call.
sed 's/^## .*/&  /' "$tmpl_repo/.github/ISSUE_TEMPLATE/task.md" >"$tmp/tmpl.tmp"
mv "$tmp/tmpl.tmp" "$tmpl_repo/.github/ISSUE_TEMPLATE/task.md"
tmpl_body="$tmp/tmpl_body.md"
cat >"$tmpl_body" <<'BODY'
## やること（WHAT）
something
BODY
: >"$tmp/args"
( cd "$tmpl_repo" && env GH_ARGS_FILE="$tmp/args" GH_LIST_TSV='' \
    PATH="$stubdir:$PATH" "$bindir/gh-issue-file" --kind task --title t \
    --body-file "$tmpl_body" >"$tmp/out" 2>"$tmp/err" )
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "ok: trailing whitespace on template heading lines does not fail validation"
else echo "FAIL: trailing ws template rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

# Case J: a malformed --not-dup-of is rejected before gh is called at all
# (neither `issue list` nor `issue create` -- the format check runs ahead of
# the dedup gate).
run --kind task --title t --body-file "$full_body" --not-dup-of abc
if [ "$rc" -eq 1 ] && [ ! -s "$tmp/args" ]; then
  echo "ok: non-numeric --not-dup-of exits 1 without calling gh"
else echo "FAIL: non-numeric --not-dup-of rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

run --kind task --title t --body-file "$full_body" --not-dup-of '7,'
if [ "$rc" -eq 1 ] && [ ! -s "$tmp/args" ]; then
  echo "ok: trailing-comma --not-dup-of exits 1 without calling gh"
else echo "FAIL: trailing-comma --not-dup-of rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# Case K: a --body-file that does not exist is rejected without calling gh.
# The message is asserted (not just rc/no-gh-call) because dropping the `[ -r
# "$body_file" ]` guard still yields rc=1 with no gh call by accident -- the
# unreadable file then makes every heading in required_headings() look
# "missing" via a failing `sed` inside the comparison loop, which is a much
# noisier and less useful failure than the wrapper's own message.
run --kind task --title t --body-file "$tmp/does-not-exist.md"
if [ "$rc" -eq 1 ] && [ ! -s "$tmp/args" ] \
  && grep -q 'cannot read body file' "$tmp/err"; then
  echo "ok: missing --body-file exits 1 with its own message and no gh call"
else echo "FAIL: missing --body-file rc=$rc args=$(cat "$tmp/args") err=$(cat "$tmp/err")"; fail=1; fi

# Case L: candidates at the --limit cap warn that the list may be truncated,
# even when --not-dup-of covers every number gh actually returned -- a full
# CSV over a truncated list still cannot rule out candidates gh never showed.
limit=200
rows=()
for i in $(seq 1 "$limit"); do
  rows+=("$(printf '%s\t%s\t%s\t%s' "$i" OPEN kind/task "t$i")")
done
list_tsv_limit="$(printf '%s\n' "${rows[@]}")"
csv_limit="$(seq -s, 1 "$limit")"
GH_LIST_TSV="$list_tsv_limit" run --kind task --title t --body-file "$full_body" \
  --not-dup-of "$csv_limit"
if [ "$rc" -eq 0 ] && grep -q '上限' "$tmp/err"; then
  echo "ok: candidate list at the limit warns about possible truncation"
else echo "FAIL: limit warning rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

# Case M: --not-dup-of membership is tested on a comma-fenced string
# (`case ",$not_dup_of," in *",$n,"*)`) precisely so that naming candidate #12
# does not also count #1 and #2 as reviewed by substring accident (unfenced,
# "1" and "2" are both substrings of "12"). Candidates 1, 2 and 12 with only
# 12 named must still gate -- #1 and #2 remain unreviewed -- and must never
# reach `gh issue create`.
list_tsv_fence="$(printf '%s\t%s\t%s\t%s\n' \
  1  OPEN kind/task 't1' \
  2  OPEN kind/task 't2' \
  12 OPEN kind/task 't12')"
GH_LIST_TSV="$list_tsv_fence" run --kind task --title t --body-file "$full_body" \
  --not-dup-of 12
if [ "$rc" -eq 2 ] && ! grep -qxF '[create]' "$tmp/args"; then
  echo "ok: --not-dup-of 12 does not also cover candidates 1 and 2 by substring"
else echo "FAIL: comma-fencing rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# --- Case N: a relative --body-file survives the cwd move -------------------
# gh now runs with the repo root as its cwd (mise exec -C "$root"), not the
# caller's, so a relative --body-file handed straight to gh would be resolved
# against the root. The wrapper absolutises it first. The fixture makes the
# failure mode visible rather than merely absent: a DECOY body.md sits at the
# root, so dropping the absolutisation does not error out -- it quietly files
# the wrong file, which is exactly the silent class this guards.
relrepo="$tmp/relrepo"
mkdir -p "$relrepo/.github/ISSUE_TEMPLATE" "$relrepo/sub"
git init -q "$relrepo"
cat >"$relrepo/.github/ISSUE_TEMPLATE/task.md" <<'TMPL'
---
name: task
---
## やること（WHAT）
TMPL
printf '## やること（WHAT）\nDECOY-BODY\n' >"$relrepo/body.md"
printf '## やること（WHAT）\nREAL-BODY\n' >"$relrepo/sub/body.md"

relrun() {  # relrun <bindir>; runs from $relrepo/sub with a RELATIVE --body-file
  : >"$tmp/args"; : >"$tmp/body"
  ( cd "$relrepo/sub" && env GH_ARGS_FILE="$tmp/args" GH_LIST_TSV='' \
      GH_BODY_OUT="$tmp/body" PATH="$stubdir:$PATH" \
      "$1/gh-issue-file" --kind task --title t --body-file body.md ) \
    >"$tmp/out" 2>"$tmp/err"
  rc=$?
}

relrun "$bindir"
if [ "$rc" -eq 0 ] && grep -q 'REAL-BODY' "$tmp/body"; then
  echo "ok: a relative --body-file still reaches gh as the caller's file, not the repo root's"
else echo "FAIL: relative --body-file rc=$rc body=$(cat "$tmp/body" 2>/dev/null) err=$(cat "$tmp/err")"; fail=1; fi

# Discrimination (evidence-over-guesswork §4): with the absolutisation removed
# the same run must file the DECOY. The tagged line is stripped the way
# test/deploy.test.sh builds its guard-less control, and `cmp` keeps the check
# from rotting into a no-op if the tag ever disappears.
mutantbin="$tmp/mutantbin"
rm -rf "$mutantbin"; mkdir -p "$mutantbin"
cp -a "$bindir/." "$mutantbin/"
grep -v 'abs-body-file@dotrc' "$bindir/gh-issue-file" >"$mutantbin/gh-issue-file"
chmod +x "$mutantbin/gh-issue-file"
if cmp -s "$bindir/gh-issue-file" "$mutantbin/gh-issue-file"; then
  echo "FAIL: the mutant is identical to gh-issue-file; the check above is a no-op"; fail=1
fi
relrun "$mutantbin"
if grep -q 'DECOY-BODY' "$tmp/body"; then
  echo "ok: dropping the absolutisation files the repo root's file instead (the case above is discriminating)"
else echo "FAIL: mutant did not file the decoy body=$(cat "$tmp/body" 2>/dev/null) rc=$rc"; fail=1; fi

# --- Case O: gh's exit code still arrives unchanged -------------------------
# dot/claude/rules/issue-workflow.md §2 documents gh's own exit code reaching
# the caller unrounded, from either gh call. Routing through `mise exec` puts a
# process in between, so the contract is re-measured here rather than assumed
# (mise propagates its child's status; the pre-existing exec did so trivially).
# 4 is the code a real unauthenticated `gh issue list` returns.
GH_EXIT_LIST=4 GH_LIST_TSV='' run --kind task --title t --body-file "$full_body"
if [ "$rc" -eq 4 ]; then
  echo "ok: a failing gh issue list propagates its own exit code through mise exec"
else echo "FAIL: gh issue list exit code rc=$rc (want 4)"; fail=1; fi

GH_EXIT_CREATE=4 GH_LIST_TSV='' run --kind task --title t --body-file "$full_body"
if [ "$rc" -eq 4 ]; then
  echo "ok: a failing gh issue create propagates its own exit code through mise exec"
else echo "FAIL: gh issue create exit code rc=$rc (want 4)"; fail=1; fi

exit "$fail"
