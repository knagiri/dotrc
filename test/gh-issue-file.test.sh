#!/usr/bin/env bash
# Functional tests for bin/gh-issue-file. A gh stub records its argv (one
# element per bracketed line) so we can assert both what the wrapper asks gh to
# do and -- for the refusals -- that it does NOT reach `gh issue create` at
# all. No test framework; run with bash.
#
# gh is reached through `mise exec -C <root> -- gh` (bin/lib/gh-mise.sh), so a
# mise stub sits next to the gh stub and moves gh's cwd the same way mise does.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
# The wrapper resolves its repo from cwd (git rev-parse --show-toplevel), so
# pin cwd to this checkout instead of wherever the test was launched from.
cd "$here/.." || exit 1
bindir="$here/../bin"
fail=0

tmp="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$tmp"' EXIT

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

# gh stub: records argv. It does not implement --jq, so the env vars below hold
# what gh would print *after* its --jq ran (same convention as the
# gh-await-reviews stub in gh-wrappers.test.sh).
stubdir="$tmp/stub"; mkdir -p "$stubdir"
cat >"$stubdir/gh" <<'STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$@" >>"$GH_ARGS_FILE"
case "$1 ${2:-}" in
  "repo view")
    echo "example-owner" ;;
  "issue list")
    [ -z "${GH_EXIT_LIST:-}" ] || exit "$GH_EXIT_LIST"
    printf '%s' "${GH_LIST_OUT:-}" ;;
  "issue close")
    [ -z "${GH_EXIT_CLOSE:-}" ] || exit "$GH_EXIT_CLOSE" ;;
  "issue create")
    # Which repo the issue lands in is decided by gh's cwd, so the --global
    # cases below need to see it.
    [ -z "${GH_PWD_FILE:-}" ] || pwd -P >"$GH_PWD_FILE"
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
    echo "${GH_CREATE_URL:-https://github.com/o/r/issues/1}" ;;
esac
exit 0
STUB
chmod +x "$stubdir/gh"

# Stands in for `mise exec -C <dir> -- <cmd> [args...]`, which every gh call
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
  env -u CLAUDE_CODE_SESSION_ID GH_ARGS_FILE="$tmp/args" \
    PATH="$stubdir:$PATH" "$bindir/gh-issue-file" "$@" >"$tmp/out" 2>"$tmp/err"
  rc=$?
}

# argv element after <flag> in the recorded gh call, e.g. `argval --parent`.
argval() { grep -A1 -xF "[$1]" "$tmp/args" | sed -n '2s/^\[\(.*\)\]$/\1/p'; }

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

# The dedup flag is gone; it is refused like any other unknown flag.
run --kind task --title t --body-file "$full_body" --not-dup-of 7
if [ "$rc" -eq 1 ] && [ ! -s "$tmp/args" ]; then
  echo "ok: the removed --not-dup-of is refused as an unknown flag"
else echo "FAIL: --not-dup-of rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

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

# --- labels -----------------------------------------------------------------
# harness and bug are observations: label `observation`, no status/* at all
# (the crawler, not a human gate, decides what happens to them).
for k in harness bug; do
  run --kind "$k" --title t --body-file "$full_body"
  if [ "$rc" -eq 0 ] \
    && grep -qxF '[create]' "$tmp/args" \
    && grep -qxF '[agent-task]' "$tmp/args" \
    && grep -qxF "[kind/$k]" "$tmp/args" \
    && grep -qxF '[observation]' "$tmp/args" \
    && ! grep -q '^\[status/' "$tmp/args"; then
    echo "ok: --kind $k files an observation without a status label"
  else echo "FAIL: --kind $k labels rc=$rc args=$(cat "$tmp/args")"; fail=1; fi
done

# task stays on the human-gated path: status/triage, never observation.
run --kind task --title t --body-file "$full_body"
if [ "$rc" -eq 0 ] \
  && grep -qxF '[kind/task]' "$tmp/args" \
  && grep -qxF '[status/triage]' "$tmp/args" \
  && ! grep -qxF '[observation]' "$tmp/args"; then
  echo "ok: --kind task keeps status/triage"
