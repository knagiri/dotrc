#!/usr/bin/env bash
# Functional tests for the gh wrappers. A gh stub records its argv (one element
# per bracketed line) so we assert each wrapper issues exactly the intended gh
# command -- and, for gh-automerge, that no extra flags (e.g. --admin) leak
# through. No test framework; run with bash.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
bindir="$here/../bin"
fail=0

stubdir="$(mktemp -d)"
trap 'rm -rf "$stubdir"' EXIT
cat >"$stubdir/gh" <<'STUB'
#!/usr/bin/env bash
: >"$GH_ARGS_FILE"
printf '[%s]\n' "$@" >>"$GH_ARGS_FILE"
STUB
chmod +x "$stubdir/gh"

# gh-automerge: numeric PR issues `gh pr merge --auto --merge <PR>`, no --admin.
GH_ARGS_FILE="$stubdir/args" PATH="$stubdir:$PATH" "$bindir/gh-automerge" 42 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] \
  && grep -qxF '[pr]' "$stubdir/args" && grep -qxF '[merge]' "$stubdir/args" \
  && grep -qxF '[--auto]' "$stubdir/args" && grep -qxF '[--merge]' "$stubdir/args" \
  && grep -qxF '[42]' "$stubdir/args" \
  && ! grep -qxF '[--admin]' "$stubdir/args"; then
  echo "ok: gh-automerge issues gh pr merge --auto --merge <PR>, no --admin"
else echo "FAIL: gh-automerge rc=$rc args=$(cat "$stubdir/args" 2>/dev/null)"; fail=1; fi

# gh-automerge: missing / non-numeric arg fail.
PATH="$stubdir:$PATH" "$bindir/gh-automerge" >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-automerge missing arg fails" || { echo "FAIL: gh-automerge missing arg"; fail=1; }
PATH="$stubdir:$PATH" "$bindir/gh-automerge" 1a >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-automerge non-numeric fails" || { echo "FAIL: gh-automerge non-numeric"; fail=1; }
PATH="$stubdir:$PATH" "$bindir/gh-automerge" 42 --admin >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-automerge rejects extra flag arg" || { echo "FAIL: gh-automerge extra flag"; fail=1; }

# gh-resolve-thread: valid id issues resolveReviewThread mutation with threadId.
GH_ARGS_FILE="$stubdir/args" PATH="$stubdir:$PATH" "$bindir/gh-resolve-thread" 'PRRT_kwABC-_=' >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] \
  && grep -qxF '[api]' "$stubdir/args" && grep -qxF '[graphql]' "$stubdir/args" \
  && grep -qxF '[threadId=PRRT_kwABC-_=]' "$stubdir/args" \
  && grep -q 'resolveReviewThread' "$stubdir/args"; then
  echo "ok: gh-resolve-thread issues resolveReviewThread mutation with threadId"
else echo "FAIL: gh-resolve-thread rc=$rc args=$(cat "$stubdir/args" 2>/dev/null)"; fail=1; fi

# gh-resolve-thread: missing / unsafe id fail.
PATH="$stubdir:$PATH" "$bindir/gh-resolve-thread" >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-resolve-thread missing arg fails" || { echo "FAIL: gh-resolve-thread missing arg"; fail=1; }
PATH="$stubdir:$PATH" "$bindir/gh-resolve-thread" 'bad;id' >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-resolve-thread unsafe id fails" || { echo "FAIL: gh-resolve-thread unsafe id"; fail=1; }

# gh-list-threads: numeric PR issues a reviewThreads query carrying pr=<PR>.
GH_ARGS_FILE="$stubdir/args" PATH="$stubdir:$PATH" "$bindir/gh-list-threads" 7 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] \
  && grep -qxF '[graphql]' "$stubdir/args" \
  && grep -qxF '[pr=7]' "$stubdir/args" \
  && grep -q 'reviewThreads' "$stubdir/args"; then
  echo "ok: gh-list-threads issues reviewThreads query for the PR"
