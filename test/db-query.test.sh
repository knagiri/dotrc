#!/usr/bin/env bash
# Functional tests for bin/db-query. A usql stub records its argv (one element
# per bracketed line); a mise stub stands in for `mise exec -- <cmd>` and sets
# DATABASE_URL only when MISE_ENV=db, the way mise loads mise.db.local.toml.
# The last section repeats the core case with the real mise, if installed.
# Each guard is also checked against a mutant of the wrapper that lacks it.
# No test framework; run with bash.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
bindir="$here/../bin"
fail=0

stubdir="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$stubdir"' EXIT
args="$stubdir/args"

cat >"$stubdir/usql" <<'STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$@" >"$USQL_ARGS_FILE"
[ -z "${USQL_STDIN_FILE:-}" ] || cat >"$USQL_STDIN_FILE"
STUB
cat >"$stubdir/mise" <<'STUB'
#!/usr/bin/env bash
[ "${MISE_ENV:-}" != db ] || [ -z "${STUB_DB_URL:-}" ] || export DATABASE_URL="$STUB_DB_URL"
while [ $# -gt 0 ]; do case "$1" in --) shift; break ;; *) shift ;; esac; done
exec "$@"
STUB
chmod +x "$stubdir/usql" "$stubdir/mise"

# run <db-query path> [args...]; env for the stubs comes from the caller.
run() {
  local q="$1"; shift
  : >"$args"
  USQL_ARGS_FILE="$args" PATH="$stubdir:$PATH" "$q" "$@" >/dev/null 2>"$stubdir/err"
}

# Mutants: copies of the wrapper with one guard removed. A sed that matched
# nothing is reported, since an unapplied mutant would make its check a no-op.
mk_mutant() {  # mk_mutant <name> <sed expression>
  sed "$2" "$bindir/db-query" >"$stubdir/$1"; chmod +x "$stubdir/$1"
  if cmp -s "$bindir/db-query" "$stubdir/$1"; then
    echo "FAIL: mutant '$1' is identical to db-query; its check is a no-op"; fail=1
  fi
}
mk_mutant nomiseenv 's|MISE_ENV=db ||'
mk_mutant keepenv 's|env -u DATABASE_URL |env |'
mk_mutant noemptycheck 's|if \[ -z "\${DATABASE_URL:-}" \]; then|if false; then|'
mk_mutant nobackslash 's|^  \*\\\\\*)$|  __never__)|'
mk_mutant keepstdin 's| </dev/null$||'

# 1. Fixed flags, the format flags and -c <sql>, then the URL from the db config.
STUB_DB_URL="postgres://ro@localhost/example" run "$bindir/db-query" -J -c 'select 1'; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$args")" = "$(printf '[%s]\n' -X -w -J -c 'select 1' "postgres://ro@localhost/example")" ]; then
  echo "ok: db-query hands usql -X -w, the format flags, -c <sql> and the MISE_ENV=db DATABASE_URL"
else echo "FAIL: db-query rc=$rc args=$(cat "$args")"; fail=1; fi

STUB_DB_URL="postgres://ro@localhost/example" run "$stubdir/nomiseenv" -c 'select 1'; rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$args" ]; then
  echo "ok: without MISE_ENV=db the URL is not loaded (the case above is discriminating)"
else echo "FAIL: nomiseenv mutant rc=$rc args=$(cat "$args")"; fail=1; fi

# 2. No DATABASE_URL in the config: a clear error, exit 2, usql never runs.
run "$bindir/db-query" -c 'select 1'; rc=$?
if [ "$rc" -eq 2 ] && [ ! -s "$args" ] && grep -qF 'DATABASE_URL is not set' "$stubdir/err"; then
  echo "ok: db-query fails with exit 2 and a message when DATABASE_URL is unset"
else echo "FAIL: unset DATABASE_URL rc=$rc args=$(cat "$args") err=$(cat "$stubdir/err")"; fail=1; fi

STUB_DB_URL="" run "$stubdir/noemptycheck" -c 'select 1'; rc=$?
if [ -s "$args" ]; then
  echo "ok: without the empty check usql runs with no URL (the case above is discriminating)"
else echo "FAIL: noemptycheck mutant rc=$rc args=$(cat "$args")"; fail=1; fi

# 3. A DATABASE_URL inherited from the caller is never used as the target.
DATABASE_URL="postgres://rw@prod.example.invalid/db" run "$bindir/db-query" -c 'select 1'; rc=$?
if [ "$rc" -eq 2 ] && [ ! -s "$args" ]; then
  echo "ok: db-query ignores an inherited DATABASE_URL"
else echo "FAIL: inherited DATABASE_URL rc=$rc args=$(cat "$args")"; fail=1; fi

DATABASE_URL="postgres://rw@prod.example.invalid/db" run "$stubdir/keepenv" -c 'select 1'; rc=$?
if grep -qxF '[postgres://rw@prod.example.invalid/db]' "$args"; then
  echo "ok: without env -u the inherited URL leaks through (the case above is discriminating)"
else echo "FAIL: keepenv mutant rc=$rc args=$(cat "$args")"; fail=1; fi

# 4. Argument shape: usql runs shell commands and writes files through
# backslash meta-commands, so only -c <sql> and format flags get through.
STUB_DB_URL="postgres://ro@localhost/example" run "$bindir/db-query" -c 'select 1; \! touch /tmp/x'; rc=$?
if [ "$rc" -eq 1 ] && [ ! -s "$args" ] && grep -qF 'backslash' "$stubdir/err"; then
  echo "ok: db-query refuses SQL containing a backslash meta-command"
else echo "FAIL: backslash rc=$rc args=$(cat "$args") err=$(cat "$stubdir/err")"; fail=1; fi

STUB_DB_URL="postgres://ro@localhost/example" run "$stubdir/nobackslash" -c 'select 1; \! touch /tmp/x'; rc=$?
if [ -s "$args" ]; then
  echo "ok: without the backslash check the meta-command reaches usql (the case above is discriminating)"
else echo "FAIL: nobackslash mutant rc=$rc args=$(cat "$args")"; fail=1; fi

for bad in "-f q.sql" "-o out.txt" "-c" "-J" "-c a -c b" "-c select --set=x"; do
  # shellcheck disable=SC2086  # each case is a word list on purpose
  STUB_DB_URL="postgres://ro@localhost/example" run "$bindir/db-query" $bad; rc=$?
  if [ "$rc" -eq 1 ] && [ ! -s "$args" ]; then
    echo "ok: db-query refuses '$bad'"
  else echo "FAIL: '$bad' rc=$rc args=$(cat "$args")"; fail=1; fi
done

# stdin is another path for meta-commands, so usql gets none of the caller's.
: >"$stubdir/stdin"
printf '\\! touch /tmp/x\n' | STUB_DB_URL="postgres://ro@localhost/example" \
  USQL_STDIN_FILE="$stubdir/stdin" run "$bindir/db-query" -c 'select 1'; rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$stubdir/stdin" ]; then
  echo "ok: db-query gives usql an empty stdin"
else echo "FAIL: stdin rc=$rc stdin=$(cat "$stubdir/stdin")"; fail=1; fi

: >"$stubdir/stdin"
printf '\\! touch /tmp/x\n' | STUB_DB_URL="postgres://ro@localhost/example" \
  USQL_STDIN_FILE="$stubdir/stdin" run "$stubdir/keepstdin" -c 'select 1'; rc=$?
if [ -s "$stubdir/stdin" ]; then
  echo "ok: without </dev/null the caller's stdin reaches usql (the case above is discriminating)"
else echo "FAIL: keepstdin mutant rc=$rc"; fail=1; fi

# 5. No mise on PATH: fail before anything else, with a message.
nomise="$stubdir/nomise"; mkdir -p "$nomise"
ln -s "$(command -v bash)" "$nomise/bash"
: >"$args"
USQL_ARGS_FILE="$args" PATH="$nomise" "$bindir/db-query" -c 'select 1' >/dev/null 2>"$stubdir/err"; rc=$?
if [ "$rc" -eq 127 ] && grep -qF 'mise not found' "$stubdir/err"; then
  echo "ok: db-query fails with 127 when mise is missing"
else echo "FAIL: no mise rc=$rc err=$(cat "$stubdir/err")"; fail=1; fi

# 6. Real mise: mise.db.local.toml at the main checkout's root is read from a
# linked worktree under <repo>/.worktrees/<name>, and only with MISE_ENV=db.
# Hermetic in the same way as the real-mise cases of gh-wrappers.test.sh.
realmise="$(command -v mise 2>/dev/null || true)"
if [ -z "$realmise" ]; then
  echo "skip: no real mise on PATH; the mise.db.local.toml cases need it"
else
  rmroot="$(cd "$stubdir" && pwd -P)/realmise"; rmrepo="$rmroot/repo"
  mkdir -p "$rmrepo" "$rmroot/cfg" "$rmroot/bin"
  git -C "$rmrepo" init -q
  git -C "$rmrepo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  git -C "$rmrepo" worktree add -q "$rmrepo/.worktrees/foo" -b foo 2>/dev/null
  printf '[env]\nDATABASE_URL = "postgres://ro@localhost/example"\n' >"$rmrepo/mise.db.local.toml"
  ln -s "$realmise" "$rmroot/bin/mise"
  cp "$stubdir/usql" "$rmroot/bin/usql"
  realmise_run() {  # realmise_run <db-query path>
    : >"$args"
    ( cd "$rmrepo/.worktrees/foo" && env -u MISE_ENV -u DATABASE_URL \
        MISE_TRUSTED_CONFIG_PATHS="$rmrepo" MISE_CEILING_PATHS="$rmroot" \
        MISE_GLOBAL_CONFIG_FILE="$rmroot/none.toml" MISE_CONFIG_DIR="$rmroot/cfg" \
        USQL_ARGS_FILE="$args" PATH="$rmroot/bin:$PATH" "$1" -c 'select 1' ) >/dev/null 2>&1
  }
  realmise_run "$bindir/db-query"; rc=$?
  if [ "$rc" -eq 0 ] && grep -qxF '[postgres://ro@localhost/example]' "$args"; then
    echo "ok: real mise reads the main checkout's mise.db.local.toml from a linked worktree"
  else echo "FAIL: real mise rc=$rc args=$(cat "$args")"; fail=1; fi

  realmise_run "$stubdir/nomiseenv"; rc=$?
  if [ "$rc" -ne 0 ] && [ ! -s "$args" ]; then
    echo "ok: real mise without MISE_ENV=db does not load it (the case above is discriminating)"
  else echo "FAIL: real mise nomiseenv rc=$rc args=$(cat "$args")"; fail=1; fi
fi

exit "$fail"
