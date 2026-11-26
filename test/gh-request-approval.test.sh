#!/usr/bin/env bash
# Tests for bin/gh-request-approval and bin/lib/gh-request-approval.sh.
#
# The logic (bin/lib/gh-request-approval.sh) is run directly with a gh stub
# that plays one PR from files under $state and appends every call to a log.
# The stub never runs the real gh, so no test can start a workflow or merge on
# a real repository. Settings live in a scratch dir (gra_config_root).
#
# The entry (bin/gh-request-approval) is run for real, but only along paths that
# stop before gh: outside a checkout and with -h. Those show the caller's
# environment (HOME, XDG_CONFIG_HOME, a PATH prefix) does not reach it.
# No test framework; run with bash.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
bindir="$here/../bin"
fail=0

tmp="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"

sha="$(printf '%040d' 0 | tr 0 a)"
other_sha="$(printf '%040d' 0 | tr 0 b)"
base_sha="$(printf '%040d' 0 | tr 0 c)"
nwo=example-org/example-repo
no_threads='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]},"latestOpinionatedReviews":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
thread_json() {  # thread_json <isResolved> <__typename of the first comment's author>
  jq -cn --argjson r "$1" --arg t "$2" \
    '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false},
      nodes:[{isResolved:$r, comments:{nodes:[{author:{__typename:$t}}]}}]},
      latestOpinionatedReviews:{pageInfo:{hasNextPage:false},nodes:[]}}}}}'
}
review_json() {  # review_json <state> <author __typename, or "null" for a deleted author>
  jq -cn --arg s "$1" --arg t "$2" --argjson ns "$no_threads" \
    '$ns | .data.repository.pullRequest.latestOpinionatedReviews.nodes
       = [{state:$s, author:(if $t == "null" then null else {__typename:$t} end)}]'
}

# A main checkout with a linked worktree inside it (dotrc's layout); the logic
# runs from the worktree and must anchor gh at the main checkout.
main="$tmp/main"
git init -q -b main "$main"
git -C "$main" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$main" worktree add -q -b wt "$main/.worktrees/wt" 2>/dev/null
wt="$main/.worktrees/wt"

