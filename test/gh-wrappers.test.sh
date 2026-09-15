#!/usr/bin/env bash
# Functional tests for the gh wrappers. A gh stub records its argv (one element
# per bracketed line) so we assert each wrapper issues exactly the intended gh
# command -- and, for gh-automerge, that no extra flags (e.g. --admin) leak
# through. No test framework; run with bash.
#
# Every wrapper now reaches gh through `mise exec -C <repo root> -- gh`
# (bin/lib/gh-mise.sh), so each stub directory also carries a mise stub that
# re-runs the command after `--`. Without it these tests would fall through to
# the real mise on PATH, which is both slower and not hermetic. The mise stub
# records into MISE_ARGS_FILE rather than GH_ARGS_FILE because the gh stubs
# below truncate the latter on entry; only the mise-plumbing section at the end
# sets it.
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
# Where gh was run matters now that the wrappers move its cwd to the repo root;
# only the mise-plumbing section sets GH_PWD_FILE, so nothing else is affected.
[ -z "${GH_PWD_FILE:-}" ] || pwd -P >"$GH_PWD_FILE"
# The token gh would authenticate with; only the real-mise case sets GH_TOKEN_FILE.
[ -z "${GH_TOKEN_FILE:-}" ] || printf '%s\n' "${GH_TOKEN:-}" >"$GH_TOKEN_FILE"
STUB
chmod +x "$stubdir/gh"

# Stands in for `mise exec -C <dir> -- <cmd> [args...]`: records its own argv
# under a `mise:` prefix, followed by the MISE_ENV it was called with, then runs
# the command in <dir> exactly as mise does.
# Installed into every stub directory so no test reaches the real mise.
install_mise_stub() {  # install_mise_stub <dir>
  cat >"$1/mise" <<'STUB'
#!/usr/bin/env bash
[ -z "${MISE_ARGS_FILE:-}" ] || printf '[mise:%s]\n' "$@" "MISE_ENV=${MISE_ENV:-}" >>"$MISE_ARGS_FILE"
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
  chmod +x "$1/mise"
}
install_mise_stub "$stubdir"

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

# gh-automerge clean-status fallback. A second stub, kept under $stubdir so the
# existing trap cleans it up: it appends (rather than truncates) so both gh
# calls of one run are visible in one argv log, and fails the `--auto` call with
# whatever GH_AUTO_FAIL_MSG says. GitHub refuses enablePullRequestAutoMerge on a
# CLEAN pull request ("Pull request is in clean status"), which a repo with no
# CI workflows hits almost immediately -- so that one refusal, and only it, must
# fall through to a direct merge.
amdir="$stubdir/am"; mkdir -p "$amdir"
cat >"$amdir/gh" <<'STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$@" >>"$GH_ARGS_FILE"
case "$*" in
  *--auto*)
    [ -n "${GH_AUTO_FAIL_MSG:-}" ] || exit 0
    echo "$GH_AUTO_FAIL_MSG" >&2
    exit "${GH_AUTO_FAIL_RC:-1}" ;;
esac
exit 0
STUB
chmod +x "$amdir/gh"
install_mise_stub "$amdir"

amrun() {  # $1 = --auto failure message ("" = succeed), $2 = its exit code
  : >"$amdir/args"
  env GH_ARGS_FILE="$amdir/args" GH_AUTO_FAIL_MSG="$1" GH_AUTO_FAIL_RC="${2:-1}" \
    PATH="$amdir:$PATH" "$bindir/gh-automerge" 42
}
amcount() { grep -cxF "$1" "$amdir/args"; }  # occurrences of one argv element

# Case A: the clean refusal falls back to a plain `gh pr merge --merge <PR>`
# (two --merge, one --auto), still without --admin.
amrun 'X GraphQL: Pull request is in clean status (enablePullRequestAutoMerge)' 1 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] \
  && [ "$(amcount '[--auto]')" -eq 1 ] && [ "$(amcount '[--merge]')" -eq 2 ] \
  && [ "$(amcount '[42]')" -eq 2 ] \
  && ! grep -qxF '[--admin]' "$amdir/args"; then
  echo "ok: gh-automerge falls back to a direct merge when auto-merge is refused for clean status"
else echo "FAIL: gh-automerge clean fallback rc=$rc args=$(cat "$amdir/args" 2>/dev/null)"; fail=1; fi

# Case B: any other refusal (unmet required check, conflict, ...) must NOT fall
# back -- the failure is the caller's to handle, and its exit code is preserved.
amrun 'X GraphQL: Required status check "build" is expected (enablePullRequestAutoMerge)' 2 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ] \
  && [ "$(amcount '[--auto]')" -eq 1 ] && [ "$(amcount '[--merge]')" -eq 1 ]; then
  echo "ok: gh-automerge does not fall back on a non-clean-status failure and preserves its exit code"
else echo "FAIL: gh-automerge non-clean failure rc=$rc args=$(cat "$amdir/args" 2>/dev/null)"; fail=1; fi

# Case C: when auto-merge is enabled successfully, no direct merge is issued.
amrun '' >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] \
  && [ "$(amcount '[--auto]')" -eq 1 ] && [ "$(amcount '[--merge]')" -eq 1 ]; then
  echo "ok: gh-automerge issues no direct merge once auto-merge is enabled"
else echo "FAIL: gh-automerge success path rc=$rc args=$(cat "$amdir/args" 2>/dev/null)"; fail=1; fi

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

# gh-list-threads: output is the bare thread array, so the obvious unresolved
# count is the real one. The stub prints the GraphQL envelope and, unlike the
# recorder above, honours --jq (via system jq) -- the unwrap under test *is* the
# --jq, so a stub that ignored it could not tell the two shapes apart. Against
# the envelope the same filter yields 0 without an error, which is the failure
# this guards: an "all resolved" that looks safe.
ltdir="$stubdir/lt"; mkdir -p "$ltdir"
cat >"$ltdir/gh" <<'STUB'
#!/usr/bin/env bash
jqexpr=""
prev=""
for a in "$@"; do
  [ "$prev" = "--jq" ] && jqexpr="$a"
  prev="$a"
done
case "$1" in
  repo) out='{"owner":{"login":"o"},"name":"r"}' ;;
  api)  out='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
          {"id":"PRRT_1","isResolved":false,"isOutdated":false,"comments":{"nodes":[]}},
          {"id":"PRRT_2","isResolved":true,"isOutdated":false,"comments":{"nodes":[]}},
          {"id":"PRRT_3","isResolved":false,"isOutdated":true,"comments":{"nodes":[]}}]}}}}}' ;;
