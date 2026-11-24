#!/usr/bin/env bash
# Functional tests for bin/db-query. A usql stub records its argv (one element
# per bracketed line) and exits with $USQL_EXIT; a mise stub stands in for
# `mise env` and `mise exec -- <cmd>` and sets DATABASE_URL only when mise is
# pointed at mise.db.local.toml, the way the real override loads it. The last
# section repeats the core cases with the real mise, if installed.
# Each guard exercised below is also checked against a mutant of the wrapper
# that lacks it (mk_mutant); the argument parser's value/duplicate checks and
# the missing-mise check have no mutant.
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
exit "${USQL_EXIT:-0}"
STUB
cat >"$stubdir/mise" <<'STUB'
#!/usr/bin/env bash
if [ "${MISE_OVERRIDE_CONFIG_FILENAMES:-}" = mise.db.local.toml ]; then
  [ -z "${STUB_DB_URL:-}" ] || export DATABASE_URL="$STUB_DB_URL"
fi
if [ "${1:-}" = env ]; then
  [ -z "${STUB_MISE_FAIL:-}" ] || { echo "mise ERROR stub: config not trusted" >&2; exit 1; }
  exit 0
fi
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
mk_mutant nooverride 's|^export MISE_OVERRIDE_CONFIG_FILENAMES=.*$|:|'
# (misenv also drops the trust hardening: its case is about config precedence,
# and the chain's mise.toml files are trusted by path prefix in that case)
mk_mutant misenv 's|^export MISE_OVERRIDE_CONFIG_FILENAMES=.*$|export MISE_ENV=db|;s|^export MISE_PARANOID=1$|:|;s|^export MISE_TRUSTED_CONFIG_PATHS=$|:|'
mk_mutant keepenv 's|env -u DATABASE_URL mise exec|env mise exec|'
mk_mutant noemptycheck 's|if \[ -z "\${DATABASE_URL:-}" \]; then|if false; then|;s|^    exit 5 ;;$|    : ;;|'
# (the scheme check is also off, since it would otherwise refuse the empty URL)
mk_mutant nobackslash 's|^  \*\\\\\*)$|  __never__)|'
mk_mutant keepstdin 's| </dev/null$||'
mk_mutant passthrough 's|^    \*) die_args .*$|    *) fmt+=("$1"); shift ;;|'
mk_mutant noemptysql 's|^\[ -n "\$sql" \] .*$|:|'
mk_mutant nousqlcheck 's|if ! command -v usql >/dev/null 2>&1; then|if false; then|'
mk_mutant noparanoid 's|^export MISE_PARANOID=1$|:|'
mk_mutant noprefixclear 's|^export MISE_TRUSTED_CONFIG_PATHS=$|:|'
mk_mutant nopreflight 's|^if ! mise_err=.*$|if false; then|'

URL="postgres://ro@localhost/example"

# 1. Fixed flags, the format flags and -c <sql>, then the URL from the db config.
STUB_DB_URL="$URL" run "$bindir/db-query" -J -c 'select 1'; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$args")" = "$(printf '[%s]\n' -X -w -J -c 'select 1' "$URL")" ]; then
  echo "ok: db-query hands usql -X -w, the format flags, -c <sql> and the DATABASE_URL from mise.db.local.toml"
else echo "FAIL: db-query rc=$rc args=$(cat "$args")"; fail=1; fi

STUB_DB_URL="$URL" run "$stubdir/nooverride" -c 'select 1'; rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$args" ]; then
  echo "ok: without the mise override the URL is not loaded (the case above is discriminating)"
else echo "FAIL: nooverride mutant rc=$rc args=$(cat "$args")"; fail=1; fi

STUB_DB_URL="$URL" run "$bindir/db-query" --json --command 'select 1'; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$args")" = "$(printf '[%s]\n' -X -w --json -c 'select 1' "$URL")" ]; then
  echo "ok: db-query accepts the long forms --json and --command"
else echo "FAIL: long flags rc=$rc args=$(cat "$args")"; fail=1; fi

run "$bindir/db-query" -h; rc=$?
if [ "$rc" -eq 0 ] && grep -qF 'usage:' "$stubdir/err" && [ ! -s "$args" ]; then
  echo "ok: db-query -h prints usage and exits 0"
else echo "FAIL: -h rc=$rc err=$(cat "$stubdir/err")"; fail=1; fi

