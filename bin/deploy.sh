#!/usr/bin/env bash

# path/to/repo
REPO_DIR=$(realpath $(dirname $(dirname $0)))

# path/to/repo/bin
export __bin_path="${REPO_DIR}/bin"
# path/to/repo/rc/bashrc
export __bashrc_path="${REPO_DIR}/rc/bashrc"

# Bashrc
# deploy.sh is meant to be re-run (that is how a new dot/ top-level entry gets
# expanded), and the symlink loop below is idempotent through `ln -snvf`. This
# append was the one part that was not, so it guards itself on the block's own
# first line. The `guard@dotrc` tags mark the lines test/deploy.test.sh strips
# to build the guard-less control (grep also drops this comment line itself,
# since it contains the tag string too; that is harmless here because only a
# comment line is removed).
# -s on grep: a first-time ~/.bashrc does not exist yet, and its absence must
# read as "not installed", not as an error on stderr.
# The marker match is a literal string, not path-aware: it also reads as
# "installed" when an existing block points at a different checkout (moved
# repo path, or a second checkout sharing $HOME), so the guard skips silently
# in that case too. The stderr note below is the deliberate mitigation --
# surface the skip so a stale block does not go unnoticed instead of trying to
# detect "same checkout" (dotrc-deploy.md §4 has the fuller rationale).
__dotrc_marker='# DOTRC =================================='
if ! grep -qsF "${__dotrc_marker}" "${HOME}/.bashrc"; then  # guard@dotrc
cat - << 'EOF' | envsubst '${__bashrc_path} ${__bin_path}' >> ${HOME}/.bashrc
# DOTRC ==================================
# bin-path@dotrc
case ":${PATH}:" in
    *:${__bin_path}:*)
        ;;
    *)
        export PATH="${__bin_path}:$PATH"
        ;;
esac

# bashrc@dotrc
source "${__bashrc_path}"
# ========================================
EOF
else                                                         # guard@dotrc
  echo "deploy.sh: DOTRC block already in ${HOME}/.bashrc; skipped (it may point at another checkout)" >&2  # guard@dotrc
fi  # guard@dotrc

#echo -e "\n# bashrc@dotrc\nsource $__bashrc_path" >> ${HOME}/.bashrc

# dotfiles
# path/to/repo/dot
__dotfiles_path="${REPO_DIR}/dot"
function dotlink {
    local exsist syml
    exist=$1
    syml=$2
    ln -snvf $1 $2
}

declare -A CustomLocationMap
# Default: `dot/example` is linked to `$HOME/.example`.
# If you need to change the link destination,
#  specify as follows:
#CustomLocationMap["example"]="/path/to/else/.example"
# The specified value must include the symlink name.
CustomLocationMap["git"]="${HOME}/.config/git"
CustomLocationMap["nvim"]="${HOME}/.config/nvim"

declare -A MergeLinkMap
# For directories where individual files should be linked INTO
# an existing directory (instead of replacing the whole directory).
# Several destinations are separated by ':' and each gets the same links.
#
# claude: CLAUDE.md, rules, skills, agents and settings.json go into ~/.claude.
# Plugins are not deployed: install them by hand.
MergeLinkMap["claude"]="${HOME}/.claude"
# ~/.config/systemd and its user/ subdirectory already exist as real directories
# (systemd keeps its own state there, e.g. *.target.wants), so a whole-directory
# link would land inside them instead of replacing them.
MergeLinkMap["systemd-user"]="${HOME}/.config/systemd/user"

