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
mkdir -p "$repo/bin" "$repo/rc" "$repo/dot/example"
: >"$repo/rc/bashrc"
: >"$repo/dot/example/file"
cp "$src" "$repo/bin/deploy.sh"
chmod +x "$repo/bin/deploy.sh"

# The control: the same script with its guard removed.
grep -v 'guard@dotrc' "$repo/bin/deploy.sh" >"$repo/bin/deploy-noguard.sh"
chmod +x "$repo/bin/deploy-noguard.sh"
check "the guard-less control really differs from the script under test" \
  "$(if ! cmp -s "$repo/bin/deploy.sh" "$repo/bin/deploy-noguard.sh"
     then echo 0; else echo 1; fi)"

run() {  # run <script> <home>
  ( HOME="$2" "$1" ) >/dev/null 2>&1
}

# Separate from run(): captures stderr instead of discarding it, to check the
# skip notice the guard prints on its else branch (a stale block pointing at
# another checkout should not go silently unnoticed -- dotrc-deploy.md §4).
run_capture_stderr() {  # run_capture_stderr <script> <home> <stderr-out-file>
  ( HOME="$2" "$1" ) >/dev/null 2>"$3"
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

exit "$fail"
