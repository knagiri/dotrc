#!/usr/bin/env bash
# Functional tests for githooks/post-merge. Each case builds a throwaway bare
# "remote" plus a clone with the hook linked into its hooks/, drives a real
# `git pull` (or merge), and records whether the hook called make. make and go
# are stubs: the make stub logs its cwd, its arguments, and the top level the
# Makefile would compute (`git rev-parse --show-toplevel` from the -C dir), so
# no Go build ever runs.
#
# Every scenario takes the hook under test as an argument, so the same scenario
# runs against mutants with one guard removed each -- the discrimination check
# (evidence-over-guesswork §4). A mutant that is byte-identical to the real
# hook would make its control vacuous, so each is checked to differ first.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
hook="$here/../githooks/post-merge"
fail=0

tmp="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$tmp"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

check() {  # check <description> <0-or-1>
  if [ "$2" = 0 ]; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi
}

git_bin="$(command -v git)"

# stubs/ has make and go; nogo/ has make and git only, so `command -v go` fails
# there whatever the host has installed.
stubs="$tmp/stubs"; nogo="$tmp/nogo"
mkdir -p "$stubs" "$nogo"
cat >"$stubs/make" <<'EOF'
#!/bin/sh
dir=.
[ "$1" = "-C" ] && dir="$2"
printf '%s|%s|%s\n' "$(pwd)" "$*" "$(cd "$dir" && git rev-parse --show-toplevel 2>/dev/null)" >>"$MAKE_LOG"
exit "${MAKE_RC:-0}"
EOF
printf '#!/bin/sh\nexit 0\n' >"$stubs/go"
chmod +x "$stubs/make" "$stubs/go"
cp "$stubs/make" "$nogo/make"
ln -s "$git_bin" "$nogo/git"

# Mutants, one guard removed each.
mut="$tmp/mutants"; mkdir -p "$mut"
sed 's|^    git diff --quiet ORIG_HEAD HEAD -- ":/src/claude-queue" && exit 0$|    :|' \
  "$hook" >"$mut/nodiff"
