// Package label derives a human-readable name for the tmux window a Claude
// Code session runs in, from the session's own transcript.
//
// The transcript is the only source that knows what a session is about. The
// live agent roster (`claude agents --json`) does not: for interactive
// sessions it names an agent after its cwd basename plus two hex digits, which
// carries no more information than the session id already does, and reading it
// costs half a second of subprocess -- far too much for a hook that fires on
// every prompt and every stop.
package label

import (
	"bufio"
	"encoding/json"
	"io"
	"os"
	"strings"
	"unicode"

	"github.com/mattn/go-runewidth"
)

// maxLabelWidth caps the title part of a window name in terminal columns
// (a double-width rune counts 2, which is why this is width and not runes --
// most titles here are Japanese). The 8-char session id and its separator are
// added on top, so a full name stays around 25 columns: long enough to read,
// short enough that a handful of them still fit one tmux status line.
const maxLabelWidth = 16

// tailScanBytes is how much of the end of a transcript is read before falling
// back to a full scan. The ai-title line is rewritten on nearly every turn
// (observed up to 106 times in one session), so the last one is almost always
// within the final few KiB; transcripts themselves reach megabytes, which is
// what makes reading all of it on every hook event the wrong default.
const tailScanBytes = 256 << 10

// maxLineBytes drops transcript lines longer than this instead of buffering
// them. A single tool_result line runs to megabytes, and neither line kind
// read here -- an ai-title record or a user prompt -- is ever near this big.
const maxLineBytes = 1 << 20

// readBufBytes is the reader window eachLine assembles lines in. It only
// bounds how many ReadSlice calls a long line costs, not what can be read.
const readBufBytes = 64 << 10

// Resolve returns the tmux window name for the session whose transcript is at
// transcriptPath, or "" when the transcript offers nothing to name it with.
//
// "" is deliberately not a name of its own: what a caller should fall back to
// depends on the caller (the picker still knows whether it is attaching or
// resuming, a hook has no name to install at all), so the choice is left there.
//
// The session id is kept as a suffix even when a title was found. Two windows
// can legitimately carry the same title -- the same worktree picked twice, a
// resumed conversation next to its original -- and the suffix is what keeps
// tmux's `new-window -S` dedupe keyed on the session rather than on the topic.
func Resolve(transcriptPath, sessionID string) string {
	lbl := Sanitize(rawTitle(transcriptPath))
	if lbl == "" {
		return ""
	}
	if s := shortID(sessionID); s != "" {
		return lbl + "-" + s
	}
	return lbl
}

// DisplayTitle returns the conversation title for the picker's title column,
// trimmed to cols terminal columns, or "" when the transcript offers none.
//
// Deliberately not Resolve: a window name has to survive tmux's -t target
// syntax and its FORMATS expansion, which is why Resolve substitutes "." ":"
// "~" "#" and spends its budget on a 16-column title plus a session id suffix.
// An fzf row is read rather than handed to tmux, so none of that applies, and
// all of it makes the title harder to read -- the suffix in particular repeats
// a column the row already carries hidden.
//
// The one thing it must still strip is the column separators. The picker's
// rows are tab-delimited and carry the session id, pane, cwd and transcript
// path in hidden columns behind the visible ones, so a tab or a newline in a
// title would shift those four and the pick would act on another session.
func DisplayTitle(transcriptPath string, cols int) string {
	return runewidth.Truncate(flatten(rawTitle(transcriptPath)), cols, "")
}

// flatten replaces the characters that would break a tab-delimited row with a
// space, and drops the remaining control characters the way Sanitize does: a
// control character is not a word boundary, so substituting one would invent a
// space that was never in the title.
func flatten(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r == '\t' || r == '\n' || r == '\r':
			b.WriteByte(' ')
		case unicode.IsControl(r):
		default:
			b.WriteRune(r)
		}
	}
	return strings.TrimSpace(b.String())
}

// shortID truncates a session id to the 8 chars every user-facing form of a
// session id uses (it is also the only form `claude attach` takes).
func shortID(sessionID string) string {
	if len(sessionID) > 8 {
		return sessionID[:8]
	}
	return sessionID
}

// Sanitize turns raw title text into something tmux can carry as a window
// name, and a human can read at a glance.
//
// "." and ":" cannot survive: tmux reads them as the window.pane and
// session:window separators in -t targets. "~" cannot survive either, because
// the picker renames a window to "<name>~exited" once its command finishes and
// relies on no live window ever ending in that suffix (see multiplexer's
// windowCommand). "#" cannot survive either: tmux format-expands window names
// passed to `rename-window` and `new-window -n` (confirmed against tmux 3.6b),
// so "#S"/"#T"/"#D"/"#W" substitute the session/pane/window, and an
// unterminated "#{" swallows the rest of the name -- silently producing a
// window that no longer matches what Resolve computed. Whitespace becomes "-"
// so the name stays one shell word. Everything else -- Japanese in
// particular, which most titles here are -- is kept as is.
func Sanitize(s string) string {
	// One line only: a title is a phrase, but a user prompt (the fallback
	// source) is often a whole paragraph.
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		s = s[:i]
	}
	var b strings.Builder
	for _, r := range s {
		switch {
		case r == '.' || r == ':' || r == '~' || r == '#' || unicode.IsSpace(r):
			b.WriteByte('-')
		case unicode.IsControl(r):
			// Dropped rather than substituted: a control character is not a
			// word boundary, so turning it into "-" would invent one.
		default:
			b.WriteRune(r)
		}
	}
	// Truncate after collapsing, so the width budget is spent on characters
	// rather than on runs of separators; trim again afterwards because the cut
	// can land right after a "-".
	return trimDashes(runewidth.Truncate(collapseDashes(b.String()), maxLabelWidth, ""))
}

