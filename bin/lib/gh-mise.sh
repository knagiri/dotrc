# shellcheck shell=bash
#
# gh-mise.sh -- run gh with the mise-provided environment of a given repo.
#
# Sourced by every gh wrapper in bin/. `mise activate` installs a shell prompt
# hook, so it never fires in a non-interactive process: a delegated background
# agent (`claude --bg`, started through a background service that does not
# inherit the delegator's env) gets no GH_TOKEN from mise, and `gh pr create` /
# `gh-automerge` then fail with "Resource not accessible by personal access
# token" against whatever stale PAT gh's hosts.yml still holds. That cannot be
# fixed at launch time -- see the note in bin/claude-worktree about `claude --bg`
# not inheriting env -- so it is fixed here, inside the tools the agent calls.
# Measured in a worktree of this repo: a plain child sees an empty GH_TOKEN
# while `mise exec -C <repo> --` sees the one the repo's mise config supplies.
#
# `-C "$dir"` carries both halves of the fix: mise resolves that directory's
# config AND runs gh there, so a wrapper aimed at another repo (gh-issue-file
# --global) gets that repo's token *and* has gh resolve that repo from its cwd.
# The cost is that gh's cwd is no longer the caller's, so a wrapper must
# absolutise any path it hands to gh -- otherwise a relative --body-file is
# resolved against the repo root and reads a different file, or none.
#
# With no mise on PATH the call degrades to a bare gh, still run in the same
# directory, so which repo a wrapper targets never depends on whether mise is
# installed. `cd` in a subshell rather than `env -C`, which is GNU-only.

# Directory gh runs in. Set with gh_mise_use; resolved lazily from cwd if not.
gh_mise_dir=""

# gh_mise_use <dir> -- run every later gh_mise call in <dir>.
gh_mise_use() { gh_mise_dir="$1"; }

# gh_mise_repo_root [<dir>] -- toplevel of the checkout holding <dir> (cwd by
# default). Outside a checkout it yields <dir> itself, so gh still reports the
# missing repository exactly as it did before this indirection existed.
# The argument is optional by design: the only caller that passes one is
# gh-issue-file (another file), which shellcheck cannot see from here.
# shellcheck disable=SC2120
gh_mise_repo_root() {
  local d="${1:-$PWD}" root
  root="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || true)"
  printf '%s\n' "${root:-$d}"
}

# gh_mise <gh args...> -- what the wrappers call wherever they used to run `gh`.
# gh's exit code is propagated unchanged through both branches, which
# dot/claude/rules/issue-workflow.md §2 relies on for gh-issue-file.
gh_mise() {
  [ -n "$gh_mise_dir" ] || gh_mise_dir="$(gh_mise_repo_root)"
  if command -v mise >/dev/null 2>&1; then
    mise exec -C "$gh_mise_dir" -- gh "$@"
  else
    ( cd "$gh_mise_dir" && exec gh "$@" )
  fi
}
