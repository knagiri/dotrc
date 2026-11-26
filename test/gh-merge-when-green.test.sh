#!/usr/bin/env bash
# Functional tests for bin/gh-merge-when-green. gh is a stub that plays one PR
# from files under $state and appends every call to a log; it never runs the
# real gh, so no test can reach `gh pr merge --admin` on a real repository. A
# mise stub runs the command after `--` the way gh_mise expects. The repo the
# wrapper runs in is a scratch git repo with a linked worktree, so the path
# list is read from the scratch main working tree, never a real checkout.
# ADMIN_MERGE_REPOS comes from the environment (or a config file under the
# sandbox HOME). No test framework; run with bash.
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
pass_json='[{"name":"build","bucket":"pass","state":"SUCCESS"},{"name":"lint","bucket":"skipping","state":"SKIPPED"}]'
pending_json='[{"name":"build","bucket":"pending","state":"IN_PROGRESS"}]'

stubdir="$tmp/stub"; mkdir -p "$stubdir"
state="$tmp/state"
cat >"$stubdir/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
[ -z "${GH_REPO:-}" ] || echo "GH_REPO_SEEN=$GH_REPO" >>"$GH_LOG"
jqexpr=""; prev=""
for a in "$@"; do [ "$prev" = --jq ] && jqexpr="$a"; prev="$a"; done
emit() { if [ -n "$jqexpr" ]; then jq -r "$jqexpr" <<<"$1"; else printf '%s\n' "$1"; fi; }
# pop <file>: the first line; it is consumed unless it is the last one left.
pop() {
  local f="$GH_STATE/$1" first
  first="$(head -n1 "$f")"
  if [ "$(wc -l <"$f")" -gt 1 ]; then tail -n +2 "$f" >"$f.next" && mv "$f.next" "$f"; fi
  printf '%s\n' "$first"
}
case "$1 $2" in
  "repo view") emit "$(cat "$GH_STATE/repo.json")" ;;
  "api user") emit "{\"login\":\"$(cat "$GH_STATE/login")\"}" ;;
  "api repos/"*) cat "$GH_STATE/files.json" ;;
  "pr view") emit "$(jq -c --arg h "$(pop heads)" '.headRefOid = $h' "$GH_STATE/pr.json")" ;;
  "pr checks")
    c="$(pop checks)"
    case "$c" in
      NOCHECKS) echo "no checks reported on the 'feature/foo' branch" >&2; exit 1 ;;
      DENIED) echo "GraphQL: Resource not accessible by personal access token (repository.pullRequest.statusCheckRollup)" >&2; exit 1 ;;
      ERR) echo "something else broke" >&2; exit 1 ;;
      rc8:*) printf '%s\n' "${c#rc8:}"; exit 8 ;;
    esac
    printf '%s\n' "$c" ;;
  "pr merge") exit "$(cat "$GH_STATE/merge_rc")" ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$stubdir/gh"
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

# The repo the wrapper runs in: a main working tree and a linked worktree.
main="$tmp/main"
git init -q "$main"
git -C "$main" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
wt="$tmp/wt"
git -C "$main" worktree add -q "$wt" -b feature/foo
list="$main/.dotrc-admin-merge-paths"

files_of() {  # files_of <path>... -> files.json with one "modified" entry each
  printf '%s\n' "$@" | jq -R . | jq -s 'map({filename: ., status: "modified"})' >"$state/files.json"
}

reset_state() {
  rm -rf "$state"; mkdir -p "$state"
  printf '%s\n' '{"nameWithOwner":"example-org/example-repo","defaultBranchRef":{"name":"main"}}' >"$state/repo.json"
  echo example-bot >"$state/login"
  printf '%s\n' '{"author":{"login":"example-bot"},"isCrossRepository":false,"baseRefName":"main","headRefOid":""}' >"$state/pr.json"
  echo "$sha" >"$state/heads"
  printf '%s\n' "$pass_json" >"$state/checks"
  echo 0 >"$state/merge_rc"
  files_of docs/a.md
  printf 'docs/\n' >"$list"
  rm -f "$wt/.dotrc-admin-merge-paths"
}
checks_seq() { printf '%s\n' "$@" >"$state/checks"; }
heads_seq() { printf '%s\n' "$@" >"$state/heads"; }

