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

# --- default seeds declared in .claude/worktree-seed ---------------------------
# A repo names the gitignored files a delegate cannot work without (the config
# supplying its GitHub token, a local .env) in .claude/worktree-seed, and they
# are copied without --seed being given. Terms differ from an explicit --seed in
# one place: a listed path that is absent here is skipped, not fatal.

# No list at all -> unchanged behavior (nothing copied, worktree still created).
out="$(cd "$cwdrepo" && "$wt" nolist 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "${cwdrepo}_nolist" ]; then
  echo "ok: no .claude/worktree-seed is a no-op"
else echo "FAIL: absent seed list rc=$rc out=$out"; fail=1; fi

mkdir -p "$cwdrepo/.claude"
# Blank lines, a comment, and an entry this checkout does not have are all in the
# list on purpose: the first two must be ignored and the third must be SKIPPED,
# because the list is written once for the repo while any checkout may lack an
# entry. An explicit --seed of the same missing path would abort instead.
cat >"$cwdrepo/.claude/worktree-seed" <<'LIST'
# a comment line

mise.local.toml
does/not/exist.env
LIST
printf '[env]\n_.file = "~/.config/gh/personal.env"\n' >"$cwdrepo/mise.local.toml"

err="$tmp/list-default-err"
out="$(cd "$cwdrepo" && "$wt" listdefault 2>"$err")"; rc=$?
if [ "$rc" -eq 0 ] \
   && grep -Fq '_.file' "${cwdrepo}_listdefault/mise.local.toml" 2>/dev/null \
   && [ "$(grep -c 'seeded mise.local.toml' "$err")" = 1 ] \
   && [ ! -e "${cwdrepo}_listdefault/does" ]; then
  echo "ok: listed paths are seeded, missing ones skipped, comments ignored"
else echo "FAIL: seed list rc=$rc seeded=$(grep -c 'seeded mise.local.toml' "$err")"; fail=1; fi

# Naming a listed path explicitly as well must not copy or log it twice.
err="$tmp/list-explicit-err"
out="$(cd "$cwdrepo" && "$wt" --seed mise.local.toml listexplicit 2>"$err")"; rc=$?
if [ "$rc" -eq 0 ] \
   && grep -Fq '_.file' "${cwdrepo}_listexplicit/mise.local.toml" 2>/dev/null \
   && [ "$(grep -c 'seeded mise.local.toml' "$err")" = 1 ]; then
  echo "ok: a listed path also passed as --seed is not seeded twice"
else echo "FAIL: list/--seed overlap rc=$rc seeded=$(grep -c 'seeded mise.local.toml' "$err")"; fail=1; fi

# The default list is scoped to same-repo: --self anchors the WORKTREE to the
# SCRIPT repo while the list still lives in cwd's (unrelated) repo, so it must
# NOT be read -- otherwise an unrelated cwd repo's list (e.g. naming a secret
# file that repo happens to have) would leak into the anchor repo's worktree
# with no explicit request from the caller. Explicit --seed is unaffected.
out="$(cd "$cwdrepo" && "$wt" --self selfnolist 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "${scriptrepo}_selfnolist" ] \
   && [ ! -e "${scriptrepo}_selfnolist/mise.local.toml" ]; then
  echo "ok: --self does not read an unrelated cwd repo's default seed list"
else echo "FAIL: --self default-seed leak rc=$rc out=$out present?=$([ -e "${scriptrepo}_selfnolist/mise.local.toml" ] && echo yes || echo no)"; fail=1; fi

out="$(cd "$cwdrepo" && "$wt" --self --seed mise.local.toml selfexplicitseed 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "${scriptrepo}_selfexplicitseed" ] \
   && grep -Fq '_.file' "${scriptrepo}_selfexplicitseed/mise.local.toml" 2>/dev/null; then
  echo "ok: --self with explicit --seed still copies from cwd's checkout"
else echo "FAIL: --self explicit --seed rc=$rc out=$out"; fail=1; fi

# An entry escaping the checkout has no relative path in the worktree. Unlike a
# merely absent entry this is a bug in a committed, reviewed file, so it must
# fail loudly -- and before the worktree exists.
printf '../outside.md\n' >"$cwdrepo/.claude/worktree-seed"
(cd "$cwdrepo" && "$wt" listescape) >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -d "${cwdrepo}_listescape" ]; then
  echo "ok: a seed-list entry outside the checkout fails before the worktree is created"