# 2. No DATABASE_URL in the config: a clear error, exit 2, usql never runs.
run "$bindir/db-query" -c 'select 1'; rc=$?
if [ "$rc" -eq 2 ] && [ ! -s "$args" ] && grep -qF 'DATABASE_URL is unset or empty' "$stubdir/err"; then
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
STUB_DB_URL="$URL" run "$bindir/db-query" -c 'select 1; \! touch /tmp/x'; rc=$?
if [ "$rc" -eq 1 ] && [ ! -s "$args" ] && grep -qF 'backslash' "$stubdir/err"; then
  echo "ok: db-query refuses SQL containing a backslash meta-command"
else echo "FAIL: backslash rc=$rc args=$(cat "$args") err=$(cat "$stubdir/err")"; fail=1; fi

STUB_DB_URL="$URL" run "$stubdir/nobackslash" -c 'select 1; \! touch /tmp/x'; rc=$?
if [ -s "$args" ]; then
  echo "ok: without the backslash check the meta-command reaches usql (the case above is discriminating)"
else echo "FAIL: nobackslash mutant rc=$rc args=$(cat "$args")"; fail=1; fi

# Each case carries a valid -c so the refusal comes from the unsupported
# argument itself, not from a missing -c.
for bad in "-f q.sql" "-o out.txt" "--set=x" "-W"; do
  # shellcheck disable=SC2086  # each case is a word list on purpose
  STUB_DB_URL="$URL" run "$bindir/db-query" -c 'select 1' $bad; rc=$?
  if [ "$rc" -eq 1 ] && [ ! -s "$args" ] && grep -qF 'unsupported argument' "$stubdir/err"; then
    echo "ok: db-query refuses '$bad' next to a valid -c"
  else echo "FAIL: '$bad' rc=$rc args=$(cat "$args") err=$(cat "$stubdir/err")"; fail=1; fi
done

STUB_DB_URL="$URL" run "$stubdir/passthrough" -c 'select 1' -f q.sql; rc=$?
if grep -qxF '[-f]' "$args"; then
  echo "ok: without the unsupported-argument refusal -f reaches usql (the cases above are discriminating)"
else echo "FAIL: passthrough mutant rc=$rc args=$(cat "$args")"; fail=1; fi

# Malformed -c and missing -c: exit 1, usql never runs, and the message says why.
check_bad() {  # check_bad <expected stderr fragment> <args...>
  local want="$1"; shift
  STUB_DB_URL="$URL" run "$bindir/db-query" "$@"; rc=$?
  if [ "$rc" -eq 1 ] && [ ! -s "$args" ] && grep -qF -- "$want" "$stubdir/err"; then
    echo "ok: db-query $* -> exit 1 ($want)"
  else echo "FAIL: '$*' rc=$rc args=$(cat "$args") err=$(cat "$stubdir/err")"; fail=1; fi
}
check_bad 'needs a value' -c
check_bad 'more than once' -c a -c b
check_bad 'empty SQL' -c ''
check_bad '-c <sql> is required' -J

STUB_DB_URL="$URL" run "$stubdir/noemptysql" -c ''; rc=$?
if [ -s "$args" ]; then
  echo "ok: without the empty-SQL check usql runs (the empty-SQL case is discriminating)"
else echo "FAIL: noemptysql mutant rc=$rc args=$(cat "$args")"; fail=1; fi

# stdin is another path for meta-commands, so usql gets none of the caller's.
: >"$stubdir/stdin"
printf '\\! touch /tmp/x\n' | STUB_DB_URL="$URL" \
  USQL_STDIN_FILE="$stubdir/stdin" run "$bindir/db-query" -c 'select 1'; rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$stubdir/stdin" ]; then
  echo "ok: db-query gives usql an empty stdin"
else echo "FAIL: stdin rc=$rc stdin=$(cat "$stubdir/stdin")"; fail=1; fi

: >"$stubdir/stdin"
printf '\\! touch /tmp/x\n' | STUB_DB_URL="$URL" \
  USQL_STDIN_FILE="$stubdir/stdin" run "$stubdir/keepstdin" -c 'select 1'; rc=$?
if [ -s "$stubdir/stdin" ]; then
  echo "ok: without </dev/null the caller's stdin reaches usql (the case above is discriminating)"
else echo "FAIL: keepstdin mutant rc=$rc"; fail=1; fi

# usql's own exit code is passed through.
STUB_DB_URL="$URL" USQL_EXIT=3 run "$bindir/db-query" -c 'select 1'; rc=$?
if [ "$rc" -eq 3 ] && [ -s "$args" ]; then
  echo "ok: db-query returns usql's exit code"
