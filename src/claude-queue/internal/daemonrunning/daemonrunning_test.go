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
		check  func(string) (bool, error)
		want   int
		stderr string
	}{
		{"running", nil, func(string) (bool, error) { return true, nil }, 0, ""},
		{"not running", nil, func(string) (bool, error) { return false, nil }, 1, ""},
		{"cannot tell", nil, func(string) (bool, error) { return false, errors.New("boom") }, 2, "boom"},
		{"bad flag", []string{"--nope"}, func(string) (bool, error) { return true, nil }, 2, "nope"},
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

func TestRun_ConfigDir(t *testing.T) {
	var seen string
	check := func(d string) (bool, error) { seen = d; return false, nil }

	run([]string{"--config-dir", "/explicit"}, check, &bytes.Buffer{})
	if seen != "/explicit" {
		t.Errorf("flag: got %q", seen)
	}
	t.Setenv("CLAUDE_CONFIG_DIR", "/from-env")
	run(nil, check, &bytes.Buffer{})
	if seen != "/from-env" {
		t.Errorf("env: got %q", seen)
	}
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	run(nil, check, &bytes.Buffer{})
	if !strings.HasSuffix(seen, ".claude") {
		t.Errorf("default: got %q", seen)
	}
}

// End to end against the real check: an empty config dir has no daemon, and a
// corrupt lock is an undecidable answer rather than "not running".
func TestRun_RealCheck(t *testing.T) {
	cfg := t.TempDir()
	if got := Run([]string{"--config-dir", cfg}); got != 1 {
		t.Errorf("empty dir: exit = %d, want 1", got)
	}
	if err := os.WriteFile(filepath.Join(cfg, "daemon.lock"), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := Run([]string{"--config-dir", cfg}); got != 2 {
		t.Errorf("corrupt lock: exit = %d, want 2", got)
	}
}
