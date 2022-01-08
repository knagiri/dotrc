#/usr/bin/env sh

__script_dir_path=$(dirname $0) # path/to/repo/bin
__bashrc_path=$(realpath ${__script_dir_path}/../rc/bashrc)

echo -e "\n# bashrc@dotrc\nsource $__bashrc_path" >> ${HOME}/.bashrc