# mwg <bindir> [VAR=value...] -- <args...>; rc in $rc, stderr in $tmp/err.
mwg() {
  local bd="$1"; shift
  local -a envs=() unsets=() repos=(ADMIN_MERGE_REPOS="example-org/example-repo")
  while [ "$1" != -- ]; do
    # env takes -u only before the assignments; an unset replaces the default.
    if [ "$1" = -u ]; then unsets+=(-u "$2"); repos=(); shift 2
    else envs+=("$1"); shift; fi
  done
  shift
  : >"$tmp/log"
  rc=0
  # timeout: a mutant without a working wait limit would otherwise poll forever.
  (cd "$wt" && timeout 20 env "${unsets[@]}" GH_LOG="$tmp/log" GH_STATE="$state" PATH="$stubdir:$PATH" \
    "${repos[@]}" \
    GH_MERGE_WHEN_GREEN_INITIAL_DELAY=0 GH_MERGE_WHEN_GREEN_INTERVAL=0 \
    GH_MERGE_WHEN_GREEN_TIMEOUT=5 GH_MERGE_WHEN_GREEN_NO_CHECKS_GRACE=0 \
    "${envs[@]}" "$bd/gh-merge-when-green" "$@") >/dev/null 2>"$tmp/err" || rc=$?
}
merged() { grep -q '^pr merge' "$tmp/log"; }
calls() { grep -c "^$1" "$tmp/log"; }

# expect <name> <want-rc> <merged yes|no> -- report the last mwg run.
expect() {
  local m=no; merged && m=yes
  if [ "$rc" -eq "$2" ] && [ "$m" = "$3" ]; then echo "ok: $1"
  else echo "FAIL: $1 (rc=$rc want $2, merged=$m want $3): $(cat "$tmp/err")"; fail=1; fi
}

# --- control: the stub is what the merge reaches ----------------------------
# Before any mutant runs, show that on the wrapper's real path (gh_mise -> mise
# stub -> gh stub) the merge call lands in the stub's log with exactly the
# intended argv, so a mutant that merges is caught here and goes nowhere else.
reset_state
mwg "$bindir" -- 42 "$sha"
if [ "$rc" -eq 0 ] && [ "$(grep '^pr merge' "$tmp/log")" = "pr merge 42 --admin --merge --match-head-commit $sha" ]; then
  echo "ok: happy path merges through the stub with --admin --merge --match-head-commit"
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
  for v in "example-org" "example-org/example-repo bad" "a/b/c" "example-org/exa mple"; do
    reset_state; mwg "$1" "ADMIN_MERGE_REPOS=$v" -- 42 "$sha"
    [ "$rc" -eq 3 ] && [ ! -s "$tmp/log" ] || return 1
  done
  reset_state; mwg "$1" -u ADMIN_MERGE_REPOS -- 42 "$sha"
  [ "$rc" -eq 3 ] && [ ! -s "$tmp/log" ]
}
ck_config_file() {  # read from the config file when the env is unset
  mkdir -p "$HOME/.config/dotrc"
  printf 'ADMIN_MERGE_REPOS=example-org/other example-org/example-repo\n' >"$HOME/.config/dotrc/config"
  reset_state; mwg "$1" -u ADMIN_MERGE_REPOS -- 42 "$sha"; local r1=$rc
  chmod 000 "$HOME/.config/dotrc/config"
  local r2=3
  if ! [ -r "$HOME/.config/dotrc/config" ]; then  # root reads anyway; skip then
    reset_state; mwg "$1" -u ADMIN_MERGE_REPOS -- 42 "$sha"; r2=$rc
  fi
  rm -rf "$HOME/.config/dotrc"
  [ "$r1" -eq 0 ] && [ "$r2" -eq 3 ]
}
ck_repo() {  # an unlisted repo -> 4; matching is case-insensitive
  reset_state; mwg "$1" ADMIN_MERGE_REPOS=example-org/another -- 42 "$sha"
  [ "$rc" -eq 4 ] && ! merged && [ "$(calls 'pr ')" -eq 0 ] || return 1
  reset_state; mwg "$1" ADMIN_MERGE_REPOS=Example-Org/Example-Repo -- 42 "$sha"
  [ "$rc" -eq 0 ]
}
ck_enabled() {  # --enabled: 0 / 4 / 3, never touches the PR
  reset_state; mwg "$1" -- --enabled; [ "$rc" -eq 0 ] || return 1
  [ "$(grep -vc '^repo view' "$tmp/log")" -eq 0 ] || return 1
  mwg "$1" ADMIN_MERGE_REPOS=example-org/another -- --enabled; [ "$rc" -eq 4 ] || return 1
  mwg "$1" -u ADMIN_MERGE_REPOS -- --enabled; [ "$rc" -eq 3 ] && [ ! -s "$tmp/log" ]
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
  reset_state; jq '.baseRefName = "release"' "$state/pr.json" >"$state/x" && mv "$state/x" "$state/pr.json"
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 4 ] && ! merged
}
ck_file_count() {  # 100 files (a full page) -> 4; 99 -> merged
  local -a f=(); local i
  for i in $(seq 1 100); do f+=("docs/f$i.md"); done
  reset_state; files_of "${f[@]}"; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 4 ] && ! merged || return 1
  reset_state; files_of "${f[@]:0:99}"; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 0 ]
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
  # gitignore cannot re-include under an excluded parent directory; accepted.
  path_case "$1" 'docs/\n!docs/keep.md\n' 0 docs/keep.md
}
ck_always_denied() {
  path_case "$1" '*\n' 0 src/a.sh || return 1                             # control
  path_case "$1" '*\n' 4 src/a.sh .github/workflows/ci.yml || return 1
  path_case "$1" '*\n' 4 .claude/settings.json || return 1
  path_case "$1" '*\n' 4 pkg/.claude/settings.local.json
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
ck_main_tree_list() {  # the worktree's copy is not read
  reset_state; printf 'docs/\n' >"$list"; printf '*\n' >"$wt/.dotrc-admin-merge-paths"; files_of src/a.sh
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 4 ] || return 1
  reset_state; printf '*\n' >"$list"; files_of src/a.sh
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 0 ]
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
ck_head_before() {
  # Two `pr view`s (gate, re-read after the files): the head is judged before
  # the wait starts, not by its first poll.
  reset_state; heads_seq "$other_sha"; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 5 ] && ! merged && [ "$(calls 'pr checks')" -eq 0 ] && [ "$(calls 'pr view')" -eq 2 ]
}
ck_head_while_files() {  # a push between the gate read and the file list
  reset_state; heads_seq "$sha" "$other_sha"; mwg "$1" -- 42 "$sha"
  [ "$rc" -eq 5 ] && ! merged && [ "$(calls 'pr view')" -eq 2 ]
}
ck_env_redirect() {  # GH_REPO / GIT_DIR from the caller are dropped
  reset_state; mwg "$1" GH_REPO=example-org/elsewhere "GIT_DIR=$tmp/nowhere" -- 42 "$sha"
  [ "$rc" -eq 0 ] || return 1
  # the stub would see GH_REPO if it leaked
  ! grep -q GH_REPO_SEEN "$tmp/log"
}
ck_head_during() {
  reset_state; heads_seq "$sha" "$sha" "$other_sha"; checks_seq "$pending_json"
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
  mwg "$1" -- 42 "$sha"; [ "$rc" -eq 6 ] && ! merged
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
  mwg "$1" GH_MERGE_WHEN_GREEN_TIMEOUT=0 -- 42 "$sha"; [ "$rc" -eq 8 ] && ! merged || return 1
  reset_state; checks_seq '[{"name":"odd","bucket":"weird","state":"?"}]'   # unknown bucket is not a pass
  mwg "$1" GH_MERGE_WHEN_GREEN_TIMEOUT=0 -- 42 "$sha"; [ "$rc" -eq 8 ] && ! merged
}
ck_denied() {
  reset_state; checks_seq DENIED; mwg "$1" -- 42 "$sha"; [ "$rc" -eq 9 ] && ! merged || return 1
  reset_state; checks_seq ERR; mwg "$1" -- 42 "$sha"; [ "$rc" -eq 1 ] && ! merged
}
ck_merge_fails() {
  reset_state; echo 1 >"$state/merge_rc"; mwg "$1" -- 42 "$sha"; [ "$rc" -eq 10 ]
}
ck_knobs() {
  reset_state; mwg "$1" GH_MERGE_WHEN_GREEN_INTERVAL=abc -- 42 "$sha"; [ "$rc" -eq 1 ] && ! merged
}