grep -v '^command -v go ' "$hook" >"$mut/nogo"
grep -v '^unset GIT_DIR ' "$hook" >"$mut/nounset"
grep -v '^\[ -d "\$top/src/claude-queue" \] || exit 0$' "$hook" >"$mut/nosrcdir"
# Range mutants: only the last commit, and the wrong merge parent.
sed 's|git diff --quiet ORIG_HEAD HEAD |git diff --quiet HEAD~1 HEAD |' "$hook" >"$mut/lastcommit"
sed 's|git diff --quiet ORIG_HEAD HEAD |git diff --quiet HEAD^2 HEAD |' "$hook" >"$mut/wrongparent"
chmod +x "$mut"/*
for m in nodiff nogo nounset nosrcdir lastcommit wrongparent; do
  check "mutant '$m' really differs from the hook" \
    "$(if ! cmp -s "$hook" "$mut/$m"; then echo 0; else echo 1; fi)"
done

commit_in() {  # commit_in <repo> <path> <content>
  mkdir -p "$(dirname "$1/$2")"
  echo "$3" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "$3"
}

# new_case <name> <hook> -> echoes "<seed> <work>": a seed repo pushing to a
# bare remote, and a clone of it with <hook> linked as its post-merge.
new_case() {
  local d="$tmp/$1" h="$2"
  mkdir -p "$d"
  git init -q --bare "$d/remote.git"
  git init -q -b main "$d/seed"
  commit_in "$d/seed" src/claude-queue/main.go v1 >/dev/null
  commit_in "$d/seed" docs/readme.md v1 >/dev/null
  git -C "$d/seed" push -q "$d/remote.git" HEAD:refs/heads/main
  git -C "$d/remote.git" symbolic-ref HEAD refs/heads/main
  git -C "$d/seed" remote add origin "$d/remote.git"
  git clone -q "$d/remote.git" "$d/work"
  git -C "$d/work" config pull.rebase false
  ln -s "$h" "$(git -C "$d/work" rev-parse --path-format=absolute --git-path hooks/post-merge)"
  printf '%s %s' "$d/seed" "$d/work"
}

push_change() {  # push_change <seed> <path>
  commit_in "$1" "$2" "change-$RANDOM" >/dev/null
  git -C "$1" push -q origin HEAD:main
}

# pull_in <work> <path-dir> [env...]: git pull with PATH set to exactly
# <path-dir> (the caller prepends :$PATH where it wants the host's tools).
# Leaves the make log at <work>.make.log.
pull_in() {
  local w="$1" p="$2"; shift 2
  env MAKE_LOG="$w.make.log" "$@" PATH="$p" "$git_bin" -C "$w" pull -q --no-edit \
    >"$w.out" 2>"$w.err"
}
calls() { [ -f "$1.make.log" ] && wc -l <"$1.make.log" || echo 0; }

# --- scenarios: each prints the observable it is judged on ------------------

# Upstream touches only docs/: make must not run.
s_docs_only() {
  read -r seed work < <(new_case "docs-$1" "$2")
  push_change "$seed" docs/readme.md
  pull_in "$work" "$stubs:$PATH"
  calls "$work"
}

# Upstream touches src/claude-queue, fast-forward pull: one make call, at the
# checkout's own src/claude-queue, target build, seeing the checkout as top.
s_src_ff() {
  read -r seed work < <(new_case "ff-$1" "$2")
  push_change "$seed" src/claude-queue/main.go
  pull_in "$work" "$stubs:$PATH"
  local line; line="$(cat "$work.make.log" 2>/dev/null)"
  [ "$line" = "$work|-C $work/src/claude-queue build|$work" ] && echo yes || echo "no: $line"
}

# Local commit plus an upstream src change: a real (non-ff) merge.
s_src_merge() {
  read -r seed work < <(new_case "merge-$1" "$2")
  commit_in "$work" local.txt local >/dev/null
  push_change "$seed" src/claude-queue/main.go
  pull_in "$work" "$stubs:$PATH"
  local parents; parents="$(git -C "$work" rev-list --parents -n1 HEAD | wc -w)"
  [ "$parents" = 3 ] && [ "$(calls "$work")" = 1 ] && echo yes || echo "no: parents=$parents"
}

# src change but no go on PATH: make must not run, and stderr says the binary
# was not rebuilt (prints 0 only when both hold).
s_no_go() {
  read -r seed work < <(new_case "nogo-$1" "$2")
  push_change "$seed" src/claude-queue/main.go
  pull_in "$work" "$nogo"
  local n; n="$(calls "$work")"
  if [ "$n" = 0 ] && grep -qF "go not on PATH; $work/bin/claude-queue was not rebuilt. Run: make -C $work/src/claude-queue build" "$work.err"
  then echo 0; else echo "no: calls=$n"; fi
}

# The merge deletes src/claude-queue: the diff is non-empty but there is
# nothing to build, so make must not run.
s_src_removed() {
  read -r seed work < <(new_case "rm-$1" "$2")
  git -C "$seed" rm -q -r src/claude-queue
  git -C "$seed" commit -q -m rm-src
  git -C "$seed" push -q origin HEAD:main
  pull_in "$work" "$stubs:$PATH"
  calls "$work"
}

# Upstream pushes a src commit then a docs commit; one ff pull covers both.
# The range is ORIG_HEAD..HEAD, so the earlier src commit must still count.
s_range_ff() {
  read -r seed work < <(new_case "range-$1" "$2")
  push_change "$seed" src/claude-queue/main.go
  push_change "$seed" docs/readme.md
  pull_in "$work" "$stubs:$PATH"
  calls "$work"
}

# The local commit touches src, upstream only docs: a non-ff merge whose own
# side changed src must not trigger a build (only what the merge brought in).
s_local_src_upstream_docs() {
  read -r seed work < <(new_case "localsrc-$1" "$2")
  commit_in "$work" src/claude-queue/local.go local >/dev/null
  push_change "$seed" docs/readme.md
  pull_in "$work" "$stubs:$PATH"
  local parents; parents="$(git -C "$work" rev-list --parents -n1 HEAD | wc -w)"
  [ "$parents" = 3 ] && echo "$(calls "$work")" || echo "no: parents=$parents"
}

# A merge inside a linked worktree: git exports GIT_DIR to the hook there, and
# the Makefile must still see the worktree itself as the top level.
s_worktree() {
  read -r seed work < <(new_case "wt-$1" "$2")
  push_change "$seed" src/claude-queue/main.go
  git -C "$work" fetch -q origin
  local wt="$tmp/wt-$1/linked"
  git -C "$work" worktree add -q -b side "$wt" main
  env MAKE_LOG="$wt.make.log" PATH="$stubs:$PATH" "$git_bin" -C "$wt" merge -q --no-edit origin/main \
    >/dev/null 2>&1
  local top; top="$(cut -d'|' -f3 "$wt.make.log" 2>/dev/null)"
  [ "$top" = "$wt" ] && echo yes || echo "no: top=$top"
}

# --- the hook under test -----------------------------------------------------
check "docs-only pull does not call make" \
  "$(if [ "$(s_docs_only real "$hook")" = 0 ]; then echo 0; else echo 1; fi)"
r="$(s_src_ff real "$hook")"
check "fast-forward pull with a src/claude-queue change runs make build there ($r)" \
  "$(if [ "$r" = yes ]; then echo 0; else echo 1; fi)"
r="$(s_src_merge real "$hook")"
check "non-ff merge pull with a src/claude-queue change runs make once ($r)" \
  "$(if [ "$r" = yes ]; then echo 0; else echo 1; fi)"
check "without go on PATH, make is not called and stderr says the binary was not rebuilt" \
  "$(if [ "$(s_no_go real "$hook")" = 0 ]; then echo 0; else echo 1; fi)"
check "a merge that deletes src/claude-queue does not call make" \
  "$(if [ "$(s_src_removed real "$hook")" = 0 ]; then echo 0; else echo 1; fi)"
check "an ff pull of a src commit then a docs commit calls make once" \
  "$(if [ "$(s_range_ff real "$hook")" = 1 ]; then echo 0; else echo 1; fi)"
check "a non-ff merge where only the local side touched src does not call make" \
  "$(if [ "$(s_local_src_upstream_docs real "$hook")" = 0 ]; then echo 0; else echo 1; fi)"
r="$(s_worktree real "$hook")"
check "in a linked worktree the build sees the worktree as top level ($r)" \
  "$(if [ "$r" = yes ]; then echo 0; else echo 1; fi)"

# A failed build: the pull still lands, and stderr says the binary is stale.
read -r seed work < <(new_case fail "$hook")
before="$(git -C "$work" rev-parse HEAD)"
push_change "$seed" src/claude-queue/main.go
pull_in "$work" "$stubs:$PATH" MAKE_RC=2
check "a failed build leaves the merge in place and reports the build failure on stderr" \
  "$(if [ "$(git -C "$work" rev-parse HEAD)" != "$before" ] \
       && [ "$(git -C "$work" rev-parse HEAD)" = "$(git -C "$seed" rev-parse HEAD)" ] \
       && grep -qF 'build failed' "$work.err" \
       && grep -qF "$work/bin/claude-queue was not rebuilt (old or missing)" "$work.err" \
       && grep -qF "make -C $work/src/claude-queue build" "$work.err"
     then echo 0; else echo 1; fi)"

# git ignores post-merge's exit status, so the status is only visible when the
# hook is run directly. After the pull above, ORIG_HEAD and the src diff are in
# place: a failing make must make the hook exit non-zero.
(cd "$work" && env MAKE_LOG="$work.direct.make.log" MAKE_RC=2 PATH="$stubs:$PATH" sh "$hook" >/dev/null 2>&1)
rc=$?
check "a failed build makes the hook itself exit non-zero (rc=$rc)" \
  "$(if [ "$rc" != 0 ] && [ "$(calls "$work.direct")" = 1 ]; then echo 0; else echo 1; fi)"

# No ORIG_HEAD: the hook says so and rebuilds anyway.
git -C "$work" update-ref -d ORIG_HEAD
(cd "$work" && env MAKE_LOG="$work.noorig.make.log" PATH="$stubs:$PATH" sh "$hook" >/dev/null 2>"$work.noorig.err")
check "without ORIG_HEAD the hook reports it and still calls make" \
  "$(if grep -qF 'ORIG_HEAD not found' "$work.noorig.err" && [ "$(calls "$work.noorig")" = 1 ]
     then echo 0; else echo 1; fi)"

# --- discrimination: each mutant must fail the scenario its guard covers ----
check "control: without the diff check, a docs-only pull calls make" \
  "$(if [ "$(s_docs_only nodiff "$mut/nodiff")" != 0 ]; then echo 0; else echo 1; fi)"
check "control: without the go check, make is called with no go on PATH" \
  "$(if [ "$(s_no_go nogo "$mut/nogo")" != 0 ]; then echo 0; else echo 1; fi)"
check "control: without the src dir check, a merge deleting it calls make" \
  "$(if [ "$(s_src_removed nosrcdir "$mut/nosrcdir")" != 0 ]; then echo 0; else echo 1; fi)"
check "control: diffing only the last commit misses the earlier src commit" \
  "$(if [ "$(s_range_ff lastcommit "$mut/lastcommit")" != 1 ]; then echo 0; else echo 1; fi)"
check "control: diffing against the wrong merge parent calls make for a local-only src change" \
  "$(if [ "$(s_local_src_upstream_docs wrongparent "$mut/wrongparent")" != 0 ]; then echo 0; else echo 1; fi)"
check "control: without unsetting GIT_DIR, the worktree build sees the wrong top" \
  "$(if [ "$(s_worktree nounset "$mut/nounset")" = "no: top=$tmp/wt-nounset/linked/src/claude-queue" ]
     then echo 0; else echo 1; fi)"

exit "$fail"
