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

exit "$fail"
