#!/usr/bin/env bash
# Functional tests for claude-reap-bg. A PATH stub stands in for the `claude`
# CLI (`agents --json` prints a fixture roster, `stop` records its argv) and
# CLAUDE_QUEUE_DB points at a fixture sqlite database, so every predicate can be
# exercised without a real session existing.
#
# bin/ is on PATH ahead of the stub dir's parent so the REAL claude-stop-bg runs
# in between: the point of routing through it is that its own guard still
# applies, and stubbing it out would test a shortcut this script does not take.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../bin/claude-reap-bg"
bindir="$here/../bin"
fail=0

for tool in jq sqlite3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "SKIP: $tool is required to run these tests"
    exit 0
  }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stubbin="$tmp/stubbin"
mkdir -p "$stubbin"
cat >"$stubbin/claude" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  agents) cat "$CLAUDE_STUB_ROSTER" ;;
  stop)   printf '%s\n' "$2" >>"$CLAUDE_STUB_STOPLOG" ;;
  *)      exit 1 ;;
esac
EOF
chmod +x "$stubbin/claude"

# Four background sessions plus one interactive, all `idle`. Only the id prefix
# matters downstream; the rest mirrors the real roster shape.
roster="$tmp/roster.json"
cat >"$roster" <<'EOF'
[
  {"pid":1,"cwd":"/w/ripe","kind":"background","sessionId":"aaaaaaaa-1111-2222-3333-444444444444","status":"idle"},
  {"pid":2,"cwd":"/w/fresh","kind":"background","sessionId":"bbbbbbbb-1111-2222-3333-444444444444","status":"idle"},
  {"pid":3,"cwd":"/w/asked","kind":"background","sessionId":"cccccccc-1111-2222-3333-444444444444","status":"idle"},
  {"pid":4,"cwd":"/w/busy","kind":"background","sessionId":"dddddddd-1111-2222-3333-444444444444","status":"busy"},
  {"pid":5,"cwd":"/w/human","kind":"interactive","sessionId":"eeeeeeee-1111-2222-3333-444444444444","status":"idle"},
  {"pid":6,"cwd":"/w/asked-meta","kind":"background","sessionId":"ffffffff-1111-2222-3333-444444444444","status":"idle"}
]
EOF

# Transcripts. `quiet` ends its last turn with a plain text reply; `asked` ends
# it with a SendMessage, i.e. a question the delegator has not answered yet.
quiet="$tmp/quiet.jsonl"
cat >"$quiet" <<'EOF'
{"type":"user","message":{"role":"user","content":"go do the thing"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"SendMessage","input":{}}]}}
{"type":"user","message":{"role":"user","content":"here is your answer"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
EOF

asked="$tmp/asked.jsonl"
cat >"$asked" <<'EOF'
{"type":"user","message":{"role":"user","content":"go do the thing"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"SendMessage","input":{}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"sent"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"waiting for the reply"}]}}
EOF

