#!/usr/bin/env bash
# Tests for bin/lib/dotrc-config.sh (dotrc_config). No test framework; run with
# bash. HOME is the sandbox's, so the config file is the one each case writes.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
lib="$here/../bin/lib/dotrc-config.sh"
fail=0

tmp="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$tmp"' EXIT

cfg="$HOME/.config/dotrc/config"
mkdir -p "${cfg%/*}"

# get <args...> -- call dotrc_config in a fresh shell with DC_* unset; sets
# $out, $err, $rc.
get() {
  out="$(env -u DC_A -u DC_B bash -c '. "$1"; shift; dotrc_config "$@"' _ "$lib" "$@" 2>"$tmp/err")"
  rc=$?
  err="$(cat "$tmp/err")"
}

pass() { echo "ok: $1"; }
nope() { echo "FAIL: $1 (rc=$rc out=$out err=$err)"; fail=1; }
# expect <description> <rc> <out> -- compare the last call against rc and out.
expect() {
  if [ "$rc" -eq "$2" ] && [ "$out" = "$3" ]; then pass "$1"; else nope "$1"; fi
}

# --- parsing ------------------------------------------------------------------
printf '%s\n' \
  '# a comment' \
  '' \
  '   ' \
  'not a setting' \
  '  DC_A  =  first value  ' \
  'DC_B=x=y' \
  'DC_A=second' >"$cfg"

get DC_A
expect "the last of repeated keys wins" 0 "second"
get DC_B
expect "the value is everything after the first =" 0 "x=y"

printf '  DC_A  =  spaced value  \n' >"$cfg"
get DC_A
expect "whitespace around key and value is dropped" 0 "spaced value"

printf '#DC_A=commented\n' >"$cfg"
get DC_A fallback
expect "a commented-out line is ignored" 0 "fallback"

printf 'DC_A=last-line-without-newline' >"$cfg"
get DC_A
expect "a final line without a newline is read" 0 "last-line-without-newline"

printf 'DC_AB=other\n' >"$cfg"
get DC_A fallback
expect "a key is matched whole, not by prefix" 0 "fallback"

# The file is parsed, never sourced: shell syntax in a value stays literal and
# runs nothing.
marker="$tmp/ran"
# shellcheck disable=SC2016  # the $( ) is meant to reach the file unexpanded
printf 'DC_A=$(touch %s)"q"\ntouch %s\n' "$marker" "$marker" >"$cfg"
get DC_A
if [ "$rc" -eq 0 ] && [ "$out" = "\$(touch $marker)\"q\"" ] && [ ! -e "$marker" ]; then
  pass "the file is not executed and values are literal"
else nope "the file is not executed and values are literal"; fi

# --- lookup order -------------------------------------------------------------
printf 'DC_A=from-file\n' >"$cfg"
out="$(DC_A=from-env bash -c '. "$1"; dotrc_config DC_A' _ "$lib" 2>"$tmp/err")"; rc=$?; err=""
expect "a non-empty environment variable wins over the file" 0 "from-env"
out="$(DC_A="" bash -c '. "$1"; dotrc_config DC_A' _ "$lib" 2>"$tmp/err")"; rc=$?
expect "an empty environment variable falls through to the file" 0 "from-file"

get DC_A fallback
expect "the file wins over the default" 0 "from-file"

printf 'DC_A=\n' >"$cfg"
get DC_A fallback
expect "an empty value in the file counts as unset" 0 "fallback"

rm -f "$cfg"
get DC_A fallback
expect "a missing file falls back to the default" 0 "fallback"

get DC_A
if [ "$rc" -eq 1 ] && [ -z "$out" ] && [[ "$err" == *"$cfg"* ]] && [[ "$err" == *"DC_A=..."* ]]; then
  pass "no value and no default returns 1, naming the file and the line"
else nope "no value and no default returns 1, naming the file and the line"; fi

xdg="$tmp/xdg"
mkdir -p "$xdg/dotrc"
printf 'DC_A=from-xdg\n' >"$xdg/dotrc/config"
out="$(XDG_CONFIG_HOME="$xdg" bash -c '. "$1"; dotrc_config DC_A' _ "$lib" 2>"$tmp/err")"; rc=$?
expect "XDG_CONFIG_HOME moves the file" 0 "from-xdg"

# CRLF line endings (a file edited on another platform): the \r is dropped with
# the rest of the trailing whitespace, so it never ends up in a value.
printf 'DC_A=crlf-value\r\nDC_B=x=y\r\n' >"$cfg"
get DC_A
expect "a CRLF line ending does not leave a carriage return in the value" 0 "crlf-value"
get DC_B
expect "a CRLF line ending after a value with = is dropped too" 0 "x=y"

# Discrimination: with the trailing-whitespace trim removed, the \r stays.
nomut="$tmp/nottrim.sh"
grep -v 'line="${line%"${line##\*\[!\[:space:\]\]}"}"' "$lib" >"$nomut"
if cmp -s "$lib" "$nomut"; then
  echo "FAIL: the trailing-trim mutant is identical; the check below is a no-op"; fail=1
fi
printf 'DC_A=crlf-value\r\n' >"$cfg"
out="$(env -u DC_A bash -c '. "$1"; dotrc_config DC_A' _ "$nomut" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" != "crlf-value" ]; then
  pass "without the trailing trim the carriage return stays in the value (the CRLF case is discriminating)"
else nope "trailing-trim mutant"; fi

# A file that exists but cannot be read is an error, not "unset": the default
# must not quietly stand in for a setting that is there but unreadable. (Root
# reads any file, so the case cannot be set up as root.)
printf 'DC_A=from-file\n' >"$cfg"
chmod 000 "$cfg"
if [ -r "$cfg" ]; then
  echo "skip: the config file is readable despite chmod 000 (running as root?); unreadable-file case not run"
else
  get DC_A fallback
  if [ "$rc" -eq 2 ] && [ -z "$out" ] && [[ "$err" == *"cannot read $cfg"* ]]; then
    pass "an unreadable config file returns 2 naming the file, not the default"
  else nope "an unreadable config file returns 2 naming the file, not the default"; fi
  # Discrimination: without the readability check the same file yields the
  # default (or "unset"), never the error.
  noread="$tmp/noread.sh"
  sed 's|\[ ! -r "\$file" \]|false|' "$lib" >"$noread"
  if cmp -s "$lib" "$noread"; then
    echo "FAIL: the readability mutant is identical; the check below is a no-op"; fail=1
  fi
  out="$(env -u DC_A bash -c '. "$1"; dotrc_config DC_A fallback' _ "$noread" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 2 ]; then
    pass "without the readability check the unreadable file is not reported (the case above is discriminating)"
  else nope "readability mutant"; fi
fi
chmod 600 "$cfg"
rm -f "$cfg"

get 'bad key'
if [ "$rc" -eq 2 ]; then pass "a key that is not an identifier returns 2"; else nope "a key that is not an identifier returns 2"; fi

exit "$fail"
