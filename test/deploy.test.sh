#!/usr/bin/env bash
# Functional tests for the Bashrc block of bin/deploy.sh, the one part of the
# script that was not idempotent (the symlink loop below it uses `ln -snvf`).
# Everything runs inside a mktemp sandbox: the script is copied into a fake
# minimal checkout so $REPO_DIR points there rather than at the real one, and
# $HOME is a directory under the sandbox, so nothing touches the real home.
#
# The fake checkout deliberately has no src/claude-queue, which is what keeps
# deploy.sh from running `make install` here -- the guard on that block is
# `-d "${REPO_DIR}/src/claude-queue"`, so no PATH surgery is needed to keep Go
# out of the test.
#
# Case B is the discrimination check (evidence-over-guesswork §4): the same
# script with its `guard@dotrc` lines stripped must append twice. If that tag
# ever disappears from deploy.sh the mutant becomes identical to the original
# and case B fails, so the check cannot rot into a no-op silently.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
src="$here/../bin/deploy.sh"
fail=0

sandbox="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$sandbox"' EXIT
# mise walks up from cwd for .config/mise/config.toml and reads it as project
# config, so a cwd under the real HOME (a dotrc checkout) picks up the real
# global trusted_config_paths over the sandbox's. Pin cwd outside HOME.
cd "$sandbox" || exit 1

check() {  # check <description> <0-or-1>
  if [ "$2" = 0 ]; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi
}

marker='# DOTRC =================================='
blocks() {  # blocks <bashrc>; how many DOTRC blocks it holds
  grep -cF "$marker" "$1" 2>/dev/null || true
}

# A minimal checkout: just enough for deploy.sh to have something to link and
# a bashrc path to substitute into the block.
repo="$sandbox/repo"
mkdir -p "$repo/bin" "$repo/rc" "$repo/dot/example" "$repo/dot/claude/rules"
: >"$repo/rc/bashrc"
: >"$repo/dot/example/file"
: >"$repo/dot/claude/rules/rule.md"
cp "$src" "$repo/bin/deploy.sh"
chmod +x "$repo/bin/deploy.sh"
repo="$(cd "$repo" && pwd -P)"  # deploy.sh resolves REPO_DIR with realpath

# The control: the same script with its guard removed.
grep -v 'guard@dotrc' "$repo/bin/deploy.sh" >"$repo/bin/deploy-noguard.sh"
chmod +x "$repo/bin/deploy-noguard.sh"
check "the guard-less control really differs from the script under test" \
  "$(if ! cmp -s "$repo/bin/deploy.sh" "$repo/bin/deploy-noguard.sh"
     then echo 0; else echo 1; fi)"

# Everything deploy.sh resolves off the environment has to land in the sandbox.
# HOME alone is not enough: mise honours XDG_* and its own MISE_* overrides, and
# an inherited one would point `mise settings add` at the real global config.
sandboxed() {  # sandboxed <home> <cmd...>
  local h="$1"; shift
  env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME \
      -u MISE_GLOBAL_CONFIG_FILE -u MISE_CONFIG_DIR -u MISE_DATA_DIR -u MISE_STATE_DIR \
      -u MISE_CACHE_DIR -u MISE_TRUSTED_CONFIG_PATHS -u MISE_ENV -u CLAUDE_CONFIG_DIR \
      HOME="$h" "$@"
}

run() {  # run <script> <home>
  sandboxed "$2" "$1" >/dev/null 2>&1
}

# Separate from run(): captures stderr instead of discarding it, to check the
# skip notice the guard prints on its else branch (a stale block pointing at
# another checkout should not go silently unnoticed -- dotrc-deploy.md §4).
run_capture_stderr() {  # run_capture_stderr <script> <home> <stderr-out-file>
  sandboxed "$2" "$1" >/dev/null 2>"$3"
}

# --- Case A: a first-time home, then a re-run -------------------------------
home_a="$sandbox/home_a"; mkdir -p "$home_a"
run "$repo/bin/deploy.sh" "$home_a"; rc_a=$?
check "a first run on a home with no ~/.bashrc exits 0 and writes the block" \
  "$(if [ "$rc_a" -eq 0 ] && [ "$(blocks "$home_a/.bashrc")" -eq 1 ]
     then echo 0; else echo 1; fi)"
