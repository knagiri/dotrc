#!/usr/bin/env bash
# Functional tests for git-reap-gone. Each case builds a throwaway bare "remote"
# plus a clone, drives it into the exact state under test, and runs the real
# script against it. No test framework; run with bash.
#
# The central case is A: a branch merged on the remote while the LOCAL base is
# stale. `git branch -d` measures a [gone] branch against HEAD (its upstream is
# gone by definition), while the script's gate measures against origin/HEAD --
# so a stale local base made the gate pass and the deletion fail, leaving the
# worktree removed and the branch behind.
#
# $GIT_REAP_GONE_BIN overrides the script under test, which is how the
# discrimination check is run (point it at the pre-fix script; A must fail).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
src="${GIT_REAP_GONE_BIN:-$here/../bin/git-reap-gone}"
fail=0

tmp="$(mktemp -d)"
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

# Deterministic identity/branch names regardless of the host's git config.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# commit_in <repo> <file> <msg>
commit_in() {
  echo "$3" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "$3"
}

# new_case <name> [<default-branch>] -> echoes "<bare> <work>"
# A bare remote whose HEAD is pinned to <default-branch> (so the clone gets a
# reliable origin/HEAD), plus a clone with one initial commit.
new_case() {
  local d="$tmp/$1" defb="${2:-main}"
  local bare="$d/remote.git" seed="$d/seed" work="$d/work"
  mkdir -p "$d"
  git init -q --bare "$bare"
  git init -q "$seed"
  git -C "$seed" symbolic-ref HEAD "refs/heads/$defb"
  commit_in "$seed" init.txt init
  git -C "$seed" push -q "$bare" "HEAD:refs/heads/$defb"
  git -C "$bare" symbolic-ref HEAD "refs/heads/$defb"
  git clone -q "$bare" "$work"
  printf '%s %s' "$bare" "$work"
}

# merged_gone <work> -- create "feat" on top of the default branch, push it,
# then advance the remote's default branch to feat's commit (the merge) and
# delete the remote branch. The LOCAL default branch is deliberately left
# stale: that is the condition that broke `git branch -d`.
merged_gone() {
  local work="$1" defb="${2:-main}"
  git -C "$work" checkout -q -b feat
  commit_in "$work" feat.txt feat
  git -C "$work" push -q -u origin feat
  git -C "$work" checkout -q "$defb"
  git -C "$work" push -q origin "feat:$defb"
  git -C "$work" push -q origin --delete feat
}

# --- A: merged branch + stale local base + worktree -> reaped ------------------
# The regression this whole change exists for. Both the worktree AND the branch
# must be gone; before the fix the worktree vanished and the branch survived.
read -r bare work < <(new_case caseA)
merged_gone "$work"
git -C "$work" worktree add -q "$tmp/caseA/wt" feat
stale_main="$(git -C "$work" rev-parse main)"
out="$(cd "$work" && "$src" feat 2>&1)"; rc=$?
branch_left=$(git -C "$work" rev-parse --verify -q refs/heads/feat >/dev/null && echo yes || echo no)
if [ "$rc" -eq 0 ] && [ "$branch_left" = no ] && [ ! -d "$tmp/caseA/wt" ] \
   && grep -q 'reaped (1)' <<<"$out"; then
  ok "A: merged [gone] branch is reaped even with a stale local base"
else
  bad "A: rc=$rc branch_left=$branch_left worktree=$([ -d "$tmp/caseA/wt" ] && echo kept || echo gone)"
  sed 's/^/  out| /' <<<"$out"
fi
# ...and the fast-forward is what made it possible: local main moved to origin/main.
if [ "$(git -C "$work" rev-parse main)" = "$(git -C "$work" rev-parse origin/main)" ] \
   && [ "$(git -C "$work" rev-parse main)" != "$stale_main" ]; then
  ok "A: local main was fast-forwarded to origin/main"
else
  bad "A: main not fast-forwarded (still $(git -C "$work" rev-parse --short main))"
fi

