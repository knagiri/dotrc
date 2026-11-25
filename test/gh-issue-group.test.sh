#!/usr/bin/env bash
# Functional tests for bin/gh-issue-group. A gh stub records its argv (one
# element per bracketed line) and answers `issue view` from per-issue fixtures,
# so we can assert both the edits the wrapper asks for and that a refused
# operation never reaches a write. No test framework; run with bash.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
cd "$here/.." || exit 1
bindir="$here/../bin"
fail=0

tmp="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$tmp"' EXIT

# gh stub. It does not implement --jq, so GH_VIEW_<N> holds what the wrapper's
# --jq would print for issue N: `state<TAB>parent|none<TAB>label,label,...`.
stubdir="$tmp/stub"; mkdir -p "$stubdir"
cat >"$stubdir/gh" <<'STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$@" >>"$GH_ARGS_FILE"
case "$1 ${2:-}" in
  "repo view")
    # The privacy check (bin/lib/issue-repo.sh): what its --jq prints.
    [ -z "${GH_EXIT_REPO:-}" ] || { echo "gh stub: forced failure" >&2; exit "$GH_EXIT_REPO"; }
    echo "${GH_PRIVATE-true}" ;;
  "issue view")
    n=""; for a in "${@:3}"; do [[ "$a" =~ ^[0-9]+$ ]] && { n="$a"; break; }; done
    v="GH_VIEW_$n"
    [ -n "$n" ] && [ -n "${!v:-}" ] || { echo "no such issue: $*" >&2; exit 1; }
    printf '%s\n' "${!v}" ;;
  "issue create") echo "https://github.com/o/r/issues/77" ;;
esac
exit 0
STUB
chmod +x "$stubdir/gh"

# Stands in for `mise exec -C <dir> -- <cmd> [args...]` (bin/lib/gh-mise.sh) so
# no test falls through to the real mise or the real gh.
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

# Control: the stubs are what the wrapper reaches. If PATH resolution ever
# skipped them, every assertion below would be about the real gh.
if [ "$(PATH="$stubdir:$PATH" command -v gh)" != "$stubdir/gh" ] \
  || [ "$(PATH="$stubdir:$PATH" command -v mise)" != "$stubdir/mise" ]; then
  echo "FAIL: stub gh/mise do not shadow the real ones"; exit 1
fi

# Every case targets this fixture name, never the real issue repo.
issue_repo=example-owner/example-issues
export ISSUE_REPO="$issue_repo"

run() {  # run gh-issue-group with a fresh argv log; sets $rc
  : >"$tmp/args"
  env GH_ARGS_FILE="$tmp/args" PATH="$stubdir:$PATH" \
    "$bindir/gh-issue-group" "$@" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  r_consistent "$*"
}
# r_consistent <label> -- every gh `issue` call in the argv log names the issue
# repo: as many `[-R]` + `[$issue_repo]` pairs as `[issue]` calls (a run that
# stops before calling gh has none of either). A call without -R would write to
# the dotrc issue of the same number.
r_consistent() {
  local calls pairs
  calls="$(grep -cxF '[issue]' "$tmp/args")"
  pairs="$(grep -A1 -xF '[-R]' "$tmp/args" | grep -cxF "[$issue_repo]")"
  if [ "$calls" -ne "$pairs" ]; then
    echo "FAIL: -R missing on a gh issue call ($1): calls=$calls pairs=$pairs args=$(tr '\n' ' ' <"$tmp/args")"; fail=1
  fi
}
wrote() { grep -qxF '[edit]' "$tmp/args" || grep -qxF '[close]' "$tmp/args" \
  || grep -qxF '[reopen]' "$tmp/args" || grep -qxF '[create]' "$tmp/args"; }

export GH_VIEW_5=$'OPEN\tnone\tagent-task,group'
export GH_VIEW_6=$'CLOSED\tnone\tagent-task,group,group/rejected'
export GH_VIEW_10=$'OPEN\tnone\tagent-task,kind/harness,observation'
export GH_VIEW_11=$'OPEN\tnone\tagent-task,kind/bug,observation'
export GH_VIEW_12=$'OPEN\t5\tagent-task,kind/bug,observation'
export GH_VIEW_30=$'OPEN\tnone\tagent-task,kind/task,status/ready'
export GH_VIEW_31=$'OPEN\tnone\tagent-task,kind/task,status/delegated'
export GH_VIEW_32=$'OPEN\tnone\tagent-task,status/delegated'

