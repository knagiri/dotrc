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
  -- an explicit act writes done_at (see MarkDone), and only an explicit act
  -- clears it (Reopen): no hook event does, a resume included. Added by
  -- migrate() too.
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
  pin_note         TEXT,
  -- Retired: where the PR watch lived before pr_watches. Nothing reads or
  -- writes these seven any more except migratePRWatches, which moves what an
  -- older binary left here into pr_watches. Not dropped because that read
  -- needs the columns to exist. Added by migrate() too.
  pin_pr             TEXT,
  pin_cursor         TEXT,
  pin_seen_at        INTEGER,
  pin_delivered_at   INTEGER,
  pin_delivered_upto TEXT,
  pin_failures       INTEGER,
  pin_halted_upto    TEXT
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

-- The PRs a session watches: new reviews and comments, and a merge or close,
-- wake the session. Independent of the pin: a watching session is not waiting
-- on anything and may go on working. pr is owner/repo#N (see ParsePRRef).
-- cursor is the RFC3339 time of the newest PR activity already handed to the
-- session; seen_at is the unix time of the watch pass that first saw newer
-- activity not yet handed over (NULL when there is none), which is what the
-- one-tick debounce measures from. delivered_at is the unix time of the pass
-- that resumed the session with that activity, NULL when no delivery awaits
-- confirmation, and delivered_upto the RFC3339 time cursor moves to once the
-- session's UserPromptSubmit confirms it (NULL for a merge / close, whose
-- confirmation removes the row instead). failures counts the deliveries in a
-- row that no UserPromptSubmit confirmed (NULL is none); once it reaches the
-- cap, delivery stops, and halted_upto is the delivered_upto of the last
-- failed one (NULL for a merge / close), the activity that has to be outdone
-- for delivery to resume. Both are cleared when delivery resumes or is
-- confirmed, and when the watch is set again. note says what the watch is for,
-- flattened to one line like memo; a stop puts its mark in front of it.
CREATE TABLE IF NOT EXISTS pr_watches (
  session_id     TEXT NOT NULL REFERENCES sessions(session_id),
  pr             TEXT NOT NULL,
  cursor         TEXT,
  seen_at        INTEGER,
  delivered_at   INTEGER,
  delivered_upto TEXT,
  failures       INTEGER,
  halted_upto    TEXT,
  note           TEXT,
  PRIMARY KEY (session_id, pr)
);

-- Delegation parent/child links, written by bin/claude-worktree through
-- ` + "`claude-queue link`" + `. The child is keyed by its 8-char short id because that
-- is all ` + "`claude --bg`" + ` prints, and its sessions row may not exist yet when the
-- link is written; readers join on substr(session_id, 1, 8). No FK to sessions
-- for the same reason, and because the parent's row can be GC'd first.
CREATE TABLE IF NOT EXISTS session_links (
  child_short       TEXT PRIMARY KEY,
  parent_session_id TEXT NOT NULL,
  created_at        INTEGER NOT NULL DEFAULT (unixepoch()),
  -- What the delegate works on: repo is the GitHub owner/repo of the
  -- worktree's origin, branch the branch it was delegated on, both NULL when
  -- the delegator could not tell them. pr is the PR number found for that repo
  -- and branch, NULL until one is found. Added by migrate() too.
  repo              TEXT,
  branch            TEXT,
  pr                INTEGER
);

-- The picker's jump history, which ` + "`claude-queue nav back|forward`" + ` walks like
-- a browser's. One history for the whole host, not one per tmux client. Holds
-- session ids rather than panes: a pane id is re-derived when it is walked to,
-- for the reason the queue view withholds a gone session's pane. pos is a gap-free
-- run with the oldest entries lowest (a jump after going back drops the forward
-- side, and its pos is reused); see db.PushNav for the cap.
-- No FK to sessions, so GC can drop a session the history still names; the
-- walk skips it like any other session it cannot switch to.
CREATE TABLE IF NOT EXISTS nav_history (
  pos        INTEGER PRIMARY KEY,
  session_id TEXT NOT NULL
);

-- The history entry the user is at, as a nav_history.pos. A single row (id is
-- always 1); absent until the first jump is recorded.
CREATE TABLE IF NOT EXISTS nav_cursor (
  id  INTEGER PRIMARY KEY CHECK (id = 1),
  pos INTEGER NOT NULL
);
`

// View is the CREATE statement of the queue view. Open compares it with the
// definition stored in sqlite_master and recreates the view only when the two
// differ, so a changed definition takes effect on an existing database while
// an unchanged one is left alone (see applyView).
//
// It lists every open session (done_at IS NULL), running or gone. A gone
// session -- terminated_at set -- surfaces as the pseudo state 'gone' whatever
// its latest event says. prior_state is the latest non-ended state, which is
// what tells interrupted mid-task from finished-a-turn once the latest event
// is an end.
//
// activity_at is when that latest non-ended event was recorded (the latest
// event's time when there is none). An end -- hibernation, a reboot -- does
// not move it and a resume does, so ordering by it keeps a session that was
// merely put to sleep where its work left it.
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
const View = `CREATE VIEW queue AS
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
    WHEN s.terminated_at IS NOT NULL THEN 'gone'
    ELSE e.state
  END AS effective_state,
  COALESCE(p.created_at, e.created_at) AS activity_at,
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
WHERE s.done_at IS NULL`

// Pragmas are set on every connection the pool opens, through the DSN (see
// dsn). The order here does not matter: modernc.org/sqlite applies busy_timeout
// first and the rest in lexicographic order, so the later ones -- journal_mode
// takes a lock -- wait for a concurrent Open instead of failing with BUSY.
var Pragmas = []string{
	"busy_timeout(5000)",
	"journal_mode(WAL)",
	"synchronous(NORMAL)",
	"foreign_keys(1)",
}
