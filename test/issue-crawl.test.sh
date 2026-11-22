#!/usr/bin/env bash
# Functional tests for bin/issue-crawl. Every command the crawler can reach --
# gh, mise, claude, claude-queue, claude-worktree and gh-issue-group -- is a
# stub on PATH that records its argv, so no test reads or writes a real repo,
# starts a session, or touches a daemon. gh answers from JSON fixtures in
# $fix. No test framework; run with bash.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
cd "$here/.." || exit 1
crawl="$here/../bin/issue-crawl"
fail=0

tmp="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$tmp"' EXIT
fix="$tmp/fix"; mkdir -p "$fix"
calls="$tmp/calls"

# --- stubs --------------------------------------------------------------------
stubdir="$tmp/stub"; mkdir -p "$stubdir"
cat >"$stubdir/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$CALLS"
has() { local a; for a in "${@:2}"; do [ "$a" = "$1" ] && return 0; done; return 1; }
after() { local p=""; for a in "${@:2}"; do [ "$p" = "$1" ] && { echo "$a"; return; }; p="$a"; done; }
# GH_FAIL=<word>_<word> (e.g. issue_list) makes that read fail.
[ "${GH_FAIL:-}" != "$1_${2:-}" ] || { echo "gh stub: forced failure" >&2; exit 1; }
case "$1 ${2:-}" in
  "repo view") echo example-owner ;;
  "issue list")
    if [ "$(after --label "$@")" = group ]; then cat "$FIX/groups.json"
    elif has --search "$@"; then cat "$FIX/obs_recent.json"
    else cat "$FIX/obs_open.json"; fi ;;
  "pr list") cat "$FIX/prs.json" ;;
  *) echo "gh stub: unexpected: $*" >&2; exit 1 ;;
esac
STUB
cat >"$stubdir/mise" <<'STUB'
#!/usr/bin/env bash
printf 'mise %s\n' "$*" >>"$CALLS"
dir=""
while [ $# -gt 0 ]; do
  case "$1" in -C) dir="$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac
done
cd "${dir:-.}" && exec "$@"
STUB
cat >"$stubdir/claude" <<'STUB'
#!/usr/bin/env bash
printf 'claude' >>"$CALLS"; printf ' [%s]' "$@" >>"$CALLS"; echo >>"$CALLS"
printf '%s' "${CLAUDE_CONFIG_DIR-unset}" >"$CLAUDE_STDIN.configdir"
cat >"$CLAUDE_STDIN"
STUB
cat >"$stubdir/claude-queue" <<'STUB'
#!/usr/bin/env bash
printf 'claude-queue %s\n' "$*" >>"$CALLS"
exit "${DAEMON_RC:-0}"
STUB
cat >"$stubdir/claude-worktree" <<'STUB'
#!/usr/bin/env bash
printf 'claude-worktree %s\n' "$*" >>"$CALLS"
exit "${WT_RC:-0}"
STUB
# Only the branch listing is faked; every other git call is the real git.
real_git="$(command -v git)"
cat >"$stubdir/git" <<STUB
#!/usr/bin/env bash
if [ "\${3:-}" = for-each-ref ] || [ "\${1:-}" = for-each-ref ]; then cat "\$FIX/branches.txt"; exit 0; fi
exec "$real_git" "\$@"
STUB
cat >"$stubdir/gh-issue-group" <<'STUB'
#!/usr/bin/env bash
printf 'gh-issue-group %s\n' "$*" >>"$CALLS"
STUB
chmod +x "$stubdir"/*

# Control: each stub, not a real command, is what PATH resolves.
for c in gh mise claude claude-queue claude-worktree gh-issue-group git; do
  if [ "$(PATH="$stubdir:$PATH" command -v "$c")" != "$stubdir/$c" ]; then
    echo "FAIL: $c does not resolve to its stub"; exit 1
  fi
done

now=2026-06-30T00:00:00Z
run() {  # run issue-crawl against the fixtures; sets $rc
  : >"$calls"; : >"$tmp/stdin"
  env CALLS="$calls" FIX="$fix" CLAUDE_STDIN="$tmp/stdin" PATH="$stubdir:$PATH" \
    CLAUDE_CONFIG_DIR=/leaked-from-the-timer-env \
    "$crawl" --now "$now" "$@" >"$tmp/out" 2>"$tmp/err"
  rc=$?
}
called() { grep -qxF -- "$1" "$calls"; }

# obs <number> <parent|null> <createdAt> <session|""> [author] [state] [body]
obs() {
  local body="${7:-observation $1}"
  [ -z "$4" ] || body="$body
<!-- observed-session: $4 -->"
  jq -n --argjson n "$1" --argjson p "$2" --arg c "$3" --arg a "${5:-example-owner}" \
    --arg s "${6:-OPEN}" --arg b "$body" \
    '{number:$n, createdAt:$c, author:{login:$a}, state:$s, body:$b,
      parent:(if $p == null then null else {number:$p} end)}'
}
# group <number> <state> <labels,csv> [stateReason] [closedAt] [author]
group() {
  jq -n --argjson n "$1" --arg s "$2" --arg l "$3" --arg r "${4:-}" --arg c "${5:-}" \
    --arg a "${6:-example-owner}" \
    '{number:$n, state:$s, author:{login:$a},
      stateReason:(if $r == "" then null else $r end),
      closedAt:(if $c == "" then null else $c end),
      labels:($l | split(",") | map({name:.}))}'
}

# --- count_group ----------------------------------------------------------------
# Sourced in library mode so the counting rule can be checked on its own.
count() {  # count <json-array>
  ( ISSUE_CRAWL_LIB=1; owner=example-owner; since=2026-05-31T00:00:00Z
    # shellcheck source=bin/issue-crawl
    . "$crawl"; count_group "$1" )
}
same_session="[$(obs 1 9 2026-06-10T00:00:00Z s1),$(obs 2 9 2026-06-11T00:00:00Z s1),$(obs 3 9 2026-06-12T00:00:00Z s1)]"
if [ "$(count "$same_session")" = 1 ]; then
  echo "ok: one session filing three observations counts once"
else echo "FAIL: same session count=$(count "$same_session")"; fail=1; fi

unmarked="[$(obs 1 9 2026-06-10T00:00:00Z ''),$(obs 2 9 2026-06-11T00:00:00Z ''),$(obs 3 9 2026-06-12T00:00:00Z '')]"
if [ "$(count "$unmarked")" = 3 ]; then
  echo "ok: observations without a session marker count one each"
else echo "FAIL: unmarked count=$(count "$unmarked")"; fail=1; fi

mixed="[$(obs 1 9 2026-06-10T00:00:00Z a),$(obs 2 9 2026-06-10T00:00:00Z b someone-else),$(obs 3 9 2026-05-01T00:00:00Z c)]"
if [ "$(count "$mixed")" = 1 ]; then
  echo "ok: observations by others or older than 30 days are not counted"
else echo "FAIL: mixed count=$(count "$mixed")"; fail=1; fi

# Discrimination (evidence-over-guesswork §4): with the session dedup removed
# the same-session case must count 3.
mutant="$tmp/issue-crawl.mutant"
sed 's#^.*session-key@dotrc$#      | null as $s#' "$crawl" >"$mutant"
if cmp -s "$crawl" "$mutant"; then
  echo "FAIL: the dedup mutant is identical; the check below is a no-op"; fail=1
fi
mcount="$( ISSUE_CRAWL_LIB=1; owner=example-owner; since=2026-05-31T00:00:00Z
  # shellcheck disable=SC1090
  . "$mutant"; count_group "$same_session" )"
if [ "$mcount" = 3 ]; then
  echo "ok: without the session dedup the same session counts 3 (the case above is discriminating)"
else echo "FAIL: dedup mutant count=$mcount"; fail=1; fi

# --- main fixture -------------------------------------------------------------
# Groups 1 and 3 reach the threshold (3), group 2 has the most (5). Group 4 was
# rejected and has nothing new since its PR closed; group 5 is delegated and
# its PR was closed unmerged; group 6 was completed but has two observations
# from after it closed (a recurrence) and one from before; group 7 has nothing
# recent; group 8 is someone else's; group 9 was closed as not planned with an
# older observation left open.
secret='SECRET-BODY-TEXT'
{
  echo '['
  group 1 OPEN agent-task,group; echo ,
  group 2 OPEN agent-task,group; echo ,
  group 3 OPEN agent-task,group; echo ,
  group 4 OPEN agent-task,group,group/rejected; echo ,
  group 5 OPEN agent-task,group,group/delegated; echo ,
  group 6 CLOSED agent-task,group COMPLETED 2026-06-10T00:00:00Z; echo ,
  group 7 OPEN agent-task,group; echo ,
  group 8 OPEN agent-task,group '' '' someone-else; echo ,
  group 9 CLOSED agent-task,group NOT_PLANNED 2026-06-10T00:00:00Z
  echo ']'
} >"$fix/groups.json"

recent=(
  "$(obs 11 1 2026-06-20T00:00:00Z a1)" "$(obs 12 1 2026-06-20T00:00:00Z a2)"
  "$(obs 13 1 2026-06-20T00:00:00Z a3)"
  "$(obs 91 1 2026-06-20T00:00:00Z x1 someone-else OPEN "$secret")"
  "$(obs 21 2 2026-06-20T00:00:00Z b1 example-owner OPEN "$secret")"
  "$(obs 22 2 2026-06-20T00:00:00Z b2)" "$(obs 23 2 2026-06-20T00:00:00Z b3)"
  "$(obs 24 2 2026-06-20T00:00:00Z b4)" "$(obs 25 2 2026-06-20T00:00:00Z b5)"
  "$(obs 31 3 2026-06-20T00:00:00Z c1)" "$(obs 32 3 2026-06-20T00:00:00Z c2)"
  "$(obs 33 3 2026-06-20T00:00:00Z c3)" "$(obs 34 3 2026-06-21T00:00:00Z c3)"
  "$(obs 41 4 2026-06-01T00:00:00Z d1)" "$(obs 42 4 2026-06-02T00:00:00Z d2)"
  "$(obs 43 4 2026-06-03T00:00:00Z d3)" "$(obs 44 4 2026-06-04T00:00:00Z d4)"
  "$(obs 45 4 2026-06-05T00:00:00Z d5)"
  "$(obs 51 5 2026-06-20T00:00:00Z e1)" "$(obs 52 5 2026-06-20T00:00:00Z e2)"
  "$(obs 53 5 2026-06-20T00:00:00Z e3)"
  "$(obs 61 6 2026-06-15T00:00:00Z f1)" "$(obs 62 6 2026-06-05T00:00:00Z f2)"
  "$(obs 65 6 2026-06-16T00:00:00Z f3)" "$(obs 64 9 2026-06-05T00:00:00Z h9)"
  "$(obs 90 null 2026-06-25T00:00:00Z g1)"
  "$(obs 101 null 2026-06-25T00:00:00Z g2 someone-else)"
)
(IFS=,; printf '[%s]\n' "${recent[*]}") >"$fix/obs_recent.json"
open_obs=(
  "$(obs 100 1 2026-05-20T00:00:00Z h1)"
  "$(obs 102 1 2026-06-01T00:00:00Z h2)"
  "$(obs 63 6 2026-05-10T00:00:00Z f0)"
  "$(obs 61 6 2026-06-15T00:00:00Z f1)" "$(obs 62 6 2026-06-05T00:00:00Z f2)"
  "$(obs 65 6 2026-06-16T00:00:00Z f3)" "$(obs 64 9 2026-06-05T00:00:00Z h9)"
  "$(obs 90 null 2026-06-25T00:00:00Z g1)"
  "$(obs 101 null 2026-06-25T00:00:00Z g2 someone-else)"
  "$(obs 103 null 2026-04-01T00:00:00Z g3 someone-else)"
)
(IFS=,; printf '[%s]\n' "${open_obs[*]}") >"$fix/obs_open.json"
# pr <number> <state> <mergedAt|null> <closedAt|null> <headRefName>
pr() {
  jq -n --argjson n "$1" --arg s "$2" --argjson m "$3" --argjson c "$4" --arg h "$5" \
    '{number:$n, state:$s, mergedAt:$m, closedAt:$c, headRefName:$h}'
}
prs() { (IFS=,; printf '[%s]\n' "$*") >"$fix/prs.json"; }
: >"$fix/branches.txt"
prs "$(pr 500 OPEN null null other-branch)" \
  "$(pr 401 CLOSED null '"2026-06-20T00:00:00Z"' group-4-20260610000000)" \
  "$(pr 501 CLOSED null '"2026-06-25T00:00:00Z"' group-5-20260615000000)"

run
[ "$rc" -eq 0 ] || { echo "FAIL: main run rc=$rc err=$(cat "$tmp/err")"; fail=1; }

# Expiry.
if called "gh-issue-group close 100 --not-planned" && ! grep -q 'gh-issue-group close 102' "$calls"; then
  echo "ok: an observation older than 30 days is closed; a younger one is not"
else echo "FAIL: observation expiry calls=$(cat "$calls")"; fail=1; fi
if ! grep -q 'gh-issue-group close 103' "$calls"; then
  echo "ok: someone else's stale issue is left alone"
else echo "FAIL: non-owner observation expired"; fail=1; fi
if called "gh-issue-group close 7 --not-planned" && ! grep -q 'gh-issue-group close 8' "$calls" \
  && ! grep -qE 'gh-issue-group close [1-5]( |$)' "$calls"; then
  echo "ok: only the group with no recent observation is closed"
else echo "FAIL: group expiry calls=$(cat "$calls")"; fail=1; fi
if called "gh-issue-group reopen 6" && called "gh-issue-group close 62" \
  && [ "$(grep -c '^gh-issue-group reopen 6$' "$calls")" -eq 1 ]; then
  echo "ok: a recurrence reopens a completed group once; an older leftover is closed"
else echo "FAIL: completed group handling calls=$(cat "$calls")"; fail=1; fi
# 63 is both stale and the leftover of a completed group: closed once, as stale.
if [ "$(grep -c '^gh-issue-group close 63' "$calls")" -eq 1 ] && called "gh-issue-group close 63 --not-planned"; then
  echo "ok: an observation closed as stale is not closed again as a leftover"
else echo "FAIL: stale leftover closed twice calls=$(cat "$calls")"; fail=1; fi
# 64's group was closed as not planned: its leftovers are not "completed".
if ! grep -q '^gh-issue-group close 64' "$calls"; then
  echo "ok: leftovers of a group closed as not planned are left open"
else echo "FAIL: not-planned leftover closed calls=$(cat "$calls")"; fail=1; fi

# PR follow-up.
if called "gh-issue-group mark 5 rejected" && ! grep -q 'gh-issue-group mark 4 ' "$calls"; then
  echo "ok: a delegated group whose PR closed unmerged is marked rejected"
else echo "FAIL: rejected marking calls=$(cat "$calls")"; fail=1; fi

# Delegation: one slot left (one open auto PR), so only the largest group goes,
# on a branch of its own and marked before the worktree starts.
wt="$(grep -c '^claude-worktree ' "$calls")"
if [ "$wt" -eq 1 ] && grep -q '^claude-worktree --global --model opus group-2-20260630000000 -- ' "$calls" \
  && called "gh-issue-group mark 2 delegated"; then
  echo "ok: the cap leaves one slot, filled by the group with the most observations"
else echo "FAIL: delegation wt=$wt calls=$(cat "$calls")"; fail=1; fi
mark_line="$(grep -n '^gh-issue-group mark 2 delegated$' "$calls" | cut -d: -f1)"
wt_line="$(grep -n '^claude-worktree ' "$calls" | cut -d: -f1)"
if [ -n "$mark_line" ] && [ -n "$wt_line" ] && [ "$mark_line" -lt "$wt_line" ]; then
  echo "ok: the group is marked delegated before its worktree starts"
else echo "FAIL: mark/worktree order mark=$mark_line wt=$wt_line"; fail=1; fi
if ! grep -qE '^claude-worktree .*group-(4|5)-' "$calls"; then
  echo "ok: rejected and just-rejected groups are not delegated"
else echo "FAIL: rejected group delegated"; fail=1; fi
if ! grep '^claude-worktree ' "$calls" | grep -q "$secret"; then
  echo "ok: the delegation prompt carries no observation body"
else echo "FAIL: observation body leaked into the delegation prompt"; fail=1; fi

# Clustering. The prompt is fixed; only the owner, the window start and a work
# dir are appended.
wd="$(tail -n1 "$tmp/stdin" | sed -n 's/^work dir: //p')"
if grep -qF "claude [-p] [--model] [sonnet] [--allowedTools] [Bash(gh-issue-group *),Bash(gh issue view *),Bash(gh issue list *),Edit(/$wd/**)]" "$calls" \
  && [ -n "$wd" ] \
  && { cat "$here/../dot/claude/crawler/cluster-prompt.md"
       printf '\nrepo owner: example-owner\nsince: 2026-05-31\nwork dir: %s\n' "$wd"; } | cmp -s - "$tmp/stdin" \
  && ! grep -q "$secret" "$tmp/stdin"; then
  echo "ok: unparented observations start claude -p with the fixed prompt, the owner, the window and the fixed tools"
else echo "FAIL: cluster invocation calls=$(cat "$calls")"; fail=1; fi
if grep -q '^mise .*-- claude ' "$calls" && [ "$(cat "$tmp/stdin.configdir")" = unset ]; then
  echo "ok: claude -p runs through mise in the repo, with the timer's CLAUDE_CONFIG_DIR removed"
else echo "FAIL: claude -p account selection calls=$(cat "$calls") dir=$(cat "$tmp/stdin.configdir")"; fail=1; fi

# --- no daemon ------------------------------------------------------------------
DAEMON_RC=1 run
if [ "$rc" -eq 0 ] && ! grep -q '^claude-worktree ' "$calls" \
  && ! grep -q 'mark [0-9]* delegated' "$calls" \
  && called "gh-issue-group close 100 --not-planned" \
  && grep -q 'skip: no daemon' "$tmp/out"; then
  echo "ok: without a daemon nothing is delegated, but expiry still runs"
else echo "FAIL: no daemon rc=$rc calls=$(cat "$calls") out=$(cat "$tmp/out")"; fail=1; fi

# Exit 2 means "cannot tell", which is not "no daemon": it is an error.
DAEMON_RC=2 run
if [ "$rc" -eq 2 ] && ! grep -q '^claude-worktree ' "$calls" \
  && ! grep -q 'skip: no daemon' "$tmp/out" && grep -q 'daemon-running exited 2' "$tmp/err"; then
  echo "ok: a daemon check that cannot tell is an error, not a quiet skip"
else echo "FAIL: daemon rc 2 rc=$rc out=$(cat "$tmp/out") err=$(cat "$tmp/err")"; fail=1; fi

# --- delegation that fails to start -----------------------------------------------
WT_RC=3 run
last_mark="$(grep '^gh-issue-group mark 2 ' "$calls" | tail -n1)"
if [ "$rc" -eq 2 ] && [ "$last_mark" = "gh-issue-group mark 2 clear" ]; then
  echo "ok: a worktree that fails to start leaves the group cleared and the pass exits 2"
else echo "FAIL: worktree failure rc=$rc last_mark=$last_mark calls=$(cat "$calls")"; fail=1; fi

# --- dry run --------------------------------------------------------------------
run --dry-run
if [ "$rc" -eq 0 ] && ! grep -qE '^(gh-issue-group|claude-worktree|claude) ' "$calls" \
  && grep -q 'delegate: group #2' "$tmp/out"; then
  echo "ok: --dry-run reports the plan without writing, clustering or delegating"
else echo "FAIL: dry run rc=$rc calls=$(cat "$calls")"; fail=1; fi

# --- reads fail before any write ---------------------------------------------------
for what in issue_list repo_view pr_list; do
  GH_FAIL="$what" run
  if [ "$rc" -eq 1 ] && ! grep -qE '^(gh-issue-group|claude-worktree|claude) ' "$calls"; then
    echo "ok: a failing $what read exits 1 with no write"
  else echo "FAIL: $what failure rc=$rc calls=$(cat "$calls")"; fail=1; fi
done

# --- a new observation lifts a rejection ------------------------------------------
# Group 4's PR now closed shortly before 42-45 were filed (the count only takes
# observations after that), and the cap is free.
prs "$(pr 401 CLOSED null '"2026-06-01T12:00:00Z"' group-4-20260610000000)" \
  "$(pr 501 CLOSED null '"2026-06-25T00:00:00Z"' group-5-20260615000000)"
run
if called "gh-issue-group mark 4 clear" \
  && grep -q '^claude-worktree --global --model opus group-4-20260630000000 -- ' "$calls"; then
  echo "ok: a rejected group with observations newer than its closed PR is cleared and delegated again"
else echo "FAIL: rejection lift calls=$(cat "$calls")"; fail=1; fi

# --- nothing unparented, no clustering --------------------------------------------
keep='[.[] | select(.parent != null or .author.login != "example-owner")]'
jq "$keep" "$fix/obs_open.json" >"$tmp/o.json"; mv "$tmp/o.json" "$fix/obs_open.json"
jq "$keep" "$fix/obs_recent.json" >"$tmp/o.json"; mv "$tmp/o.json" "$fix/obs_recent.json"
run
if ! grep -q '^claude ' "$calls"; then
  echo "ok: with no unparented owner observation claude -p is not started"
else echo "FAIL: claude -p started with nothing to cluster calls=$(cat "$calls")"; fail=1; fi

# An unparented observation older than the window is not a reason to cluster.
{ echo '['; "obs" 66 null 2026-05-01T00:00:00Z o1; echo ']'; } >"$tmp/old.json"
jq -s '.[0] + .[1]' "$fix/obs_recent.json" "$tmp/old.json" >"$tmp/o.json"; mv "$tmp/o.json" "$fix/obs_recent.json"
run
if ! grep -q '^claude ' "$calls"; then
  echo "ok: an unparented observation older than 30 days does not start clustering"
else echo "FAIL: stale unparented observation clustered calls=$(cat "$calls")"; fail=1; fi

# A closed, unparented observation (filed already resolved) is still grouped.
{ echo '['; "obs" 67 null 2026-06-26T00:00:00Z r1 example-owner CLOSED; echo ']'; } >"$tmp/closed.json"
jq -s '.[0] + .[1]' "$fix/obs_recent.json" "$tmp/closed.json" >"$tmp/o.json"; mv "$tmp/o.json" "$fix/obs_recent.json"
run
if grep -q '^claude ' "$calls"; then
  echo "ok: a closed unparented observation is clustered so it counts"
else echo "FAIL: closed unparented observation ignored calls=$(cat "$calls")"; fail=1; fi

# --- no group is closed on the strength of missing data ---------------------------
# Recent observations exist but none has a parent: that looks like a failed read.
jq '[.[] | select(.parent == null)]' "$fix/obs_recent.json" >"$tmp/o.json"; mv "$tmp/o.json" "$fix/obs_recent.json"
run
if [ "$rc" -eq 2 ] && ! called "gh-issue-group close 7 --not-planned" \
  && grep -q 'skipping group expiry' "$tmp/err"; then
  echo "ok: observations with no parent at all stop group expiry instead of closing every group"
else echo "FAIL: group expiry guard rc=$rc calls=$(cat "$calls") err=$(cat "$tmp/err")"; fail=1; fi

# --- follow and in-flight scenarios -----------------------------------------------
# Group 12: delegated, no PR yet. 13: an old closed PR and a newer open one on
# the same branch. 14: reopened after its PR merged. 16: re-delegated on a new
# branch that has no PR yet, with a closed PR on the old one. 17: rejected with
# no PR at all. 20 reaches the threshold.
{
  echo '['
  group 12 OPEN agent-task,group,group/delegated; echo ,
  group 13 OPEN agent-task,group,group/delegated; echo ,
  group 14 OPEN agent-task,group,group/delegated; echo ,
  group 16 OPEN agent-task,group,group/delegated; echo ,
  group 17 OPEN agent-task,group,group/rejected; echo ,
  group 20 OPEN agent-task,group
  echo ']'
} >"$fix/groups.json"
o20=("$(obs 201 20 2026-06-20T00:00:00Z s1)" "$(obs 202 20 2026-06-20T00:00:00Z s2)" "$(obs 203 20 2026-06-20T00:00:00Z s3)")
o14=("$(obs 141 14 2026-06-20T00:00:00Z t1)" "$(obs 142 14 2026-06-20T00:00:00Z t2)")
o12=("$(obs 121 12 2026-06-20T00:00:00Z u1)" "$(obs 131 13 2026-06-20T00:00:00Z u2)" "$(obs 171 17 2026-06-20T00:00:00Z u3)")
(IFS=,; printf '[%s]\n' "${o20[*]},${o14[*]},${o12[*]}") >"$fix/obs_recent.json"
echo '[]' >"$fix/obs_open.json"
printf 'group-16-20260620000000\n' >"$fix/branches.txt"
prs "$(pr 601 CLOSED null '"2026-06-10T00:00:00Z"' group-13-20260610000000)" \
  "$(pr 602 OPEN null null group-13-20260610000000)" \
  "$(pr 611 CLOSED null '"2026-06-01T00:00:00Z"' group-14-20260601000000)" \
  "$(pr 612 CLOSED '"2026-06-15T00:00:00Z"' '"2026-06-15T00:00:00Z"' group-14-20260610000000)" \
  "$(pr 631 CLOSED null '"2026-06-02T00:00:00Z"' group-16-20260601000000)"
run
if ! grep -q 'mark 12 \|mark 13 \|mark 16 ' "$calls"; then
  echo "ok: delegated groups with no PR yet, a mix of closed and open PRs, or a new branch without a PR are not rejected"
else echo "FAIL: premature rejection calls=$(cat "$calls")"; fail=1; fi
if called "gh-issue-group mark 14 clear"; then
  echo "ok: a delegated group reopened after its PR merged is cleared"
else echo "FAIL: merged-then-reopened group calls=$(cat "$calls")"; fail=1; fi
if ! grep -q 'mark 17 ' "$calls" && grep -q 'group #17 is rejected' "$tmp/err"; then
  echo "ok: a rejected group with no closed PR is left alone with a warning"
else echo "FAIL: rejected without PR calls=$(cat "$calls") err=$(cat "$tmp/err")"; fail=1; fi
# 12, 13 and 16 are delegated: that alone fills both slots, with no open auto PR
# counted for them (602 is open, but 12 and 16 have none), so group 20 waits.
if ! grep -q '^claude-worktree ' "$calls" && grep -q 'skip: 3 automatic PR(s) in flight' "$tmp/out"; then
  echo "ok: delegated groups count as in flight even without an open PR"
else echo "FAIL: in-flight count calls=$(cat "$calls") out=$(cat "$tmp/out")"; fail=1; fi
# 14's observations are all older than its merge (06-15)? No: they are newer
# (06-20) but only two, so it does not reach the threshold by itself.
if ! grep -q 'close 12\|close 13\|close 16' "$calls"; then
  echo "ok: expiry does not close a delegated group"
else echo "FAIL: delegated group closed calls=$(cat "$calls")"; fail=1; fi

# One delegated group without a PR, no open auto PR, two candidates: one slot is
# left, so exactly one is delegated.
{
  echo '['
  group 12 OPEN agent-task,group,group/delegated; echo ,
  group 20 OPEN agent-task,group; echo ,
  group 21 OPEN agent-task,group
  echo ']'
} >"$fix/groups.json"
o21=("$(obs 211 21 2026-06-20T00:00:00Z v1)" "$(obs 212 21 2026-06-20T00:00:00Z v2)" "$(obs 213 21 2026-06-20T00:00:00Z v3)")
(IFS=,; printf '[%s]\n' "${o20[*]},${o21[*]}") >"$fix/obs_recent.json"
: >"$fix/branches.txt"
prs
run
if [ "$(grep -c '^claude-worktree ' "$calls")" -eq 1 ] && ! grep -q 'close 12' "$calls"; then
  echo "ok: a delegated group with no PR takes a slot, so one of two candidates goes"
else echo "FAIL: delegated slot calls=$(cat "$calls")"; fail=1; fi

# --- a merged PR's date starts a new count ----------------------------------------
# Group 20's three observations predate its merged PR, so it does not count
# again; group 21's are newer than its older merged PR.
{
  echo '['
  group 20 OPEN agent-task,group; echo ,
  group 21 OPEN agent-task,group
  echo ']'
} >"$fix/groups.json"
prs "$(pr 701 CLOSED '"2026-06-25T00:00:00Z"' '"2026-06-25T00:00:00Z"' group-20-20260620000000)" \
  "$(pr 702 CLOSED '"2026-06-01T00:00:00Z"' '"2026-06-01T00:00:00Z"' group-21-20260601000000)"
run
if grep -q '^claude-worktree .* group-21-' "$calls" && ! grep -q '^claude-worktree .* group-20-' "$calls"; then
  echo "ok: only observations filed after the group's last merged PR are counted"
else echo "FAIL: count after merge calls=$(cat "$calls")"; fail=1; fi

exit "$fail"
