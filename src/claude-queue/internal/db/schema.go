package db

// Schema is the full DDL applied at Open. Idempotent (IF NOT EXISTS).
const Schema = `
CREATE TABLE IF NOT EXISTS sessions (
  session_id      TEXT PRIMARY KEY,
  tmux_pane       TEXT,
  cwd             TEXT,
  transcript_path TEXT,
  started_at      INTEGER NOT NULL DEFAULT (unixepoch()),
  terminated_at   INTEGER
);

CREATE INDEX IF NOT EXISTS idx_sessions_pane_live
  ON sessions(tmux_pane) WHERE terminated_at IS NULL;

CREATE TABLE IF NOT EXISTS events (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(session_id),
  event_type TEXT NOT NULL,
  state      TEXT NOT NULL,
  payload    TEXT,
  created_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE INDEX IF NOT EXISTS idx_events_session_latest
  ON events(session_id, id DESC);

DROP VIEW IF EXISTS queue;
CREATE VIEW queue AS
SELECT
  s.session_id,
  s.tmux_pane,
  s.cwd,
  s.transcript_path,
  e.event_type,
  e.state AS raw_state,
  e.payload,
  e.created_at,
  CASE
    WHEN e.state = 'working'           AND unixepoch() - e.created_at > 3600 THEN 'stale'
    WHEN e.state = 'awaiting_approval' AND unixepoch() - e.created_at > 1800 THEN 'stale'
    WHEN e.state = 'idle_done'         AND unixepoch() - e.created_at >  900 THEN 'stale'
    ELSE e.state
  END AS effective_state,
  CASE
    WHEN e.state = 'awaiting_approval' AND unixepoch() - e.created_at <= 1800 THEN 1
    WHEN e.state = 'idle_done'         AND unixepoch() - e.created_at <=  900 THEN 2
    WHEN e.state = 'working'           AND unixepoch() - e.created_at <= 3600 THEN 3
    ELSE 5
  END AS priority
FROM events e
JOIN (SELECT session_id, MAX(id) AS mid FROM events GROUP BY session_id) l
  ON e.id = l.mid
JOIN sessions s ON s.session_id = e.session_id
WHERE s.terminated_at IS NULL
  AND e.state != 'ended';
`

// Pragmas are applied at Open, in order.
var Pragmas = []string{
	"PRAGMA journal_mode=WAL",
	"PRAGMA synchronous=NORMAL",
	"PRAGMA busy_timeout=5000",
	"PRAGMA foreign_keys=ON",
}