# envsubst has to have expanded the two exported paths; an unexpanded or empty
# block would still carry the marker and so still satisfy the count above.
check "the block sources the checkout's own rc/bashrc" \
  "$(if grep -qF "source \"$repo/rc/bashrc\"" "$home_a/.bashrc"; then echo 0; else echo 1; fi)"
check "the block puts the checkout's own bin/ on PATH" \
  "$(if grep -qF "export PATH=\"$repo/bin:\$PATH\"" "$home_a/.bashrc"
     then echo 0; else echo 1; fi)"
run "$repo/bin/deploy.sh" "$home_a"
check "re-running deploy.sh does not append the block a second time" \
  "$(if [ "$(blocks "$home_a/.bashrc")" -eq 1 ]; then echo 0; else echo 1; fi)"
# deploy.sh is re-run precisely to expand new dot/ entries, so the guard must
# not have cost the rest of the script its second pass.
check "the re-run still expands dot/ entries" \
  "$(if [ -L "$home_a/.example" ]; then echo 0; else echo 1; fi)"
stderr_a="$sandbox/stderr_a"
run_capture_stderr "$repo/bin/deploy.sh" "$home_a" "$stderr_a"
check "re-running deploy.sh reports the skip on stderr instead of staying silent" \
  "$(if grep -qF 'already in' "$stderr_a" && grep -qF 'skipped' "$stderr_a"
     then echo 0; else echo 1; fi)"

# --- Case B: the same two runs without the guard ----------------------------
home_b="$sandbox/home_b"; mkdir -p "$home_b"
run "$repo/bin/deploy-noguard.sh" "$home_b"
run "$repo/bin/deploy-noguard.sh" "$home_b"
check "without the guard, two runs leave two blocks" \
  "$(if [ "$(blocks "$home_b/.bashrc")" -eq 2 ]; then echo 0; else echo 1; fi)"

# --- Case C: an existing ~/.bashrc that knows nothing about dotrc -----------
home_c="$sandbox/home_c"; mkdir -p "$home_c"
printf '%s\n' '# hand-written line' >"$home_c/.bashrc"
run "$repo/bin/deploy.sh" "$home_c"
run "$repo/bin/deploy.sh" "$home_c"
check "an unrelated ~/.bashrc keeps its content and gains exactly one block" \
  "$(if grep -qF '# hand-written line' "$home_c/.bashrc" \
       && [ "$(blocks "$home_c/.bashrc")" -eq 1 ]
     then echo 0; else echo 1; fi)"

# --- Case D: a subdirectory under bin/ --------------------------------------
# bin/lib/ (the gh wrappers' shared helper) is the first non-executable
# subdirectory to live under bin/. deploy.sh only puts bin/ on PATH -- it never
# links bin/ entry by entry, and its symlink loop walks dot/ -- so the
# subdirectory should be invisible to it. Asserted rather than assumed: the
# failure mode would be a stray ~/.lib symlink, or the dot/ expansion breaking.
mkdir -p "$repo/bin/lib"
: >"$repo/bin/lib/gh-mise.sh"
check "the fixture really has a subdirectory under bin/" \
  "$(if [ -d "$repo/bin/lib" ]; then echo 0; else echo 1; fi)"
home_d="$sandbox/home_d"; mkdir -p "$home_d"
run "$repo/bin/deploy.sh" "$home_d"; rc_d=$?
check "a subdirectory under bin/ leaves deploy.sh's block and dot/ expansion intact" \
  "$(if [ "$rc_d" -eq 0 ] && [ "$(blocks "$home_d/.bashrc")" -eq 1 ] \
       && [ -L "$home_d/.example" ] && [ ! -e "$home_d/.lib" ] && [ ! -e "$home_d/.bin" ]
     then echo 0; else echo 1; fi)"

