# shellcheck shell=bash
#
# gh-request-approval.sh -- gra_main <PR-number> <head-SHA> | --enabled
#
# For a PR whose head is <SHA>: check the gates, then start the repo's approve
# workflow. It stops there: it neither waits for the approval nor merges.
# --enabled only reports whether the repo's settings exist and are usable.
#
# Prerequisites: bin/lib/gh-mise.sh is sourced; jq and git are on PATH; the
# caller has set gra_config_root (a plain shell variable, not read from the
# environment): the directory holding <OWNER>/<NAME>/{paths,workflow}.
#
# Every failure goes through gra_die, which prints one line to stderr and exits
# with its code: 1 unexpected (arguments, gh failure or output), 3 settings
# unusable, 4 a gate refused, 5 the head is not <SHA>, 6 the workflow did not
# start.

gra_me=gh-request-approval
gra_config_root=""

gra_die() { echo "$gra_me: $2" >&2; exit "$1"; }

gra_usage() {
  {
    echo "usage: $gra_me <PR-number> <head-SHA>"
    echo "       $gra_me --enabled"
    echo "settings: ${gra_config_root:-<unset>}/<OWNER>/<NAME>/{paths,workflow}"
  } >&2
  exit "${1:-1}"
}

# gra_human_review_state <owner> <name> <pr> -- prints "<unresolved threads
# started by a non-Bot> <latest CHANGES_REQUESTED reviews by anyone>" (a deleted
# author counts as human; a Bot's CHANGES_REQUESTED counts too, since it blocks
# the merge as a human's does), or "more 0" when either list needs a second
# page: refused rather than paginated.
gra_human_review_state() {
  local out
  # shellcheck disable=SC2016  # $owner etc. are GraphQL variables
  out="$(gh_mise api graphql \
    -f query='query($owner:String!,$name:String!,$pr:Int!){
      repository(owner:$owner,name:$name){ pullRequest(number:$pr){
        reviewThreads(first:100){ pageInfo{ hasNextPage }
          nodes{ isResolved comments(first:1){ nodes{ author{ __typename } } } } }
        latestOpinionatedReviews(first:100){ pageInfo{ hasNextPage }
          nodes{ state author{ __typename } } } } } }' \
    -f owner="$1" -f name="$2" -F pr="$3")" \
    || gra_die 1 "gh api graphql (review threads of #$3) failed"
  jq -er '.data.repository.pullRequest as $p
      | if $p.reviewThreads.pageInfo.hasNextPage
           or ($p.latestOpinionatedReviews.pageInfo.hasNextPage // false) then "more 0"
        else ([$p.reviewThreads.nodes[] | select(.isResolved | not)
               | select((.comments.nodes[0].author.__typename // "") != "Bot")] | length) as $t
             | ([$p.latestOpinionatedReviews.nodes[] | select(.state == "CHANGES_REQUESTED")] | length) as $r
             | "\($t) \($r)"
        end' <<<"$out" \
    || gra_die 1 "unexpected review threads response for #$3"
}

gra_check_human_reviews() {  # <owner> <name> <pr>
  local out n r
  # not read <<<"$(...)": that would swallow gra_human_review_state's exit
  out="$(gra_human_review_state "$@")" || exit $?
  read -r n r <<<"$out"
  [ "$n" != more ] || gra_die 4 "#$3 has more than 100 review threads or reviews; refusing to judge a truncated list"
  [ "$n" -eq 0 ] || gra_die 4 "#$3 has $n unresolved review thread(s) started by a human"
  [ "$r" -eq 0 ] || gra_die 4 "#$3 has $r CHANGES_REQUESTED review(s)"
}

# gra_check_paths <nwo> <base branch> <sha> <paths file> <scratch dir> --
# at least one and fewer than 100 files changed from the merge base of the base
# branch and <sha> to <sha> (three-dot compare; both sides of a rename), all
# allowed by <paths file> (.gitignore format), and none is under the root
# .github/, .codex/ or .githooks/, under a .claude/ or .agents/ at any depth, is
# the root .mcp.json or a root or docs/ CODEOWNERS, or starts with ':' (git would
# read it as pathspec magic). Dies with 4 on a refusal.
# <paths file> has gitignore semantics: a negation cannot re-include a file
# under an excluded parent directory (`src/` then `!src/x` still allows src/x);
# write `src/*` for the negation to take effect.
gra_check_paths() {
  local nwo="$1" base="$2" sha="$3" list="$4" scratch="$5"
  local base_sha files_json nfiles p rc src _line pat checked expected

  [ -r "$list" ] || gra_die 3 "cannot read $list"
  rc=0
  grep -qvE '^[[:space:]]*(#.*)?$' "$list" 2>/dev/null || rc=$?
  case "$rc" in
    0) ;;
    1) gra_die 4 "$list has no patterns; no path is allowed" ;;
    *) gra_die 3 "cannot read $list" ;;
  esac

  # The base is resolved to a commit through the branches endpoint first: given
  # a bare name, compare would also resolve a tag of the same name.
  base_sha="$(gh_mise api "repos/$nwo/branches/$base" --jq .commit.sha)" \
    || gra_die 1 "gh api branches/$base failed"
  [[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] || gra_die 1 "unexpected branches/$base response: $base_sha"
  files_json="$(gh_mise api "repos/$nwo/compare/$base_sha...$sha")" \
    || gra_die 1 "gh api compare/$base_sha...$sha failed"
  nfiles="$(jq 'if (.files | type) == "array" then .files | length else error("no files array") end' <<<"$files_json")" \
    || gra_die 1 "unexpected compare/$base_sha...$sha response"
  # compare lists at most 300 files; refusing well below that means a list it
  # truncated can never pass unchecked.
  [ "$nfiles" -lt 100 ] || gra_die 4 "$sha changes 100 or more files; refusing to judge a truncated list"
  [ "$nfiles" -gt 0 ] || gra_die 4 "$sha changes no files"

  # NUL-separated so any byte in a path survives.
  jq -j '.files[] | (.filename, "\u0000"), (.previous_filename // empty | (., "\u0000"))' \
    <<<"$files_json" >"$scratch/paths" || gra_die 1 "unexpected compare/$base_sha...$sha response"

  while IFS= read -r -d '' p; do
    case "${p,,}" in
      :*) gra_die 4 "$p starts with ':', which git would read as pathspec magic" ;;
      codeowners|docs/codeowners) gra_die 4 "$p is a CODEOWNERS file, which is never approved this way" ;;
      .mcp.json) gra_die 4 "$p is the root .mcp.json, which is never approved this way" ;;
    esac
    # The leading and trailing '/' make a directory match only at a path
    # component boundary: */.claude/* catches a/b/.claude/x but not foo.claude/x.
    case "/${p,,}/" in
      /.github/*) gra_die 4 "$p is under .github/, which is never approved this way" ;;
      /.codex/*) gra_die 4 "$p is under .codex/, which is never approved this way" ;;
      /.githooks/*) gra_die 4 "$p is under .githooks/, which is never approved this way" ;;
      */.claude/*) gra_die 4 "$p is under .claude/, which is never approved this way" ;;
      # .claude/ may be a symlink into .agents/ (e.g. .claude/skills -> .agents/skills).
      */.agents/*) gra_die 4 "$p is under .agents/, which is never approved this way" ;;
    esac
  done <"$scratch/paths"

  # git evaluates the list as the info/exclude of an empty scratch repo, with no
  # config of the caller, user or system taking part. "Ignored" reads as
  # "allowed"; a path whose last matching pattern is a negation, or that
  # matches nothing, is refused.
  gra_scratch_git() {
    env -i PATH="$PATH" HOME="$scratch" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      git -c core.excludesFile=/dev/null -c core.ignoreCase=false "$@"
  }
  gra_scratch_git init -q "$scratch/repo" || gra_die 1 "git init failed in the scratch dir"
  # A git without a template dir does not create info/.
  mkdir -p "$scratch/repo/.git/info" || gra_die 1 "cannot create info/ in the scratch repo"
  cp "$list" "$scratch/repo/.git/info/exclude" || gra_die 3 "cannot read $list"

  rc=0
  (cd "$scratch/repo" && gra_scratch_git check-ignore --no-index --stdin -z -v -n) \
    <"$scratch/paths" >"$scratch/verdict" || rc=$?
  # 0: some path is ignored (allowed), 1: none is (including negation-only
  # matches); anything else is git failing.
  [ "$rc" -le 1 ] || gra_die 1 "git check-ignore failed ($rc); cannot judge the paths"

  # -z -v -n prints four fields per path: source, line number, pattern, path.
  checked=0
  while IFS= read -r -d '' src && IFS= read -r -d '' _line \
    && IFS= read -r -d '' pat && IFS= read -r -d '' p; do
    checked=$((checked + 1))
    if [ -z "$src" ] || [ -z "$pat" ]; then
      gra_die 4 "$p is not in the path list $list"
    fi
    case "$pat" in
      '!'*) gra_die 4 "$p is excluded by '$pat' in $list" ;;
    esac
  done <"$scratch/verdict"
  expected="$(tr -cd '\0' <"$scratch/paths" | wc -c)"
  [ "$checked" -eq "$expected" ] \
    || gra_die 4 "git check-ignore judged $checked of $expected paths; refusing"
}

# gra_check_pr_gate <nwo> <pr> <token login> <default branch> -- the PR is OPEN,
# its author is the token's own login, it is not from a fork and its base is the
# default branch. Dies with 4 on a refusal.
gra_check_pr_gate() {
  local nwo="$1" pr="$2" me_login="$3" default_branch="$4"
  local pr_out author cross base state
  pr_out="$(gh_mise pr view "$pr" -R "$nwo" --json author,isCrossRepository,baseRefName,state \
    --jq '(.author.login // ""), (.isCrossRepository | tostring), (.baseRefName // ""), (.state // "")')" \
    || gra_die 1 "gh pr view #$pr failed"
  { read -r author; read -r cross; read -r base; read -r state; } <<<"$pr_out" || true
  [ -n "$state" ] || gra_die 1 "unexpected gh pr view output for #$pr"
  [ "$state" = OPEN ] || gra_die 4 "#$pr is ${state:-in an unknown state}, not OPEN"
  [ "$author" = "$me_login" ] || gra_die 4 "#$pr is by '$author', not by the token's login $me_login"
  [ "$cross" = false ] || gra_die 4 "#$pr comes from a fork (isCrossRepository: $cross)"
  [ "$base" = "$default_branch" ] || gra_die 4 "#$pr targets '$base', not the default branch '$default_branch'"
}

gra_main() {
  local enabled_only=0 pr="" sha="" root repo_out nwo default_branch dir workflow paths_file
  local me_login head scratch

  case "${1:-}" in
    -h|--help) [ $# -eq 1 ] || gra_usage 1; gra_usage 0 ;;
    --enabled) [ $# -eq 1 ] || gra_usage 1; enabled_only=1 ;;
    *)
      [ $# -eq 2 ] || gra_usage 1
      pr="$1"; sha="$2"
      [[ "$pr" =~ ^[0-9]+$ ]] || gra_die 1 "PR number must be numeric (got: $pr)"
      [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || gra_die 1 "SHA must be 40 lower-case hex digits (got: $sha)"
      ;;
  esac
  [ -n "$gra_config_root" ] || gra_die 1 "gra_config_root is not set"

  # --- 1. repo -------------------------------------------------------------
  # gh runs in the main working tree, so mise reads the config of the main
  # checkout, its ancestor directories and the global one, never a linked
  # worktree's own; see gh_mise_main_root.
  root="$(gh_mise_main_root)" || gra_die 1 "$PWD is not in a git working tree"
  gh_mise_use "$root"
  repo_out="$(gh_mise repo view --json nameWithOwner,defaultBranchRef \
    --jq '.nameWithOwner, (.defaultBranchRef.name // "")')" \
    || gra_die 1 "gh repo view failed"
  { read -r nwo; read -r default_branch; } <<<"$repo_out" || true
  [[ "${nwo:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || gra_die 1 "gh repo view returned no usable repository (got: ${nwo:-})"
  case "/$nwo/" in */./*|*/../*) gra_die 1 "repository name has a . or .. component: $nwo" ;; esac
  [ -n "$default_branch" ] || gra_die 1 "gh repo view returned no default branch for $nwo"

  # --- 2. settings ---------------------------------------------------------
  dir="$gra_config_root/$nwo"
  workflow="$dir/workflow"; paths_file="$dir/paths"
  if [ -d "$dir" ]; then
    [ -r "$dir" ] && [ -x "$dir" ] || gra_die 3 "cannot read $dir"
  elif [ -e "$dir" ]; then
    gra_die 3 "$dir is not a directory"
  fi
  [ -e "$workflow" ] && [ -e "$paths_file" ] \
    || gra_die 4 "$nwo is not enabled: $dir needs both 'workflow' and 'paths'"
  [ -f "$workflow" ] && [ -r "$workflow" ] || gra_die 3 "cannot read $workflow"
  [ -f "$paths_file" ] && [ -r "$paths_file" ] || gra_die 3 "cannot read $paths_file"
  workflow="$(grep -vE '^[[:space:]]*(#.*)?$' "$workflow")" || workflow=""
  [[ "$workflow" =~ ^[A-Za-z0-9_.-]+\.ya?ml$ ]] \
    || gra_die 3 "$dir/workflow must hold one workflow file name (got: ${workflow:-<empty>})"
  if [ "$enabled_only" -eq 1 ]; then
    echo "$gra_me: $nwo is enabled (workflow $workflow)" >&2
    exit 0
  fi

  # --- 3. PR gates ---------------------------------------------------------
  me_login="$(gh_mise api user --jq .login)" || gra_die 1 "gh api user failed"
  [ -n "$me_login" ] || gra_die 1 "gh api user returned no login"
  gra_check_pr_gate "$nwo" "$pr" "$me_login" "$default_branch"
  gra_check_human_reviews "${nwo%%/*}" "${nwo#*/}" "$pr"
  scratch="$(mktemp -d)" || gra_die 1 "mktemp -d failed"
  # shellcheck disable=SC2064  # expand now: $scratch is local
  trap "rm -rf '$scratch'" EXIT
  gra_check_paths "$nwo" "$default_branch" "$sha" "$paths_file" "$scratch"

  # --- 4. head -------------------------------------------------------------
  head="$(gh_mise pr view "$pr" -R "$nwo" --json headRefOid --jq '.headRefOid // ""')" \
    || gra_die 1 "gh pr view #$pr failed"
  [ "$head" = "$sha" ] || gra_die 5 "#$pr head is ${head:-unknown}, not $sha"

  # --- 5. approve workflow -------------------------------------------------
  # Fully qualified ref: a bare name is also resolved as a tag, and a same-named
  # tag (which a pusher can create) would supply the workflow file and its secrets.
  gh_mise workflow run "$workflow" -R "$nwo" --ref "refs/heads/$default_branch" -f pr="$pr" -f head_sha="$sha" \
    || gra_die 6 "starting $workflow for #$pr failed"
  echo "$gra_me: started $workflow for #$pr at $sha" >&2
}
