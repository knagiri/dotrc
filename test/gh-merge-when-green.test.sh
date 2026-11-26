#!/usr/bin/env bash
# Functional tests for bin/gh-merge-when-green. gh is a stub that plays one PR
# from files under $state and appends every call to a log; it never runs the
# real gh, so no test can reach `gh pr merge --admin` on a real repository.
# ADMIN_MERGE_REPOS and the path list live under XDG_CONFIG_HOME, pointed at a
# scratch dir, so the real dotrc config is never read or written. No test
# framework; run with bash.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
bindir="$here/../bin"
fail=0

tmp="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$tmp"' EXIT

sha="$(printf '%040d' 0 | tr 0 a)"
other_sha="$(printf '%040d' 0 | tr 0 b)"
base_sha="$(printf '%040d' 0 | tr 0 c)"
pass_json='[{"name":"build","bucket":"pass","state":"SUCCESS"},{"name":"lint","bucket":"skipping","state":"SKIPPED"}]'
pending_json='[{"name":"build","bucket":"pending","state":"IN_PROGRESS"}]'
no_threads='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]},"latestOpinionatedReviews":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
# thread_json <isResolved> <__typename of the first comment's author>
thread_json() {
  jq -cn --argjson r "$1" --arg t "$2" \
    '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false},
      nodes:[{isResolved:$r, comments:{nodes:[{author:{__typename:$t}}]}}]},
      latestOpinionatedReviews:{pageInfo:{hasNextPage:false},nodes:[]}}}}}'
}
# review_json <state> <author __typename, or "null" for a deleted author>
review_json() {
  jq -cn --arg s "$1" --arg t "$2" --argjson ns "$no_threads" \
    '$ns | .data.repository.pullRequest.latestOpinionatedReviews.nodes
       = [{state:$s, author:(if $t == "null" then null else {__typename:$t} end)}]'
}

stubdir="$tmp/stub"; mkdir -p "$stubdir"
state="$tmp/state"
cat >"$stubdir/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MWG_LOG"
# Any GitHub token or selector reaching gh from the caller's environment.
for v in $(compgen -v GH_) $(compgen -v GITHUB_); do
  case "$v" in GH_MERGE_WHEN_GREEN_*) ;; *) echo "LEAKED_ENV=$v" >>"$MWG_LOG" ;; esac
done
# Git's repo selectors reaching gh from the caller's environment.
for v in GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_CEILING_DIRECTORIES; do
  [ -z "${!v+x}" ] || echo "LEAKED_ENV=$v" >>"$MWG_LOG"
