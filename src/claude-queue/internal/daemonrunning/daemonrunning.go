// Package daemonrunning implements `claude-queue daemon-running`: whether the
// claude daemon of a config dir is up, answered without starting one.
//
// Exit codes: 0 running, 1 not running, 2 cannot tell (bad flags, or the
// daemon lock could not be read or parsed). 2 is distinct from 1 so a caller
// that must not start work without a daemon can fail closed on either.
package daemonrunning

import (
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/knagiri/dotrc/src/claude-queue/internal/configdir"
	"github.com/knagiri/dotrc/src/claude-queue/internal/prwatch"
)

// Run is the CLI entrypoint; it returns the process exit code.
func Run(args []string) int {
	return run(args, prwatch.DaemonRunning, os.Stderr)
}

func run(args []string, check func(string) (bool, error), stderr io.Writer) int {
	fs := flag.NewFlagSet("daemon-running", flag.ContinueOnError)
	fs.SetOutput(stderr)
	dir := fs.String("config-dir", "", "claude config dir (default $"+configdir.EnvVar+", else ~/.claude)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *dir == "" {
		*dir = os.Getenv(configdir.EnvVar)
	}
	if *dir == "" {
		*dir = configdir.Default()
	}
	running, err := check(*dir)
	if err != nil {
		fmt.Fprintf(stderr, "daemon-running: %v\n", err)
		return 2
	}
	if running {
		return 0
	}
	return 1
}
