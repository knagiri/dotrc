package hook

import (
	"testing"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

// The env each kind of session was measured to hand its SessionStart hook.
func TestKindFromEnv(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
		want string
	}{
		{"interactive", map[string]string{
			"CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_CODE_SESSION_ATTENDED": "1",
		}, db.KindInteractive},
		{"background", map[string]string{
			"CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_JOB_DIR": "/home/u/.claude/jobs/abcd1234",
			"CLAUDE_CODE_SESSION_ATTENDED": "0",
		}, db.KindBackground},
		{"print", map[string]string{
			"CLAUDE_CODE_ENTRYPOINT": "sdk-cli", "CLAUDE_CODE_SESSION_ATTENDED": "0",
		}, db.KindPrint},
		{"print inheriting a background job's dir", map[string]string{
			"CLAUDE_CODE_ENTRYPOINT": "sdk-cli", "CLAUDE_JOB_DIR": "/home/u/.claude/jobs/abcd1234",
		}, db.KindPrint},
		{"nothing set", map[string]string{}, db.KindInteractive},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := KindFromEnv(func(k string) string { return tc.env[k] }); got != tc.want {
				t.Errorf("KindFromEnv = %q, want %q", got, tc.want)
			}
		})
	}
}
