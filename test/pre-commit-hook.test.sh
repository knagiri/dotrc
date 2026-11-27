#!/usr/bin/env bash
# Functional tests for githooks/pre-commit. Each case builds throwaway repos
# under a mktemp dir, links the hook under test into the repo's hooks dir, and
# runs a real `git commit`: the commit either lands (HEAD moves) or is refused.
#
# Every scenario takes the hook under test as an argument, so the same scenario
# runs against mutants with one condition removed each -- the discrimination
# check (evidence-over-guesswork §4). A mutant that is byte-identical to the
# real hook would make its control vacuous, so each is checked to differ first.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
hook="$here/../githooks/pre-commit"
fail=0

tmp="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$tmp"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# A tool shell may inherit either marker from the caller.
unset CLAUDECODE CODEX_THREAD_ID

check() {  # check <description> <0-or-1>
  if [ "$2" = 0 ]; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi
}

# Mutants. Most remove one condition's line; the exceptions: nocommon removes
# only the git-dir comparison (an intermediate for nolinked); nolinked removes
# both halves of a (a double guard: a linked worktree fails each half, so
# removing one changes nothing there); nofallback replaces the main fallback
# with a no-op instead of deleting it.
mut="$tmp/mutants"; mkdir -p "$mut"
grep -v 'agent-env@dotrc' "$hook" >"$mut/noenv"
grep -v '^\[ "\$common" = "\$gitdir" \] || exit 0$' "$hook" >"$mut/nocommon"
grep -v '^\[ -d "\$top/.git" \] || exit 0$' "$hook" >"$mut/nodotgit"
grep -v '^\[ -d "\$top/.git" \] || exit 0$' "$mut/nocommon" >"$mut/nolinked"
grep -v '^\[ "\$branch" = "\$target" \] || exit 0$' "$hook" >"$mut/nobranch"
sed 's|^\[ -n "\$target" \] \|\| target=main$|:|' "$hook" >"$mut/nofallback"
grep -v '^git remote get-url origin ' "$hook" >"$mut/noorigin"
grep -v '^git rev-parse -q --verify HEAD ' "$hook" >"$mut/nohead"
chmod +x "$mut"/*
for m in noenv nocommon nodotgit nolinked nobranch nofallback noorigin nohead; do
  check "mutant '$m' really differs from the hook" \
    "$(if ! cmp -s "$hook" "$mut/$m"; then echo 0; else echo 1; fi)"
done

commit_in() {  # commit_in <repo> <file> <msg>   (no hook involved: --no-verify)
  echo "$3" >>"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q --no-verify -m "$3"
}

link_hook() {  # link_hook <repo> <hook>
  local d
  d="$(git -C "$1" rev-parse --path-format=absolute --git-path hooks)"
  mkdir -p "$d"
  ln -snf "$2" "$d/pre-commit"
}

# clone_with_remote <dir> <default-branch>: <dir>/work is a clone of a bare
# remote whose HEAD is <default-branch>, with one commit; origin/HEAD is set.
clone_with_remote() {
  local d="$1" defb="$2"
  mkdir -p "$d"
  git init -q -b "$defb" "$d/seed"
  commit_in "$d/seed" init.txt init
  git init -q --bare -b "$defb" "$d/remote.git"
  git -C "$d/seed" push -q "$d/remote.git" "HEAD:refs/heads/$defb"
  git clone -q "$d/remote.git" "$d/work"
}

# try_commit <cwd> <claudecode> [command] [repo]: runs <command> (default
# `git commit -q -m x` after staging a change) from <cwd> with CLAUDECODE set
# to <claudecode> (empty: unset). Prints one of:
#   landed   HEAD moved
#   refused  HEAD did not move and stderr carries the hook's refusal message
#   failed   HEAD did not move for any other reason (a broken fixture or
#            mutant), so a "refused" expectation cannot pass on it by accident
# stderr goes to $tmp/last.err. The repo whose HEAD is watched is the dir the
# command commits in, given as [repo] (default <cwd>).
try_commit() {
  local cwd="$1" cc="$2" cmd="${3:-git commit -q -m x}" repo="${4:-$1}" before after
  echo "$RANDOM" >>"$repo/change.txt"
  git -C "$repo" add change.txt
  before="$(git -C "$repo" rev-parse -q --verify HEAD)"
  if [ -n "$cc" ]; then
    (cd "$cwd" && CLAUDECODE="$cc" bash -c "$cmd") >/dev/null 2>"$tmp/last.err"
  else
    (cd "$cwd" && bash -c "$cmd") >/dev/null 2>"$tmp/last.err"
  fi
  after="$(git -C "$repo" rev-parse -q --verify HEAD)"
  if [ -n "$after" ] && [ "$after" != "$before" ]; then echo landed
  elif grep -qF 'pre-commit: commit を止めた' "$tmp/last.err"; then echo refused
  else echo failed; fi
}

# --- scenarios: each prints landed/refused ---------------------------------

# Main working tree on the integration branch, under Claude Code.
s_main() {
  clone_with_remote "$tmp/main-$1" main
  link_hook "$tmp/main-$1/work" "$2"
  try_commit "$tmp/main-$1/work" 1
}

s_codex() {
  clone_with_remote "$tmp/codex-$1" main
  link_hook "$tmp/codex-$1/work" "$2"
  CODEX_THREAD_ID=test-thread try_commit "$tmp/codex-$1/work" ""
}

# Same repo, no agent marker (a human's commit).
s_human() {
  clone_with_remote "$tmp/human-$1" main
  link_hook "$tmp/human-$1/work" "$2"
  try_commit "$tmp/human-$1/work" ""
}

# A feature branch in the main working tree.
s_feature() {
  clone_with_remote "$tmp/feat-$1" main
  git -C "$tmp/feat-$1/work" checkout -q -b feature
  link_hook "$tmp/feat-$1/work" "$2"
  try_commit "$tmp/feat-$1/work" 1
}

# A linked worktree on a feature branch.
s_linked_feature() {
  clone_with_remote "$tmp/lf-$1" main
  git -C "$tmp/lf-$1/work" worktree add -q -b feat "$tmp/lf-$1/wt"
  link_hook "$tmp/lf-$1/work" "$2"
  try_commit "$tmp/lf-$1/wt" 1
}

# A linked worktree that has the integration branch checked out (the main
# working tree moved off it): only condition a excludes it.
s_linked_main() {
  clone_with_remote "$tmp/lm-$1" main
  git -C "$tmp/lm-$1/work" checkout -q -b elsewhere
  git -C "$tmp/lm-$1/work" worktree add -q "$tmp/lm-$1/wt" main
  link_hook "$tmp/lm-$1/work" "$2"
  try_commit "$tmp/lm-$1/wt" 1
}

# The session's cwd is the main checkout (on main), and the commit runs after
# `cd` into a linked worktree on a feature branch: it lands, because the hook
# judges the repo the commit runs in, not the cwd. Background:
# docs/incidents/pre-tool-use-commit-guard-misses-cd.md.
s_cd_into_linked() {
  clone_with_remote "$tmp/cd-$1" main
  git -C "$tmp/cd-$1/work" worktree add -q -b feat "$tmp/cd-$1/wt"
  link_hook "$tmp/cd-$1/work" "$2"
  try_commit "$tmp/cd-$1/work" 1 "cd $tmp/cd-$1/wt && git commit -q -m x" "$tmp/cd-$1/wt"
}

# The reverse: cwd is a linked worktree, the commit runs after `cd` into the
# main checkout on main. Must be refused.
s_cd_into_main() {
  clone_with_remote "$tmp/cm-$1" main
  git -C "$tmp/cm-$1/work" worktree add -q -b feat "$tmp/cm-$1/wt"
  link_hook "$tmp/cm-$1/work" "$2"
  try_commit "$tmp/cm-$1/wt" 1 "cd $tmp/cm-$1/work && git commit -q -m x" "$tmp/cm-$1/work"
}

# No remote at all.
s_no_origin() {
  mkdir -p "$tmp/no-$1"
  git init -q -b main "$tmp/no-$1/r"
  commit_in "$tmp/no-$1/r" a.txt a
  link_hook "$tmp/no-$1/r" "$2"
  try_commit "$tmp/no-$1/r" 1
}

# The first commit of a new repo that already has origin.
s_first_commit() {
  clone_with_remote "$tmp/fc-$1" main   # only for its remote.git
  git init -q -b main "$tmp/fc-$1/r"
  git -C "$tmp/fc-$1/r" remote add origin "$tmp/fc-$1/remote.git"
  link_hook "$tmp/fc-$1/r" "$2"
  try_commit "$tmp/fc-$1/r" 1
}

# A submodule on main: the two git dirs match, but .git is a file.
s_submodule() {
  clone_with_remote "$tmp/sm-$1" main
  git init -q -b main "$tmp/sm-$1/super"
  commit_in "$tmp/sm-$1/super" s.txt s
  git -C "$tmp/sm-$1/super" -c protocol.file.allow=always submodule add -q "$tmp/sm-$1/remote.git" sub 2>/dev/null
  git -C "$tmp/sm-$1/super/sub" checkout -q main
  link_hook "$tmp/sm-$1/super/sub" "$2"
  try_commit "$tmp/sm-$1/super/sub" 1
}

# origin/HEAD names trunk: on trunk refused, on main passes.
s_trunk() {
  clone_with_remote "$tmp/tr-$1" trunk
  link_hook "$tmp/tr-$1/work" "$2"
  try_commit "$tmp/tr-$1/work" 1
}
s_main_while_trunk() {
  clone_with_remote "$tmp/mt-$1" trunk
  git -C "$tmp/mt-$1/work" checkout -q -b main
  link_hook "$tmp/mt-$1/work" "$2"
  try_commit "$tmp/mt-$1/work" 1
}

# origin exists but origin/HEAD is unset: falls back to main.
s_no_origin_head() {
  clone_with_remote "$tmp/nh-$1" main
  git -C "$tmp/nh-$1/work" remote set-head origin -d
  link_hook "$tmp/nh-$1/work" "$2"
  try_commit "$tmp/nh-$1/work" 1
}

expect() {  # expect <description> <want> <got>
  check "$1 (want $2, got $3)" "$(if [ "$2" = "$3" ]; then echo 0; else echo 1; fi)"
}

# --- the hook under test -----------------------------------------------------
expect "main working tree on the integration branch under Claude Code is refused" refused "$(s_main real "$hook")"
check "the refusal says to branch off with git switch -c, cites §5, and forbids --no-verify" \
  "$(if grep -qF 'git switch -c <branch>' "$tmp/last.err" && grep -qF 'session-scope.md §5' "$tmp/last.err" \
       && grep -qF -- '--no-verify' "$tmp/last.err"; then echo 0; else echo 1; fi)"
expect "main working tree on the integration branch under Codex is refused" refused "$(s_codex real "$hook")"
expect "without either agent marker the commit lands" landed "$(s_human real "$hook")"
expect "a feature branch in the main working tree lands" landed "$(s_feature real "$hook")"
expect "a linked worktree on a feature branch lands" landed "$(s_linked_feature real "$hook")"
expect "a linked worktree on the integration branch lands" landed "$(s_linked_main real "$hook")"
expect "cwd main checkout, cd into a linked worktree, commit lands" landed "$(s_cd_into_linked real "$hook")"
expect "cwd linked worktree, cd into the main checkout on main, commit is refused" refused "$(s_cd_into_main real "$hook")"
expect "no origin remote lands" landed "$(s_no_origin real "$hook")"
expect "the first commit lands" landed "$(s_first_commit real "$hook")"
expect "a submodule on main lands" landed "$(s_submodule real "$hook")"
expect "on origin/HEAD's branch (trunk) is refused" refused "$(s_trunk real "$hook")"
expect "on main while origin/HEAD is trunk lands" landed "$(s_main_while_trunk real "$hook")"
expect "origin/HEAD unset, on main is refused" refused "$(s_no_origin_head real "$hook")"

# --- discrimination: each mutant must fail the scenario its condition covers -
expect "control: without the agent check, a human's commit is refused" refused "$(s_human noenv "$mut/noenv")"
expect "control: without either half of a, a linked worktree on main is refused" refused "$(s_linked_main nolinked "$mut/nolinked")"
expect "control: without the .git directory check, a submodule on main is refused" refused "$(s_submodule nodotgit "$mut/nodotgit")"
expect "control: without the branch check, a feature branch is refused" refused "$(s_feature nobranch "$mut/nobranch")"
expect "control: without the main fallback, origin/HEAD unset on main lands" landed "$(s_no_origin_head nofallback "$mut/nofallback")"
expect "control: without the origin check, a repo with no origin is refused" refused "$(s_no_origin noorigin "$mut/noorigin")"
expect "control: without the HEAD check, the first commit is refused" refused "$(s_first_commit nohead "$mut/nohead")"

exit "$fail"
