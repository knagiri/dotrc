# shellcheck shell=bash
#
# dotrc-config.sh -- read dotrc's machine-local settings: values that differ
# per machine or must not be published, kept out of the checkout.
#
# File: ${XDG_CONFIG_HOME:-$HOME/.config}/dotrc/config (untracked).
# Format, one setting per line:
#   KEY=value
# - Leading and trailing whitespace of the line is dropped; so is whitespace
#   around the key and around the value.
# - Blank lines and lines starting with `#` are ignored. A line with no `=` is
#   ignored too.
# - The value is everything after the first `=`, taken literally: no quote
#   removal, no variable or command expansion.
# - If a key appears more than once, the last line wins.
#
# The file is parsed, never sourced: a read never executes anything in it, so
# whoever can write the file cannot make a reader run commands that no
# approval prompt has seen.
#
# dotrc_config <KEY> [<default>]
#   Prints the value of KEY. Lookup order: a non-empty environment variable
#   named KEY, then the file, then <default>. An empty value counts as unset.
#   With no default and no value, prints the file path and the line to add to
#   stderr and returns 1. A KEY that is not a shell identifier returns 2, and
#   so does a file that exists but cannot be read.

dotrc_config_file() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/dotrc/config"
}

dotrc_config() {
  local key="${1-}" file line k v found=""
  if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "dotrc_config: invalid key: $key" >&2
    return 2
  fi

  if [ -n "${!key-}" ]; then
    printf '%s\n' "${!key}"
    return 0
  fi

  file="$(dotrc_config_file)"
  if [ -e "$file" ]; then
    if [ ! -r "$file" ]; then
      echo "dotrc_config: cannot read $file" >&2
      return 2
    fi
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      case "$line" in ''|'#'*) continue ;; esac
      [[ "$line" == *=* ]] || continue
      k="${line%%=*}"; v="${line#*=}"
      k="${k%"${k##*[![:space:]]}"}"
      v="${v#"${v%%[![:space:]]*}"}"
      [ "$k" = "$key" ] && found="$v"
    done <"$file"
  fi

  if [ -n "$found" ]; then
    printf '%s\n' "$found"
  elif [ $# -ge 2 ]; then
    printf '%s\n' "$2"
  else
    echo "dotrc_config: $key is not set; add this line to $file:" >&2
    echo "  $key=..." >&2
    return 1
  fi
}
