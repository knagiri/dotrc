#!/usr/bin/env bash
# Functional tests for claude-spinoff. tmux, claude, mise and claude-queue are
# stubbed on PATH and never forward to the real commands. The tmux stub records
# its argv and then RUNS the pane command it was handed (in the -c dir), which
# reaches only the mise and claude stubs -- so the cases assert what the spun-off
# claude actually got (cwd, argv, env), not just how the tmux line was spelled.
# No test framework; run with bash.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
src="$here/../bin/claude-spinoff"
fail=0

tmp="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$tmp"' EXIT

commit() { git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; }

# "script repo" holds a copy of claude-spinoff (stands in for dotrc, for --global).
scriptrepo="$tmp/scriptrepo"
mkdir -p "$scriptrepo/bin"
cp "$src" "$scriptrepo/bin/claude-spinoff"
chmod +x "$scriptrepo/bin/claude-spinoff"
git -C "$scriptrepo" init -q && commit "$scriptrepo"
so="$scriptrepo/bin/claude-spinoff"

# The repo the caller works in, plus a linked worktree of it.
cwdrepo="$tmp/cwdrepo"
mkdir -p "$cwdrepo"
git -C "$cwdrepo" init -q && commit "$cwdrepo"
git -C "$cwdrepo" worktree add -q -b wt "$cwdrepo/.worktrees/wt" 2>/dev/null

dotrepo="$tmp/my.repo"
mkdir -p "$dotrepo"
git -C "$dotrepo" init -q && commit "$dotrepo"

stubbin="$tmp/stubbin"
mkdir -p "$stubbin"
# tmux: has-session answers from $TMUX_STUB_HAS (1 = session exists);
# new-session/new-window log argv (one element per line) to $TMUX_STUB_LOG, fail
# when $TMUX_STUB_FAIL=1, else run the trailing command in the -c dir.
cat >"$stubbin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  has-session) [ "${TMUX_STUB_HAS:-0}" = 1 ]; exit ;;
  new-session|new-window)
    printf '%s\n' "$@" >"$TMUX_STUB_LOG"
    env >"$TMUX_STUB_ENV"
    [ "${TMUX_STUB_FAIL:-0}" = 1 ] && exit 1
    shift; dir=.
    while [ $# -gt 0 ]; do
      case "$1" in -d) shift ;; -s|-t) shift 2 ;; -c) dir="$2"; shift 2 ;; *) break ;; esac
    done
    cd "$dir" && exec "$@" ;;
  *) exit 0 ;;
esac
EOF
# claude: `agents` lists the test shell as a named session (so a delegator
# lookup, if the script did one, WOULD find a parent); a launch records argv,
# cwd and the env it was given.
cat >"$stubbin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = agents ]; then
  printf '[{"pid":%s,"name":"parent-session","sessionId":"parent-sid-0000","kind":"interactive"}]\n' "$CLAUDE_STUB_PARENT_PID"
  exit 0
