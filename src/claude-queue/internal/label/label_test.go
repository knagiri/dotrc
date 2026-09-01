package label

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSanitize(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{
			// Most titles this reads are Japanese, so multi-byte text has to
			// survive intact rather than be transliterated or dropped.
			name: "japanese is kept",
			in:   "ロググループ管理",
			want: "ロググループ管理",
		},
		{
			name: "spaces become hyphens",
			in:   "Vercel log drain",
			want: "Vercel-log-drain",
		},
		{
			// "." and ":" are tmux's window.pane and session:window
			// separators; "~" is reserved for the picker's "~exited" suffix.
			name: "tmux separators are replaced",
			in:   "a.b:c~d",
			want: "a-b-c-d",
		},
		{
			// "#" triggers tmux's format expansion in a window name (e.g.
			// "#S" substitutes the session name), which would make the name
			// tmux actually stores diverge from what Resolve computed.
			name: "hash is replaced",
			in:   "fix-#67",
			want: "fix-67",
		},
		{
			name: "runs of separators collapse and edges are trimmed",
			in:   "  a   ..b  ",
			want: "a-b",
		},
		{
			// A control character is not a word boundary, so it leaves no
			// hyphen behind.
			name: "control characters are dropped, not substituted",
			in:   "a\x00\x07b",
			want: "ab",
		},
		{
			// A user prompt (the fallback source) is often a paragraph; only
			// its opening line can be a window name.
			name: "only the first line is used",
			in:   "first line\nsecond line",
			want: "first-line",
		},
		{
			// 20 columns of half-width text cut to the 16 the budget allows.
			name: "half-width text is cut at 16 columns",
			in:   "abcdefghijklmnopqrst",
			want: "abcdefghijklmnop",
		},
		{
			// 9 double-width runes are 18 columns, so 8 of them fit.
			name: "double-width runes count two columns each",
			in:   "ロググループの管理",
			want: "ロググループの管",
		},
		{
			// The cut can land right after a separator, which would leave the
			// name ending in a dangling hyphen before the id suffix.
			name: "a trailing hyphen left by the cut is trimmed",
			in:   "abcdefghijklmno pqr",
			want: "abcdefghijklmno",
		},
		{
			name: "empty stays empty",
			in:   "",
			want: "",
		},
		{
			// Nothing but separators is no name at all, and must not become a
			// window called "-".
			name: "separators only yield nothing",
			in:   " .:~ ",
			want: "",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := Sanitize(tt.in); got != tt.want {
				t.Errorf("Sanitize(%q) = %q, want %q", tt.in, got, tt.want)
			}
		})
	}
}

// writeTranscript lays out a jsonl file for one test and returns its path.
// Fixtures are generated rather than committed: the big one below is a third of
// a megabyte, and none of this is data worth carrying in the repository.
func writeTranscript(t *testing.T, lines ...string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "transcript.jsonl")
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0600); err != nil {
		t.Fatalf("write transcript: %v", err)
	}
	return path
}

func aiTitleLine(title string) string {
	return fmt.Sprintf(`{"type":"ai-title","aiTitle":%q,"sessionId":"6773febd-ce31-4e22-8354-5bc0d72c18a1"}`, title)
}

func userLine(content string) string {
	return fmt.Sprintf(`{"type":"user","message":{"role":"user","content":%q},"uuid":"x"}`, content)
}

const sessionID = "6773febd-ce31-4e22-8354-5bc0d72c18a1"

