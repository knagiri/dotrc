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
# After claude -p has run: GH_FAIL_AFTER fails that read, and groups_after.json
# (if present) replaces groups.json, as if claude -p had rewritten the groups.
if [ -e "$FIX/claude_ran" ]; then
  [ "${GH_FAIL_AFTER:-}" != "$1_${2:-}" ] || { echo "gh stub: forced failure after claude" >&2; exit 1; }
  [ ! -e "$FIX/groups_after.json" ] || groups_file="$FIX/groups_after.json"
fi
groups_file="${groups_file:-$FIX/groups.json}"
case "$1 ${2:-}" in
  "issue list")
    # Every issue read must name the issue repo; anything else is a bug.
    [ "$(after -R "$@")" = "$ISSUE_REPO" ] || { echo "gh stub: issue list without -R $ISSUE_REPO: $*" >&2; exit 1; }
    # The cluster probe (--limit 1) stands in for the claude -p session's own
    # read: it must run with the session's token, never the PAT (MISE_ENV=gh).
    if [ "$(after --limit "$@")" = 1 ]; then
      [ -z "${MISE_ENV:-}" ] || { echo "gh stub: probe read under MISE_ENV=$MISE_ENV" >&2; exit 1; }
      [ -z "${GH_FAIL_PROBE:-}" ] || { echo "gh stub: forced probe failure" >&2; exit 1; }
      echo '[]'; exit 0
    fi
    if [ "$(after --label "$@")" = group ]; then cat "$groups_file"
    elif [ "$(after --label "$@")" = kind/task ]; then
      # Only started tasks are read: closing one that was never started is wrong.
      has status/delegated "$@" || { echo "gh stub: task list without status/delegated: $*" >&2; exit 1; }
      [ -z "${GH_FAIL_TASKS:-}" ] || { echo "gh stub: forced failure of the task list" >&2; exit 1; }
      cat "$FIX/tasks.json" 2>/dev/null || echo '[]'
    elif has --search "$@"; then cat "$FIX/obs_recent.json"
    else cat "$FIX/obs_open.json"; fi ;;
  "repo view")
    # The privacy check (bin/lib/issue-repo.sh): what its --jq prints.
    [ -z "${GH_EXIT_REPO:-}" ] || { echo "gh stub: forced failure" >&2; exit "$GH_EXIT_REPO"; }
    echo "${GH_PRIVATE-true}" ;;
  "pr list")
    # GH_FAIL_MERGED fails only the merged-PR read, past every other read.
    if [ -n "${GH_FAIL_MERGED:-}" ] && [ "$(after --state "$@")" = merged ]; then
      echo "gh stub: forced failure of the merged PR list" >&2; exit 1
    fi
    if has -R "$@"; then echo "gh stub: PRs are this repo's, not -R: $*" >&2; exit 1; fi
    if [ "$(after --state "$@")" = merged ]; then cat "$FIX/merged_prs.json" 2>/dev/null || echo '[]'
    else cat "$FIX/prs.json"; fi ;;
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
printf 'claude-env GH_REPO=%s\n' "${GH_REPO:-}" >>"$CALLS"
: >"$FIX/claude_ran"
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
# Only the read of a rejected group's newer observations (the one jq call with
# `--arg t`) can be made to fail; every other jq call is the real jq.
real_jq="$(command -v jq)"
cat >"$stubdir/jq" <<STUB
#!/usr/bin/env bash
if [ -n "\${JQ_FAIL_T:-}" ] && [[ " \$* " == *" --arg t "* ]]; then echo "jq stub: forced failure" >&2; exit 5; fi
exec "$real_jq" "\$@"
STUB
cat >"$stubdir/gh-issue-group" <<'STUB'
#!/usr/bin/env bash
printf 'gh-issue-group %s\n' "$*" >>"$CALLS"
# GIG_FAIL=<args> fails exactly that call.
[ "${GIG_FAIL:-}" != "$*" ] || exit 1
STUB
chmod +x "$stubdir"/*

# Control: each stub, not a real command, is what PATH resolves.
for c in gh mise claude claude-queue claude-worktree gh-issue-group git jq; do
  if [ "$(PATH="$stubdir:$PATH" command -v "$c")" != "$stubdir/$c" ]; then
    echo "FAIL: $c does not resolve to its stub"; exit 1
  fi
done

now=2026-06-30T00:00:00Z
run() {  # run issue-crawl against the fixtures; sets $rc
  : >"$calls"; : >"$tmp/stdin"; rm -f "$fix/claude_ran"
  env CALLS="$calls" FIX="$fix" CLAUDE_STDIN="$tmp/stdin" PATH="$stubdir:$PATH" \
    ISSUE_REPO=example-owner/example-issues \
    "$crawl" --now "$now" "$@" >"$tmp/out" 2>"$tmp/err"
  rc=$?
}
called() { grep -qxF -- "$1" "$calls"; }

# obs <number> <parent|null> <createdAt> <session|""> [state] [body]
obs() {
  local body="${6:-observation $1}"
  [ -z "$4" ] || body="$body
<!-- observed-session: $4 -->"
  jq -n --argjson n "$1" --argjson p "$2" --arg c "$3" \
    --arg s "${5:-OPEN}" --arg b "$body" \
    '{number:$n, createdAt:$c, state:$s, body:$b,
      parent:(if $p == null then null else {number:$p} end)}'
}
# group <number> <state> <labels,csv> [stateReason] [closedAt]
group() {
  jq -n --argjson n "$1" --arg s "$2" --arg l "$3" --arg r "${4:-}" --arg c "${5:-}" \
    '{number:$n, state:$s,
      stateReason:(if $r == "" then null else $r end),
      closedAt:(if $c == "" then null else $c end),
      labels:($l | split(",") | map({name:.}))}'
}

# --- count_group ----------------------------------------------------------------
# Sourced in library mode so the counting rule can be checked on its own.
count() {  # count <json-array>
  ( ISSUE_CRAWL_LIB=1; since=2026-05-31T00:00:00Z
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

mixed="[$(obs 1 9 2026-06-10T00:00:00Z a),$(obs 2 9 2026-06-10T00:00:00Z b),$(obs 3 9 2026-05-01T00:00:00Z c)]"
if [ "$(count "$mixed")" = 2 ]; then
  echo "ok: observations older than 30 days are not counted"
else echo "FAIL: mixed count=$(count "$mixed")"; fail=1; fi

# Discrimination (evidence-over-guesswork §4): with the session dedup removed
# the same-session case must count 3.
mutant="$tmp/issue-crawl.mutant"
sed 's#^.*session-key@dotrc$#      | null as $s#' "$crawl" >"$mutant"
if cmp -s "$crawl" "$mutant"; then
  echo "FAIL: the dedup mutant is identical; the check below is a no-op"; fail=1
fi
mcount="$( ISSUE_CRAWL_LIB=1; since=2026-05-31T00:00:00Z
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
# recent; group 9 was closed as not planned with an
# older observation left open. Group 8 was completed by a PR merged on 06-12 and
# closed by the crawler only on 06-29 (the crawl time): observation 81, filed on
# 06-20 between the two, is a recurrence, and 82, filed before the merge, is a
# leftover.
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
  group 8 CLOSED agent-task,group COMPLETED 2026-06-29T00:00:00Z; echo ,
  group 9 CLOSED agent-task,group NOT_PLANNED 2026-06-10T00:00:00Z
  echo ']'
} >"$fix/groups.json"

recent=(
  "$(obs 11 1 2026-06-20T00:00:00Z a1)" "$(obs 12 1 2026-06-20T00:00:00Z a2)"
  "$(obs 13 1 2026-06-20T00:00:00Z a3)"
  "$(obs 21 2 2026-06-20T00:00:00Z b1 OPEN "$secret")"
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
  "$(obs 81 8 2026-06-20T00:00:00Z k1)" "$(obs 82 8 2026-06-01T00:00:00Z k2)"
  "$(obs 90 null 2026-06-25T00:00:00Z g1)"
)
(IFS=,; printf '[%s]\n' "${recent[*]}") >"$fix/obs_recent.json"
open_obs=(
  "$(obs 100 1 2026-05-20T00:00:00Z h1)"
  "$(obs 102 1 2026-06-01T00:00:00Z h2)"
  "$(obs 63 6 2026-05-10T00:00:00Z f0)"
  "$(obs 61 6 2026-06-15T00:00:00Z f1)" "$(obs 62 6 2026-06-05T00:00:00Z f2)"
  "$(obs 65 6 2026-06-16T00:00:00Z f3)" "$(obs 64 9 2026-06-05T00:00:00Z h9)"
  "$(obs 81 8 2026-06-20T00:00:00Z k1)" "$(obs 82 8 2026-06-01T00:00:00Z k2)"
  "$(obs 90 null 2026-06-25T00:00:00Z g1)"
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
  "$(pr 801 CLOSED '"2026-06-12T00:00:00Z"' '"2026-06-12T00:00:00Z"' group-8-20260610000000)" \
  "$(pr 401 CLOSED null '"2026-06-20T00:00:00Z"' group-4-20260610000000)" \
  "$(pr 501 CLOSED null '"2026-06-25T00:00:00Z"' group-5-20260615000000)"

run
[ "$rc" -eq 0 ] || { echo "FAIL: main run rc=$rc err=$(cat "$tmp/err")"; fail=1; }

# Expiry.
if called "gh-issue-group close 100 --not-planned" && ! grep -q 'gh-issue-group close 102' "$calls"; then
  echo "ok: an observation older than 30 days is closed; a younger one is not"
else echo "FAIL: observation expiry calls=$(cat "$calls")"; fail=1; fi
if called "gh-issue-group close 7 --not-planned" \
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

# Clustering. The prompt is fixed; only the issue repo, the window start and a
# work dir are appended.
wd="$(tail -n1 "$tmp/stdin" | sed -n 's/^work dir: //p')"
if grep -qF "claude [-p] [--model] [sonnet] [--allowedTools] [Bash(gh-issue-group create *),Bash(gh-issue-group attach *),Bash(gh-issue-group detach *),Bash(gh-issue-group set-body *),Bash(gh-issue-group close *),Bash(gh issue view -R example-owner/example-issues *),Bash(gh issue list -R example-owner/example-issues *),Edit(/$wd/**)]" "$calls" \
  && called "claude-env GH_REPO=example-owner/example-issues" \
  && [ -n "$wd" ] \
  && { cat "$here/../dot/claude/crawler/cluster-prompt.md"
       printf '\nissue repo: example-owner/example-issues\nsince: 2026-05-31\nwork dir: %s\n' "$wd"; } | cmp -s - "$tmp/stdin" \
  && ! grep -q "$secret" "$tmp/stdin"; then
  echo "ok: unparented observations start claude -p with the fixed prompt, the issue repo, the window and the fixed tools"
else echo "FAIL: cluster invocation calls=$(cat "$calls")"; fail=1; fi
if grep -q '^mise .*-- claude ' "$calls"; then
  echo "ok: claude -p runs through mise in the repo"
else echo "FAIL: claude -p mise prefix calls=$(cat "$calls")"; fail=1; fi

# A completed group's leftovers are judged from when its PR merged, not from
# when the crawler got round to closing it: 81 (filed between the merge and the
# close) is a recurrence, 82 (before the merge) a leftover.
if called "gh-issue-group reopen 8" && [ "$(grep -c '^gh-issue-group reopen 8$' "$calls")" -eq 1 ] \
  && called "gh-issue-group close 82" && ! called "gh-issue-group close 81"; then
  echo "ok: an observation filed between a group's merge and its close reopens it; an older one is a leftover"
else echo "FAIL: merge-to-close recurrence calls=$(cat "$calls")"; fail=1; fi

# mroot <name> -- a throwaway checkout holding a copy of bin/ and the cluster
# prompt, so a mutated crawler can run end to end; sets $mroot.
mroot=""
mk_mroot() {
  mroot="$tmp/mroot-$1"; rm -rf "$mroot"; mkdir -p "$mroot/dot/claude/crawler"
  git init -q "$mroot"
  cp -a "$here/../bin" "$mroot/bin"
  cp "$here/../dot/claude/crawler/cluster-prompt.md" "$mroot/dot/claude/crawler/"
}
# run_script <script> [args...] -- run another copy of issue-crawl on the fixtures.
run_script() {
  : >"$calls"; : >"$tmp/stdin"; rm -f "$fix/claude_ran"
  env CALLS="$calls" FIX="$fix" CLAUDE_STDIN="$tmp/stdin" PATH="$stubdir:$PATH" \
    ISSUE_REPO=example-owner/example-issues \
    "$1" --now "$now" "${@:2}" >"$tmp/out" 2>"$tmp/err"
  rc=$?
}
# Discrimination: the leftover threshold falls back to the group's closedAt.
mk_mroot leftover
grep -v 'leftover-threshold@dotrc' "$crawl" >"$mroot/bin/issue-crawl"; chmod +x "$mroot/bin/issue-crawl"
if cmp -s "$crawl" "$mroot/bin/issue-crawl"; then
  echo "FAIL: the leftover-threshold mutant is identical; the check below is a no-op"; fail=1
fi
run_script "$mroot/bin/issue-crawl"
if ! called "gh-issue-group reopen 8" && called "gh-issue-group close 81"; then
  echo "ok: judged from the group's closedAt, the recurrence is closed as a leftover (the case above is discriminating)"
else echo "FAIL: leftover-threshold mutant calls=$(cat "$calls")"; fail=1; fi

# The session's tools: nothing in the allowlist matches close-task, reopen or
# mark, and every subcommand the cluster prompt uses is matched.
allowed_matches() {  # allowed_matches <command>: 0 iff a pattern of the last claude -p call matches it
  local tools pat
  tools="$(grep '^claude \[' "$calls" | sed -n 's/.*\[--allowedTools\] \[\(.*\)\]$/\1/p')"
  [ -n "$tools" ] || return 2
  while IFS= read -r pat; do
    pat="${pat#Bash(}"; pat="${pat%)}"
    # shellcheck disable=SC2053  # the pattern is meant as a glob
    [[ "$1" == $pat ]] && return 0
  done < <(tr ',' '\n' <<<"$tools" | grep '^Bash(gh-issue-group')
  return 1
}
tools_ok() {
  local c bad=0
  for c in "gh-issue-group close-task 5" "gh-issue-group reopen 5" "gh-issue-group mark 5 clear"; do
    ! allowed_matches "$c" || bad=1
  done
  for c in "gh-issue-group create --title t --body-file f" "gh-issue-group attach 5 6" \
      "gh-issue-group detach 6" "gh-issue-group set-body 5 f" "gh-issue-group close 5 --not-planned"; do
    allowed_matches "$c" || bad=1
  done
  return "$bad"
}
run
if tools_ok; then
  echo "ok: the clustering session may create, attach, detach, set-body and close, but not close-task, reopen or mark"
else echo "FAIL: cluster tools calls=$(cat "$calls")"; fail=1; fi
mk_mroot tools
sed 's|Bash(gh-issue-group create \*),Bash(gh-issue-group attach \*),Bash(gh-issue-group detach \*),Bash(gh-issue-group set-body \*),Bash(gh-issue-group close \*)|Bash(gh-issue-group *)|' \
  "$crawl" >"$mroot/bin/issue-crawl"; chmod +x "$mroot/bin/issue-crawl"
if cmp -s "$crawl" "$mroot/bin/issue-crawl"; then
  echo "FAIL: the broad-tools mutant is identical; the check below is a no-op"; fail=1
fi
run_script "$mroot/bin/issue-crawl"
if ! tools_ok; then
  echo "ok: a blanket gh-issue-group pattern would let the session close tasks (the case above is discriminating)"
else echo "FAIL: broad-tools mutant still passed calls=$(cat "$calls")"; fail=1; fi

# The session's own gh is probed before it starts: a read that fails with the
# session's token skips clustering, with an error and exit 2, but the rest of
# the pass runs.
if called "gh issue list -R example-owner/example-issues --limit 1" && grep -q '^claude \[' "$calls"; then
  echo "ok: the session's token is probed with a one-issue read before claude -p starts"
else echo "FAIL: cluster probe missing calls=$(cat "$calls")"; fail=1; fi
GH_FAIL_PROBE=1 run
if [ "$rc" -eq 2 ] && ! grep -q '^claude ' "$calls" && grep -q "cannot read example-owner/example-issues" "$tmp/err" \
  && called "gh-issue-group close 100 --not-planned"; then
  echo "ok: a token that cannot read the issue repo skips clustering with an error; the rest of the pass runs"
else echo "FAIL: probe failure rc=$rc calls=$(cat "$calls") err=$(cat "$tmp/err")"; fail=1; fi
GH_FAIL_PROBE=1 run --dry-run
if [ "$rc" -eq 0 ] && ! called "gh issue list -R example-owner/example-issues --limit 1"; then
  echo "ok: --dry-run does not probe"
else echo "FAIL: dry-run probe rc=$rc calls=$(cat "$calls")"; fail=1; fi
# Discrimination: no probe at all; and a probe through gh_mise (the PAT), which
# the stub refuses, so clustering would be skipped on a token the session lacks.
mk_mroot probe
sed 's|^\( *\)if ! GH_REPO=.*cluster-probe@dotrc$|\1if false; then|' "$crawl" >"$mroot/bin/issue-crawl"; chmod +x "$mroot/bin/issue-crawl"
if cmp -s "$crawl" "$mroot/bin/issue-crawl"; then
  echo "FAIL: the no-probe mutant is identical; the check below is a no-op"; fail=1
fi
GH_FAIL_PROBE=1 run_script "$mroot/bin/issue-crawl"
if grep -q '^claude ' "$calls"; then
  echo "ok: without the probe clustering starts on a token that cannot read (the probe case is discriminating)"
else echo "FAIL: no-probe mutant calls=$(cat "$calls")"; fail=1; fi
mk_mroot probe-pat
sed 's|if ! GH_REPO="\$ISSUE_REPO" in_repo gh issue list|if ! gh_mise issue list|' "$crawl" >"$mroot/bin/issue-crawl"; chmod +x "$mroot/bin/issue-crawl"
if cmp -s "$crawl" "$mroot/bin/issue-crawl"; then
  echo "FAIL: the probe-through-PAT mutant is identical; the check below is a no-op"; fail=1
fi
run_script "$mroot/bin/issue-crawl"
if ! grep -q '^claude ' "$calls" && grep -q 'probe read under MISE_ENV=gh' "$tmp/err"; then
  echo "ok: a probe that used the PAT would not test the session's token (the stub refuses it)"
else echo "FAIL: probe-through-PAT mutant calls=$(cat "$calls") err=$(cat "$tmp/err")"; fail=1; fi

# A rejected group's observations that cannot be read (jq fails) are an error,
# not "nothing new": exit 2, and the group is left alone.
JQ_FAIL_T=1 run
if [ "$rc" -eq 2 ] && grep -q 'cannot read observations of group #4' "$tmp/err" && ! grep -q 'mark 4 ' "$calls"; then
  echo "ok: an unreadable rejected group is reported and left alone, with exit 2"
else echo "FAIL: rejected jq failure rc=$rc err=$(cat "$tmp/err") calls=$(cat "$calls")"; fail=1; fi
mk_mroot newer
sed 's#^        || { echo "error: cannot read observations of group \#\$g" >&2; failed=1; continue; }$##; s#^\(      newer=.*\) \\$#\1#' "$crawl" >"$mroot/bin/issue-crawl"; chmod +x "$mroot/bin/issue-crawl"
if cmp -s "$crawl" "$mroot/bin/issue-crawl"; then
  echo "FAIL: the newer-guard mutant is identical; the check below is a no-op"; fail=1
fi
JQ_FAIL_T=1 run_script "$mroot/bin/issue-crawl"
if [ "$rc" -eq 0 ]; then
  echo "ok: without the guard the failed read passes silently with exit 0 (the case above is discriminating)"
else echo "FAIL: newer-guard mutant rc=$rc err=$(cat "$tmp/err")"; fail=1; fi

# --- the issue repo: not configured (3), not private (5) --------------------------
# Not configured: nothing is read.
: >"$calls"
env -u ISSUE_REPO CALLS="$calls" FIX="$fix" CLAUDE_STDIN="$tmp/stdin" PATH="$stubdir:$PATH" \
  "$crawl" --now "$now" >"$tmp/out" 2>"$tmp/err"; rc=$?
if [ "$rc" -eq 3 ] && [ ! -s "$calls" ] && grep -q 'ISSUE_REPO' "$tmp/err"; then
  echo "ok: with no issue repo configured the crawler exits 3 without calling anything"
else echo "FAIL: unconfigured rc=$rc calls=$(cat "$calls") err=$(cat "$tmp/err")"; fail=1; fi
mk_mroot config
sed 's/exit 3/:/' "$here/../bin/lib/issue-repo.sh" >"$mroot/bin/lib/issue-repo.sh"
if cmp -s "$here/../bin/lib/issue-repo.sh" "$mroot/bin/lib/issue-repo.sh"; then
  echo "FAIL: the exit-3 mutant is identical; the check below is a no-op"; fail=1
fi
: >"$calls"
env -u ISSUE_REPO CALLS="$calls" FIX="$fix" CLAUDE_STDIN="$tmp/stdin" PATH="$stubdir:$PATH" \
  "$mroot/bin/issue-crawl" --now "$now" >"$tmp/out" 2>"$tmp/err"; rc=$?
if [ "$rc" -ne 3 ] && [ -s "$calls" ]; then
  echo "ok: without the exit 3 an unconfigured crawler goes on to call gh (the case above is discriminating)"
else echo "FAIL: exit-3 mutant rc=$rc calls=$(cat "$calls")"; fail=1; fi

# Not private, or not verifiable: exit 5 before any issue is read, and no write.
not_private_stops() {  # not_private_stops <script>; 0 iff every case exits 5 with no issue read or write
  local bad=0 v
  for v in GH_PRIVATE=false GH_EXIT_REPO=1 GH_PRIVATE=maybe GH_PRIVATE=; do
    : >"$calls"; rm -f "$fix/claude_ran"
    env "$v" CALLS="$calls" FIX="$fix" CLAUDE_STDIN="$tmp/stdin" PATH="$stubdir:$PATH" \
      ISSUE_REPO=example-owner/example-issues "$1" --now "$now" >"$tmp/out" 2>"$tmp/err"
    rc=$?
    { [ "$rc" -eq 5 ] && ! grep -qE '^(gh issue|gh pr|gh-issue-group|claude|claude-worktree) ' "$calls" \
      && grep -qE 'not private|cannot verify' "$tmp/err"; } || bad=1
  done
  return "$bad"
}
if not_private_stops "$crawl"; then
  echo "ok: a public, unverifiable or odd-answer issue repo exits 5 before anything is read or written"
else echo "FAIL: not private rc=$rc calls=$(cat "$calls") err=$(cat "$tmp/err")"; fail=1; fi
mk_mroot nocheck
sed '/private-check@dotrc$/d' "$crawl" >"$mroot/bin/issue-crawl"; chmod +x "$mroot/bin/issue-crawl"
if cmp -s "$crawl" "$mroot/bin/issue-crawl"; then
  echo "FAIL: the no-check mutant is identical; the check below is a no-op"; fail=1
fi
if ! not_private_stops "$mroot/bin/issue-crawl"; then
  echo "ok: without the privacy check a public issue repo is crawled (the exit-5 cases are discriminating)"
else echo "FAIL: no-check mutant still stopped everything"; fail=1; fi
mk_mroot loose
sed 's|\[ "\$last" != true \]|[ -z "$last" ]|' "$here/../bin/lib/issue-repo.sh" >"$mroot/bin/lib/issue-repo.sh"
if cmp -s "$here/../bin/lib/issue-repo.sh" "$mroot/bin/lib/issue-repo.sh"; then
  echo "FAIL: the loose-compare mutant is identical; the check below is a no-op"; fail=1
fi
if ! not_private_stops "$mroot/bin/issue-crawl"; then
  echo "ok: a comparison loosened to any output lets a public repo through (the exit-5 cases are discriminating)"
else echo "FAIL: loose-compare mutant still stopped everything"; fail=1; fi

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
for what in issue_list pr_list; do
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
keep='[.[] | select(.parent != null)]'
jq "$keep" "$fix/obs_open.json" >"$tmp/o.json"; mv "$tmp/o.json" "$fix/obs_open.json"
jq "$keep" "$fix/obs_recent.json" >"$tmp/o.json"; mv "$tmp/o.json" "$fix/obs_recent.json"
run
if ! grep -q '^claude ' "$calls"; then
  echo "ok: with no unparented observation claude -p is not started"
else echo "FAIL: claude -p started with nothing to cluster calls=$(cat "$calls")"; fail=1; fi

# An unparented observation older than the window is not a reason to cluster.
{ echo '['; "obs" 66 null 2026-05-01T00:00:00Z o1; echo ']'; } >"$tmp/old.json"
jq -s '.[0] + .[1]' "$fix/obs_recent.json" "$tmp/old.json" >"$tmp/o.json"; mv "$tmp/o.json" "$fix/obs_recent.json"
run
if ! grep -q '^claude ' "$calls"; then
  echo "ok: an unparented observation older than 30 days does not start clustering"
else echo "FAIL: stale unparented observation clustered calls=$(cat "$calls")"; fail=1; fi

# A closed, unparented observation (filed already resolved) is still grouped.
{ echo '['; "obs" 67 null 2026-06-26T00:00:00Z r1 CLOSED; echo ']'; } >"$tmp/closed.json"
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
# the same branch. 14: its PR merged. 16: re-delegated on a new
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
o14=("$(obs 141 14 2026-06-20T00:00:00Z t1)" "$(obs 142 14 2026-06-20T00:00:00Z t2)" "$(obs 143 14 2026-06-20T00:00:00Z t3)")
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
clear_line="$(grep -n '^gh-issue-group mark 14 clear$' "$calls" | cut -d: -f1)"
close_line="$(grep -n '^gh-issue-group close 14$' "$calls" | cut -d: -f1)"
if [ -n "$clear_line" ] && [ -n "$close_line" ] && [ "$clear_line" -lt "$close_line" ]; then
  echo "ok: a delegated group whose PR merged is cleared, then closed as completed"
else echo "FAIL: merged group calls=$(cat "$calls")"; fail=1; fi
# 14 is closed now: it neither takes a slot nor becomes a candidate.
if ! grep -q 'group-14-2026063' "$calls"; then
  echo "ok: a group closed on merge is not delegated again in the same pass"
else echo "FAIL: closed group delegated calls=$(cat "$calls")"; fail=1; fi

# Discrimination: without the close the merged group stays open.
mutant="$tmp/mbin-merged/issue-crawl"; rm -rf "$tmp/mbin-merged"; cp -a "$here/../bin" "$tmp/mbin-merged"
grep -v 'merged-close@dotrc' "$crawl" >"$mutant"; chmod +x "$mutant"
if cmp -s "$crawl" "$mutant"; then
  echo "FAIL: the merged-close mutant is identical; the check below is a no-op"; fail=1
fi
: >"$calls"; rm -f "$fix/claude_ran"
env CALLS="$calls" FIX="$fix" CLAUDE_STDIN="$tmp/stdin" PATH="$stubdir:$PATH" \
  ISSUE_REPO=example-owner/example-issues "$mutant" --now "$now" >/dev/null 2>&1
# The clear is asserted too, so a mutant that never ran cannot pass.
if called "gh-issue-group mark 14 clear" && ! called "gh-issue-group close 14"; then
  echo "ok: without the close step the merged group is left open (the case above is discriminating)"
else echo "FAIL: merged-close mutant still closed 14"; fail=1; fi
# A clear that fails must not be followed by a close: the group would be left
# closed with group/delegated still on it.
GIG_FAIL="mark 14 clear" run
if [ "$rc" -eq 2 ] && called "gh-issue-group mark 14 clear" && ! called "gh-issue-group close 14"; then
  echo "ok: a failed clear on a merged group is not followed by a close, and the pass exits 2"
else echo "FAIL: close after failed clear rc=$rc calls=$(cat "$calls")"; fail=1; fi
# A clear that works and a close that fails: the failure is reported (exit 2),
# the group is not delegated in its place, and nothing else is rewritten.
GIG_FAIL="close 14" run
if [ "$rc" -eq 2 ] && called "gh-issue-group mark 14 clear" && called "gh-issue-group close 14" \
  && grep -q 'group #14 PR merged; close as completed failed' "$tmp/err" \
  && ! grep -q 'group-14-2026063' "$calls" && ! called "gh-issue-group mark 14 delegated"; then
  echo "ok: a failed close after a successful clear is an error (exit 2), and the group is not delegated again"
else echo "FAIL: close failure after clear rc=$rc calls=$(cat "$calls") err=$(cat "$tmp/err")"; fail=1; fi
# Discrimination: an act that does not record its failure lets both this and the
# close-task failure below pass with exit 0.
mk_mroot actfail
sed 's|echo "error: \$what failed" >&2; failed=1; return 1|echo "error: $what failed" >\&2; return 1|' "$crawl" >"$mroot/bin/issue-crawl"; chmod +x "$mroot/bin/issue-crawl"
if cmp -s "$crawl" "$mroot/bin/issue-crawl"; then
  echo "FAIL: the act-failure mutant is identical; the checks below are no-ops"; fail=1
fi
GIG_FAIL="close 14" run_script "$mroot/bin/issue-crawl"
if [ "$rc" -eq 0 ] && called "gh-issue-group close 14"; then
  echo "ok: an act that forgets its failure exits 0 on a failed close (the exit-2 case above is discriminating)"
else echo "FAIL: act-failure mutant rc=$rc calls=$(cat "$calls")"; fail=1; fi
run
if ! grep -q 'mark 17 ' "$calls" && grep -q 'group #17 is rejected' "$tmp/err"; then
  echo "ok: a rejected group with no closed PR is left alone with a warning"
else echo "FAIL: rejected without PR calls=$(cat "$calls") err=$(cat "$tmp/err")"; fail=1; fi
# 12, 13 and 16 are delegated: that alone fills both slots, with no open auto PR
# counted for them (602 is open, but 12 and 16 have none), so group 20 waits.
if ! grep -q '^claude-worktree ' "$calls" && grep -q 'skip: 3 automatic PR(s) in flight' "$tmp/out"; then
  echo "ok: delegated groups count as in flight even without an open PR"
else echo "FAIL: in-flight count calls=$(cat "$calls") out=$(cat "$tmp/out")"; fail=1; fi
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

# --- a group closed on merge is not a candidate in the same pass -------------------
# Group 14 merged and has three recent observations (the threshold) from after
# the merge; no group is delegated, so a slot is free. Only group 20 goes.
{
  echo '['
  group 14 OPEN agent-task,group,group/delegated; echo ,
  group 20 OPEN agent-task,group
  echo ']'
} >"$fix/groups.json"
(IFS=,; printf '[%s]\n' "${o14[*]},${o20[*]}") >"$fix/obs_recent.json"
prs "$(pr 612 CLOSED '"2026-06-15T00:00:00Z"' '"2026-06-15T00:00:00Z"' group-14-20260610000000)"
run
if called "gh-issue-group close 14" \
  && [ "$(grep -c '^claude-worktree ' "$calls")" -eq 1 ] && grep -q '^claude-worktree .* group-20-' "$calls" \
  && ! called "gh-issue-group mark 14 delegated"; then
  echo "ok: a group closed on merge is not delegated again, though its new count reaches the threshold"
else echo "FAIL: merged group re-delegated calls=$(cat "$calls")"; fail=1; fi
(IFS=,; printf '[%s]\n' "${o20[*]},${o21[*]}") >"$fix/obs_recent.json"

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

# --- claude -p rewrites groups: steps 3-4 judge the new picture ---------------------
# Group 20 and 21 both reach the threshold, and an unparented observation makes
# claude -p run. The stub then reports group 20 as closed (merged into another
# group by the clustering step): it must not be marked or delegated, while 21 is.
{
  echo '['
  group 20 OPEN agent-task,group; echo ,
  group 21 OPEN agent-task,group
  echo ']'
} >"$fix/groups.json"
{
  echo '['
  group 20 CLOSED agent-task,group NOT_PLANNED 2026-06-29T00:00:00Z; echo ,
  group 21 OPEN agent-task,group
  echo ']'
} >"$fix/groups_after.json"
(IFS=,; printf '[%s]\n' "${o20[*]},${o21[*]},$(obs 90 null 2026-06-25T00:00:00Z g1)") >"$fix/obs_recent.json"
echo '[]' >"$fix/obs_open.json"
prs
run
if grep -q '^claude ' "$calls" && [ "$rc" -eq 0 ] \
  && ! grep -q 'mark 20 \|group-20-' "$calls" \
  && called "gh-issue-group mark 21 delegated" && grep -q '^claude-worktree .* group-21-' "$calls"; then
  echo "ok: a group closed by the clustering step is not delegated in the same pass"
else echo "FAIL: stale groups after clustering rc=$rc calls=$(cat "$calls")"; fail=1; fi

# Without the second read the stale groups are judged (control: both go).
rm -f "$fix/groups_after.json"
run
if grep -q '^claude-worktree .* group-20-' "$calls" && grep -q '^claude-worktree .* group-21-' "$calls"; then
  echo "ok: with the groups unchanged by clustering, both candidates are delegated (the case above is discriminating)"
else echo "FAIL: control for re-read calls=$(cat "$calls")"; fail=1; fi

# A failed re-read ends the pass after clustering: error, exit 2, no delegation.
for what in issue_list pr_list; do
  GH_FAIL_AFTER="$what" run
  if [ "$rc" -eq 2 ] && grep -q '^claude ' "$calls" \
    && ! grep -qE '^(gh-issue-group mark|claude-worktree) ' "$calls" \
    && grep -q 'cannot re-read after clustering' "$tmp/err"; then
    echo "ok: a failing $what re-read after clustering skips follow and delegate"
  else echo "FAIL: $what re-read failure rc=$rc calls=$(cat "$calls") err=$(cat "$tmp/err")"; fail=1; fi
done

# --- delegated tasks closed on merge -------------------------------------------
# 40 has a merged task-40-* PR; 41 only shares a number prefix with task-411-*;
# 42's PR is not merged (absent from the merged list). Only 40 is closed.
echo '[{"number":40},{"number":41},{"number":42}]' >"$fix/tasks.json"
echo '[{"headRefName":"task-40-fix-thing"},{"headRefName":"task-411-other"},{"headRefName":"group-20-20260620000000"}]' >"$fix/merged_prs.json"
run
if [ "$rc" -eq 0 ] && called "gh-issue-group close-task 40" \
  && [ "$(grep -c '^gh-issue-group close-task ' "$calls")" -eq 1 ]; then
  echo "ok: only a delegated task whose task-<N>- branch PR merged is closed"
else echo "FAIL: task close rc=$rc calls=$(cat "$calls")"; fail=1; fi

# A close-task that fails is reported (exit 2); the pass still ran to the end.
GIG_FAIL="close-task 40" run
if [ "$rc" -eq 2 ] && called "gh-issue-group close-task 40" && grep -q 'task #40 PR merged; close failed' "$tmp/err"; then
  echo "ok: a failed close-task is an error (exit 2)"
else echo "FAIL: close-task failure rc=$rc calls=$(cat "$calls") err=$(cat "$tmp/err")"; fail=1; fi
GIG_FAIL="close-task 40" run_script "$mroot/bin/issue-crawl"
if [ "$rc" -eq 0 ] && called "gh-issue-group close-task 40"; then
  echo "ok: an act that forgets its failure exits 0 on a failed close-task (the exit-2 case above is discriminating)"
else echo "FAIL: act-failure mutant on close-task rc=$rc calls=$(cat "$calls")"; fail=1; fi

# The delegated-task read failing ends the pass before any write (exit 1): a
# read that comes back empty would otherwise mean "no task to close".
GH_FAIL_TASKS=1 run
if [ "$rc" -eq 1 ] && ! grep -qE '^(gh-issue-group|claude-worktree|claude) ' "$calls" \
  && grep -q 'cannot list delegated tasks' "$tmp/err"; then
  echo "ok: a failing delegated-task read exits 1 with no write"
else echo "FAIL: task read failure rc=$rc calls=$(cat "$calls") err=$(cat "$tmp/err")"; fail=1; fi
mk_mroot taskread
sed 's/|| die "cannot list delegated tasks"/|| true/' "$crawl" >"$mroot/bin/issue-crawl"; chmod +x "$mroot/bin/issue-crawl"
if cmp -s "$crawl" "$mroot/bin/issue-crawl"; then
  echo "FAIL: the task-read mutant is identical; the check below is a no-op"; fail=1
fi
GH_FAIL_TASKS=1 run_script "$mroot/bin/issue-crawl"
if [ "$rc" -ne 1 ]; then
  echo "ok: without the guard a failed task read goes on (the exit-1 case above is discriminating)"
else echo "FAIL: task-read mutant rc=$rc"; fail=1; fi

run --dry-run
if ! grep -q '^gh-issue-group close-task' "$calls" && grep -q 'dry-run: follow: task #40' "$tmp/out"; then
  echo "ok: --dry-run reports the task close without writing"
else echo "FAIL: task dry run calls=$(cat "$calls") out=$(cat "$tmp/out")"; fail=1; fi

# Discrimination: matching without the trailing dash closes 41 as well.
mutant="$tmp/mbin-taskprefix/issue-crawl"; rm -rf "$tmp/mbin-taskprefix"; cp -a "$here/../bin" "$tmp/mbin-taskprefix"
sed 's|"\^task-\$t-"|"^task-$t"|' "$crawl" >"$mutant"; chmod +x "$mutant"
if cmp -s "$crawl" "$mutant"; then
  echo "FAIL: the task-prefix mutant is identical; the check below is a no-op"; fail=1
fi
: >"$calls"; rm -f "$fix/claude_ran"
env CALLS="$calls" FIX="$fix" CLAUDE_STDIN="$tmp/stdin" PATH="$stubdir:$PATH" \
  ISSUE_REPO=example-owner/example-issues "$mutant" --now "$now" >/dev/null 2>&1
if called "gh-issue-group close-task 41"; then
  echo "ok: a prefix match without the dash closes the wrong task (the case above is discriminating)"
else echo "FAIL: task-prefix mutant did not close 41 calls=$(cat "$calls")"; fail=1; fi

# A failing merged-PR read (every other read succeeding) ends the pass before
# any write, with its own message.
GH_FAIL_MERGED=1 run
if [ "$rc" -eq 1 ] && ! grep -qE '^(gh-issue-group|claude-worktree|claude) ' "$calls" \
  && grep -q 'cannot list merged PRs' "$tmp/err"; then
  echo "ok: a failing merged-PR read exits 1 with no write"
else echo "FAIL: merged PR read failure rc=$rc calls=$(cat "$calls") err=$(cat "$tmp/err")"; fail=1; fi

# A merged-PR list that fills its limit may have cut off the PR of a task that
# is still open: that is warned about, not silently ignored. Short lists are not.
run
if [ "$rc" -eq 0 ] && ! grep -q 'merged PR list reached its limit' "$tmp/err"; then
  echo "ok: a merged-PR list under its limit raises no warning"
else echo "FAIL: short merged list warned rc=$rc err=$(cat "$tmp/err")"; fail=1; fi
jq -n '[range(999) | {headRefName: "other-\(.)"}] + [{headRefName: "task-40-fix-thing"}]' >"$fix/merged_prs.json"
run
if [ "$rc" -eq 0 ] && grep -q 'merged PR list reached its limit (1000)' "$tmp/err" && called "gh-issue-group close-task 40"; then
  echo "ok: a merged-PR list that fills its limit is warned about; the pass still runs"
else echo "FAIL: full merged list rc=$rc err=$(cat "$tmp/err") calls=$(cat "$calls")"; fail=1; fi
mk_mroot mergedlimit
sed 's|"\$merged_count" -ge "\$merged_limit"|"$merged_count" -gt 99999|' "$crawl" >"$mroot/bin/issue-crawl"; chmod +x "$mroot/bin/issue-crawl"
if cmp -s "$crawl" "$mroot/bin/issue-crawl"; then
  echo "FAIL: the merged-limit mutant is identical; the check below is a no-op"; fail=1
fi
run_script "$mroot/bin/issue-crawl"
if ! grep -q 'merged PR list reached its limit' "$tmp/err"; then
  echo "ok: without the check a full merged-PR list passes in silence (the case above is discriminating)"
else echo "FAIL: merged-limit mutant still warned"; fail=1; fi
rm -f "$fix/tasks.json" "$fix/merged_prs.json"

exit "$fail"