esac
if [ -n "$jqexpr" ]; then printf '%s' "$out" | jq -r "$jqexpr"; else printf '%s\n' "$out"; fi
STUB
chmod +x "$ltdir/gh"
install_mise_stub "$ltdir"
out="$(PATH="$ltdir:$PATH" "$bindir/gh-list-threads" 7 2>/dev/null)"; rc=$?
unresolved="$(printf '%s' "$out" | jq '[.[] | select(.isResolved == false)] | length' 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$unresolved" = 2 ] \
  && printf '%s' "$out" | jq -e 'type == "array" and length == 3' >/dev/null; then
  echo "ok: gh-list-threads prints the thread array, so the unresolved count is real"
else echo "FAIL: gh-list-threads shape rc=$rc unresolved=$unresolved out=$out"; fail=1; fi

# gh-list-threads: missing / non-numeric arg fail.
PATH="$stubdir:$PATH" "$bindir/gh-list-threads" >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-list-threads missing arg fails" || { echo "FAIL: gh-list-threads missing arg"; fail=1; }
PATH="$stubdir:$PATH" "$bindir/gh-list-threads" x9 >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-list-threads non-numeric fails" || { echo "FAIL: gh-list-threads non-numeric"; fail=1; }

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

# --- gh-pr-checks -----------------------------------------------------------
# gh-pr-checks consumes gh's *output*, so it needs a stub that answers each call
# with a fixture. The stub does not implement --jq, so every fixture holds what
# gh would print *after* its --jq ran: scalars for repo/sha, and for the api
# calls the projected {workflow_runs: [...]} / {statuses: [...]} objects.
# Endpoints are matched with a trailing * because the wrapper appends --jq.
checksstub="$(mktemp -d)"
trap 'rm -rf "$stubdir" "$checksstub"' EXIT
cat >"$checksstub/gh" <<'STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$@" >>"$GH_ARGS_FILE"
case "$*" in
  "repo view"*)     cat "$GH_STUB_DIR/repo" ;;
  "pr view"*)       cat "$GH_STUB_DIR/sha" ;;
  *actions/runs*)   cat "$GH_STUB_DIR/runs" ;;
  *"/status"*)      cat "$GH_STUB_DIR/statuses" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$checksstub/gh"
install_mise_stub "$checksstub"

sha40='9ae7061c0c4b7b4f2b3b1f7a4d6e8c9f0a1b2c3d'
checksenv() { env GH_STUB_DIR="$1" GH_ARGS_FILE="$1/args" PATH="$checksstub:$PATH" \
  "$bindir/gh-pr-checks" "${@:2}"; }
checksfx() {  # $1 = dir, $2 = runs JSON, $3 = statuses JSON
  mkdir -p "$1"; : >"$1/args"
  echo 'knagiri/dotrc' >"$1/repo"; echo "$sha40" >"$1/sha"
  printf '%s' "$2" >"$1/runs"; printf '%s' "$3" >"$1/statuses"
}

# Case A: everything green -> has_failure false, and the Actions query filters by
# head_sha server-side while nothing touches the (403-under-fine-grained-PAT)
# check-runs endpoint.
fx="$checksstub/a"
checksfx "$fx" \
  '{"workflow_runs":[{"name":"Lint","status":"completed","conclusion":"success"},
                     {"name":"Test","status":"completed","conclusion":"skipped"}]}' \
  '{"statuses":[{"context":"ci/external","state":"success"}]}'
out=$(checksenv "$fx" 537 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | jq -e '.pr == 537' >/dev/null \
  && printf '%s' "$out" | jq -e --arg s "$sha40" '.sha == $s' >/dev/null \
  && printf '%s' "$out" | jq -e '.has_failure == false and .pending_count == 0' >/dev/null \
  && printf '%s' "$out" | jq -e '.checks | length == 3' >/dev/null \
  && printf '%s' "$out" | jq -e '.summary == "3 checks: 3 success, 0 pending, 0 failure"' >/dev/null \
  && grep -qF "head_sha=$sha40" "$fx/args" \
  && ! grep -qF 'check-runs' "$fx/args"; then
  echo "ok: gh-pr-checks reports a green PR (skipped is not a failure) via actions+statuses"
else echo "FAIL: gh-pr-checks green rc=$rc out=$out"; fail=1; fi

# Case B: a failed run, a queued run, a non-enumerated-status run ("waiting",
# which is a real Actions run status but not one of the literal enum values
# is_pending used to check) and a failed commit status are all counted.
fx="$checksstub/b"
checksfx "$fx" \
  '{"workflow_runs":[{"name":"Lint","status":"completed","conclusion":"failure"},
                     {"name":"Test","status":"queued","conclusion":null},
                     {"name":"Deploy","status":"waiting","conclusion":null}]}' \
  '{"statuses":[{"context":"ci/external","state":"error"},
                {"context":"ci/slow","state":"pending"}]}'
