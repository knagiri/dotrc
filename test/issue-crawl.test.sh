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
case "$1 ${2:-}" in
  "repo view") echo example-owner ;;
  "issue list")
    if [ "$(after --label "$@")" = group ]; then cat "$FIX/groups.json"
    elif has --search "$@"; then cat "$FIX/obs_recent.json"
    else cat "$FIX/obs_open.json"; fi ;;
  "pr list")
    h="$(after --head "$@")"
    if [ -n "$h" ]; then cat "$FIX/pr_$h.json" 2>/dev/null || echo '[]'
    else cat "$FIX/auto_prs.json"; fi ;;
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
STUB
cat >"$stubdir/gh-issue-group" <<'STUB'
#!/usr/bin/env bash
printf 'gh-issue-group %s\n' "$*" >>"$CALLS"
STUB
chmod +x "$stubdir"/*

# Control: each stub, not a real command, is what PATH resolves.
for c in gh mise claude claude-queue claude-worktree gh-issue-group; do
  if [ "$(PATH="$stubdir:$PATH" command -v "$c")" != "$stubdir/$c" ]; then
    echo "FAIL: $c does not resolve to its stub"; exit 1
  fi
done

now=2026-06-30T00:00:00Z
run() {  # run issue-crawl against the fixtures; sets $rc
  : >"$calls"; : >"$tmp/stdin"
  env CALLS="$calls" FIX="$fix" CLAUDE_STDIN="$tmp/stdin" PATH="$stubdir:$PATH" \
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
# its PR was closed unmerged; group 6 was completed but has one observation
# from after it closed (a recurrence) and one from before; group 7 has nothing
# recent; group 8 is someone else's.
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
  group 8 OPEN agent-task,group '' '' someone-else
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
  "$(obs 90 null 2026-06-25T00:00:00Z g1)"
  "$(obs 101 null 2026-06-25T00:00:00Z g2 someone-else)"
)
(IFS=,; printf '[%s]\n' "${recent[*]}") >"$fix/obs_recent.json"
open_obs=(
  "$(obs 100 1 2026-05-20T00:00:00Z h1)"
  "$(obs 102 1 2026-06-01T00:00:00Z h2)"
  "$(obs 61 6 2026-06-15T00:00:00Z f1)" "$(obs 62 6 2026-06-05T00:00:00Z f2)"
  "$(obs 90 null 2026-06-25T00:00:00Z g1)"
  "$(obs 101 null 2026-06-25T00:00:00Z g2 someone-else)"
  "$(obs 103 null 2026-04-01T00:00:00Z g3 someone-else)"
)
(IFS=,; printf '[%s]\n' "${open_obs[*]}") >"$fix/obs_open.json"
echo '[{"number":500}]' >"$fix/auto_prs.json"
echo '[{"number":401,"state":"CLOSED","mergedAt":null,"closedAt":"2026-06-20T00:00:00Z"}]' >"$fix/pr_group-4.json"
echo '[{"number":501,"state":"CLOSED","mergedAt":null,"closedAt":"2026-06-25T00:00:00Z"}]' >"$fix/pr_group-5.json"

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
if called "gh-issue-group reopen 6" && called "gh-issue-group close 62"; then
  echo "ok: a recurrence reopens a completed group; an older leftover is closed"
else echo "FAIL: completed group handling calls=$(cat "$calls")"; fail=1; fi

# PR follow-up.
if called "gh-issue-group mark 5 rejected" && ! grep -q 'gh-issue-group mark 4 ' "$calls"; then
  echo "ok: a delegated group whose PR closed unmerged is marked rejected"
else echo "FAIL: rejected marking calls=$(cat "$calls")"; fail=1; fi

# Delegation: one slot left (one open auto PR), so only the largest group goes.
wt="$(grep -c '^claude-worktree ' "$calls")"
if [ "$wt" -eq 1 ] && grep -q '^claude-worktree --global --model opus group-2 -- ' "$calls" \
  && called "gh-issue-group mark 2 delegated"; then
  echo "ok: the cap leaves one slot, filled by the group with the most observations"
else echo "FAIL: delegation wt=$wt calls=$(cat "$calls")"; fail=1; fi
if ! grep -qE '^claude-worktree .*group-(4|5) ' "$calls"; then
  echo "ok: rejected and just-rejected groups are not delegated"
else echo "FAIL: rejected group delegated"; fail=1; fi
if ! grep '^claude-worktree ' "$calls" | grep -q "$secret"; then
  echo "ok: the delegation prompt carries no observation body"
else echo "FAIL: observation body leaked into the delegation prompt"; fail=1; fi

# Clustering.
if grep -qF 'claude [-p] [--model] [sonnet] [--allowedTools] [Bash(gh-issue-group *),Bash(gh issue view *),Bash(gh issue list *)]' "$calls" \
  && { cat "$here/../dot/claude/crawler/cluster-prompt.md"; printf '\nrepo owner: example-owner\n'; } \
     | cmp -s - "$tmp/stdin" \
  && ! grep -q "$secret" "$tmp/stdin"; then
  echo "ok: unparented observations start claude -p with the fixed prompt, the owner and the fixed tools"
else echo "FAIL: cluster invocation calls=$(cat "$calls")"; fail=1; fi
if grep -q '^mise .*-- nice -n 10 claude ' "$calls"; then
  echo "ok: claude -p runs through mise in the repo (its account, not the timer's env)"
else echo "FAIL: claude -p not run through mise calls=$(cat "$calls")"; fail=1; fi

# --- no daemon ------------------------------------------------------------------
DAEMON_RC=1 run
if [ "$rc" -eq 0 ] && ! grep -q '^claude-worktree ' "$calls" \
  && ! grep -q 'mark [0-9]* delegated' "$calls" \
  && called "gh-issue-group close 100 --not-planned" \
  && grep -q 'skip: no daemon' "$tmp/out"; then
  echo "ok: without a daemon nothing is delegated, but expiry still runs"
else echo "FAIL: no daemon rc=$rc calls=$(cat "$calls") out=$(cat "$tmp/out")"; fail=1; fi

# --- dry run --------------------------------------------------------------------
run --dry-run
if [ "$rc" -eq 0 ] && ! grep -qE '^(gh-issue-group|claude-worktree|claude) ' "$calls" \
  && grep -q 'delegate: group #2' "$tmp/out"; then
  echo "ok: --dry-run reports the plan without writing, clustering or delegating"
else echo "FAIL: dry run rc=$rc calls=$(cat "$calls")"; fail=1; fi

# --- a new observation lifts a rejection ------------------------------------------
# Group 4's PR now closed before 43-45 were filed, and the cap is free.
echo '[{"number":401,"state":"CLOSED","mergedAt":null,"closedAt":"2026-06-02T12:00:00Z"}]' >"$fix/pr_group-4.json"
echo '[]' >"$fix/auto_prs.json"
run
if called "gh-issue-group mark 4 clear" \
  && grep -q '^claude-worktree --global --model opus group-4 -- ' "$calls"; then
  echo "ok: a rejected group with observations newer than its closed PR is cleared and delegated again"
else echo "FAIL: rejection lift calls=$(cat "$calls")"; fail=1; fi

# --- nothing unparented, no clustering --------------------------------------------
jq '[.[] | select(.parent != null or .author.login != "example-owner")]' "$fix/obs_open.json" >"$tmp/o.json"
mv "$tmp/o.json" "$fix/obs_open.json"
run
if ! grep -q '^claude ' "$calls"; then
  echo "ok: with no unparented owner observation claude -p is not started"
else echo "FAIL: claude -p started with nothing to cluster calls=$(cat "$calls")"; fail=1; fi

exit "$fail"
