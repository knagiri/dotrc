#!/usr/bin/env bash
# Functional tests for claude-stop-bg. PATH stubs stand in for the `claude` CLI
# (`agents --json` prints a fixture roster, `stop` records its argv) and for
# `claude-queue` (`done` records its argv), and CLAUDE_QUEUE_DB points at a
# temp path, so no real session is stopped and the real ledger is never read
# or written. The guard can be exercised exhaustively.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
src="$here/../bin/claude-stop-bg"
fail=0

tmp="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$tmp"' EXIT

stubbin="$tmp/stubbin"
mkdir -p "$stubbin"
cat >"$stubbin/claude" <<'EOF'
#!/usr/bin/env bash
# Both calls record the CLAUDE_CONFIG_DIR they saw. A session in another config
# dir is invisible to the default dir's daemon, so pointing either call at the
# wrong dir is a silent wrong answer, not an error -- which is why the dir is
# recorded rather than assumed.
[ -n "${CLAUDE_STUB_ENVLOG:-}" ] && printf '%s %s\n' "$1" "${CLAUDE_CONFIG_DIR:-UNSET}" >>"$CLAUDE_STUB_ENVLOG"
case "$1" in
  agents) cat "$CLAUDE_STUB_ROSTER" ;;
  stop)   printf '%s\n' "$2" >"$CLAUDE_STUB_STOPLOG"
          if [ -n "${CLAUDE_STUB_ORDERLOG:-}" ]; then echo stop >>"$CLAUDE_STUB_ORDERLOG"; fi ;;
  *)      exit 1 ;;
esac
EOF
chmod +x "$stubbin/claude"

# claude-queue stub: records `done <id>`, so a case can assert whether the work
# was marked done and in what order relative to the stop.
cat >"$stubbin/claude-queue" <<'EOF'
#!/usr/bin/env bash
[ "$1" = done ] || exit 2
printf '%s\n' "$2" >>"$CLAUDE_STUB_DONELOG"
if [ -n "${CLAUDE_STUB_ORDERLOG:-}" ]; then echo done >>"$CLAUDE_STUB_ORDERLOG"; fi
EOF
chmod +x "$stubbin/claude-queue"
donelog="$tmp/done.log"
: >"$donelog"
export CLAUDE_STUB_DONELOG="$donelog"
# Every run reads this ledger path, which does not exist unless a case creates
# it, so the real ~/.claude/session-queue.db is never consulted.
export CLAUDE_QUEUE_DB="$tmp/none.db"

roster="$tmp/roster.json"
cat >"$roster" <<'EOF'
[
  {"pid":111,"cwd":"/w/a","kind":"background","sessionId":"aaaaaaaa-1111-2222-3333-444444444444","status":"idle"},
  {"pid":222,"cwd":"/w/b","kind":"interactive","sessionId":"bbbbbbbb-1111-2222-3333-444444444444","name":"dotrc-32","status":"busy"}
]
EOF

stoplog="$tmp/stop.log"
run() { PATH="$stubbin:$PATH" CLAUDE_STUB_ROSTER="$roster" CLAUDE_STUB_STOPLOG="$stoplog" "$src" "$@"; }

# background session -> marked done, then stopped, and the SHORT id is what
# reaches both. Done comes first: the stop's SessionEnd (reason "other") is the
# one a reboot sends too, so the ledger keeps the session open unless the done
# mark is already there.
orderlog="$tmp/order.log"
: >"$stoplog"; : >"$donelog"; : >"$orderlog"
CLAUDE_STUB_ORDERLOG="$orderlog" run aaaaaaaa >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$stoplog")" = "aaaaaaaa" ] && [ "$(cat "$donelog")" = "aaaaaaaa" ] \
   && [ "$(tr '\n' ' ' <"$orderlog")" = "done stop " ]; then
  echo "ok: background session is marked done, then stopped, by short id"
else echo "FAIL: background stop rc=$rc stoplog=$(cat "$stoplog") donelog=$(cat "$donelog") order=$(cat "$orderlog")"; fail=1; fi

# A failing done mark: the running path still stops the session but ends
# non-zero and says it was not marked; the not-running path has only the mark to
# do, so it ends non-zero and never claims "marked done".
failbin="$tmp/failbin"; mkdir -p "$failbin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$failbin/claude-queue"; chmod +x "$failbin/claude-queue"
: >"$stoplog"
out="$(PATH="$failbin:$stubbin:$PATH" CLAUDE_STUB_ROSTER="$roster" CLAUDE_STUB_STOPLOG="$stoplog" "$src" aaaaaaaa 2>&1)"; rc=$?
if [ "$rc" -eq 3 ] && [ "$(cat "$stoplog")" = "aaaaaaaa" ] && grep -qF 'NOT marked done' <<<"$out"; then
  echo "ok: a failed done mark still stops the session but exits non-zero"
