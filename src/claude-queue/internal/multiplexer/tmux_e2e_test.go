package multiplexer

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"
)

// e2eServer is a private tmux server (its own socket) with real attached
// clients, so returnClause runs against tmux's actual client selection rather
// than a reading of the man page. Clients need a terminal, which script(1)
// provides.
type e2eServer struct {
	t    *testing.T
	sock string
}

func newE2EServer(t *testing.T) *e2eServer {
	t.Helper()
	if runtime.GOOS != "linux" {
		t.Skip("script(1) -c syntax is the util-linux one")
	}
	for _, bin := range []string{"tmux", "script"} {
		if _, err := exec.LookPath(bin); err != nil {
			t.Skipf("%s not available", bin)
		}
	}
	// Not t.TempDir(): a unix socket path is capped near 108 bytes, and test
	// names make that directory long.
	dir, err := os.MkdirTemp("", "cq-tmux")
	if err != nil {
		t.Fatal(err)
	}
	s := &e2eServer{t: t, sock: filepath.Join(dir, "s")}
	t.Cleanup(func() {
		_ = exec.Command("tmux", "-S", s.sock, "kill-server").Run()
		_ = os.RemoveAll(dir)
	})
	return s
}

func (s *e2eServer) tmux(args ...string) string {
	s.t.Helper()
	cmd := exec.Command("tmux", append([]string{"-S", s.sock, "-f", "/dev/null"}, args...)...)
	cmd.Env = e2eEnv()
	out, err := cmd.CombinedOutput()
	if err != nil {
		s.t.Fatalf("tmux %v: %v: %s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

// attach starts a client on session and kills it at cleanup.
func (s *e2eServer) attach(session string) {
	s.t.Helper()
	cmd := exec.Command("script", "-qfc", "tmux -S "+s.sock+" attach -t "+session, "/dev/null")
	cmd.Env = e2eEnv()
	if err := cmd.Start(); err != nil {
		s.t.Fatal(err)
	}
	s.t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait() })
}

// clientSessions lists the session each attached client is on, sorted.
func (s *e2eServer) clientSessions() []string {
	out := s.tmux("list-clients", "-F", "#{client_session}")
	if out == "" {
		return nil
	}
	got := strings.Split(out, "\n")
	slices.Sort(got)
	return got
}

func (s *e2eServer) waitFor(what string, cond func() bool) {
	s.t.Helper()
	for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
		if cond() {
			return
		}
	}
	s.t.Fatalf("timed out waiting for %s", what)
}

// e2eEnv drops any TMUX inherited from a test run inside tmux, so nothing can
// reach the caller's server, and gives the clients a terminal type.
func e2eEnv() []string {
	env := slices.DeleteFunc(os.Environ(), func(kv string) bool {
		return strings.HasPrefix(kv, "TMUX=") || strings.HasPrefix(kv, "TMUX_PANE=") || strings.HasPrefix(kv, "TERM=")
	})
	return append(env, "TERM=xterm")
}

// TestWindowCommandReturnsOnlyViewingClient runs windowCommand's clean path in
// a real tmux with two clients. The window's argv waits on a gate file, so the
// clients are in place before it exits 0.
//
//   - viewed: client A shows the window, B shows another session. Only A goes
//     back to the origin pane.
//   - unviewed: neither client shows the window. Nobody moves. This is the case
//     a bare `switch-client -t` gets wrong -- tmux then picks the most recently
//     active client and pulls it away from whatever it was on.
func TestWindowCommandReturnsOnlyViewingClient(t *testing.T) {
	for _, tt := range []struct {
		name  string
		aOn   string // session client A attaches to
		wantA string // session client A is on afterwards
	}{
		{"viewed", "work", "home"},
		{"unviewed", "side", "side"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			s := newE2EServer(t)
			gate := filepath.Join(filepath.Dir(s.sock), "gate")

			s.tmux("new-session", "-d", "-s", "home", "-x", "80", "-y", "24")
			origin := s.tmux("display-message", "-p", "-t", "home", "#{pane_id}")
			s.tmux("new-session", "-d", "-s", "away")
			s.tmux("new-session", "-d", "-s", "side")
			argv := []string{"sh", "-c", "while [ ! -e " + gate + " ]; do sleep 0.05; done"}
			s.tmux(append([]string{"new-session", "-d", "-s", "work"}, windowCommand("w", origin, argv)...)...)

			s.attach(tt.aOn)
			s.attach("away")
			before := []string{tt.aOn, "away"}
			slices.Sort(before)
			s.waitFor("both clients to attach", func() bool { return slices.Equal(s.clientSessions(), before) })

			if err := os.WriteFile(gate, nil, 0o600); err != nil {
				t.Fatal(err)
			}
			// The window closes only after the return clause has finished, so
			// its absence is the point at which the clients are final.
			s.waitFor("the window to close", func() bool {
				return exec.Command("tmux", "-S", s.sock, "has-session", "-t", "=work").Run() != nil
			})

			want := []string{tt.wantA, "away"}
			slices.Sort(want)
			if got := s.clientSessions(); !slices.Equal(got, want) {
				t.Errorf("clients on %v after the window exited 0, want %v", got, want)
			}
		})
	}
}
