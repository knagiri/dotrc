// Package prwatch is the PR half of `claude-queue watch`: for every open
// session whose pin watches a PR, it reads the PR's reviews, comments and
// state with gh, and wakes the session with a message when there is something
// new -- a review or a comment, or the PR being merged or closed.
//
// The session woken is always the one that pinned itself (in practice the
// delegator, which is where a person's review lands too); see
// docs/design/claude-queue-lifecycle.md.
package prwatch

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

// PR states, as gh reports them.
const (
	StateOpen   = "OPEN"
	StateMerged = "MERGED"
	StateClosed = "CLOSED"
)

// Event kinds.
const (
	KindReview  = "review"
	KindComment = "comment"
)

// Activity is what Poll read off a PR.
type Activity struct {
	State  string
	Events []Event
}

// Event is one review or comment on the PR.
type Event struct {
	Kind   string
	Author string
	At     time.Time
	// Summary is the first non-empty line of the body, cut to summaryWidth.
	Summary string
	// ReviewState is a review's verdict (APPROVED, CHANGES_REQUESTED,
	// COMMENTED, ...); empty for a comment.
	ReviewState string
}

// summaryWidth bounds an event's summary, in runes: the message carries one
// line per event, and the session reads the PR itself for the rest.
const summaryWidth = 80

// Runner runs argv in dir and returns its stdout.
type Runner func(argv []string, dir string) ([]byte, error)

// Poll reads the PR pr (owner/repo#N, as db.ParsePRRef returns it) with gh,
// from dir.
//
// --repo is always passed, so the answer never depends on which repo dir is
// in: the pinned session's cwd may belong to another repo, or be gone. --json
// names exactly the fields needed, because the default view also asks for
// statusCheckRollup, which a fine-grained token cannot read
// (dot/claude/rules/gh-commands.md Sec1).
//
// Every review and comment counts, whoever wrote it. A delegate opens its PR
// with the person's own token, so the PR author is the person, and leaving out
// the author's activity would leave out the person's own review comments.
// Agents do not post on PRs (gh-commands.md Sec3), so nothing here is the
// woken session talking to itself.
func Poll(pr, dir string, run Runner) (Activity, error) {
	repo, num, ok := strings.Cut(pr, "#")
	if !ok || repo == "" || num == "" {
		return Activity{}, fmt.Errorf("bad PR reference %q", pr)
	}
	out, err := run([]string{"gh", "pr", "view", num, "--repo", repo, "--json", "state,reviews,comments"}, dir)
	if err != nil {
		return Activity{}, fmt.Errorf("gh pr view %s: %w", pr, err)
	}
	return parse(out)
}

type ghAuthor struct {
	Login string `json:"login"`
}

type ghView struct {
	State   string `json:"state"`
	Reviews []struct {
		Author      ghAuthor  `json:"author"`
		Body        string    `json:"body"`
		State       string    `json:"state"`
		SubmittedAt time.Time `json:"submittedAt"`
	} `json:"reviews"`
	Comments []struct {
		Author    ghAuthor  `json:"author"`
		Body      string    `json:"body"`
		CreatedAt time.Time `json:"createdAt"`
	} `json:"comments"`
}

func parse(data []byte) (Activity, error) {
	var v ghView
	if err := json.Unmarshal(data, &v); err != nil {
		return Activity{}, fmt.Errorf("parse gh pr view: %w", err)
	}
	if v.State == "" {
		return Activity{}, errors.New("parse gh pr view: no state")
	}
	a := Activity{State: v.State}
	for _, r := range v.Reviews {
		// A pending review is the reviewer's unsubmitted draft; it has no
		// submittedAt and nobody else can see it yet.
		if r.SubmittedAt.IsZero() {
			continue
		}
		a.Events = append(a.Events, Event{Kind: KindReview, Author: r.Author.Login, At: r.SubmittedAt, Summary: summary(r.Body), ReviewState: r.State})
	}
	for _, c := range v.Comments {
		a.Events = append(a.Events, Event{Kind: KindComment, Author: c.Author.Login, At: c.CreatedAt, Summary: summary(c.Body)})
	}
	sort.SliceStable(a.Events, func(i, j int) bool { return a.Events[i].At.Before(a.Events[j].At) })
	return a, nil
}

// summary is the first non-empty line of body, trimmed and cut to
// summaryWidth runes.
func summary(body string) string {
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if utf8.RuneCountInString(line) > summaryWidth {
			r := []rune(line)
			line = string(r[:summaryWidth-1]) + "…"
		}
		return line
	}
	return ""
}

// NewSince returns a's events newer than cursor, oldest first. An event at
// exactly the cursor is already delivered: the cursor is set to the newest
// delivered event's time.
func NewSince(a Activity, cursor time.Time) []Event {
	var out []Event
	for _, e := range a.Events {
		if e.At.After(cursor) {
			out = append(out, e)
		}
	}
	return out
}

// GhRunner runs gh the way bin/lib/gh-mise.sh does: under
// `MISE_ENV=gh mise exec -C <dir> --`, so a dotrc PR is read with the personal
// token mise.gh.local.toml supplies and any other repo falls back to
// hosts.yml. Without mise on PATH it runs gh directly, in the same dir.
//
// dir is the pinned session's cwd. One that no longer exists (a reaped
// worktree) is replaced by $HOME: --repo already says which PR, and a missing
// dir would only make the call fail.
func GhRunner(argv []string, dir string) ([]byte, error) {
	if dir == "" || !isDir(dir) {
		dir, _ = os.UserHomeDir()
	}
	_, err := exec.LookPath("mise")
	full := ghArgv(argv, dir, err == nil)
	cmd := exec.Command(full[0], full[1:]...)
	cmd.Dir = dir
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

// ghArgv is GhRunner's command line, split out so the token path can be
// asserted without running mise or gh.
func ghArgv(argv []string, dir string, haveMise bool) []string {
	if !haveMise {
		return argv
	}
	return append([]string{"env", "MISE_ENV=gh", "mise", "exec", "-C", dir, "--"}, argv...)
}

func isDir(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.IsDir()
}
