#!/usr/bin/env sh

set -u

commands=( \
    "git" "docker" \
    "gpg" "curl"\
    "rustc" "rustup" "cargo" \
    "node" "fnm"\
    "python3" "poetry" \
    "exa" "bat" "fd" "fzf" \
)

function is_exist_command {
    if [ -z "$($1 --version 2> /dev/null)" ]; then
        return 1
    fi
    return 0
}

out=""
for _cmd in ${commands[@]}; do
    is_exist_command ${_cmd} || out="${out} ${_cmd}"
done
echo $out