else echo "FAIL: gh-list-threads rc=$rc args=$(cat "$stubdir/args" 2>/dev/null)"; fail=1; fi

# gh-list-threads: missing / non-numeric arg fail.
PATH="$stubdir:$PATH" "$bindir/gh-list-threads" >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-list-threads missing arg fails" || { echo "FAIL: gh-list-threads missing arg"; fail=1; }
PATH="$stubdir:$PATH" "$bindir/gh-list-threads" x9 >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-list-threads non-numeric fails" || { echo "FAIL: gh-list-threads non-numeric"; fail=1; }

# gh-pr-report: numeric PR + stdin body issues `gh pr comment <PR> --body-file -`.
printf 'report body' | GH_ARGS_FILE="$stubdir/args" PATH="$stubdir:$PATH" "$bindir/gh-pr-report" 42 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] \
  && grep -qxF '[pr]' "$stubdir/args" && grep -qxF '[comment]' "$stubdir/args" \
  && grep -qxF '[42]' "$stubdir/args" \
  && grep -qxF '[--body-file]' "$stubdir/args" && grep -qxF '[-]' "$stubdir/args"; then
  echo "ok: gh-pr-report issues gh pr comment <PR> --body-file -"
else echo "FAIL: gh-pr-report rc=$rc args=$(cat "$stubdir/args" 2>/dev/null)"; fail=1; fi

# gh-pr-report: missing / non-numeric / extra-flag arg fail (no flag passthrough).
printf x | PATH="$stubdir:$PATH" "$bindir/gh-pr-report" >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-pr-report missing arg fails" || { echo "FAIL: gh-pr-report missing arg"; fail=1; }
printf x | PATH="$stubdir:$PATH" "$bindir/gh-pr-report" 9z >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-pr-report non-numeric fails" || { echo "FAIL: gh-pr-report non-numeric"; fail=1; }
printf x | PATH="$stubdir:$PATH" "$bindir/gh-pr-report" 42 --edit-last >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-pr-report rejects extra flag arg" || { echo "FAIL: gh-pr-report extra flag"; fail=1; }

# gh-pr-comments: numeric PR issues `gh pr view <PR> --json reviews,comments` with a --jq reshape.
GH_ARGS_FILE="$stubdir/args" PATH="$stubdir:$PATH" "$bindir/gh-pr-comments" 42 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] \
  && grep -qxF '[pr]' "$stubdir/args" && grep -qxF '[view]' "$stubdir/args" \
  && grep -qxF '[42]' "$stubdir/args" \
  && grep -qxF '[--json]' "$stubdir/args" && grep -qxF '[reviews,comments]' "$stubdir/args" \
  && grep -qxF '[--jq]' "$stubdir/args" \
  && grep -q 'submittedAt' "$stubdir/args" && grep -q 'createdAt' "$stubdir/args"; then
  echo "ok: gh-pr-comments issues gh pr view <PR> --json reviews,comments"
else echo "FAIL: gh-pr-comments rc=$rc args=$(cat "$stubdir/args" 2>/dev/null)"; fail=1; fi

# gh-pr-comments: missing / non-numeric / extra-flag arg fail (no flag passthrough).
PATH="$stubdir:$PATH" "$bindir/gh-pr-comments" >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-pr-comments missing arg fails" || { echo "FAIL: gh-pr-comments missing arg"; fail=1; }
PATH="$stubdir:$PATH" "$bindir/gh-pr-comments" 9z >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-pr-comments non-numeric fails" || { echo "FAIL: gh-pr-comments non-numeric"; fail=1; }
PATH="$stubdir:$PATH" "$bindir/gh-pr-comments" 42 --comments >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-pr-comments rejects extra flag arg" || { echo "FAIL: gh-pr-comments extra flag"; fail=1; }

exit "$fail"
