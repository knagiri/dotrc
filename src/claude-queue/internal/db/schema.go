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
  config_dir      TEXT,
  -- The events.id the session was manually marked "waiting" at (claude-queue
  -- mark, Tab in the picker). Non-NULL is marked, until it is toggled off;
  -- later events do not lift it. NULL is unmarked. Added by migrate() too, for
  -- the same reason as config_dir.
  waiting_event_id INTEGER,
  -- The work axis: when the session's work was declared finished. NULL is
  -- open. terminated_at is the process axis (NULL running, set gone) and says
  -- nothing about the work -- a reboot, a reconcile ForcedEnd or a background
  -- job timing out all set it on sessions whose work is still in flight. Only
  -- an explicit act writes done_at (see MarkDone), and nothing clears it: done
  -- is one-way. Added by migrate() too.
  done_at          INTEGER,
  -- How the session was started: 'interactive', 'background' (claude --bg) or
  -- 'print' (claude -p). NULL is unknown and reads as interactive. Recorded by
  -- the hook from its environment (hook.KindFromEnv), because the SessionEnd
  -- reason cannot tell them apart. Added by migrate() too.
  kind             TEXT,
  -- Free-text annotations, NULL when absent: memo is a note any open session
  -- can carry, pin_note says what a pinned session (waiting_event_id set) is
  -- waiting on. Both are flattened to one line on write (see SetMemo) because
  -- the picker lays them into a tab-separated line. Added by migrate() too.
  memo             TEXT,
  pin_note         TEXT
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
//
// It lists every open session (done_at IS NULL), running or gone. A gone
// session -- terminated_at set -- surfaces as the pseudo state 'gone' whatever
// its latest event says, sorted behind every running one: interrupted mid-task
// (6) ahead of finished-a-turn (7). prior_state is the latest non-ended state,
// which is what tells those two apart once the latest event is an end.
//
// tmux_pane is withheld from a gone session. The ledger never clears it -- the
// upsert COALESCEs it forward -- so on such a row it names the pane of a
// process that has ended, and pane ids are a per-server counter a fresh server
// restarts from %0: after a reboot the recorded id almost certainly resolves to
// an unrelated live pane. The picker's last-resort fallback trusts a ledger
// pane when the roster cannot be read, and honouring a gone row's pane there
// would switch to a stranger's pane instead of resuming. Where the session is
// in fact reachable the roster names its process and the picker re-derives the
// pane from its ancestry, so nothing is lost.
const View = `DROP VIEW IF EXISTS queue;
CREATE VIEW queue AS
SELECT
  s.session_id,
  CASE WHEN s.terminated_at IS NULL THEN s.tmux_pane END AS tmux_pane,
  s.cwd,
  s.transcript_path,
  s.config_dir,
  s.kind,
  e.event_type,
  e.state AS raw_state,
  e.payload,
  e.created_at,
  CASE
    WHEN s.terminated_at IS NOT NULL                                           THEN 'gone'
    WHEN e.state = 'working'           AND unixepoch() - e.created_at > 28800 THEN 'stale'
    WHEN e.state = 'awaiting_approval' AND unixepoch() - e.created_at >  7200 THEN 'stale'
    WHEN e.state = 'idle_done'         AND unixepoch() - e.created_at > 14400 THEN 'stale'
    ELSE e.state
  END AS effective_state,
  CASE
    WHEN s.terminated_at IS NOT NULL THEN
      CASE WHEN p.state IN ('working', 'awaiting_approval') THEN 6 ELSE 7 END
    WHEN e.state = 'awaiting_approval' AND unixepoch() - e.created_at <=  7200 THEN 1
    WHEN e.state = 'idle_done'         AND unixepoch() - e.created_at <= 14400 THEN 2
    WHEN e.state = 'working'           AND unixepoch() - e.created_at <= 28800 THEN 3
    ELSE 5
  END AS priority,
  p.state AS prior_state,
  CASE WHEN s.waiting_event_id IS NOT NULL THEN 1 ELSE 0 END AS marked,
  s.memo,
  s.pin_note
FROM events e
JOIN (SELECT session_id, MAX(id) AS mid FROM events GROUP BY session_id) l
  ON e.id = l.mid
JOIN sessions s ON s.session_id = e.session_id
LEFT JOIN events p ON p.id = (
  SELECT MAX(id) FROM events
  WHERE session_id = e.session_id AND state != 'ended'
)
WHERE s.done_at IS NULL;
`

// Pragmas are applied at Open, in order.
var Pragmas = []string{
	"PRAGMA journal_mode=WAL",
	"PRAGMA synchronous=NORMAL",
	"PRAGMA busy_timeout=5000",
	"PRAGMA foreign_keys=ON",
}