else echo "FAIL: --kind task labels rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# --- no dedup gate ----------------------------------------------------------
# Existing agent tasks no longer stop a filing: duplicates are the signal the
# crawler counts. Even with a list fixture present, create is reached and no
# issue list query runs at all.
GH_LIST_OUT="$(printf '#12\tworktree 委譲先で token が届かない\n')" \
  run --kind harness --title t --body-file "$full_body"
if [ "$rc" -eq 0 ] && grep -qxF '[create]' "$tmp/args" \
  && ! grep -qxF '[list]' "$tmp/args"; then
  echo "ok: filing never consults existing issues and reaches create"
else echo "FAIL: no dedup gate rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# --- --parent -----------------------------------------------------------------
run --kind harness --title t --body-file "$full_body" --parent 12
if [ "$rc" -eq 0 ] && [ "$(argval --parent)" = 12 ]; then
  echo "ok: --parent N reaches gh issue create"
else echo "FAIL: --parent rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

run --kind harness --title t --body-file "$full_body" --parent x
if [ "$rc" -eq 1 ] && [ ! -s "$tmp/args" ]; then
  echo "ok: non-numeric --parent exits 1 without calling gh"
else echo "FAIL: --parent x rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# --- session marker -----------------------------------------------------------
# The marker is what lets the crawler count one session's repeated filings as
# one. It is appended to a copy: the caller's file must stay untouched.
cp "$full_body" "$tmp/marker_src.md"
: >"$tmp/args"; : >"$tmp/body"
env CLAUDE_CODE_SESSION_ID=abc GH_ARGS_FILE="$tmp/args" GH_BODY_OUT="$tmp/body" \
  PATH="$stubdir:$PATH" "$bindir/gh-issue-file" --kind harness --title t \
  --body-file "$tmp/marker_src.md" >"$tmp/out" 2>"$tmp/err"
rc=$?
if [ "$rc" -eq 0 ] \
  && [ "$(tail -n1 "$tmp/body")" = '<!-- observed-session: abc -->' ] \
  && cmp -s "$full_body" "$tmp/marker_src.md"; then
  echo "ok: the session marker ends the filed body and the caller's file is untouched"
else echo "FAIL: session marker rc=$rc body=$(cat "$tmp/body") err=$(cat "$tmp/err")"; fail=1; fi

: >"$tmp/body"
env -u CLAUDE_CODE_SESSION_ID GH_ARGS_FILE="$tmp/args" GH_BODY_OUT="$tmp/body" \
  PATH="$stubdir:$PATH" "$bindir/gh-issue-file" --kind harness --title t \
  --body-file "$full_body" >"$tmp/out" 2>"$tmp/err"
if ! grep -q 'observed-session' "$tmp/body"; then
  echo "ok: no session id, no marker"
else echo "FAIL: marker without session id body=$(cat "$tmp/body")"; fail=1; fi

# --- --resolved-by ------------------------------------------------------------
# An observation that was already fixed on the spot is filed and then closed
# with a pointer to the PR; it still counts toward the 30-day window.
GH_CREATE_URL="https://github.com/o/r/issues/57" \
  run --kind harness --title t --body-file "$full_body" \
  --resolved-by https://github.com/o/r/pull/9
close_line="$(grep -n -xF '[close]' "$tmp/args" | cut -d: -f1)"
create_line="$(grep -n -xF '[create]' "$tmp/args" | cut -d: -f1)"
if [ "$rc" -eq 0 ] && [ -n "$close_line" ] && [ -n "$create_line" ] \
  && [ "$close_line" -gt "$create_line" ] \
  && grep -A1 -xF '[close]' "$tmp/args" | grep -qxF '[57]' \
  && grep -A1 -xF '[--comment]' "$tmp/args" | grep -q 'pull/9' \
  && grep -q 'issues/57' "$tmp/out"; then
  echo "ok: --resolved-by closes the new issue with a pointer to the PR"
else echo "FAIL: --resolved-by rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