# --- attach -------------------------------------------------------------------
run attach 5 10 11
if [ "$rc" -eq 0 ] && grep -A1 -xF '[--add-sub-issue]' "$tmp/args" | grep -qxF '[10,11]' \
  && ! grep -qxF '[reopen]' "$tmp/args"; then
  echo "ok: attach adds every observation as a sub-issue of the open group"
else echo "FAIL: attach rc=$rc args=$(cat "$tmp/args") err=$(cat "$tmp/err")"; fail=1; fi

# Every read and write names the issue repo: as many `-R <repo>` pairs as issue
# calls (three views and one edit here), and who filed an issue is not read
# (the issue repo is private): the one `repo view` is the privacy check.
run attach 5 10 11
if [ "$(grep -cxF '[issue]' "$tmp/args")" -eq 4 ] \
  && [ "$(grep -A1 -xF '[-R]' "$tmp/args" | grep -cxF "[$issue_repo]")" -eq 4 ] \
  && [ "$(grep -cxF '[repo]' "$tmp/args")" -eq 1 ] && grep -qxF '[isPrivate]' "$tmp/args" \
  && ! grep -q 'author' "$tmp/args"; then
  echo "ok: every gh call targets the issue repo, with no author or owner read"
else echo "FAIL: attach -R args=$(cat "$tmp/args")"; fail=1; fi

run attach 5 30
if [ "$rc" -eq 1 ] && ! wrote; then
  echo "ok: attach refuses an issue without the observation label"
else echo "FAIL: attach non-observation rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

run attach 10 11
if [ "$rc" -eq 1 ] && ! wrote; then
  echo "ok: attach refuses a target that is not a group"
else echo "FAIL: attach to non-group rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# A new observation revives a closed group. group/rejected is not touched here:
# lifting a rejection depends on when the observation was filed, which only the
# crawler's follow step looks at.
run attach 6 10
if [ "$rc" -eq 0 ] \
  && grep -A3 -xF '[reopen]' "$tmp/args" | grep -qxF '[6]' \
  && ! grep -qxF '[--remove-label]' "$tmp/args" \
  && grep -qxF '[--add-sub-issue]' "$tmp/args"; then
  echo "ok: attach reopens a closed group and leaves group/rejected alone"
else echo "FAIL: attach reopen rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# An observation that already has a parent is refused before any write: the
# group is neither reopened nor edited, even when the parented one comes last.
run attach 6 10 12
if [ "$rc" -eq 1 ] && ! wrote && grep -q 'already has parent #5' "$tmp/err"; then
  echo "ok: attach refuses an observation that already has a parent, before any write"
else echo "FAIL: attach parented rc=$rc args=$(cat "$tmp/args") err=$(cat "$tmp/err")"; fail=1; fi

# Discrimination (evidence-over-guesswork §4): the edit's -R is dropped and
# the case above must break.
mutant="$tmp/mutant"; mkdir -p "$mutant/lib"
cp -a "$bindir/lib/." "$mutant/lib/"
sed 's|gh_mise issue edit "\${R\[@\]}" "\$group"|gh_mise issue edit "$group"|' \
  "$bindir/gh-issue-group" >"$mutant/gh-issue-group"
chmod +x "$mutant/gh-issue-group"
if cmp -s "$bindir/gh-issue-group" "$mutant/gh-issue-group"; then
  echo "FAIL: the no-R mutant is identical; the check below is a no-op"; fail=1
fi
: >"$tmp/args"
env GH_ARGS_FILE="$tmp/args" PATH="$stubdir:$PATH" \
  "$mutant/gh-issue-group" attach 5 10 11 >"$tmp/out" 2>"$tmp/err"
if grep -qxF '[--add-sub-issue]' "$tmp/args" \
  && [ "$(grep -A1 -xF '[-R]' "$tmp/args" | grep -cxF "[$issue_repo]")" -eq 3 ]; then
  echo "ok: an edit without -R is visible to the count above (the case above is discriminating)"
else echo "FAIL: no-R mutant args=$(cat "$tmp/args")"; fail=1; fi

# --- detach / close / reopen / set-body ---------------------------------------
run detach 10
if [ "$rc" -eq 0 ] && grep -qxF '[--remove-parent]' "$tmp/args"; then
  echo "ok: detach removes the observation's parent"
