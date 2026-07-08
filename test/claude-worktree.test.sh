#!/usr/bin/env bash
# Functional tests for claude-worktree's repo anchoring. Two throwaway git repos
# stand in for the "script repo" (dotrc) and an unrelated "cwd repo". We assert
# add-only mode prints a worktree path anchored to the right repo: default = cwd,
# --self = the repo the script itself lives in. No test framework; run with bash.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../bin/claude-worktree"
fail=0

tmp="$(mktemp -d)"
trap 'git -C "$tmp" worktree prune 2>/dev/null; rm -rf "$tmp"' EXIT

# "script repo" = where a copy of claude-worktree lives (stands in for dotrc).
scriptrepo="$tmp/scriptrepo"
mkdir -p "$scriptrepo/bin"
cp "$src" "$scriptrepo/bin/claude-worktree"
chmod +x "$scriptrepo/bin/claude-worktree"
git -C "$scriptrepo" init -q
git -C "$scriptrepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# unrelated "cwd repo".
cwdrepo="$tmp/cwdrepo"
mkdir -p "$cwdrepo"
git -C "$cwdrepo" init -q
git -C "$cwdrepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

wt="$scriptrepo/bin/claude-worktree"

# Default (no --self): anchored to cwd repo -> "<cwdrepo>_def".
out="$(cd "$cwdrepo" && "$wt" def 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "${cwdrepo}_def" ]; then
  echo "ok: default anchors worktree to cwd repo"
else echo "FAIL: default anchor rc=$rc out=$out want=${cwdrepo}_def"; fail=1; fi

# --self: anchored to the script's repo -> "<scriptrepo>_glob", NOT cwd repo.
out="$(cd "$cwdrepo" && "$wt" --self glob 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "${scriptrepo}_glob" ]; then
  echo "ok: --self anchors worktree to the script's own repo"
else echo "FAIL: --self anchor rc=$rc out=$out want=${scriptrepo}_glob"; fail=1; fi

# --self composes with -b (branch name independent of worktree label).
out="$(cd "$cwdrepo" && "$wt" --self glob2 -b harness/x 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "${scriptrepo}_glob2" ]; then
  echo "ok: --self composes with -b"
else echo "FAIL: --self with -b rc=$rc out=$out want=${scriptrepo}_glob2"; fail=1; fi

# Unknown flags still rejected (regression: parser didn't swallow everything).
(cd "$cwdrepo" && "$wt" --bogus name) >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: unknown flag still rejected" || { echo "FAIL: unknown flag accepted"; fail=1; }

# --- --seed -------------------------------------------------------------------
# A gitignored file in the cwd repo lands at the same relative path inside the new
# worktree (that's what lets a delegated session read it without a permission
# prompt). Nested dir exercised so the parent is created.
#
# .gitignore must be COMMITTED: `git worktree add` only checks out the branch, so
# an uncommitted .gitignore never reaches the worktree and the seeded copy would
# show up as untracked-but-not-ignored. Committing it is what makes the "seeded
# files never land in the delegate's commit" guarantee real -- and testable below.
mkdir -p "$cwdrepo/docs/specs"
echo "plan body" >"$cwdrepo/docs/specs/plan.md"
echo "docs/" >"$cwdrepo/.gitignore"
git -C "$cwdrepo" add .gitignore
git -C "$cwdrepo" -c user.email=t@t -c user.name=t commit -q -m ignore

out="$(cd "$cwdrepo" && "$wt" --seed docs/specs/plan.md seeded 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "${cwdrepo}_seeded/docs/specs/plan.md" 2>/dev/null)" = "plan body" ]; then
  echo "ok: --seed copies the file to the same relative path in the worktree"
else echo "FAIL: --seed copy rc=$rc out=$out"; fail=1; fi

# The seeded copy inherits the branch's .gitignore, so it stays ignored -- a
# delegated session running `git add -A` cannot sweep the spec into a commit.
# Empty `status --porcelain` is exactly that guarantee.
# (guard on the file existing too, so this can't pass vacuously when nothing copied)
st="$(git -C "${cwdrepo}_seeded" status --porcelain 2>/dev/null)"
if [ -f "${cwdrepo}_seeded/docs/specs/plan.md" ] && [ -z "$st" ]; then
  echo "ok: seeded gitignored file stays ignored in the worktree"
else echo "FAIL: seeded file is visible to git: ${st:-<file missing>}"; fail=1; fi

# --self anchors the WORKTREE to the script's repo, but seed sources always
# resolve against cwd's checkout (that's where the uncommitted files live).
out="$(cd "$cwdrepo" && "$wt" --self --seed docs/specs/plan.md selfseed 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "${scriptrepo}_selfseed" ] \
   && [ "$(cat "${scriptrepo}_selfseed/docs/specs/plan.md" 2>/dev/null)" = "plan body" ]; then
  echo "ok: --self seeds from cwd's checkout into the script repo's worktree"
else echo "FAIL: --self --seed rc=$rc out=$out"; fail=1; fi

