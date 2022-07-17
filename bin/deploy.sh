#/usr/bin/env sh

# path/to/repo
REPO_DIR=$(realpath $(dirname $(dirname $0)))

# path/to/repo/bin
export __bin_path="${REPO_DIR}/bin"
# path/to/repo/rc/bashrc
export __bashrc_path="${REPO_DIR}/rc/bashrc"

# Bashrc
cat - << 'EOF' | envsubst '${__bashrc_path} ${__bin_path}' >> ${HOME}/.bashrc
# DOTRC ==================================
# bashrc@dotrc
source "${__bashrc_path}"

# bin-path@dotrc
case ":${PATH}:" in
    *:${__bin_path}:*)
        ;;
    *)
        export PATH="${__bin_path}:$PATH"
        ;;
esac
# ========================================
EOF

#echo -e "\n# bashrc@dotrc\nsource $__bashrc_path" >> ${HOME}/.bashrc

# dotfiles
# path/to/repo/dot
__dotfiles_path="${REPO_DIR}/dot"
function dotlink {
    local exsist syml
    exist=$1
    syml=$2
    ln -snv $1 $2
}

declare -A CustomLocationMap
# Default: `dot/example` is linked to `$HOME/.example`.
# If you need to change the link destination,
#  specify as follows:
#CustomLocationMap["example"]="/path/to/else/.example"
# The specified value must include the symlink name.
CustomLocationMap["git"]="${HOME}/.config/git"
CustomLocationMap["nvim"]="${HOME}/.config/nvim"

for dotname in $(ls "$__dotfiles_path"); do
    if [ -z "${CustomLocationMap["${dotname}"]}" ]; then
        dotlink "${__dotfiles_path}/${dotname}" "${HOME}/.${dotname}"
    else
        dotlink "${__dotfiles_path}/${dotname}" "${CustomLocationMap["${dotname}"]}"
    fi
done