# `asked_meta` is `asked` with an isMeta injected entry (skill-launch style)
# tacked on after the SendMessage turn. isMeta entries are not something the
# human typed, so they must not count as a turn boundary -- if they did, the
# "last turn" window would start after this entry and would no longer contain
# the SendMessage, and the session would be wrongly stopped mid-question.
asked_meta="$tmp/asked_meta.jsonl"
cat >"$asked_meta" <<'EOF'
{"type":"user","message":{"role":"user","content":"go do the thing"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"SendMessage","input":{}}]}}
{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /x"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"waiting for the reply"}]}}
EOF

# Fixture database. Ages are relative to unixepoch() so the thresholds are
# exercised without freezing the clock.
#
# This DDL is a hand-written subset of src/claude-queue/internal/db/schema.go
# (the `Schema` constant) -- the source of truth. It intentionally drops
# `effective_state` and `priority` from the `queue` view because
# claude-reap-bg only ever reads `session_id`, `raw_state`, `created_at`, and
# `transcript_path`, plus the view's live-row filter (terminated_at IS NULL
# AND state != 'ended'). If schema.go's column names or that filter change,
# update this block to match.
db="$tmp/queue.db"
sqlite3 "$db" <<SQL
CREATE TABLE sessions (
  session_id      TEXT PRIMARY KEY,
  tmux_pane       TEXT,
  cwd             TEXT,
  transcript_path TEXT,
  started_at      INTEGER NOT NULL DEFAULT (unixepoch()),
  terminated_at   INTEGER
);
CREATE TABLE events (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(session_id),
  event_type TEXT NOT NULL,
  state      TEXT NOT NULL,
  payload    TEXT,
  created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE VIEW queue AS
SELECT s.session_id, s.tmux_pane, s.cwd, s.transcript_path,
       e.event_type, e.state AS raw_state, e.payload, e.created_at
FROM events e
JOIN (SELECT session_id, MAX(id) AS mid FROM events GROUP BY session_id) l
  ON e.id = l.mid
JOIN sessions s ON s.session_id = e.session_id
WHERE s.terminated_at IS NULL AND e.state != 'ended';

INSERT INTO sessions(session_id, transcript_path) VALUES
  ('aaaaaaaa-1111-2222-3333-444444444444', '$quiet'),
  ('bbbbbbbb-1111-2222-3333-444444444444', '$quiet'),
  ('cccccccc-1111-2222-3333-444444444444', '$asked'),
  ('dddddddd-1111-2222-3333-444444444444', '$quiet'),
  ('eeeeeeee-1111-2222-3333-444444444444', '$quiet'),
  ('ffffffff-1111-2222-3333-444444444444', '$asked_meta');

-- ripe: stopped 40 minutes ago. fresh: 2 minutes ago (under the threshold).
INSERT INTO events(session_id, event_type, state, created_at) VALUES
  ('aaaaaaaa-1111-2222-3333-444444444444', 'Stop', 'idle_done', unixepoch() - 2400),
  ('bbbbbbbb-1111-2222-3333-444444444444', 'Stop', 'idle_done', unixepoch() - 120),
  ('cccccccc-1111-2222-3333-444444444444', 'Stop', 'idle_done', unixepoch() - 2400),
  ('dddddddd-1111-2222-3333-444444444444', 'Stop', 'idle_done', unixepoch() - 2400),
  ('eeeeeeee-1111-2222-3333-444444444444', 'Stop', 'idle_done', unixepoch() - 2400),
  ('ffffffff-1111-2222-3333-444444444444', 'Stop', 'idle_done', unixepoch() - 2400);
SQL

stoplog="$tmp/stop.log"
run() {
  : >"$stoplog"
  PATH="$stubbin:$bindir:$PATH" \
    CLAUDE_STUB_ROSTER="$roster" CLAUDE_STUB_STOPLOG="$stoplog" \
    CLAUDE_QUEUE_DB="$db" "$src" "$@"
}
stopped() { grep -qF "$1" "$stoplog"; }

# The whole point: an idle background session whose turn ended long enough ago
# and which is not waiting on a reply gets stopped.
out="$(run 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && stopped aaaaaaaa; then
  echo "ok: idle background session past the threshold is stopped"
else echo "FAIL: ripe session not stopped rc=$rc out=$out"; fail=1; fi

# Under the threshold -> skipped. The turn may have ended seconds ago and the
# delegator may still be about to send the next message.
if ! stopped bbbbbbbb && grep -q 'bbbbbbbb.*threshold' <<<"$out"; then
  echo "ok: session under the idle threshold is skipped, with the reason"
else echo "FAIL: fresh session not skipped out=$out"; fail=1; fi

# Last turn ended with SendMessage -> skipped. This is the delegate that asked
# a question and is waiting; stopping it discards live work.
if ! stopped cccccccc && grep -q 'cccccccc.*SendMessage' <<<"$out"; then
  echo "ok: session whose last turn sent a SendMessage is skipped"
else echo "FAIL: asking session not skipped out=$out"; fail=1; fi

# An isMeta injected entry (skill-launch style) after the SendMessage must not
# be mistaken for a turn boundary -- otherwise the "last turn" window would
# start past it, no longer see the SendMessage, and the session would be
# wrongly stopped while still awaiting a reply.
if ! stopped ffffffff && grep -q 'ffffffff.*SendMessage' <<<"$out"; then
  echo "ok: an isMeta entry after SendMessage does not defeat the pending-reply guard"
else echo "FAIL: isMeta-confused session not skipped out=$out"; fail=1; fi

# status=="busy" -> never a candidate, so it is not even reported.
if ! stopped dddddddd && ! grep -q dddddddd <<<"$out"; then
  echo "ok: busy background session is not a candidate"
else echo "FAIL: busy session considered out=$out"; fail=1; fi

# kind=="interactive" -> never a candidate. A sweep that could touch the user's
# own session is the failure mode this tool must not have.
if ! stopped eeeeeeee && ! grep -q eeeeeeee <<<"$out"; then
  echo "ok: interactive session is not a candidate"
else echo "FAIL: interactive session considered out=$out"; fail=1; fi

# --dry-run reports the same decision but stops nothing.
out="$(run --dry-run 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$stoplog" ] && grep -q 'would reap' <<<"$out" && grep -q aaaaaaaa <<<"$out"; then
  echo "ok: --dry-run reports the candidate and stops nothing"
else echo "FAIL: dry-run rc=$rc stoplog=$(cat "$stoplog") out=$out"; fail=1; fi

# An explicit id restricts the sweep to that session.
out="$(run cccccccc 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$stoplog" ] && grep -q cccccccc <<<"$out" && ! grep -q aaaaaaaa <<<"$out"; then
  echo "ok: an explicit id restricts the sweep to that session"