func TestResolve(t *testing.T) {
	t.Run("the last ai-title wins", func(t *testing.T) {
		// Claude Code re-titles a session when the topic moves on, and the
		// window should follow the conversation rather than its opening.
		path := writeTranscript(t,
			userLine("ci docs-lint の timeout を調べて"),
			aiTitleLine("ci docs-lint timeout"),
			aiTitleLine("Docs Lint 判断"),
		)
		if got, want := Resolve(path, sessionID), "Docs-Lint-判断-6773febd"; got != want {
			t.Errorf("Resolve = %q, want %q", got, want)
		}
	})

	t.Run("falls back to the first user prompt", func(t *testing.T) {
		// A session titled only after its first answer still has to be
		// nameable from the moment the user hits enter.
		path := writeTranscript(t,
			userLine("GitHub App の PR 作成"),
			userLine("次の質問"),
		)
		if got, want := Resolve(path, sessionID), "GitHub-App-の-PR-6773febd"; got != want {
			t.Errorf("Resolve = %q, want %q", got, want)
		}
	})

	t.Run("tool results and injected context are not prompts", func(t *testing.T) {
		// A tool_result is a "user" record with an array content, and Claude
		// Code injects its own context as pseudo-tagged user text; neither
		// says anything about what the session is about.
		path := writeTranscript(t,
			`{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"iac/cdk.json"}]}}`,
			userLine("<local-command-caveat>Caveat: ...</local-command-caveat>"),
			userLine("本当の質問"),
		)
		if got, want := Resolve(path, sessionID), "本当の質問-6773febd"; got != want {
			t.Errorf("Resolve = %q, want %q", got, want)
		}
	})

	t.Run("nothing to name it with", func(t *testing.T) {
		// "" is the contract that hands the choice back to the caller: the
		// picker still knows it is attaching, a hook has nothing to install.
		path := writeTranscript(t, `{"type":"assistant","message":{"role":"assistant"}}`)
		if got := Resolve(path, sessionID); got != "" {
			t.Errorf("Resolve = %q, want empty", got)
		}
	})

	t.Run("an unreadable transcript is not an error", func(t *testing.T) {
		if got := Resolve(filepath.Join(t.TempDir(), "absent.jsonl"), sessionID); got != "" {
			t.Errorf("Resolve = %q, want empty", got)
		}
		if got := Resolve("", sessionID); got != "" {
			t.Errorf(`Resolve("") = %q, want empty`, got)
		}
	})

	t.Run("a session id shorter than 8 chars is used as is", func(t *testing.T) {
		path := writeTranscript(t, aiTitleLine("topic"))
		if got, want := Resolve(path, "abc"), "topic-abc"; got != want {
			t.Errorf("Resolve = %q, want %q", got, want)
		}
	})
}

// TestResolveFallsBackToAFullScan covers the case the tail read exists to
// avoid paying for, and must not silently lose: a session titled early and then
// buried under more than tailScanBytes of tool output. The tail alone sees no
// ai-title there, so the read has to start over from the beginning.
func TestResolveFallsBackToAFullScan(t *testing.T) {
	lines := []string{aiTitleLine("early topic")}
	// Padding that parses cleanly but names nothing, so a wrong answer here
	// can only come from the scan, never from the filler.
	filler := `{"type":"assistant","message":{"role":"assistant","content":"` + strings.Repeat("x", 900) + `"}}`
	for total := 0; total < 2*tailScanBytes; total += len(filler) + 1 {
		lines = append(lines, filler)
	}
	path := writeTranscript(t, lines...)

	if fi, err := os.Stat(path); err != nil || fi.Size() <= tailScanBytes {
		t.Fatalf("fixture must exceed the tail window: size err=%v", err)
	}
	if got, want := Resolve(path, sessionID), "early-topic-6773febd"; got != want {
		t.Errorf("Resolve = %q, want %q", got, want)
	}
}

// TestResolveTailAloneAnswers covers the tail read's ordinary job: the sole
// ai-title sits within the last tailScanBytes of the transcript, with nothing
// answering before it. Unlike every other Resolve test above (which puts its
// title within the first tailScanBytes and so never actually exercises the
// tail window), this one only comes out right if the tail window is read from
// somewhere past the head.
func TestResolveTailAloneAnswers(t *testing.T) {
	// Padding that parses cleanly but names nothing, so a wrong answer here
	// can only come from the scan, never from the filler.
	filler := `{"type":"assistant","message":{"role":"assistant","content":"` + strings.Repeat("x", 900) + `"}}`
	var lines []string
	for total := 0; total < 2*tailScanBytes; total += len(filler) + 1 {
		lines = append(lines, filler)
	}
	lines = append(lines, aiTitleLine("tail only"))
	path := writeTranscript(t, lines...)

	if fi, err := os.Stat(path); err != nil || fi.Size() <= tailScanBytes {
		t.Fatalf("fixture must exceed the tail window: size err=%v", err)
	}
	if got, want := Resolve(path, sessionID), "tail-only-6773febd"; got != want {
		t.Errorf("Resolve = %q, want %q", got, want)
	}
}

