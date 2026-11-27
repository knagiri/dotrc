#!/usr/bin/env bash
# Functional tests for bin/git-wt-stash. Every fixture repo is made with
# `git init` under a mktemp dir, so nothing here touches a real (shared) stash.
#
# Races and failures are staged with a git stub put in front of PATH: it runs
# the real git, except as RACE_ON says. Races (an "intruder" pushes the way a
# concurrent session would):
#   push       right after the wrapper's `stash push` returned (so before its
#              tag lookup), from another worktree;
#   store      just before the wrapper's `update-ref --create-reflog`, i.e.
#              before its pre-drop check of refs/stash, from another worktree;
#   recheck    at the second `rev-parse refs/worktree/stash@{N}` of a pop/drop
#              (the re-resolve before the delete), from the same worktree;
#   lastdrop   just before the `update-ref -d` that removes the emptied
#              refs/worktree/stash, from the same worktree.
# Other conditions:
#   translate  `stash drop` succeeds and prints its result in another language
#              ("... gelöscht"), as under a translated locale;
#   vanish     the entry just pushed is dropped again by "someone else";
#   failstore  `update-ref --create-reflog` fails;  faildrop  `stash drop` fails;
#   failread   every reflog read of refs/worktree/stash fails;
#   failread2  the second one does;  failstashread  reads of refs/stash fail.
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
check "push: list shows the message" bash -c "[[ \"\$(cd '$d/w1' && '$src' list)\" == 'refs/worktree/stash@{0}: On b1: mine' ]]"
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
check "default message is WIP" bash -c "[[ \"\$(cd '$d/w1' && '$src' list)\" == 'refs/worktree/stash@{0}: On b1: WIP' ]]"
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
want=$'refs/worktree/stash@{0}: On b1: C\nrefs/worktree/stash@{1}: On b1: B\nrefs/worktree/stash@{2}: On b1: A'
check "list numbers entries newest first" test "$(ws "$d/w1" list)" = "$want"
check "show 2 describes A's change" bash -c "(cd '$d/w1' && '$src' show 2) | grep -q 'f | 4'"
check "show 1 describes B's change" bash -c "(cd '$d/w1' && '$src' show 1) | grep -q 'f | 2'"
check "show describes C's change" bash -c "(cd '$d/w1' && '$src' show) | grep -q 'f | 3'"
check "show 08 is read as 8 (no such entry, exit 2), not an octal error" bash -c "cd '$d/w1' && out=\$('$src' show 08 2>&1); rc=\$?; [ \$rc -eq 2 ] && [[ \$out == *'no entry 8'* ]]"
ws "$d/w1" apply 1 >/dev/null
check "apply 1 restores B and keeps it" bash -c "grep -qx b '$d/w1/f' && [ \"\$(cd '$d/w1' && '$src' list | wc -l)\" -eq 3 ]"
git -C "$d/w1" checkout -q f
ws "$d/w1" pop 1 >/dev/null
check "pop 1 restores B" grep -qx b "$d/w1/f"
check "pop 1 removes only B" test "$(ws "$d/w1" list)" = $'refs/worktree/stash@{0}: On b1: C\nrefs/worktree/stash@{1}: On b1: A'
git -C "$d/w1" checkout -q f
ws "$d/w1" drop 1 >/dev/null
check "drop 1 removes A and keeps C" test "$(ws "$d/w1" list)" = 'refs/worktree/stash@{0}: On b1: C'
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
  translate:stash:drop) "$real_git" "\$@" || exit; echo "stash@{0} (0000000000000000000000000000000000000000) gelöscht"; exit 0 ;;
  vanish:stash:push) "$real_git" "\$@" || exit; "$real_git" stash drop -q; exit 0 ;;
  failstore:update-ref:--create-reflog) echo "stub: update-ref failed" >&2; exit 1 ;;
  faildrop:stash:drop) echo "stub: stash drop failed" >&2; exit 1 ;;
  failread:reflog:show) echo "stub: reflog read failed" >&2; exit 1 ;;
  failstashread:reflog:show)
    case "\$*" in *refs/stash*) echo "stub: reflog read failed" >&2; exit 1 ;; esac ;;
  failread2:reflog:show)
    n=\$(cat "\$RACE_CNT" 2>/dev/null || echo 0); echo \$((n + 1)) >"\$RACE_CNT"
    if [ "\$n" -eq 1 ]; then echo "stub: reflog read failed" >&2; exit 1; fi ;;
  lastdrop:update-ref:-d)
    echo z >>"\$RACE_DIR/f"
    sha=\$("$real_git" -C "\$RACE_DIR" stash create) && "$real_git" -C "\$RACE_DIR" checkout -q -- f &&
      "$real_git" -C "\$RACE_DIR" update-ref --create-reflog -m intruder refs/worktree/stash "\$sha" ;;
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
check "push with a translated drop message keeps the entry in w1" test "$(n_entries "$d/w1")" -eq 1