# --- Case E: dot/claude goes to ~/.claude only ----------------------------
# A re-run must leave the links links (not a nested rules/rules, which is what
# `ln -snvf` onto an existing real dir would make), and no second config dir
# is created next to ~/.claude.
linked_to_rules() {  # linked_to_rules <path>
  [ -L "$1" ] && [ "$(readlink "$1")" = "$repo/dot/claude/rules" ]
}
home_e="$sandbox/home_e"; mkdir -p "$home_e"
run "$repo/bin/deploy.sh" "$home_e"
run "$repo/bin/deploy.sh" "$home_e"
check "dot/claude entries are linked into ~/.claude, idempotently" \
  "$(if linked_to_rules "$home_e/.claude/rules" && [ ! -e "$repo/dot/claude/rules/rules" ]
     then echo 0; else echo 1; fi)"
check "deploy.sh creates no ~/.claude-personal" \
  "$(if [ ! -e "$home_e/.claude-personal" ]; then echo 0; else echo 1; fi)"

# --- Case F: personal.env and mise.gh.local.toml templates -------------------
# Created when absent, owner-only; never overwritten, since by the second run
# the token has been filled in. The control drops the absence check.
home_f="$sandbox/home_f"; mkdir -p "$home_f"
rm -f "$repo/mise.gh.local.toml"
run "$repo/bin/deploy.sh" "$home_f"
penv="$home_f/.config/gh/personal.env"
check "a missing personal.env is created, mode 600, with an empty GH_TOKEN key" \
  "$(if [ "$(stat -c %a "$penv" 2>/dev/null)" = 600 ] && grep -qx 'GH_TOKEN=' "$penv"
     then echo 0; else echo 1; fi)"
check "a missing mise.gh.local.toml is created pointing at personal.env" \
  "$(if grep -qF '_.file = "~/.config/gh/personal.env"' "$repo/mise.gh.local.toml" 2>/dev/null
     then echo 0; else echo 1; fi)"
printf 'GH_TOKEN=filled\n' >"$penv"
printf '# hand-edited\n' >"$repo/mise.gh.local.toml"
run "$repo/bin/deploy.sh" "$home_f"
check "a re-run leaves a filled-in personal.env and mise.gh.local.toml alone" \
  "$(if grep -qx 'GH_TOKEN=filled' "$penv" && grep -qx '# hand-edited' "$repo/mise.gh.local.toml"
     then echo 0; else echo 1; fi)"
sed 's|^if \[ ! -e "${__personal_env}" \]; then$|if true; then|' \
  "$repo/bin/deploy.sh" >"$repo/bin/deploy-clobber.sh"
chmod +x "$repo/bin/deploy-clobber.sh"
run "$repo/bin/deploy-clobber.sh" "$home_f"
check "without the absence check, the filled-in token would be overwritten" \
  "$(if ! grep -qx 'GH_TOKEN=filled' "$penv"; then echo 0; else echo 1; fi)"

# --- Case H: mise.local.toml is not deploy.sh's ----------------------------
# deploy.sh neither creates it nor touches one that already exists (a checkout
# may still carry a hand-written one).
home_h="$sandbox/home_h"; mkdir -p "$home_h"
rm -f "$repo/mise.local.toml"
run "$repo/bin/deploy.sh" "$home_h"
check "a fresh deploy does not create mise.local.toml" \
  "$(if [ ! -e "$repo/mise.local.toml" ]; then echo 0; else echo 1; fi)"
printf '# hand-edited\n' >"$repo/mise.local.toml"
run "$repo/bin/deploy.sh" "$home_h"
check "an existing mise.local.toml is left alone" \
  "$(if [ "$(cat "$repo/mise.local.toml")" = '# hand-edited' ]; then echo 0; else echo 1; fi)"
rm -f "$repo/mise.local.toml"

