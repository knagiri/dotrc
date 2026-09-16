package configdir

import (
	"path/filepath"
	"reflect"
	"testing"
)

// The path shape is the contract with claude itself, measured against a real
// run: CLAUDE_CONFIG_DIR=<dir> claude -p reported
// transcript_path=<dir>/projects/<cwd slug>/<session uuid>.jsonl in its hook
// payload. Everything below is that shape and the ways it can fail to hold.
func TestFromTranscript(t *testing.T) {
	cases := []struct {
		name  string
		path  string
		want  string
		wantB bool
	}{
		{
			name:  "the shape claude writes",
			path:  "/home/x/.claude-personal/projects/-home-x-repo/1234.jsonl",
			want:  "/home/x/.claude-personal",
			wantB: true,
		},
		{
			name:  "the default dir is nothing special",
			path:  "/home/x/.claude/projects/-home-x-repo/1234.jsonl",
			want:  "/home/x/.claude",
			wantB: true,
		},
		{
			// Without the projects/ check any path would yield a "config dir"
			// two levels up, so a transcript moved elsewhere would be recorded
			// as a dir that has no roster at all.
			name: "a path with no projects/ segment is rejected",
			path: "/home/x/somewhere/else/1234.jsonl",
		},
		{name: "empty", path: ""},
		{name: "too shallow to have a dir above projects/", path: "projects/slug/1234.jsonl"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := FromTranscript(tc.path)
			if ok != tc.wantB || got != tc.want {
				t.Errorf("FromTranscript(%q) = (%q, %v), want (%q, %v)", tc.path, got, ok, tc.want, tc.wantB)
			}
		})
	}
}

// The precedence is the whole point of Resolve: the transcript path is claude's
// own answer, the env is only its caller's.
func TestResolve(t *testing.T) {
	const transcript = "/home/x/.claude-personal/projects/-home-x-repo/1234.jsonl"

	if got := Resolve(transcript, "/home/x/.claude-other"); got != "/home/x/.claude-personal" {
		t.Errorf("transcript should win over env, got %q", got)
	}
	if got := Resolve("", "/home/x/.claude-other/"); got != "/home/x/.claude-other" {
		t.Errorf("env should be used (cleaned) when there is no transcript, got %q", got)
	}
	if got := Resolve("", ""); got != Default() {
		t.Errorf("Resolve with nothing = %q, want the default %q", got, Default())
	}
	// An unusable transcript path must not swallow the env: it is not an answer,
	// it is the absence of one.
	if got := Resolve("/nowhere/1234.jsonl", "/home/x/.claude-other"); got != "/home/x/.claude-other" {
		t.Errorf("an unparseable transcript should fall through to the env, got %q", got)
	}
}

func TestDefaultIsUnderHome(t *testing.T) {
	t.Setenv("HOME", "/home/probe")
	if got := Default(); got != filepath.Join("/home/probe", ".claude") {
		t.Errorf("Default() = %q, want /home/probe/.claude", got)
	}
}

func TestUnion(t *testing.T) {
	t.Setenv("HOME", "/home/probe")
	def := "/home/probe/.claude"

	got := Union([]string{"/home/probe/.claude-personal", "", def, "/home/probe/.claude-personal/"})
	want := []string{def, "/home/probe/.claude-personal"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Union = %v, want %v", got, want)
	}

	// The default is in the list even when the ledger names nothing: a ledger
	// whose rows were all GC'd must not leave the one certain dir unlisted.
	if got := Union(nil); !reflect.DeepEqual(got, []string{def}) {
		t.Errorf("Union(nil) = %v, want [%s]", got, def)
	}
}
