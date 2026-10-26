package db

import (
	"database/sql"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
)

// ErrDone is returned by the annotation writers for a session whose work is
// done: it is no longer listed, so a memo or a pin on it would never be seen.
var ErrDone = errors.New("session is done")

// flatten turns the tabs and line breaks in a free-text annotation into spaces
// and trims it. A picker line is tab separated with hidden columns after the
// visible ones, so a tab or a newline left in the text would shift those
// columns onto another session's values.
func flatten(s string) string {
	return strings.TrimSpace(strings.NewReplacer("\t", " ", "\n", " ", "\r", " ").Replace(s))
}

// nullIfEmpty is the stored form of an annotation: empty is no annotation.
func nullIfEmpty(s string) sql.NullString {
	return sql.NullString{String: s, Valid: s != ""}
}

// SetMemo replaces the free-text memo on an open session. An empty text (after
// flattening) clears it.
func SetMemo(conn *sql.DB, sessionID, text string) error {
	return annotate(conn, "set memo", sessionID,
		"UPDATE sessions SET memo = ?2 WHERE session_id = ?1 AND done_at IS NULL",
		nullIfEmpty(flatten(text)))
}

// SetPin pins an open session -- marks it waiting on something outside it --
// and sets the pin's note. A session already pinned keeps the event id it was
// pinned at. A nil note keeps the existing note; a non-nil one replaces it,
// and an empty one clears it. Putting the pin on again lifts a stop on its
// PR's delivery (see FailPRDelivery): the person has looked at it.
func SetPin(conn *sql.DB, sessionID string, note *string) error {
	var keep bool
	var n sql.NullString
	if note == nil {
		keep = true
	} else {
		n = nullIfEmpty(flatten(*note))
	}
	return annotate(conn, "set pin", sessionID, `
		UPDATE sessions
		SET waiting_event_id = COALESCE(waiting_event_id,
		      (SELECT MAX(id) FROM events WHERE session_id = ?1), 0),
		    pin_note = CASE WHEN ?2 THEN pin_note ELSE ?3 END,
		    pin_failures = NULL, pin_halted_upto = NULL
		WHERE session_id = ?1 AND done_at IS NULL`, keep, n)
}

// ClearPin unpins an open session and drops the pin's note and PR watch.
func ClearPin(conn *sql.DB, sessionID string) error {
	return annotate(conn, "clear pin", sessionID, `
		UPDATE sessions
		SET waiting_event_id = NULL, pin_note = NULL, pin_pr = NULL, pin_cursor = NULL, pin_seen_at = NULL,
		    pin_delivered_at = NULL, pin_delivered_upto = NULL, pin_failures = NULL, pin_halted_upto = NULL
		WHERE session_id = ?1 AND done_at IS NULL`)
}

// ClearPRPin unpins a session whose watched PR has closed. It is ClearPin,
// except that it changes nothing unless the pin still watches pr: the person
// may have re-pinned the session on another PR while the delivery that
// precedes this ran, and that pin is not the one that closed.
func ClearPRPin(conn *sql.DB, sessionID, pr string) error {
	_, err := conn.Exec(`
		UPDATE sessions
		SET waiting_event_id = NULL, pin_note = NULL, pin_pr = NULL, pin_cursor = NULL, pin_seen_at = NULL,
		    pin_delivered_at = NULL, pin_delivered_upto = NULL, pin_failures = NULL, pin_halted_upto = NULL
		WHERE session_id = ?1 AND pin_pr = ?2`, sessionID, pr)
	if err != nil {
		return fmt.Errorf("clear PR pin: %w", err)
	}
	return nil
}

var (
	prShort = regexp.MustCompile(`^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([1-9][0-9]*)$`)
	prURL   = regexp.MustCompile(`^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)(?:[/?#].*)?$`)
)

// ParsePRRef reads a PR reference -- owner/repo#N or a github.com pull URL --
// and returns it as owner/repo#N, the form pin_pr stores. The repo is always
// part of it: the watch pass queries the PR with --repo rather than from the
// pinned session's cwd, which may belong to another repo or be gone.
func ParsePRRef(s string) (string, error) {
	s = strings.TrimSpace(s)
	for _, re := range []*regexp.Regexp{prShort, prURL} {
		if m := re.FindStringSubmatch(s); m != nil {
			return m[1] + "/" + m[2] + "#" + m[3], nil
		}
	}
	return "", fmt.Errorf("not a PR reference (want owner/repo#N or https://github.com/owner/repo/pull/N): %q", s)
}