# --- Case G: the checkout is trusted by path prefix, once --------------------
# A worktree's own mise.toml is not covered by `mise trust` on the checkout, so
# deploy.sh adds the checkout to trusted_config_paths. `mise settings add`
# appends a duplicate per call, so two runs must still leave one entry; the
# control without the check-first leaves two.
if command -v mise >/dev/null 2>&1; then
  mise_cfg() { printf '%s\n' "$1/.config/mise/config.toml"; }
  trusted_count() {  # trusted_count <home>
    grep -oF "\"$repo\"" "$(mise_cfg "$1")" 2>/dev/null | wc -l
  }
  home_g="$sandbox/home_g"; mkdir -p "$home_g"
  run "$repo/bin/deploy.sh" "$home_g"
  run "$repo/bin/deploy.sh" "$home_g"
  check "two runs leave the checkout in trusted_config_paths exactly once" \
    "$(if [ "$(trusted_count "$home_g")" -eq 1 ]; then echo 0; else echo 1; fi)"
  # A leftover untrusted parent mise.local.toml would make the control below
  # fail for the wrong reason, so do not depend on Case H's cleanup.
  rm -f "$repo/mise.local.toml"
  mkdir -p "$repo/.worktrees/wt"
  printf '[env]\nDEPLOY_TEST = "yes"\n' >"$repo/.worktrees/wt/mise.toml"
  check "the control: without deploy.sh, that worktree mise.toml is untrusted" \
    "$(home_g0="$sandbox/home_g0"; mkdir -p "$home_g0"
       if ! sandboxed "$home_g0" mise env -C "$repo/.worktrees/wt" >/dev/null 2>&1
       then echo 0; else echo 1; fi)"
  check "a worktree's own mise.toml is trusted after deploy.sh" \
    "$(if sandboxed "$home_g" mise env -C "$repo/.worktrees/wt" 2>/dev/null | grep -qF 'DEPLOY_TEST=yes'
       then echo 0; else echo 1; fi)"
  grep -v '^    if ! mise settings get trusted_config_paths' "$repo/bin/deploy.sh" \
    | sed '/^        mise settings add trusted_config_paths/{n;d}' >"$repo/bin/deploy-dup.sh"
  chmod +x "$repo/bin/deploy-dup.sh"
  home_g2="$sandbox/home_g2"; mkdir -p "$home_g2"
  run "$repo/bin/deploy-dup.sh" "$home_g2"
  run "$repo/bin/deploy-dup.sh" "$home_g2"
  check "without the check-first, two runs leave a duplicate entry" \
    "$(if [ "$(trusted_count "$home_g2")" -eq 2 ]; then echo 0; else echo 1; fi)"
else
  echo "skip: mise not available; trusted_config_paths not exercised"
fi

