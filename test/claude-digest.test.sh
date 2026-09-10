#!/usr/bin/env bash
# Functional tests for claude-digest. Everything is synthesised into a mktemp
# sandbox -- transcripts, git repositories, the `claude` binary -- so nothing
# here reads the real ~/.claude or the network, and no fixture file is
# committed. No test framework; run with bash.
#
# The collection half is asserted through `--generate --dry-run`, which prints
# exactly the facts block that stage 2 would be handed but makes no LLM call.
# The generate half runs with a stubbed `claude` that records its invocations.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/../bin/claude-digest"
fail=0

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

projects="$sandbox/projects"
digests="$sandbox/digests"
mkdir -p "$projects/-proj-a" "$projects/-proj-b" "$digests"

# --------------------------------------------------------------------------
# The `claude` stub: serves the roster, and answers -p from stdin. It records
# one line per -p call so the idempotency test can count them.
# --------------------------------------------------------------------------
stubdir="$sandbox/stub"; mkdir -p "$stubdir"
cat >"$stubdir/claude" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  agents) cat "${CD_ROSTER:-/dev/null}"; exit 0 ;;
  -p)
    body="$(cat)"
    printf '%s\n' "-p" >>"${CD_CALLS:-/dev/null}"
    if printf '%s' "$body" | grep -q '事実ブロック'; then
      printf 'STUB-DIGEST\n'
      printf '%s\n' "$body" | grep -E '^(SHORT|LANDED_PR|OPEN_BRANCH):' || true
    else
      printf -- '---\nends_with_question: no\ndelegate_incomplete: no\n---\n'
      printf '## 着地したもの\nなし\n## 残っているもの\nなし\n## 一言\nstub.\n'
    fi
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$stubdir/claude"

echo '[]' >"$sandbox/roster.json"

# --------------------------------------------------------------------------
# Git fixtures. repo_a uses the GitHub noreply address, repo_b a plain one.
# --------------------------------------------------------------------------
me='65004703+gili-Katagiri@users.noreply.github.com'
# Same numeric prefix, no "+": close enough to "<65004703+" to be worth
# excluding, and it is excluded because the "+" is matched literally.
impostor='650047033@example.com'
# git log --author is a basic regular expression by default, where "." is any
# character. This address therefore matches the pattern "plain@example.com"
# read as a regex but not read as a fixed string -- which is what makes the -F
# observable from outside.
bre_impostor='plain@exampleXcom'

# Everything lands inside the 2026-03-01 window (2026-02-28T20:00Z ..
# 2026-03-01T20:00Z), which is the day under test throughout.
export GIT_AUTHOR_DATE='2026-03-01T10:00:00+0900'
export GIT_COMMITTER_DATE='2026-03-01T10:00:00+0900'

git init -q --bare "$sandbox/remote.git"
repo_a="$sandbox/repo_a"
git init -q -b main "$repo_a"
git -C "$repo_a" config user.name 'Me'
git -C "$repo_a" config user.email "$me"
git -C "$repo_a" commit -q --allow-empty -m 'init'
git -C "$repo_a" remote add origin "$sandbox/remote.git"
git -C "$repo_a" push -q -u origin main
git -C "$repo_a" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

merge_pr() {  # merge_pr <branch> <pr> <title> [<author-email>]
  local br="$1" pr="$2" title="$3" email="${4:-$me}" name=Other
  [ "$email" = "$me" ] && name=Me
  git -C "$repo_a" switch -q -c "$br"
  GIT_AUTHOR_EMAIL="$email" GIT_AUTHOR_NAME="$name" \
    git -C "$repo_a" commit -q --allow-empty -m "work on $br"
  git -C "$repo_a" switch -q main
  git -C "$repo_a" merge -q --no-ff -m "$title (#$pr)" "$br"
  git -C "$repo_a" branch -q -D "$br"
}
merge_pr pr101 101 'feat: the mentioned one'
merge_pr pr102 102 'chore: not mine at all' "$impostor"
merge_pr pr103 103 'fix: landed but unmentioned'
git -C "$repo_a" push -q origin main