else echo "FAIL: failed mark on running session rc=$rc out=$out"; fail=1; fi

# interactive session -> refused. This is the whole reason the wrapper exists:
# a broad `claude stop *` grant would let an agent kill the user's own session.
# A refusal writes no done mark either.
: >"$stoplog"; : >"$donelog"
out="$(run bbbbbbbb 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$stoplog" ] && [ ! -s "$donelog" ] \
   && grep -qF 'refusing to stop a interactive session' <<<"$out"; then
  echo "ok: interactive session is refused, reaching neither claude stop nor the done mark"
else echo "FAIL: interactive not refused rc=$rc out=$out donelog=$(cat "$donelog")"; fail=1; fi

# Not running, and no ledger to check its kind against -> refused: an
# unreadable ledger is no evidence the session is a background one.
: >"$stoplog"; : >"$donelog"
run cccccccc >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$stoplog" ] && [ ! -s "$donelog" ]; then
  echo "ok: an id not running and not checkable against the ledger is refused"
else echo "FAIL: unchecked id accepted rc=$rc"; fail=1; fi

# Malformed ids must be rejected before any roster lookup: a full UUID is the
# realistic mistake (claude attach/stop only accept the 8-char form).
: >"$stoplog"
run aaaaaaaa-1111-2222-3333-444444444444 >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$stoplog" ]; then
  echo "ok: full UUID is rejected as not a short id"
else echo "FAIL: full UUID accepted rc=$rc"; fail=1; fi

# No argument -> usage error. Same shape as the other refusal cases (reset the
# stoplog, assert it stays empty) so this case proves `claude stop` was never
# reached, not just that the exit code is nonzero.
: >"$stoplog"
run >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$stoplog" ]; then
  echo "ok: missing argument is rejected"
else echo "FAIL: missing argument accepted rc=$rc"; fail=1; fi

# Too many arguments -> usage error. [ $# -eq 1 ] is what stops a caller from
# smuggling extra flags (e.g. --force) past this wrapper into `claude stop`.
: >"$stoplog"
run aaaaaaaa --force >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$stoplog" ]; then
  echo "ok: extra arguments are rejected"
else echo "FAIL: extra arguments accepted rc=$rc stoplog=$(cat "$stoplog")"; fail=1; fi

# Missing `claude` CLI -> refused with a diagnostic message, not a silent
# non-zero exit. PATH here has jq but no claude (real or stub), so the
# roster-fetch step must fail loudly.
noclaude="$tmp/noclaude"
mkdir -p "$noclaude"
ln -s "$(command -v bash)" "$noclaude/bash"
ln -s "$(command -v jq)" "$noclaude/jq"
out="$(PATH="$noclaude" "$src" aaaaaaaa 2>&1)"; rc=$?
# Pinned to the exact guard message rather than a loose 'claude' substring: every
# diagnostic this script prints is prefixed "claude-stop-bg:", so a loose match
# would also pass if a *different* guard (e.g. the jq one) fired instead.
if [ "$rc" -ne 0 ] && [ -n "$out" ] && grep -qF 'the claude CLI is required' <<<"$out"; then
  echo "ok: missing claude CLI is refused with a diagnostic message"
else echo "FAIL: missing claude CLI rc=$rc out=$out"; fail=1; fi

# Missing `jq` -> refused with a diagnostic message. PATH here has claude (the
# stub, so the claude-CLI guard passes) but no jq, so the jq guard must be the
# one that fires. The stub claude script itself uses `cat` to print the
# fixture roster, so `cat` is symlinked in too even though this guard fires
# before `claude agents` is ever invoked -- keeping the stub runnable if that
# ordering ever changes is cheap insurance.
nojq="$tmp/nojq"
mkdir -p "$nojq"
ln -s "$(command -v bash)" "$nojq/bash"
ln -s "$(command -v cat)" "$nojq/cat"
cp "$stubbin/claude" "$nojq/claude"
chmod +x "$nojq/claude"
: >"$stoplog"
out="$(PATH="$nojq" CLAUDE_STUB_ROSTER="$roster" CLAUDE_STUB_STOPLOG="$stoplog" "$src" aaaaaaaa 2>&1)"; rc=$?
# Pinned to the exact guard message (not a loose 'jq' substring) for the same
# reason as the missing-claude case: a loose match would also pass if a
# *different* guard fired instead, losing the discriminating power.
if [ "$rc" -ne 0 ] && [ ! -s "$stoplog" ] && grep -qF 'jq is required to verify the session kind' <<<"$out"; then
  echo "ok: missing jq is refused with a diagnostic message"