done
jqexpr=""; prev=""
for a in "$@"; do [ "$prev" = --jq ] && jqexpr="$a"; prev="$a"; done
emit() { if [ -n "$jqexpr" ]; then jq -r "$jqexpr" <<<"$1"; else printf '%s\n' "$1"; fi; }
# pop <file>: the first line; it is consumed unless it is the last one left.
pop() {
  local f="$MWG_STATE/$1" first
  first="$(head -n1 "$f")"
  if [ "$(wc -l <"$f")" -gt 1 ]; then tail -n +2 "$f" >"$f.next" && mv "$f.next" "$f"; fi
  printf '%s\n' "$first"
}
case "$1 $2" in
  "repo view") emit "$(cat "$MWG_STATE/repo.json")" ;;
  "api user") emit "{\"login\":\"$(cat "$MWG_STATE/login")\"}" ;;
  "api graphql")
    c="$(pop threads)"
    [ "$c" != GHFAIL ] || { echo "gh: graphql failed" >&2; exit 1; }
    printf '%s\n' "$c" ;;
  "api repos/"*/branches/*) emit "{\"commit\":{\"sha\":\"$(printf "%040d" 0 | tr 0 c)\"}}" ;;
  "api repos/"*compare/*) jq -c '{files: .}' "$MWG_STATE/files.json" ;;
  "pr view")
    emit "$(jq -c --arg h "$(pop heads)" --arg b "$(pop bases)" \
      '.headRefOid = $h | .baseRefName = $b' "$MWG_STATE/pr.json")" ;;
  "pr checks")
    c="$(pop checks)"
    case "$c" in
      NOCHECKS) echo "no checks reported on the 'feature/foo' branch" >&2; exit 1 ;;
      DENIED) echo "GraphQL: Resource not accessible by personal access token (repository.pullRequest.statusCheckRollup)" >&2; exit 1 ;;
      ERR) echo "something else broke" >&2; exit 1 ;;
      EMPTY) exit 0 ;;
      rc8:*) printf '%s\n' "${c#rc8:}"; exit 8 ;;
    esac
    printf '%s\n' "$c" ;;
  "pr merge") exit "$(cat "$MWG_STATE/merge_rc")" ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$stubdir/gh"
# gh must be called directly: a mise on PATH that is reached fails the run.
printf '#!/usr/bin/env bash\necho "MISE_CALLED $*" >>"$MWG_LOG"\nexit 97\n' >"$stubdir/mise"
chmod +x "$stubdir/mise"

xdg="$tmp/xdg"
conf="$xdg/dotrc/config"
list="$xdg/dotrc/admin-merge-paths/example-org/example-repo"
cwd="$tmp/cwd"; mkdir -p "$cwd"

files_of() {  # files_of <path>... -> files.json with one "modified" entry each
  printf '%s\n' "$@" | jq -R . | jq -s 'map({filename: ., status: "modified"})' >"$state/files.json"
}

reset_state() {
  rm -rf "$state" "$xdg"; mkdir -p "$state" "$(dirname "$list")"
  printf 'ADMIN_MERGE_REPOS=example-org/example-repo\n' >"$conf"
  printf '%s\n' '{"nameWithOwner":"example-org/example-repo","defaultBranchRef":{"name":"main"}}' >"$state/repo.json"
  echo example-bot >"$state/login"
  printf '%s\n' '{"author":{"login":"example-bot"},"isCrossRepository":false,"baseRefName":"","headRefOid":""}' >"$state/pr.json"
  echo "$sha" >"$state/heads"
  echo main >"$state/bases"
  printf '%s\n' "$pass_json" >"$state/checks"
  printf '%s\n' "$no_threads" >"$state/threads"
  echo 0 >"$state/merge_rc"
  files_of docs/a.md
  printf 'docs/\n' >"$list"
}
checks_seq() { printf '%s\n' "$@" >"$state/checks"; }
heads_seq() { printf '%s\n' "$@" >"$state/heads"; }

# mwg <bindir> [VAR=value...] -- <args...>; rc in $rc, stderr in $tmp/err.
# timeout: a mutant without a working wait limit would otherwise poll forever.
mwg() {
  local bd="$1"; shift
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : >"$tmp/log"
  rc=0
  (cd "$cwd" && timeout 20 env MWG_LOG="$tmp/log" MWG_STATE="$state" PATH="$stubdir:$PATH" \
    XDG_CONFIG_HOME="$xdg" \
    GH_MERGE_WHEN_GREEN_INITIAL_DELAY=0 GH_MERGE_WHEN_GREEN_INTERVAL=0 \
    GH_MERGE_WHEN_GREEN_TIMEOUT=5 GH_MERGE_WHEN_GREEN_NO_CHECKS_GRACE=0 \
    "${envs[@]}" "$bd/gh-merge-when-green" "$@") >/dev/null 2>"$tmp/err" || rc=$?
}
merged() { grep -q '^pr merge' "$tmp/log"; }
calls() { grep -c "^$1" "$tmp/log"; }

# --- control: the stub is what the merge reaches ----------------------------
# Before any mutant runs, show that on the wrapper's real path the merge call
# lands in the stub's log with exactly the intended argv, so a mutant that
# merges is caught here and goes nowhere else.
reset_state
mwg "$bindir" -- 42 "$sha"
if [ "$rc" -eq 0 ] && [ "$(grep '^pr merge' "$tmp/log")" = "pr merge 42 -R example-org/example-repo --admin --merge --match-head-commit $sha" ]; then
  echo "ok: happy path merges through the stub with -R --admin --merge --match-head-commit"
else echo "FAIL: happy path rc=$rc log=$(cat "$tmp/log") err=$(cat "$tmp/err")"; fail=1; fi

# --- the checks below, as functions so mutants can rerun them -----------------
# Each returns 0 when the wrapper behaves as specified.

ck_args() {  # malformed calls stop with 1 before any gh call
  local a
  for a in "" "42" "4x $sha" "42 ${sha:0:39}" "42 ${sha^^}" "42 $sha extra" \
           "--enabled extra" "--admin 42 $sha" "42 $sha --admin"; do
    # shellcheck disable=SC2086
    mwg "$1" -- $a; [ "$rc" -eq 1 ] && [ ! -s "$tmp/log" ] || return 1
  done
}
ck_config() {  # unusable ADMIN_MERGE_REPOS -> 3 before any gh call
  local v
  for v in "example-org" "example-org/example-repo bad" "a/b/c" "example-org/exa mple" \
           "../example-repo" "example-org/.."; do
    reset_state; printf 'ADMIN_MERGE_REPOS=%s\n' "$v" >"$conf"; mwg "$1" -- 42 "$sha"
    [ "$rc" -eq 3 ] && [ ! -s "$tmp/log" ] || return 1
  done
  reset_state; rm -f "$conf"; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 3 ] && [ ! -s "$tmp/log" ] || return 1
  reset_state; chmod 000 "$conf"
  if ! [ -r "$conf" ]; then  # root reads anyway; skip then
    mwg "$1" -- 42 "$sha"; [ "$rc" -eq 3 ] && [ ! -s "$tmp/log" ] || return 1
  fi
  chmod 600 "$conf"
}
ck_config_env_ignored() {  # the environment cannot name the repos
  reset_state; rm -f "$conf"
  mwg "$1" ADMIN_MERGE_REPOS=example-org/example-repo -- 42 "$sha"
  [ "$rc" -eq 3 ] && ! merged || return 1
  reset_state; printf 'ADMIN_MERGE_REPOS=example-org/another\n' >"$conf"
  mwg "$1" ADMIN_MERGE_REPOS=example-org/example-repo -- 42 "$sha"
  [ "$rc" -eq 4 ] && ! merged
}
ck_repo() {  # an unlisted repo -> 4; matching is case-insensitive, the list path follows the config's spelling
  reset_state; printf 'ADMIN_MERGE_REPOS=example-org/another\n' >"$conf"; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 4 ] && ! merged && [ "$(calls 'pr ')" -eq 0 ] || return 1
  reset_state; printf 'ADMIN_MERGE_REPOS=example-org/other Example-Org/Example-Repo\n' >"$conf"
  mkdir -p "$xdg/dotrc/admin-merge-paths/Example-Org"
  printf 'docs/\n' >"$xdg/dotrc/admin-merge-paths/Example-Org/Example-Repo"; rm -f "$list"
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 0 ]
}
ck_enabled() {  # --enabled: 0 / 4 / 3, never touches the PR
  reset_state; mwg "$1" -- --enabled; [ "$rc" -eq 0 ] || return 1
  [ "$(grep -vc '^repo view' "$tmp/log")" -eq 0 ] || return 1
  printf 'ADMIN_MERGE_REPOS=example-org/another\n' >"$conf"
  mwg "$1" -- --enabled; [ "$rc" -eq 4 ] || return 1
  rm -f "$conf"; mwg "$1" -- --enabled; [ "$rc" -eq 3 ] && [ ! -s "$tmp/log" ]
}
ck_env_dropped() {  # GitHub tokens / selectors and git selectors from the caller do not reach gh
  reset_state
  mwg "$1" GH_REPO=example-org/elsewhere GH_HOST=example.invalid GH_TOKEN=x \
    GH_CONFIG_DIR="$tmp/nowhere" GITHUB_TOKEN=y "GIT_DIR=$tmp/nowhere" \
    "GIT_WORK_TREE=$tmp/nowhere" "GIT_COMMON_DIR=$tmp/nowhere" "GIT_INDEX_FILE=$tmp/nowhere" \
    "GIT_CEILING_DIRECTORIES=$tmp/nowhere" -- 42 "$sha"
  [ "$rc" -eq 0 ] && ! grep -q '^LEAKED_ENV=' "$tmp/log"
}
ck_no_mise() {  # gh is called directly, never through mise
  reset_state; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 0 ] && ! grep -q '^MISE_CALLED' "$tmp/log"
}
ck_pinned_repo() {  # every PR call names the repo resolved first
  reset_state; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 0 ] || return 1
  ! grep '^pr ' "$tmp/log" | grep -vq -- '-R example-org/example-repo'
}
ck_author() {
  reset_state; echo someone-else >"$state/login"; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 4 ] && ! merged
}
ck_fork() {
  reset_state; jq '.isCrossRepository = true' "$state/pr.json" >"$state/x" && mv "$state/x" "$state/pr.json"
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 4 ] && ! merged
}
ck_base() {
  # One `pr view`: refused at the gate, not by the first poll's re-read.
  reset_state; echo release >"$state/bases"
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 4 ] && ! merged && [ "$(calls 'pr view')" -eq 1 ]
}
ck_base_during() {  # the base is re-read on every poll
  reset_state; printf 'main\nmain\nrelease\n' >"$state/bases"
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 4 ] && ! merged
}
ck_file_count() {  # 100 files (a full page) -> 4; 99 -> merged; none -> 4
  local -a f=(); local i
  for i in $(seq 1 100); do f+=("docs/f$i.md"); done
  reset_state; files_of "${f[@]}"; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 4 ] && ! merged || return 1
  reset_state; files_of "${f[@]:0:99}"; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 0 ] || return 1
  reset_state; echo '[]' >"$state/files.json"; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 4 ] && ! merged
}
# path_case <bindir> <list content> <want rc> <path>...
path_case() {
  local bd="$1" content="$2" want="$3"; shift 3
  reset_state; printf '%b' "$content" >"$list"; files_of "$@"
  mwg "$bd" -- 42 "$sha"; [ "$rc" -eq "$want" ]
}
ck_list_missing() {
  reset_state; rm -f "$list"; mwg "$1" -- 42 "$sha"; [ "$rc" -eq 4 ] && ! merged || return 1
  path_case "$1" '# only a comment\n\n   \n' 4 docs/a.md
}
ck_list_not_in_checkout() {  # a list in the cwd checkout is not read
  reset_state; printf '*\n' >"$cwd/.dotrc-admin-merge-paths"; files_of src/a.sh
  mwg "$1" -- 42 "$sha"; local r=$rc; rm -f "$cwd/.dotrc-admin-merge-paths"
  [ "$r" -eq 4 ]
}
ck_paths_outside() { path_case "$1" 'docs/\n' 4 docs/a.md src/b.sh; }
ck_paths_forms() {  # the main .gitignore forms, as git reads them
  path_case "$1" 'docs/\n' 0 docs/a/b/c.txt x/docs/d.txt || return 1   # dir pattern reaches nested paths
  path_case "$1" '*.md\n' 0 README.md deep/er/notes.md || return 1
  path_case "$1" '/rootonly.txt\n' 0 rootonly.txt || return 1
  path_case "$1" '/rootonly.txt\n' 4 z/rootonly.txt || return 1          # anchored
  path_case "$1" 'sub/**/x.txt\n' 0 sub/x.txt sub/a/b/x.txt
}
ck_paths_negation() {
  path_case "$1" 'docs/*\n!docs/secret.md\n' 4 docs/secret.md || return 1
  path_case "$1" 'docs/*\n!docs/secret.md\n' 0 docs/public.md || return 1
  # gitignore cannot re-include under an excluded parent directory, so `!`
  # cannot carve a path out of an allowed `dir/`; accepted and documented.
  path_case "$1" 'docs/\n!docs/keep.md\n' 0 docs/keep.md
}
ck_always_denied() {
  path_case "$1" '*\n' 0 src/a.sh || return 1                             # control
  path_case "$1" '*\n' 4 src/a.sh .github/workflows/ci.yml || return 1
  path_case "$1" '*\n' 4 .claude/settings.json || return 1
  path_case "$1" '*\n' 4 pkg/.claude/settings.local.json
}
ck_always_denied_case() {  # a case-insensitive checkout reads .Claude as .claude
  path_case "$1" '*\n' 4 .Claude/settings.json || return 1
  path_case "$1" '*\n' 4 .GitHub/workflows/ci.yml
}
ck_rename() {  # both sides of a rename are judged
  reset_state
  printf '%s\n' '[{"filename":"docs/new.md","previous_filename":"secret/old.md","status":"renamed"}]' >"$state/files.json"
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 4 ] && ! merged || return 1
  reset_state
  printf '%s\n' '[{"filename":"docs/new.md","previous_filename":"docs/old.md","status":"renamed"}]' >"$state/files.json"
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 0 ] || return 1
  reset_state  # a deleted file is a changed path like any other
  printf '%s\n' '[{"filename":"secret/gone.md","status":"removed"}]' >"$state/files.json"
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 4 ]
}
ck_default_ignore() {  # ~/.config/git/ignore (read with no excludesFile set) does not leak in
  mkdir -p "$HOME/.config/git"; printf '*\n' >"$HOME/.config/git/ignore"
  path_case "$1" 'docs/\n' 4 src/a.sh; local r=$?
  rm -rf "$HOME/.config/git"; return "$r"
}
ck_global_config() {  # ~/.gitconfig (ignoreCase, excludesFile) does not leak in
  printf '*\n' >"$tmp/globalignore"
  printf '[core]\n\tignoreCase = true\n\texcludesFile = %s\n' "$tmp/globalignore" >"$HOME/.gitconfig"
  path_case "$1" 'docs/\n' 4 DOCS/a.md; local r=$?
  rm -f "$HOME/.gitconfig"; return "$r"
}
ck_env_config() {  # config injected through the environment does not leak in
  reset_state; printf 'docs/\n' >"$list"; files_of DOCS/a.md
  mwg "$1" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.ignoreCase GIT_CONFIG_VALUE_0=true \
    "GIT_CONFIG_PARAMETERS='core.ignorecase'='true'" -- 42 "$sha"
  [ "$rc" -eq 4 ] && ! merged
}
ck_threads() {  # an unresolved thread started by a human blocks; bots and resolved ones do not
  reset_state; thread_json false User >"$state/threads"; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 4 ] && ! merged && [ "$(calls 'pr checks')" -eq 0 ] || return 1
  reset_state; thread_json false Bot >"$state/threads"; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 0 ] || return 1
  reset_state; thread_json true User >"$state/threads"; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 0 ] || return 1
  reset_state  # a deleted author has no __typename: counted as human
  jq -c '.data.repository.pullRequest.reviewThreads.nodes = [{isResolved:false, comments:{nodes:[{author:null}]}}]' \
    <<<"$no_threads" >"$state/threads"
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 4 ] && ! merged
}
ck_reviews() {  # a human's CHANGES_REQUESTED review blocks; a Bot's, or a human's approval, does not
  reset_state; review_json CHANGES_REQUESTED User >"$state/threads"; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 4 ] && ! merged && [ "$(calls 'pr checks')" -eq 0 ] || return 1
  reset_state; review_json CHANGES_REQUESTED Bot >"$state/threads"; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 0 ] && merged || return 1
  reset_state; review_json APPROVED User >"$state/threads"; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 0 ] || return 1
  reset_state; review_json CHANGES_REQUESTED null >"$state/threads"; mwg "$1" -- 42 "$sha"  # deleted author: human
  [ "$rc" -eq 4 ] && ! merged || return 1
  reset_state  # requested while the checks ran
  { printf '%s\n' "$no_threads"; review_json CHANGES_REQUESTED User; } >"$state/threads"
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 4 ] && ! merged && [ "$(calls 'pr checks')" -eq 2 ]
}
ck_files_pinned() {  # the file list is read for <SHA>, not for the PR's moving head
  reset_state; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 0 ] && grep -qx "api repos/example-org/example-repo/compare/$base_sha...$sha" "$tmp/log"
}
ck_threads_gh_fail() {  # a failing graphql call is exit 1 (unexpected gh failure), not 4 (gate refused)
  reset_state; echo GHFAIL >"$state/threads"; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 1 ] && ! merged || return 1
  reset_state; { printf '%s\n' "$no_threads"; echo GHFAIL; } >"$state/threads"  # also on the re-check before merging
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 1 ] && ! merged
}
ck_threads_page() {  # more than one page of threads is refused
  reset_state
  jq -c '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage = true' <<<"$no_threads" >"$state/threads"
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 4 ] && ! merged || return 1
  reset_state  # likewise for reviews
  jq -c '.data.repository.pullRequest.latestOpinionatedReviews.pageInfo.hasNextPage = true' <<<"$no_threads" >"$state/threads"
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 4 ] && ! merged
}
ck_threads_before_merge() {  # a human thread opened while the checks ran
  reset_state; { printf '%s\n' "$no_threads"; thread_json false User; } >"$state/threads"
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 4 ] && ! merged && [ "$(calls 'pr checks')" -eq 2 ]
}
ck_head_before() {
  # One `pr view` (the gate): the head is judged before the files are read and
  # before the wait starts, not by its first poll.
  reset_state; heads_seq "$other_sha"; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 5 ] && ! merged && [ "$(calls 'pr checks')" -eq 0 ] \
    && [ "$(calls 'pr view')" -eq 1 ] && [ "$(calls 'api repos/')" -eq 0 ]
}
ck_head_during() {
  reset_state; heads_seq "$sha" "$other_sha"; checks_seq "$pending_json"
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 5 ] && ! merged
}
ck_fail() {
  reset_state; checks_seq '[{"name":"build","bucket":"fail","state":"FAILURE"},{"name":"x","bucket":"pass","state":"SUCCESS"}]'
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 6 ] && ! merged || return 1
  reset_state; checks_seq '[{"name":"build","bucket":"cancel","state":"CANCELLED"}]'
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 6 ] && ! merged
}
ck_pending_then_pass() {
  reset_state; checks_seq "$pending_json" "rc8:$pending_json" "$pass_json"
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 0 ] && [ "$(calls 'pr checks')" -eq 4 ]
}
ck_two_in_a_row() {  # complete, then a late workflow appears -> wait again
  reset_state; checks_seq "$pass_json" "$pending_json" "$pass_json"
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 0 ] && [ "$(calls 'pr checks')" -eq 4 ] || return 1
  reset_state; checks_seq "$pass_json" '[{"name":"late","bucket":"fail","state":"FAILURE"}]'
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 6 ] && ! merged || return 1
  # checks vanishing in between also restart the count
  reset_state; checks_seq "$pass_json" NOCHECKS "$pass_json"
  mwg "$1" GH_MERGE_WHEN_GREEN_NO_CHECKS_GRACE=100 -- 42 "$sha"
  [ "$rc" -eq 0 ] && [ "$(calls 'pr checks')" -eq 4 ]
}
ck_no_checks() {
  reset_state; checks_seq NOCHECKS; mwg "$1" -- 42 "$sha"; [ "$rc" -eq 7 ] && ! merged || return 1
  reset_state; checks_seq '[]'; mwg "$1" -- 42 "$sha"; [ "$rc" -eq 7 ] && ! merged
}
ck_no_checks_grace() {  # checks that appear within the grace period are waited for
  reset_state; checks_seq NOCHECKS NOCHECKS "$pass_json"
  mwg "$1" GH_MERGE_WHEN_GREEN_NO_CHECKS_GRACE=100 -- 42 "$sha"; [ "$rc" -eq 0 ]
}
ck_timeout() {
  reset_state; checks_seq "$pending_json"
  mwg "$1" GH_MERGE_WHEN_GREEN_TIMEOUT=0 -- 42 "$sha"; [ "$rc" -eq 8 ] && ! merged
}
ck_unknown_bucket() {  # an unknown bucket is not a pass: waited on until the timeout
  reset_state; checks_seq '[{"name":"odd","bucket":"weird","state":"?"}]'
  mwg "$1" GH_MERGE_WHEN_GREEN_TIMEOUT=1 -- 42 "$sha"; [ "$rc" -eq 8 ] && ! merged
}
ck_denied() {
  reset_state; checks_seq DENIED; mwg "$1" -- 42 "$sha"; [ "$rc" -eq 9 ] && ! merged || return 1
  reset_state; checks_seq ERR; mwg "$1" -- 42 "$sha"; [ "$rc" -eq 1 ] && ! merged || return 1
  reset_state; checks_seq EMPTY; mwg "$1" -- 42 "$sha"; [ "$rc" -eq 1 ] && ! merged
}
ck_merge_fails() {
  reset_state; echo 1 >"$state/merge_rc"; mwg "$1" -- 42 "$sha"; [ "$rc" -eq 10 ]
}
ck_knobs() {
  reset_state; mwg "$1" GH_MERGE_WHEN_GREEN_INTERVAL=abc -- 42 "$sha"; [ "$rc" -eq 1 ] && ! merged
}