# A branch of mine that is still ahead of origin/main -> OPEN.
git -C "$repo_a" switch -q -c feature/open
git -C "$repo_a" commit -q --allow-empty -m 'open work'
# A branch somebody else drives -> dropped by the tip-author filter. Its root
# commit is mine, which is what `git log -1 --author=` would wrongly latch on.
git -C "$repo_a" switch -q main
git -C "$repo_a" switch -q -c feature/theirs
GIT_AUTHOR_EMAIL="$impostor" GIT_AUTHOR_NAME=Other \
  git -C "$repo_a" commit -q --allow-empty -m 'their work'
# A branch of mine that is merged and whose remote is gone -> reap candidate.
git -C "$repo_a" switch -q main
git -C "$repo_a" switch -q -c feature/landed
git -C "$repo_a" push -q -u origin feature/landed
git -C "$repo_a" push -q origin --delete feature/landed
git -C "$repo_a" fetch -q --prune
git -C "$repo_a" switch -q main

# repo_b: the plain-address fallback, and the home of the -F check. Its author
# pattern is the address itself, "." included.
repo_b="$sandbox/repo_b"
git init -q --bare "$sandbox/remote_b.git"
git init -q -b main "$repo_b"
git -C "$repo_b" config user.name 'Plain'
git -C "$repo_b" config user.email 'plain@example.com'
git -C "$repo_b" commit -q --allow-empty -m 'init'
git -C "$repo_b" remote add origin "$sandbox/remote_b.git"
git -C "$repo_b" push -q -u origin main
git -C "$repo_b" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

merge_pr_b() {  # merge_pr_b <branch> <pr> <title> <author-email> <author-name>
  git -C "$repo_b" switch -q -c "$1"
  GIT_AUTHOR_EMAIL="$4" GIT_AUTHOR_NAME="$5" \
    git -C "$repo_b" commit -q --allow-empty -m "work on $1"
  git -C "$repo_b" switch -q main
  git -C "$repo_b" merge -q --no-ff -m "$3 (#$2)" "$1"
  git -C "$repo_b" branch -q -D "$1"
}
merge_pr_b pr201 201 'feat: mine in repo_b' 'plain@example.com' 'Plain'
merge_pr_b pr202 202 'chore: regex-only match' "$bre_impostor" 'Other'
git -C "$repo_b" push -q origin main

unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE

# --------------------------------------------------------------------------
# Transcript fixtures.
# --------------------------------------------------------------------------
entry() {  # entry <ts> <cwd> <branch>; one human turn carrying $TEXT
  jq -cn --arg ts "$1" --arg cwd "$2" --arg br "$3" --arg text "${TEXT:-hello}" \
    '{type:"user", entrypoint:"cli", isSidechain:false, origin:{kind:"human"},
      uuid:"x", timestamp:$ts, cwd:$cwd, gitBranch:$br,
      message:{role:"user", content:$text}}'
}
title_entry() { jq -cn --arg t "$1" '{type:"ai-title", aiTitle:$t}'; }

# EARLY: 19:30Z is JST 04:30 the next morning, i.e. still 2026-03-01. Its
# timestamps carry milliseconds, which fromdateiso8601 refuses outright.
early=11111111-1111-1111-1111-111111111111
{ title_entry 'early session'
  TEXT='landed https://github.com/o/r/pull/101 and also o/r/pull/999' \
    entry '2026-03-01T19:30:00.197Z' "$repo_a" 'feature/open'
  entry '2026-03-01T19:31:00.900Z' "$repo_a" 'feature/landed'
} >"$projects/-proj-a/$early.jsonl"

# LATE: 20:30Z is JST 05:30, past the boundary, so it belongs to 2026-03-02.
late=22222222-2222-2222-2222-222222222222
{ title_entry 'late session'
  entry '2026-03-01T20:30:00.500Z' "$repo_a" 'feature/open'
} >"$projects/-proj-a/$late.jsonl"

