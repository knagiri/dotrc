package db

import (
	"database/sql"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
)

var (
	prShort = regexp.MustCompile(`^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([1-9][0-9]*)$`)
	prURL   = regexp.MustCompile(`^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)(?:[/?#].*)?$`)
)

// ParsePRRef reads a PR reference -- owner/repo#N or a github.com pull URL --
// and returns it as owner/repo#N, the form pr_watches stores. The repo is
// always part of it: the watch pass queries the PR with --repo rather than
// from the watching session's cwd, which may belong to another repo or be gone.
func ParsePRRef(s string) (string, error) {
	s = strings.TrimSpace(s)
	for _, re := range []*regexp.Regexp{prShort, prURL} {
		if m := re.FindStringSubmatch(s); m != nil {
			return m[1] + "/" + m[2] + "#" + m[3], nil
		}
	}
	return "", fmt.Errorf("not a PR reference (want owner/repo#N or https://github.com/owner/repo/pull/N): %q", s)
}

// SetPRWatch makes an open session watch pr, which must already be in
// ParsePRRef's form. The cursor starts at now: what happened on the PR before
// the watch was set is not news to the session that set it. Setting it again
// on the same PR moves the cursor to now and drops its delivery record and any
// stop on its delivery (see FailPRDelivery). A nil note keeps the existing
// note; a non-nil one replaces it, and an empty one clears it.
//
// A watch is independent of the pin: the session stays free to go on working,
// and is not marked waiting.
func SetPRWatch(conn *sql.DB, sessionID, pr string, note *string, now time.Time) error {
	var keep bool
	var n sql.NullString
	if note == nil {
		keep = true
	} else {
		n = nullIfEmpty(flatten(*note))
	}
	return annotate(conn, "set PR watch", sessionID, `
		INSERT INTO pr_watches(session_id, pr, cursor, note)
		SELECT session_id, ?2, ?3, ?5 FROM sessions WHERE session_id = ?1 AND done_at IS NULL
		ON CONFLICT(session_id, pr) DO UPDATE SET
		  cursor = excluded.cursor, seen_at = NULL, delivered_at = NULL, delivered_upto = NULL,
		  failures = NULL, halted_upto = NULL,
		  note = CASE WHEN ?4 THEN note ELSE excluded.note END`,
		pr, now.UTC().Format(time.RFC3339), keep, n)
}

// ClearPRWatch stops the session watching pr and reports how many watches that
// removed (0 or 1). The pin is not touched.
func ClearPRWatch(conn *sql.DB, sessionID, pr string) (int64, error) {
	res, err := conn.Exec("DELETE FROM pr_watches WHERE session_id = ? AND pr = ?", sessionID, pr)
	if err != nil {
		return 0, fmt.Errorf("clear PR watch: %w", err)
	}
	return res.RowsAffected()
}

// ClearPRWatches stops every watch of the session and reports how many that
// removed. The pin is not touched.
func ClearPRWatches(conn *sql.DB, sessionID string) (int64, error) {
	res, err := conn.Exec("DELETE FROM pr_watches WHERE session_id = ?", sessionID)
	if err != nil {
		return 0, fmt.Errorf("clear PR watches: %w", err)
	}
	return res.RowsAffected()
}

// PRWatch is one PR an open session watches, with what a delivery to it needs.
type PRWatch struct {
	SessionID string
	PR        string
	// Cursor is the time of the newest activity already delivered.
	Cursor time.Time
	// SeenAt is the unix time newer activity was first seen, 0 when none is
	// pending.
	SeenAt int64
	// DeliveredAt is the unix time of the pass that resumed the session with
	// activity it has not yet been seen to take in, 0 when there is none.
	// DeliveredUpTo is where Cursor moves once it has; zero for a merge or
	// close, whose confirmation removes the watch instead.
	DeliveredAt   int64
	DeliveredUpTo time.Time
	// Failures counts the deliveries in a row that were never confirmed. At
	// the cap, delivery has stopped, and HaltedUpTo is the DeliveredUpTo of
	// the last of them: activity newer than it resumes delivery.
	// HaltedUpTo is zero when the stopped delivery was a merge or close.
	Failures       int
	HaltedUpTo     time.Time
	Cwd            string
	TranscriptPath string
	ConfigDir      string
	// Kind is sessions.kind; "" is unknown and reads as interactive.
	Kind string
	// Gone is the process axis: the session's process has ended.
	Gone bool
}

