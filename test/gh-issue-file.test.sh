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
    case "$*" in
      # The privacy check (bin/lib/issue-repo.sh): what its --jq prints.
      *isPrivate*)
        [ -z "${GH_EXIT_REPO:-}" ] || { echo "gh stub: forced failure" >&2; exit "$GH_EXIT_REPO"; }
        echo "${GH_PRIVATE-true}" ;;
      *nameWithOwner*) echo "${GH_NWO:-o/r}" ;;
      *) echo "example-owner" ;;
    esac ;;
  "issue view")
    # What the wrapper's --jq prints: the labels, comma-joined (a group by default).
    printf '%s\n' "${GH_VIEW_OUT:-agent-task,group}" ;;
  "issue list")
    [ -z "${GH_EXIT_LIST:-}" ] || exit "$GH_EXIT_LIST"
    printf '%s' "${GH_LIST_OUT:-}" ;;
  "issue close")
    [ -z "${GH_EXIT_CLOSE:-}" ] || exit "$GH_EXIT_CLOSE" ;;
  "issue create")
    # gh's cwd decides whose token (mise config) is used, so the
    # cwd-independence cases below need to see it.
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

# The cases run in a throwaway repo that carries copies of the templates and
# bin/, so they do not depend on the state of this checkout.
isorepo="$tmp/isorepo"
mkdir -p "$isorepo/.github"
cp -a "$here/../.github/ISSUE_TEMPLATE" "$isorepo/.github/"
cp -a "$bindir" "$isorepo/bin"
git init -q "$isorepo"

# Every case targets this fixture name, never the real issue repo.
issue_repo=example-owner/example-issues
export ISSUE_REPO="$issue_repo"