# SDK: the security-review skill talking to itself; must never be counted.
sdk=33333333-3333-3333-3333-333333333333
jq -cn --arg cwd "$repo_a" \
  '{type:"user", entrypoint:"sdk-py", isSidechain:false, origin:{kind:"human"},
    timestamp:"2026-03-01T10:00:00.000Z", cwd:$cwd, gitBranch:"feature/open",
    message:{role:"user", content:"Review this change for security vulnerabilities."}}' \
  >"$projects/-proj-a/$sdk.jsonl"

# DUP: the very same session uuid under two project directories, which is what
# a relocated cwd leaves behind. It must be counted once.
dup=44444444-4444-4444-4444-444444444444
{ title_entry 'relocated session'
  entry '2026-03-01T09:00:00.001Z' "$repo_a" 'feature/theirs'
} >"$projects/-proj-a/$dup.jsonl"
cp "$projects/-proj-a/$dup.jsonl" "$projects/-proj-b/$dup.jsonl"

# BARE: no ai-title, no gitBranch, and a working directory that is gone.
bare=55555555-5555-5555-5555-555555555555
jq -cn '{type:"user", entrypoint:"cli", isSidechain:false, origin:{kind:"human"},
         timestamp:"2026-03-01T08:00:00.123Z", cwd:"/nonexistent/reaped_worktree",
         message:{role:"user", content:"first prompt of an untitled session"}}' \
  >"$projects/-proj-a/$bare.jsonl"

# PLAIN: lives in the repo whose user.email is not a noreply address.
plain=66666666-6666-6666-6666-666666666666
{ title_entry 'plain email session'
  entry '2026-03-01T07:00:00.500Z' "$repo_b" 'main'
} >"$projects/-proj-b/$plain.jsonl"

# --------------------------------------------------------------------------
run() {  # run <day>; prints the facts block
  env CLAUDE_PROJECTS_DIR="$projects" CLAUDE_DIGEST_DIR="$digests" \
      CD_ROSTER="$sandbox/roster.json" CD_CALLS="$sandbox/calls" \
      PATH="$stubdir:$PATH" \
      "$bin" --generate --dry-run "$1" 2>"$sandbox/err"
}
# check <description> <0-or-1>. Every call site spells its condition as
# "$(if <cond>; then echo 0; else echo 1; fi)" rather than "<cond>; echo $?",
# so no exit status of a test is ever read back through $?.
check() {
  if [ "$2" = 0 ]; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi
}

d1="$(run 2026-03-01)"; rc1=$?
d2="$(run 2026-03-02)"; rc2=$?

check "dry-run exits 0 for both days" \
  "$(if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ]; then echo 0; else echo 1; fi)"

# --- 05:00 JST boundary -----------------------------------------------------
check "JST 04:30 (19:30Z) still belongs to the previous day" \
  "$(if grep -q "SESSION $early" <<<"$d1" && ! grep -q "SESSION $early" <<<"$d2"
     then echo 0; else echo 1; fi)"
check "JST 05:30 (20:30Z) starts the new day" \
  "$(if grep -q "SESSION $late" <<<"$d2" && ! grep -q "SESSION $late" <<<"$d1"
     then echo 0; else echo 1; fi)"

# --- fromdateiso8601 and fractional seconds --------------------------------
# Every fixture timestamp carries milliseconds. Without the sub() that strips
# them, jq aborts on the first entry and the transcript is skipped wholesale.
check "milliseconds in the timestamp do not break collection" \
  "$(if grep -q "SESSION $early" <<<"$d1" && ! grep -q 'unparseable transcript' "$sandbox/err"
     then echo 0; else echo 1; fi)"

# --- entrypoint filter ------------------------------------------------------
check "sdk-py sessions are excluded" \
  "$(if ! grep -q "SESSION $sdk" <<<"$d1"; then echo 0; else echo 1; fi)"