run --kind harness --title t --body-file "$full_body" --resolved-by 'not-a-url'
if [ "$rc" -eq 1 ] && [ ! -s "$tmp/args" ]; then
  echo "ok: malformed --resolved-by exits 1 without calling gh"
else echo "FAIL: bad --resolved-by rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# --- --list-groups ------------------------------------------------------------
# Lists open groups so the caller can pick --parent. No body, no template.
GH_LIST_OUT="$(printf '#5\tsome group\n')" run --list-groups
if [ "$rc" -eq 0 ] \
  && grep -qxF '[list]' "$tmp/args" \
  && [ "$(argval --label)" = group ] \
  && [ "$(argval --state)" = open ] \
  && [ "$(argval --author)" = example-owner ] \
  && ! grep -qxF '[create]' "$tmp/args" \
  && grep -qF "$(printf '#5\tsome group')" "$tmp/out"; then
  echo "ok: --list-groups lists the owner's open groups without validating a body"
else echo "FAIL: --list-groups rc=$rc args=$(cat "$tmp/args") out=$(cat "$tmp/out")"; fail=1; fi

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
( cd "$tmpl_repo" && env GH_ARGS_FILE="$tmp/args" \
    PATH="$stubdir:$PATH" "$bindir/gh-issue-file" --kind task --title t \
    --body-file "$tmpl_body" >"$tmp/out" 2>"$tmp/err" )
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "ok: trailing whitespace on template heading lines does not fail validation"
else echo "FAIL: trailing ws template rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

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

# --- Case N: a relative --body-file survives the cwd move -------------------
# gh runs with the repo root as its cwd (mise exec -C "$root"), not the
# caller's, so a relative --body-file handed straight to gh would be resolved
# against the root. The wrapper hands gh an absolute copy instead. The fixture makes the
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
  ( cd "$relrepo/sub" && env -u CLAUDE_CODE_SESSION_ID GH_ARGS_FILE="$tmp/args" \
      GH_BODY_OUT="$tmp/body" PATH="$stubdir:$PATH" \
      "$1/gh-issue-file" --kind task --title t --body-file body.md ) \
    >"$tmp/out" 2>"$tmp/err"
  rc=$?
}

relrun "$bindir"
if [ "$rc" -eq 0 ] && grep -q 'REAL-BODY' "$tmp/body"; then
  echo "ok: a relative --body-file still reaches gh as the caller's file, not the repo root's"
else echo "FAIL: relative --body-file rc=$rc body=$(cat "$tmp/body" 2>/dev/null) err=$(cat "$tmp/err")"; fail=1; fi

# --- Case O: gh's exit code still arrives unchanged -------------------------
# dot/claude/rules/issue-workflow.md §2 documents gh's own exit code reaching
# the caller unrounded. Routing through `mise exec` puts a process in between,
# so the contract is measured here rather than assumed. 4 is the code a real
# unauthenticated gh returns.
GH_EXIT_CREATE=4 run --kind task --title t --body-file "$full_body"
if [ "$rc" -eq 4 ]; then
  echo "ok: a failing gh issue create propagates its own exit code through mise exec"
else echo "FAIL: gh issue create exit code rc=$rc (want 4)"; fail=1; fi

GH_EXIT_CLOSE=4 run --kind harness --title t --body-file "$full_body" \
  --resolved-by https://github.com/o/r/pull/9
if [ "$rc" -eq 4 ]; then
  echo "ok: a failing gh issue close (--resolved-by) propagates its own exit code"
else echo "FAIL: gh issue close exit code rc=$rc (want 4)"; fail=1; fi