else echo "FAIL: usql exit rc=$rc"; fail=1; fi

# Embedded engines run in usql with the local user's rights (SQL alone can
# write files), so only server-database schemes pass.
mk_mutant noschemecheck 's|^    exit 5 ;;$|    : ;;|'
for bad_url in "sq:/tmp/x.db" "sqlite:///tmp/x.db" "duckdb:/tmp/x.db" "dk:/tmp/x.db" \
               "file:///tmp/x.db" "/tmp/x.db" "myconn" "SQLITE3:///tmp/x.db"; do
  STUB_DB_URL="$bad_url" run "$bindir/db-query" -c 'select 1'; rc=$?
  if [ "$rc" -eq 5 ] && [ ! -s "$args" ] && grep -qF 'server-database URL' "$stubdir/err"; then
    echo "ok: db-query refuses DATABASE_URL '$bad_url' (exit 5)"
  else echo "FAIL: '$bad_url' rc=$rc args=$(cat "$args")"; fail=1; fi
done
for good_url in "postgresql://ro@h/db" "MySQL://ro@h/db" "sqlserver://ro@h/db"; do
  STUB_DB_URL="$good_url" run "$bindir/db-query" -c 'select 1'; rc=$?
  if [ "$rc" -eq 0 ] && grep -qxF "[$good_url]" "$args"; then
    echo "ok: db-query accepts server URL '$good_url'"
  else echo "FAIL: '$good_url' rc=$rc args=$(cat "$args")"; fail=1; fi
done
STUB_DB_URL="sq:/tmp/x.db" run "$stubdir/noschemecheck" -c 'select 1'; rc=$?
if grep -qxF '[sq:/tmp/x.db]' "$args"; then
  echo "ok: without the scheme check an embedded URL reaches usql (the cases above are discriminating)"
else echo "FAIL: noschemecheck mutant rc=$rc args=$(cat "$args")"; fail=1; fi

# 5. Environment failures each get their own code and message.
# 5a. No mise on PATH: fail before anything else.
nomise="$stubdir/nomise"; mkdir -p "$nomise"
ln -s "$(command -v bash)" "$nomise/bash"
: >"$args"
USQL_ARGS_FILE="$args" PATH="$nomise" "$bindir/db-query" -c 'select 1' >/dev/null 2>"$stubdir/err"; rc=$?
if [ "$rc" -eq 127 ] && grep -qF 'mise not found' "$stubdir/err"; then
  echo "ok: db-query fails with 127 when mise is missing"
else echo "FAIL: no mise rc=$rc err=$(cat "$stubdir/err")"; fail=1; fi

# 5b. mise cannot load the config (e.g. untrusted): exit 4, mise's message and
# the trust command shown, usql never runs.
STUB_DB_URL="$URL" STUB_MISE_FAIL=1 run "$bindir/db-query" -c 'select 1'; rc=$?
if [ "$rc" -eq 4 ] && [ ! -s "$args" ] && grep -qF 'config not trusted' "$stubdir/err" \
   && grep -qF 'MISE_OVERRIDE_CONFIG_FILENAMES=mise.db.local.toml mise trust' "$stubdir/err"; then
  echo "ok: db-query fails with 4 and the trust command when mise cannot load the config"
else echo "FAIL: mise failure rc=$rc args=$(cat "$args") err=$(cat "$stubdir/err")"; fail=1; fi

STUB_DB_URL="$URL" STUB_MISE_FAIL=1 run "$stubdir/nopreflight" -c 'select 1'; rc=$?
if [ "$rc" -ne 4 ]; then
  echo "ok: without the mise preflight the failure is not reported as 4 (the case above is discriminating)"
else echo "FAIL: nopreflight mutant rc=$rc"; fail=1; fi

# 5c. usql not installed: exit 3 with its own message. The stub dir has no usql
# here, so the inner shell finds none.
nousql="$stubdir/nousql"; mkdir -p "$nousql"; cp "$stubdir/mise" "$nousql/mise"
ln -s "$(command -v bash)" "$nousql/bash"
for tool in env dirname; do ln -s "$(command -v $tool)" "$nousql/$tool"; done
nousql_run() {
  : >"$args"
  STUB_DB_URL="$URL" PATH="$nousql" "$1" -c 'select 1' >/dev/null 2>"$stubdir/err"
}
nousql_run "$bindir/db-query"; rc=$?
if [ "$rc" -eq 3 ] && grep -qF 'usql not found' "$stubdir/err"; then
  echo "ok: db-query fails with 3 when usql is missing"