run() {  # run gh-issue-file with a fresh argv log; echoes nothing, sets $rc
  : >"$tmp/args"
  ( cd "$isorepo" && env -u CLAUDE_CODE_SESSION_ID GH_ARGS_FILE="$tmp/args" \
      PATH="$stubdir:$PATH" "$isorepo/bin/gh-issue-file" "$@" ) >"$tmp/out" 2>"$tmp/err"
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

# The issue repo is private, so who filed the parent is not checked: the read
# asks for labels only, and the one `repo view` is the privacy check, not an
# owner lookup.
run --kind harness --title t --body-file "$full_body" --parent 12
if [ "$rc" -eq 0 ] && grep -qxF '[create]' "$tmp/args" \
  && grep -A1 -xF '[--json]' "$tmp/args" | grep -qxF '[labels]' \
  && [ "$(grep -cxF '[repo]' "$tmp/args")" -eq 1 ] && grep -qxF '[isPrivate]' "$tmp/args"; then
  echo "ok: --parent checks the group label only, with no author lookup"
else echo "FAIL: --parent author lookup rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# The parent read and the create both name the issue repo: a view without -R
# would read the dotrc issue of the same number.
if [ "$(grep -cxF '[-R]' "$tmp/args")" -eq 2 ] \
  && [ "$(grep -A1 -xF '[-R]' "$tmp/args" | grep -cxF "[$issue_repo]")" -eq 2 ]; then
  echo "ok: --parent's view and create both target the issue repo"
else echo "FAIL: --parent -R args=$(cat "$tmp/args")"; fail=1; fi

GH_VIEW_OUT='agent-task,kind/task' \
  run --kind harness --title t --body-file "$full_body" --parent 12
if [ "$rc" -eq 1 ] && ! grep -qxF '[create]' "$tmp/args" && grep -q 'not a group' "$tmp/err"; then
  echo "ok: --parent that is not a group exits 1 before create"
else echo "FAIL: --parent non-group rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# --- session marker -----------------------------------------------------------
# The marker is what lets the crawler count one session's repeated filings as
# one. It is appended to a copy: the caller's file must stay untouched.
cp "$full_body" "$tmp/marker_src.md"
: >"$tmp/args"; : >"$tmp/body"
( cd "$isorepo" && env CLAUDE_CODE_SESSION_ID=abc GH_ARGS_FILE="$tmp/args" GH_BODY_OUT="$tmp/body" \
  PATH="$stubdir:$PATH" "$isorepo/bin/gh-issue-file" --kind harness --title t \
  --body-file "$tmp/marker_src.md" ) >"$tmp/out" 2>"$tmp/err"
rc=$?
if [ "$rc" -eq 0 ] \
  && [ "$(tail -n1 "$tmp/body")" = '<!-- observed-session: abc -->' ] \
  && cmp -s "$full_body" "$tmp/marker_src.md"; then
  echo "ok: the session marker ends the filed body and the caller's file is untouched"
else echo "FAIL: session marker rc=$rc body=$(cat "$tmp/body") err=$(cat "$tmp/err")"; fail=1; fi

: >"$tmp/body"
( cd "$isorepo" && env -u CLAUDE_CODE_SESSION_ID GH_ARGS_FILE="$tmp/args" GH_BODY_OUT="$tmp/body" \
  PATH="$stubdir:$PATH" "$isorepo/bin/gh-issue-file" --kind harness --title t \
  --body-file "$full_body" ) >"$tmp/out" 2>"$tmp/err"
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
  && grep -A3 -xF '[close]' "$tmp/args" | grep -qxF '[57]' \
  && [ "$(argval --comment)" = 'Resolved by https://github.com/o/r/pull/9' ] \
  && grep -q 'issues/57' "$tmp/out"; then
  echo "ok: --resolved-by closes the new issue with a pointer to the PR"
else echo "FAIL: --resolved-by rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# Both the create and the close name the issue repo.
if [ "$(grep -cxF '[-R]' "$tmp/args")" -eq 2 ] \
  && [ "$(grep -A1 -xF '[-R]' "$tmp/args" | grep -cxF "[$issue_repo]")" -eq 2 ]; then
  echo "ok: --resolved-by creates and closes in the issue repo"
else echo "FAIL: --resolved-by -R args=$(cat "$tmp/args")"; fail=1; fi

run --kind harness --title t --body-file "$full_body" --resolved-by 'not-a-url'
if [ "$rc" -eq 1 ] && [ ! -s "$tmp/args" ]; then
  echo "ok: malformed --resolved-by exits 1 without calling gh"
else echo "FAIL: bad --resolved-by rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# The comment lands in the private issue repo, so a PR of any repository is
# named as is.
GH_CREATE_URL="https://github.com/o/r/issues/58" \
  run --kind harness --title t --body-file "$full_body" \
  --resolved-by https://github.com/elsewhere/other/pull/3
if [ "$rc" -eq 0 ] && [ "$(argval --comment)" = 'Resolved by https://github.com/elsewhere/other/pull/3' ]; then
  echo "ok: --resolved-by names a PR of another repository too"
else echo "FAIL: foreign --resolved-by rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# --resolved-by failing after the issue exists exits 4, never gh's own code or
# 1, so a caller that retries on failure cannot file twice.
GH_EXIT_CLOSE=7 run --kind harness --title t --body-file "$full_body" \
  --resolved-by https://github.com/o/r/pull/9
if [ "$rc" -eq 4 ] && grep -qxF '[create]' "$tmp/args" && grep -q 'Do not run again' "$tmp/err"; then
  echo "ok: a failed close after filing exits 4 with a do-not-rerun message"
else echo "FAIL: close failure rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

GH_CREATE_URL="https://example.invalid/oops" run --kind harness --title t --body-file "$full_body" \
  --resolved-by https://github.com/o/r/pull/9
if [ "$rc" -eq 4 ] && ! grep -qxF '[close]' "$tmp/args" && grep -q 'Do not run again' "$tmp/err"; then
  echo "ok: an unreadable issue number after filing exits 4 without closing"
else echo "FAIL: number parse failure rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

# --- --list-groups ------------------------------------------------------------
# Lists open groups so the caller can pick --parent. No body, no template.
GH_LIST_OUT="$(printf '#5\tsome group\n')" run --list-groups
if [ "$rc" -eq 0 ] \
  && grep -qxF '[list]' "$tmp/args" \
  && [ "$(argval --label)" = group ] \
  && [ "$(argval --state)" = open ] \
  && [ "$(argval -R)" = "$issue_repo" ] \
  && ! grep -qxF '[--author]' "$tmp/args" \
  && ! grep -qxF '[create]' "$tmp/args" \
  && grep -qF "$(printf '#5\tsome group')" "$tmp/out"; then
  echo "ok: --list-groups lists the issue repo's open groups without validating a body"
else echo "FAIL: --list-groups rc=$rc args=$(cat "$tmp/args") out=$(cat "$tmp/out")"; fail=1; fi

# --list-groups takes no filing flag: combined with one it is refused before
# gh is called, rather than silently ignoring the flag.
run --list-groups --kind harness
if [ "$rc" -eq 1 ] && [ ! -s "$tmp/args" ]; then
  echo "ok: --list-groups with another flag exits 1 without calling gh"
else echo "FAIL: --list-groups exclusivity rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

# --- --repo -------------------------------------------------------------------
# Prints the issue repo, from ISSUE_REPO when set and from the dotrc config file
# (bin/lib/dotrc-config.sh) otherwise. The only gh call is the privacy check.
run --repo
if [ "$rc" -eq 0 ] && [ "$(cat "$tmp/out")" = "$issue_repo" ] \
  && grep -qxF '[isPrivate]' "$tmp/args" && ! grep -qxF '[issue]' "$tmp/args"; then
  echo "ok: --repo prints ISSUE_REPO after the privacy check, reading no issue"
else echo "FAIL: --repo rc=$rc out=$(cat "$tmp/out") args=$(cat "$tmp/args")"; fail=1; fi

# run_unset <args...> -- like run, with ISSUE_REPO absent from the environment.
# HOME is the sandbox's, so the config file is whatever the case wrote there.
dotrc_cfg="$HOME/.config/dotrc/config"
run_unset() {
  : >"$tmp/args"
  ( cd "$isorepo" && env -u ISSUE_REPO GH_ARGS_FILE="$tmp/args" PATH="$stubdir:$PATH" \
      "$isorepo/bin/gh-issue-file" "$@" ) >"$tmp/out" 2>"$tmp/err"
  rc=$?
}

mkdir -p "${dotrc_cfg%/*}"
printf '# machine-local\nISSUE_REPO=example-owner/from-config\n' >"$dotrc_cfg"
run_unset --repo
if [ "$rc" -eq 0 ] && [ "$(cat "$tmp/out")" = "example-owner/from-config" ]; then
  echo "ok: --repo without ISSUE_REPO prints the name from the dotrc config file"
else echo "FAIL: --repo from config rc=$rc out=$(cat "$tmp/out") err=$(cat "$tmp/err")"; fail=1; fi

# Not configured: exit 3 before any gh call, naming the file and the line to add.
rm -f "$dotrc_cfg"
run_unset --kind harness --title t --body-file "$full_body"
if [ "$rc" -eq 3 ] && [ ! -s "$tmp/args" ] && grep -qF "$dotrc_cfg" "$tmp/err" \
    && grep -qF 'ISSUE_REPO=' "$tmp/err"; then
  echo "ok: unconfigured issue repo exits 3 without calling gh, naming the config line"
else echo "FAIL: unconfigured rc=$rc args=$(cat "$tmp/args") err=$(cat "$tmp/err")"; fail=1; fi

# A value that is not OWNER/NAME is refused the same way (it ends up in -R and,
# in issue-crawl, inside an --allowedTools pattern).
printf 'ISSUE_REPO=example-owner/x *) Bash(*\n' >"$dotrc_cfg"
run_unset --kind harness --title t --body-file "$full_body"
if [ "$rc" -eq 3 ] && [ ! -s "$tmp/args" ]; then
  echo "ok: a malformed ISSUE_REPO exits 3 without calling gh"
else echo "FAIL: malformed rc=$rc args=$(cat "$tmp/args") err=$(cat "$tmp/err")"; fail=1; fi
rm -f "$dotrc_cfg"

run --repo --list-groups
if [ "$rc" -eq 1 ] && [ ! -s "$tmp/args" ]; then
  echo "ok: --repo with --list-groups exits 1 without calling gh"
else echo "FAIL: --repo --list-groups rc=$rc args=$(cat "$tmp/args")"; fail=1; fi

run --repo --kind harness
if [ "$rc" -eq 1 ] && [ ! -s "$tmp/args" ]; then
  echo "ok: --repo with another flag exits 1"
else echo "FAIL: --repo exclusivity rc=$rc out=$(cat "$tmp/out")"; fail=1; fi

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
# it is missing that heading. This needs its own throwaway git repo holding a
# copy of bin/, since the wrapper reads the template from the repo it lives in.
tmpl_repo="$tmp/tmplrepo"
mkdir -p "$tmpl_repo/.github/ISSUE_TEMPLATE"
cp -a "$bindir" "$tmpl_repo/bin"
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
    PATH="$stubdir:$PATH" "$tmpl_repo/bin/gh-issue-file" --kind task --title t \
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
# gh runs with the script repo's root as its cwd (mise exec -C "$root"), not the
# caller's, so a relative --body-file handed straight to gh would be resolved
# against the root. The wrapper hands gh an absolute copy instead. The fixture makes the
# failure mode visible rather than merely absent: a DECOY body.md sits at the
# root, so dropping the absolutisation does not error out -- it quietly files
# the wrong file, which is exactly the silent class this guards.
relrepo="$tmp/relrepo"
mkdir -p "$relrepo/.github/ISSUE_TEMPLATE" "$relrepo/sub"
cp -a "$bindir" "$relrepo/bin"
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

relrun "$relrepo/bin"
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


# --- Case P: filing does not depend on cwd ----------------------------------
# An agent working in an unrelated project files exactly as one in this repo:
# the template comes from the repo holding the script and the issue goes to the
# issue repo via -R. The fixture is two throwaway repos -- a "script repo"
# holding a copy of bin/ (stands in for dotrc) and an unrelated cwd repo --
# mirroring test/claude-worktree.test.sh. gh is the stub throughout.
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

globalrun() {  # globalrun <bindir> <cwd> <title> [extra flags...]
  : >"$tmp/args"; : >"$tmp/pwd"
  ( cd "$2" && env -u CLAUDE_CODE_SESSION_ID GH_ARGS_FILE="$tmp/args" \
      GH_PWD_FILE="$tmp/pwd" PATH="$stubdir:$PATH" \
      "$1/gh-issue-file" --kind harness --title "$3" --body-file "$global_body" "${@:4}" ) \
    >"$tmp/out" 2>"$tmp/err"
  rc=$?
}
filed_into_issue_repo() {
  [ "$rc" -eq 0 ] \
    && [ "$(cat "$tmp/pwd" 2>/dev/null)" = "$scriptrepo_real" ] \
    && grep -qxF '[create]' "$tmp/args" \
    && [ "$(argval -R)" = "$issue_repo" ]
}

# From an unrelated repo, without --global: the script repo's template, gh run
# in the script repo (its token), the issue repo as the target.
globalrun "$scriptrepo/bin" "$otherrepo" t
if filed_into_issue_repo; then
  echo "ok: from an unrelated repo the script repo's template is used and the issue goes to the issue repo"
else echo "FAIL: cwd-independent rc=$rc pwd=$(cat "$tmp/pwd" 2>/dev/null) args=$(cat "$tmp/args") err=$(cat "$tmp/err")"; fail=1; fi

# --global is accepted and changes nothing.
globalrun "$scriptrepo/bin" "$otherrepo" t --global
if filed_into_issue_repo; then
  echo "ok: --global is accepted and ignored"
else echo "FAIL: --global rc=$rc pwd=$(cat "$tmp/pwd" 2>/dev/null) err=$(cat "$tmp/err")"; fail=1; fi

# Discrimination (evidence-over-guesswork §4): the template root is resolved
# from cwd instead, and the first case must break. The mutant sits inside the
# script repo so that, unmutated, it would still find the template there.
# `cmp` keeps the check from rotting into a no-op if the tag goes.
globalmutant="$scriptrepo/mutbin"
rm -rf "$globalmutant"; mkdir -p "$globalmutant"
cp -a "$bindir/." "$globalmutant/"
sed 's|^.*template-root@dotrc$|root="$(git rev-parse --show-toplevel)"|' \
  "$bindir/gh-issue-file" >"$globalmutant/gh-issue-file"
chmod +x "$globalmutant/gh-issue-file"
if cmp -s "$bindir/gh-issue-file" "$globalmutant/gh-issue-file"; then
  echo "FAIL: the template-root mutant is identical to gh-issue-file; the check above is a no-op"; fail=1
fi
globalrun "$globalmutant" "$otherrepo" t
if [ "$rc" -eq 1 ] && grep -q 'no template at' "$tmp/err"; then
  echo "ok: resolving the template root from cwd loses the template (the case above is discriminating)"
else echo "FAIL: template-root mutant rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

# Mutant: the -R on create dropped; the issue-repo assertion must catch it.
rm -rf "$globalmutant"; mkdir -p "$globalmutant"
cp -a "$bindir/." "$globalmutant/"
sed 's|gh_mise issue create -R "\$ISSUE_REPO"|gh_mise issue create|' \
  "$bindir/gh-issue-file" >"$globalmutant/gh-issue-file"
chmod +x "$globalmutant/gh-issue-file"
if cmp -s "$bindir/gh-issue-file" "$globalmutant/gh-issue-file"; then
  echo "FAIL: the no-R mutant is identical to gh-issue-file; the check below is a no-op"; fail=1
fi
globalrun "$globalmutant" "$otherrepo" t
if ! filed_into_issue_repo; then
  echo "ok: dropping -R from create is caught (the issue-repo assertion is discriminating)"
else echo "FAIL: no-R mutant still looked like it filed into the issue repo"; fail=1; fi
rm -rf "$globalmutant"

# --- Case Q: no content gate on a filing from another repo ------------------
# A filing from an unrelated repo is created whether or not a
# .issue-denylist file exists in the script repo, and whatever that file lists:
# the wrapper does not read it. Against a wrapper that does (refusing without a
# usable list, or on a listed term), both runs below exit non-zero.
rm -f "$scriptrepo/.issue-denylist"
globalrun "$scriptrepo/bin" "$otherrepo" 'about example-corp things'
if [ "$rc" -eq 0 ] && grep -qxF '[create]' "$tmp/args"; then
  echo "ok: a filing from another repo files with no .issue-denylist present"
else echo "FAIL: no-denylist foreign rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

printf 'Example-Corp\n' >"$scriptrepo/.issue-denylist"
globalrun "$scriptrepo/bin" "$otherrepo" 'about example-corp things'
if [ "$rc" -eq 0 ] && grep -qxF '[create]' "$tmp/args"; then
  echo "ok: a filing from another repo files even when .issue-denylist lists a word in the title"
else echo "FAIL: denylist-present foreign rc=$rc err=$(cat "$tmp/err")"; fail=1; fi
rm -f "$scriptrepo/.issue-denylist"

# --- argument errors come before the issue repo is resolved -----------------------
# With nothing configured, bad input is still exit 1 (the caller's mistake), not
# 3 (the machine's). The arguments need no issue repo to be judged.
rm -f "$dotrc_cfg"
for bad in "--kind bogus --title t --body-file $full_body" "--kind task" \
    "--kind task --title t" "--kind task --title t --body-file $tmp/does-not-exist.md" \
    "--list-groups --kind harness" "--repo --kind harness" "--bogus"; do
  # shellcheck disable=SC2086
  run_unset $bad
  if [ "$rc" -eq 1 ] && [ ! -s "$tmp/args" ]; then
    echo "ok: with no issue repo configured, '${bad%% --body-file*}' still exits 1 (arguments are checked first)"
  else echo "FAIL: arg check before config '$bad' rc=$rc err=$(cat "$tmp/err")"; fail=1; fi
done

# Discrimination: the issue repo resolved before the arguments are read turns
# the same bad input into exit 3.
ordmut="$tmp/ordmut"; rm -rf "$ordmut"; mkdir -p "$ordmut"; cp -a "$bindir/." "$ordmut/"
sed 's|^kind=""; title=""|. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/issue-repo.sh"\n&|' \
  "$bindir/gh-issue-file" >"$ordmut/gh-issue-file"
chmod +x "$ordmut/gh-issue-file"
if cmp -s "$bindir/gh-issue-file" "$ordmut/gh-issue-file"; then
  echo "FAIL: the source-order mutant is identical; the check below is a no-op"; fail=1
fi
( cd "$isorepo" && env -u ISSUE_REPO GH_ARGS_FILE="$tmp/args" PATH="$stubdir:$PATH" \
    "$ordmut/gh-issue-file" --kind bogus --title t --body-file "$full_body" ) >"$tmp/out" 2>"$tmp/err"; rc=$?
if [ "$rc" -eq 3 ]; then
  echo "ok: resolving the issue repo before the arguments turns bad input into exit 3 (the case above is discriminating)"
else echo "FAIL: source-order mutant rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

# --- the issue repo must be private (fail closed) ---------------------------------
# Public, an unreadable lookup and output that is not `true` all stop every mode
# with exit 5 before any issue is read or written (and --repo prints nothing).
for v in GH_PRIVATE=false GH_EXIT_REPO=1 GH_PRIVATE=maybe GH_PRIVATE=; do
  for mode in repo groups file; do
    case "$mode" in
      repo)   a=(--repo) ;;
      groups) a=(--list-groups) ;;
      file)   a=(--kind harness --title t --body-file "$full_body") ;;
    esac
    export "${v?}"
    run "${a[@]}"
    unset "${v%%=*}"
    if [ "$rc" -eq 5 ] && ! grep -qxF '[issue]' "$tmp/args" && [ ! -s "$tmp/out" ] \
      && grep -qE 'not private|cannot verify' "$tmp/err"; then
      echo "ok: $mode with $v exits 5 before any issue is read or written"
    else echo "FAIL: private check $mode $v rc=$rc args=$(cat "$tmp/args") out=$(cat "$tmp/out") err=$(cat "$tmp/err")"; fail=1; fi
  done