else echo "FAIL: missing jq rc=$rc out=$out"; fail=1; fi

# Two roster entries sharing the prefix are ambiguous -> refuse rather than
# guess, since stopping the wrong session is unrecoverable.
cat >"$tmp/dup.json" <<'EOF'
[
  {"pid":111,"cwd":"/w/a","kind":"background","sessionId":"dddddddd-1111-2222-3333-444444444444","status":"idle"},
  {"pid":333,"cwd":"/w/c","kind":"background","sessionId":"dddddddd-9999-2222-3333-444444444444","status":"idle"}
]
EOF
: >"$stoplog"
PATH="$stubbin:$PATH" CLAUDE_STUB_ROSTER="$tmp/dup.json" CLAUDE_STUB_STOPLOG="$stoplog" \
  "$src" dddddddd >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$stoplog" ]; then
  echo "ok: ambiguous short id is refused"
else echo "FAIL: ambiguous id accepted rc=$rc"; fail=1; fi

# --- config dir resolution --------------------------------------------------
#
# The ledger records every session on the host, but the roster and the daemon
# behind it are per CLAUDE_CONFIG_DIR. Asking under this process's own
# environment would report a session in another dir as simply absent, so the dir
# comes off the row and is exported for both the roster read and the stop.

if command -v sqlite3 >/dev/null 2>&1; then
  personal="$tmp/.claude-personal"
  cqdb="$tmp/queue.db"
  sqlite3 "$cqdb" "
    CREATE TABLE sessions (session_id TEXT PRIMARY KEY, config_dir TEXT);
    INSERT INTO sessions VALUES ('aaaaaaaa-1111-2222-3333-444444444444', '$personal');
    INSERT INTO sessions VALUES ('eeeeeeee-1111-2222-3333-444444444444', '$personal');
    INSERT INTO sessions VALUES ('eeeeeeee-9999-2222-3333-444444444444', '$tmp/.claude-other');
  "

  envlog="$tmp/env.log"
  runcfg() {
    PATH="$stubbin:$PATH" CLAUDE_STUB_ROSTER="$roster" CLAUDE_STUB_STOPLOG="$stoplog" \
      CLAUDE_STUB_ENVLOG="$envlog" CLAUDE_QUEUE_DB="$cqdb" HOME="$tmp" "$src" "$@"
  }

  # A session the ledger places in a second config dir: BOTH the roster read and
  # the stop must run under that dir, not under the caller's environment.
  : >"$stoplog"; : >"$envlog"
  CLAUDE_CONFIG_DIR="$tmp/.claude-wrong" runcfg aaaaaaaa >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ] \
     && [ "$(cat "$stoplog")" = "aaaaaaaa" ] \
     && [ "$(grep -c "^agents $personal\$" "$envlog")" -eq 1 ] \
     && [ "$(grep -c "^stop $personal\$" "$envlog")" -eq 1 ]; then
    echo "ok: the roster read and the stop both run under the row's config dir"
  else echo "FAIL: config dir not applied rc=$rc envlog=$(cat "$envlog")"; fail=1; fi

  # An id the ledger does not know falls back to the default dir ($HOME/.claude),
  # which is what every session ran under before a second dir existed. The
  # default dir is reached by UNSETTING the variable -- even one inherited as an
  # explicit $HOME/.claude -- since claude reads a different global config file
  # when ~/.claude is spelled out.
  : >"$stoplog"; : >"$envlog"
  CLAUDE_CONFIG_DIR="$tmp/.claude" runcfg bbbbbbbb >/dev/null 2>&1
  if [ "$(cat "$envlog")" = "agents UNSET" ]; then
    echo "ok: an id the ledger does not know falls back to the default dir, unset"
  else echo "FAIL: no default-dir fallback: $(cat "$envlog")"; fail=1; fi

  # Rows under two different dirs share the prefix: refuse rather than guess,
  # since pointing the stop at one of them could stop nothing -- or, once the
  # dirs hold ids in common, the wrong thing.
  : >"$stoplog"; : >"$envlog"
  out="$(runcfg eeeeeeee 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && [ ! -s "$stoplog" ] && [ ! -s "$envlog" ] \
     && grep -qF 'more than one CLAUDE_CONFIG_DIR' <<<"$out"; then
    echo "ok: an id spanning two config dirs is refused before any claude call"
  else echo "FAIL: cross-dir id not refused rc=$rc out=$out"; fail=1; fi

  # One row of the shared prefix names a dir explicitly; the other recorded no
  # dir at all (config_dir IS NULL), which the ledger and the Go side both read
  # as the default dir. That must be just as ambiguous as two named dirs: this
  # regression-tests a bug where the NULL row's blank query-result line was
  # silently dropped by capturing sqlite3's output into a variable and
  # filtering it through `grep .` (what the code used to do) -- `grep .` drops
  # blank lines unconditionally, regardless of where they sort, collapsing the
  # two distinct dirs down to one and returning the explicit dir with exit 0
  # instead of refusing.
  sqlite3 "$cqdb" "
    INSERT INTO sessions VALUES ('ffffffff-1111-2222-3333-444444444444', '$tmp/.claude-other');
    INSERT INTO sessions VALUES ('ffffffff-9999-2222-3333-444444444444', NULL);
  "
  : >"$stoplog"; : >"$envlog"
  out="$(runcfg ffffffff 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && [ ! -s "$stoplog" ] && [ ! -s "$envlog" ] \
     && grep -qF 'more than one CLAUDE_CONFIG_DIR' <<<"$out"; then
    echo "ok: a NULL row and an explicit-dir row sharing a prefix are refused"
  else echo "FAIL: NULL-vs-explicit-dir prefix not refused rc=$rc out=$out"; fail=1; fi
