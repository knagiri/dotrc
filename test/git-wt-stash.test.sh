#!/usr/bin/env bash
# Functional tests for bin/git-wt-stash. Every fixture repo is made with
# `git init` under a mktemp dir, so nothing here touches a real (shared) stash.
#
# The races are staged with a git stub put in front of PATH: it runs the real
# git, and lets an "intruder" push an entry the way a concurrent session would
# at one of three points:
#   RACE_ON=push    right after the wrapper's `stash push` returned (so before
#                   its tag lookup), from another worktree;
#   RACE_ON=store   just before the wrapper's `update-ref --create-reflog`, i.e.
#                   before its pre-drop check of refs/stash, from another
#                   worktree;
#   RACE_ON=translate  not a race: `stash drop` prints its result in another
#                   language ("... gelöscht"), as under a translated locale;
#   RACE_ON=recheck at the second `rev-parse refs/worktree/stash@{N}` of a
#                   pop/drop (the re-resolve before the delete), from the same
#                   worktree.
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
# The diffstats differ per entry (A: f | 4, B: f | 2, C: f | 3) so show can be
# told apart by which entry it describes.
printf 'a1\na2\na3\n' >"$d/w1/f"; ws "$d/w1" push -m A >/dev/null
echo b >"$d/w1/f"; ws "$d/w1" push -m B >/dev/null
printf 'c\nc2\n' >"$d/w1/f"; ws "$d/w1" push -m C >/dev/null
want=$'stash@{0}: On b1: C\nstash@{1}: On b1: B\nstash@{2}: On b1: A'
check "list numbers entries newest first" test "$(ws "$d/w1" list)" = "$want"
check "show 2 describes A's change" bash -c "(cd '$d/w1' && '$src' show 2) | grep -q 'f | 4'"
check "show 1 describes B's change" bash -c "(cd '$d/w1' && '$src' show 1) | grep -q 'f | 2'"
check "show describes C's change" bash -c "(cd '$d/w1' && '$src' show) | grep -q 'f | 3'"
check "show 08 is read as 8, not an octal error (no such entry: 2)" bash -c "cd '$d/w1' && out=\$('$src' show 08 2>&1); rc=\$?; [ \$rc -eq 2 ] && [[ \$out == *'no entry 8'* ]]"
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
            "pop -1" "pop 1 2" "pop x" "show 1234567890" "drop 99999999999999999999" "apply --index" "drop stash@{0}" "clear"; do
  # shellcheck disable=SC2086 # split on purpose: each string is an argv
  (cd "$d/w1" && "$src" $args) >/dev/null 2>&1; rc=$?
  check "rejects '$args' with 2" test "$rc" -eq 2
done
check "a 20-digit index is a usage error, not an overflowed number" bash -c "cd '$d/w1' && out=\$('$src' drop 99999999999999999999 2>&1); [[ \$out == usage:* ]]"
mkdir -p "$tmp/norepo"
(cd "$tmp/norepo" && GIT_CEILING_DIRECTORIES="$tmp" "$src" list) >/dev/null 2>&1; rc=$?
check "list outside a git repo fails instead of reporting no entries" test "$rc" -ne 0
(cd "$d/w1" && "$src" push -m $'two\nlines') >/dev/null 2>&1; rc=$?
check "rejects a multi-line message with 2" test "$rc" -eq 2
check "rejected calls left the entry alone" test "$(n_entries "$d/w1")" -eq 1

# --- git stub (see the header) ---------------------------------------------
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
  store:update-ref:--create-reflog) intrude ;;
  translate:stash:drop) "$real_git" "\$@" | sed 's/^Dropped \(.*\)\$/\1 gelöscht/'; exit "\${PIPESTATUS[0]}" ;;
  recheck:rev-parse:*)
    case "\${!#}" in
      refs/worktree/stash@*)
        n=\$(cat "\$RACE_CNT" 2>/dev/null || echo 0); echo \$((n + 1)) >"\$RACE_CNT"
        if [ "\$n" -eq 1 ]; then
          (cd "\$RACE_DIR" && echo z >>f && RACE_ON= "\$RACE_SRC" push -m intruder) >/dev/null
        fi ;;
    esac ;;
esac
exec "$real_git" "\$@"
STUB
chmod +x "$stub/git"

# --- existing shared entries, other repos' states ---------------------------
d="$tmp/shared"; fixture "$d"
echo s >>"$d/r/f"; git -C "$d/r" stash push -q -m shared
echo w1 >>"$d/w1/f"
ws "$d/w1" push -m mine >/dev/null 2>&1; rc=$?
check "push over an existing shared entry exits 0" test "$rc" -eq 0
check "push leaves the existing shared entry alone" bash -c "[ \$(git -C '$d/r' stash list | wc -l) -eq 1 ] && git -C '$d/r' stash list | grep -q 'shared'"
check "push over an existing shared entry stores ours in w1" test "$(n_entries "$d/w1")" -eq 1
d="$tmp/shared-clean"; fixture "$d"
echo s >>"$d/r/f"; git -C "$d/r" stash push -q -m shared
before="$(git -C "$d/r" rev-parse refs/stash)"
ws "$d/w1" push >/dev/null 2>&1; rc=$?
check "push with no changes over a shared entry exits 0" test "$rc" -eq 0
check "push with no changes does not touch the shared entry" test "$(git -C "$d/r" rev-parse refs/stash)" = "$before"
if has_ref "$d/w1"; then ng "push with no changes over a shared entry stores nothing"; else ok "push with no changes over a shared entry stores nothing"; fi

