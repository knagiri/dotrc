# shellcheck shell=bash
#
# issue-repo.sh -- the repository that holds agent-filed issues (observations,
# groups, tasks), as OWNER/NAME.
#
# Sets ISSUE_REPO from the machine-local setting ISSUE_REPO
# (bin/lib/dotrc-config.sh: the environment first, then the dotrc config
# file). There is no default: the name is not kept in the checkout. When the
# setting is missing, is not of the form OWNER/NAME, or the config file exists
# but cannot be read, it says so on stderr and exits the sourcing script with
# status 3, before any gh call.
#
# issue_repo_require_private -- exits the calling script with status 5 unless
# `gh repo view` reports the issue repo as private. Anything else (public, a
# failed or unreadable lookup, unexpected output) stops too, with the reason on
# stderr: the check fails closed. Needs bin/lib/gh-mise.sh sourced and
# gh_mise_use called first. It makes one gh call and changes nothing.
#
# The check cannot see who has access: that the repo invites no collaborators
# is an assumption (docs/design/agent-issue-workflow.md).

# shellcheck source=bin/lib/dotrc-config.sh
. "$(dirname "${BASH_SOURCE[0]}")/dotrc-config.sh"

ISSUE_REPO="$(dotrc_config ISSUE_REPO)" || exit 3
if [[ ! "$ISSUE_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "issue-repo: ISSUE_REPO must be OWNER/NAME (got: $ISSUE_REPO)" >&2
  exit 3
fi

issue_repo_require_private() {
  local out last rc=0
  out="$(gh_mise repo view "$ISSUE_REPO" --json isPrivate --jq .isPrivate 2>&1)" || rc=$?
  last="${out##*$'\n'}"
  if [ "$rc" -ne 0 ]; then
    echo "issue-repo: cannot verify that $ISSUE_REPO is private (gh exited $rc): ${last:-no output}" >&2
    exit 5
  fi
  if [ "$last" != true ]; then
    echo "issue-repo: $ISSUE_REPO is not private (isPrivate: ${last:-no output}); refusing to use it" >&2
    exit 5
  fi
}