# --- reflog expiry (git gc) must not eat entries -----------------------------
# The wrapper writes no gc settings; dotrc's global git config (dot/git/config)
# carries them. Its gc.* entries are copied into a global config file of the
# sandbox (GIT_CONFIG_GLOBAL, per command), so the real one is never read. The
# control runs with an empty global config: there the entry has to go, or the
# "survives" checks prove nothing. refs/stash is the in-repo control: git
# exempts it from expiry either way.
gcfg="$tmp/gitconfig-gc"; : >"$gcfg"
while read -r key val; do
  git config -f "$gcfg" "$key" "$val"
done < <(git config -f "$here/../dot/git/config" --get-regexp '^gc\.')
# One key per pattern and per setting, by exact name: a misspelt key or a missing
# pattern is not hidden by a count.
for pat in refs/worktree/stash 'worktrees/*/refs/worktree/stash' main-worktree/refs/worktree/stash; do
  for k in reflogexpire reflogexpireunreachable; do
    check "dot/git/config: gc.$pat.$k is never" test "$(git config -f "$here/../dot/git/config" --get "gc.$pat.$k")" = never
  done
done
check "dot/git/config carries exactly those six gc settings" test "$(git config -f "$gcfg" --get-regexp '^gc\.' | wc -l)" -eq 6
nocfg="$tmp/gitconfig-empty"; : >"$nocfg"
old="$(date -d '100 days ago' +%s) +0000"
for from in r w1; do
  for cfg in none dotrc; do
    d="$tmp/gc-$from-$cfg"; fixture "$d"
    echo old >>"$d/w1/f"
    (cd "$d/w1" && GIT_COMMITTER_DATE="$old" "$src" push -m old) >/dev/null 2>&1
    echo old >>"$d/r/f"
    (cd "$d/r" && GIT_COMMITTER_DATE="$old" "$src" push -m old-main) >/dev/null 2>&1
    check "push writes no gc settings to the repo config ($from/$cfg)" bash -c "[ -z \"\$(git -C '$d/r' config --local --get-regexp '^gc\.')\" ]"
    echo shared >>"$d/r/f"; GIT_COMMITTER_DATE="$old" git -C "$d/r" stash push -q -m shared
    g="$nocfg"; [ "$cfg" = dotrc ] && g="$gcfg"
    GIT_CONFIG_GLOBAL="$g" git -C "$d/$from" reflog expire --all
    GIT_CONFIG_GLOBAL="$g" git -C "$d/$from" gc -q
    check "expire from $from ($cfg): refs/stash keeps its entry (control)" test "$(n_shared "$d/r")" -eq 1
    if [ "$cfg" = dotrc ]; then
      check "expire from $from with dotrc's gc settings: w1's entry survives" test "$(n_entries "$d/w1")" -eq 1
      check "expire from $from with dotrc's gc settings: the main working tree's entry survives" test "$(n_entries "$d/r")" -eq 1
    else
      check "expire from $from without gc settings: w1's entry is gone (control)" test "$(n_entries "$d/w1")" -eq 0
      check "expire from $from without gc settings: the main working tree's entry is gone (control)" test "$(n_entries "$d/r")" -eq 0
    fi
  done
