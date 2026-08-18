package picker

import (
	"database/sql"
	"strings"
	"testing"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

func nowUnix() int64         { return 1_800_000_000 }
func nowMinus(d int64) int64 { return nowUnix() - d }

func TestFormatLine_AwaitingApproval(t *testing.T) {
	row := db.Row{
		SessionID:      "s1",
		TmuxPane:       sql.NullString{String: "%1", Valid: true},
		Cwd:            sql.NullString{String: "/home/x/projects/everysteel-api", Valid: true},
		EffectiveState: "awaiting_approval",
		Payload:        sql.NullString{String: `{"tool_name":"Bash","tool_input":{"command":"pnpm prisma migrate"}}`, Valid: true},
		CreatedAt:      nowMinus(120),
	}
	got := FormatLine(row, nowUnix(), false)
	fields := strings.Split(got, "\t")
	if len(fields) != 7 {
		t.Fatalf("want 7 tab-separated fields, got %d: %q", len(fields), got)
	}
	if fields[0] != "⏳" {
		t.Errorf("icon = %q, want ⏳", fields[0])
	}
	if fields[1] != "everysteel-api" {
		t.Errorf("cwd basename = %q, want everysteel-api", fields[1])
	}
	if !strings.Contains(fields[2], "Bash: pnpm prisma migrate") {
		t.Errorf("summary = %q", fields[2])
	}
	if fields[3] != "2m" {
		t.Errorf("age = %q, want 2m", fields[3])
	}
	if fields[4] != "s1" {
		t.Errorf("hidden session id = %q, want s1", fields[4])
	}
	if fields[5] != "%1" {
		t.Errorf("hidden tmux_pane = %q, want %%1", fields[5])
	}
	if fields[6] != "/home/x/projects/everysteel-api" {
		t.Errorf("hidden cwd = %q, want the full path", fields[6])
	}
}

func TestFormatAge(t *testing.T) {
	cases := []struct {
		sec  int64
		want string
	}{
		{30, "30s"},
		{119, "119s"},
		{120, "2m"},
		{60 * 59, "59m"},
		{60 * 60, "1h"},
		{60 * 60 * 24 * 2, "2d"},
	}
	for _, c := range cases {
		if got := formatAge(c.sec); got != c.want {
			t.Errorf("formatAge(%d) = %q, want %q", c.sec, got, c.want)
		}
	}
}

// A background session has no tmux pane, so the picker cannot switch to it --
// it has to open the session with `claude attach` instead. These cases pin the
// routing, which is the only part with branching worth testing; the exec calls
// themselves are one-liners in the multiplexer.
func TestDecideAction(t *testing.T) {
	const uuid = "61c846eb-8205-4a8e-8a0d-7772410051c9"

	got := DecideAction(uuid, "%12", "/w/a")
	if got.Kind != "switch" || got.Pane != "%12" {
		t.Errorf("with a pane: got %+v, want switch to %%12", got)
	}

	// `claude attach` only accepts the 8-char short id; passing the full UUID
	// fails with "No job matching".
	got = DecideAction(uuid, "", "/w/a")
	if got.Kind != "attach" || got.Short != "61c846eb" || got.Cwd != "/w/a" {
		t.Errorf("without a pane: got %+v, want attach 61c846eb in /w/a", got)
	}

	// A row with neither a pane nor a usable id is not actionable.
	got = DecideAction("", "", "/w/a")
	if got.Kind != "none" || got.Reason == "" {
		t.Errorf("empty session id: got %+v, want none with a reason", got)
	}

	// Short ids that are already <= 8 chars must not be sliced out of range.
	got = DecideAction("abc", "", "")
	if got.Kind != "attach" || got.Short != "abc" {
		t.Errorf("short session id: got %+v, want attach abc", got)
	}
}
