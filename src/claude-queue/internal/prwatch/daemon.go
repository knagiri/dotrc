package prwatch

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// DaemonRunning reports whether the claude daemon of configDir is running,
// without starting one.
//
// The daemon writes <configDir>/daemon.lock with its pid and procStart, the
// start time /proc/<pid>/stat gives in field 22 (measured against Claude Code
// 2.1.310: the two agree for a live supervisor). Neither the file nor the pid
// is trusted on its own: a lock a daemon left behind could name a pid since
// reused by another process, and the start time tells the two apart. No lock,
// or a lock naming a process that is not that one, is no daemon.
//
// Asking claude instead does not answer the question: `claude agents --json`
// starts no daemon, but with none running it prints [] and exits 0 (measured
// for hibernation), so an empty answer does not say whether one is running.
func DaemonRunning(configDir string) (bool, error) {
	return daemonRunning(configDir, "/proc")
}

func daemonRunning(configDir, proc string) (bool, error) {
	data, err := os.ReadFile(filepath.Join(configDir, "daemon.lock"))
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	var lock struct {
		PID       int    `json:"pid"`
		ProcStart string `json:"procStart"`
	}
	if err := json.Unmarshal(data, &lock); err != nil {
		return false, fmt.Errorf("parse daemon.lock: %w", err)
	}
	if lock.PID <= 0 || lock.ProcStart == "" {
		return false, fmt.Errorf("daemon.lock names no pid and start time")
	}
	stat, err := os.ReadFile(filepath.Join(proc, strconv.Itoa(lock.PID), "stat"))
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	start, ok := startTime(string(stat))
	if !ok {
		return false, fmt.Errorf("cannot read the start time of pid %d", lock.PID)
	}
	return start == lock.ProcStart, nil
}

// startTime is field 22 of a /proc/<pid>/stat line. The fields are counted
// from after the last ')', because field 2 is the command name in parentheses
// and may itself hold spaces and parentheses.
func startTime(stat string) (string, bool) {
	i := strings.LastIndexByte(stat, ')')
	if i < 0 {
		return "", false
	}
	fields := strings.Fields(stat[i+1:])
	// fields[0] is field 3 (state), so field 22 is fields[19].
	if len(fields) < 20 {
		return "", false
	}
	return fields[19], true
}
