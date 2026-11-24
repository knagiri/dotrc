package daemonrunning

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRun_ExitCodes(t *testing.T) {
	for _, tc := range []struct {
		name   string
		args   []string
		check  func() (bool, error)
		want   int
		stderr string
	}{
		{"running", nil, func() (bool, error) { return true, nil }, 0, ""},
		{"not running", nil, func() (bool, error) { return false, nil }, 1, ""},
		{"cannot tell", nil, func() (bool, error) { return false, errors.New("boom") }, 2, "boom"},
		{"bad flag", []string{"--nope"}, func() (bool, error) { return true, nil }, 2, "nope"},
		// The flag is gone: a caller still passing it gets "cannot tell"
		// rather than an answer about some other dir.
		{"removed --config-dir", []string{"--config-dir", "/x"}, func() (bool, error) { return true, nil }, 2, "config-dir"},
	} {
		var errBuf bytes.Buffer
		if got := run(tc.args, tc.check, &errBuf); got != tc.want {
			t.Errorf("%s: exit = %d, want %d", tc.name, got, tc.want)
		}
		if !strings.Contains(errBuf.String(), tc.stderr) {
			t.Errorf("%s: stderr %q lacks %q", tc.name, errBuf.String(), tc.stderr)
		}
	}
}

// End to end against the real check, under the config dir the environment
// names: an empty one has no daemon, and a corrupt lock is an undecidable
// answer rather than "not running".
func TestRun_RealCheck(t *testing.T) {
	cfg := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", cfg)
	if got := Run(nil); got != 1 {
		t.Errorf("empty dir: exit = %d, want 1", got)
	}
	if err := os.WriteFile(filepath.Join(cfg, "daemon.lock"), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := Run(nil); got != 2 {
		t.Errorf("corrupt lock: exit = %d, want 2", got)
	}
}