stubdir="$tmp/stub"; mkdir -p "$stubdir"
state="$tmp/state"
cat >"$stubdir/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GRA_LOG"
jqexpr=""; prev=""
for a in "$@"; do [ "$prev" = --jq ] && jqexpr="$a"; prev="$a"; done
emit() { if [ -n "$jqexpr" ]; then jq -r "$jqexpr" <<<"$1"; else printf '%s\n' "$1"; fi; }
# pop <file>: the first line; it is consumed unless it is the last one left.
pop() {
  local f="$GRA_STATE/$1" first
  first="$(head -n1 "$f")"
  if [ "$(wc -l <"$f")" -gt 1 ]; then tail -n +2 "$f" >"$f.next" && mv "$f.next" "$f"; fi
  printf '%s\n' "$first"
}
case "$1 $2" in
  "repo view") emit "$(cat "$GRA_STATE/repo.json")" ;;
  "api user") emit "{\"login\":\"$(cat "$GRA_STATE/login")\"}" ;;
  "api graphql") pop threads ;;
  "api repos/"*/branches/*) emit "{\"commit\":{\"sha\":\"$(cat "$GRA_STATE/branch_sha")\"}}" ;;
  "api repos/"*compare/*) jq -c '{files: .}' "$GRA_STATE/files.json" ;;
  "pr view")
    case "$*" in
      *headRefOid*) emit "$(jq -cn --arg h "$(cat "$GRA_STATE/head")" '{headRefOid: $h}')" ;;
      *) emit "$(pop gate1)" ;;
    esac ;;
  "workflow run") exit "$(cat "$GRA_STATE/workflow_rc")" ;;
  # Succeeds, so a logic that merged after starting the workflow would still
  # exit 0; only the log shows it.
  "pr merge") exit 0 ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$stubdir/gh"
# Stands in for `mise exec -C <dir> -- <cmd...>`: records <dir>, runs the command there.
cat >"$stubdir/mise" <<'STUB'
#!/usr/bin/env bash
dir=""
while [ $# -gt 0 ]; do
  case "$1" in -C) dir="$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac
done
printf '%s\n' "$dir" >>"$GRA_MISE_LOG"
cd "${dir:-.}" && exec "$@"
STUB
chmod +x "$stubdir/mise"

cfg="$tmp/cfg"
conf="$cfg/$nwo"
files_of() {  # files_of <path>... -> files.json with one "modified" entry each
  printf '%s\n' "$@" | jq -R . | jq -s 'map({filename: ., status: "modified"})' >"$state/files.json"
}
reset_state() {
  rm -rf "$state" "$cfg"; mkdir -p "$state" "$conf"
  printf 'approve.yml\n' >"$conf/workflow"
  printf 'docs/\n' >"$conf/paths"
  printf '%s\n' "{\"nameWithOwner\":\"$nwo\",\"defaultBranchRef\":{\"name\":\"main\"}}" >"$state/repo.json"
  echo example-bot >"$state/login"
  printf '%s\n' '{"author":{"login":"example-bot"},"isCrossRepository":false,"baseRefName":"main","state":"OPEN"}' >"$state/gate1"
  echo "$sha" >"$state/head"
  echo "$base_sha" >"$state/branch_sha"
  printf '%s\n' "$no_threads" >"$state/threads"
  echo 0 >"$state/workflow_rc"
  files_of docs/a.md
}
# pr_set <jq filter>: applies it to every queued PR-gate response (the PR fields gate 1 reads).
pr_set() { jq -c "$1" "$state/gate1" >"$state/gate1.next" && mv "$state/gate1.next" "$state/gate1"; }

# gra <libdir> -- <args...>: runs gra_main from the worktree; rc in $rc, stderr in $tmp/err.
# timeout: a mutant that loops must not hang the suite.
gra() {
  local ld="$1"; shift; [ "$1" = -- ] && shift
  : >"$tmp/log"; : >"$tmp/mise.log"
  rc=0
  (cd "$wt" && timeout 20 env GRA_LOG="$tmp/log" GRA_MISE_LOG="$tmp/mise.log" GRA_STATE="$state" \
    PATH="$stubdir:$PATH" bash -c '
      set -euo pipefail
      . "$1/gh-mise.sh"; . "$1/gh-request-approval.sh"
      gra_config_root="$2"
      shift 2; gra_main "$@"' _ "$ld" "$cfg" "$@") >/dev/null 2>"$tmp/err" || rc=$?
}
called() { grep -q "^$1" "$tmp/log"; }
started() { called 'workflow run'; }

# --- control: the stub is what the workflow run reaches ----------------------
# Before any mutant runs, show that on the logic's real path the side effect
# lands in the stub's log with exactly the intended argv, through mise anchored
# at the main checkout.
reset_state
gra "$bindir/lib" -- 42 "$sha"
if [ "$rc" -eq 0 ] \
  && [ "$(grep '^workflow run' "$tmp/log")" = "workflow run approve.yml -R $nwo --ref refs/heads/main -f pr=42 -f head_sha=$sha" ] \
  && ! grep -q -- '--admin' "$tmp/log" \
  && grep -qFx "api repos/$nwo/branches/main --jq .commit.sha" "$tmp/log" \
  && grep -qFx "api repos/$nwo/compare/$base_sha...$sha" "$tmp/log"; then
  echo "ok: happy path starts the workflow through the stub, pinned to -R, the default branch ref and the SHA, no --admin; the compare is base-commit...SHA"
else echo "FAIL: happy path rc=$rc log=$(cat "$tmp/log") err=$(cat "$tmp/err")"; fail=1; fi

# --- checks, as functions so mutants can rerun them ---------------------------
# Each returns 0 when the logic behaves as specified.

ck_mainroot() {  # every gh call runs in the main checkout, never the worktree
  reset_state; gra "$1" -- 42 "$sha"
  [ "$rc" -eq 0 ] && [ -s "$tmp/mise.log" ] && [ "$(sort -u "$tmp/mise.log")" = "$main" ]
}
ck_args() {  # malformed calls stop with 1 before any gh call
  local a
  for a in "" "42" "4x $sha" "42 ${sha:0:39}" "42 ${sha^^}" "42 $sha extra" \
           "--enabled extra" "--admin 42 $sha" "42 $sha --admin"; do
    reset_state
    # shellcheck disable=SC2086
    gra "$1" -- $a; [ "$rc" -eq 1 ] && [ ! -s "$tmp/log" ] || return 1
  done
}
ck_enabled() {  # --enabled: 0 with both files, 4 without, 3 unusable; never touches the PR
  reset_state; gra "$1" -- --enabled
  [ "$rc" -eq 0 ] && [ "$(grep -vc '^repo view' "$tmp/log")" -eq 0 ] || return 1
  reset_state; rm "$conf/paths"; gra "$1" -- --enabled; [ "$rc" -eq 4 ] || return 1
  reset_state; rm "$conf/workflow"; gra "$1" -- --enabled; [ "$rc" -eq 4 ] || return 1
  reset_state; rm -r "$conf"; gra "$1" -- --enabled; [ "$rc" -eq 4 ] || return 1
  local w
  for w in "" "approve" "a b.yml" "../x.yml" $'a.yml\nb.yml'; do
    reset_state; printf '%s\n' "$w" >"$conf/workflow"; gra "$1" -- --enabled
    [ "$rc" -eq 3 ] || return 1
  done
  reset_state; chmod 000 "$conf"; gra "$1" -- --enabled; local r3=$rc; chmod 700 "$conf"
  [ "$r3" -eq 3 ] || return 1
  reset_state; rm "$conf/paths"; mkdir "$conf/paths"; gra "$1" -- --enabled
  [ "$rc" -eq 3 ] || return 1
  reset_state; printf '# the approve workflow\n\napprove.yaml\n' >"$conf/workflow"
  gra "$1" -- --enabled; [ "$rc" -eq 0 ]
}
ck_notenabled() {  # a repo without settings never gets a workflow run
  reset_state; rm -r "$conf"; gra "$1" -- 42 "$sha"
  [ "$rc" -eq 4 ] && ! started
}
ck_pr_gate() {  # state / author / fork / base -> 4 before the workflow
  local f
  for f in '.state = "CLOSED"' '.state = "MERGED"' '.author.login = "someone"' \
           '.isCrossRepository = true' '.baseRefName = "release"'; do
    reset_state; pr_set "$f"; gra "$1" -- 42 "$sha"
    [ "$rc" -eq 4 ] && ! started || return 1
  done
}
ck_human() {  # human threads / CHANGES_REQUESTED -> 4; bot ones and resolved ones pass
  local t
  for t in "$(thread_json false User)" "$(review_json CHANGES_REQUESTED User)" \
           "$(review_json CHANGES_REQUESTED null)" "$(review_json CHANGES_REQUESTED Bot)" \
           "$(jq -c '.data.repository.pullRequest.latestOpinionatedReviews.pageInfo.hasNextPage = true' <<<"$no_threads")" \
           "$(jq -c '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage = true' <<<"$no_threads")"; do
    reset_state; printf '%s\n' "$t" >"$state/threads"; gra "$1" -- 42 "$sha"
    [ "$rc" -eq 4 ] && ! started || return 1
  done
  for t in "$(thread_json false Bot)" "$(thread_json true User)" "$(review_json APPROVED Bot)"; do
    reset_state; printf '%s\n' "$t" >"$state/threads"; gra "$1" -- 42 "$sha"
    [ "$rc" -eq 0 ] || return 1
  done
}
ck_paths() {  # changed files outside the list, or under .github/ .claude/ -> 4
  local p
  for p in src/a.sh .github/workflows/ci.yml .GitHub/x docs/.claude/settings.json .claude/settings.json \
           CODEOWNERS docs/CODEOWNERS docs/codeowners; do
    reset_state; printf 'docs/\n.github/\n*\n' >"$conf/paths"
    [ "$p" = src/a.sh ] && printf 'docs/\n' >"$conf/paths"
    files_of docs/a.md "$p"; gra "$1" -- 42 "$sha"
    [ "$rc" -eq 4 ] && ! started || return 1
  done
  reset_state; jq -c '. + [{filename: "docs/b.md", previous_filename: "src/b.md", status: "renamed"}]' \
    "$state/files.json" >"$state/f" && mv "$state/f" "$state/files.json"
  gra "$1" -- 42 "$sha"; [ "$rc" -eq 4 ] && ! started || return 1
  for p in ':/docs/x' ':(top)docs/y'; do
    reset_state; printf '/docs/\n' >"$conf/paths"; files_of "$p"; gra "$1" -- 42 "$sha"
    [ "$rc" -eq 4 ] && ! started || return 1
  done
  reset_state; printf '[]\n' >"$state/files.json"; gra "$1" -- 42 "$sha"; [ "$rc" -eq 4 ] && ! started || return 1
  reset_state; printf 'docs/*\n!docs/secret.md\n' >"$conf/paths"; files_of docs/secret.md
  gra "$1" -- 42 "$sha"; [ "$rc" -eq 4 ] && ! started || return 1
  reset_state; printf '# nothing yet\n\n' >"$conf/paths"
  gra "$1" -- 42 "$sha"; [ "$rc" -eq 4 ] && ! started || return 1
  reset_state; jq -n '[range(100) | {filename: "docs/f\(.).md", status: "added"}]' >"$state/files.json"
  gra "$1" -- 42 "$sha"; [ "$rc" -eq 4 ] && ! started || return 1
  reset_state; files_of docs/a/b/c.md docs/x.md; gra "$1" -- 42 "$sha"; [ "$rc" -eq 0 ]
}
ck_head() {  # head is not the SHA -> 5 before the workflow
  reset_state; echo "$other_sha" >"$state/head"; gra "$1" -- 42 "$sha"
  [ "$rc" -eq 5 ] && ! started
}
ck_workflow_fail() {  # a failed workflow start -> 6
  reset_state; echo 1 >"$state/workflow_rc"; gra "$1" -- 42 "$sha"
  [ "$rc" -eq 6 ] && started
}
ck_stops() {  # after the workflow starts nothing else is called: no merge, no wait
  reset_state; gra "$1" -- 42 "$sha"
  [ "$rc" -eq 0 ] && [ "$(grep -c '^workflow run' "$tmp/log")" -eq 1 ] \
    && [ "$(tail -n1 "$tmp/log")" = "workflow run approve.yml -R $nwo --ref refs/heads/main -f pr=42 -f head_sha=$sha" ] \
    && ! called 'pr merge' && ! grep -q '/reviews' "$tmp/log"
}

ck_calls() {  # owner/name/pr reach the graphql query; every pr view is pinned with -R
  reset_state; gra "$1" -- 42 "$sha"
  [ "$rc" -eq 0 ] && grep -qF -- "-f owner=example-org -f name=example-repo -F pr=42" "$tmp/log" \
    && [ "$(grep -c '^pr view' "$tmp/log")" -gt 0 ] \
    && [ -z "$(grep '^pr view' "$tmp/log" | grep -vF -- "-R $nwo")" ]
}
ck_compare_pin() {  # the compare is base-commit...SHA; a branch response that is no commit is refused
  reset_state; gra "$1" -- 42 "$sha"
  [ "$rc" -eq 0 ] && grep -qFx "api repos/$nwo/branches/main --jq .commit.sha" "$tmp/log" \
    && grep -qFx "api repos/$nwo/compare/$base_sha...$sha" "$tmp/log" || return 1
  reset_state; echo main >"$state/branch_sha"; gra "$1" -- 42 "$sha"
  [ "$rc" -eq 1 ] && ! called 'api repos/.*/compare/' && ! started
}
ck_login() {  # no token login and a deleted PR author must not match each other
  reset_state; echo >"$state/login"; pr_set '.author = null'; gra "$1" -- 42 "$sha"
  [ "$rc" -eq 1 ] && ! started
}
ck_repoview() {  # an unusable repo view -> 1 before anything else
  local j
  for j in "{\"nameWithOwner\":\"example-org/..\",\"defaultBranchRef\":{\"name\":\"main\"}}" \
           "{\"nameWithOwner\":\"$nwo\",\"defaultBranchRef\":null}"; do
    reset_state; printf '%s\n' "$j" >"$state/repo.json"; gra "$1" -- 42 "$sha"
    [ "$rc" -eq 1 ] && ! started || return 1
  done
}
ck_pr_short() {  # a pr view output without a state line is unexpected output -> 1, no workflow
  reset_state; printf '%s\n' '{"author":{"login":"example-bot"}}' >"$state/gate1"
  gra "$1" -- 42 "$sha"
  [ "$rc" -eq 1 ] && ! started
}
ck_graphql_null() {  # a null pullRequest is no review state -> 1, no workflow
  reset_state; printf '%s\n' '{"data":{"repository":{"pullRequest":null}}}' >"$state/threads"
  gra "$1" -- 42 "$sha"
  [ "$rc" -eq 1 ] && ! started
}
checks="ck_mainroot ck_args ck_enabled ck_notenabled ck_pr_gate ck_human ck_paths ck_head ck_workflow_fail ck_stops ck_calls ck_compare_pin ck_login ck_repoview ck_graphql_null ck_pr_short"
for c in $checks; do
  if "$c" "$bindir/lib"; then echo "ok: $c"
  else echo "FAIL: $c rc=$rc log=$(cat "$tmp/log") err=$(cat "$tmp/err")"; fail=1; fi
