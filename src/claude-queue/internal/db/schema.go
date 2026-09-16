package db

// Tables is the table + index DDL applied at Open. Idempotent (IF NOT EXISTS).
//
// Split from View because migrate() has to run between the two: the view selects
// sessions.config_dir, which on a database created before that column existed is
// only there once the ALTER in migrate() has run.
const Tables = `
CREATE TABLE IF NOT EXISTS sessions (
  session_id      TEXT PRIMARY KEY,
  tmux_pane       TEXT,
  cwd             TEXT,
  transcript_path TEXT,
  started_at      INTEGER NOT NULL DEFAULT (unixepoch()),
  terminated_at   INTEGER,
  -- Which CLAUDE_CONFIG_DIR this session runs under. This one ledger records
  -- every session on the host (its path is keyed off $HOME), but the agent
  -- roster, the daemon behind it and the transcripts are all per config dir, so
  -- a row that does not say which dir it belongs to cannot be matched against
  -- any of them. NULL is every row written before the column existed, and reads
  -- as configdir.Default().
  --
  -- Added by migrate() as well, because CREATE TABLE IF NOT EXISTS is a no-op on
  -- an existing database and would leave the column off it forever.
  config_dir      TEXT
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

-- Delegation parent/child links, written by bin/claude-worktree through
-- ` + "`claude-queue link`" + `. The child is keyed by its 8-char short id because that
-- is all ` + "`claude --bg`" + ` prints, and its sessions row may not exist yet when the
-- link is written; readers join on substr(session_id, 1, 8). No FK to sessions
-- for the same reason, and because the parent's row can be GC'd first.
CREATE TABLE IF NOT EXISTS session_links (
  child_short       TEXT PRIMARY KEY,
  parent_session_id TEXT NOT NULL,
  created_at        INTEGER NOT NULL DEFAULT (unixepoch())
);
`

// View is the queue view, recreated at Open (DROP VIEW IF EXISTS) so a changed
// definition takes effect on an existing database.
const View = `DROP VIEW IF EXISTS queue;
CREATE VIEW queue AS
SELECT
  s.session_id,
  s.tmux_pane,
  s.cwd,
  s.transcript_path,
  s.config_dir,
  e.event_type,
  e.state AS raw_state,
  e.payload,
  e.created_at,
  CASE
    WHEN e.state = 'working'           AND unixepoch() - e.created_at > 28800 THEN 'stale'
    WHEN e.state = 'awaiting_approval' AND unixepoch() - e.created_at >  7200 THEN 'stale'
    WHEN e.state = 'idle_done'         AND unixepoch() - e.created_at > 14400 THEN 'stale'
    ELSE e.state
  END AS effective_state,
  CASE
    WHEN e.state = 'awaiting_approval' AND unixepoch() - e.created_at <=  7200 THEN 1
    WHEN e.state = 'idle_done'         AND unixepoch() - e.created_at <= 14400 THEN 2
    WHEN e.state = 'working'           AND unixepoch() - e.created_at <= 28800 THEN 3
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