else echo "FAIL: no usql rc=$rc err=$(cat "$stubdir/err")"; fail=1; fi

nousql_run "$stubdir/nousqlcheck"; rc=$?
if [ "$rc" -ne 3 ]; then
  echo "ok: without the usql check the failure is not reported as 3 (the case above is discriminating)"
else echo "FAIL: nousqlcheck mutant rc=$rc"; fail=1; fi

# 6. Real mise. mise.db.local.toml at the main checkout's root is read from a
# linked worktree under <repo>/.worktrees/<name>, and no other mise config (a
# worktree's own mise.toml, a root mise.toml when mise.db.local.toml is absent)
# can supply the URL, and editing it after it was trusted makes db-query stop
# (exit 4) instead of evaluating the new content. Trust is given with a real
# `mise trust` under MISE_PARANOID (a content hash), not with
# MISE_TRUSTED_CONFIG_PATHS, which would bypass the hash. Hermetic in the same
# way as the real-mise cases of gh-wrappers.test.sh.
realmise="$(command -v mise 2>/dev/null || true)"
if [ -z "$realmise" ]; then
  echo "skip: no real mise on PATH; the mise.db.local.toml cases need it"
else
  rmroot="$(cd "$stubdir" && pwd -P)/realmise"; rmrepo="$rmroot/repo"
  mkdir -p "$rmrepo" "$rmroot/cfg" "$rmroot/state" "$rmroot/bin"
  git -C "$rmrepo" init -q
  git -C "$rmrepo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  git -C "$rmrepo" worktree add -q "$rmrepo/.worktrees/foo" -b foo 2>/dev/null
  printf '[env]\nDATABASE_URL = "%s"\n' "$URL" >"$rmrepo/mise.db.local.toml"
  ln -s "$realmise" "$rmroot/bin/mise"
  cp "$stubdir/usql" "$rmroot/bin/usql"
  # RM_PREFIX, when set, is a trusted path prefix in the caller's env.
  realmise_run() {  # realmise_run <db-query path>
    : >"$args"
    ( cd "$rmrepo/.worktrees/foo" && env -u MISE_ENV -u DATABASE_URL -u MISE_OVERRIDE_CONFIG_FILENAMES \
        MISE_TRUSTED_CONFIG_PATHS="${RM_PREFIX:-}" MISE_CEILING_PATHS="$rmroot" \
        MISE_GLOBAL_CONFIG_FILE="$rmroot/none.toml" MISE_CONFIG_DIR="$rmroot/cfg" \
        MISE_STATE_DIR="$rmroot/state" \
        USQL_ARGS_FILE="$args" PATH="$rmroot/bin:$PATH" "$1" -c 'select 1' ) >/dev/null 2>"$stubdir/err"
  }
  realmise_trust() {  # the human step the exit 4 message names
    ( cd "$rmrepo" && env -u MISE_ENV MISE_TRUSTED_CONFIG_PATHS= MISE_PARANOID=1 \
        MISE_OVERRIDE_CONFIG_FILENAMES=mise.db.local.toml MISE_CEILING_PATHS="$rmroot" \
        MISE_GLOBAL_CONFIG_FILE="$rmroot/none.toml" MISE_CONFIG_DIR="$rmroot/cfg" \
        MISE_STATE_DIR="$rmroot/state" mise trust ) >/dev/null 2>&1
  }
  realmise_trust
  realmise_run "$bindir/db-query"; rc=$?
  if [ "$rc" -eq 0 ] && grep -qxF "[$URL]" "$args"; then
    echo "ok: real mise reads the main checkout's mise.db.local.toml from a linked worktree"
  else echo "FAIL: real mise rc=$rc args=$(cat "$args")"; fail=1; fi

  realmise_run "$stubdir/nooverride"; rc=$?
  if [ "$rc" -ne 0 ] && [ ! -s "$args" ]; then
    echo "ok: real mise without the override does not load it (the case above is discriminating)"
  else echo "FAIL: real mise nooverride rc=$rc args=$(cat "$args")"; fail=1; fi

  # A worktree's own mise.toml with a DATABASE_URL is nearer than the main
  # checkout's file; under MISE_ENV=db alone it would win.
  printf '[env]\nDATABASE_URL = "postgres://rw@wt.example.invalid/db"\n' >"$rmrepo/.worktrees/foo/mise.toml"
  realmise_run "$bindir/db-query"; rc=$?
  if [ "$rc" -eq 0 ] && grep -qxF "[$URL]" "$args"; then
    echo "ok: a worktree's own mise.toml DATABASE_URL does not override mise.db.local.toml"
  else echo "FAIL: worktree mise.toml rc=$rc args=$(cat "$args")"; fail=1; fi

  RM_PREFIX="$rmrepo" realmise_run "$stubdir/misenv"; rc=$?
  if grep -qxF '[postgres://rw@wt.example.invalid/db]' "$args"; then
    echo "ok: with MISE_ENV=db alone the worktree's mise.toml wins (the case above is discriminating)"
  else echo "FAIL: real mise misenv mutant rc=$rc args=$(cat "$args")"; fail=1; fi

  # mise.db.local.toml absent and only a root mise.toml sets the URL: exit 2,
  # not that value.
  rm "$rmrepo/.worktrees/foo/mise.toml"
  mv "$rmrepo/mise.db.local.toml" "$rmroot/db.off"
  printf '[env]\nDATABASE_URL = "postgres://rw@root.example.invalid/db"\n' >"$rmrepo/mise.toml"
  realmise_run "$bindir/db-query"; rc=$?
  if [ "$rc" -eq 2 ] && [ ! -s "$args" ]; then
    echo "ok: without mise.db.local.toml a root mise.toml DATABASE_URL is not used (exit 2)"
  else echo "FAIL: absent db config rc=$rc args=$(cat "$args")"; fail=1; fi

  RM_PREFIX="$rmrepo" realmise_run "$stubdir/misenv"; rc=$?
  if grep -qxF '[postgres://rw@root.example.invalid/db]' "$args"; then
    echo "ok: with MISE_ENV=db alone the root mise.toml URL is used (the case above is discriminating)"
  else echo "FAIL: real mise misenv mutant (absent) rc=$rc args=$(cat "$args")"; fail=1; fi

  # An edit after trust must stop db-query: mise would evaluate the new
  # content (here an exec template that touches a marker file).
  rm "$rmrepo/mise.toml"
  mv "$rmroot/db.off" "$rmrepo/mise.db.local.toml"
  realmise_trust
  realmise_run "$bindir/db-query"; rc=$?
  if [ "$rc" -eq 0 ] && grep -qxF "[$URL]" "$args"; then
    echo "ok: a content-trusted mise.db.local.toml is read"
  else echo "FAIL: content-trusted config rc=$rc args=$(cat "$args")"; fail=1; fi
  marker="$rmroot/pwned"
  printf 'PWN = "{{ exec(command=\\"touch %s\\") }}"\n' "$marker" >>"$rmrepo/mise.db.local.toml"
  realmise_run "$bindir/db-query"; rc=$?
  if [ "$rc" -eq 4 ] && [ ! -s "$args" ] && [ ! -e "$marker" ] && grep -qF 'not trusted' "$stubdir/err"; then
    echo "ok: editing mise.db.local.toml after trust makes db-query stop with 4 and run nothing"
  else echo "FAIL: edited config rc=$rc args=$(cat "$args") marker=$(ls "$marker" 2>&1)"; fail=1; fi

  realmise_run "$stubdir/noparanoid"; rc=$?
  if [ "$rc" -eq 0 ] && [ -e "$marker" ]; then
    echo "ok: without MISE_PARANOID the edited content is evaluated (the case above is discriminating)"
  else echo "FAIL: noparanoid mutant rc=$rc marker=$(ls "$marker" 2>&1)"; fail=1; fi
  rm -f "$marker"

  # A trusted path prefix in the caller's env bypasses the hash unless cleared.
  RM_PREFIX="$rmrepo" realmise_run "$bindir/db-query"; rc=$?
  if [ "$rc" -eq 4 ] && [ ! -e "$marker" ]; then
    echo "ok: a trusted path prefix in the env does not bypass the content trust"
  else echo "FAIL: prefix rc=$rc marker=$(ls "$marker" 2>&1)"; fail=1; fi

  RM_PREFIX="$rmrepo" realmise_run "$stubdir/noprefixclear"; rc=$?
  if [ "$rc" -eq 0 ] && [ -e "$marker" ]; then
    echo "ok: without clearing MISE_TRUSTED_CONFIG_PATHS the prefix bypasses it (the case above is discriminating)"
  else echo "FAIL: noprefixclear mutant rc=$rc marker=$(ls "$marker" 2>&1)"; fail=1; fi
fi

exit "$fail"