done

# --- discrimination (evidence-over-guesswork §4) -------------------------------
# The lib is new, so its checks are mutated one at a time; each mutant must
# break the check that covers it. `cmp` keeps a sed that matched nothing from
# a mutant a no-op, and `bash -n` one that no longer parses from passing for the
# wrong reason. Every mutant still runs only against the stub. Called in the
# current shell (not in $(...)) so that `fail=1` sticks.
mutant() {  # mutant <name> <sed expression>; the mutant's lib dir is $tmp/mutant-<name>
  local d="$tmp/mutant-$1"
  rm -rf "$d"; mkdir -p "$d"; cp -a "$bindir/lib/." "$d/"
  sed "$2" "$bindir/lib/gh-request-approval.sh" >"$d/gh-request-approval.sh"
  if cmp -s "$bindir/lib/gh-request-approval.sh" "$d/gh-request-approval.sh"; then
    echo "FAIL: mutant '$1' is identical; the check is a no-op"; fail=1; return 1
  fi
  bash -n "$d/gh-request-approval.sh" || { echo "FAIL: mutant '$1' does not parse"; fail=1; return 1; }
}
expect_broken() {  # expect_broken <name> <sed> <check>
  mutant "$1" "$2" || return 0
  if ! "$3" "$tmp/mutant-$1"; then echo "ok: mutant '$1' breaks $3"
  else echo "FAIL: mutant '$1' still passes $3"; fail=1; fi
}
expect_broken reporoot 's|root="$(gh_mise_main_root)"|root="$(gh_mise_repo_root)"|' ck_mainroot
expect_broken noargsha 's|\[\[ "\$sha" =~ ^\[0-9a-f\]{40}\$ \]\] \|\||true \|\||' ck_args
expect_broken noenabledexit '/echo "\$gra_me: \$nwo is enabled/{n;s|exit 0|:|}' ck_enabled
expect_broken nowfcheck 's|\[\[ "\$workflow" =~ ^\[A-Za-z0-9_.-\]+\\.ya?ml\$ \]\]|true|' ck_enabled
expect_broken nobothfiles 's|\[ -e "\$workflow" \] && \[ -e "\$paths_file" \]|true|' ck_notenabled
expect_broken noshort 's|^  \[ -n "\$state" \] \|\| gra_die 1 "unexpected gh pr view output for #\$pr"$|  true|' ck_pr_short
expect_broken nostate 's|\[ "\$state" = OPEN \] \|\| gra_die 4 "#\$pr is|true \|\| gra_die 4 "#$pr is|' ck_pr_gate
expect_broken noauthor 's|\[ "\$author" = "\$me_login" \]|true|' ck_pr_gate
expect_broken nocross 's|\[ "\$cross" = false \]|true|' ck_pr_gate
expect_broken nobase 's|\[ "\$base" = "\$default_branch" \]|true|' ck_pr_gate
expect_broken nothreads 's|\[ "\$n" -eq 0 \] \|\||true \|\||' ck_human
expect_broken noreviews 's|\[ "\$r" -eq 0 \] \|\||true \|\||' ck_human
expect_broken nodotgithub 's|/.github/\*) gra_die 4|/.nothing/*) gra_die 4|' ck_paths
expect_broken nodotclaude 's|\*/.claude/\*) gra_die 4|*/.nothing/*) gra_die 4|' ck_paths
expect_broken noprevname 's|, (.previous_filename // empty \| (., "\\u0000"))||' ck_paths
expect_broken nonegation "s|'!'\\*) gra_die 4|'!nothing'*) gra_die 4|" ck_paths
expect_broken nocap 's|\[ "\$nfiles" -lt 100 \]|true|' ck_paths
expect_broken nohead 's|\[ "\$head" = "\$sha" \] \|\| gra_die 5 "#\$pr head is|true \|\| gra_die 5 "#$pr head is|' ck_head
expect_broken noworkflowrc 's|\|\| gra_die 6|\|\| true|' ck_workflow_fail
expect_broken nocolon 's|^      :\*) gra_die 4|      :nothing*) gra_die 4|' ck_paths
expect_broken nocodeowners 's/^      codeowners|docs\/codeowners) gra_die 4/      codeowners-nothing) gra_die 4/' ck_paths
expect_broken nodocscodeowners 's/codeowners|docs\/codeowners) gra_die 4/codeowners) gra_die 4/' ck_paths
expect_broken nozerofiles 's|\[ "\$nfiles" -gt 0 \]|true|' ck_paths
expect_broken nobotcr 's|select(.state == "CHANGES_REQUESTED")\]|select(.state == "CHANGES_REQUESTED" and .author.__typename != "Bot")]|' ck_human
expect_broken nocompareban 's|api "repos/\$nwo/compare/\$base_sha\.\.\.\$sha"|api "repos/$nwo/compare/$base...$sha"|' ck_compare_pin
expect_broken nobasehex 's|\[\[ "\$base_sha" =~ ^\[0-9a-f\]{40}\$ \]\] \|\||true \|\||' ck_compare_pin
expect_broken norinpr 's|gh_mise pr view "\$pr" -R "\$nwo" --json headRefOid|gh_mise pr view "$pr" --json headRefOid|' ck_calls
# A logic that goes on after the workflow start (merging, or polling reviews)
# must break ck_stops; the stub accepts the merge, so only the log can show it.
expect_broken mergesafter '/echo "\$gra_me: started \$workflow for/a\  gh_mise pr merge "$pr" -R "$nwo" --auto --merge --match-head-commit "$sha"' ck_stops
expect_broken pollsafter '/echo "\$gra_me: started \$workflow for/a\  gh_mise api "repos/$nwo/pulls/$pr/reviews" || true' ck_stops
expect_broken nologin 's|\[ -n "\$me_login" \] \|\| gra_die 1|true \|\| gra_die 1|' ck_login
expect_broken nodotdot 's,|\*/\.\./\*) gra_die,|*/.nothing/*) gra_die,' ck_repoview
expect_broken nodefaultbranch 's|\[ -n "\$default_branch" \] \|\| gra_die 1|true \|\| gra_die 1|' ck_repoview

