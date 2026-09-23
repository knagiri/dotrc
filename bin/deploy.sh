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
# claude: ~/.claude is the default account's config dir and ~/.claude-personal
# the one dotrc's mise.local.toml selects through CLAUDE_CONFIG_DIR. CLAUDE.md,
# rules, skills, agents and settings.json are all read per config dir, so both
# dirs get them. Plugins are not deployed: install them into each dir by hand.
MergeLinkMap["claude"]="${HOME}/.claude:${HOME}/.claude-personal"
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
# mise.local.toml created below and any config a worktree carries locally.
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

# Personal Claude Code account. mise.local.toml (gitignored, always loaded)
# points CLAUDE_CONFIG_DIR at ~/.claude-personal for everything run under the
# checkout. Created only when absent, so an edited or emptied file stays as is.
# Why it is local rather than tracked: docs/design/mise-config-layering.md.
if [ ! -e "${REPO_DIR}/mise.local.toml" ]; then
    printf '%s\n' '# Personal Claude Code account for dotrc (see docs/design/mise-config-layering.md)' \
        '[env]' 'CLAUDE_CONFIG_DIR = "{{env.HOME}}/.claude-personal"' >"${REPO_DIR}/mise.local.toml"
fi

# Build claude-queue if Go is available
if command -v go >/dev/null 2>&1 && [ -d "${REPO_DIR}/src/claude-queue" ]; then
    (cd "${REPO_DIR}/src/claude-queue" && make install)
fi