# A missing seed must fail BEFORE `git worktree add` -- otherwise the delegated
# session stalls on a file that never arrives, and an orphan worktree is left.
(cd "$cwdrepo" && "$wt" --seed docs/specs/nope.md missingseed) >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -d "${cwdrepo}_missingseed" ]; then
  echo "ok: missing --seed fails before the worktree is created"
else echo "FAIL: missing seed rc=$rc, worktree created?=$([ -d "${cwdrepo}_missingseed" ] && echo yes || echo no)"; fail=1; fi

# Seeds outside cwd's checkout have no relative path in the worktree -> reject.
echo outside >"$tmp/outside.md"
(cd "$cwdrepo" && "$wt" --seed "$tmp/outside.md" outsideseed) >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -d "${cwdrepo}_outsideseed" ]; then
  echo "ok: --seed outside the checkout is rejected"
else echo "FAIL: out-of-checkout seed accepted rc=$rc"; fail=1; fi

# --seed is repeatable and takes directories. Re-running over the now-existing
# worktree is what exercises the `rm -rf` before `cp -a`: copying a directory onto
# an existing directory of the same name nests it (docs/specs/specs) instead of
# replacing it, which would leave the delegate reading a stale spec one level up.
echo "note body" >"$cwdrepo/docs/note.md"
(cd "$cwdrepo" && "$wt" --seed docs/specs --seed docs/note.md multiseed) >/dev/null 2>&1; rc=$?
(cd "$cwdrepo" && "$wt" --seed docs/specs --seed docs/note.md multiseed) >/dev/null 2>&1; rc2=$?
if [ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] \
   && [ "$(cat "${cwdrepo}_multiseed/docs/specs/plan.md" 2>/dev/null)" = "plan body" ] \
   && [ "$(cat "${cwdrepo}_multiseed/docs/note.md" 2>/dev/null)" = "note body" ] \
   && [ ! -e "${cwdrepo}_multiseed/docs/specs/specs" ]; then
  echo "ok: repeated --seed and directory seeds replace rather than nest on reseed"
else echo "FAIL: multi/dir seed rc=$rc rc2=$rc2 nested?=$([ -e "${cwdrepo}_multiseed/docs/specs/specs" ] && echo yes || echo no)"; fail=1; fi

# --- session-launch mode (with a prompt) --------------------------------------
# We can't reproduce real tmux/claude behavior, so we stub `tmux` on PATH: it
# fails `has-session` (so the script proceeds) and records `new-session`'s argv
# (one element per line) to $TMUX_STUB_LOG. This lets us assert exactly how the
# launch command is built -- including the pane-return chain -- without spawning
# anything. `git` stays real (stub only shadows tmux).
stubbin="$tmp/stubbin"
mkdir -p "$stubbin"
cat >"$stubbin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  has-session) exit 1 ;;                        # pretend no session exists yet
  new-session) printf '%s\n' "$@" >"$TMUX_STUB_LOG"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$stubbin/tmux"

# Prompt carrying a space plus both quote kinds -- must survive as ONE argv
# element (the whole point of passing it separately, not folded into a string).
prompt='say "hi" it'\''s here'

# Inside tmux ($TMUX set): launch is wrapped in `bash -c` so claude's exit is
# chained to `switch-client -t <origin_pane>`, returning the client to the pane
# we launched from. Assert the chain is wired and quoting is intact.
log="$tmp/ns-in"
out="$(cd "$cwdrepo" && { unset TMUX TMUX_PANE
  export PATH="$stubbin:$PATH" TMUX_STUB_LOG="$log" TMUX=fake TMUX_PANE=%9
  "$wt" insess -- "$prompt"; } 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] \
   && grep -q 'switch-client' "$log" \
   && grep -Fxq '%9' "$log" \
   && grep -Fxq "$prompt" "$log" \
   && grep -q 'attach   : gts' <<<"$out"; then
  echo "ok: \$TMUX set wires switch-client back to origin pane, prompt intact"
else
  echo "FAIL: in-tmux launch rc=$rc"; sed 's/^/  argv| /' "$log" 2>/dev/null; fail=1
fi

# Outside tmux ($TMUX unset): no client to return, so claude runs directly (no
# wrapper, no switch-client) and the attach hint falls back to `tmux attach`.
log="$tmp/ns-out"
out="$(cd "$cwdrepo" && { unset TMUX TMUX_PANE
  export PATH="$stubbin:$PATH" TMUX_STUB_LOG="$log"
  "$wt" nosess -- "$prompt"; } 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] \
   && ! grep -q 'switch-client' "$log" \
   && grep -Fxq 'claude' "$log" \
   && grep -Fxq "$prompt" "$log" \
   && grep -q 'attach   : tmux attach -t' <<<"$out"; then
  echo "ok: no \$TMUX launches claude directly, no pane-return chain"
else
  echo "FAIL: out-of-tmux launch rc=$rc"; sed 's/^/  argv| /' "$log" 2>/dev/null; fail=1
fi

exit "$fail"