else echo "FAIL: escaping list entry accepted rc=$rc"; fail=1; fi

# An absolute entry is rejected outright (same committed-and-reviewed reasoning
# as the escaping-entry case above), before the worktree is created.
printf '/etc/passwd\n' >"$cwdrepo/.claude/worktree-seed"
(cd "$cwdrepo" && "$wt" listabs) >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -d "${cwdrepo}_listabs" ]; then
  echo "ok: an absolute seed-list entry fails before the worktree is created"
else echo "FAIL: absolute list entry accepted rc=$rc"; fail=1; fi

# Removed again so the launch-mode tests below are unaffected by either.
rm -rf "$cwdrepo/.claude" "$cwdrepo/mise.local.toml"

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

# claude-worktree unconditionally calls `claude agents --json` to resolve the
# delegator name (and, in bg mode, to check for a colliding session) whenever a
# prompt is given -- including in the --tmux-mode tests below, which predate
# the more elaborate claude stub further down this file. Without a stub here,
# those tests would fall through to the AMBIENT claude on $PATH, making them
# depend on the host's live session roster (and call an external process from
# what should be a self-contained test). Default to an empty roster; tests that
# care about a specific roster override it via $CLAUDE_STUB_ROSTER.
cat >"$stubbin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "agents" ]; then
  if [ -n "${CLAUDE_STUB_ROSTER:-}" ]; then cat "$CLAUDE_STUB_ROSTER"; else printf '[]\n'; fi
  exit 0
fi
printf '%s\n' "$@" >"${CLAUDE_STUB_LOG:-/dev/null}"
printf 'backgrounded · %s\n' "${CLAUDE_STUB_ID:-abcd1234}"
EOF
chmod +x "$stubbin/claude"

# Prompt carrying a space plus both quote kinds -- must survive as ONE argv
# element (the whole point of passing it separately, not folded into a string).
prompt='say "hi" it'\''s here'

# Inside tmux ($TMUX set): launch is wrapped in `bash -c` so claude's exit is
# chained to `switch-client -t <origin_pane>`, returning the client to the pane
# we launched from. Assert the chain is wired and quoting is intact.
log="$tmp/ns-in"
out="$(cd "$cwdrepo" && { unset TMUX TMUX_PANE
  export PATH="$stubbin:$PATH" TMUX_STUB_LOG="$log" TMUX=fake TMUX_PANE=%9
  "$wt" --tmux insess -- "$prompt"; } 2>/dev/null)"; rc=$?
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
  "$wt" --tmux nosess -- "$prompt"; } 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] \
   && ! grep -q 'switch-client' "$log" \
   && grep -Fxq 'claude' "$log" \
   && grep -Fxq "$prompt" "$log" \
   && grep -q 'attach   : tmux attach -t' <<<"$out"; then
  echo "ok: no \$TMUX launches claude directly, no pane-return chain"
else
  echo "FAIL: out-of-tmux launch rc=$rc"; sed 's/^/  argv| /' "$log" 2>/dev/null; fail=1
fi

# Omitting --model must leave the out-of-tmux launch byte-identical to before the
# flag existed: no `--model` in argv at all, so claude inherits its default model.
# (reuses the out-of-tmux log captured just above)
if ! grep -q -- '--model' "$tmp/ns-out" && ! grep -q 'model    :' <<<"$out"; then
  echo "ok: no --model in argv when the flag is omitted"
else
  echo "FAIL: --model leaked into a launch that did not ask for it"; fail=1
fi

# In-tmux the same check cannot grep for `--model`: the `bash -c` wrapper string
# carries that literal in BOTH branches, so a substring match there is vacuous
# (it passes even when the flag was never given). What actually decides is the
# model slot -- the trailing positional ($3) -- which must arrive EMPTY so the
# wrapper takes its else branch instead of running `claude --model ""`.
if [ -z "$(tail -n1 "$tmp/ns-in")" ]; then
  echo "ok: in-tmux model slot is empty when --model is omitted"
else
  echo "FAIL: in-tmux model slot is '$(tail -n1 "$tmp/ns-in")' without --model"; fail=1
fi

