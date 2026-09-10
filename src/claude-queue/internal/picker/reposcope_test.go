package picker

import (
	"database/sql"
	"testing"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

func TestFilterSameRepo(t *testing.T) {
	rows := []db.Row{
		{SessionID: "a", Cwd: sql.NullString{String: "/repo/.worktrees/x", Valid: true}},
		{SessionID: "b", Cwd: sql.NullString{String: "/other", Valid: true}},
		{SessionID: "c", Cwd: sql.NullString{String: "/repo", Valid: true}},
		{SessionID: "d"}, // no cwd recorded
	}
	keyOf := func(cwd string) string {
		switch cwd {
		case "/repo", "/repo/.worktrees/x":
			return "/repo/.git"
		case "/other":
			return "/other/.git"
		default:
			return "" // "" cwd, or a cwd git cannot resolve
		}
	}
	got := filterSameRepo(rows, "/repo/.git", keyOf)
	if len(got) != 2 || got[0].SessionID != "a" || got[1].SessionID != "c" {
		t.Fatalf("filterSameRepo kept %v, want [a c]", ids(got))
	}
}

// A wantKey of "" (picker cwd not in a repo) must not sweep in the rows whose
// cwd also fails to resolve -- Run handles that case before calling the filter,
// but this pins the filter's raw behavior so a future caller change is noticed.
func TestFilterSameRepo_EmptyWantKeyMatchesNothingUseful(t *testing.T) {
	rows := []db.Row{
		{SessionID: "a", Cwd: sql.NullString{String: "/x", Valid: true}},
		{SessionID: "d"},
	}
	keyOf := func(string) string { return "" }
	got := filterSameRepo(rows, "", keyOf)
	// Every row resolves to "" here, so an empty wantKey would technically match
	// all of them. Run guards against ever calling with wantKey=="" -- this test
	// pins the filter's raw behavior so a future caller change is noticed.
	if len(got) != 2 {
		t.Fatalf("filterSameRepo with empty wantKey kept %d rows, want 2 (raw match)", len(got))
	}
}

func ids(rows []db.Row) []string {
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = r.SessionID
	}
	return out
}