# --- uuid, not path, is the idempotency key --------------------------------
check "one session uuid under two project directories is counted once" \
  "$(if [ "$(grep -c "SESSION $dup" <<<"$d1")" -eq 1 ]; then echo 0; else echo 1; fi)"

# --- author derivation ------------------------------------------------------
check "a noreply address yields the numeric-id author pattern" \
  "$(if grep -qF "$repo_a base=origin/main author=<65004703+" <<<"$d1"
     then echo 0; else echo 1; fi)"
check "a plain address falls back to the address itself" \
  "$(if grep -qF "$repo_b base=origin/main author=plain@example.com" <<<"$d1"
     then echo 0; else echo 1; fi)"

# --- landed pull requests ---------------------------------------------------
check "a landed PR the session mentions is attached to it" \
  "$(if grep -q "^LANDED_PR: #101 feat: the mentioned one (自分の commit 1)" <<<"$d1"
     then echo 0; else echo 1; fi)"
check "a landed PR nobody mentioned goes to the unlinked list" \
  "$(if grep -q '^- #103 fix: landed but unmentioned' <<<"$d1"; then echo 0; else echo 1; fi)"
check "a near-miss author address is not counted as mine" \
  "$(if ! grep -q '#102' <<<"$d1"; then echo 0; else echo 1; fi)"
check "the plain-address pattern still finds my own landings" \
  "$(if grep -q '#201 feat: mine in repo_b' <<<"$d1"; then echo 0; else echo 1; fi)"
# "plain@example.com" as a basic regular expression matches
# "plain@exampleXcom"; as a fixed string it does not. Dropping the -F from
# git log --author is exactly this difference.
check "-F keeps a regex-only author collision out of the landed list" \
  "$(if ! grep -q '#202' <<<"$d1"; then echo 0; else echo 1; fi)"
check "a PR number the session merely mentions does not become a landing" \
  "$(if ! grep -q '#999' <<<"$d1"; then echo 0; else echo 1; fi)"

# --- leftover branches ------------------------------------------------------
check "a branch of mine that is ahead of the base is reported OPEN" \
  "$(if grep -q '^OPEN_BRANCH: feature/open ahead=1' <<<"$d1"; then echo 0; else echo 1; fi)"
check "a branch whose tip is somebody else's is dropped" \
  "$(if ! grep -q 'feature/theirs' <<<"$d1"; then echo 0; else echo 1; fi)"
check "the base branch itself is never a leftover" \
  "$(if ! grep -qE '^OPEN_BRANCH: main ' <<<"$d1"; then echo 0; else echo 1; fi)"
check "a merged branch whose remote is gone becomes a reap candidate" \
  "$(if grep -q '^- feature/landed (ahead=0 upstream gone)' <<<"$d1"
     then echo 0; else echo 1; fi)"

# --- empty and missing ------------------------------------------------------
check "a session with no ai-title falls back to its first prompt" \
  "$(if grep -q '^TITLE: first prompt of an untitled session' <<<"$d1"
     then echo 0; else echo 1; fi)"
check "a session with no surviving cwd is reported unreachable" \
  "$(if grep -q "^- ${bare:0:8} first prompt" <<<"$d1"; then echo 0; else echo 1; fi)"
check "an entry with no gitBranch produces no branch line" \
  "$(if ! grep -qE '^OPEN_BRANCH: +$' <<<"$d1"; then echo 0; else echo 1; fi)"

d0="$(run 2026-01-01)"; rc0=$?
check "a day with no sessions still produces a facts block" \
  "$(if [ "$rc0" -eq 0 ] && grep -q '^# 2026-01-01' <<<"$d0" && grep -q '^- なし' <<<"$d0"
     then echo 0; else echo 1; fi)"

# --- ordering ---------------------------------------------------------------
# A background session the roster reports as blocked outranks everything, and
# that call is the script's, never the model's.
jq -cn --arg id "$plain" \
  '[{sessionId:$id, kind:"background", status:null, state:"blocked"}]' >"$sandbox/roster.json"