# --- --model ------------------------------------------------------------------
# Inside tmux the model rides in as a positional arg ($3) of the `bash -c` wrapper
# rather than being folded into the command string, so it cannot break the
# pane-return chain. The alias reaching argv as its own element is what proves the
# flag was honored -- grepping the log for `--model` would be vacuous here (see
# the omitted-flag check above). Assert instead that the wrapper still guards on
# an empty $3, that the alias arrives, the chain survives, and the report names it.
log="$tmp/ns-model-in"
out="$(cd "$cwdrepo" && { unset TMUX TMUX_PANE
  export PATH="$stubbin:$PATH" TMUX_STUB_LOG="$log" TMUX=fake TMUX_PANE=%9
  "$wt" --tmux --model opus modelin -- "$prompt"; } 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] \
   && grep -Fq 'if [ -n "$3" ]; then' "$log" \
   && grep -Fxq 'opus' "$log" \
   && grep -q 'switch-client' "$log" \
   && grep -Fxq "$prompt" "$log" \
   && grep -q 'model    : opus' <<<"$out"; then
  echo "ok: --model reaches the in-tmux launch and is reported"
else
  echo "FAIL: in-tmux --model rc=$rc"; sed 's/^/  argv| /' "$log" 2>/dev/null; fail=1
fi

# Outside tmux claude is exec'd directly, so `--model <alias>` must sit in argv
# as two adjacent elements ahead of the prompt.
log="$tmp/ns-model-out"
out="$(cd "$cwdrepo" && { unset TMUX TMUX_PANE
  export PATH="$stubbin:$PATH" TMUX_STUB_LOG="$log"
  "$wt" --tmux --model sonnet modelout -- "$prompt"; } 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] \
   && grep -A1 -Fx -- '--model' "$log" | grep -Fxq 'sonnet' \
   && grep -Fxq "$prompt" "$log" \
   && grep -q 'model    : sonnet' <<<"$out"; then
  echo "ok: --model reaches the out-of-tmux launch and is reported"
else
  echo "FAIL: out-of-tmux --model rc=$rc"; sed 's/^/  argv| /' "$log" 2>/dev/null; fail=1
fi

# A dangling --model would otherwise swallow the worktree name as its value.
(cd "$cwdrepo" && "$wt" --model) >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: --model without a value is rejected" \
  || { echo "FAIL: dangling --model accepted"; fail=1; }

# `--model ""` -- the common unset-variable expansion at a call site. Falling back
# to the inherited default here would run an unwatched delegation on a model the
# caller did not ask for, so it must fail loudly (and before the worktree exists).
(cd "$cwdrepo" && "$wt" --model "" emptymodel) >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -d "${cwdrepo}_emptymodel" ]; then
  echo "ok: empty --model value is rejected before the worktree is created"
else echo "FAIL: empty --model accepted rc=$rc"; fail=1; fi

# --- remote-only branch resolution --------------------------------------------
# `-b <branch>` must resolve against LOCAL branches, then origin's remote-tracking
# branches, before falling back to "create new from current HEAD". A dedicated
# bare origin + clone (not cwdrepo/scriptrepo, to avoid interfering with the
# tests above) lets us push branches that never get a local tracking branch.

remotesrc="$tmp/remotesrc"
mkdir -p "$remotesrc"
git -C "$remotesrc" init -q
git -C "$remotesrc" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
# `git init`'s initial branch follows init.defaultBranch, which varies by
# environment (e.g. "master" instead of "main") -- pin it explicitly so the
# `checkout -q main` calls below don't fail on non-"main"-default setups.
git -C "$remotesrc" branch -q -M main

originbare="$tmp/origin.git"
git init -q --bare "$originbare"
# Push the initial commit to an explicit "main" ref, then point the bare repo's
# HEAD at it directly -- `git init --bare`'s HEAD follows init.defaultBranch,
# which varies by environment, so this is what makes `git clone` below check out
# the branch we actually intend ("main") rather than whatever the default was.
git -C "$remotesrc" push -q "$originbare" HEAD:refs/heads/main
git -C "$originbare" symbolic-ref HEAD refs/heads/main