# --- Case J: corepack shims for mise's node installs --------------------------
# node.corepack is set for future installs, and installs already present get
# `corepack enable` unless they already have both the yarn and pnpm shims. The
# installs are fakes under the sandbox HOME's mise data dir; their corepack is
# a stub that records the call and the path `command -v corepack` resolves to,
# and creates the shims beside itself (never beside what PATH resolves to, so a
# mutant that breaks the PATH prefix cannot write outside the sandbox). It never
# forwards to a real corepack.
if command -v mise >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  fake_node() {  # fake_node <home> <version> [shims|yarn-only|no-corepack|failing]
    local d="$1/.local/share/mise/installs/node/$2/bin"
    mkdir -p "$d"
    case "${3-}" in
      no-corepack) return 0 ;;
      failing) printf '#!/bin/sh\nexit 1\n' >"$d/corepack" ;;
      *) printf '#!/bin/sh\necho "$*" >>"$(dirname "$0")/corepack.calls"\ncommand -v corepack >"$(dirname "$0")/corepack.which"\ntouch "$(dirname "$0")/yarn" "$(dirname "$0")/pnpm"\n' >"$d/corepack" ;;
    esac
    chmod +x "$d/corepack"
    case "${3-}" in
      shims) : >"$d/yarn"; : >"$d/pnpm" ;;
      yarn-only) : >"$d/yarn" ;;
    esac
  }
  nbin() { printf '%s\n' "$1/.local/share/mise/installs/node/$2/bin"; }
  # Assumes mise writes the setting as `corepack = true` under [settings.node].
  corepack_lines() {  # corepack_lines <home>
    grep -c '^corepack = true$' "$1/.config/mise/config.toml" 2>/dev/null || true
  }
  called() {  # called <home> <version>; 0 if corepack enable ran there
    [ -e "$(nbin "$1" "$2")/corepack.calls" ]
  }

  home_j="$sandbox/home_j"; mkdir -p "$home_j"
  fake_node "$home_j" 96.0.0 no-corepack
  fake_node "$home_j" 97.0.0 yarn-only
  fake_node "$home_j" 97.5.0 failing
  fake_node "$home_j" 98.0.0
  fake_node "$home_j" 99.0.0 shims
  run_capture_stderr "$repo/bin/deploy.sh" "$home_j" "$sandbox/j.err"; rc_j=$?
  run "$repo/bin/deploy.sh" "$home_j"
  check "node.corepack is true after deploy (set once, not duplicated)" \
    "$(if [ "$(sandboxed "$home_j" mise settings get node.corepack 2>/dev/null)" = true ] \
         && [ "$(corepack_lines "$home_j")" -eq 1 ]
       then echo 0; else echo 1; fi)"
  check "deploy exits 0 with a failing corepack and a node without corepack" \
    "$(if [ "$rc_j" -eq 0 ]; then echo 0; else echo 1; fi)"
  check "an install without shims gets exactly one corepack enable across two runs" \
    "$(if [ -e "$(nbin "$home_j" 98.0.0)/yarn" ] \
         && [ "$(cat "$(nbin "$home_j" 98.0.0)/corepack.calls" 2>/dev/null)" = enable ]
       then echo 0; else echo 1; fi)"
  check "corepack enable runs with the install's own corepack first on PATH" \
    "$(if [ "$(cat "$(nbin "$home_j" 98.0.0)/corepack.which" 2>/dev/null)" = "$(nbin "$home_j" 98.0.0)/corepack" ]
       then echo 0; else echo 1; fi)"
  check "an install with yarn but no pnpm shim is enabled" \
    "$(if called "$home_j" 97.0.0 && [ -e "$(nbin "$home_j" 97.0.0)/pnpm" ]; then echo 0; else echo 1; fi)"
  check "an install that already has both shims is left alone" \
    "$(if ! called "$home_j" 99.0.0; then echo 0; else echo 1; fi)"
  check "a node without corepack is reported, and the other installs are still processed" \
    "$(if grep -qF "no corepack in $(cd "$(nbin "$home_j" 96.0.0)/.." && pwd -P)" "$sandbox/j.err" \
         && called "$home_j" 97.0.0 && called "$home_j" 98.0.0
       then echo 0; else echo 1; fi)"
  check "a failing corepack enable is reported and does not stop the other installs" \
    "$(if grep -qF "corepack enable failed in $(cd "$(nbin "$home_j" 97.5.0)/.." && pwd -P)" "$sandbox/j.err" \
         && called "$home_j" 97.0.0 && called "$home_j" 98.0.0
       then echo 0; else echo 1; fi)"

  home_j0="$sandbox/home_j0"; mkdir -p "$home_j0"
  run "$repo/bin/deploy.sh" "$home_j0"; rc_j0=$?
  check "deploy succeeds when no node is installed" \
    "$(if [ "$rc_j0" -eq 0 ]; then echo 0; else echo 1; fi)"

  # Controls. Each mutant replaces one line with a no-op (or an edited form) and
  # must differ from the script under test; a syntax error would make every
  # control pass vacuously, so each run is also required to exit 0.
  mutate() {  # mutate <out> <sed-expr>
    sed "$2" "$repo/bin/deploy.sh" >"$repo/bin/$1"
    chmod +x "$repo/bin/$1"
  }
  mutate deploy-nocp.sh 's|^        mise settings set node.corepack true$|        :|'
  mutate deploy-reenable.sh 's|^            if \[ -e "${__node_dir}/bin/yarn" \] \&\& \[ -e "${__node_dir}/bin/pnpm" \]; then$|            if false; then|'
  mutate deploy-yarnonly.sh 's|^            if \[ -e "${__node_dir}/bin/yarn" \] \&\& \[ -e "${__node_dir}/bin/pnpm" \]; then$|            if [ -e "${__node_dir}/bin/yarn" ]; then|'
  mutate deploy-nopath.sh 's|PATH="${__node_dir}/bin:${PATH}" "${__node_dir}/bin/corepack" enable|"${__node_dir}/bin/corepack" enable|'
  check "the controls really differ from the script under test" \
    "$(ok=0; for m in nocp reenable yarnonly nopath; do
         cmp -s "$repo/bin/deploy.sh" "$repo/bin/deploy-$m.sh" && ok=1
       done; echo "$ok")"
  home_j2="$sandbox/home_j2"; mkdir -p "$home_j2"
  fake_node "$home_j2" 98.0.0
  run "$repo/bin/deploy-nocp.sh" "$home_j2"; rc_nocp=$?
  check "without the setting line, node.corepack stays off (and the rest still ran)" \
    "$(if [ "$rc_nocp" -eq 0 ] && called "$home_j2" 98.0.0 \
         && [ "$(sandboxed "$home_j2" mise settings get node.corepack 2>/dev/null)" != true ]
       then echo 0; else echo 1; fi)"
  home_j3="$sandbox/home_j3"; mkdir -p "$home_j3"
  fake_node "$home_j3" 99.0.0 shims
  run "$repo/bin/deploy-reenable.sh" "$home_j3"; rc_re=$?
  check "without the shim check, an enabled install would be enabled again" \
    "$(if [ "$rc_re" -eq 0 ] && called "$home_j3" 99.0.0; then echo 0; else echo 1; fi)"
  home_j4="$sandbox/home_j4"; mkdir -p "$home_j4"
  fake_node "$home_j4" 97.0.0 yarn-only
  run "$repo/bin/deploy-yarnonly.sh" "$home_j4"; rc_yo=$?
  check "with a yarn-only check, an install missing the pnpm shim would be skipped" \
    "$(if [ "$rc_yo" -eq 0 ] && ! called "$home_j4" 97.0.0; then echo 0; else echo 1; fi)"
  home_j5="$sandbox/home_j5"; mkdir -p "$home_j5"
  fake_node "$home_j5" 98.0.0
  run "$repo/bin/deploy-nopath.sh" "$home_j5"; rc_np=$?
  check "without the PATH prefix, corepack would not resolve to the install's own" \
    "$(if [ "$rc_np" -eq 0 ] && called "$home_j5" 98.0.0 \
         && [ "$(cat "$(nbin "$home_j5" 98.0.0)/corepack.which" 2>/dev/null)" != "$(nbin "$home_j5" 98.0.0)/corepack" ]
       then echo 0; else echo 1; fi)"