done

# --- pop whose apply fails keeps the entry -----------------------------------
d="$tmp/popfail"; fixture "$d"
echo stashed >"$d/w1/f"; ws "$d/w1" push -m mine >/dev/null
echo conflicting >"$d/w1/f"
err="$(ws "$d/w1" pop 2>&1 >/dev/null)"; rc=$?
check "pop with a conflicting working tree fails" test "$rc" -ne 0
check "pop that failed to apply says the entry was kept" bash -c "[[ \$1 == *'the entry was kept'* ]]" _ "$err"
check "pop that failed to apply keeps the entry" test "$(n_entries "$d/w1")" -eq 1
check "pop that failed to apply keeps the ref" has_ref "$d/w1"

# --- races -------------------------------------------------------------------

# Another push lands between ours and the tag lookup.
d="$tmp/race-push"; fixture "$d"
echo mine >>"$d/w1/f"
err="$(cd "$d/w1" && PATH="$stub:$PATH" RACE_ON=push RACE_DIR="$d/w2" "$src" push -m mine 2>&1 >/dev/null)"; rc=$?
check "push race: exits 1" test "$rc" -eq 1
line="$(git -C "$d/r" stash list --format='%H %gs' | grep mine)"
check "push race: stderr names the entry's commit and tag" bash -c "[[ \$1 == *\"commit \$2)\"* && \$1 == *\"\$3\"* ]]" _ "$err" "${line%% *}" "${line##* }"
check "push race: stderr says the working tree is clean of it" bash -c "[[ \$1 == *'out of the working tree'* ]]" _ "$err"
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
check "drop race: our entry is stored in w1" test "$(ws "$d/w1" list)" = 'refs/worktree/stash@{0}: On b1: mine'
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

# --- failures of the steps after the entry has been staged -------------------
d="$tmp/failstore"; fixture "$d"
echo mine >>"$d/w1/f"
err="$(cd "$d/w1" && PATH="$stub:$PATH" RACE_ON=failstore "$src" push -m mine 2>&1 >/dev/null)"; rc=$?
line="$(git -C "$d/r" stash list --format='%H %gs')"
check "update-ref failure: exits 1" test "$rc" -eq 1
check "update-ref failure: stderr names the commit and tag" bash -c "[[ \$1 == *\"\$2\"* && \$1 == *\"\$3\"* ]]" _ "$err" "${line%% *}" "${line##* }"
check "update-ref failure: the entry stays in the shared stash only" bash -c "[ \$(git -C '$d/r' stash list | wc -l) -eq 1 ] && ! git -C '$d/w1' show-ref --exists refs/worktree/stash 2>/dev/null"

d="$tmp/faildrop"; fixture "$d"
echo mine >>"$d/w1/f"
err="$(cd "$d/w1" && PATH="$stub:$PATH" RACE_ON=faildrop "$src" push -m mine 2>&1 >/dev/null)"; rc=$?
line="$(git -C "$d/r" stash list --format='%H %gs')"
check "stash drop failure: exits 1" test "$rc" -eq 1
check "stash drop failure: stderr names the commit and tag" bash -c "[[ \$1 == *\"\$2\"* && \$1 == *\"\$3\"* ]]" _ "$err" "${line%% *}" "${line##* }"
check "stash drop failure: the entry is in both places" bash -c "[ \$(git -C '$d/r' stash list | wc -l) -eq 1 ] && [ \$(cd '$d/w1' && '$src' list | wc -l) -eq 1 ]"

