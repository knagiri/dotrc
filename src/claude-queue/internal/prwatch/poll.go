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

// Event is one review or comment on the PR. It deliberately carries neither
// the body nor the author's login: see Message.
type Event struct {
	Kind string
	// Bot is set when the author is a GitHub App or bot account (GraphQL
	// __typename Bot). A login is not enough to tell: the Copilot reviewer's
	// does not end in [bot].
	Bot bool
	At  time.Time
	// ReviewState is a review's verdict (APPROVED, CHANGES_REQUESTED,
	// COMMENTED, ...); empty for a comment.
	ReviewState string
}

// Runner runs argv in dir and returns its stdout.
type Runner func(argv []string, dir string) ([]byte, error)

// query asks for the PR's state and the newest 100 reviews and comments, with
// no body: nothing a PR's commenters wrote is read, so none of it can reach
// the woken session (see Message). A PR with more than 100 of either since
// the last delivery loses the oldest of them from the count only.
const query = `query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      state
      reviews(last: 100) { nodes { state submittedAt author { __typename } } }
      comments(last: 100) { nodes { createdAt author { __typename } } }
    }
  }
}`

// Poll reads the PR pr (owner/repo#N, as db.ParsePRRef returns it) with gh,
// from dir.
//
// The repo is always named in the query, so the answer never depends on which
// repo dir is in: the pinned session's cwd may belong to another repo, or be
// gone. It is a GraphQL query rather than `gh pr view --json` because only
// GraphQL says whether an author is a bot, and it names exactly the fields
// needed -- the default view also asks for statusCheckRollup, which a
// fine-grained token cannot read (dot/claude/rules/gh-commands.md Sec1).
//
// Every review and comment counts, whoever wrote it. A delegate opens its PR
// with the person's own token, so the PR author is the person, and leaving out
// the author's activity would leave out the person's own review comments.
// Agents do not post on PRs (gh-commands.md Sec3), so nothing here is the
// woken session talking to itself.
func Poll(pr, dir string, run Runner) (Activity, error) {
	repo, num, ok := strings.Cut(pr, "#")
	owner, name, ok2 := strings.Cut(repo, "/")
	if !ok || !ok2 || owner == "" || name == "" || num == "" {
		return Activity{}, fmt.Errorf("bad PR reference %q", pr)
	}
	out, err := run([]string{"gh", "api", "graphql", "-f", "query=" + query,
		"-F", "owner=" + owner, "-F", "repo=" + name, "-F", "number=" + num}, dir)
	if err != nil {
		return Activity{}, fmt.Errorf("gh api graphql %s: %w", pr, err)
	}
	return parse(out)
}

type ghAuthor struct {
	Typename string `json:"__typename"`
}

type ghView struct {
	Data struct {
		Repository struct {
			PullRequest *struct {
				State   string `json:"state"`
				Reviews struct {
					Nodes []struct {
						State       string    `json:"state"`
						SubmittedAt time.Time `json:"submittedAt"`
						Author      *ghAuthor `json:"author"`
					} `json:"nodes"`
				} `json:"reviews"`
				Comments struct {
					Nodes []struct {
						CreatedAt time.Time `json:"createdAt"`
						Author    *ghAuthor `json:"author"`
					} `json:"nodes"`
				} `json:"comments"`
			} `json:"pullRequest"`
		} `json:"repository"`
	} `json:"data"`
}

// isBot reads an author, which is null for a deleted account.
func isBot(a *ghAuthor) bool { return a != nil && a.Typename == "Bot" }

func parse(data []byte) (Activity, error) {
	var v ghView
	if err := json.Unmarshal(data, &v); err != nil {
		return Activity{}, fmt.Errorf("parse gh api graphql: %w", err)
	}
	pr := v.Data.Repository.PullRequest
	if pr == nil || pr.State == "" {
		return Activity{}, errors.New("parse gh api graphql: no pull request state")
	}
	a := Activity{State: pr.State}
	for _, r := range pr.Reviews.Nodes {
		// A pending review is the reviewer's unsubmitted draft; it has no
		// submittedAt and nobody else can see it yet.
		if r.SubmittedAt.IsZero() {
			continue
		}
		a.Events = append(a.Events, Event{Kind: KindReview, Bot: isBot(r.Author), At: r.SubmittedAt, ReviewState: r.State})
	}
	for _, c := range pr.Comments.Nodes {
		a.Events = append(a.Events, Event{Kind: KindComment, Bot: isBot(c.Author), At: c.CreatedAt})
	}
	sort.SliceStable(a.Events, func(i, j int) bool { return a.Events[i].At.Before(a.Events[j].At) })
	return a, nil
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
