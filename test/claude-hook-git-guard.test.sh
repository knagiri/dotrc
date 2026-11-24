#!/usr/bin/env bash
# Functional tests for bin/claude-hook-git-guard. Every fixture repo is made
# with `git init` under a mktemp dir, so the stash operations here never touch
# a real (shared) stash. Each case feeds a PreToolUse hook input on stdin and
# checks the permissionDecision that comes back ("none" when the hook prints
# nothing).
#
# $CLAUDE_HOOK_GIT_GUARD_BIN overrides the script under test, which is how the
# discrimination check is run (point it at a mutated copy).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
src="${CLAUDE_HOOK_GIT_GUARD_BIN:-$here/../bin/claude-hook-git-guard}"
fail=0

tmp="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$tmp"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# run_hook <cwd> <command> -> prints the decision (or "none")
run_hook() {
  local out
  out="$(jq -n --arg c "$2" --arg d "$1" \
    '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' \
    | "$src")"
  if [ -z "$out" ]; then echo none; else jq -r '.hookSpecificOutput.permissionDecision' <<<"$out"; fi
}

# expect <name> <want> <cwd> <command>
expect() {
  local got
  got="$(run_hook "$3" "$4")"
  if [ "$got" = "$2" ]; then echo "ok: $1"; else echo "FAIL: $1 (want $2, got $got)"; fail=1; fi
}

commit_in() { # <repo> <file> <msg>
  echo "$3" >>"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "$3"
}

# clone_with_remote <dir> <default-branch> -> a clone of a bare remote whose
# HEAD is <default-branch>, with one commit; origin/HEAD is set by the clone.
clone_with_remote() {
  local d="$1" defb="$2"
  mkdir -p "$d"
  git init -q -b "$defb" "$d/seed"
  commit_in "$d/seed" init.txt init
  git init -q --bare -b "$defb" "$d/remote.git"
  git -C "$d/seed" push -q "$d/remote.git" "HEAD:refs/heads/$defb"
  git clone -q "$d/remote.git" "$d/work"
}

# ============================== git commit (#182) ==============================
clone_with_remote "$tmp/c1" main
main="$tmp/c1/work"
git -C "$main" worktree add -q -b feat "$tmp/c1/wt"
mkdir -p "$tmp/elsewhere"

expect "commit: main working tree on main -> ask" ask "$main" "git commit -m x"
expect "commit: git -C <main> from another dir -> ask" ask "$tmp/elsewhere" "git -C $main commit -m x"
expect "commit: git -C relative path -> ask" ask "$tmp/c1" "git -C work commit -m x"
expect "commit: compound add && commit -> ask" ask "$main" "git add . && git commit -m x"
expect "commit: global opts before subcommand -> ask" ask "$main" "git -c commit.gpgsign=false --no-pager commit -m x"
expect "commit: linked worktree -> none" none "$tmp/c1/wt" "git commit -m x"
expect "commit: git -C <linked wt> from main -> none" none "$main" "git -C $tmp/c1/wt commit -m x"
expect "commit: log --grep commit -> none" none "$main" "git log --grep commit"
expect "commit: non-git command -> none" none "$main" "ls -la"

clone_with_remote "$tmp/c2" main
git -C "$tmp/c2/work" checkout -q -b feature
expect "commit: feature branch in main working tree -> none" none "$tmp/c2/work" "git commit -m x"

mkdir -p "$tmp/c3"
git init -q -b main "$tmp/c3/r"
commit_in "$tmp/c3/r" a.txt a
expect "commit: no remote -> none" none "$tmp/c3/r" "git commit -m x"

mkdir -p "$tmp/c4"
git init -q -b main "$tmp/c4/r"
git -C "$tmp/c4/r" remote add origin "$tmp/c1/remote.git"
expect "commit: zero commits -> none" none "$tmp/c4/r" "git commit -m x"

# origin/HEAD names the integration branch: here it is trunk, not main.
clone_with_remote "$tmp/c5" trunk
expect "commit: on origin/HEAD's branch (trunk) -> ask" ask "$tmp/c5/work" "git commit -m x"
git -C "$tmp/c5/work" checkout -q -b main
expect "commit: on main while origin/HEAD is trunk -> none" none "$tmp/c5/work" "git commit -m x"

# No origin/HEAD at all: fall back to main.
mkdir -p "$tmp/c6"
git init -q -b main "$tmp/c6/r"
commit_in "$tmp/c6/r" a.txt a
git -C "$tmp/c6/r" remote add origin "$tmp/c1/remote.git"
expect "commit: origin/HEAD unset, on main -> ask" ask "$tmp/c6/r" "git commit -m x"