checks=(ck_args ck_config ck_config_env_ignored ck_repo ck_enabled ck_env_dropped
  ck_no_mise ck_pinned_repo ck_author ck_fork ck_base ck_base_during ck_file_count
  ck_list_missing ck_list_not_in_checkout ck_paths_outside ck_paths_forms
  ck_paths_negation ck_always_denied ck_always_denied_case ck_rename
  ck_default_ignore ck_global_config ck_env_config ck_threads ck_threads_gh_fail ck_threads_page
  ck_reviews ck_files_pinned ck_threads_before_merge ck_head_before ck_head_during
  ck_fail ck_pending_then_pass ck_two_in_a_row ck_no_checks ck_no_checks_grace
  ck_timeout ck_unknown_bucket ck_denied ck_merge_fails ck_knobs)
for c in "${checks[@]}"; do
  if "$c" "$bindir"; then echo "ok: $c"
  else echo "FAIL: $c (rc=$rc): $(cat "$tmp/err")"; fail=1; fi
done

# --- discrimination (evidence-over-guesswork §4) -----------------------------
# The wrapper is new, so each guard is broken one at a time in a copy and the
# check covering it must then fail. `cmp` keeps a sed that matched nothing from
# passing as a mutant. The control above showed the merge of a mutant lands in
# the stub; the unmutated copy below shows the copy itself passes every check,
# so a mutant is not "caught" merely because the copy is broken.
w="$bindir/gh-merge-when-green"
copy_of() {  # copy_of <name> [<sed expression>] -> prints the copy's bindir
  local d="$tmp/mutant-$1"
  rm -rf "$d"; mkdir -p "$d"; cp -a "$bindir/." "$d/"
  sed "${2:-}" "$w" >"$d/gh-merge-when-green"; chmod +x "$d/gh-merge-when-green"
  printf '%s\n' "$d"
}
d="$(copy_of unmutated)"
copy_ok=1
for c in "${checks[@]}"; do "$c" "$d" >/dev/null 2>&1 || { copy_ok=0; echo "FAIL: unmutated copy fails $c"; }; done
[ "$copy_ok" -eq 1 ] && echo "ok: an unmutated copy passes every check" || fail=1