else echo "FAIL: detach rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# set-body and detach refuse the same targets: nothing but an issue with the
# right label is ever written.
printf 'body\n' >"$tmp/sb.md"
run set-body 10 "$tmp/sb.md"
if [ "$rc" -eq 1 ] && ! wrote; then
  echo "ok: set-body refuses an issue that is not a group"
else echo "FAIL: set-body non-group rc=$rc args=$(cat "$tmp/args")"; fail=1; fi
run detach 5
if [ "$rc" -eq 1 ] && ! grep -qxF '[--remove-parent]' "$tmp/args"; then
  echo "ok: detach refuses an issue without the observation label"
else echo "FAIL: detach non-observation rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

run close 30
if [ "$rc" -eq 1 ] && ! wrote; then
  echo "ok: close refuses an issue that is neither an observation nor a group"
else echo "FAIL: close plain issue rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

run close 10
if [ "$rc" -eq 0 ] && grep -A3 -xF '[close]' "$tmp/args" | grep -qxF '[10]' \
  && ! grep -qxF '[--reason]' "$tmp/args"; then
  echo "ok: close closes an observation as completed"
else echo "FAIL: close observation rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

run close 5 --not-planned
if [ "$rc" -eq 0 ] && grep -A1 -xF '[--reason]' "$tmp/args" | grep -qxF '[not planned]'; then
  echo "ok: close --not-planned closes with reason not planned"
else echo "FAIL: close --not-planned rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

run reopen 10
if [ "$rc" -eq 1 ] && ! wrote; then
  echo "ok: reopen refuses a non-group"
else echo "FAIL: reopen non-group rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

run reopen 6
if [ "$rc" -eq 0 ] && grep -A3 -xF '[reopen]' "$tmp/args" | grep -qxF '[6]'; then
  echo "ok: reopen reopens a closed group"
else echo "FAIL: reopen group rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

printf 'why these belong together\n' >"$tmp/gbody.md"
run set-body 5 "$tmp/gbody.md"
if [ "$rc" -eq 0 ] && grep -A1 -xF '[--body-file]' "$tmp/args" | grep -qF "$tmp/gbody.md"; then
  echo "ok: set-body replaces the group body from the file"
else echo "FAIL: set-body rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# --- mark ---------------------------------------------------------------------
run mark 5 rejected
if [ "$rc" -eq 0 ] \
  && grep -A1 -xF '[--add-label]' "$tmp/args" | grep -qxF '[group/rejected]' \
  && grep -A1 -xF '[--remove-label]' "$tmp/args" | grep -qxF '[group/delegated]'; then
  echo "ok: mark rejected swaps group/delegated for group/rejected"
else echo "FAIL: mark rejected rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

run mark 5 delegated
if [ "$rc" -eq 0 ] \
  && grep -A1 -xF '[--add-label]' "$tmp/args" | grep -qxF '[group/delegated]' \
  && grep -A1 -xF '[--remove-label]' "$tmp/args" | grep -qxF '[group/rejected]'; then
  echo "ok: mark delegated swaps group/rejected for group/delegated"
else echo "FAIL: mark delegated rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

run mark 5 clear
if [ "$rc" -eq 0 ] && ! grep -qxF '[--add-label]' "$tmp/args" \
  && [ "$(grep -c -xF '[--remove-label]' "$tmp/args")" -eq 2 ]; then
  echo "ok: mark clear removes both group states"
else echo "FAIL: mark clear rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

run mark 5 bogus
if [ "$rc" -eq 1 ] && ! wrote; then
  echo "ok: mark refuses an unknown state"
else echo "FAIL: mark bogus rc=$rc"; fail=1; fi

run mark 10 delegated
if [ "$rc" -eq 1 ] && ! wrote; then
  echo "ok: mark refuses a non-group"
else echo "FAIL: mark non-group rc=$rc"; fail=1; fi

# --- close-task ---------------------------------------------------------------
run close-task 31
if [ "$rc" -eq 0 ] && grep -A3 -xF '[close]' "$tmp/args" | grep -qxF '[31]' \
  && ! grep -qxF '[--reason]' "$tmp/args" \
  && [ "$(grep -A1 -xF '[-R]' "$tmp/args" | grep -cxF "[$issue_repo]")" -eq 2 ]; then
  echo "ok: close-task closes a delegated task as completed in the issue repo"