else
  echo "skip: mise or jq not available; corepack shims not exercised"
fi

# --- Case I: githooks/post-merge is linked into the checkout's hooks/ --------
# Only in a git checkout (the minimal one above has no .git, so the block is a
# no-op there; that holds because sandbox.sh unsets GIT_DIR, which would
# otherwise make git look at another repo). The link goes where `git rev-parse --git-path` says, which from a
# linked worktree is the common dir's hooks/. A hand-written hook that is not a
# symlink is kept and reported; the control drops that check and clobbers it.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
grepo="$sandbox/grepo"
mkdir -p "$grepo/bin" "$grepo/rc" "$grepo/dot/example" "$grepo/githooks"
: >"$grepo/rc/bashrc"
: >"$grepo/dot/example/file"
printf '#!/bin/sh\n' >"$grepo/githooks/post-merge"
cp "$src" "$grepo/bin/deploy.sh"
chmod +x "$grepo/bin/deploy.sh" "$grepo/githooks/post-merge"
grepo="$(cd "$grepo" && pwd -P)"
git -C "$grepo" init -q -b main
git -C "$grepo" add -A
git -C "$grepo" commit -q -m init
ghook="$grepo/.git/hooks/post-merge"
links_to() {  # links_to <link> <target>
  [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]
}

home_i="$sandbox/home_i"; mkdir -p "$home_i"
rm -f "$ghook"
run "$grepo/bin/deploy.sh" "$home_i"
# The re-run must see its own link as a symlink, not resolve it to the target
# (a regular file) and report a hand-written hook it does not have.
stderr_i0="$sandbox/stderr_i0"
run_capture_stderr "$grepo/bin/deploy.sh" "$home_i" "$stderr_i0"
check "deploy.sh links githooks/post-merge into .git/hooks, idempotently and quietly" \
  "$(if links_to "$ghook" "$grepo/githooks/post-merge" && ! grep -qF 'post-merge' "$stderr_i0"
     then echo 0; else echo 1; fi)"