out=$(checksenv "$fx" 537 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | jq -e '.has_failure == true' >/dev/null \
  && printf '%s' "$out" | jq -e '.pending_count == 3' >/dev/null \
  && printf '%s' "$out" | jq -e '.summary == "5 checks: 0 success, 3 pending, 2 failure"' >/dev/null; then
  echo "ok: gh-pr-checks flags failures and counts pending (incl. non-enumerated 'waiting' status) across both sources"
else echo "FAIL: gh-pr-checks failure rc=$rc out=$out"; fail=1; fi

# Case C: no CI at all -> valid, empty, non-failing report.
fx="$checksstub/c"
checksfx "$fx" '{"workflow_runs":[]}' '{"statuses":[]}'
out=$(checksenv "$fx" 537 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | jq -e '.checks == [] and .has_failure == false and .pending_count == 0' >/dev/null; then
  echo "ok: gh-pr-checks reports an empty, non-failing state when no CI ran"
else echo "FAIL: gh-pr-checks empty rc=$rc out=$out"; fail=1; fi

# Case D: a runs payload past MAX_ARG_STRLEN (128 KiB / 131072 B) -- the
# regression this PR fixes. The old `--argjson runs "$runs"` implementation puts
# $runs on argv as a single element; Linux caps any *single* argv element at
# MAX_ARG_STRLEN regardless of the larger ARG_MAX total, so execve fails with
# E2BIG (the shell reports "Argument list too long") once $runs alone crosses
# that line. Piping to jq's stdin (this PR's fix) never goes through execve for
# the payload, so it has no such ceiling. The fixture is built here rather than
# committed so no ~370 KB JSON blob lives in the repo; the size assertion below
# guards against the generator silently drifting under the threshold and the
# case going quiet.
fx="$checksstub/d"
mkdir -p "$fx"; : >"$fx/args"
echo 'knagiri/dotrc' >"$fx/repo"; echo "$sha40" >"$fx/sha"
jq -nc '{workflow_runs: [range(4000) | {name: "Workflow-\(.)-with-a-fairly-long-name", status: "completed", conclusion: "success"}]}' >"$fx/runs"
printf '%s' '{"statuses":[]}' >"$fx/statuses"
[ "$(wc -c <"$fx/runs")" -gt 131072 ] \
  || { echo "FAIL: gh-pr-checks Case D fixture is not past MAX_ARG_STRLEN, test would be a no-op"; fail=1; }
out=$(checksenv "$fx" 537 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | jq -e '.checks | length == 4000' >/dev/null \
  && printf '%s' "$out" | jq -e '.summary == "4000 checks: 4000 success, 0 pending, 0 failure"' >/dev/null; then
  echo "ok: gh-pr-checks handles a runs payload past MAX_ARG_STRLEN (128 KiB argv element cap)"
else echo "FAIL: gh-pr-checks Case D rc=$rc out=${out:0:200}"; fail=1; fi

# Case E: superseded runs -- `concurrency: cancel-in-progress` leaves the killed
# run (cancelled) next to its replacement (success) under the same head SHA, and
# the stale cancelled one used to pin has_failure to true forever. Shaped after
# the measurement that prompted the fix, including the `Go Lint and Build` /
# `Go Test` pair sharing run_numbers 5119/5120: run_number is per-workflow, so a
# global comparison would be meaningless and the grouping by workflow_id is
# load-bearing (each same-named pair below shares one workflow_id, standing in
# for "same workflow file").
fx="$checksstub/e"
checksfx "$fx" \
  '{"workflow_runs":[{"name":"Packages Tests","status":"completed","conclusion":"cancelled","run_number":9525,"workflow_id":701},
                     {"name":"Packages Tests","status":"completed","conclusion":"success","run_number":9526,"workflow_id":701},
                     {"name":"Go Lint and Build","status":"completed","conclusion":"cancelled","run_number":5119,"workflow_id":702},
                     {"name":"Go Lint and Build","status":"completed","conclusion":"success","run_number":5120,"workflow_id":702},
                     {"name":"Go Test","status":"completed","conclusion":"success","run_number":5119,"workflow_id":703},
                     {"name":"Go Test","status":"completed","conclusion":"success","run_number":5120,"workflow_id":703}]}' \
  '{"statuses":[]}'
out=$(checksenv "$fx" 537 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | jq -e '.has_failure == false and .pending_count == 0' >/dev/null \
  && printf '%s' "$out" | jq -e '.summary == "6 checks: 6 success, 0 pending, 0 failure"' >/dev/null \
  && printf '%s' "$out" | jq -e '[.checks[] | select(.conclusion == "cancelled")] | length == 2 and all(.superseded)' >/dev/null \
  && printf '%s' "$out" | jq -e '[.checks[] | select(.run_number == 9526 or .run_number == 5120)] | all(.superseded | not)' >/dev/null; then
  echo "ok: gh-pr-checks does not count a cancelled run superseded by a newer completed run of the same workflow"
else echo "FAIL: gh-pr-checks superseded rc=$rc out=$out"; fail=1; fi

# Case F: a lone cancelled run still fails. A human stop or a job-level timeout
# looks exactly like this, and reading it as "passed" is the dangerous direction,
# so the exemption in case E must not generalise into an unconditional dedup.
# `Lint` carries a much higher run_number than the cancelled `E2E`: comparing
# run_numbers without grouping by workflow_id would wrongly exonerate E2E here.
fx="$checksstub/f"
checksfx "$fx" \
  '{"workflow_runs":[{"name":"E2E","status":"completed","conclusion":"cancelled","run_number":11,"workflow_id":810},
                     {"name":"Lint","status":"completed","conclusion":"success","run_number":99,"workflow_id":820}]}' \
  '{"statuses":[]}'
out=$(checksenv "$fx" 537 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | jq -e '.has_failure == true' >/dev/null \
  && printf '%s' "$out" | jq -e '.summary == "2 checks: 1 success, 0 pending, 1 failure"' >/dev/null \
  && printf '%s' "$out" | jq -e '.checks | all(.superseded | not)' >/dev/null; then
  echo "ok: gh-pr-checks still counts a lone cancelled run as a failure (no unconditional dedup)"
else echo "FAIL: gh-pr-checks lone cancelled rc=$rc out=$out"; fail=1; fi

# Case G: the three ways "newer completed run of the same workflow" can fail to
# hold. All must resolve conservatively, i.e. the cancelled run keeps counting:
# - Twin: the same-workflow run shares the run_number, so neither is newer.
# - NoKey: the cancelled run has no ordering key, so nothing can be shown newer.
# - Racing: the replacement exists but has not completed, so it cannot yet
#   vouch for anything -- the gate stays shut until it does.
fx="$checksstub/g"
checksfx "$fx" \
  '{"workflow_runs":[{"name":"Twin","status":"completed","conclusion":"cancelled","run_number":7,"workflow_id":831},
                     {"name":"Twin","status":"completed","conclusion":"success","run_number":7,"workflow_id":831},
                     {"name":"NoKey","status":"completed","conclusion":"cancelled","run_number":null,"workflow_id":832},
                     {"name":"NoKey","status":"completed","conclusion":"success","run_number":8,"workflow_id":832},
                     {"name":"Racing","status":"completed","conclusion":"cancelled","run_number":3,"workflow_id":833},
                     {"name":"Racing","status":"in_progress","conclusion":null,"run_number":4,"workflow_id":833}]}' \
  '{"statuses":[]}'