# origin-only branch: pushed to origin, then deleted locally, so nothing but the
# remote-tracking ref (refs/remotes/origin/remoteonly) will exist in the clone.
git -C "$remotesrc" checkout -q -b remoteonly
echo "remote content" >"$remotesrc/remote.txt"
git -C "$remotesrc" add remote.txt
git -C "$remotesrc" -c user.email=t@t -c user.name=t commit -q -m "remote-only commit"
git -C "$remotesrc" push -q "$originbare" remoteonly
remote_only_sha="$(git -C "$remotesrc" rev-parse remoteonly)"
git -C "$remotesrc" checkout -q main
git -C "$remotesrc" branch -q -D remoteonly

# a branch that will exist BOTH locally (in the clone, below) and on origin, at
# DIFFERENT commits -- proves local takes precedence over same-named remote.
git -C "$remotesrc" checkout -q -b localdiff
echo "origin's localdiff content" >"$remotesrc/localdiff.txt"
git -C "$remotesrc" add localdiff.txt
git -C "$remotesrc" -c user.email=t@t -c user.name=t commit -q -m "origin's localdiff commit"
git -C "$remotesrc" push -q "$originbare" localdiff
git -C "$remotesrc" checkout -q main
git -C "$remotesrc" branch -q -D localdiff

clone2="$tmp/clone2"
git clone -q "$originbare" "$clone2"
clone_head_sha="$(git -C "$clone2" rev-parse HEAD)"

# Give the clone its OWN local "localdiff" branch, at a commit that differs from
# origin/localdiff (sanity-checked below so this can't pass vacuously).
git -C "$clone2" checkout -q -b localdiff main
echo "local's localdiff content" >"$clone2/localdiff.txt"
git -C "$clone2" add localdiff.txt
git -C "$clone2" -c user.email=t@t -c user.name=t commit -q -m "local's localdiff commit"
local_localdiff_sha="$(git -C "$clone2" rev-parse localdiff)"
origin_localdiff_sha="$(git -C "$clone2" rev-parse origin/localdiff)"
git -C "$clone2" checkout -q main

if [ "$local_localdiff_sha" = "$origin_localdiff_sha" ] || [ "$remote_only_sha" = "$clone_head_sha" ]; then
  echo "FAIL: test setup produced colliding shas, the assertions below would be vacuous"; fail=1
fi

# Case 1: branch absent locally but present on origin -> checked out at origin's
# commit (NOT built fresh from the clone's current HEAD, which is the bug) and
# tracking origin/<branch>.
out="$(cd "$clone2" && "$wt" remoteonlytest -b remoteonly 2>/dev/null)"; rc=$?
wt_sha="$(git -C "$out" rev-parse HEAD 2>/dev/null)"
wt_upstream="$(git -C "$out" rev-parse --abbrev-ref --symbolic-full-name "@{upstream}" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$wt_sha" = "$remote_only_sha" ] && [ "$wt_upstream" = "origin/remoteonly" ]; then
  echo "ok: remote-only branch checks out origin's commit and tracks origin/<branch>"
else
  echo "FAIL: remote-only branch rc=$rc sha=$wt_sha want=$remote_only_sha upstream=$wt_upstream want=origin/remoteonly"
  fail=1
fi

# Case 2: branch exists both locally and on origin, at different commits -> the
# LOCAL branch wins (must not be pulled from origin just because origin also
# has it).
out="$(cd "$clone2" && "$wt" localdifftest -b localdiff 2>/dev/null)"; rc=$?
wt_sha="$(git -C "$out" rev-parse HEAD 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$wt_sha" = "$local_localdiff_sha" ]; then
  echo "ok: local branch takes precedence over a same-named branch on origin"
else
  echo "FAIL: local-branch precedence rc=$rc sha=$wt_sha want=$local_localdiff_sha (origin has $origin_localdiff_sha)"
  fail=1
fi

# Case 3: branch absent from both local and origin -> unchanged behavior, a new
# branch created from the clone's current HEAD.
out="$(cd "$clone2" && "$wt" newbranchtest -b brandnew 2>/dev/null)"; rc=$?
wt_sha="$(git -C "$out" rev-parse HEAD 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$wt_sha" = "$clone_head_sha" ]; then
  echo "ok: branch absent from both local and origin is created fresh from current HEAD"
else
  echo "FAIL: new-branch fallback rc=$rc sha=$wt_sha want=$clone_head_sha"; fail=1
