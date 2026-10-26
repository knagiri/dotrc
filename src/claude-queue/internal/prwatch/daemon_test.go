package prwatch

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// A fake /proc and config dir: daemon.lock names pid 4242 started at 2005199.
func daemonFixture(t *testing.T, lock, stat string) (cfg, proc string) {
	t.Helper()
	cfg, proc = t.TempDir(), t.TempDir()
	if lock != "" {
		if err := os.WriteFile(filepath.Join(cfg, "daemon.lock"), []byte(lock), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if stat != "" {
		if err := os.MkdirAll(filepath.Join(proc, "4242"), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(proc, "4242", "stat"), []byte(stat), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return cfg, proc
}

// stat is a /proc/<pid>/stat line whose command name holds spaces and a ')',
// with start time (field 22) set to start.
func stat(start string) string {
	return "4242 (claude ) daemon) S 1 4242 4242 0 -1 4194560 1 0 0 0 1 1 0 0 20 0 11 0 " + start + " 1 1 18446744073709551615\n"
}

const lock = `{"pid": 4242, "procStart": "2005199", "version": "2.1.310"}`

func TestDaemonRunning(t *testing.T) {
	for _, tc := range []struct {
		name, lock, stat string
		want             bool
	}{
		{"live", lock, stat("2005199"), true},
		{"no lock", "", stat("2005199"), false},
		{"pid gone", lock, "", false},
		{"pid reused by another process", lock, stat("9999999"), false},
	} {
		cfg, proc := daemonFixture(t, tc.lock, tc.stat)
		got, err := daemonRunning(cfg, proc)
		if err != nil || got != tc.want {
			t.Errorf("%s: daemonRunning = %v, %v; want %v", tc.name, got, err, tc.want)
		}
	}
	cfg, proc := daemonFixture(t, "{", "")
	if _, err := daemonRunning(cfg, proc); err == nil {
		t.Error("a corrupt lock was read as an answer")
	}
}

// The real check against this process: it is not a daemon, so a lock naming
// it with a wrong start time reads as none, and one with its own start time as
// running.
func TestDaemonRunning_RealProc(t *testing.T) {
	data, err := os.ReadFile("/proc/self/stat")
	if err != nil {
		t.Skip("no /proc")
	}
	start, ok := startTime(string(data))
	if !ok {
		t.Fatalf("cannot parse /proc/self/stat: %q", data)
	}
	cfg := t.TempDir()
	pid := os.Getpid()
	write := func(ps string) {
		if err := os.WriteFile(filepath.Join(cfg, "daemon.lock"), []byte(`{"pid": `+strconv.Itoa(pid)+`, "procStart": "`+ps+`"}`), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write(start)
	if got, err := DaemonRunning(cfg); err != nil || !got {
		t.Errorf("own start time: %v, %v", got, err)
	}
	write(start + "0")
	if got, err := DaemonRunning(cfg); err != nil || got {
		t.Errorf("wrong start time: %v, %v", got, err)
	}
}