# --- Case P: --global files into the script's own repo ----------------------
# An agent working in an unrelated project still has to be able to open a
# harness issue where the harness lives. Without --global there is no path at
# all: cwd's repo carries no .github/ISSUE_TEMPLATE/<kind>.md. The fixture is
# two throwaway repos -- a "script repo" holding a copy of bin/ (stands in for
# dotrc) and an unrelated cwd repo -- mirroring test/claude-worktree.test.sh.
# No issue is created against a real repo: gh is the stub throughout.
scriptrepo="$tmp/scriptrepo"
mkdir -p "$scriptrepo/.github/ISSUE_TEMPLATE" "$scriptrepo/bin"
cp -a "$bindir/." "$scriptrepo/bin/"
git init -q "$scriptrepo"
cat >"$scriptrepo/.github/ISSUE_TEMPLATE/harness.md" <<'TMPL'
---
name: harness
---
## やること（WHAT）
TMPL
scriptrepo_real="$(cd "$scriptrepo" && pwd -P)"

otherrepo="$tmp/otherrepo"
mkdir -p "$otherrepo"
git init -q "$otherrepo"

global_body="$tmp/global_body.md"
printf '## やること（WHAT）\nsomething\n' >"$global_body"

# The denylist below decides whether a filing from another repo is allowed at
# all; these runs give it one with an unrelated term so they test --global.
deny="$scriptrepo/.issue-denylist"
printf 'unrelated-term\n' >"$deny"

globalrun() {  # globalrun <bindir> <cwd> <title> [extra flags...]
  : >"$tmp/args"; : >"$tmp/pwd"
  ( cd "$2" && env -u CLAUDE_CODE_SESSION_ID GH_ARGS_FILE="$tmp/args" \
      GH_PWD_FILE="$tmp/pwd" PATH="$stubdir:$PATH" \
      "$1/gh-issue-file" --kind harness --title "$3" --body-file "$global_body" "${@:4}" ) \
    >"$tmp/out" 2>"$tmp/err"
  rc=$?
}

# Without --global the wrapper stops on the missing template -- and says how to
# reach the repo that does have one.
globalrun "$scriptrepo/bin" "$otherrepo" t
if [ "$rc" -eq 1 ] && grep -q 'no template at' "$tmp/err" && grep -q -- '--global' "$tmp/err"; then
  echo "ok: without --global an unrelated repo fails on the missing template and names --global"
else echo "FAIL: no-global rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

# With --global: the script repo's template validates the body and the issue is
# created with gh running in the script repo.
globalrun "$scriptrepo/bin" "$otherrepo" t --global
if [ "$rc" -eq 0 ] \
  && [ "$(cat "$tmp/pwd" 2>/dev/null)" = "$scriptrepo_real" ] \
  && grep -qxF '[create]' "$tmp/args"; then
  echo "ok: --global reads the script repo's template and files into that repo"
else echo "FAIL: --global rc=$rc pwd=$(cat "$tmp/pwd" 2>/dev/null) err=$(cat "$tmp/err")"; fail=1; fi

# Discrimination (evidence-over-guesswork §4): the root resolution is put back
# to cwd's repo and the case above must break. `cmp` keeps the check from
# rotting into a no-op if the tag goes.
globalmutant="$tmp/globalmutant"
rm -rf "$globalmutant"; mkdir -p "$globalmutant"
cp -a "$bindir/." "$globalmutant/"
sed 's|^.*global-root@dotrc$|  root="$(git rev-parse --show-toplevel)"|' \
  "$bindir/gh-issue-file" >"$globalmutant/gh-issue-file"
chmod +x "$globalmutant/gh-issue-file"
if cmp -s "$bindir/gh-issue-file" "$globalmutant/gh-issue-file"; then
  echo "FAIL: the --global mutant is identical to gh-issue-file; the check above is a no-op"; fail=1
fi
globalrun "$globalmutant" "$otherrepo" t --global
if [ "$rc" -eq 1 ] && grep -q 'no template at' "$tmp/err"; then
  echo "ok: resolving --global's root from cwd instead loses the template (the case above is discriminating)"
else echo "FAIL: --global mutant rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

# --- denylist -----------------------------------------------------------------
# Filings from other repos reach the public repo unattended, so title and body
# are matched (case-insensitively, as fixed strings) against the gitignored
# $root/.issue-denylist and refused with exit 3 on a hit.
printf 'Example-Corp\n' >"$deny"
globalrun "$scriptrepo/bin" "$otherrepo" 'about example-corp things' --global
if [ "$rc" -eq 3 ] && ! grep -qxF '[create]' "$tmp/args"; then
  echo "ok: a denylisted term in the title (any case) exits 3 before create"