# --- B: HEAD not on the integration base -> exit 1, nothing touched -----------
read -r bare work < <(new_case caseB)
merged_gone "$work"
git -C "$work" worktree add -q "$tmp/caseB/wt" feat
git -C "$work" fetch -q --prune
before_main="$(git -C "$work" rev-parse main)"
git -C "$work" checkout -q -b side
out="$(cd "$work" && "$src" --no-fetch 2>&1)"; rc=$?
branch_left=$(git -C "$work" rev-parse --verify -q refs/heads/feat >/dev/null && echo yes || echo no)
if [ "$rc" -eq 1 ] && [ "$branch_left" = yes ] && [ -d "$tmp/caseB/wt" ] \
   && [ "$(git -C "$work" rev-parse main)" = "$before_main" ] \
   && grep -q 'git switch main' <<<"$out"; then
  ok "B: HEAD off the base exits 1 without touching branches, worktrees or main"
else
  bad "B: rc=$rc branch_left=$branch_left worktree=$([ -d "$tmp/caseB/wt" ] && echo kept || echo gone)"
  sed 's/^/  out| /' <<<"$out"
fi

# --- C: diverged local base (ff fails) -> preflight skips, worktree KEPT ------
# The point is the ABSENCE of a half-reaped state: `git branch -d` would refuse
# here, so the worktree must never be removed in the first place.
read -r bare work < <(new_case caseC)
merged_gone "$work"
git -C "$work" worktree add -q "$tmp/caseC/wt" feat
git -C "$work" fetch -q --prune
commit_in "$work" local.txt "local-only"   # diverges main from origin/main
out="$(cd "$work" && "$src" --no-fetch 2>&1)"; rc=$?
branch_left=$(git -C "$work" rev-parse --verify -q refs/heads/feat >/dev/null && echo yes || echo no)
if [ "$rc" -eq 0 ] && [ "$branch_left" = yes ] && [ -d "$tmp/caseC/wt" ] \
   && grep -q 'not reachable from HEAD' <<<"$out" \
   && grep -q 'could not fast-forward' <<<"$out"; then
  ok "C: a failed fast-forward warns and skips before the worktree is touched"
else
  bad "C: rc=$rc branch_left=$branch_left worktree=$([ -d "$tmp/caseC/wt" ] && echo kept || echo gone)"
  sed 's/^/  out| /' <<<"$out"
fi

# --- D: [gone] branch with unintegrated commits -> skipped (non-regression) ---
read -r bare work < <(new_case caseD)
git -C "$work" checkout -q -b feat
commit_in "$work" feat.txt feat
git -C "$work" push -q -u origin feat
git -C "$work" checkout -q main
git -C "$work" push -q origin --delete feat   # deleted WITHOUT merging
out="$(cd "$work" && "$src" 2>&1)"; rc=$?
branch_left=$(git -C "$work" rev-parse --verify -q refs/heads/feat >/dev/null && echo yes || echo no)
if [ "$rc" -eq 0 ] && [ "$branch_left" = yes ] \
   && grep -q 'unintegrated commit(s) ahead of origin/main' <<<"$out"; then
  ok "D: unintegrated commits still block the reap"
else
  bad "D: rc=$rc branch_left=$branch_left"; sed 's/^/  out| /' <<<"$out"
fi

# --- E: dirty worktree -> skipped, both worktree and branch kept --------------
read -r bare work < <(new_case caseE)
merged_gone "$work"
git -C "$work" worktree add -q "$tmp/caseE/wt" feat
echo dirty >"$tmp/caseE/wt/dirty.txt"
out="$(cd "$work" && "$src" 2>&1)"; rc=$?
branch_left=$(git -C "$work" rev-parse --verify -q refs/heads/feat >/dev/null && echo yes || echo no)
if [ "$rc" -eq 0 ] && [ "$branch_left" = yes ] && [ -d "$tmp/caseE/wt" ] \
   && grep -q 'worktree not clean' <<<"$out"; then
  ok "E: a dirty worktree is skipped with both worktree and branch intact"