// TestResolveTailTitleBeatsHeadTitle pins the tail window's offset arithmetic
// (fi.Size()-tailScanBytes in rawTitle), not just that a title is eventually
// found. The head and the tail each carry a different ai-title; a correctly
// placed tail window sees only the tail one and returns it directly. A wrong
// offset (0, say -- reading the head instead of the tail) would see the
// head's title instead, return it immediately as a non-empty match, and never
// reach the fallback full scan that would otherwise have caught the mistake.
// TestResolveFallsBackToAFullScan cannot tell these two code paths apart
// because it only ever has one title in the whole transcript.
func TestResolveTailTitleBeatsHeadTitle(t *testing.T) {
	lines := []string{aiTitleLine("head topic")}
	filler := `{"type":"assistant","message":{"role":"assistant","content":"` + strings.Repeat("x", 900) + `"}}`
	for total := 0; total < 2*tailScanBytes; total += len(filler) + 1 {
		lines = append(lines, filler)
	}
	lines = append(lines, aiTitleLine("tail topic"))
	path := writeTranscript(t, lines...)

	if fi, err := os.Stat(path); err != nil || fi.Size() <= tailScanBytes {
		t.Fatalf("fixture must exceed the tail window: size err=%v", err)
	}
	if got, want := Resolve(path, sessionID), "tail-topic-6773febd"; got != want {
		t.Errorf("Resolve = %q, want %q", got, want)
	}
}

// TestScanReassemblesAMultiChunkLine covers eachLine's acc reassembly path: a
// line longer than readBufBytes (64 KiB) but well under maxLineBytes (1 MiB),
// which forces multiple ReadSlice passes to be stitched back into one line
// before it can be unmarshalled. None of the other fixtures in this file
// exercise it -- they are all short, or (TestScanSkipsOversizedLines) long
// enough to take the drop path instead. A pasted user prompt or a long
// ai-title both land in exactly this band, so the path is real, not
// hypothetical.
func TestScanReassemblesAMultiChunkLine(t *testing.T) {
	const size = 200 << 10 // between readBufBytes and maxLineBytes
	long := strings.Repeat("z", size)
	title, _ := scan(strings.NewReader(aiTitleLine(long) + "\n"))
	if len(title) != size || title != long {
		t.Errorf("scan lost or corrupted a %d-byte line spanning multiple read buffers (got len=%d)", size, len(title))
	}
}

// TestScanSkipsOversizedLines pins why bufio.Scanner is not used here: a
// transcript reliably contains tool_result lines of several megabytes, and a
// reader that gives up on the first one would never reach the title that
// follows it.
func TestScanSkipsOversizedLines(t *testing.T) {
	huge := `{"type":"assistant","message":{"role":"assistant","content":"` + strings.Repeat("x", 2*maxLineBytes) + `"}}`
	title, _ := scan(strings.NewReader(huge + "\n" + aiTitleLine("after the giant") + "\n"))
	if want := "after the giant"; title != want {
		t.Errorf("scan title = %q, want %q", title, want)
	}
}

// TestScanIgnoresAPartialFirstLine is the tail read's one structural hazard:
// the window starts mid-line. Half a JSON object is simply unparseable, which
// is the same path every other malformed line takes.
func TestScanIgnoresAPartialFirstLine(t *testing.T) {
	title, prompt := scan(strings.NewReader(`ssage":{"role":"user","content":"cut in half"}}` + "\n" + aiTitleLine("whole") + "\n"))
	if title != "whole" {
		t.Errorf("scan title = %q, want %q", title, "whole")
	}
	if prompt != "" {
		t.Errorf("scan prompt = %q, want empty: a half line is not a prompt", prompt)
	}
}