// SetPinPR pins an open session (keeping a pin it already has, and its note)
// and makes the pin watch pr, which must already be in ParsePRRef's form. The
// cursor starts at now: what happened on the PR before the pin was put on is
// not news to the session that put it there.
func SetPinPR(conn *sql.DB, sessionID, pr string, now time.Time) error {
	return annotate(conn, "set pin", sessionID, `
		UPDATE sessions
		SET waiting_event_id = COALESCE(waiting_event_id,
		      (SELECT MAX(id) FROM events WHERE session_id = ?1), 0),
		    pin_pr = ?2, pin_cursor = ?3, pin_seen_at = NULL,
		    pin_delivered_at = NULL, pin_delivered_upto = NULL, pin_failures = NULL, pin_halted_upto = NULL
		WHERE session_id = ?1 AND done_at IS NULL`, pr, now.UTC().Format(time.RFC3339))
}

// PRPin is an open session whose pin watches a PR, with what a delivery to it
// needs.
type PRPin struct {
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
	// close, whose confirmation takes the pin off instead.
	DeliveredAt   int64
	DeliveredUpTo time.Time
	// Failures counts the deliveries in a row that were never confirmed. At
	// the cap, delivery has stopped, and HaltedUpTo is the DeliveredUpTo of
	// the last of them: activity newer than it resumes delivery. Zero for a
	// merge or close.
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

// PRPins returns every open, pinned session whose pin watches a PR. A done
// session is never watched: nobody is left to act on what the PR says.
func PRPins(conn *sql.DB) ([]PRPin, error) {
	rows, err := conn.Query(`
		SELECT session_id, pin_pr, COALESCE(pin_cursor, ''), COALESCE(pin_seen_at, 0),
		       COALESCE(pin_delivered_at, 0), COALESCE(pin_delivered_upto, ''),
		       COALESCE(pin_failures, 0), COALESCE(pin_halted_upto, ''),
		       COALESCE(cwd, ''), COALESCE(transcript_path, ''), config_dir, COALESCE(kind, ''),
		       terminated_at IS NOT NULL
		FROM sessions
		WHERE done_at IS NULL AND waiting_event_id IS NOT NULL AND pin_pr IS NOT NULL
		ORDER BY session_id`)
	if err != nil {
		return nil, fmt.Errorf("PR pins: %w", err)
	}
	defer rows.Close()
	var out []PRPin
	for rows.Next() {
		var p PRPin
		var cursor, upTo, halted string
		var dir sql.NullString
		if err := rows.Scan(&p.SessionID, &p.PR, &cursor, &p.SeenAt, &p.DeliveredAt, &upTo, &p.Failures, &halted, &p.Cwd, &p.TranscriptPath, &dir, &p.Kind, &p.Gone); err != nil {
			return nil, err
		}
		p.ConfigDir = ConfigDirOf(dir)
		if cursor != "" {
			t, err := time.Parse(time.RFC3339, cursor)
			if err != nil {
				return nil, fmt.Errorf("PR pin of %s: bad cursor %q: %w", p.SessionID, cursor, err)
			}
			p.Cursor = t
		}
		if upTo != "" {
			t, err := time.Parse(time.RFC3339, upTo)
			if err != nil {
				return nil, fmt.Errorf("PR pin of %s: bad delivered cursor %q: %w", p.SessionID, upTo, err)
			}
			p.DeliveredUpTo = t
		}
		if halted != "" {
			t, err := time.Parse(time.RFC3339, halted)
			if err != nil {
				return nil, fmt.Errorf("PR pin of %s: bad halted cursor %q: %w", p.SessionID, halted, err)
			}
			p.HaltedUpTo = t
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// SetPRSeen records (at > 0) or clears (at == 0) when a pass first saw
// activity on the session's PR that has not been delivered yet. Like every
// write the watch pass makes to a pin, it applies only while the pin still
// watches pr.
func SetPRSeen(conn *sql.DB, sessionID, pr string, at int64) error {
	_, err := conn.Exec(`UPDATE sessions SET pin_seen_at = ?3 WHERE session_id = ?1 AND pin_pr = ?2`,
		sessionID, pr, sql.NullInt64{Int64: at, Valid: at > 0})
	if err != nil {
		return fmt.Errorf("set PR seen: %w", err)
	}
	return nil
}

// AdvancePRCursor marks the PR's activity up to cursor as delivered and clears
// the pending mark, the delivery record and the count of failed deliveries,
// while the pin still watches pr.
func AdvancePRCursor(conn *sql.DB, sessionID, pr string, cursor time.Time) error {
	_, err := conn.Exec(`
		UPDATE sessions
		SET pin_cursor = ?3, pin_seen_at = NULL, pin_delivered_at = NULL, pin_delivered_upto = NULL,
		    pin_failures = NULL, pin_halted_upto = NULL
		WHERE session_id = ?1 AND pin_pr = ?2`,
		sessionID, pr, cursor.UTC().Format(time.RFC3339))
	if err != nil {
		return fmt.Errorf("advance PR cursor: %w", err)
	}
	return nil
}

// SetPRDelivered records (at > 0) that the session was resumed at unix time at
// with the PR's activity up to upTo (zero for a merge or close), or clears
// that record (at == 0), while the pin still watches pr. The cursor is not
// moved here: a resume that was launched may still fail inside its window, so
// the cursor waits for the session's own UserPromptSubmit (PromptSince).
func SetPRDelivered(conn *sql.DB, sessionID, pr string, at int64, upTo time.Time) error {
	var up sql.NullString
	if at > 0 && !upTo.IsZero() {
		up = sql.NullString{String: upTo.UTC().Format(time.RFC3339), Valid: true}
	}
	_, err := conn.Exec(`UPDATE sessions SET pin_delivered_at = ?3, pin_delivered_upto = ?4 WHERE session_id = ?1 AND pin_pr = ?2`,
		sessionID, pr, sql.NullInt64{Int64: at, Valid: at > 0}, up)
	if err != nil {
		return fmt.Errorf("set PR delivered: %w", err)
	}
	return nil
}

// FailPRDelivery records that the delivery on the session's pin was never
// confirmed, while the pin still watches pr: it drops the delivery record and
// counts one more failure in a row, which it returns. The count reaching max
// stops delivery: the delivery's upTo is kept as where newer activity resumes
// it (pin_halted_upto), and the pin's note gets the prefix note in front, so
// the stop shows in the picker -- once, however often it stops again. A
// return of 0 is a pin no longer watching pr, which changed nothing.
func FailPRDelivery(conn *sql.DB, sessionID, pr string, max int, upTo time.Time, note string) (int, error) {
	var up sql.NullString
	if !upTo.IsZero() {
		up = sql.NullString{String: upTo.UTC().Format(time.RFC3339), Valid: true}
	}
	var n int
	err := conn.QueryRow(`
		UPDATE sessions
		SET pin_delivered_at = NULL, pin_delivered_upto = NULL,
		    pin_failures = COALESCE(pin_failures, 0) + 1,
		    pin_halted_upto = CASE WHEN COALESCE(pin_failures, 0) + 1 >= ?3 THEN ?4 END,
		    pin_note = CASE
		      WHEN COALESCE(pin_failures, 0) + 1 < ?3 THEN pin_note
		      WHEN substr(COALESCE(pin_note, ''), 1, length(?5)) = ?5 THEN pin_note
		      ELSE rtrim(?5 || ' ' || COALESCE(pin_note, ''))
		    END
		WHERE session_id = ?1 AND pin_pr = ?2
		RETURNING pin_failures`, sessionID, pr, max, up, note).Scan(&n)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("fail PR delivery: %w", err)
	}
	return n, nil
}

// ResumePRDelivery lifts a stop on the PR's delivery (see FailPRDelivery),
// while the pin still watches pr. The pin's note keeps its prefix: the person
// may still want to know the resumes kept failing.
func ResumePRDelivery(conn *sql.DB, sessionID, pr string) error {
	_, err := conn.Exec(`UPDATE sessions SET pin_failures = NULL, pin_halted_upto = NULL WHERE session_id = ?1 AND pin_pr = ?2`, sessionID, pr)
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

// annotate runs an UPDATE that touches only an open sessionID (its first
// argument is ?1) and, when it changed nothing, tells a done session (ErrDone)
// from an unknown one (sql.ErrNoRows).
func annotate(conn *sql.DB, what, sessionID, query string, args ...any) error {
	res, err := conn.Exec(query, append([]any{sessionID}, args...)...)
	if err != nil {
		return fmt.Errorf("%s: %w", what, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("%s: %w", what, err)
	}
	if n > 0 {
		return nil
	}
	var done bool
	err = conn.QueryRow("SELECT done_at IS NOT NULL FROM sessions WHERE session_id = ?", sessionID).Scan(&done)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("%s: no session %s: %w", what, sessionID, err)
	}
	if err != nil {
		return fmt.Errorf("%s: %w", what, err)
	}
	if done {
		return fmt.Errorf("%s: %s: %w", what, sessionID, ErrDone)
	}
	return fmt.Errorf("%s: %s: nothing updated", what, sessionID)
}

// Memo returns the memo on sessionID, empty when it has none. Unlike the
// writers it reads a done session too.
func Memo(conn *sql.DB, sessionID string) (string, error) {
	var m sql.NullString
	if err := conn.QueryRow("SELECT memo FROM sessions WHERE session_id = ?", sessionID).Scan(&m); err != nil {
		return "", fmt.Errorf("read memo: %w", err)
	}
	return m.String, nil
}