# --- locale: no git message is parsed -----------------------------------------
d="$tmp/locale"; fixture "$d"
echo x >>"$d/w1/f"
(cd "$d/w1" && LANGUAGE=de LC_ALL=de_DE.UTF-8 LANG=de_DE.UTF-8 "$src" push -m mine) >/dev/null 2>&1; rc=$?
check "push under a German locale exits 0" test "$rc" -eq 0
check "push under a German locale stores the entry" test "$(n_entries "$d/w1")" -eq 1
check "push under a German locale leaves the shared stash empty" test "$(n_shared "$d/r")" -eq 0

# The same, with git's drop message translated by the stub (no locale needed).
d="$tmp/locale-stub"; fixture "$d"
echo x >>"$d/w1/f"
(cd "$d/w1" && PATH="$stub:$PATH" RACE_ON=translate "$src" push -m mine) >/dev/null 2>&1; rc=$?
check "push with a translated drop message exits 0" test "$rc" -eq 0
check "push with a translated drop message empties the shared stash" test "$(n_shared "$d/r")" -eq 0

# --- reflog expiry (git gc) must not eat entries -----------------------------
d="$tmp/gc"; fixture "$d"
echo old >>"$d/w1/f"
old="$(date -d '40 days ago' +%s) +0000"
(cd "$d/w1" && GIT_COMMITTER_DATE="$old" "$src" push -m old) >/dev/null 2>&1
git -C "$d/r" reflog expire --all
check "entry survives reflog expire from the main working tree" test "$(n_entries "$d/w1")" -eq 1
git -C "$d/w1" reflog expire --all
check "entry survives reflog expire from its own worktree" test "$(n_entries "$d/w1")" -eq 1

# --- pop whose apply fails keeps the entry -----------------------------------
d="$tmp/popfail"; fixture "$d"
echo stashed >"$d/w1/f"; ws "$d/w1" push -m mine >/dev/null
echo conflicting >"$d/w1/f"
ws "$d/w1" pop >/dev/null 2>&1; rc=$?
check "pop with a conflicting working tree fails" test "$rc" -ne 0
check "pop that failed to apply keeps the entry" test "$(n_entries "$d/w1")" -eq 1
check "pop that failed to apply keeps the ref" has_ref "$d/w1"

# --- races -------------------------------------------------------------------

# Another push lands between ours and the tag lookup.
d="$tmp/race-push"; fixture "$d"
echo mine >>"$d/w1/f"
err="$(cd "$d/w1" && PATH="$stub:$PATH" RACE_ON=push RACE_DIR="$d/w2" "$src" push -m mine 2>&1 >/dev/null)"; rc=$?
check "push race: exits 1" test "$rc" -eq 1
check "push race: stderr names the entry's commit" bash -c "[[ \$1 == *'commit '* ]]" _ "$err"
if has_ref "$d/w1"; then ng "push race: nothing stored in w1"; else ok "push race: nothing stored in w1"; fi
check "push race: both entries stay in the shared git stash" bash -c "git -C '$d/r' stash list | grep -q 'mine' && git -C '$d/r' stash list | grep -q 'intruder'"

# Our push saves nothing, but another session pushes at the same time: that is
# not our entry, so it is not a race.
d="$tmp/race-empty"; fixture "$d"
(cd "$d/w1" && PATH="$stub:$PATH" RACE_ON=push RACE_DIR="$d/w2" "$src" push -m mine) >/dev/null 2>&1; rc=$?
check "empty push beside another push: exits 0" test "$rc" -eq 0
if has_ref "$d/w1"; then ng "empty push beside another push: nothing stored"; else ok "empty push beside another push: nothing stored"; fi
check "empty push beside another push: the other entry is untouched" bash -c "git -C '$d/r' stash list | grep -q 'intruder'"

# Another push lands after our update-ref's turn, before the pre-drop check.
d="$tmp/race-drop"; fixture "$d"
echo mine >>"$d/w1/f"
(cd "$d/w1" && PATH="$stub:$PATH" RACE_ON=store RACE_DIR="$d/w2" "$src" push -m mine) >/dev/null 2>&1; rc=$?
check "drop race: exits 1" test "$rc" -eq 1
check "drop race: our entry is stored in w1" test "$(ws "$d/w1" list)" = 'stash@{0}: On b1: mine'
check "drop race: the shared stash keeps both entries (nothing dropped)" bash -c "[ \$(git -C '$d/r' stash list | wc -l) -eq 2 ] && git -C '$d/r' stash list | grep -q 'intruder'"

# A push into the same worktree between resolving N and deleting it.
for op in pop drop; do
  d="$tmp/index-race-$op"; fixture "$d"
  echo mine >"$d/w1/f"; ws "$d/w1" push -m mine >/dev/null
  rm -f "$d/cnt"
  (cd "$d/w1" && PATH="$stub:$PATH" RACE_ON=recheck RACE_DIR="$d/w1" RACE_CNT="$d/cnt" RACE_SRC="$src" "$src" "$op") >/dev/null 2>&1; rc=$?
  check "$op race: exits 1" test "$rc" -eq 1
  check "$op race: both entries remain" test "$(n_entries "$d/w1")" -eq 2
  check "$op race: ours is still there" bash -c "cd '$d/w1' && '$src' list | grep -q mine"
done

[ "$fail" -eq 0 ] && echo "all ok" || echo "some FAILED"
exit "$fail"