fi

# --- background launch mode (default when a prompt is given) ------------------
# `claude` is stubbed on PATH: `--bg` records its argv and prints the real
# banner shape, `agents --json` prints a roster fixture. Nothing is spawned.
cat >"$stubbin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "agents" ]; then cat "$CLAUDE_STUB_ROSTER"; exit 0; fi
printf '%s\n' "$@" >"$CLAUDE_STUB_LOG"
printf 'Starting background service…\n'
printf 'backgrounded · %s\n' "${CLAUDE_STUB_ID:-abcd1234}"
printf '  claude attach %s    open in this terminal\n' "${CLAUDE_STUB_ID:-abcd1234}"
EOF
chmod +x "$stubbin/claude"

emptyroster="$tmp/roster-empty.json"
echo '[]' >"$emptyroster"

# Default (no --tmux): claude --bg is launched with acceptEdits, the short id is
# lifted out of the banner, and the report tells the user how to attach.
log="$tmp/bg-default"
out="$(cd "$cwdrepo" && { unset TMUX TMUX_PANE
  export PATH="$stubbin:$PATH" CLAUDE_STUB_LOG="$log" CLAUDE_STUB_ROSTER="$emptyroster"
  "$wt" bgdefault -- "$prompt"; } 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] \
   && grep -Fxq -- '--bg' "$log" \
   && grep -Fxq -- 'acceptEdits' "$log" \
   && grep -Fxq "$prompt" "$log" \
   && grep -q 'session  : abcd1234 (background' <<<"$out" \
   && grep -q 'attach   : claude attach abcd1234' <<<"$out"; then
  echo "ok: default launch uses claude --bg and reports the short id"
else
  echo "FAIL: bg default rc=$rc"; sed 's/^/  argv| /' "$log" 2>/dev/null; echo "$out"; fail=1
fi

# The worktree dir must be the launched session's cwd -- otherwise the delegate
# reads the wrong checkout. The stub records it via PWD.
cat >"$stubbin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "agents" ]; then cat "$CLAUDE_STUB_ROSTER"; exit 0; fi
printf '%s\n' "$PWD" >"$CLAUDE_STUB_CWDLOG"
printf '%s\n' "$@" >"$CLAUDE_STUB_LOG"
printf 'backgrounded · %s\n' "${CLAUDE_STUB_ID:-abcd1234}"
EOF
chmod +x "$stubbin/claude"
log="$tmp/bg-cwd"; cwdlog="$tmp/bg-cwd-pwd"
(cd "$cwdrepo" && { unset TMUX TMUX_PANE
  export PATH="$stubbin:$PATH" CLAUDE_STUB_LOG="$log" CLAUDE_STUB_CWDLOG="$cwdlog" \
         CLAUDE_STUB_ROSTER="$emptyroster"
  "$wt" bgcwd -- "$prompt"; }) >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$cwdlog" 2>/dev/null)" = "${cwdrepo}_bgcwd" ]; then
  echo "ok: bg launch runs with the worktree as cwd"
else echo "FAIL: bg cwd rc=$rc got=$(cat "$cwdlog" 2>/dev/null) want=${cwdrepo}_bgcwd"; fail=1; fi

# --model rides through to the bg launch as two adjacent argv elements.
log="$tmp/bg-model"
out="$(cd "$cwdrepo" && { unset TMUX TMUX_PANE
  export PATH="$stubbin:$PATH" CLAUDE_STUB_LOG="$log" CLAUDE_STUB_CWDLOG="$tmp/x" \
         CLAUDE_STUB_ROSTER="$emptyroster"
  "$wt" --model opus bgmodel -- "$prompt"; } 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] \
   && grep -A1 -Fx -- '--model' "$log" | grep -Fxq 'opus' \
   && grep -q 'model    : opus' <<<"$out"; then
  echo "ok: --model reaches the bg launch and is reported"
else echo "FAIL: bg --model rc=$rc"; sed 's/^/  argv| /' "$log" 2>/dev/null; fail=1; fi