# --- failures to read a reflog are not "no entries" --------------------------
d="$tmp/readfail"; fixture "$d"
echo a >"$d/w1/f"; ws "$d/w1" push -m A >/dev/null
echo b >"$d/w1/f"; ws "$d/w1" push -m B >/dev/null
(cd "$d/w1" && PATH="$stub:$PATH" RACE_ON=failread "$src" list) >/dev/null 2>&1; rc=$?
check "list fails when the reflog cannot be read" test "$rc" -ne 0
rm -f "$d/cnt"
(cd "$d/w1" && PATH="$stub:$PATH" RACE_ON=failread2 RACE_CNT="$d/cnt" "$src" drop) >/dev/null 2>&1; rc=$?
check "drop fails when the count after the delete cannot be read" test "$rc" -ne 0
check "drop that could not count keeps the remaining entry" test "$(n_entries "$d/w1")" -eq 1
check "drop that could not count keeps the ref" has_ref "$d/w1"

d="$tmp/readfail-push"; fixture "$d"
echo mine >>"$d/w1/f"
err="$(cd "$d/w1" && PATH="$stub:$PATH" RACE_ON=failstashread "$src" push -m mine 2>&1 >/dev/null)"; rc=$?
check "push fails when the shared stash cannot be read (not 'nothing to save')" test "$rc" -eq 1
check "push that could not read the shared stash names the tag" bash -c "[[ \$1 == *'[git-wt-stash:'* ]]" _ "$err"
check "push that could not read the shared stash left the entry in the shared stash" test "$(n_shared "$d/r")" -eq 1

d="$tmp/vanish"; fixture "$d"
echo mine >>"$d/w1/f"
err="$(cd "$d/w1" && PATH="$stub:$PATH" RACE_ON=vanish "$src" push -m mine 2>&1 >/dev/null)"; rc=$?
check "push whose entry vanished from the shared stash exits 1, not 0" test "$rc" -eq 1
check "push whose entry vanished stores nothing" bash -c "! git -C '$d/w1' show-ref --exists refs/worktree/stash 2>/dev/null"

# --- a push into this worktree between the count and the ref delete ----------
d="$tmp/lastdrop"; fixture "$d"
echo mine >>"$d/w1/f"; ws "$d/w1" push -m mine >/dev/null
err="$(cd "$d/w1" && PATH="$stub:$PATH" RACE_ON=lastdrop RACE_DIR="$d/w1" "$src" drop 2>&1 >/dev/null)"; rc=$?
check "drop of the last entry beside a push: exits 0" test "$rc" -eq 0
check "drop of the last entry beside a push: the new entry survives" test "$(ws "$d/w1" list)" = 'refs/worktree/stash@{0}: intruder'
check "drop of the last entry beside a push: says so on stderr" bash -c "[[ \$1 == *'was kept with its entry'* ]]" _ "$err"

# --- a name that is not the ref must not be read as the ref ------------------
d="$tmp/dwim"; fixture "$d"
echo x >>"$d/w1/f"; git -C "$d/w1" commit -q -am x
git -C "$d/w1" branch refs/worktree/stash 2>/dev/null
git -C "$d/w1" reflog show refs/heads/refs/worktree/stash >/dev/null 2>&1 || git -C "$d/w1" update-ref --create-reflog -m branchlog refs/heads/refs/worktree/stash HEAD
before="$(git -C "$d/w1" rev-parse refs/heads/refs/worktree/stash)"
check "fixture: a branch named refs/worktree/stash exists" git -C "$d/w1" show-ref --verify -q refs/heads/refs/worktree/stash
out="$(ws "$d/w1" list 2>&1)"; rc=$?
check "list ignores a branch named like the ref" bash -c "[ $rc -eq 0 ] && [ -z \"\$1\" ]" _ "$out"
ws "$d/w1" show >/dev/null 2>&1; rc=$?
check "show ignores a branch named like the ref (exit 2)" test "$rc" -eq 2
ws "$d/w1" drop >/dev/null 2>&1; rc=$?
check "drop ignores a branch named like the ref (exit 2)" test "$rc" -eq 2
check "the branch is untouched" test "$(git -C "$d/w1" rev-parse refs/heads/refs/worktree/stash)" = "$before"
check "the branch's reflog is untouched" test "$(git -C "$d/w1" reflog show refs/heads/refs/worktree/stash | wc -l)" -ge 1

