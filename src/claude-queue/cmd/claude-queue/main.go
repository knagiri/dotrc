package main

import (
	"fmt"
	"os"

	"github.com/knagiri/dotrc/src/claude-queue/internal/annotate"
	"github.com/knagiri/dotrc/src/claude-queue/internal/done"
	"github.com/knagiri/dotrc/src/claude-queue/internal/hook"
	"github.com/knagiri/dotrc/src/claude-queue/internal/link"
	"github.com/knagiri/dotrc/src/claude-queue/internal/mark"
	"github.com/knagiri/dotrc/src/claude-queue/internal/picker"
	"github.com/knagiri/dotrc/src/claude-queue/internal/reconcile"
	"github.com/knagiri/dotrc/src/claude-queue/internal/reopen"
	"github.com/knagiri/dotrc/src/claude-queue/internal/reset"
	"github.com/knagiri/dotrc/src/claude-queue/internal/status"
	"github.com/knagiri/dotrc/src/claude-queue/internal/watch"
)

// version is set via -ldflags "-X main.version=..." at build time.
var version = "dev"

func usage() {
	fmt.Fprintln(os.Stderr, "usage: claude-queue {hook <event>|status|picker|reconcile|watch|reset} [flags]")
	fmt.Fprintln(os.Stderr, "       claude-queue link --parent <session-id> --child <short-id>")
	fmt.Fprintln(os.Stderr, "       claude-queue mark <session-id>")
	fmt.Fprintln(os.Stderr, "       claude-queue done <session-id-or-prefix>")
	fmt.Fprintln(os.Stderr, "       claude-queue reopen <session-id-or-prefix>")
	fmt.Fprintln(os.Stderr, "       claude-queue memo [--session <id>] [--] [<text>]")
	fmt.Fprintln(os.Stderr, "       claude-queue pin [--session <id>] [--note <text>] [--pr <owner/repo#N | PR URL>]")
	fmt.Fprintln(os.Stderr, "       claude-queue unpin [--session <id>]")
	fmt.Fprintln(os.Stderr, "       claude-queue --version")
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	switch os.Args[1] {
	case "--version", "-v":
		fmt.Println(version)
	case "hook":
		// Hooks must NEVER block claude: always exit 0.
		if len(os.Args) < 3 {
			os.Exit(0)
		}
		hook.Run(os.Args[2])
		os.Exit(0)
	case "status":
		status.Run()
	case "picker":
		picker.Run(os.Args[2:])
	case "reconcile":
		reconcile.Run(os.Args[2:])
	case "watch":
		watch.Run(os.Args[2:])
	case "reset":
		reset.Run(os.Args[2:])
	case "link":
		link.Run(os.Args[2:])
	case "mark":
		mark.Run(os.Args[2:])
	case "done":
		done.Run(os.Args[2:])
	case "reopen":
		reopen.Run(os.Args[2:])
	case "memo", "pin", "unpin":
		annotate.Run(os.Args[1], os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand: %s\n", os.Args[1])
		usage()
		os.Exit(2)
	}
}
