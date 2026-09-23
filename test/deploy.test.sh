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
src="$here/../bin/deploy.sh"
fail=0

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

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

# --- Case E: dot/claude goes to both config dirs ----------------------------
# ~/.claude is the default account's config dir and ~/.claude-personal the one
# dotrc's mise.local.toml selects. Each reads its own rules/skills/settings, so
# both must get the links, and a re-run must leave them links (not a nested
# rules/rules, which is what `ln -snvf` onto an existing real dir would make).
# The control is the same script with the personal destination removed.
sed 's|^MergeLinkMap\["claude"\]=.*$|MergeLinkMap["claude"]="${HOME}/.claude"|' \
  "$repo/bin/deploy.sh" >"$repo/bin/deploy-onedir.sh"
chmod +x "$repo/bin/deploy-onedir.sh"
check "the one-dir control really differs from the script under test" \
  "$(if ! cmp -s "$repo/bin/deploy.sh" "$repo/bin/deploy-onedir.sh"; then echo 0; else echo 1; fi)"

linked_to_rules() {  # linked_to_rules <path>
  [ -L "$1" ] && [ "$(readlink "$1")" = "$repo/dot/claude/rules" ]
}
home_e="$sandbox/home_e"; mkdir -p "$home_e"
run "$repo/bin/deploy.sh" "$home_e"
run "$repo/bin/deploy.sh" "$home_e"
check "dot/claude entries are linked into ~/.claude and ~/.claude-personal, idempotently" \
  "$(if linked_to_rules "$home_e/.claude/rules" && linked_to_rules "$home_e/.claude-personal/rules" \
       && [ ! -e "$repo/dot/claude/rules/rules" ]
     then echo 0; else echo 1; fi)"
home_e2="$sandbox/home_e2"; mkdir -p "$home_e2"
run "$repo/bin/deploy-onedir.sh" "$home_e2"
check "without the personal destination, ~/.claude-personal gets nothing" \
  "$(if linked_to_rules "$home_e2/.claude/rules" && [ ! -e "$home_e2/.claude-personal/rules" ]
     then echo 0; else echo 1; fi)"

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

# --- Case H: mise.local.toml template ---------------------------------------
# Selects the personal config dir for claude runs under the checkout. Created
# when absent; never overwritten, since the file may have been edited or
# deliberately emptied on a machine that needs no account split. The control
# drops the absence check.
home_h="$sandbox/home_h"; mkdir -p "$home_h"
rm -f "$repo/mise.local.toml"
run "$repo/bin/deploy.sh" "$home_h"
check "a missing mise.local.toml is created selecting ~/.claude-personal" \
  "$(if grep -qxF 'CLAUDE_CONFIG_DIR = "{{env.HOME}}/.claude-personal"' "$repo/mise.local.toml" 2>/dev/null
     then echo 0; else echo 1; fi)"
printf '# hand-edited\n' >"$repo/mise.local.toml"
run "$repo/bin/deploy.sh" "$home_h"
check "a re-run leaves an existing mise.local.toml alone" \
  "$(if [ "$(cat "$repo/mise.local.toml")" = '# hand-edited' ]; then echo 0; else echo 1; fi)"
sed 's|^if \[ ! -e "${REPO_DIR}/mise.local.toml" \]; then$|if true; then|' \
  "$repo/bin/deploy.sh" >"$repo/bin/deploy-clobber-local.sh"
chmod +x "$repo/bin/deploy-clobber-local.sh"
run "$repo/bin/deploy-clobber-local.sh" "$home_h"
check "without the absence check, an existing mise.local.toml would be overwritten" \
  "$(if [ "$(cat "$repo/mise.local.toml")" != '# hand-edited' ]; then echo 0; else echo 1; fi)"
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

exit "$fail"
