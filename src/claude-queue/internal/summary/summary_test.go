package summary

import "testing"

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

func TestSummaryForIdleDone_TruncatesAt35(t *testing.T) {
	long := "this is a very long assistant message that exceeds the limit by quite a bit really"
	got := Summarize(Input{
		EffectiveState: "idle_done",
		Payload:        `{"last_assistant_message":"` + long + `"}`,
	})
	if len(got) > 35 {
		t.Errorf("summary longer than 35: %q (len=%d)", got, len(got))
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