out=$(checksenv "$fx" 537 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | jq -e '.has_failure == true and .pending_count == 1' >/dev/null \
  && printf '%s' "$out" | jq -e '.summary == "6 checks: 2 success, 1 pending, 3 failure"' >/dev/null \
  && printf '%s' "$out" | jq -e '[.checks[] | select(.conclusion == "cancelled")] | length == 3 and all(.superseded | not)' >/dev/null; then
  echo "ok: gh-pr-checks treats an equal run_number, a missing run_number and an unfinished replacement as not superseding"
else echo "FAIL: gh-pr-checks superseded boundaries rc=$rc out=$out"; fail=1; fi

# Case H: a run with no workflow_id (the "name" field this dedup used to group
# by is nullable in GitHub's schema, and `--jq` turns any missing/nullable field
# into JSON null) must not abort the wrapper. jq's object-index operator raises
# a hard error ("Cannot index object with null") on a null key *before* the `//`
# fallback ever runs, so a naive `$newest[.workflow_id]` crashes jq with exit
# code 5 instead of falling through to -1. Regression check for that; run
# against the pre-fix jq program to confirm this actually fails there.
fx="$checksstub/h"
checksfx "$fx" \
  '{"workflow_runs":[{"name":null,"status":"completed","conclusion":"success","run_number":12,"workflow_id":null}]}' \
  '{"statuses":[]}'
out=$(checksenv "$fx" 537 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | jq -e '.has_failure == false and .pending_count == 0' >/dev/null \
  && printf '%s' "$out" | jq -e '.summary == "1 checks: 1 success, 0 pending, 0 failure"' >/dev/null; then
  echo "ok: gh-pr-checks does not abort on a run with a null grouping key"
else echo "FAIL: gh-pr-checks null-key rc=$rc out=$out"; fail=1; fi

# Case I: two distinct workflow *files* sharing the same name: run_number is
# per-file, so file A's high run_number must not exonerate file B's cancelled
# run just because jq grouped them by name. workflow_id (unique per file) is
# the correct grouping key; name is not. This is the dangerous direction (a
# real cancellation read as passed), unlike Case F's isolation by different
# names -- here the names collide and only workflow_id keeps them apart.
fx="$checksstub/i"
checksfx "$fx" \
  '{"workflow_runs":[{"name":"CI","status":"completed","conclusion":"cancelled","run_number":10,"workflow_id":901},
                     {"name":"CI","status":"completed","conclusion":"success","run_number":900,"workflow_id":902}]}' \
  '{"statuses":[]}'