# --- a ref whose reflog is empty ---------------------------------------------
d="$tmp/orphan"; fixture "$d"
echo mine >"$d/w1/f"; ws "$d/w1" push -m mine >/dev/null
c="$(git -C "$d/w1" rev-parse refs/worktree/stash)"
git -C "$d/w1" reflog delete --updateref --rewrite 'refs/worktree/stash@{0}'
err="$(ws "$d/w1" list 2>&1 >/dev/null)"; rc=$?
check "list with a ref but no reflog entries exits 0" test "$rc" -eq 0
check "list with a ref but no reflog entries prints the commit" bash -c "[[ \$1 == *\"\$2\"* ]]" _ "$err" "$c"
echo again >"$d/w1/f"
err="$(ws "$d/w1" push -m second 2>&1 >/dev/null)"; rc=$?
check "push onto a ref with no reflog entries exits 1" test "$rc" -eq 1
check "push onto a ref with no reflog entries leaves the commit in place" test "$(git -C "$d/w1" rev-parse refs/worktree/stash)" = "$c"
check "push onto a ref with no reflog entries leaves the changes in the working tree" grep -qx again "$d/w1/f"
check "push onto a ref with no reflog entries names the commit" bash -c "[[ \$1 == *\"\$2\"* ]]" _ "$err" "$c"

# --- untracked files without -u ---------------------------------------------
d="$tmp/no-u"; fixture "$d"
echo tracked >>"$d/w1/f"; echo new >"$d/w1/u"
ws "$d/w1" push -m mine >/dev/null
check "push without -u leaves the untracked file in place" grep -qx new "$d/w1/u"
check "push without -u keeps the untracked file out of the entry" bash -c "! git -C '$d/w1' ls-tree -r --name-only 'refs/worktree/stash^3' 2>/dev/null | grep -qx u"
echo new >"$d/w1/u2"
git -C "$d/w1" checkout -q f
(cd "$d/w1" && "$src" push) >/dev/null 2>&1; rc=$?
check "push without -u and only untracked files exits 0 (nothing to save)" test "$rc" -eq 0
check "push without -u and only untracked files stores nothing new" test "$(n_entries "$d/w1")" -eq 1

# --- an empty index is not 0 ---------------------------------------------------
d="$tmp/empty-index"; fixture "$d"
echo x >>"$d/w1/f"; ws "$d/w1" push >/dev/null
(cd "$d/w1" && "$src" drop '') >/dev/null 2>&1; rc=$?
check "drop '' is a usage error" test "$rc" -eq 2
check "drop '' leaves the entry" test "$(n_entries "$d/w1")" -eq 1

# --- permissions: raw git stash is denied, the wrapper is allowed -------------
settings="$here/../dot/claude/settings.json"
has() { # <jq filter>
  jq -e "$1" "$settings" >/dev/null
}
check "settings: Bash(git stash) is denied" has '.permissions.deny | index("Bash(git stash)")'
check "settings: Bash(git stash *) is denied" has '.permissions.deny | index("Bash(git stash *)")'
check "settings: Bash(git-wt-stash) is allowed" has '.permissions.allow | index("Bash(git-wt-stash)")'
check "settings: Bash(git-wt-stash *) is allowed" has '.permissions.allow | index("Bash(git-wt-stash *)")'
check "settings: no PreToolUse hook runs claude-hook-git-guard" has '[.hooks.PreToolUse[]?.hooks[]?.command] | all(. != "claude-hook-git-guard")'
check "settings: git stash is not in the allow list" has '[.permissions.allow[] | select(startswith("Bash(git stash"))] | length == 0'

[ "$fail" -eq 0 ] && echo "all ok" || echo "some FAILED"
exit "$fail"