else echo "FAIL: id filter rc=$rc out=$out"; fail=1; fi

# An id that is not a live idle background session is reported, not silently
# ignored, so the caller learns why nothing happened.
out="$(run eeeeeeee 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$stoplog" ] && grep -q 'eeeeeeee.*not a live idle background session' <<<"$out"; then
  echo "ok: a non-candidate id is reported as skipped"
else echo "FAIL: non-candidate id rc=$rc out=$out"; fail=1; fi

# --idle-minutes moves the threshold: at 1 minute the 2-minute-old session
# becomes reapable too. This proves the flag is wired to the comparison rather
# than merely accepted.
out="$(run --idle-minutes 1 --dry-run 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q bbbbbbbb <<<"$out" && ! grep -q 'bbbbbbbb.*threshold' <<<"$out"; then
  echo "ok: --idle-minutes lowers the threshold"
else echo "FAIL: --idle-minutes ignored rc=$rc out=$out"; fail=1; fi

# A non-numeric threshold is rejected before anything is stopped.
out="$(run --idle-minutes soon 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$stoplog" ]; then
  echo "ok: a non-numeric --idle-minutes is rejected"
else echo "FAIL: bad --idle-minutes accepted rc=$rc out=$out"; fail=1; fi

# A session with no queue row is skipped rather than stopped: without the
# ledger there is no timestamp to age, so the threshold cannot be checked.
noqueue="$tmp/noqueue.db"
sqlite3 "$db" ".dump" | sqlite3 "$noqueue"
sqlite3 "$noqueue" "DELETE FROM events WHERE session_id = 'aaaaaaaa-1111-2222-3333-444444444444';"
: >"$stoplog"
out="$(PATH="$stubbin:$bindir:$PATH" CLAUDE_STUB_ROSTER="$roster" CLAUDE_STUB_STOPLOG="$stoplog" \
  CLAUDE_QUEUE_DB="$noqueue" "$src" aaaaaaaa 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$stoplog" ] && grep -q 'aaaaaaaa.*no live claude-queue row' <<<"$out"; then
  echo "ok: a session with no queue row is skipped"
else echo "FAIL: missing queue row rc=$rc out=$out"; fail=1; fi

# A missing transcript is skipped: the pending-question check cannot run, and an
# unverifiable session must not be treated as a quiet one.
notx="$tmp/notx.db"
sqlite3 "$db" ".dump" | sqlite3 "$notx"
sqlite3 "$notx" "UPDATE sessions SET transcript_path = '$tmp/gone.jsonl' WHERE session_id = 'aaaaaaaa-1111-2222-3333-444444444444';"
: >"$stoplog"
out="$(PATH="$stubbin:$bindir:$PATH" CLAUDE_STUB_ROSTER="$roster" CLAUDE_STUB_STOPLOG="$stoplog" \
  CLAUDE_QUEUE_DB="$notx" "$src" aaaaaaaa 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$stoplog" ] && grep -q 'aaaaaaaa.*transcript' <<<"$out"; then
  echo "ok: an unreadable transcript is skipped"
else echo "FAIL: missing transcript rc=$rc out=$out"; fail=1; fi

# An unreadable roster must abort, not sweep: "claude agents failed" says
# nothing about which sessions are alive.
: >"$stoplog"
out="$(PATH="$stubbin:$bindir:$PATH" CLAUDE_STUB_ROSTER="$tmp/nope.json" CLAUDE_STUB_STOPLOG="$stoplog" \
  CLAUDE_QUEUE_DB="$db" "$src" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$stoplog" ]; then
  echo "ok: an unreadable roster aborts without stopping anything"
else echo "FAIL: unreadable roster swept rc=$rc out=$out"; fail=1; fi

# A missing database aborts for the same reason.
: >"$stoplog"
out="$(PATH="$stubbin:$bindir:$PATH" CLAUDE_STUB_ROSTER="$roster" CLAUDE_STUB_STOPLOG="$stoplog" \
  CLAUDE_QUEUE_DB="$tmp/absent.db" "$src" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$stoplog" ] && grep -q 'no claude-queue database' <<<"$out"; then
  echo "ok: a missing claude-queue database is refused"
else echo "FAIL: missing db rc=$rc out=$out"; fail=1; fi

exit "$fail"