# Omitting --model must not synthesise `--model ""` (claude rejects it).
log="$tmp/bg-nomodel"
out="$(cd "$cwdrepo" && { unset TMUX TMUX_PANE
  export PATH="$stubbin:$PATH" CLAUDE_STUB_LOG="$log" CLAUDE_STUB_CWDLOG="$tmp/x" \
         CLAUDE_STUB_ROSTER="$emptyroster"
  "$wt" bgnomodel -- "$prompt"; } 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && ! grep -q -- '--model' "$log" && ! grep -q 'model    :' <<<"$out"; then
  echo "ok: no --model in the bg launch when the flag is omitted"
else echo "FAIL: bg model leak rc=$rc"; fail=1; fi

# A banner the parser does not recognise must not be swallowed: the session IS
# running, so the raw output is surfaced instead of a silently missing id.
cat >"$stubbin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "agents" ]; then cat "$CLAUDE_STUB_ROSTER"; exit 0; fi
printf 'some unexpected banner shape\n'
EOF
chmod +x "$stubbin/claude"
out="$(cd "$cwdrepo" && { unset TMUX TMUX_PANE
  export PATH="$stubbin:$PATH" CLAUDE_STUB_ROSTER="$emptyroster"
  "$wt" bgweird -- "$prompt"; } 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'some unexpected banner shape' <<<"$out"; then
  echo "ok: unparseable banner is surfaced rather than dropped"
else echo "FAIL: unparseable banner rc=$rc out=$out"; fail=1; fi

# When claude itself FAILS (nonzero exit), the failure must be diagnosable: rc
# is nonzero AND the captured stderr reaches the caller. Under `set -e`, a bare
# `launch_out="$(... claude ...)"` assignment aborts the script the instant
# claude exits nonzero -- before the captured output is ever printed -- so this
# guards against that regression (rc=1 with empty output).
cat >"$stubbin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "agents" ]; then cat "$CLAUDE_STUB_ROSTER"; exit 0; fi
echo "claude: fatal: something went wrong" >&2
exit 1
EOF
chmod +x "$stubbin/claude"
out="$(cd "$cwdrepo" && { unset TMUX TMUX_PANE
  export PATH="$stubbin:$PATH" CLAUDE_STUB_ROSTER="$emptyroster"
  "$wt" bgfail -- "$prompt"; } 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'claude: fatal: something went wrong' <<<"$out"; then
  echo "ok: a failing bg launch reports its captured stderr instead of dying silently"
else echo "FAIL: bg launch failure rc=$rc out=$out"; fail=1; fi

# A background session already running in the same worktree means a second
# delegation would race the first -- refuse, and say how to reach the existing
# one. Must fail BEFORE launching (stub log stays empty).
cat >"$stubbin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "agents" ]; then cat "$CLAUDE_STUB_ROSTER"; exit 0; fi
printf '%s\n' "$@" >"$CLAUDE_STUB_LOG"
printf 'backgrounded · abcd1234\n'
EOF
chmod +x "$stubbin/claude"
busyroster="$tmp/roster-busy.json"
cat >"$busyroster" <<EOF
[{"pid":1,"cwd":"${cwdrepo}_bgbusy","kind":"background","sessionId":"feedface-1111-2222-3333-444444444444","status":"working"}]
EOF
log="$tmp/bg-busy"; : >"$log"
out="$(cd "$cwdrepo" && { unset TMUX TMUX_PANE
  export PATH="$stubbin:$PATH" CLAUDE_STUB_LOG="$log" CLAUDE_STUB_ROSTER="$busyroster"
  "$wt" bgbusy -- "$prompt"; } 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$log" ] && grep -q 'feedface' <<<"$out"; then
  echo "ok: an existing bg session in the same worktree blocks a second launch"
else echo "FAIL: bg collision rc=$rc out=$out"; fail=1; fi

# --- delegator name injection -------------------------------------------------
# The delegate has no conversation history, so it can only report back if it is
# told who to report to. The name is resolved by walking this process's
# ancestors until one is a live claude session -- the test shell stands in for
# that session by putting its own pid in the roster.
# This stub additionally records the LAST argv element on its own. The injected
# block must ride inside the prompt argument; splitting it into a second
# argument would make claude treat it as a separate positional. Since the log
# writes one element per LINE and the prompt itself is multi-line, a line-based
# grep cannot tell the two apart -- capturing the last element does.
cat >"$stubbin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "agents" ]; then cat "$CLAUDE_STUB_ROSTER"; exit 0; fi
printf '%s\n' "$@" >"$CLAUDE_STUB_LOG"
printf '%s' "${!#}" >"${CLAUDE_STUB_LASTARG:-/dev/null}"
printf 'backgrounded · abcd1234\n'
EOF
chmod +x "$stubbin/claude"