else echo "FAIL: close-task rc=$rc args=$(cat "$tmp/args") err=$(cat "$tmp/err")"; fail=1; fi

task_refusals() {  # task_refusals <bindir>; 0 iff every bad target is refused without a write
  local bad=0 n
  for n in 30 32 5 10; do  # ready task, delegated non-task, group, observation
    : >"$tmp/args"
    env GH_ARGS_FILE="$tmp/args" PATH="$stubdir:$PATH" \
      "$1/gh-issue-group" close-task "$n" >"$tmp/out" 2>"$tmp/err" && bad=1
    wrote && bad=1
  done
  return "$bad"
}
if task_refusals "$bindir"; then
  echo "ok: close-task refuses a task not delegated, a non-task, a group and an observation"
else echo "FAIL: close-task accepted a bad target args=$(cat "$tmp/args")"; fail=1; fi

# Discrimination: drop the status/delegated check and a ready task gets closed.
grep -v 'task-delegated@dotrc' "$bindir/gh-issue-group" >"$mutant/gh-issue-group"
chmod +x "$mutant/gh-issue-group"
if cmp -s "$bindir/gh-issue-group" "$mutant/gh-issue-group"; then
  echo "FAIL: the task-delegated mutant is identical; the check below is a no-op"; fail=1
fi
if ! task_refusals "$mutant"; then
  echo "ok: without the status/delegated check a bad target is closed (the case above is discriminating)"
else echo "FAIL: task-delegated mutant still refused everything"; fail=1; fi

# --- create / argument hygiene ------------------------------------------------
run create --title 'g' --body-file "$tmp/gbody.md"
if [ "$rc" -eq 0 ] && grep -qxF '[create]' "$tmp/args" \
  && grep -qxF '[agent-task]' "$tmp/args" && grep -qxF '[group]' "$tmp/args" \
  && grep -q 'issues/77' "$tmp/out"; then
  echo "ok: create files a group with the fixed labels"
else echo "FAIL: create rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# gh runs in the repo root, so the wrapper must hand it an absolute path: a
# relative --body-file given from another cwd would be read from the root.
mkdir -p "$tmp/sub"; printf 'rel body\n' >"$tmp/sub/rel.md"
for c in "create --title g --body-file rel.md" "set-body 5 rel.md"; do
  : >"$tmp/args"
  # shellcheck disable=SC2086
  ( cd "$tmp/sub" && env GH_ARGS_FILE="$tmp/args" PATH="$stubdir:$PATH" \
      "$bindir/gh-issue-group" $c ) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  r_consistent "$c"
  if [ "$rc" -eq 0 ] && grep -A1 -xF '[--body-file]' "$tmp/args" | grep -qxF "[$(cd "$tmp/sub" && pwd -P)/rel.md]"; then
    echo "ok: ${c%% *} hands gh an absolute --body-file resolved in the caller's cwd"
  else echo "FAIL: ${c%% *} relative body rc=$rc args=$(cat "$tmp/args")"; fail=1; fi
done

run create --title 'g' --body-file "$tmp/gbody.md" --label extra
if [ "$rc" -eq 1 ] && ! wrote; then
  echo "ok: create refuses an extra flag"
else echo "FAIL: create extra flag rc=$rc"; fail=1; fi

run attach 5 x
if [ "$rc" -eq 1 ] && [ ! -s "$tmp/args" ]; then
  echo "ok: a non-numeric issue number exits 1 before calling gh"
else echo "FAIL: non-numeric rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

run frobnicate 5
if [ "$rc" -eq 1 ] && [ ! -s "$tmp/args" ]; then
  echo "ok: an unknown subcommand exits 1 before calling gh"
else echo "FAIL: unknown subcommand rc=$rc"; fail=1; fi