else
  bad "E: rc=$rc branch_left=$branch_left worktree=$([ -d "$tmp/caseE/wt" ] && echo kept || echo gone)"
  sed 's/^/  out| /' <<<"$out"
fi

# --- F: origin/master repo -> the base branch is never touched ----------------
# The never-touch guard used to be hardcoded to "main". Here the base is master,
# and master itself is driven [gone] (upstream pointed at a branch that is then
# deleted) so it would otherwise enter the loop.
read -r bare work < <(new_case caseF master)
git -C "$work" push -q origin master:refs/heads/tmpup
git -C "$work" branch -q --set-upstream-to=origin/tmpup master
git -C "$work" push -q origin --delete tmpup
git -C "$work" fetch -q --prune
out="$(cd "$work" && "$src" --no-fetch 2>&1)"; rc=$?
master_left=$(git -C "$work" rev-parse --verify -q refs/heads/master >/dev/null && echo yes || echo no)
if [ "$rc" -eq 0 ] && [ "$master_left" = yes ] \
   && grep -q 'reaped (0)' <<<"$out" && ! grep -q '^skipped' <<<"$out"; then
  ok "F: the base branch (master) is excluded before the loop, not skipped inside it"
else
  bad "F: rc=$rc master_left=$master_left"; sed 's/^/  out| /' <<<"$out"
fi

# Naming the base explicitly must say WHY, not the misleading "not a [gone] branch".
out="$(cd "$work" && "$src" --no-fetch master 2>&1)"; rc=$?
master_left=$(git -C "$work" rev-parse --verify -q refs/heads/master >/dev/null && echo yes || echo no)
if [ "$rc" -eq 0 ] && [ "$master_left" = yes ] && grep -q 'protected branch' <<<"$out"; then
  ok "F: filtering on the base branch reports it as protected"
else
  bad "F: protected-branch message rc=$rc master_left=$master_left"; sed 's/^/  out| /' <<<"$out"
fi

# --- G: HEAD off base AND base already checked out in another worktree -------
# Simulates the primary caller of worktree-scope.md §7: an agent running the
# script from inside the very linked worktree it was delegated into. `git
# switch main` there would fail with "already used by worktree", so the
# message must point at the other checkout's path instead.
read -r bare work < <(new_case caseG)
git -C "$work" checkout -q -b side
git -C "$work" checkout -q main   # main stays checked out in $work
git -C "$work" worktree add -q "$tmp/caseG/wt2" side
out="$(cd "$tmp/caseG/wt2" && "$src" --no-fetch 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q "already checked out at '$work'" <<<"$out" \
   && ! grep -q 'git switch main' <<<"$out"; then
  ok "G: HEAD off base from a linked worktree points at the other checkout"
else
  bad "G: rc=$rc"; sed 's/^/  out| /' <<<"$out"
fi

# --- H: worktree directory hand-removed -> skipped, not misread as clean -----
# `git worktree remove` was never run; only the directory itself was `rm -rf`'d,
# leaving the worktree registered in `git worktree list --porcelain`. Without
# the explicit `[ ! -d "$wt" ]` guard, `git -C <gone dir> status --porcelain`
# would fail and its empty stdout would be misread as "clean", leading straight
# into a `git worktree remove` that also fails on the missing directory.
read -r bare work < <(new_case caseH)
merged_gone "$work"
git -C "$work" worktree add -q "$tmp/caseH/wt" feat
rm -rf "$tmp/caseH/wt"
out="$(cd "$work" && "$src" 2>&1)"; rc=$?
branch_left=$(git -C "$work" rev-parse --verify -q refs/heads/feat >/dev/null && echo yes || echo no)
if [ "$rc" -eq 0 ] && [ "$branch_left" = yes ] \
   && grep -q 'worktree directory is missing' <<<"$out" \
   && grep -q 'git worktree prune' <<<"$out"; then
  ok "H: a hand-removed worktree directory is skipped, not misread as clean"
else
  bad "H: rc=$rc branch_left=$branch_left"; sed 's/^/  out| /' <<<"$out"
fi

exit "$fail"