# A linked worktree that has the integration branch checked out (the main
# working tree moved off it): only condition 1 excludes it.
clone_with_remote "$tmp/c8" main
git -C "$tmp/c8/work" checkout -q -b elsewhere
git -C "$tmp/c8/work" worktree add -q "$tmp/c8/wt" main
expect "commit: linked worktree on main -> none" none "$tmp/c8/wt" "git commit -m x"

# A submodule: --git-common-dir and --git-dir match, but .git is a file.
mkdir -p "$tmp/c7"
git init -q -b main "$tmp/c7/super"
commit_in "$tmp/c7/super" s.txt s
git -C "$tmp/c7/super" -c protocol.file.allow=always submodule add -q "$tmp/c1/remote.git" sub
git -C "$tmp/c7/super/sub" checkout -q main
expect "commit: submodule on main -> none" none "$tmp/c7/super/sub" "git commit -m x"

# ============================== git stash (#126) ===============================
clone_with_remote "$tmp/s1" main
sm="$tmp/s1/work"                       # on main
git -C "$sm" worktree add -q -b feat "$tmp/s1/wt"
sw="$tmp/s1/wt"                         # on feat
echo m >>"$sm/init.txt"; git -C "$sm" stash push -q -m mine-main
echo f >>"$sw/init.txt"; git -C "$sw" stash push -q -m mine-feat
# Now stash@{0} is feat's entry, stash@{1} is main's.

expect "stash: pop own top entry (feat) -> none" none "$sw" "git stash pop"
expect "stash: pop top entry owned by feat from main -> deny" deny "$sm" "git stash pop"
expect "stash: pop stash@{1} (own) from main -> none" none "$sm" "git stash pop stash@{1}"
expect "stash: pop 1 (numeric, own) from main -> none" none "$sm" "git stash pop 1"
expect "stash: pop 1 (numeric, main's) from feat -> deny" deny "$sw" "git stash pop 1"
expect "stash: pop --index stash@{1} (own) -> none" none "$sm" "git stash pop --index stash@{1}"
expect "stash: pop stash@{1} (main's) from feat -> deny" deny "$sw" "git stash pop stash@{1}"
expect "stash: apply other's top -> deny" deny "$sm" "git stash apply"
expect "stash: apply own stash@{1} -> none" none "$sm" "git stash apply stash@{1}"
expect "stash: apply by sha of other's entry -> deny" deny "$sm" "git stash apply $(git -C "$sm" rev-parse 'stash@{0}')"
expect "stash: drop other's top -> deny" deny "$sm" "git stash drop"
expect "stash: drop own stash@{1} -> none" none "$sm" "git stash drop -q stash@{1}"
expect "stash: branch from other's top -> deny" deny "$sm" "git stash branch nb"
expect "stash: branch from own stash@{1} -> none" none "$sm" "git stash branch nb stash@{1}"
expect "stash: clear with other branch's entries -> deny" deny "$sm" "git stash clear"
expect "stash: push -> none" none "$sm" "git stash push -m x"
expect "stash: bare git stash -> none" none "$sm" "git stash"
expect "stash: -u (implicit push) -> none" none "$sm" "git stash -u"
expect "stash: list -> none" none "$sm" "git stash list"
expect "stash: show -> none" none "$sm" "git stash show -p"
expect "stash: pop missing entry -> none" none "$sm" "git stash pop stash@{9}"
expect "stash: git -C <wt> pop from main (owner matches wt) -> none" none "$sm" "git -C $sw stash pop"
expect "stash: git -C <main> pop from wt -> deny" deny "$sw" "git -C $sm stash pop"
expect "stash: git -c k=v stash pop -> deny" deny "$sm" "git -c core.pager=cat stash pop"
expect "stash: foo && git stash pop -> deny" deny "$sm" "true && git stash pop"
expect "stash: pipe then pop -> deny" deny "$sm" "echo hi | git stash pop"
expect "stash: newline-separated pop -> deny" deny "$sm" $'echo hi\ngit stash pop'
expect "stash: redirections around own pop -> none" none "$sm" "git stash pop stash@{1} 2>&1 >/dev/null | tail -1"
expect "stash: redirect target is not taken as the ref -> deny" deny "$sm" "git stash pop 2>/dev/null"
expect "stash: fd number is not taken as the ref -> deny" deny "$sm" "git stash pop 2>&1"
expect "stash: spaced redirect target is not taken as the ref -> deny" deny "$sm" "git stash pop 2> /dev/null"
expect "stash: deny beats ask in one line" deny "$sm" "git stash pop; git commit -m x"

