# shellcheck shell=bash
# Sourced at the top of every test/*.test.sh, before the test makes its own
# tmp dirs or stubs. It keeps a test from reaching the real environment:
#
#   - HOME points into a mktemp dir, so anything under ~ (~/.claude, mise's
#     ~/.local/state, ...) lands there. CLAUDE_CONFIG_DIR is unset for the same
#     reason: it would otherwise point a script at the real config dir no matter
#     what HOME is.
#   - CLAUDE_QUEUE_DB points into the same dir. It is what
#     src/claude-queue/internal/db/path.go reads before falling back to
#     ~/.claude/session-queue.db, so a test that reaches a real claude-queue
#     still cannot write the real ledger.
#   - PATH loses dotrc's bin/ -- both this checkout's and the main working
#     tree's (the one deploy.sh puts on PATH; from a linked worktree the two
#     differ) -- and any other directory holding a claude-queue. A test reaches
#     a script under test by its path, and puts its own stub dir in front of
#     PATH as before.
#
# Call sandbox_assert right after sourcing: it fails the test if any of the
# above did not take. A test that sets its own EXIT trap calls sandbox_cleanup
# from it, since a later `trap ... EXIT` replaces the one set here.

sandbox_dir="$(mktemp -d)" || { echo "FAIL: sandbox: mktemp -d failed"; exit 1; }
sandbox_cleanup() { rm -rf "$sandbox_dir"; }
trap sandbox_cleanup EXIT

sandbox_real_home="$HOME"
export HOME="$sandbox_dir/home"
mkdir -p "$HOME"
export CLAUDE_QUEUE_DB="$sandbox_dir/session-queue.db"
unset CLAUDE_CONFIG_DIR

# dotrc bin/ dirs to drop, resolved from this file's location rather than cwd.
sandbox_bindirs=()
sandbox_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
sandbox_bindirs+=("$sandbox_repo/bin")
if sandbox_common="$(git -C "$sandbox_repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
  sandbox_bindirs+=("$(dirname "$sandbox_common")/bin")
fi

sandbox_is_dropped() { # <PATH entry>
  local e r b
  e="$1"
  [ -n "$e" ] || return 0
  r="$(cd "$e" 2>/dev/null && pwd -P)" || r="$e"
  for b in "${sandbox_bindirs[@]}"; do
    [ "$r" = "$b" ] && return 0
  done
  [ -x "$e/claude-queue" ]
}

sandbox_path=""
IFS=: read -ra sandbox_entries <<<"$PATH"
for sandbox_e in "${sandbox_entries[@]}"; do
  sandbox_is_dropped "$sandbox_e" && continue
  sandbox_path="${sandbox_path:+$sandbox_path:}$sandbox_e"
done
export PATH="$sandbox_path"
unset sandbox_path sandbox_entries sandbox_e sandbox_common

sandbox_assert() {
  local bad=0 cq e
  local -a entries
  case "$HOME" in
    "$sandbox_dir"/*) ;;
    *) echo "FAIL: sandbox: HOME is $HOME, not under $sandbox_dir"; bad=1 ;;
  esac
  [ "$HOME" != "$sandbox_real_home" ] \
    || { echo "FAIL: sandbox: HOME is still the real home"; bad=1; }
  case "${CLAUDE_QUEUE_DB:-}" in
    "$sandbox_dir"/*) ;;
    *) echo "FAIL: sandbox: CLAUDE_QUEUE_DB is '${CLAUDE_QUEUE_DB:-}', not under $sandbox_dir"; bad=1 ;;
  esac
  [ -z "${CLAUDE_CONFIG_DIR+x}" ] \
    || { echo "FAIL: sandbox: CLAUDE_CONFIG_DIR is set ($CLAUDE_CONFIG_DIR)"; bad=1; }
  if cq="$(command -v claude-queue)"; then
    echo "FAIL: sandbox: claude-queue resolves to $cq; want it absent until a test stubs it"; bad=1
  fi
  IFS=: read -ra entries <<<"$PATH"
  for e in "${entries[@]}"; do
    if [ -n "$e" ] && sandbox_is_dropped "$e"; then
      echo "FAIL: sandbox: PATH still holds $e"; bad=1
    fi
  done
  [ "$bad" = 0 ] || exit 1
}