dord="$(run 2026-03-01)"
first="$(grep '^### SESSION' <<<"$dord" | head -1)"
check "a blocked session sorts to the top" \
  "$(if grep -q "$plain" <<<"$first" && grep -q '^STATE: blocked' <<<"$dord"
     then echo 0; else echo 1; fi)"
check "a live session is not offered a --resume line" \
  "$(if ! grep -q "claude --resume $plain" <<<"$dord"; then echo 0; else echo 1; fi)"
echo '[]' >"$sandbox/roster.json"

# --- reachability -----------------------------------------------------------
check "a session with a surviving cwd is offered --resume with its own uuid" \
  "$(if grep -qF "RESUME: claude --resume $early   (cwd: $repo_a)" <<<"$d1"
     then echo 0; else echo 1; fi)"

# --- generate: idempotency and the two stages -------------------------------
: >"$sandbox/calls"
gen() {
  env CLAUDE_PROJECTS_DIR="$projects" CLAUDE_DIGEST_DIR="$digests" \
      CD_ROSTER="$sandbox/roster.json" CD_CALLS="$sandbox/calls" \
      PATH="$stubdir:$PATH" "$bin" --generate 2026-03-01 >/dev/null 2>>"$sandbox/err"
}
gen; g1=$?
calls1="$(wc -l <"$sandbox/calls")"
gen; g2=$?
calls2="$(wc -l <"$sandbox/calls")"

check "generate writes the day's digest" \
  "$(if [ "$g1" -eq 0 ] && [ -s "$digests/2026-03-01.md" ] \
       && grep -q 'STUB-DIGEST' "$digests/2026-03-01.md"
     then echo 0; else echo 1; fi)"
check "stage 1 writes one intermediate per session" \
  "$(if [ -s "$digests/2026-03-01/$early.md" ] && [ -s "$digests/2026-03-01/$dup.md" ]
     then echo 0; else echo 1; fi)"
# The second run reuses every intermediate, so it costs exactly one more -p
# call than the first: the reduce.
check "re-running a day reuses the intermediates and only redoes the reduce" \
  "$(if [ "$g2" -eq 0 ] && [ "$(( calls2 - calls1 ))" -eq 1 ]; then echo 0; else echo 1; fi)"
check "the reduce is handed the facts, not the raw transcripts" \
  "$(if grep -q "SHORT: ${early:0:8}" "$digests/2026-03-01.md"; then echo 0; else echo 1; fi)"

# --- show mode --------------------------------------------------------------
out="$(env CLAUDE_DIGEST_DIR="$digests" PATH="$stubdir:$PATH" "$bin" 2026-03-01 2>&1)"
check "show prints the requested day" \
  "$(if grep -q 'STUB-DIGEST' <<<"$out"; then echo 0; else echo 1; fi)"
if env CLAUDE_DIGEST_DIR="$digests" PATH="$stubdir:$PATH" "$bin" 2026-05-05 >/dev/null 2>&1
then rc=1; else rc=0; fi
check "show fails for a day that was never generated" "$rc"
out="$(env CLAUDE_DIGEST_DIR="$digests" PATH="$stubdir:$PATH" "$bin" 2>&1)"
check "show with no date picks the most recent digest" \
  "$(if grep -q 'STUB-DIGEST' <<<"$out"; then echo 0; else echo 1; fi)"

# --- argument handling ------------------------------------------------------
if "$bin" 2026-3-1 >/dev/null 2>&1; then rc=1; else rc=0; fi
check "a malformed date is rejected" "$rc"
if "$bin" --dry-run >/dev/null 2>&1; then rc=1; else rc=0; fi
check "--dry-run without --generate is rejected" "$rc"
if "$bin" --nope >/dev/null 2>&1; then rc=1; else rc=0; fi
check "an unknown flag is rejected" "$rc"

exit "$fail"
