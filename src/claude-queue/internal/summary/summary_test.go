package summary

import (
	"strings"
	"testing"

	"github.com/mattn/go-runewidth"
)

func TestSummaryForAwaitingApproval_Bash(t *testing.T) {
	got := Summarize(Input{
		EffectiveState: "awaiting_approval",
		Payload:        `{"tool_name":"Bash","tool_input":{"command":"pnpm prisma migrate dev"}}`,
	})
	want := "Bash: pnpm prisma migrate dev"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestSummaryForAwaitingApproval_Write(t *testing.T) {
	got := Summarize(Input{
		EffectiveState: "awaiting_approval",
		Payload:        `{"tool_name":"Write","tool_input":{"file_path":"/repo/src/hls.go"}}`,
	})
	want := "Write: hls.go"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestSummaryForIdleDone_TruncatesAtSummaryWidth(t *testing.T) {
	long := strings.Repeat("assistant message that runs on and on ", 10)
	got := Summarize(Input{
		EffectiveState: "idle_done",
		Payload:        `{"last_assistant_message":"` + long + `"}`,
	})
	if w := runewidth.StringWidth(got); w > summaryWidth {
		t.Errorf("summary is %d columns wide, want at most %d: %q", w, summaryWidth, got)
	}
	// The point of raising the cap was that the column now has the rest of the
	// row: a summary still cut at the old 35 would not be using it.
	if w := runewidth.StringWidth(got); w < summaryWidth-2 {
		t.Errorf("summary is only %d columns wide, want it to fill %d", w, summaryWidth)
	}
}

func TestSummaryForIdleDone_FlattensNewlines(t *testing.T) {
	got := Summarize(Input{
		EffectiveState: "idle_done",
		Payload:        `{"last_assistant_message":"line1\nline2"}`,
	})
	for _, r := range got {
		if r == '\n' {
			t.Errorf("summary contains newline: %q", got)
		}
	}
}

// The picker's rows are tab-delimited and carry the session id, pane, cwd and
// transcript path hidden behind the summary, so a tab reaching the column
// shifts all four: the pick then attaches to another session, or opens a
// window in another worktree's directory. A Bash command is the live path --
// `awk -F'<tab>'` is ordinary in this repo -- and it reaches the summary
// verbatim, which is why this asserts on a real awk invocation rather than on
// a bare tab.
func TestSummaryStripsTabs(t *testing.T) {
	cases := []struct {
		name string
		in   Input
	}{{
		name: "bash command with a literal tab",
		in: Input{
			EffectiveState: "awaiting_approval",
			Payload:        `{"tool_name":"Bash","tool_input":{"command":"awk -F'\t' '{print $2}' rows.tsv"}}`,
		},
	}, {
		name: "assistant message with a literal tab",
		in: Input{
			EffectiveState: "idle_done",
			Payload:        `{"last_assistant_message":"col1\tcol2"}`,
		},
	}}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := Summarize(c.in)
			if strings.ContainsAny(got, "\t\n\r") {
				t.Errorf("summary carries a row separator: %q", got)
			}
		})
	}
}

func TestSummaryForWorking(t *testing.T) {
	got := Summarize(Input{EffectiveState: "working"})
	if got != "working" {
		t.Errorf("got %q, want working", got)
	}
}

func TestSummaryForStale(t *testing.T) {
	got := Summarize(Input{EffectiveState: "stale", RawState: "idle_done"})
	if got != "stale (was idle_done)" {
		t.Errorf("got %q, want %q", got, "stale (was idle_done)")
	}
}

// A resumable row's own state is 'ended' and its payload holds only the end
// reason, so the prior state is the only thing that distinguishes one of these
// rows from another.
func TestSummaryForResumable(t *testing.T) {
	got := Summarize(Input{EffectiveState: "resumable", RawState: "ended", PriorState: "working"})
	if got != "resumable (was working)" {
		t.Errorf("got %q, want %q", got, "resumable (was working)")
	}
}

func TestSummaryForResumable_NoPriorState(t *testing.T) {
	got := Summarize(Input{EffectiveState: "resumable", RawState: "ended"})
	if got != "resumable" {
		t.Errorf("got %q, want %q", got, "resumable")
	}
}

func TestTruncateWidth_JapanesePreservesWidth(t *testing.T) {
	got := TruncateWidth("あいうえおかきくけこ", 6)
	if got != "あいう" {
		t.Errorf("got %q, want %q", got, "あいう")
	}
}

func TestExtractHost_StripsUserinfo(t *testing.T) {
	got := Summarize(Input{
		EffectiveState: "awaiting_approval",
		Payload:        `{"tool_name":"WebFetch","tool_input":{"url":"https://user:pass@example.com:8080/path?q=1"}}`,
	})
	want := "WebFetch: example.com"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestSummarizeApproval_FallbackOnEmptyPayload(t *testing.T) {
	got := Summarize(Input{EffectiveState: "awaiting_approval", Payload: ""})
	if got != "awaiting approval" {
		t.Errorf("got %q, want %q", got, "awaiting approval")
	}
}

func TestSummarizeDone_FallbackOnEmptyPayload(t *testing.T) {
	got := Summarize(Input{EffectiveState: "idle_done", Payload: ""})
	if got != "done" {
		t.Errorf("got %q, want %q", got, "done")
	}
}
