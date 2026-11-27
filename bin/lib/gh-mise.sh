# shellcheck shell=bash
#
# gh-mise.sh -- run gh with the mise-provided environment of a given repo.
#
# Sourced by every gh wrapper in bin/. The personal PAT is deliberately kept
# out of every shell's env and read only here, at call time.
#
# Why not in the env: a background delegate (`claude --bg`) does not get its
# requester's env. It gets the env of whichever `claude --bg` call started the
# daemon for that config dir on demand -- only the requester's cwd crosses over
# -- and the daemon lives until its last client disconnects. So a GH_TOKEN in
# the env of that one caller is handed to every later delegate, stale after a
# rotation (gh: "The token in GH_TOKEN is invalid.") and leaking into repos that
# have no mise config at all, where hosts.yml is the right source. Loading the
# PAT from `mise.local.toml` put it in exactly that env via `mise activate`.
#
# So the repo reads the PAT from `mise.gh.local.toml`, which mise loads only
# when MISE_ENV=gh. Nothing sets that globally: shells, claude sessions, the
# daemon and its delegates carry no GH_TOKEN, and a bare `gh` (including one in
# another repo's scripts) falls back to hosts.yml. The wrappers set MISE_ENV=gh
# for the one `mise exec -C <repo> --` call below, which reads the config at
# call time and so always yields the current token. Anything else that needs
# the PAT -- e.g. a person running `gh pr create` by hand in this repo -- goes
# through a wrapper (gh-pr-create) or spells it `MISE_ENV=gh mise exec -- gh ...`.
#
# `-C "$dir"` carries both halves of the fix: mise resolves that directory's
# config AND runs gh there, so a wrapper anchored to its own repo rather than
# the caller's cwd gets that repo's token *and* has gh resolve that repo from its
# cwd (unless the caller passes -R).
# The cost is that gh's cwd is no longer the caller's, so a wrapper must
# absolutise any path it hands to gh -- otherwise a relative --body-file is
# resolved against the repo root and reads a different file, or none.
#
# With no mise on PATH the call degrades to a bare gh, still run in the same
# directory, so which repo a wrapper targets never depends on whether mise is
# installed. `cd` in a subshell rather than `env -C`, which is GNU-only.

# Directory gh runs in. Set with gh_mise_use; gh_mise refuses to run while it
# is empty (there is no lazy default: a silent fallback to the cwd's checkout
# would read exactly the config a caller may have meant to keep out).
gh_mise_dir=""

# gh_mise_use <dir> -- run every later gh_mise call in <dir>. An empty <dir>
# (e.g. a failed `$(gh_mise_main_root)`) is rejected with rc 1 and leaves
# gh_mise_dir empty, so gh_mise then refuses instead of picking a directory.
gh_mise_use() {
  if [ -z "${1:-}" ]; then
    gh_mise_dir=""
    echo "gh_mise_use: empty directory" >&2
    return 1
  fi
  gh_mise_dir="$1"
}

# gh_mise_repo_root [<dir>] -- toplevel of the checkout holding <dir> (cwd by
# default). Outside a checkout it yields <dir> itself, so gh still reports the
# missing repository exactly as it did before this indirection existed.
# The argument is optional by design: a caller in another file may pass one,
# which shellcheck cannot see from here.
# shellcheck disable=SC2120
gh_mise_repo_root() {
  local d="${1:-$PWD}" root
  root="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || true)"
  printf '%s\n' "${root:-$d}"
}

# gh_mise_main_root [<dir>] -- the MAIN working tree of the repo holding <dir>
# (cwd by default): the parent of `git rev-parse --git-common-dir`, which is the
# same for the main working tree and every linked worktree of it.
# Anchoring gh_mise there makes mise read the main checkout's config, its
# ancestors' and the global one, never a linked worktree's: a worktree's tracked
# mise.toml -- which any branch can change -- then cannot inject a GH_TOKEN or
# another GH_* into gh. The token is still resolved as for any wrapper: the
# main checkout's mise.gh.local.toml if it has one, otherwise hosts.yml.
# Call it so that a failure stops the caller; `gh_mise_use "$(...)"` would hide
# the rc (gh_mise_use rejects the empty result, but only the explicit form can
# report why):
#   root="$(gh_mise_main_root)" || { echo "<why>" >&2; exit 1; }
#   gh_mise_use "$root"
# gh then also runs in the main checkout, not the worktree: a `gh pr view`
# without a PR number targets the main checkout's branch, and a relative path is
# resolved against the main root, so callers pass the PR number explicitly and
# absolutise paths.
# Returns 1 without output when <dir> is not in a checkout, or when the common
# dir is not `<toplevel>/.git` of a working tree: a submodule, a bare repo
# (even one inside a checkout, or its linked worktree) and a --separate-git-dir
# checkout all fail. There is no fallback, since falling back to <dir> would
# read exactly the config this function exists to keep out.
# The argument is optional by design: a caller in another file may pass one,
# which shellcheck cannot see from here.
# shellcheck disable=SC2120
gh_mise_main_root() {
  local d="${1:-$PWD}" common main top
  common="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ "$(basename "$common")" = .git ] || return 1
  main="$(dirname "$common")"
  top="$(git -C "$main" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ "$top" = "$main" ] || return 1
  printf '%s\n' "$main"
}

# gh_mise <gh args...> -- what the wrappers call wherever they used to run `gh`.
# gh's exit code is propagated unchanged through both branches, which
# dot/claude/rules/issue-workflow.md §2 relies on for gh-issue-file.
gh_mise() {
  if [ -z "$gh_mise_dir" ]; then
    echo "gh_mise: no directory set; call gh_mise_use first" >&2
    return 1
  fi
  if command -v mise >/dev/null 2>&1; then
    MISE_ENV=gh mise exec -C "$gh_mise_dir" -- gh "$@"
  else
    ( cd "$gh_mise_dir" && exec gh "$@" )
  fi
}