for dotname in $(ls "$__dotfiles_path"); do
    if [ -n "${MergeLinkMap["${dotname}"]}" ]; then
        IFS=: read -r -a merge_targets <<<"${MergeLinkMap["${dotname}"]}"
        for merge_target in "${merge_targets[@]}"; do
            mkdir -p "$merge_target"
            for file in "${__dotfiles_path}/${dotname}"/*; do
                dotlink "$file" "${merge_target}/$(basename "$file")"
            done
        done
    elif [ -n "${CustomLocationMap["${dotname}"]}" ]; then
        dotlink "${__dotfiles_path}/${dotname}" "${CustomLocationMap["${dotname}"]}"
    else
        dotlink "${__dotfiles_path}/${dotname}" "${HOME}/.${dotname}"
    fi
done

# mise: trust this checkout's configs, including those of every worktree under
# it. dotrc tracks no mise config of its own; what needs trust is the local
# mise.gh.local.toml created below and any config a worktree carries locally.
# `mise trust` on the checkout does not cover a config in a subdirectory
# (measured: the checkout read trusted, <checkout>/.worktrees/<name>/mise.toml
# still untrusted, so `mise exec -C` there failed). trusted_config_paths
# matches by path prefix, which covers both. `mise settings add` appends a
# duplicate on every call, hence the check first.
if command -v mise >/dev/null 2>&1; then
    if ! mise settings get trusted_config_paths 2>/dev/null | grep -qF "\"${REPO_DIR}\""; then
        mise settings add trusted_config_paths "${REPO_DIR}"
    fi
fi

# Personal GitHub PAT. mise.gh.local.toml (gitignored, read only under
# MISE_ENV=gh -- see bin/lib/gh-mise.sh) loads ~/.config/gh/personal.env. Both
# are created only when absent, so a re-run never touches a filled-in token.
# The template holds the keys alone; an empty GH_TOKEN makes gh fall back to
# hosts.yml, and a missing personal.env does not make mise fail either.
__personal_env="${HOME}/.config/gh/personal.env"
if [ ! -e "${__personal_env}" ]; then
    mkdir -p "$(dirname "${__personal_env}")"
    (umask 077 && printf '%s\n' '# Personal GitHub PAT for dotrc (read via mise.gh.local.toml)' 'GH_TOKEN=' >"${__personal_env}")
    chmod 600 "${__personal_env}"
    echo "deploy.sh: created ${__personal_env}; fill in GH_TOKEN" >&2
fi
if [ ! -e "${REPO_DIR}/mise.gh.local.toml" ]; then
    printf '[env]\n_.file = "~/.config/gh/personal.env"\n' >"${REPO_DIR}/mise.gh.local.toml"
fi

# git hook: githooks/post-merge rebuilds bin/claude-queue after a pull that
# changes src/claude-queue. Linked as a symlink so later edits to the hook take
# effect without a re-run. `--git-path` resolves to the common dir's hooks/
# even from a linked worktree (hooks are shared across worktrees), and to
# core.hooksPath when that is set, i.e. wherever git actually reads hooks from.
# If core.hooksPath is a dir shared by several repos, the hook runs in all of
# them; it exits at once where src/claude-queue did not change.
# Existing hooks are left alone unless they are our own link: a regular file
# and a symlink that does not end in githooks/post-merge (a hook manager's,
# say) are reported on stderr and skipped. A link to another checkout's
# githooks/post-merge is re-pointed here, with a note on stderr.
# The block does nothing, silently, when REPO_DIR has no .git (not a
# checkout; this also assumes GIT_DIR is not exported, since git would then
# look at that repo instead). If .git exists but rev-parse fails (dubious
# ownership, an old git), it warns and skips.
# The directory is resolved, not hooks/post-merge itself: --path-format=absolute
# resolves symlinks, so on a re-run it would return the link's target (this
# checkout's githooks/post-merge, a regular file) instead of the link.
if [ -e "${REPO_DIR}/.git" ]; then
    if __hook_dir="$(git -C "${REPO_DIR}" rev-parse --path-format=absolute --git-path hooks 2>/dev/null)"; then
        __hook_dst="${__hook_dir}/post-merge"
        if [ -e "${__hook_dst}" ] && [ ! -L "${__hook_dst}" ]; then
            echo "deploy.sh: ${__hook_dst} exists and is not a symlink; skipped installing githooks/post-merge" >&2
        else
            __hook_install=1
            if [ -L "${__hook_dst}" ]; then
                case "$(readlink "${__hook_dst}")" in
                    "${REPO_DIR}/githooks/post-merge") ;;
                    */githooks/post-merge) echo "deploy.sh: re-pointing ${__hook_dst} from $(readlink "${__hook_dst}") to ${REPO_DIR}/githooks/post-merge" >&2 ;;
                    *) echo "deploy.sh: ${__hook_dst} is a symlink to $(readlink "${__hook_dst}"), not a githooks/post-merge; skipped installing githooks/post-merge" >&2; __hook_install=0 ;;
                esac
            fi
            if [ "${__hook_install}" = 1 ]; then
                mkdir -p "${__hook_dir}"
                ln -snf "${REPO_DIR}/githooks/post-merge" "${__hook_dst}"
            fi
        fi
    else
        echo "deploy.sh: git rev-parse --git-path hooks failed in ${REPO_DIR}; skipped installing githooks/post-merge" >&2
    fi
fi

# Build claude-queue if Go is available
if command -v go >/dev/null 2>&1 && [ -d "${REPO_DIR}/src/claude-queue" ]; then
    (cd "${REPO_DIR}/src/claude-queue" && make install)
fi
