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
MergeLinkMap["claude"]="${HOME}/.claude"
# ~/.config/systemd and its user/ subdirectory already exist as real directories
# (systemd keeps its own state there, e.g. *.target.wants), so a whole-directory
# link would land inside them instead of replacing them.
MergeLinkMap["systemd-user"]="${HOME}/.config/systemd/user"

for dotname in $(ls "$__dotfiles_path"); do
    if [ -n "${MergeLinkMap["${dotname}"]}" ]; then
        merge_target="${MergeLinkMap["${dotname}"]}"
        mkdir -p "$merge_target"
        for file in "${__dotfiles_path}/${dotname}"/*; do
            dotlink "$file" "${merge_target}/$(basename "$file")"
        done
    elif [ -n "${CustomLocationMap["${dotname}"]}" ]; then
        dotlink "${__dotfiles_path}/${dotname}" "${CustomLocationMap["${dotname}"]}"
    else
        dotlink "${__dotfiles_path}/${dotname}" "${HOME}/.${dotname}"
    fi
done

# Build claude-queue if Go is available
if command -v go >/dev/null 2>&1 && [ -d "${REPO_DIR}/src/claude-queue" ]; then
    (cd "${REPO_DIR}/src/claude-queue" && make install)
fi
