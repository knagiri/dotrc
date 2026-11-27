#!/usr/bin/env bash
# Functional tests for bin/git-wt-stash. Every fixture repo is made with
# `git init` under a mktemp dir, so nothing here touches a real (shared) stash.
#
# The push race is staged with a git stub put in front of PATH: it runs the
# real git, and on the wrapper's `stash push` (RACE_ON=push) or `stash drop`
# (RACE_ON=drop) it first lets an "intruder" push an entry from another
# worktree, the way a concurrent session would.
#
# $GIT_WT_STASH_BIN overrides the script under test, which is how the
# discrimination check is run (point it at a mutated copy).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
src="${GIT_WT_STASH_BIN:-$here/../bin/git-wt-stash}"
fail=0

tmp="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$tmp"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

ok() { echo "ok: $1"; }
ng() { echo "FAIL: $1"; fail=1; }
check() { # <name> <command...>: passes when the command succeeds
  local name="$1"; shift
  if "$@"; then ok "$name"; else ng "$name"; fi
}

# fixture <dir>: main working tree r (main) with linked worktrees w1 (b1), w2 (b2)
fixture() {
  local d="$1"
  mkdir -p "$d"
  git init -q -b main "$d/r"
  echo base >"$d/r/f"
  git -C "$d/r" add f
  git -C "$d/r" commit -q -m init
  git -C "$d/r" worktree add -q -b b1 "$d/w1"
  git -C "$d/r" worktree add -q -b b2 "$d/w2"
}

ws() { # <dir> <args...>: run the wrapper in <dir>
  local d="$1"; shift
  (cd "$d" && "$src" "$@")
}

n_entries() { ws "$1" list | wc -l; }
n_shared() { git -C "$1" stash list | wc -l; }
has_ref() { git -C "$1" rev-parse -q --verify refs/worktree/stash >/dev/null; }

# --- isolation between worktrees -------------------------------------------
d="$tmp/iso"; fixture "$d"
echo w1-change >>"$d/w1/f"
ws "$d/w1" push -m mine >/dev/null
check "push leaves the working tree clean" test -z "$(git -C "$d/w1" status --porcelain)"
check "push: one entry in w1" test "$(n_entries "$d/w1")" -eq 1
check "push: list shows the message" bash -c "[[ \"\$(cd '$d/w1' && '$src' list)\" == 'stash@{0}: On b1: mine' ]]"
check "push: nothing left in the shared git stash" test "$(n_shared "$d/r")" -eq 0
check "w2 does not see w1's entry" test "$(n_entries "$d/w2")" -eq 0
check "the main working tree does not see w1's entry" test "$(n_entries "$d/r")" -eq 0
ws "$d/w2" pop >/dev/null 2>&1; rc=$?
check "pop in w2 fails with 2 (nothing to take)" test "$rc" -eq 2
check "pop in w2 leaves w2 untouched" test -z "$(git -C "$d/w2" status --porcelain)"
check "w1's entry is still there after w2's pop" test "$(n_entries "$d/w1")" -eq 1
echo main-change >>"$d/r/f"
ws "$d/r" push -m from-main >/dev/null
check "main and w1 keep separate stashes" test "$(n_entries "$d/r")" -eq 1 -a "$(n_entries "$d/w1")" -eq 1
ws "$d/w1" pop >/dev/null 2>&1; rc=$?
check "pop in w1 returns its own change" bash -c "[ $rc -eq 0 ] && grep -qx w1-change '$d/w1/f' && ! grep -qx main-change '$d/w1/f'"
check "main's entry survives w1's pop" test "$(n_entries "$d/r")" -eq 1

# --- -u brings untracked files back; last drop removes the ref -------------
d="$tmp/untracked"; fixture "$d"
echo tracked >>"$d/w1/f"
echo new >"$d/w1/u"
ws "$d/w1" push -u >/dev/null
check "push -u stashes the untracked file too" test ! -e "$d/w1/u"
check "default message is WIP" bash -c "[[ \"\$(cd '$d/w1' && '$src' list)\" == 'stash@{0}: On b1: WIP' ]]"
ws "$d/w1" pop >/dev/null
check "pop restores tracked and untracked changes" bash -c "[ \"\$(git -C '$d/w1' status --porcelain)\" = \"\$(printf ' M f\n?? u')\" ]"
check "pop of the last entry removes refs/worktree/stash" bash -c "! git -C '$d/w1' rev-parse -q --verify refs/worktree/stash >/dev/null"
check "list with no entries is empty and exits 0" bash -c "out=\$(cd '$d/w1' && '$src' list) && [ -z \"\$out\" ]"
git -C "$d/w1" checkout -q f; rm -f "$d/w1/u"

echo x >>"$d/w1/f"
ws "$d/w1" push >/dev/null
ws "$d/w1" drop >/dev/null
if has_ref "$d/w1"; then ng "drop of the last entry removes refs/worktree/stash"; else ok "drop of the last entry removes refs/worktree/stash"; fi
check "drop discards the change" test -z "$(git -C "$d/w1" status --porcelain)"

