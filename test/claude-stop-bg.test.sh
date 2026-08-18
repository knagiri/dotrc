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

# No argument -> usage error.
run >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: missing argument is rejected" \
  || { echo "FAIL: missing argument accepted"; fail=1; }

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

exit "$fail"
