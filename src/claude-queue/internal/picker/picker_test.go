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
	if len(fields) != 6 {
		t.Fatalf("want 6 tab-separated fields, got %d: %q", len(fields), got)
	}
	if fields[0] != "⏳" {
		t.Errorf("icon = %q, want ⏳", fields[0])
	}
	if !strings.Contains(fields[1], "Bash: pnpm prisma migrate") {
		t.Errorf("summary = %q", fields[1])
	}
	if fields[2] != "everysteel-api" {
		t.Errorf("cwd basename = %q, want everysteel-api", fields[2])
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