out=$(checksenv "$fx" 537 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | jq -e '.has_failure == true' >/dev/null \
  && printf '%s' "$out" | jq -e '.summary == "2 checks: 1 success, 0 pending, 1 failure"' >/dev/null \
  && printf '%s' "$out" | jq -e '[.checks[] | select(.conclusion == "cancelled")] | length == 1 and all(.superseded | not)' >/dev/null; then
  echo "ok: gh-pr-checks does not let a same-named different-workflow_id run supersede a real cancellation"
else echo "FAIL: gh-pr-checks same-name distinct-workflow_id rc=$rc out=$out"; fail=1; fi

# gh-pr-checks: missing / non-numeric / extra-flag arg fail (no flag passthrough).
PATH="$checksstub:$PATH" "$bindir/gh-pr-checks" >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-pr-checks missing arg fails" || { echo "FAIL: gh-pr-checks missing arg"; fail=1; }
PATH="$checksstub:$PATH" "$bindir/gh-pr-checks" 9z >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-pr-checks non-numeric fails" || { echo "FAIL: gh-pr-checks non-numeric"; fail=1; }
PATH="$checksstub:$PATH" "$bindir/gh-pr-checks" 42 --watch >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-pr-checks rejects extra flag arg" || { echo "FAIL: gh-pr-checks extra flag"; fail=1; }

# --- gh-await-reviews -------------------------------------------------------
# A second stub: ignores argv and prints the Nth fixture on the Nth call (the
# last fixture repeats). gh-await-reviews consumes gh's *output*, so the argv
# recorder above is not enough. The stub emits the REQ/ACT tab-separated lines
# that the wrapper's --jq expression produces against real gh.
awaitstub="$(mktemp -d)"
trap 'rm -rf "$stubdir" "$checksstub" "$awaitstub"' EXIT
cat >"$awaitstub/gh" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$GH_STUB_COUNT" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" >"$GH_STUB_COUNT"
f="$GH_STUB_DIR/$n"
[ -f "$f" ] || f="$GH_STUB_DIR/$(ls "$GH_STUB_DIR" | sort -n | tail -1)"
cat "$f"
STUB
chmod +x "$awaitstub/gh"
install_mise_stub "$awaitstub"

# Fast clocks so the state machine is exercised in ~1s, not ~10min.
awaitenv() { env GH_AWAIT_REVIEWS_TIMEOUT=3 GH_AWAIT_REVIEWS_QUIET=1 \
  GH_AWAIT_REVIEWS_GRACE=1 GH_AWAIT_REVIEWS_POLL=1 \
  GH_STUB_DIR="$1" GH_STUB_COUNT="$1/.count" PATH="$awaitstub:$PATH" \
  "$bindir/gh-await-reviews" "${@:2}"; }

old='2020-01-01T00:00:00Z'

# Case A: an already-reviewed, quiet PR settles immediately (quiet is measured
# from the real timestamp, not from when we started polling). CRT is old so
# the $expected_floor_s gate (default 90s, irrelevant here since copilot
# already arrived) can never be the reason this settles.
fx="$awaitstub/a"; mkdir -p "$fx"
printf 'CRT\t%s\nACT\tcopilot-pull-request-reviewer\t%s\n' "$old" "$old" >"$fx/1"
out=$(awaitenv "$fx" 42 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | grep -q '"settled":true' \
  && printf '%s' "$out" | grep -q '"timed_out":false' \
  && printf '%s' "$out" | grep -q '"login":"copilot-pull-request-reviewer"' \
  && printf '%s' "$out" | grep -q "\"last_activity_at\":\"$old\""; then
  echo "ok: gh-await-reviews settles immediately on a quiet reviewed PR"
else echo "FAIL: gh-await-reviews quiet PR rc=$rc out=$out"; fail=1; fi

# Case B: copilot is requested but never posts -> timed_out with missing=[copilot].
fx="$awaitstub/b"; mkdir -p "$fx"
printf 'REQ\tcopilot-pull-request-reviewer\n' >"$fx/1"
out=$(awaitenv "$fx" 42 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | grep -q '"timed_out":true' \
  && printf '%s' "$out" | grep -q '"settled":false' \
  && printf '%s' "$out" | grep -q '"missing":\["copilot"\]' \
  && printf '%s' "$out" | grep -q '"arrived":false' \
  && printf '%s' "$out" | grep -q '"expected_unknown":false'; then
  echo "ok: gh-await-reviews times out with missing=[copilot] when copilot never posts"
else echo "FAIL: gh-await-reviews missing copilot rc=$rc out=$out"; fail=1; fi

# Case C: copilot requested, then arrives -> settled, expected.arrived=true.
fx="$awaitstub/c"; mkdir -p "$fx"
printf 'REQ\tcopilot-pull-request-reviewer\n' >"$fx/1"
printf 'ACT\tcopilot-pull-request-reviewer\t%s\n' "$old" >"$fx/2"
out=$(awaitenv "$fx" 42 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | grep -q '"settled":true' \
  && printf '%s' "$out" | grep -q '"name":"copilot"' \
  && printf '%s' "$out" | grep -q '"arrived":true' \
  && printf '%s' "$out" | grep -q '"missing":\[\]' \
  && printf '%s' "$out" | grep -q '"expected_unknown":false'; then
  echo "ok: gh-await-reviews settles once the requested copilot review arrives"
else echo "FAIL: gh-await-reviews copilot arrival rc=$rc out=$out"; fail=1; fi

# Case D: no expected reviewer and nobody posted -> settle after GRACE, empty
# report. CRT is old so the $expected_floor_s gate is already satisfied and
# GRACE (not the floor) is what this case is exercising.
fx="$awaitstub/d"; mkdir -p "$fx"
printf 'CRT\t%s\n' "$old" >"$fx/1"
out=$(awaitenv "$fx" 42 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | grep -q '"settled":true' \
  && printf '%s' "$out" | grep -q '"timed_out":false' \
  && printf '%s' "$out" | grep -q '"expected":\[\]' \
  && printf '%s' "$out" | grep -q '"observed":\[\]' \
  && printf '%s' "$out" | grep -q '"last_activity_at":null' \
  && printf '%s' "$out" | grep -q '"expected_unknown":true'; then
  echo "ok: gh-await-reviews settles after GRACE when no automated review runs"
else echo "FAIL: gh-await-reviews grace rc=$rc out=$out"; fail=1; fi

# Case E: a non-copilot participant (e.g. coderabbit) is tracked without any
# pre-arrival signal, and the PR author's own comment is not tracked. The
# wrapper's --jq already drops the author, so the fixture only carries others.
# CRT is old for the same reason as case D.
fx="$awaitstub/e"; mkdir -p "$fx"
printf 'CRT\t%s\nACT\tcoderabbitai\t%s\n' "$old" "$old" >"$fx/1"
out=$(awaitenv "$fx" 42 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | grep -q '"login":"coderabbitai"' \
  && printf '%s' "$out" | grep -q '"expected":\[\]' \
  && printf '%s' "$out" | grep -q '"expected_unknown":true' \
  && printf '%s' "$out" | grep -q '"settled":true'; then
  echo "ok: gh-await-reviews tracks a non-copilot participant with no pre-arrival signal"
else echo "FAIL: gh-await-reviews tracks coderabbit rc=$rc out=$out"; fail=1; fi

# Case F: PR just created (CRT ~= now), nothing posted, no reviewer requested.
# The floor (EXPECTED_FLOOR=90) outlives TIMEOUT=3, so an empty `expected`
# must not be believed within either the GRACE or the timeout window -- the
# floor keeps this timed_out rather than settling early, and does not itself
# stretch the overall timeout past TIMEOUT.
fx="$awaitstub/f"; mkdir -p "$fx"
printf 'CRT\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$fx/1"
out=$(env GH_AWAIT_REVIEWS_TIMEOUT=3 GH_AWAIT_REVIEWS_QUIET=1 GH_AWAIT_REVIEWS_GRACE=1 \
  GH_AWAIT_REVIEWS_POLL=1 GH_AWAIT_REVIEWS_EXPECTED_FLOOR=90 \
  GH_STUB_DIR="$fx" GH_STUB_COUNT="$fx/.count" PATH="$awaitstub:$PATH" \
  "$bindir/gh-await-reviews" 42 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | grep -q '"settled":false' \
  && printf '%s' "$out" | grep -q '"timed_out":true' \
  && printf '%s' "$out" | grep -Eq '"waited_seconds":[34]' \
  && printf '%s' "$out" | grep -q '"expected_unknown":true'; then
  echo "ok: gh-await-reviews floor outlasting TIMEOUT times out instead of settling early, without stretching TIMEOUT"
else echo "FAIL: gh-await-reviews floor-outlives-timeout rc=$rc out=$out"; fail=1; fi

# Case G: same fresh-PR fixture as F, but with a floor (1s) shorter than
# TIMEOUT (3s) -- once the floor age is reached, an empty `expected` may be
# believed and the PR settles instead of timing out.
fx="$awaitstub/g"; mkdir -p "$fx"
printf 'CRT\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$fx/1"
out=$(env GH_AWAIT_REVIEWS_TIMEOUT=3 GH_AWAIT_REVIEWS_QUIET=1 GH_AWAIT_REVIEWS_GRACE=1 \
  GH_AWAIT_REVIEWS_POLL=1 GH_AWAIT_REVIEWS_EXPECTED_FLOOR=1 \
  GH_STUB_DIR="$fx" GH_STUB_COUNT="$fx/.count" PATH="$awaitstub:$PATH" \
  "$bindir/gh-await-reviews" 42 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | grep -q '"settled":true' \
  && printf '%s' "$out" | grep -q '"timed_out":false' \
  && printf '%s' "$out" | grep -q '"expected_unknown":true'; then
  echo "ok: gh-await-reviews settles once a short floor has elapsed"
else echo "FAIL: gh-await-reviews short-floor rc=$rc out=$out"; fail=1; fi

# Case H: an ACT timestamp that fails to parse (`date -u -d` rejects it) must
# not crash the script before it emits JSON -- regression test for the inline
# `$(( now - $(date ...) ))` trap described above expected_settled(). CRT is
# old so only the quiet-window `date` call (not the floor) is exercised.
fx="$awaitstub/h"; mkdir -p "$fx"
printf 'CRT\t%s\nACT\tcoderabbitai\tgarbage\n' "$old" >"$fx/1"
out=$(awaitenv "$fx" 42 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | grep -q '"pr":42' \
  && printf '%s' "$out" | grep -q '"login":"coderabbitai"'; then
  echo "ok: gh-await-reviews emits JSON instead of crashing on an unparseable ACT timestamp"
else echo "FAIL: gh-await-reviews unparseable timestamp rc=$rc out=$out"; fail=1; fi

# gh-await-reviews: missing / non-numeric / extra-flag arg fail (no flag passthrough).
PATH="$awaitstub:$PATH" "$bindir/gh-await-reviews" >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-await-reviews missing arg fails" || { echo "FAIL: gh-await-reviews missing arg"; fail=1; }
PATH="$awaitstub:$PATH" "$bindir/gh-await-reviews" 9z >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-await-reviews non-numeric fails" || { echo "FAIL: gh-await-reviews non-numeric"; fail=1; }
PATH="$awaitstub:$PATH" "$bindir/gh-await-reviews" 42 --watch >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: gh-await-reviews rejects extra flag arg" || { echo "FAIL: gh-await-reviews extra flag"; fail=1; }

# --- mise env plumbing (bin/lib/gh-mise.sh) ---------------------------------
# Every wrapper must reach gh through `MISE_ENV=gh mise exec -C <repo root> --
# gh`: the PAT lives in mise.gh.local.toml, which mise reads only under
# MISE_ENV=gh, so it stays out of every shell's (and the bg daemon's) env and is
# loaded here at call time instead. Three things are asserted: the prefix is
# there, it carries MISE_ENV=gh, and the directory it names is the repo TOPLEVEL
# rather than the caller's cwd (the wrappers are run from a subdirectory to make
# those two differ). MISE_ENV is unset on the way in so an ambient value cannot
# satisfy the check.
#
# rc is deliberately not asserted in the sweep below: gh-pr-checks and
# gh-await-reviews consume gh's *output*, which the plain recorder does not
# supply. What is under test here is the prefix, not the wrapper's own logic --
# that is covered case by case above.
miserepo="$stubdir/miserepo"
mkdir -p "$miserepo/sub"
git -C "$miserepo" init -q
miserepo_real="$(cd "$miserepo" && pwd -P)"
miseargs="$stubdir/miseargs"

wrappers="gh-automerge gh-await-reviews gh-list-threads gh-pr-checks gh-pr-comments gh-resolve-thread"
wrapper_arg() {  # the one argument each wrapper's validation accepts
  case "$1" in gh-resolve-thread) echo 'PRRT_kwABC' ;; *) echo 42 ;; esac
}

# Runs <wrapper> from a subdirectory of $miserepo with the stubs on PATH.
# $2 (optional) overrides PATH, which the no-mise cases below need.
mise_run() {  # mise_run <bindir> <wrapper> [path]
  : >"$miseargs"; : >"$stubdir/args"; : >"$stubdir/pwd"
  ( cd "$miserepo/sub" && env -u MISE_ENV GH_ARGS_FILE="$stubdir/args" \
      MISE_ARGS_FILE="$miseargs" GH_PWD_FILE="$stubdir/pwd" \
      GH_AWAIT_REVIEWS_TIMEOUT=1 GH_AWAIT_REVIEWS_QUIET=0 \
      GH_AWAIT_REVIEWS_GRACE=0 GH_AWAIT_REVIEWS_POLL=1 \
      PATH="${3:-$stubdir:$PATH}" "$1/$2" "$(wrapper_arg "$2")" ) >/dev/null 2>&1
}

# True when the recorded mise argv is exactly the `exec -C <toplevel> -- gh`
# prefix this change is about, called with MISE_ENV=gh.
went_through_mise() {
  grep -qxF '[mise:MISE_ENV=gh]' "$miseargs" \
    && grep -qxF '[mise:exec]' "$miseargs" \
    && grep -qxF '[mise:-C]' "$miseargs" \
    && grep -qxF "[mise:$miserepo_real]" "$miseargs" \
    && grep -qxF '[mise:--]' "$miseargs" \
    && grep -qxF '[mise:gh]' "$miseargs"
}

for w in $wrappers; do
  mise_run "$bindir" "$w"
  if went_through_mise; then
    echo "ok: $w reaches gh through MISE_ENV=gh mise exec -C <repo toplevel>"
  else echo "FAIL: $w mise prefix mise=$(cat "$miseargs" 2>/dev/null)"; fail=1; fi
done

# Discrimination (evidence-over-guesswork §4). gh-mise.sh is a new file, so
# running these assertions against the pre-change wrappers would only prove the
# symbol did not exist yet. Instead the NEW code is mutated, one branch at a
# time, and each mutant must break the case that covers that branch. Mutants A
# and B rewrite the single `command -v mise` condition and mutant C drops the
# MISE_ENV=gh assignment, so all stay syntactically valid; `cmp` guards against
# the sed silently matching nothing and the checks below rotting into no-ops.
mutantdir="$stubdir/mutant"
mk_mutant() {  # mk_mutant <name> <sed expression applied to gh-mise.sh>
  rm -rf "${mutantdir:?}/${1:?}"; mkdir -p "${mutantdir:?}/${1:?}"
  cp -a "$bindir/." "$mutantdir/$1/"
  sed "$2" "$bindir/lib/gh-mise.sh" \
    >"$mutantdir/$1/lib/gh-mise.sh"
  if cmp -s "$bindir/lib/gh-mise.sh" "$mutantdir/$1/lib/gh-mise.sh"; then
    echo "FAIL: mutant '$1' is identical to gh-mise.sh; the check is a no-op"; fail=1
  fi
}

# Mutant A: mise is never used even though it is installed. The sweep above
# must fail against it -- otherwise those assertions were passing for some
# reason other than the prefix.
mk_mutant nomise 's|command -v mise >/dev/null 2>&1|false|'
mise_run "$mutantdir/nomise" gh-pr-comments
if ! went_through_mise && grep -qxF '[pr]' "$stubdir/args"; then
  echo "ok: forcing gh-mise.sh down its fallback branch loses the mise prefix (the sweep above is discriminating)"
else echo "FAIL: nomise mutant still recorded a mise prefix: $(cat "$miseargs" 2>/dev/null)"; fail=1; fi

# The no-mise environment for the two cases below: a PATH with the stubs but
# without mise anywhere. Stripping is iterative because mise may sit in more
# than one PATH entry. The control assertion is what keeps these cases honest:
# if mise were still reachable, "falls back" would pass vacuously.
nomise_path="$PATH"
while d="$(PATH="$nomise_path" command -v mise 2>/dev/null)"; do
  d="$(dirname "$d")"
  nomise_path="$(printf '%s' "$nomise_path" | tr ':' '\n' | grep -vxF "$d" | paste -sd: -)"
done
nomisedir="$stubdir/nomise"; mkdir -p "$nomisedir"
cp "$stubdir/gh" "$nomisedir/gh"
nomise_path="$nomisedir:$nomise_path"
if ! PATH="$nomise_path" command -v mise >/dev/null 2>&1; then
  echo "ok: the no-mise PATH really has no mise on it"
else echo "FAIL: no-mise PATH still resolves mise; the fallback cases would pass vacuously"; fail=1; fi

# With no mise installed the wrapper still runs gh -- and still runs it in the
# repo toplevel, so which repo a wrapper targets does not depend on whether
# mise happens to be installed.
mise_run "$bindir" gh-pr-comments "$nomise_path"
if grep -qxF '[pr]' "$stubdir/args" && [ ! -s "$miseargs" ] \
  && [ "$(cat "$stubdir/pwd" 2>/dev/null)" = "$miserepo_real" ]; then
  echo "ok: with no mise on PATH the wrapper calls gh directly, still in the repo toplevel"
else echo "FAIL: no-mise fallback args=$(cat "$stubdir/args" 2>/dev/null) pwd=$(cat "$stubdir/pwd" 2>/dev/null)"; fail=1; fi

# Mutant B: the fallback branch is removed (the condition is always true), so a
# machine without mise gets `mise: command not found`. The case above must fail
# against it -- that is what shows the fallback is load-bearing rather than
# decorative.
mk_mutant alwaysmise 's|command -v mise >/dev/null 2>&1|true|'
mise_run "$mutantdir/alwaysmise" gh-pr-comments "$nomise_path"
if [ ! -s "$stubdir/args" ]; then
  echo "ok: removing the fallback breaks the wrapper when mise is absent (the case above is discriminating)"
else echo "FAIL: alwaysmise mutant still reached gh without mise: $(cat "$stubdir/args" 2>/dev/null)"; fail=1; fi

# Mutant C: MISE_ENV=gh is dropped, which is exactly the pre-fix call. The sweep
# must fail against it; the prefix is otherwise intact, so this isolates the
# MISE_ENV assertion from the rest of went_through_mise.
mk_mutant nomiseenv 's|MISE_ENV=gh ||'
mise_run "$mutantdir/nomiseenv" gh-pr-comments
if ! went_through_mise && grep -qxF '[mise:exec]' "$miseargs"; then
  echo "ok: dropping MISE_ENV=gh fails the sweep while the rest of the prefix survives (the MISE_ENV check is discriminating)"
else echo "FAIL: nomiseenv mutant mise=$(cat "$miseargs" 2>/dev/null)"; fail=1; fi

# With the real mise: a repo holding both mise.local.toml and mise.gh.local.toml
# must keep the gh one out of plain `mise env` (what `mise activate` puts in a
# shell, and so in the bg daemon) while gh_mise hands it to gh. Hermetic: the
# repo is trusted via MISE_TRUSTED_CONFIG_PATHS rather than the user's trust
# store, the global config is pointed at nothing (so no user-configured tool --
# a mise-managed gh included -- shadows the stub), the config walk stops above
# the temp dir, and an ambient MISE_ENV / GH_TOKEN is removed.
realmise="$(command -v mise 2>/dev/null || true)"
if [ -z "$realmise" ]; then
  echo "skip: no real mise on PATH; the mise.gh.local.toml cases need it"
else
  rmroot="$stubdir/realmise"; rmrepo="$rmroot/repo"
  mkdir -p "$rmrepo/sub" "$rmroot/cfg"
  git -C "$rmrepo" init -q
  rmrepo_real="$(cd "$rmrepo" && pwd -P)"
  printf '[env]\nDOTRC_TEST_PLAIN = "plain-marker"\n' >"$rmrepo/mise.local.toml"
  printf '[env]\nGH_TOKEN = "tok-from-gh-env"\n' >"$rmrepo/mise.gh.local.toml"
  realmise_env() {  # realmise_env <cmd...>
    env -u MISE_ENV -u GH_TOKEN MISE_TRUSTED_CONFIG_PATHS="$rmrepo_real" \
      MISE_CEILING_PATHS="$(cd "$rmroot" && pwd -P)" \
      MISE_GLOBAL_CONFIG_FILE="$rmroot/none.toml" MISE_CONFIG_DIR="$rmroot/cfg" "$@"
  }
  # Runs the wrapper under the real mise with only the gh stub in front of it.
  realmise_run() {  # realmise_run <bindir>
    : >"$stubdir/args"; : >"$stubdir/token"
    ( cd "$rmrepo/sub" && realmise_env GH_ARGS_FILE="$stubdir/args" \
        GH_TOKEN_FILE="$stubdir/token" PATH="$nomisedir:$PATH" \
        "$1/gh-pr-comments" 42 ) >/dev/null 2>&1
  }

  # The plain-marker is the control: it proves mise read this repo's config, so
  # the token's absence is not just a config that was never loaded.
  plain_env="$(realmise_env "$realmise" env -C "$rmrepo_real/sub" 2>/dev/null)"
  if printf '%s' "$plain_env" | grep -qF 'plain-marker' \
    && ! printf '%s' "$plain_env" | grep -qF 'tok-from-gh-env'; then
    echo "ok: plain mise env loads mise.local.toml but not mise.gh.local.toml"
  else echo "FAIL: plain mise env=$plain_env"; fail=1; fi

  realmise_run "$bindir"
  if grep -qxF '[pr]' "$stubdir/args" \
    && [ "$(cat "$stubdir/token")" = "tok-from-gh-env" ]; then
    echo "ok: gh_mise hands gh the GH_TOKEN from mise.gh.local.toml (real mise)"
  else echo "FAIL: real mise gh_mise args=$(cat "$stubdir/args" 2>/dev/null) token=$(cat "$stubdir/token" 2>/dev/null)"; fail=1; fi

  realmise_run "$mutantdir/nomiseenv"
  if grep -qxF '[pr]' "$stubdir/args" && [ -z "$(cat "$stubdir/token")" ]; then
    echo "ok: without MISE_ENV=gh the real mise gives gh no token (the case above is discriminating)"
  else echo "FAIL: nomiseenv mutant under real mise args=$(cat "$stubdir/args" 2>/dev/null) token=$(cat "$stubdir/token" 2>/dev/null)"; fail=1; fi
fi

# --- gh-pr-create -----------------------------------------------------------
# Unlike the other wrappers this one passes every flag through: it exists only
# to put the repo's mise env in front of `gh pr create`, which my-create-pr used
# to call directly and which is what actually failed twice in a delegated agent.
# So the assertions are (a) the flags arrive untouched, (b) no flag is added,
# and (c) the two file-reading flags are absolutised before gh's cwd moves.
prcreatedir="$stubdir/prcreate"; mkdir -p "$prcreatedir/sub"
git -C "$prcreatedir" init -q 2>/dev/null || true
prcreate_real="$(cd "$prcreatedir" && pwd -P)"
printf 'REAL\n' >"$prcreatedir/sub/pr.md"
printf 'DECOY\n' >"$prcreatedir/pr.md"

prcreate_run() {  # prcreate_run <bindir> [args...]; runs from $prcreatedir/sub
  : >"$stubdir/args"
  ( cd "$prcreatedir/sub" && env GH_ARGS_FILE="$stubdir/args" \
      PATH="$stubdir:$PATH" "$1/gh-pr-create" "${@:2}" ) >/dev/null 2>&1
}

prcreate_run "$bindir" --title t --body b --base main
if grep -qxF '[pr]' "$stubdir/args" && grep -qxF '[create]' "$stubdir/args" \
  && grep -qxF '[--title]' "$stubdir/args" && grep -qxF '[t]' "$stubdir/args" \
  && grep -qxF '[--body]' "$stubdir/args" && grep -qxF '[b]' "$stubdir/args" \
  && grep -qxF '[--base]' "$stubdir/args" && grep -qxF '[main]' "$stubdir/args" \
  && [ "$(grep -c . "$stubdir/args")" -eq 8 ]; then
  echo "ok: gh-pr-create passes its flags through to gh pr create and adds none"
else echo "FAIL: gh-pr-create passthrough args=$(cat "$stubdir/args" 2>/dev/null)"; fail=1; fi

# A relative --body-file must still name the caller's file after gh's cwd moves
# to the repo root, where a DECOY of the same name sits. Both spellings, and the
# --body-file=<path> form, go through the same rewrite.
for flag in --body-file -F; do
  prcreate_run "$bindir" "$flag" pr.md
  if grep -qxF "[$prcreate_real/sub/pr.md]" "$stubdir/args"; then
    echo "ok: gh-pr-create absolutises a relative $flag value"
  else echo "FAIL: gh-pr-create $flag args=$(cat "$stubdir/args" 2>/dev/null)"; fail=1; fi
done

# --template is left exactly as given: gh matches it against the repo's own PR
# templates by name, so rewriting it could change what gh looks up.
prcreate_run "$bindir" --template pull_request_template.md
if grep -qxF '[pull_request_template.md]' "$stubdir/args"; then
  echo "ok: gh-pr-create leaves --template untouched (gh resolves it by name)"
else echo "FAIL: gh-pr-create --template args=$(cat "$stubdir/args" 2>/dev/null)"; fail=1; fi
prcreate_run "$bindir" --body-file=pr.md
if grep -qxF "[--body-file=$prcreate_real/sub/pr.md]" "$stubdir/args"; then
  echo "ok: gh-pr-create absolutises the --body-file=<path> form too"
else echo "FAIL: gh-pr-create --body-file= args=$(cat "$stubdir/args" 2>/dev/null)"; fail=1; fi

# "-" means stdin, not a path, so it must survive untouched.
prcreate_run "$bindir" --body-file -
if grep -qxF '[-]' "$stubdir/args"; then
  echo "ok: gh-pr-create leaves --body-file - alone"
else echo "FAIL: gh-pr-create stdin body args=$(cat "$stubdir/args" 2>/dev/null)"; fail=1; fi

# gh-pr-create reaches gh through mise, like every other wrapper.
: >"$miseargs"
( cd "$prcreatedir/sub" && env -u MISE_ENV GH_ARGS_FILE="$stubdir/args" MISE_ARGS_FILE="$miseargs" \
    PATH="$stubdir:$PATH" "$bindir/gh-pr-create" --title t ) >/dev/null 2>&1
if grep -qxF '[mise:exec]' "$miseargs" && grep -qxF "[mise:$prcreate_real]" "$miseargs" \
  && grep -qxF '[mise:gh]' "$miseargs" && grep -qxF '[mise:MISE_ENV=gh]' "$miseargs"; then
  echo "ok: gh-pr-create reaches gh through MISE_ENV=gh mise exec -C <repo toplevel>"
else echo "FAIL: gh-pr-create mise prefix mise=$(cat "$miseargs" 2>/dev/null)"; fail=1; fi

# Discrimination (evidence-over-guesswork §4): with the absolutisation stripped,
# the relative --body-file reaches gh as "pr.md" -- which, from the repo root,
# is the DECOY. `cmp` keeps the check from rotting into a no-op.
prcreatemutant="$stubdir/prcreatemutant"
rm -rf "$prcreatemutant"; mkdir -p "$prcreatemutant"
cp -a "$bindir/." "$prcreatemutant/"
grep -v 'abs-path-arg@dotrc' "$bindir/gh-pr-create" >"$prcreatemutant/gh-pr-create"
chmod +x "$prcreatemutant/gh-pr-create"
if cmp -s "$bindir/gh-pr-create" "$prcreatemutant/gh-pr-create"; then
  echo "FAIL: the gh-pr-create mutant is identical; the cases above are no-ops"; fail=1
fi
prcreate_run "$prcreatemutant" --body-file pr.md
if grep -qxF '[pr.md]' "$stubdir/args"; then
  echo "ok: dropping the absolutisation hands gh the bare relative path (the cases above are discriminating)"
else echo "FAIL: gh-pr-create mutant args=$(cat "$stubdir/args" 2>/dev/null)"; fail=1; fi

exit "$fail"