namedroster="$tmp/roster-named.json"
cat >"$namedroster" <<EOF
[{"pid":$$,"cwd":"$cwdrepo","kind":"interactive","sessionId":"eeeeeeee-1111-2222-3333-444444444444","name":"test-delegator","status":"busy"}]
EOF

log="$tmp/bg-name"; lastarg="$tmp/bg-name-last"
out="$(cd "$cwdrepo" && { unset TMUX TMUX_PANE
  export PATH="$stubbin:$PATH" CLAUDE_STUB_LOG="$log" CLAUDE_STUB_LASTARG="$lastarg" \
         CLAUDE_STUB_ROSTER="$namedroster"
  "$wt" bgname -- "$prompt"; } 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] \
   && grep -Fq '## 委譲元' "$log" \
   && grep -Fq '報告先 name: test-delegator' "$log" \
   && grep -q 'report-to: test-delegator' <<<"$out"; then
  echo "ok: delegator name is resolved, injected, and reported"
else
  echo "FAIL: name injection rc=$rc"; sed 's/^/  argv| /' "$log" 2>/dev/null; fail=1
fi

# Same argv element: the last argument must contain BOTH the original prompt and
# the injected block. Two separate arguments would make claude read the block as
# a stray positional instead of part of the delegated instructions.
if grep -Fq "$prompt" "$lastarg" && grep -Fq '報告先 name: test-delegator' "$lastarg"; then
  echo "ok: the injected block rides inside the prompt argument"
else
  echo "FAIL: injected block is not in the prompt argv element"; fail=1
fi

# No claude ancestor (a human running the script from a plain shell) -> nothing
# is injected and no report-to line is printed. Silence is correct here: there
# is no delegator to report to.
log="$tmp/bg-noname"
out="$(cd "$cwdrepo" && { unset TMUX TMUX_PANE
  export PATH="$stubbin:$PATH" CLAUDE_STUB_LOG="$log" CLAUDE_STUB_ROSTER="$emptyroster"
  "$wt" bgnoname -- "$prompt"; } 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] \
   && ! grep -Fq '委譲元' "$log" \
   && ! grep -q 'report-to' <<<"$out"; then
  echo "ok: no delegator resolvable -> nothing injected, nothing reported"
else echo "FAIL: unexpected injection rc=$rc"; fail=1; fi

# A roster entry without a `name` field (older sessions have none) must be
# treated as unresolvable rather than injecting an empty name.
nonameroster="$tmp/roster-noname.json"
cat >"$nonameroster" <<EOF
[{"pid":$$,"cwd":"$cwdrepo","kind":"interactive","sessionId":"ffffffff-1111-2222-3333-444444444444","status":"busy"}]
EOF
log="$tmp/bg-nullname"
out="$(cd "$cwdrepo" && { unset TMUX TMUX_PANE
  export PATH="$stubbin:$PATH" CLAUDE_STUB_LOG="$log" CLAUDE_STUB_ROSTER="$nonameroster"
  "$wt" bgnullname -- "$prompt"; } 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && ! grep -Fq '委譲元' "$log" && ! grep -q 'report-to' <<<"$out"; then
  echo "ok: a roster entry without a name is treated as unresolvable"
else echo "FAIL: nameless entry injected rc=$rc"; fail=1; fi

# --tmux gets the same injection: a human may be sitting with that session, but
# the delegate still benefits from knowing who asked.
log="$tmp/tmux-name"
(cd "$cwdrepo" && { unset TMUX TMUX_PANE
  export PATH="$stubbin:$PATH" TMUX_STUB_LOG="$log" CLAUDE_STUB_ROSTER="$namedroster"
  "$wt" --tmux tmuxname -- "$prompt"; }) >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -Fq '報告先 name: test-delegator' "$log"; then
  echo "ok: --tmux receives the same delegator injection"
else echo "FAIL: --tmux missing injection rc=$rc"; sed 's/^/  argv| /' "$log" 2>/dev/null; fail=1; fi

exit "$fail"
