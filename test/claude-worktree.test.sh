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

exit "$fail"
