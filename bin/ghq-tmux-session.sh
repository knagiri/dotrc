#!/usr/bin/env bash

set -euo pipefail

# Ref: https://github.com/izumin5210/dotfiles/blob/aa17b272068491d24e7e52bd9fb58903c6947e4f/config/.bin/tm

changeSession() {
  local change
  [[ -n "${TMUX:-""}" ]] && change="switch-client" || change="attach-session"
  tmux $change -t "$1"
}

createSessionIfNeeded() {
  local name=$1
  [[ -n "$2" ]] && dir=$2 || dir=$(pwd)
  tmux list-sessions -F "#{session_name}" |
    grep -q -E "^${name}$" ||
    tmux new-session -d -c "${dir}" -s "${name}"
}

selectRepo() {
  echo "$(ghq root)/$(ghq list | fzf)"
}

main() {
  if [ $# -eq 1 ]; then
    createSessionIfNeeded $1
    changeSession $1
    exit
  fi

  local repo="$(selectRepo)"
  local session="$(echo "$repo" | awk -F/ '{ print $NF }')"

  createSessionIfNeeded $session $repo
  changeSession $session
}

main