# Only a git at the start of a part counts.
expect "commit: rg \"git commit\" docs -> none" none "$main" 'rg "git commit" docs'
expect "stash: echo \"git stash pop\" -> none" none "$sm" 'echo "git stash pop"'
expect "stash: git log --grep stash -> none" none "$sm" "git log --grep stash"
expect "stash: echo git stash pop (unquoted) -> none" none "$sm" "echo git stash pop"

# Quoted text is not read, so a commit message line reading `git stash pop`
# is seen. That is accepted: the stash check still asks git who owns the entry.
expect "stash: 'git stash pop' in a commit message, own top entry -> none" none "$sw" $'git commit -m "x\ngit stash pop\n"'
expect "stash: 'git stash pop' in a commit message, other's top entry -> deny" deny "$sm" $'git commit -m "x\ngit stash pop\n"'

# Entries pushed without -m ("WIP on <branch>: ...").
clone_with_remote "$tmp/s5" main
wip_m="$tmp/s5/work"
git -C "$wip_m" worktree add -q -b wipb "$tmp/s5/wt"
echo a >>"$wip_m/init.txt"; git -C "$wip_m" stash -q
expect "stash: WIP-on entry, own -> none" none "$wip_m" "git stash pop"
expect "stash: WIP-on entry, other -> deny" deny "$tmp/s5/wt" "git stash pop"

# Env assignments and wrappers before git.
expect "stash: env assignment before git -> deny" deny "$sm" "GIT_PAGER=cat git stash pop"
expect "commit: env assignment before git -> ask" ask "$main" "FOO=1 git commit -m x"
expect "stash: timeout wrapper -> deny" deny "$sm" "timeout 30 git stash pop"
expect "stash: timeout -k wrapper -> deny" deny "$sm" "timeout -k 5 30 git stash pop"
expect "stash: nice -n wrapper -> deny" deny "$sm" "nice -n 10 git stash pop"
expect "stash: nice -10 wrapper -> deny" deny "$sm" "nice -10 git stash pop"
expect "stash: nohup wrapper -> deny" deny "$sm" "nohup git stash pop"
expect "stash: stdbuf wrapper -> deny" deny "$sm" "stdbuf -oL git stash pop"
expect "stash: time wrapper -> deny" deny "$sm" "time git stash pop"
expect "stash: command wrapper -> deny" deny "$sm" "command git stash pop"
expect "stash: env wrapper -> deny" deny "$sm" "env X=1 git stash pop"
expect "stash: env -u wrapper -> deny" deny "$sm" "env -u X git stash pop"
expect "stash: xargs wrapper -> deny" deny "$sm" "echo x | xargs -n 1 git stash pop"
expect "stash: wrapper around own pop -> none" none "$sw" "timeout 30 git stash pop"
expect "stash: wrapped non-git command -> none" none "$sm" "timeout 30 ls"

# deny wins even when the ask comes first.
expect "stash: commit then pop -> deny" deny "$sm" "git commit -m x; git stash pop"

# -C values apply in order, each relative to the previous dir.
clone_with_remote "$tmp/s6" main
m6="$tmp/s6/work"
git -C "$m6" worktree add -q -b feat6 "$tmp/s6/wt"
w6="$tmp/s6/wt"
echo a >>"$m6/init.txt"; git -C "$m6" stash push -q -m m6-entry
expect "stash: -C given twice resolves both -> deny" deny "$tmp" "git -C $tmp/s6 -C wt stash pop"
expect "stash: -C given twice, own entry -> none" none "$tmp" "git -C $tmp/s6 -C work stash pop"
expect "stash: -C relative to cwd, own entry -> none" none "$tmp/s6" "git -C work stash pop"
expect "stash: quoted literal -C path -> none" none "$w6" "git -C \"$m6\" stash pop"
# cd is not followed: the cwd stays the target dir.
expect "stash: cd <own dir> && pop from another branch's dir -> deny" deny "$w6" "cd $m6 && git stash pop"

# A target dir that cannot be resolved fails closed.
expect "stash: -C \"\$PWD\" -> deny" deny "$m6" 'git -C "$PWD" stash pop'
expect "stash: -C \$(pwd) -> deny" deny "$m6" 'git -C $(pwd) stash pop'
expect "stash: -C missing dir -> deny" deny "$m6" "git -C $tmp/nonexistent stash pop"
expect "stash: unresolved dir, push -> none" none "$m6" 'git -C "$PWD" stash push -m x'
expect "commit: unresolved -C dir -> none" none "$tmp/elsewhere" 'git -C "$PWD" commit -m x'