checks=(ck_args ck_config ck_config_file ck_repo ck_enabled ck_author ck_fork ck_base
  ck_file_count ck_list_missing ck_paths_outside ck_paths_forms ck_paths_negation
  ck_always_denied ck_rename ck_main_tree_list ck_default_ignore ck_global_config
  ck_head_before ck_head_while_files ck_env_redirect ck_head_during ck_fail ck_pending_then_pass ck_two_in_a_row
  ck_no_checks ck_no_checks_grace ck_timeout ck_denied ck_merge_fails ck_knobs)
for c in "${checks[@]}"; do
  if "$c" "$bindir"; then echo "ok: $c"
  else echo "FAIL: $c (rc=$rc): $(cat "$tmp/err")"; fail=1; fi
done

# --- discrimination (evidence-over-guesswork §4) -----------------------------
# The wrapper is new, so each guard is broken one at a time in a copy and the
# check covering it must then fail. `cmp` keeps a sed that matched nothing from
# passing as a mutant. The control above showed the merge of a mutant lands in
# the stub.
w="$bindir/gh-merge-when-green"
mutant() {  # mutant <name> <sed expression> <check fn>
  local d="$tmp/mutant-$1"
  rm -rf "$d"; mkdir -p "$d"; cp -a "$bindir/." "$d/"
  sed "$2" "$w" >"$d/gh-merge-when-green"; chmod +x "$d/gh-merge-when-green"
  if cmp -s "$w" "$d/gh-merge-when-green"; then
    echo "FAIL: mutant '$1' is identical; the sed matched nothing"; fail=1
  elif ! "$3" "$d" >/dev/null 2>&1; then
    echo "ok: mutant '$1' is caught by $3"
  else echo "FAIL: mutant '$1' still passes $3"; fail=1; fi
}
mutant sha-format 's/\^\[0-9a-f\]{40}\$/^.+$/' ck_args
mutant repo-format 's|\^\[A-Za-z0-9_.-\]+/\[A-Za-z0-9_.-\]+\$|^.+$|' ck_config
mutant repo-list 's/\[ "\$listed" -eq 0 \]/false/' ck_repo
mutant enabled-exit 's/  exit 0$/  exit 4/' ck_enabled
mutant author 's/\[ "\$author" = "\$me_login" \]/true/' ck_author
mutant fork 's/\[ "\$cross" = false \]/true/' ck_fork
mutant base 's/\[ "\$base" = "\$default_branch" \]/true/' ck_base
mutant file-count 's/\[ "\$nfiles" -lt 100 \]/[ "$nfiles" -lt 1000 ]/' ck_file_count
# A missing or pattern-less list is refused by its own check and again by the
# no-match check (nothing can match), and a missing one also by every read of
# it, so those guards are broken together (evidence-over-guesswork §4, double
# guard): with all of them gone, the case must merge and be caught.
no_match='s/if \[ -z "\$src" \] || \[ -z "\$pat" \]; then/if false; then/'
mutant list-empty "s/grep -qvE '\\^\\[\\[:space:\\]\\]\\*(#\\.\\*)?\\\$'/true/; $no_match" ck_list_missing
mutant list-missing "s/\\[ -[fr] \"\\\$paths_file\" \\] ||/true ||/; s/grep -qvE '\\^\\[\\[:space:\\]\\]\\*(#\\.\\*)?\\\$'/true/; s/^cp \"\\\$paths_file\" \"\\\$scratch\\/repo\\/.git\\/info\\/exclude\" ||/true ||/; $no_match" ck_list_missing
mutant no-match 's/if \[ -z "\$src" \] || \[ -z "\$pat" \]; then/if false; then/' ck_paths_outside
mutant negation "s/'!'\\*) die 4/'!'*) : /" ck_paths_negation
mutant github 's|/.github/\*) die 4|/.github/*) :|' ck_always_denied
mutant claude 's|\*/.claude/\*) die 4|*/.claude/*) :|' ck_always_denied
mutant rename 's/, (.previous_filename \/\/ empty | (., "\\u0000"))//' ck_rename
mutant worktree-list 's|paths_file="\$(dirname "\$common_dir")/|paths_file="$repo_root/|' ck_main_tree_list
mutant excludesfile 's| -c core.excludesFile=/dev/null "\$@"| "$@"|' ck_default_ignore
mutant global-config 's/GIT_CONFIG_GLOBAL=\/dev\/null/GIT_CONFIG_GLOBAL_X=/' ck_global_config
mutant head-before 's/\[ "\$head" = "\$sha" \] || die 5 "#\$pr head is/true || die 5 "#$pr head is/' ck_head_before
mutant head-while-files 's/\[ "\$head_after" = "\$head" \]/true/' ck_head_while_files
mutant env-ghrepo 's/^unset GH_REPO GH_HOST /unset GH_HOST /' ck_env_redirect
mutant env-gitdir 's/ GIT_DIR GIT_WORK_TREE/ GIT_WORK_TREE/' ck_env_redirect
mutant head-during 's/\[ "\$head" = "\$sha" \] || die 5 "#\$pr head moved/true || die 5 "#$pr head moved/' ck_head_during
mutant fail 's/if \[ "\$failed" -gt 0 \]/if false/' ck_fail
mutant pending 's/\[ "\$pending" -eq 0 \]/true/' ck_pending_then_pass
mutant streak 's/\[ "\$complete_streak" -lt 2 \]/[ "$complete_streak" -lt 1 ]/' ck_two_in_a_row
mutant zero-checks 's/elif \[ "\$total" -eq 0 \]/elif false/' ck_no_checks
mutant grace 's/\[ "\$elapsed" -lt "\$grace_s" \] ||/false ||/' ck_no_checks_grace
mutant nochecks-msg 's/no checks reported/no such message/' ck_no_checks
mutant timeout 's/\[ "\$elapsed" -lt "\$timeout_s" \] ||/true ||/' ck_timeout
mutant denied 's/Resource not accessible|HTTP 403/no such message/' ck_denied
mutant merge-rc 's/|| die 10 /|| die 1 /' ck_merge_fails

if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAILED"; exit 1; fi