// collapseDashes folds runs of "-" into one and drops the leading and trailing
// ones. Beyond looks: a leading "-" would make the name an option as far as
// tmux's argument parser is concerned, and a trailing one would show up as a
// dangling separator before the session id suffix.
func collapseDashes(s string) string {
	var b strings.Builder
	prevDash := false
	for _, r := range s {
		if r == '-' {
			prevDash = true
			continue
		}
		if prevDash && b.Len() > 0 {
			b.WriteByte('-')
		}
		prevDash = false
		b.WriteRune(r)
	}
	return b.String()
}

func trimDashes(s string) string {
	return strings.Trim(s, "-")
}

// rawTitle reads transcriptPath and returns the best label text in it, or ""
// when it has none (which includes every failure to read it: a hook must never
// be the reason a session misbehaves, so an unreadable transcript degrades to
// "no name" rather than to an error).
func rawTitle(path string) string {
	if path == "" {
		return ""
	}
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()

	fi, err := f.Stat()
	if err != nil {
		return ""
	}
	if fi.Size() > tailScanBytes {
		// The tail alone answers nearly every call. Its first line is almost
		// certainly cut in half, which needs no handling: half a line is not
		// valid JSON, so it is skipped like any other unparseable line.
		if title, _ := scan(io.NewSectionReader(f, fi.Size()-tailScanBytes, tailScanBytes)); title != "" {
			return title
		}
		// A session that has not been titled yet (or was titled only very
		// early, before a long run of tool output) still deserves a name, so
		// pay for the full read rather than give up.
		if _, err := f.Seek(0, io.SeekStart); err != nil {
			return ""
		}
	}
	title, prompt := scan(f)
	if title != "" {
		return title
	}
	return prompt
}

// scan reads jsonl records and returns the last ai-title and the first user
// prompt it saw.
//
// Last ai-title, not first: Claude Code re-titles a session when the topic
// moves on (4 of 39 sampled sessions did), and following the current topic is
// the point of naming the window at all. The cost is that a re-title makes the
// picker's `new-window -S` miss the window it opened under the old name and
// add a second one -- rare enough to accept, and self-correcting once the
// stale window's command exits.
func scan(r io.Reader) (title, prompt string) {
	eachLine(r, func(line []byte) bool {
		var rec record
		if err := json.Unmarshal(line, &rec); err != nil {
			return true
		}
		switch rec.Type {
		case "ai-title":
			if rec.AITitle != "" {
				title = rec.AITitle
			}
		case "user":
			if prompt == "" {
				prompt = userPrompt(rec)
			}
		}
		return true
	})
	return title, prompt
}

// record is the union of the two transcript line shapes this package reads.
// Every other field of a transcript line is ignored, so one decode per line
// covers both without a second pass.
type record struct {
	Type    string `json:"type"`
	AITitle string `json:"aiTitle"`
	Message struct {
		// Raw because "user" covers two different things: a typed prompt has
		// a string content, while a tool_result carries an array. Decoding
		// into a string is itself the test that tells them apart.
		Content json.RawMessage `json:"content"`
	} `json:"message"`
}

// userPrompt returns the prompt text of a user record, or "" when the record
// is not a prompt a human typed.
//
// Lines opening with "<" are dropped: Claude Code wraps injected context in
// pseudo-tags (<local-command-caveat>, <command-name>, <system-reminder>),
// which are user records by type but say nothing about the conversation.
func userPrompt(rec record) string {
	var content string
	if err := json.Unmarshal(rec.Message.Content, &content); err != nil {
		return "" // an array: tool_result, not a typed prompt
	}
	content = strings.TrimSpace(content)
	if strings.HasPrefix(content, "<") {
		return ""
	}
	return content
}

// eachLine feeds r's newline-separated lines to fn, stopping early when fn
// returns false.
//
// bufio.Scanner is not used because it fails the entire scan on the first line
// over its buffer, and a transcript reliably contains such lines. Here an
// oversized line is dropped and the scan continues -- the ai-title line that
// matters is very likely to come after it.
func eachLine(r io.Reader, fn func([]byte) bool) {
	br := bufio.NewReaderSize(r, readBufBytes)
	var acc []byte
	dropped := false
	for {
		chunk, err := br.ReadSlice('\n')
		if err == bufio.ErrBufferFull {
			if dropped || len(acc)+len(chunk) > maxLineBytes {
				acc, dropped = nil, true
				continue
			}
			acc = append(acc, chunk...)
			continue
		}
		line := chunk
		if dropped {
			line = nil
		} else if len(acc) > 0 {
			line = append(acc, chunk...)
		}
		acc, dropped = nil, false
		if len(line) > 0 && !fn(line) {
			return
		}
		if err != nil {
			return // io.EOF, or a read error we have nothing better to do about
		}
	}
}
