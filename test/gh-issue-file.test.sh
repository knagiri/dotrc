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

# gh stub: records argv, prints an empty issue list so the dedup gate (added in
# a later task) has nothing to offer.
stubdir="$tmp/stub"; mkdir -p "$stubdir"
cat >"$stubdir/gh" <<'STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$@" >>"$GH_ARGS_FILE"
case "$1 ${2:-}" in
  "issue list") echo "${GH_LIST_JSON:-[]}" ;;
  "issue create") echo "https://github.com/o/r/issues/1" ;;
esac
exit 0
STUB
chmod +x "$stubdir/gh"

run() {  # run gh-issue-file with a fresh argv log; echoes nothing, sets $rc
  : >"$tmp/args"
  env GH_ARGS_FILE="$tmp/args" GH_LIST_JSON="${GH_LIST_JSON:-[]}" \
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

exit "$fail"
