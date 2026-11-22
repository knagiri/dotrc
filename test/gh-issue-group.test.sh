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
# --jq would print for issue N: `state<TAB>author<TAB>label,label,...`.
stubdir="$tmp/stub"; mkdir -p "$stubdir"
cat >"$stubdir/gh" <<'STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$@" >>"$GH_ARGS_FILE"
case "$1 ${2:-}" in
  "repo view") echo "example-owner" ;;
  "issue view")
    v="GH_VIEW_$3"
    [ -n "${!v:-}" ] || { echo "no such issue: $3" >&2; exit 1; }
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

run() {  # run gh-issue-group with a fresh argv log; sets $rc
  : >"$tmp/args"
  env GH_ARGS_FILE="$tmp/args" PATH="$stubdir:$PATH" \
    "$bindir/gh-issue-group" "$@" >"$tmp/out" 2>"$tmp/err"
  rc=$?
}
wrote() { grep -qxF '[edit]' "$tmp/args" || grep -qxF '[close]' "$tmp/args" \
  || grep -qxF '[reopen]' "$tmp/args" || grep -qxF '[create]' "$tmp/args"; }

export GH_VIEW_5=$'OPEN\texample-owner\tagent-task,group'
export GH_VIEW_6=$'CLOSED\texample-owner\tagent-task,group,group/rejected'
export GH_VIEW_10=$'OPEN\texample-owner\tagent-task,kind/harness,observation'
export GH_VIEW_11=$'OPEN\texample-owner\tagent-task,kind/bug,observation'
export GH_VIEW_20=$'OPEN\tsomeone-else\tagent-task,kind/harness,observation'
export GH_VIEW_30=$'OPEN\texample-owner\tagent-task,kind/task,status/ready'

# --- attach -------------------------------------------------------------------
run attach 5 10 11
if [ "$rc" -eq 0 ] && grep -A1 -xF '[--add-sub-issue]' "$tmp/args" | grep -qxF '[10,11]' \
  && ! grep -qxF '[reopen]' "$tmp/args"; then
  echo "ok: attach adds every observation as a sub-issue of the open group"
else echo "FAIL: attach rc=$rc args=$(cat "$tmp/args") err=$(cat "$tmp/err")"; fail=1; fi

# An issue someone else filed is never attached, even with the observation
# label: anyone can open an issue in a public repo.
run attach 5 10 20
if [ "$rc" -eq 1 ] && ! wrote; then
  echo "ok: attach refuses an observation not filed by the owner, before any write"
else echo "FAIL: attach non-owner rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

run attach 5 30
if [ "$rc" -eq 1 ] && ! wrote; then
  echo "ok: attach refuses an issue without the observation label"
else echo "FAIL: attach non-observation rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

run attach 10 11
if [ "$rc" -eq 1 ] && ! wrote; then
  echo "ok: attach refuses a target that is not a group"
else echo "FAIL: attach to non-group rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# A new observation is what lifts a rejection and revives a closed group.
run attach 6 10
if [ "$rc" -eq 0 ] \
  && grep -A1 -xF '[reopen]' "$tmp/args" | grep -qxF '[6]' \
  && grep -A1 -xF '[--remove-label]' "$tmp/args" | grep -qxF '[group/rejected]' \
  && grep -qxF '[--add-sub-issue]' "$tmp/args"; then
  echo "ok: attach reopens a closed group and clears group/rejected"
else echo "FAIL: attach reopen rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# Discrimination (evidence-over-guesswork §4): with the owner check removed the
# non-owner case must go through.
mutant="$tmp/mutant"; mkdir -p "$mutant/lib"
cp -a "$bindir/lib/." "$mutant/lib/"
grep -v 'owner-check@dotrc' "$bindir/gh-issue-group" >"$mutant/gh-issue-group"
chmod +x "$mutant/gh-issue-group"
if cmp -s "$bindir/gh-issue-group" "$mutant/gh-issue-group"; then
  echo "FAIL: the owner-check mutant is identical; the check below is a no-op"; fail=1
fi
: >"$tmp/args"
env GH_ARGS_FILE="$tmp/args" PATH="$stubdir:$PATH" \
  "$mutant/gh-issue-group" attach 5 10 20 >"$tmp/out" 2>"$tmp/err"
if grep -qxF '[--add-sub-issue]' "$tmp/args"; then
  echo "ok: without the owner check the non-owner observation is attached (the case above is discriminating)"
else echo "FAIL: owner-check mutant did not attach args=$(cat "$tmp/args")"; fail=1; fi

# --- detach / close / reopen / set-body ---------------------------------------
run detach 10
if [ "$rc" -eq 0 ] && grep -qxF '[--remove-parent]' "$tmp/args"; then
  echo "ok: detach removes the observation's parent"
else echo "FAIL: detach rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

run close 30
if [ "$rc" -eq 1 ] && ! wrote; then
  echo "ok: close refuses an issue that is neither an observation nor a group"
else echo "FAIL: close plain issue rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

run close 10
if [ "$rc" -eq 0 ] && grep -A1 -xF '[close]' "$tmp/args" | grep -qxF '[10]' \
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

# --- create / argument hygiene ------------------------------------------------
run create --title 'g' --body-file "$tmp/gbody.md"
if [ "$rc" -eq 0 ] && grep -qxF '[create]' "$tmp/args" \
  && grep -qxF '[agent-task]' "$tmp/args" && grep -qxF '[group]' "$tmp/args" \
  && grep -q 'issues/77' "$tmp/out"; then
  echo "ok: create files a group with the fixed labels"
else echo "FAIL: create rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

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

exit "$fail"
