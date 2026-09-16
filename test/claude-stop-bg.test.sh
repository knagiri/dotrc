#!/usr/bin/env bash
# Functional tests for claude-stop-bg. A PATH stub stands in for the `claude`
# CLI: `agents --json` prints a fixture roster, `stop` records its argv. No real
# session is ever started, so the guard can be exercised exhaustively.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../bin/claude-stop-bg"
fail=0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

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
  stop)   printf '%s\n' "$2" >"$CLAUDE_STUB_STOPLOG" ;;
  *)      exit 1 ;;
esac
EOF
chmod +x "$stubbin/claude"

roster="$tmp/roster.json"
cat >"$roster" <<'EOF'
[
  {"pid":111,"cwd":"/w/a","kind":"background","sessionId":"aaaaaaaa-1111-2222-3333-444444444444","status":"idle"},
  {"pid":222,"cwd":"/w/b","kind":"interactive","sessionId":"bbbbbbbb-1111-2222-3333-444444444444","name":"dotrc-32","status":"busy"}
]
EOF

stoplog="$tmp/stop.log"
run() { PATH="$stubbin:$PATH" CLAUDE_STUB_ROSTER="$roster" CLAUDE_STUB_STOPLOG="$stoplog" "$src" "$@"; }

# background session -> stopped, and the SHORT id is what reaches `claude stop`.
: >"$stoplog"
run aaaaaaaa >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$stoplog")" = "aaaaaaaa" ]; then
  echo "ok: background session is stopped by short id"
else echo "FAIL: background stop rc=$rc stoplog=$(cat "$stoplog")"; fail=1; fi

# interactive session -> refused. This is the whole reason the wrapper exists:
# a broad `claude stop *` grant would let an agent kill the user's own session.
: >"$stoplog"
out="$(run bbbbbbbb 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$stoplog" ] && grep -q 'interactive' <<<"$out"; then
  echo "ok: interactive session is refused and never reaches claude stop"
else echo "FAIL: interactive not refused rc=$rc out=$out"; fail=1; fi

# unknown id -> refused (no session matches the prefix).
: >"$stoplog"
run cccccccc >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$stoplog" ]; then
  echo "ok: unknown short id is refused"
else echo "FAIL: unknown id accepted rc=$rc"; fail=1; fi

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
  # which is what every session ran under before a second dir existed.
  : >"$stoplog"; : >"$envlog"
  runcfg bbbbbbbb >/dev/null 2>&1
  if grep -qF "agents $tmp/.claude" "$envlog"; then
    echo "ok: an id the ledger does not know falls back to the default dir"
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

exit "$fail"
