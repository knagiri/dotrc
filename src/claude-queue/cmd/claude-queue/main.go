package main

import (
	"fmt"
	"os"
)

// version is set via -ldflags "-X main.version=..." at build time.
var version = "dev"

func usage() {
	fmt.Fprintln(os.Stderr, "usage: claude-queue {hook <event>|status|picker|reset} [flags]")
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
		// TODO(Task 6): call hook.Run(os.Args[2])
		os.Exit(0)
	case "status":
		// TODO(Task 10): call status.Run()
	case "picker":
		// TODO(Task 12): call picker.Run(os.Args[2:])
	case "reset":
		// TODO(Task 13): call reset.Run(os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand: %s\n", os.Args[1])
		usage()
		os.Exit(2)
	}
}