else
  echo "skip: sqlite3 not available; config dir resolution not exercised"
fi

# --- sessions that are no longer running --------------------------------------
#
# A delegate whose process already ended (it timed out, the host went down) is
# not in the roster, but its work is still open in the ledger. Whether it may be
# closed is decided by the kind the ledger recorded, since the roster has none.

if command -v sqlite3 >/dev/null 2>&1; then
  kdb="$tmp/kind.db"
  sqlite3 "$kdb" "
    CREATE TABLE sessions (session_id TEXT PRIMARY KEY, config_dir TEXT, kind TEXT);
    INSERT INTO sessions VALUES ('11111111-1111-2222-3333-444444444444', NULL, 'background');
    INSERT INTO sessions VALUES ('22222222-1111-2222-3333-444444444444', NULL, 'interactive');
    INSERT INTO sessions VALUES ('33333333-1111-2222-3333-444444444444', NULL, NULL);
  "
  runk() { CLAUDE_QUEUE_DB="$kdb" run "$@"; }

  : >"$stoplog"; : >"$donelog"
  out="$(runk 11111111 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$stoplog" ] && [ "$(cat "$donelog")" = "11111111" ]; then
    echo "ok: a background session no longer running is marked done without a stop"
  else echo "FAIL: gone background rc=$rc out=$out donelog=$(cat "$donelog")"; fail=1; fi

  # The done mark fails (claude-queue exits 1): the mark is this path's only
  # effect, so it must end non-zero and must not claim "marked done".
  : >"$stoplog"
  out="$(PATH="$failbin:$stubbin:$PATH" CLAUDE_STUB_ROSTER="$roster" CLAUDE_STUB_STOPLOG="$stoplog" CLAUDE_QUEUE_DB="$kdb" "$src" 11111111 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && ! grep -qF 'is not running; marked done' <<<"$out"; then
    echo "ok: a gone session whose done mark fails exits non-zero without claiming it was marked"
  else echo "FAIL: failed mark on gone session rc=$rc out=$out"; fail=1; fi

  # The case the wrapper's grant must not cover: the user's own interactive
  # session, gone after a reboot. Closing it would drop their WIP from the list.
  # A row with no kind recorded is read as interactive.
  for sid in 22222222 33333333; do
    : >"$stoplog"; : >"$donelog"
    out="$(runk "$sid" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && [ ! -s "$stoplog" ] && [ ! -s "$donelog" ] \
       && grep -qF 'refusing to stop a interactive session' <<<"$out"; then
      echo "ok: a gone session the ledger records as interactive ($sid) is refused, done not written"
    else echo "FAIL: gone interactive $sid rc=$rc out=$out donelog=$(cat "$donelog")"; fail=1; fi
  done

  : >"$stoplog"; : >"$donelog"
  out="$(runk 44444444 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$stoplog" ] && [ ! -s "$donelog" ] && grep -qF 'nothing to do' <<<"$out"; then
    echo "ok: an id neither running nor in the ledger is a reported no-op"
  else echo "FAIL: unknown id rc=$rc out=$out"; fail=1; fi
else
  echo "skip: sqlite3 not available; ledger kind checks not exercised"
fi

exit "$fail"