# Branch names that collide with a tag name.
clone_with_remote "$tmp/s7" main
git -C "$tmp/s7/work" worktree add -q -b feat7 "$tmp/s7/wt"
git -C "$tmp/s7/work" tag feat7 2>/dev/null
echo a >>"$tmp/s7/wt/init.txt"; git -C "$tmp/s7/wt" stash push -q -m own
expect "stash: branch with a same-named tag, own entry -> none" none "$tmp/s7/wt" "git stash pop"
clone_with_remote "$tmp/s8" main
git -C "$tmp/s8/work" tag main 2>/dev/null
expect "commit: tag named like the integration branch -> ask" ask "$tmp/s8/work" "git commit -m x"

# Not stash-like / path forms / options with an argument.
expect "stash: apply HEAD (not a stash entry) -> none" none "$sm" "git stash apply HEAD"
expect "stash: /usr/bin/git -> deny" deny "$sm" "/usr/bin/git stash pop"
expect "stash: --work-tree <dir> skipped -> deny" deny "$sm" "git --work-tree . stash pop"

# cwd missing from the hook input: falls back to the process cwd.
out="$(cd "$sm" && jq -n --arg c "git stash pop" '{tool_name:"Bash",tool_input:{command:$c}}' | "$src")"
if [ -n "$out" ]; then echo "ok: stash: no cwd in input falls back to \$PWD"; else echo "FAIL: stash: no cwd fallback"; fail=1; fi

# Typical commit heredoc.
expect "commit: heredoc message via \$(cat <<EOF) -> ask" ask "$main" $'git commit -m "$(cat <<\'EOF\'\nfix thing\nEOF\n)"'

# clear with only own entries / with none.
clone_with_remote "$tmp/s2" main
echo a >>"$tmp/s2/work/init.txt"; git -C "$tmp/s2/work" stash push -q -m own
expect "stash: clear with only own entries -> none" none "$tmp/s2/work" "git stash clear"
clone_with_remote "$tmp/s3" main
expect "stash: clear with no entries -> none" none "$tmp/s3/work" "git stash clear"

# Detached HEAD: the current HEAD, or the entry's.
clone_with_remote "$tmp/s4" main
d4="$tmp/s4/work"
echo a >>"$d4/init.txt"; git -C "$d4" stash push -q -m own
git -C "$d4" checkout -q --detach
expect "stash: pop while detached -> deny" deny "$d4" "git stash pop"
expect "stash: clear while detached -> deny" deny "$d4" "git stash clear"
git -C "$d4" stash drop -q
echo b >>"$d4/init.txt"; git -C "$d4" stash push -q -m detached-entry
expect "stash: pop a detached entry while detached -> deny" deny "$d4" "git stash pop"
git -C "$d4" checkout -q main
expect "stash: pop an entry pushed on a detached HEAD -> deny" deny "$d4" "git stash pop"
expect "stash: clear with a detached entry -> deny" deny "$d4" "git stash clear"

# The reason names the owner and the way forward.
reason="$(jq -n --arg c "git stash pop" --arg d "$sm" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
  | "$src" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
case "$reason" in
  *"'feat'"*'stash@{N}'*"他 branch の entry は明示しても止まる"*) echo "ok: stash: deny reason names the owner and stash@{N}" ;;
  *) echo "FAIL: stash: deny reason: $reason"; fail=1 ;;
esac

# The detached-HEAD hint must not send the agent to stash@{N}, which is still denied.
reason="$(jq -n --arg c "git stash pop" --arg d "$d4" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
  | "$src" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
case "$reason" in
  *"branch を checkout してから撃つ"*) echo "ok: stash: detached deny hint says to check out a branch" ;;
  *) echo "FAIL: stash: detached hint: $reason"; fail=1 ;;
esac

# The output carries the event name Claude Code expects.
ev="$(jq -n --arg c "git stash pop" --arg d "$sm" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
  | "$src" | jq -r '.hookSpecificOutput.hookEventName')"
if [ "$ev" = PreToolUse ]; then echo "ok: output hookEventName is PreToolUse"; else echo "FAIL: hookEventName: $ev"; fail=1; fi

# Not a Bash tool call -> nothing.
out="$(jq -n --arg d "$sm" '{tool_name:"Edit",tool_input:{command:"git stash pop"},cwd:$d}' | "$src")"
if [ -z "$out" ]; then echo "ok: non-Bash tool -> none"; else echo "FAIL: non-Bash tool printed $out"; fail=1; fi

exit "$fail"