mutant() {  # mutant <name> <sed expression> <check fn>
  local d; d="$(copy_of "$1" "$2")"
  if cmp -s "$w" "$d/gh-merge-when-green"; then
    echo "FAIL: mutant '$1' is identical; the sed matched nothing"; fail=1
  elif ! "$3" "$d" >/dev/null 2>&1; then
    echo "ok: mutant '$1' is caught by $3"
  else echo "FAIL: mutant '$1' still passes $3"; fail=1; fi
}
mutant sha-format 's/\^\[0-9a-f\]{40}\$/^.+$/' ck_args
mutant repo-format 's|\^\[A-Za-z0-9_.-\]+/\[A-Za-z0-9_.-\]+\$|^.+$|' ck_config
mutant repo-dots 's|\*/\./\*|\*/no/\*|; s|\*/\.\./\*|\*/nono/\*|' ck_config
mutant env-repos 's/^unset ADMIN_MERGE_REPOS$/: /' ck_config_env_ignored
mutant repo-list 's/\[ -n "\$listed" \]/true/' ck_repo
mutant list-spelling 's|admin-merge-paths/\$listed"|admin-merge-paths/$nwo"|' ck_repo
mutant enabled-exit 's/  exit 0$/  exit 4/' ck_enabled
mutant env-gh 's/\*) unset "\$v" ;; esac/*) : ;; esac/' ck_env_dropped
mutant pin-repo 's/gh pr view "\$pr" -R "\$nwo"/gh pr view "$pr"/' ck_pinned_repo
mutant via-mise 's/^me_login="\$(gh api user/me_login="$(mise exec -- gh api user/' ck_no_mise
mutant author 's/\[ "\$author" = "\$me_login" \]/true/' ck_author
mutant fork 's/\[ "\$cross" = false \]/true/' ck_fork
mutant base 's/\[ -n "\$default_branch" \] && \[ "\$base" = "\$default_branch" \]/true/' ck_base
mutant base-during 's/\[ "\$base" = "\$default_branch" \] || die 4/true || die 4/' ck_base_during
mutant file-count 's/\[ "\$nfiles" -lt 100 \]/[ "$nfiles" -lt 1000 ]/' ck_file_count
mutant file-none 's/\[ "\$nfiles" -gt 0 \]/true/' ck_file_count
# A missing or pattern-less list is refused by its own check and again by the
# no-match check (nothing can match), and a missing one also by every read of
# it, so those guards are broken together (evidence-over-guesswork §4, double
# guard): with all of them gone, the case must merge and be caught.
no_match='s/if \[ -z "\$src" \] || \[ -z "\$pat" \]; then/if false; then/'
mutant list-empty "s/grep -qvE '\\^\\[\\[:space:\\]\\]\\*(#\\.\\*)?\\\$'/true/; $no_match" ck_list_missing
mutant list-missing "s/\\[ -[fr] \"\\\$paths_file\" \\] ||/true ||/; s/grep -qvE '\\^\\[\\[:space:\\]\\]\\*(#\\.\\*)?\\\$'/true/; s/^cp \"\\\$paths_file\" \"\\\$scratch\\/repo\\/.git\\/info\\/exclude\" ||/true ||/; $no_match" ck_list_missing
mutant no-match "$no_match" ck_paths_outside
mutant negation "s/'!'\\*) die 4/'!'*) : /" ck_paths_negation
mutant github 's|/.github/\*) die 4|/.github/*) :|' ck_always_denied
mutant claude 's|\*/.claude/\*) die 4|*/.claude/*) :|' ck_always_denied
mutant denied-case 's|case "/\${p,,}/" in|case "/$p/" in|' ck_always_denied_case
mutant rename 's/, (.previous_filename \/\/ empty | (., "\\u0000"))//' ck_rename
# The user's files are kept out twice or three times over: HOME is a scratch
# dir under env -i, the global config is /dev/null, and -c fixes excludesFile
# and ignoreCase. Each case breaks all the guards that cover it together.
home_through='s/  env -i PATH="\$PATH" HOME="\$scratch"/  env -i PATH="$PATH" HOME="$HOME"/'
mutant excludesfile "$home_through; s| -c core.excludesFile=/dev/null -c core.ignoreCase=false \"\\\$@\"| -c core.ignoreCase=false \"\$@\"|" ck_default_ignore
mutant global-config "$home_through; s/GIT_CONFIG_GLOBAL=\\/dev\\/null/GIT_CONFIG_GLOBAL_X=/; s/ -c core.ignoreCase=false \"\\\$@\"/ \"\$@\"/" ck_global_config
mutant env-config 's/  env -i PATH="\$PATH" HOME="\$scratch"/  env HOME="$scratch"/; s/ -c core.ignoreCase=false "\$@"/ "$@"/' ck_env_config
mutant threads 's/\[ "\$n" -eq 0 \] || die 4/true || die 4/' ck_threads
mutant reviews 's/\[ "\$r" -eq 0 \] || die 4/true || die 4/' ck_reviews
mutant reviews-bot 's/(.author.__typename \/\/ "") != "Bot")\] | length) as \$r/(.author.__typename \/\/ "") != "Nobody")] | length) as $r/' ck_reviews
mutant reviews-state 's/select(.state == "CHANGES_REQUESTED")/select(.state != "CHANGES_REQUESTED")/' ck_reviews
mutant reviews-page 's/ or (\$p.latestOpinionatedReviews.pageInfo.hasNextPage \/\/ false)//' ck_threads_page
mutant files-pin 's|compare/\$base_sha\.\.\.\$sha")|compare/$base_sha...$base_sha")|' ck_files_pinned
mutant base-by-name 's|^files_json="\$(gh api "repos/\$nwo/compare/\$base_sha|files_json="$(gh api "repos/$nwo/compare/$base|' ck_files_pinned
mutant git-env 's/^unset GIT_DIR GIT_WORK_TREE.*$/:/' ck_env_dropped
mutant threads-gh-fail 's/^  out="\$(human_threads)" || exit \$?$/  out="$(human_threads)" || true/' ck_threads_gh_fail
mutant threads-bot 's/!= "Bot")\]/!= "Nobody")]/' ck_threads
# "more" is also refused by the numeric test that follows (a non-number fails
# -eq), so both are broken together.
mutant threads-page 's/\[ "\$n" != more \] || die 4/true || die 4/; s/\[ "\$n" -eq 0 \] || die 4/true || die 4/' ck_threads_page
mutant threads-final '/^# A human may have opened a thread or requested changes while the checks ran\.$/{n;s/^check_threads$/:/}' ck_threads_before_merge
mutant head-before 's/\[ "\$head" = "\$sha" \] || die 5 "#\$pr head is/true || die 5 "#$pr head is/' ck_head_before
mutant head-during 's/\[ "\$head" = "\$sha" \] || die 5 "#\$pr head moved/true || die 5 "#$pr head moved/' ck_head_during
mutant fail 's/if \[ "\$failed" -gt 0 \]/if false/' ck_fail
mutant pending 's/\[ "\$pending" -eq 0 \]/true/' ck_pending_then_pass
mutant unknown-bucket 's/(map(select(.bucket != "pass" and .bucket != "skipping"/(map(select(.bucket == "pending" and .bucket != "skipping"/' ck_unknown_bucket
mutant streak 's/\[ "\$complete_streak" -lt 2 \]/[ "$complete_streak" -lt 1 ]/' ck_two_in_a_row
mutant streak-reset '/elif \[ "\$total" -eq 0 \]; then/{n;s/complete_streak=0/:/}' ck_two_in_a_row
mutant zero-checks 's/elif \[ "\$total" -eq 0 \]/elif false/' ck_no_checks
mutant grace 's/\[ "\$elapsed" -lt "\$grace_s" \] ||/false ||/' ck_no_checks_grace
mutant nochecks-msg 's/no checks reported/no such message/' ck_no_checks
mutant timeout 's/\[ "\$elapsed" -lt "\$timeout_s" \] ||/true ||/' ck_timeout
mutant denied 's/Resource not accessible|HTTP 403/no such message/' ck_denied
mutant empty-checks "s/counts=\"\$(jq -er /counts=\"\$(jq -r /" ck_denied
mutant merge-rc 's/|| die 10 /|| die 1 /' ck_merge_fails

if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAILED"; exit 1; fi