done

# Discrimination: with the check removed, or its comparison loosened to "any
# output", a public repo goes through. Each mutant runs from a copy of bin/.
privmut() {  # privmut <name> <file under bin/> <sed expr>; sets $privmut_dir
  privmut_dir="$tmp/privmut-$1"; rm -rf "$privmut_dir"; mkdir -p "$privmut_dir"
  cp -a "$bindir/." "$privmut_dir/"
  sed "$3" "$bindir/$2" >"$privmut_dir/$2"
  chmod +x "$privmut_dir/$2"
  if cmp -s "$bindir/$2" "$privmut_dir/$2"; then
    echo "FAIL: the $1 mutant is identical; the check below is a no-op"; fail=1
  fi
}
privmut nocall gh-issue-file '/private-check@dotrc$/d'
( cd "$isorepo" && env GH_PRIVATE=false GH_ARGS_FILE="$tmp/args" PATH="$stubdir:$PATH" \
    "$privmut_dir/gh-issue-file" --repo ) >"$tmp/out" 2>"$tmp/err"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$tmp/out")" = "$issue_repo" ]; then
  echo "ok: without the check a public issue repo is used (the exit-5 cases are discriminating)"
else echo "FAIL: no-call mutant rc=$rc out=$(cat "$tmp/out")"; fail=1; fi
privmut loose lib/issue-repo.sh 's|\[ "\$last" != true \]|[ -z "$last" ]|'
( cd "$isorepo" && env GH_PRIVATE=false GH_ARGS_FILE="$tmp/args" PATH="$stubdir:$PATH" \
    "$privmut_dir/gh-issue-file" --repo ) >"$tmp/out" 2>"$tmp/err"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$tmp/out")" = "$issue_repo" ]; then
  echo "ok: a comparison loosened to any output lets a public repo through (the exit-5 cases are discriminating)"
else echo "FAIL: loose-compare mutant rc=$rc out=$(cat "$tmp/out")"; fail=1; fi

exit "$fail"
