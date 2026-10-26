package prwatch

import (
	"errors"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"
)

var fixture = `{
  "state": "OPEN",
  "reviews": [
    {"author": {"login": "example-bot[bot]"}, "body": "\n### Needs a closer look\n\ndetails", "state": "COMMENTED", "submittedAt": "2026-10-26T10:05:00Z"},
    {"author": {"login": "example-user"}, "body": "", "state": "PENDING", "submittedAt": null},
    {"author": {"login": "example-user"}, "body": "rename this", "state": "CHANGES_REQUESTED", "submittedAt": "2026-10-26T10:01:00Z"}
  ],
  "comments": [
    {"author": {"login": "example-user"}, "body": "` + "x" + strings.Repeat("y", 100) + `", "createdAt": "2026-10-26T10:03:00Z"}
  ]
}`

func at(hhmm string) time.Time {
	t, err := time.Parse(time.RFC3339, "2026-10-26T"+hhmm+":00Z")
	if err != nil {
		panic(err)
	}
	return t
}

func stub(out string, err error, got *[]string, gotDir *string) Runner {
	return func(argv []string, dir string) ([]byte, error) {
		*got, *gotDir = argv, dir
		return []byte(out), err
	}
}

func TestPoll_ParsesReviewsAndComments(t *testing.T) {
	var argv []string
	var dir string
	a, err := Poll("example-org/example-repo#12", "/w", stub(fixture, nil, &argv, &dir))
	if err != nil {
		t.Fatal(err)
	}
	if a.State != StateOpen {
		t.Errorf("State = %q", a.State)
	}
	want := []Event{
		{Kind: KindReview, Author: "example-user", At: at("10:01"), Summary: "rename this", ReviewState: "CHANGES_REQUESTED"},
		{Kind: KindComment, Author: "example-user", At: at("10:03"), Summary: "x" + strings.Repeat("y", 78) + "…"},
		{Kind: KindReview, Author: "example-bot[bot]", At: at("10:05"), Summary: "### Needs a closer look", ReviewState: "COMMENTED"},
	}
	if !reflect.DeepEqual(a.Events, want) {
		t.Errorf("Events =\n%+v\nwant\n%+v", a.Events, want)
	}
}

// The repo comes from the pin, never from the cwd, and only
// the needed fields are asked for (no statusCheckRollup).
func TestPoll_PassesRepo(t *testing.T) {
	var argv []string
	var dir string
	if _, err := Poll("example-org/example-repo#12", "/elsewhere", stub(fixture, nil, &argv, &dir)); err != nil {
		t.Fatal(err)
	}
	want := []string{"gh", "pr", "view", "12", "--repo", "example-org/example-repo", "--json", "state,reviews,comments"}
	if !slices.Equal(argv, want) || dir != "/elsewhere" {
		t.Errorf("ran %q in %q, want %q", argv, dir, want)
	}
}

// A failing gh is an error, not an empty PR.
func TestPoll_GhErrorSkipsPin(t *testing.T) {
	var argv []string
	var dir string
	if _, err := Poll("example-org/example-repo#12", "/w", stub("", errors.New("HTTP 401"), &argv, &dir)); err == nil || !strings.Contains(err.Error(), "HTTP 401") {
		t.Errorf("err = %v", err)
	}
	if _, err := Poll("example-org/example-repo#12", "/w", stub(`{"reviews": []}`, nil, &argv, &dir)); err == nil {
		t.Error("an answer without a state was accepted")
	}
}

func TestNewSince_Boundary(t *testing.T) {
	a := Activity{Events: []Event{{At: at("10:01")}, {At: at("10:03")}, {At: at("10:05")}}}
	got := NewSince(a, at("10:03"))
	if len(got) != 1 || !got[0].At.Equal(at("10:05")) {
		t.Errorf("NewSince = %+v", got)
	}
	if got := NewSince(a, time.Time{}); len(got) != 3 {
		t.Errorf("NewSince(zero) = %d events", len(got))
	}
}

func TestGhArgv_TokenPath(t *testing.T) {
	gh := []string{"gh", "pr", "view", "1"}
	if got, want := ghArgv(gh, "/w", true), []string{"env", "MISE_ENV=gh", "mise", "exec", "-C", "/w", "--", "gh", "pr", "view", "1"}; !slices.Equal(got, want) {
		t.Errorf("with mise: %q", got)
	}
	if got := ghArgv(gh, "/w", false); !slices.Equal(got, gh) {
		t.Errorf("without mise: %q", got)
	}
}