else echo "FAIL: denylist title rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

printf '## やること（WHAT）\nseen at EXAMPLE-CORP\n' >"$tmp/deny_body.md"
cp "$tmp/deny_body.md" "$global_body"
globalrun "$scriptrepo/bin" "$otherrepo" t --global
if [ "$rc" -eq 3 ] && ! grep -qxF '[create]' "$tmp/args"; then
  echo "ok: a denylisted term in the body exits 3 before create"
else echo "FAIL: denylist body rc=$rc args=$(cat "$tmp/args")"; fail=1; fi
printf '## やること（WHAT）\nsomething\n' >"$global_body"

# Blank and whitespace-only lines must not turn into an empty pattern, which
# grep -F matches against every line and would stop every filing.
printf '\n  \n' >"$deny"
globalrun "$scriptrepo/bin" "$otherrepo" t --global
if [ "$rc" -eq 0 ] && grep -qxF '[create]' "$tmp/args"; then
  echo "ok: a denylist of blank lines matches nothing"
else echo "FAIL: blank denylist rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

# Discrimination: without the blank-line filter the same run is refused.
blankmutant="$tmp/blankmutant"
rm -rf "$blankmutant"; mkdir -p "$blankmutant"
cp -a "$scriptrepo/bin/." "$blankmutant/"
sed 's|^.*deny-blank@dotrc$|  cat -- "$deny_file"|' \
  "$bindir/gh-issue-file" >"$blankmutant/gh-issue-file"
chmod +x "$blankmutant/gh-issue-file"
if cmp -s "$bindir/gh-issue-file" "$blankmutant/gh-issue-file"; then
  echo "FAIL: the blank-line mutant is identical to gh-issue-file; the check below is a no-op"; fail=1
fi
# The mutant lives outside $scriptrepo, so run it with $scriptrepo as its
# --global root by placing it there temporarily.
cp "$scriptrepo/bin/gh-issue-file" "$tmp/gh-issue-file.keep"
cp "$blankmutant/gh-issue-file" "$scriptrepo/bin/gh-issue-file"
globalrun "$scriptrepo/bin" "$otherrepo" t --global
cp "$tmp/gh-issue-file.keep" "$scriptrepo/bin/gh-issue-file"
if [ "$rc" -eq 3 ]; then
  echo "ok: without the blank-line filter every filing is refused (the case above is discriminating)"
else echo "FAIL: blank-line mutant rc=$rc (want 3)"; fail=1; fi

# No denylist: a filing from another repo is refused (fail closed), while one
# from the root's own repo still goes through.
rm -f "$deny"
globalrun "$scriptrepo/bin" "$otherrepo" t --global
if [ "$rc" -eq 3 ] && ! grep -qxF '[create]' "$tmp/args"; then
  echo "ok: no denylist and filing from another repo exits 3"
else echo "FAIL: missing denylist foreign rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

globalrun "$scriptrepo/bin" "$scriptrepo" t --global
if [ "$rc" -eq 0 ] && grep -qxF '[create]' "$tmp/args"; then
  echo "ok: no denylist and filing from the root's own repo is allowed"
else echo "FAIL: missing denylist same repo rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

# A linked worktree of the root's repo is the same repo, not a foreign one.
git -C "$scriptrepo" -c user.name=t -c user.email=t@example.com add -A >/dev/null
git -C "$scriptrepo" -c user.name=t -c user.email=t@example.com commit -qm init
git -C "$scriptrepo" worktree add -q "$tmp/scriptwt" 2>/dev/null
globalrun "$scriptrepo/bin" "$tmp/scriptwt" t --global
if [ "$rc" -eq 0 ] && grep -qxF '[create]' "$tmp/args"; then
  echo "ok: a linked worktree of the root's repo counts as the same repo"
else echo "FAIL: worktree same repo rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

exit "$fail"
