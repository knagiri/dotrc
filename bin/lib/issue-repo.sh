# shellcheck shell=bash
#
# issue-repo.sh -- the repository that holds agent-filed issues (observations,
# groups, tasks), as OWNER/NAME.
#
# Sets ISSUE_REPO from the machine-local setting ISSUE_REPO
# (bin/lib/dotrc-config.sh: the environment first, then the dotrc config
# file). There is no default: the name is not kept in the checkout. When the
# setting is missing, or is not of the form OWNER/NAME, it says so on stderr
# and exits the sourcing script with status 3, before any gh call.
#
# Assumes the repo is private and invites no collaborators.

# shellcheck source=bin/lib/dotrc-config.sh
. "$(dirname "${BASH_SOURCE[0]}")/dotrc-config.sh"

ISSUE_REPO="$(dotrc_config ISSUE_REPO)" || exit 3
if [[ ! "$ISSUE_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "issue-repo: ISSUE_REPO must be OWNER/NAME (got: $ISSUE_REPO)" >&2
  exit 3
fi