// PRWatches returns every watch of an open session, pinned or not, running or
// gone. A done session is never watched: nobody is left to act on what the PR
// says.
func PRWatches(conn *sql.DB) ([]PRWatch, error) {
	rows, err := conn.Query(`
		SELECT w.session_id, w.pr, COALESCE(w.cursor, ''), COALESCE(w.seen_at, 0),
		       COALESCE(w.delivered_at, 0), COALESCE(w.delivered_upto, ''),
		       COALESCE(w.failures, 0), COALESCE(w.halted_upto, ''),
		       COALESCE(s.cwd, ''), COALESCE(s.transcript_path, ''), s.config_dir, COALESCE(s.kind, ''),
		       s.terminated_at IS NOT NULL
		FROM pr_watches w
		JOIN sessions s ON s.session_id = w.session_id
		WHERE s.done_at IS NULL
		ORDER BY w.session_id, w.pr`)
	if err != nil {
		return nil, fmt.Errorf("PR watches: %w", err)
	}
	defer rows.Close()
	var out []PRWatch
	for rows.Next() {
		var p PRWatch
		var cursor, upTo, halted string
		var dir sql.NullString
		if err := rows.Scan(&p.SessionID, &p.PR, &cursor, &p.SeenAt, &p.DeliveredAt, &upTo, &p.Failures, &halted, &p.Cwd, &p.TranscriptPath, &dir, &p.Kind, &p.Gone); err != nil {
			return nil, err
		}
		p.ConfigDir = ConfigDirOf(dir)
		if cursor != "" {
			t, err := time.Parse(time.RFC3339, cursor)
			if err != nil {
				return nil, fmt.Errorf("PR watch of %s: bad cursor %q: %w", p.SessionID, cursor, err)
			}
			p.Cursor = t
		}
		if upTo != "" {
			t, err := time.Parse(time.RFC3339, upTo)
			if err != nil {
				return nil, fmt.Errorf("PR watch of %s: bad delivered cursor %q: %w", p.SessionID, upTo, err)
			}
			p.DeliveredUpTo = t
		}
		if halted != "" {
			t, err := time.Parse(time.RFC3339, halted)
			if err != nil {
				return nil, fmt.Errorf("PR watch of %s: bad halted cursor %q: %w", p.SessionID, halted, err)
			}
			p.HaltedUpTo = t
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// SetPRSeen records (at > 0) or clears (at == 0) when a pass first saw
// activity on the PR that has not been delivered yet. Like every write the
// watch pass makes, it changes nothing once the session no longer watches pr.
func SetPRSeen(conn *sql.DB, sessionID, pr string, at int64) error {
	_, err := conn.Exec(`UPDATE pr_watches SET seen_at = ?3 WHERE session_id = ?1 AND pr = ?2`,
		sessionID, pr, sql.NullInt64{Int64: at, Valid: at > 0})
	if err != nil {
		return fmt.Errorf("set PR seen: %w", err)
	}
	return nil
}

// AdvancePRCursor marks the PR's activity up to cursor as delivered and clears
// the pending mark, the delivery record and the count of failed deliveries.
func AdvancePRCursor(conn *sql.DB, sessionID, pr string, cursor time.Time) error {
	_, err := conn.Exec(`
		UPDATE pr_watches
		SET cursor = ?3, seen_at = NULL, delivered_at = NULL, delivered_upto = NULL,
		    failures = NULL, halted_upto = NULL
		WHERE session_id = ?1 AND pr = ?2`,
		sessionID, pr, cursor.UTC().Format(time.RFC3339))
	if err != nil {
		return fmt.Errorf("advance PR cursor: %w", err)
	}
	return nil
}

// SetPRDelivered records (at > 0) that a resume of the session is attempted at
// unix time at with the PR's activity up to upTo (zero for a merge or close), or
// clears that record (at == 0). The cursor is not moved here: a resume may still
// fail inside its window, so the cursor waits for the session's own
// UserPromptSubmit (PromptSince).
func SetPRDelivered(conn *sql.DB, sessionID, pr string, at int64, upTo time.Time) error {
	var up sql.NullString
	if at > 0 && !upTo.IsZero() {
		up = sql.NullString{String: upTo.UTC().Format(time.RFC3339), Valid: true}
	}
	_, err := conn.Exec(`UPDATE pr_watches SET delivered_at = ?3, delivered_upto = ?4 WHERE session_id = ?1 AND pr = ?2`,
		sessionID, pr, sql.NullInt64{Int64: at, Valid: at > 0}, up)
	if err != nil {
		return fmt.Errorf("set PR delivered: %w", err)
	}
	return nil
}

// FailPRDelivery records that the delivery on the watch was never confirmed:
// it drops the delivery record and counts one more failure in a row, which it
// returns. The count reaching max stops delivery: the delivery's upTo is kept
// as where newer activity resumes it (halted_upto), and the watch's note gets
// the prefix note in front, so the stop can be seen -- once, however often it
// stops again. A return of 0 is a session no longer watching pr, which changed
// nothing.
func FailPRDelivery(conn *sql.DB, sessionID, pr string, max int, upTo time.Time, note string) (int, error) {
	var up sql.NullString
	if !upTo.IsZero() {
		up = sql.NullString{String: upTo.UTC().Format(time.RFC3339), Valid: true}
	}
	var n int
	err := conn.QueryRow(`
		UPDATE pr_watches
		SET delivered_at = NULL, delivered_upto = NULL,
		    failures = COALESCE(failures, 0) + 1,
		    halted_upto = CASE WHEN COALESCE(failures, 0) + 1 >= ?3 THEN ?4 END,
		    note = CASE
		      WHEN COALESCE(failures, 0) + 1 < ?3 THEN note
		      WHEN substr(COALESCE(note, ''), 1, length(?5)) = ?5 THEN note
		      ELSE rtrim(?5 || ' ' || COALESCE(note, ''))
		    END
		WHERE session_id = ?1 AND pr = ?2
		RETURNING failures`, sessionID, pr, max, up, note).Scan(&n)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("fail PR delivery: %w", err)
	}
	return n, nil
}

// ResumePRDelivery lifts a stop on the PR's delivery (see FailPRDelivery). It
// also clears seen_at: the pending mark left from before the stop would
// otherwise count as an elapsed debounce for the next activity. The note keeps
// its prefix: the person may still want to know the resumes kept failing.
func ResumePRDelivery(conn *sql.DB, sessionID, pr string) error {
	_, err := conn.Exec(`UPDATE pr_watches SET failures = NULL, halted_upto = NULL, seen_at = NULL WHERE session_id = ?1 AND pr = ?2`, sessionID, pr)
	if err != nil {
		return fmt.Errorf("resume PR delivery: %w", err)
	}
	return nil
}

// PromptSince reports whether the ledger has a UserPromptSubmit event of
// sessionID recorded at or after unix time at.
func PromptSince(conn *sql.DB, sessionID string, at int64) (bool, error) {
	var ok bool
	err := conn.QueryRow(`
		SELECT EXISTS (SELECT 1 FROM events
		               WHERE session_id = ? AND event_type = 'UserPromptSubmit' AND created_at >= ?)`,
		sessionID, at).Scan(&ok)
	if err != nil {
		return false, fmt.Errorf("prompt since: %w", err)
	}
	return ok, nil
}