# --- the issue repo: not configured (3), not private (5) --------------------------
# Not configured: ISSUE_REPO is absent and the sandbox HOME has no config file,
# so every subcommand stops with 3 before gh is called.
run_unset() {  # run_unset <bindir> <args...>; ISSUE_REPO absent from the environment
  : >"$tmp/args"
  env -u ISSUE_REPO GH_ARGS_FILE="$tmp/args" PATH="$stubdir:$PATH" \
    "$1/gh-issue-group" "${@:2}" >"$tmp/out" 2>"$tmp/err"
  rc=$?
}
unconfigured_stops() {  # 0 iff every subcommand exits 3 without a gh call
  local bad=0 c
  for c in "close 10" "close-task 31" "attach 5 10" "mark 5 clear" "reopen 6"; do
    # shellcheck disable=SC2086
    run_unset "$1" $c
    { [ "$rc" -eq 3 ] && [ ! -s "$tmp/args" ]; } || bad=1
  done
  return "$bad"
}
if unconfigured_stops "$bindir"; then
  echo "ok: with no issue repo configured every subcommand exits 3 without calling gh"
else echo "FAIL: unconfigured rc=$rc args=$(cat "$tmp/args") err=$(cat "$tmp/err")"; fail=1; fi
# Discrimination: with exit 3 turned into a no-op in the lib, a call is made.
cfgmut="$tmp/cfgmut"; rm -rf "$cfgmut"; mkdir -p "$cfgmut"; cp -a "$bindir/." "$cfgmut/"
sed 's/exit 3/:/' "$bindir/lib/issue-repo.sh" >"$cfgmut/lib/issue-repo.sh"
if cmp -s "$bindir/lib/issue-repo.sh" "$cfgmut/lib/issue-repo.sh"; then
  echo "FAIL: the exit-3 mutant is identical; the check below is a no-op"; fail=1
fi
if ! unconfigured_stops "$cfgmut"; then
  echo "ok: without the exit 3 an unconfigured issue repo gets through (the case above is discriminating)"
else echo "FAIL: exit-3 mutant still stopped everything"; fail=1; fi

# Not private (or not verifiable): exit 5, and no issue is read or written.
not_private_stops() {  # not_private_stops <bindir>; 0 iff every case exits 5 with no issue call
  local bad=0 v c
  for v in GH_PRIVATE=false GH_EXIT_REPO=1 GH_PRIVATE=maybe GH_PRIVATE=; do
    for c in "close 10" "close-task 31" "attach 5 10" "mark 5 clear" "reopen 6" "create --title g --body-file $tmp/gbody.md"; do
      : >"$tmp/args"
      # shellcheck disable=SC2086
      env "$v" GH_ARGS_FILE="$tmp/args" PATH="$stubdir:$PATH" \
        "$1/gh-issue-group" $c >"$tmp/out" 2>"$tmp/err"
      rc=$?
      { [ "$rc" -eq 5 ] && ! grep -qxF '[issue]' "$tmp/args" && grep -qE 'not private|cannot verify' "$tmp/err"; } || bad=1
    done
  done
  return "$bad"
}
if not_private_stops "$bindir"; then
  echo "ok: a public, unverifiable or odd-answer issue repo exits 5 before any issue is touched"
else echo "FAIL: not private rc=$rc args=$(cat "$tmp/args") err=$(cat "$tmp/err")"; fail=1; fi
# Discrimination: the call dropped, or the comparison loosened to any output.
privmut="$tmp/privmut"; rm -rf "$privmut"; mkdir -p "$privmut"; cp -a "$bindir/." "$privmut/"
sed '/private-check@dotrc$/d' "$bindir/gh-issue-group" >"$privmut/gh-issue-group"
if cmp -s "$bindir/gh-issue-group" "$privmut/gh-issue-group"; then
  echo "FAIL: the no-check mutant is identical; the check below is a no-op"; fail=1
fi
if ! not_private_stops "$privmut"; then
  echo "ok: without the privacy check a public issue repo is written to (the exit-5 cases are discriminating)"
else echo "FAIL: no-check mutant still stopped everything"; fail=1; fi
sed 's|\[ "\$last" != true \]|[ -z "$last" ]|' "$bindir/lib/issue-repo.sh" >"$privmut/lib/issue-repo.sh"
cp -a "$bindir/gh-issue-group" "$privmut/gh-issue-group"
if cmp -s "$bindir/lib/issue-repo.sh" "$privmut/lib/issue-repo.sh"; then
  echo "FAIL: the loose-compare mutant is identical; the check below is a no-op"; fail=1
fi
if ! not_private_stops "$privmut"; then
  echo "ok: a comparison loosened to any output lets a public repo through (the exit-5 cases are discriminating)"
else echo "FAIL: loose-compare mutant still stopped everything"; fail=1; fi

exit "$fail"
