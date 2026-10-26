package prwatch

import (
	"database/sql"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/hibernate"
)

// DefaultDebounce is how long new activity must have been pending before it is
// delivered: one tick of the 3-minute timer, less a margin for the timer's
// jitter and for how far into a pass the clock is read. A bot review arrives
// as a burst of comments, and this hands the whole burst over in one wake-up
// instead of one per comment.
const DefaultDebounce = 2 * time.Minute

// Message is what a woken session is given as its first input.
func Message(pr string, a Activity, events []Event) string {
	switch a.State {
	case StateMerged:
		return fmt.Sprintf("PR %s が merge されました。次の作業を整理してください。", pr)
	case StateClosed:
		return fmt.Sprintf("PR %s が merge されずに close されました。状況を確認してください。", pr)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "PR %s に新しい活動があります。\n", pr)
	for _, e := range events {
		what := "comment"
		if e.Kind == KindReview {
			what = strings.ToLower(e.ReviewState)
		}
		fmt.Fprintf(&b, "- %s: %s %s\n", e.Author, what, e.Summary)
	}
	b.WriteString("内容を読み、修正の要否を判断してください。修正は同じ worktree で新しい委譲先を起こして行ってください（delegate-to-worktree）。")
	return b.String()
}

// Pass checks every PR pin once and delivers what is due. It returns the
// sessions it resumed, which the same watch pass must not then hibernate. Like
// the rest of the watch pass it reports failures as lines on out and goes on.
//
// For one pin:
//   - a merged or closed PR is delivered at once, and the pin comes off once
//     the delivery succeeded;
//   - activity newer than the cursor is delivered once it has been pending for
//     debounce (see DefaultDebounce): the first pass that sees it only records
//     when it did. The cursor moves to the newest delivered event only after
//     the delivery succeeded, so a skipped or failed one is retried by the
//     next pass with everything that piled up meanwhile, and nothing is
//     handed over twice;
//   - no new activity clears a pending mark left by activity that is no
//     longer there (a deleted comment).
//
// A pin whose PR cannot be read (gh failed: a token, the network) is skipped
// and the other pins go on.
func Pass(conn *sql.DB, now time.Time, debounce time.Duration, deps Deps, out io.Writer) map[string]bool {
	resumed := map[string]bool{}
	pins, err := db.PRPins(conn)
	if err != nil {
		fmt.Fprintln(out, "pr-watch: failed:", err)
		return resumed
	}
	for _, p := range pins {
		id := short(p.SessionID)
		a, err := deps.Poll(p.PR, p.Cwd)
		if err != nil {
			fmt.Fprintf(out, "pr-watch: skipped %s (%s): %v\n", id, p.PR, err)
			continue
		}
		events := NewSince(a, p.Cursor)
		closed := a.State == StateMerged || a.State == StateClosed
		if !closed {
			switch {
			case len(events) == 0:
				if p.SeenAt != 0 {
					report(out, db.SetPRSeen(conn, p.SessionID, p.PR, 0))
				}
				continue
			case p.SeenAt == 0:
				report(out, db.SetPRSeen(conn, p.SessionID, p.PR, now.Unix()))
				fmt.Fprintf(out, "pr-watch: %s (%s): %d new event(s), delivering on a later pass\n", id, p.PR, len(events))
				continue
			case now.Sub(time.Unix(p.SeenAt, 0)) < debounce:
				fmt.Fprintf(out, "pr-watch: %s (%s): %d new event(s), pending for %s\n", id, p.PR, len(events), hibernate.Minutes(now.Sub(time.Unix(p.SeenAt, 0))))
				continue
			}
		}

		switch err := Deliver(p, Message(p.PR, a, events), deps); {
		case hibernate.IsSkip(err):
			fmt.Fprintf(out, "pr-watch: skipped %s (%s): %v\n", id, p.PR, err)
			continue
		case err != nil:
			fmt.Fprintf(out, "pr-watch: failed %s (%s): %v\n", id, p.PR, err)
			continue
		}
		resumed[p.SessionID] = true
		if closed {
			report(out, db.ClearPRPin(conn, p.SessionID, p.PR))
			fmt.Fprintf(out, "pr-watch: woke %s (%s %s), unpinned\n", id, p.PR, strings.ToLower(a.State))
			continue
		}
		report(out, db.AdvancePRCursor(conn, p.SessionID, p.PR, events[len(events)-1].At))
		fmt.Fprintf(out, "pr-watch: woke %s (%s: %d new event(s))\n", id, p.PR, len(events))
	}
	return resumed
}

func report(out io.Writer, err error) {
	if err != nil {
		fmt.Fprintln(out, "pr-watch: failed:", err)
	}
}

func short(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}