fi
{ printf '%s\n' "$@"; } >"$CLAUDE_STUB_ARGV"
pwd -P >"$CLAUDE_STUB_CWD"
env >"$CLAUDE_STUB_ENV"
EOF
cat >"$stubbin/mise" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MISE_STUB_LOG"
[ "${1:-}" = exec ] || exit 0
shift; dir=.
while [ $# -gt 0 ]; do case "$1" in -C) dir="$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac; done
cd "$dir" && exec "$@"
EOF
cat >"$stubbin/claude-queue" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CQ_STUB_LOG"
EOF
chmod +x "$stubbin"/*

export PATH="$stubbin:$PATH"
export TMUX_STUB_LOG="$tmp/tmux.log" TMUX_STUB_ENV="$tmp/tmux.env" CLAUDE_STUB_ARGV="$tmp/claude.argv" \
  CLAUDE_STUB_CWD="$tmp/claude.cwd" CLAUDE_STUB_ENV="$tmp/claude.env" \
  MISE_STUB_LOG="$tmp/mise.log" CQ_STUB_LOG="$tmp/cq.log" CLAUDE_STUB_PARENT_PID=$$
unset TMUX TMUX_PANE

reset_logs() { rm -f "$TMUX_STUB_LOG" "$TMUX_STUB_ENV" "$CLAUDE_STUB_ARGV" "$CLAUDE_STUB_CWD" "$CLAUDE_STUB_ENV" "$MISE_STUB_LOG" "$CQ_STUB_LOG"; }
real() { (cd "$1" && pwd -P); }

prompt='look into "X" -- it'\''s out of scope here'

# --- main tree, no tmux session yet -> new-session in main toplevel ------------
reset_logs
out="$(cd "$cwdrepo" && TMUX_STUB_HAS=0 "$so" -- "$prompt" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sed -n 1p "$TMUX_STUB_LOG")" = new-session ] \
   && grep -qxF -- '-d' "$TMUX_STUB_LOG" \
   && [ "$(grep -A1 -xF -- '-s' "$TMUX_STUB_LOG" | tail -n1)" = cwdrepo ] \
   && [ "$(cat "$CLAUDE_STUB_CWD")" = "$(real "$cwdrepo")" ]; then
  echo "ok: main tree + no session -> new-session -d -s <repo> running in main toplevel"
else echo "FAIL: main tree new-session rc=$rc out=$out"; sed 's/^/  tmux| /' "$TMUX_STUB_LOG" 2>/dev/null; fail=1; fi

# The prompt arrives as ONE argv element, unchanged, with acceptEdits.
if [ "$(tail -n1 "$CLAUDE_STUB_ARGV")" = "$prompt" ] \
   && [ "$(head -n2 "$CLAUDE_STUB_ARGV" | paste -sd' ')" = "--permission-mode acceptEdits" ] \
   && [ "$(wc -l <"$CLAUDE_STUB_ARGV")" -eq 3 ]; then
  echo "ok: prompt is passed verbatim as one argv element, acceptEdits, no --model"
else echo "FAIL: claude argv"; sed 's/^/  argv| /' "$CLAUDE_STUB_ARGV"; fail=1; fi

# --- linked worktree, session exists -> new-window, still main toplevel --------
reset_logs
out="$(cd "$cwdrepo/.worktrees/wt" && TMUX_STUB_HAS=1 "$so" -- "$prompt" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sed -n 1p "$TMUX_STUB_LOG")" = new-window ] \
   && grep -qxF -- '-d' "$TMUX_STUB_LOG" \
   && [ "$(grep -A1 -xF -- '-t' "$TMUX_STUB_LOG" | tail -n1)" = "=cwdrepo:" ] \
   && [ "$(grep -A1 -xF -- '-c' "$TMUX_STUB_LOG" | tail -n1)" = "$cwdrepo" ] \
   && [ "$(cat "$CLAUDE_STUB_CWD")" = "$(real "$cwdrepo")" ] \
   && grep -qF 'new-window' <<<"$out"; then
  echo "ok: linked worktree + existing session -> new-window -d -t =<repo>: in main toplevel"
else echo "FAIL: worktree new-window rc=$rc out=$out"; sed 's/^/  tmux| /' "$TMUX_STUB_LOG" 2>/dev/null; fail=1; fi

# --- session name sanitizing --------------------------------------------------
reset_logs
(cd "$dotrepo" && "$so" -- "$prompt") >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -A1 -xF -- '-s' "$TMUX_STUB_LOG" | tail -n1)" = my_repo ]; then
  echo "ok: '.' in the repo basename becomes '_' in the session name"
else echo "FAIL: sanitize rc=$rc"; sed 's/^/  tmux| /' "$TMUX_STUB_LOG" 2>/dev/null; fail=1; fi

# --- no parent link, no caller markers, account from the main checkout --------
# Called as if from inside a claude session: the roster lists an ancestor, and
# the session markers and a non-default config dir are in the env.
reset_logs
(cd "$cwdrepo" && CLAUDE_CODE_SESSION_ID=parent-sid-0000 CLAUDE_CODE_CHILD_SESSION=1 \
   CLAUDECODE=1 CLAUDE_CONFIG_DIR="$tmp/caller-config" "$so" -- "$prompt") >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ -s "$CLAUDE_STUB_ARGV" ] && ! grep -q '委譲元' "$CLAUDE_STUB_ARGV" && [ -s "$TMUX_STUB_LOG" ] && [ ! -e "$CQ_STUB_LOG" ]; then
  echo "ok: no '## 委譲元' appended and no claude-queue link, even under a claude parent"
else echo "FAIL: parent link rc=$rc cq=$(cat "$CQ_STUB_LOG" 2>/dev/null)"; fail=1; fi
if [ "$rc" -eq 0 ] && [ -s "$CLAUDE_STUB_ENV" ] && ! grep -qE '^(CLAUDE_CODE_SESSION_ID|CLAUDE_CODE_CHILD_SESSION|CLAUDECODE|CLAUDE_CONFIG_DIR)=' "$CLAUDE_STUB_ENV"; then
  echo "ok: caller's session markers and CLAUDE_CONFIG_DIR do not reach the new claude"
else echo "FAIL: env leaked: $(grep -E '^(CLAUDE_|CLAUDECODE)' "$CLAUDE_STUB_ENV" | paste -sd' ')"; fail=1; fi
# tmux itself must not carry them either: a server that tmux starts keeps its
# own env as the global environment for every later pane.
if [ "$rc" -eq 0 ] && [ -s "$TMUX_STUB_ENV" ] && ! grep -qE '^(CLAUDE_CODE_SESSION_ID|CLAUDE_CODE_CHILD_SESSION|CLAUDECODE|CLAUDE_CONFIG_DIR)=' "$TMUX_STUB_ENV"; then
  echo "ok: caller's session markers and CLAUDE_CONFIG_DIR do not reach tmux (server global env)"
else echo "FAIL: env leaked into tmux: $(grep -E '^(CLAUDE_|CLAUDECODE)' "$TMUX_STUB_ENV" 2>/dev/null | paste -sd' ')"; fail=1; fi
if grep -qxF "exec -C $cwdrepo -- claude --permission-mode acceptEdits $prompt" "$MISE_STUB_LOG"; then
  echo "ok: claude is launched through mise exec -C <main toplevel>"
else echo "FAIL: mise exec"; sed 's/^/  mise| /' "$MISE_STUB_LOG" 2>/dev/null; fail=1; fi

# --- --model ------------------------------------------------------------------
reset_logs
out="$(cd "$cwdrepo" && "$so" --model opus -- "$prompt" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sed -n 3,4p "$CLAUDE_STUB_ARGV" | paste -sd' ')" = "--model opus" ] \
   && grep -qxF 'model    : opus' <<<"$out"; then
  echo "ok: --model is passed to claude and reported"
else echo "FAIL: --model rc=$rc"; sed 's/^/  argv| /' "$CLAUDE_STUB_ARGV" 2>/dev/null; fail=1; fi

for args in "--model|''|--|p" "nothing" "--" "--|''" "p"; do
  reset_logs
  case "$args" in
    "--model|''|--|p") set -- --model "" -- p ;;
    nothing) set -- ;;
    --) set -- -- ;;
    "--|''") set -- -- "" ;;
    p) set -- p ;;
  esac
  (cd "$cwdrepo" && "$so" "$@") >/dev/null 2>&1; rc=$?
  if [ "$rc" -ne 0 ] && [ ! -e "$TMUX_STUB_LOG" ]; then
    echo "ok: rejected without launching: $args"
  else echo "FAIL: accepted or launched: $args (rc=$rc)"; fail=1; fi
done
set --

# --- --global -----------------------------------------------------------------
reset_logs
out="$(cd "$cwdrepo" && "$so" --global -- "$prompt" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$CLAUDE_STUB_CWD")" = "$(real "$scriptrepo")" ] \
   && [ "$(grep -A1 -xF -- '-s' "$TMUX_STUB_LOG" | tail -n1)" = scriptrepo ]; then
  echo "ok: --global anchors to the script's own repo, not cwd"
else echo "FAIL: --global rc=$rc out=$out"; fail=1; fi

# --- attach hint --------------------------------------------------------------
out="$(cd "$cwdrepo" && "$so" -- p 2>/dev/null)"
out_in="$(cd "$cwdrepo" && TMUX=fake "$so" -- p 2>/dev/null)"
if grep -qxF 'attach   : tmux attach -t cwdrepo' <<<"$out" && grep -qxF 'attach   : gts cwdrepo' <<<"$out_in"; then
  echo "ok: attach hint is gts inside tmux, tmux attach outside"
else echo "FAIL: attach hint: [$out] [$out_in]"; fail=1; fi

# --- tmux failures ------------------------------------------------------------
reset_logs
err="$(cd "$cwdrepo" && TMUX_STUB_FAIL=1 "$so" -- p 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'new-session' <<<"$err" && [ ! -e "$CLAUDE_STUB_ARGV" ]; then
  echo "ok: a failing tmux launch exits non-zero with the reason on stderr"
else echo "FAIL: tmux failure rc=$rc err=$err"; fail=1; fi

# No tmux on PATH at all: a PATH holding only what the script needs besides tmux.
notmux="$tmp/notmux"
mkdir -p "$notmux"
for c in bash env git dirname basename readlink awk grep; do ln -s "$(command -v "$c")" "$notmux/$c"; done
err="$(cd "$cwdrepo" && PATH="$notmux" "$notmux/bash" "$so" -- p 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'tmux not found' <<<"$err"; then
  echo "ok: missing tmux exits non-zero with the reason on stderr"
else echo "FAIL: missing tmux rc=$rc err=$err"; fail=1; fi

[ "$fail" -eq 0 ] && echo "ALL OK" || echo "SOME FAILED"
exit "$fail"