# --- token resolution with the real mise --------------------------------------
# The logic resolves the token at the main checkout: its mise.gh.local.toml PAT
# when there is one, otherwise no GH_TOKEN (gh falls to hosts.yml) -- and a
# GH_TOKEN planted in the worktree's tracked mise.toml never reaches gh. The
# stub writes `ran:<GH_TOKEN>`, so a gh that never ran cannot pass as "no token".
# Hermetic as in gh-wrappers.test.sh: trust via MISE_TRUSTED_CONFIG_PATHS, no
# global config, the config walk stops at $tmp, ambient MISE_ENV / GH_* removed.
realmise="$(command -v mise 2>/dev/null || true)"
if [ -z "$realmise" ]; then
  echo "skip: no real mise on PATH; the token-resolution cases need it"
else
  tokdir="$tmp/tokstub"; mkdir -p "$tokdir" "$tmp/misecfg"
  cat >"$tokdir/gh" <<'STUB'
#!/usr/bin/env bash
printf 'ran:%s\n' "${GH_TOKEN:-}" >"$GRA_TOKEN_FILE"
case "$1 $2" in
  "repo view") printf 'example-org/example-repo\nmain\n' ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 99 ;;
esac
STUB
  chmod +x "$tokdir/gh"
  printf '[env]\nGH_TOKEN = "tok-from-worktree"\n' >"$wt/mise.toml"
  token_run() {  # token_run -> the stub's `ran:<GH_TOKEN>` line, empty if gh never ran
    : >"$tmp/token"; reset_state
    (cd "$wt" && env -u MISE_ENV -u GH_TOKEN -u GITHUB_TOKEN \
      MISE_TRUSTED_CONFIG_PATHS="$tmp" MISE_CEILING_PATHS="$tmp" \
      MISE_GLOBAL_CONFIG_FILE="$tmp/none.toml" MISE_CONFIG_DIR="$tmp/misecfg" \
      GRA_TOKEN_FILE="$tmp/token" PATH="$tokdir:$PATH" bash -c '
        . "$1/gh-mise.sh"; . "$1/gh-request-approval.sh"
        gra_config_root="$2"; gra_main --enabled' _ "$bindir/lib" "$cfg") >/dev/null 2>"$tmp/err"
    cat "$tmp/token"
  }
  printf '[env]\nGH_TOKEN = "tok-personal"\n' >"$main/mise.gh.local.toml"
  t="$(token_run)"
  [ "$t" = ran:tok-personal ] \
    && echo "ok: with mise.gh.local.toml in the main checkout gh gets its PAT, not the worktree's GH_TOKEN" \
    || { echo "FAIL: personal-PAT case token=$t err=$(cat "$tmp/err")"; fail=1; }
  rm "$main/mise.gh.local.toml"
  t="$(token_run)"
  [ "$t" = ran: ] \
    && echo "ok: without mise.gh.local.toml gh runs with no GH_TOKEN (hosts.yml), not the worktree's" \
    || { echo "FAIL: hosts.yml case token=$t err=$(cat "$tmp/err")"; fail=1; }
  rm "$wt/mise.toml"
fi

# --- the entry: the caller's environment does not reach the logic ------------
# Run for real, only along paths that end before any gh call: -h (prints the
# settings location and exits) and --enabled outside a checkout (exits 1 at
# gh_mise_main_root, which calls git). The caller's PATH carries a git that
# records its calls, so a PATH that leaks shows up in the log.
real_home="$(getent passwd "$(id -u)" | cut -d: -f6)"
leak="$tmp/leak"; mkdir -p "$leak" "$tmp/nogit"
printf '#!/usr/bin/env bash\necho "LEAKED git $*" >>"%s"\nexit 1\n' "$tmp/leak.log" >"$leak/git"
cp "$leak/git" "$leak/gh"; cp "$leak/git" "$leak/mise"
chmod +x "$leak/git" "$leak/gh" "$leak/mise"
entry() {  # entry <bin dir> <args...>; rc in $rc, stderr in $tmp/err
  local bd="$1"; shift
  : >"$tmp/leak.log"; rc=0
  (cd "$tmp/nogit" && env HOME="$tmp/fakehome" XDG_CONFIG_HOME="$tmp/xdg" PATH="$leak:$PATH" \
    GH_TOKEN=leaked GIT_DIR="$main/.git" MISE_ENV=gh "$bd/gh-request-approval" "$@") \
    >/dev/null 2>"$tmp/err" || rc=$?
}
ck_entry_help() {  # -h names the settings under getent's HOME, not $HOME or XDG_CONFIG_HOME
  entry "$1" -h
  [ "$rc" -eq 0 ] && grep -qF "settings: $real_home/.config/dotrc/bot-approve/" "$tmp/err" \
    && ! grep -qF "$tmp" "$tmp/err"
}
ck_entry_path() {  # the logic runs the system git, not the caller's PATH; GIT_DIR does not select a repo
  entry "$1" --enabled
  [ "$rc" -eq 1 ] && grep -q 'is not in a git working tree' "$tmp/err" && [ ! -s "$tmp/leak.log" ]
}
ck_entry_forged() {  # a forged marker with a dirty environment is refused before anything runs
  entry "$1" -h; local clean_rc=$rc
  : >"$tmp/leak.log"; rc=0
  (cd "$tmp/nogit" && env DOTRC_GH_REQUEST_APPROVAL_CLEAN=1 HOME="$tmp/fakehome" PATH="$leak:$PATH" \
    "$1/gh-request-approval" -h) >/dev/null 2>"$tmp/err" || rc=$?
  [ "$clean_rc" -eq 0 ] && [ "$rc" -eq 1 ] && grep -q 'despite DOTRC_GH_REQUEST_APPROVAL_CLEAN' "$tmp/err"
}
ck_entry_bashhooks() {  # an exported function (even with a forged marker) and BASH_ENV never run in either bash
  local fixed="$real_home/.local/bin:$real_home/.local/share/mise/shims:/usr/local/bin:/usr/bin:/bin"
  : >"$tmp/leak.log"; rc=0
  (cd "$tmp/nogit" && env -i DOTRC_GH_REQUEST_APPROVAL_CLEAN=1 HOME="$real_home" PATH="$fixed" \
    "BASH_FUNC_dirname%%=() { echo LEAKED dirname >>\"$tmp/leak.log\"; }" \
    "$1/gh-request-approval" -h) >/dev/null 2>"$tmp/err" || rc=$?
  [ "$rc" -eq 0 ] && [ ! -s "$tmp/leak.log" ] || return 1
  printf 'echo LEAKED BASH_ENV >>"%s"\n' "$tmp/leak.log" >"$tmp/bashenv"
  : >"$tmp/leak.log"; rc=0
  (cd "$tmp/nogit" && env BASH_ENV="$tmp/bashenv" "$1/gh-request-approval" -h) >/dev/null 2>"$tmp/err" || rc=$?
  [ "$rc" -eq 0 ] && [ ! -s "$tmp/leak.log" ]
}
for c in ck_entry_help ck_entry_path ck_entry_forged ck_entry_bashhooks; do
  if "$c" "$bindir"; then echo "ok: $c"
  else echo "FAIL: $c rc=$rc err=$(cat "$tmp/err") leak=$(cat "$tmp/leak.log" 2>/dev/null)"; fail=1; fi
done

entry_mutant() {  # entry_mutant <name> <sed expression>; the mutant's bin dir is $tmp/emutant-<name>
  local d="$tmp/emutant-$1"
  rm -rf "$d"; mkdir -p "$d"; cp -a "$bindir/." "$d/"
  sed "$2" "$bindir/gh-request-approval" >"$d/gh-request-approval"
  chmod +x "$d/gh-request-approval"
  if cmp -s "$bindir/gh-request-approval" "$d/gh-request-approval"; then
    echo "FAIL: entry mutant '$1' is identical; the check is a no-op"; fail=1
  fi
  bash -n "$d/gh-request-approval" || { echo "FAIL: entry mutant '$1' does not parse"; fail=1; }
}
entry_mutant nopriv '1s|^#!/bin/bash -p$|#!/usr/bin/env bash|'; d="$tmp/emutant-nopriv"
if ! ck_entry_bashhooks "$d"; then
  echo "ok: entry mutant 'nopriv' runs an exported function or BASH_ENV (ck_entry_bashhooks is discriminating)"
else echo "FAIL: entry mutant 'nopriv' still passed ck_entry_bashhooks"; fail=1; fi
# Without the re-exec the dirty-environment refusal is the remaining guard; the
# two are a double guard, so the mutant removes both.
entry_mutant noreexec '/^if \[ "\${!marker:-}" != 1 \]; then/,/^done$/d'; d="$tmp/emutant-noreexec"
if ! ck_entry_help "$d" && ! ck_entry_path "$d"; then
  echo "ok: entry mutant 'noreexec' lets the caller's HOME and PATH through (the entry checks are discriminating)"
else echo "FAIL: entry mutant 'noreexec' still passed the entry checks"; fail=1; fi
entry_mutant noenvi 's|exec /usr/bin/env -i |exec /usr/bin/env |'; d="$tmp/emutant-noenvi"
if ! ck_entry_help "$d"; then
  echo "ok: entry mutant 'noenvi' is refused by the dirty-environment check (ck_entry_help is discriminating)"
else echo "FAIL: entry mutant 'noenvi' still passed ck_entry_help"; fail=1; fi
entry_mutant nodirtycheck 's|\*) echo "gh-request-approval: \$v is set despite|*) : "|'; d="$tmp/emutant-nodirtycheck"
if ! ck_entry_forged "$d"; then
  echo "ok: entry mutant 'nodirtycheck' runs with a forged marker (ck_entry_forged is discriminating)"
else echo "FAIL: entry mutant 'nodirtycheck' still refused the forged marker"; fail=1; fi

exit "$fail"
