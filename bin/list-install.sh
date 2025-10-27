#!/usr/bin/env sh

set -u

commands=( \
    "git" "docker" "docker-compose" \
    "gpg" "curl"\
    "aws" \
    "rustc" "rustup" "cargo" \
    "node" "volta" \
    "pyenv" "poetry" \
    "go" \
    "eza" "bat" "fd" "rg" "fzf" \
    "nvim" "tmux" \
)

function is_exist_command {
    if [ -z "$(type $1 2>/dev/null)" ]; then
        return 1
    fi
    return 0
}

out=""
for _cmd in ${commands[@]}; do
    is_exist_command ${_cmd} || out="${out} ${_cmd}"
done
echo $out