# --- several entries, by index ----------------------------------------------
d="$tmp/multi"; fixture "$d"
echo a >"$d/w1/f"; ws "$d/w1" push -m A >/dev/null
echo b >"$d/w1/f"; ws "$d/w1" push -m B >/dev/null
echo c >"$d/w1/f"; ws "$d/w1" push -m C >/dev/null
want=$'stash@{0}: On b1: C\nstash@{1}: On b1: B\nstash@{2}: On b1: A'
check "list numbers entries newest first" test "$(ws "$d/w1" list)" = "$want"
check "show 2 describes A's change" bash -c "(cd '$d/w1' && '$src' show 2) | grep -q 'f | 2'"
ws "$d/w1" apply 1 >/dev/null
check "apply 1 restores B and keeps it" bash -c "grep -qx b '$d/w1/f' && [ \"\$(cd '$d/w1' && '$src' list | wc -l)\" -eq 3 ]"
git -C "$d/w1" checkout -q f
ws "$d/w1" pop 1 >/dev/null
check "pop 1 restores B" grep -qx b "$d/w1/f"
check "pop 1 removes only B" test "$(ws "$d/w1" list)" = $'stash@{0}: On b1: C\nstash@{1}: On b1: A'
git -C "$d/w1" checkout -q f
ws "$d/w1" drop 1 >/dev/null
check "drop 1 removes A and keeps C" test "$(ws "$d/w1" list)" = 'stash@{0}: On b1: C'
check "the ref stays while entries remain" has_ref "$d/w1"
ws "$d/w1" pop >/dev/null
check "pop 0 restores C" grep -qx c "$d/w1/f"
git -C "$d/w1" checkout -q f
ws "$d/w1" show 0 >/dev/null 2>&1; rc=$?
check "show on an empty stash exits 2" test "$rc" -eq 2

# --- nothing to save --------------------------------------------------------
d="$tmp/clean"; fixture "$d"
ws "$d/w1" push >/dev/null 2>&1; rc=$?
check "push with no changes exits 0" test "$rc" -eq 0
if has_ref "$d/w1"; then ng "push with no changes stores nothing"; else ok "push with no changes stores nothing"; fi

# --- usage errors -----------------------------------------------------------
d="$tmp/usage"; fixture "$d"
echo x >>"$d/w1/f"; ws "$d/w1" push >/dev/null
for args in "" "frob" "push --keep-index" "push -m" "push -p" "list -v" "show -p" \
            "pop -1" "pop 1 2" "pop x" "apply --index" "drop stash@{0}" "clear"; do
  # shellcheck disable=SC2086 # split on purpose: each string is an argv
  (cd "$d/w1" && "$src" $args) >/dev/null 2>&1; rc=$?
  check "rejects '$args' with 2" test "$rc" -eq 2
done
(cd "$d/w1" && "$src" push -m $'two\nlines') >/dev/null 2>&1; rc=$?
check "rejects a multi-line message with 2" test "$rc" -eq 2
check "rejected calls left the entry alone" test "$(n_entries "$d/w1")" -eq 1

# --- push races -------------------------------------------------------------
real_git="$(command -v git)"
stub="$tmp/stub"; mkdir -p "$stub"
cat >"$stub/git" <<STUB
#!/usr/bin/env bash
intrude() {
  echo intruder >>"\$RACE_DIR/f"
  "$real_git" -C "\$RACE_DIR" stash push -q -m intruder
}
case "\${RACE_ON:-}:\$1:\${2:-}" in
  push:stash:push) "$real_git" "\$@" || exit; intrude; exit 0 ;;
  drop:stash:drop) intrude ;;
esac
exec "$real_git" "\$@"
STUB
chmod +x "$stub/git"

# Another push lands between ours and the subject check.
d="$tmp/race-push"; fixture "$d"
echo mine >>"$d/w1/f"
(cd "$d/w1" && PATH="$stub:$PATH" RACE_ON=push RACE_DIR="$d/w2" "$src" push -m mine) >/dev/null 2>&1; rc=$?
check "push race: exits 1" test "$rc" -eq 1
if has_ref "$d/w1"; then ng "push race: nothing stored in w1"; else ok "push race: nothing stored in w1"; fi
check "push race: both entries stay in the shared git stash" bash -c "git -C '$d/r' stash list | grep -q 'mine' && git -C '$d/r' stash list | grep -q 'intruder'"

# Another push lands between the subject check and the drop.
d="$tmp/race-drop"; fixture "$d"
echo mine >>"$d/w1/f"
(cd "$d/w1" && PATH="$stub:$PATH" RACE_ON=drop RACE_DIR="$d/w2" "$src" push -m mine) >/dev/null 2>&1; rc=$?
check "drop race: exits 1" test "$rc" -eq 1
check "drop race: our entry is stored in w1" test "$(ws "$d/w1" list)" = 'stash@{0}: On b1: mine'
check "drop race: the intruder's entry is back in the shared git stash" bash -c "git -C '$d/r' stash list | grep -q 'intruder'"

[ "$fail" -eq 0 ] && echo "all ok" || echo "some FAILED"
exit "$fail"
