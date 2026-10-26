# shellcheck shell=bash
# Sourced at the top of every test/*.test.sh, before the test makes its own
# tmp dirs or stubs. It keeps a test from reaching the real environment:
#
#   - HOME points into a mktemp dir, so anything resolved from ~ (~/.claude,
#     mise's ~/.local/state, ...) lands there. That holds only if nothing
#     overrides the HOME-derived default, so the variables that do are unset:
#     CLAUDE_CONFIG_DIR, XDG_{CONFIG,DATA,STATE,CACHE}_HOME, GIT_CONFIG_GLOBAL,
#     and the MISE_* path/config/env overrides (see sandbox_unset_vars). Left
#     set, they would point a script at the real dirs no matter what HOME is
#     (mise would keep writing ~/.local/state/mise/tracked-configs/ symlinks).
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

# Variables that override a HOME-derived location (or select a real mise
# profile). sandbox_assert checks each stays unset.
sandbox_unset_vars=(
  CLAUDE_CONFIG_DIR
  XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
  GIT_CONFIG_GLOBAL
  MISE_GLOBAL_CONFIG_FILE MISE_CONFIG_DIR MISE_DATA_DIR MISE_STATE_DIR
  MISE_CACHE_DIR MISE_TRUSTED_CONFIG_PATHS MISE_ENV
)
for sandbox_v in "${sandbox_unset_vars[@]}"; do unset "$sandbox_v"; done
unset sandbox_v

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
  local bad=0 cq e v
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
  for v in "${sandbox_unset_vars[@]}"; do
    if [ -n "${!v+x}" ]; then
      echo "FAIL: sandbox: $v is set (${!v})"; bad=1
    fi
  done
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