ln -snf "$sandbox/elsewhere/githooks/post-merge" "$ghook"
stderr_i1="$sandbox/stderr_i1"
run_capture_stderr "$grepo/bin/deploy.sh" "$home_i" "$stderr_i1"
check "a stale symlink (another checkout's githooks/post-merge) is replaced, with a note" \
  "$(if links_to "$ghook" "$grepo/githooks/post-merge" && grep -qF 're-pointing' "$stderr_i1"
     then echo 0; else echo 1; fi)"

# A symlink to something that is not a githooks/post-merge (a hook manager's)
# is not ours: kept, and the skip is reported.
ln -snf "$sandbox/manager/dispatch" "$ghook"
stderr_i2="$sandbox/stderr_i2"
run_capture_stderr "$grepo/bin/deploy.sh" "$home_i" "$stderr_i2"
check "a symlink to a foreign target is kept and the skip is reported" \
  "$(if links_to "$ghook" "$sandbox/manager/dispatch" && grep -qF 'skipped installing' "$stderr_i2"
     then echo 0; else echo 1; fi)"
sed 's|; __hook_install=0 ;;$| ;;|' "$grepo/bin/deploy.sh" >"$grepo/bin/deploy-clobber-link.sh"
chmod +x "$grepo/bin/deploy-clobber-link.sh"
check "the foreign-symlink control really differs from the script under test" \
  "$(if ! cmp -s "$grepo/bin/deploy.sh" "$grepo/bin/deploy-clobber-link.sh"; then echo 0; else echo 1; fi)"
run "$grepo/bin/deploy-clobber-link.sh" "$home_i"
check "without the foreign-symlink skip, the manager's link would be replaced" \
  "$(if links_to "$ghook" "$grepo/githooks/post-merge"; then echo 0; else echo 1; fi)"

rm -f "$ghook"; printf '# hand-written hook\n' >"$ghook"
stderr_i="$sandbox/stderr_i"
run_capture_stderr "$grepo/bin/deploy.sh" "$home_i" "$stderr_i"
check "an existing non-symlink post-merge is kept and the skip is reported" \
  "$(if [ ! -L "$ghook" ] && [ "$(cat "$ghook")" = '# hand-written hook' ] \
       && grep -qF 'is not a symlink; skipped' "$stderr_i"
     then echo 0; else echo 1; fi)"
sed 's|^        if \[ -e "${__hook_dst}" \] && \[ ! -L "${__hook_dst}" \]; then$|        if false; then|' \
  "$grepo/bin/deploy.sh" >"$grepo/bin/deploy-clobber-hook.sh"
chmod +x "$grepo/bin/deploy-clobber-hook.sh"
check "the clobber control really differs from the script under test" \
  "$(if ! cmp -s "$grepo/bin/deploy.sh" "$grepo/bin/deploy-clobber-hook.sh"; then echo 0; else echo 1; fi)"
run "$grepo/bin/deploy-clobber-hook.sh" "$home_i"
check "without the non-symlink check, the hand-written hook would be replaced" \
  "$(if [ -L "$ghook" ]; then echo 0; else echo 1; fi)"

# core.hooksPath wins over .git/hooks, and a missing dir is created (mkdir -p).
chooks="$sandbox/custom-hooks/sub"
git -C "$grepo" config core.hooksPath "$chooks"
rm -f "$ghook"
run "$grepo/bin/deploy.sh" "$home_i"
check "with core.hooksPath set, the missing dir is created and holds the link" \
  "$(if [ -d "$chooks" ] && links_to "$chooks/post-merge" "$grepo/githooks/post-merge" && [ ! -e "$ghook" ]
     then echo 0; else echo 1; fi)"
git -C "$grepo" config --unset core.hooksPath

# From a linked worktree checkout: the link lands in the common dir's hooks/
# (where git reads hooks for every worktree), pointing at that checkout.
rm -f "$ghook"
gwt="$sandbox/grepo-wt"
git -C "$grepo" worktree add -q -b wt "$gwt"
gwt="$(cd "$gwt" && pwd -P)"
run "$gwt/bin/deploy.sh" "$home_i"
check "from a linked worktree, the hook is linked into the common dir's hooks/" \
  "$(if links_to "$ghook" "$gwt/githooks/post-merge"; then echo 0; else echo 1; fi)"

exit "$fail"
