#!/usr/bin/env bash
# Functional tests for bin/claude-review. A tmux stub records its argv (one
# element per line, bracketed) so we can assert the launch command without a
# real tmux server. No test framework required; run with bash.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../bin/claude-review"
fail=0

stubdir="$(mktemp -d)"
trap 'rm -rf "$stubdir"' EXIT
cat >"$stubdir/tmux" <<'STUB'
#!/usr/bin/env bash
: >"$TMUX_ARGS_FILE"
printf '[%s]\n' "$@" >>"$TMUX_ARGS_FILE"
STUB
chmod +x "$stubdir/tmux"

# Case 1: a numeric PR launches a bash -c that pipes `claude -p ...` into
# `tee <logfile>`, and creates the log dir under XDG_STATE_HOME/claude-review.
state="$stubdir/state"
out="$(TMUX_ARGS_FILE="$stubdir/args" TMUX="fake" XDG_STATE_HOME="$state" \
  PATH="$stubdir:$PATH" "$script" 42 2>&1)"; rc=$?
launchcmd="$(sed -n 's/^\[\(.*\)\]$/\1/p' "$stubdir/args" | tail -n1)"
if [ "$rc" -eq 0 ] \
  && grep -qxF '[new-window]' "$stubdir/args" \
  && grep -qxF '[review-pr42]' "$stubdir/args" \
  && grep -qxF '[bash]' "$stubdir/args" \
  && grep -qxF '[-c]' "$stubdir/args" \
  && printf '%s' "$launchcmd" | grep -qF '/pr-review-automerge 42' \
  && printf '%s' "$launchcmd" | grep -qE 'tee -- .*/claude-review/[^/]+/pr42_[^/]*_[0-9]{8}-[0-9]{6}\.log' \
  && [ -d "$state/claude-review" ]; then
  echo "ok: numeric PR launches bash -c piping claude into tee <logfile>, log dir created"
else
  echo "FAIL: case 1; rc=$rc out=$out args=$(cat "$stubdir/args" 2>/dev/null)"; fail=1
fi

# Case 2: missing argument exits non-zero.
TMUX="fake" PATH="$stubdir:$PATH" "$script" >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: missing arg fails" || { echo "FAIL: missing arg should exit non-zero"; fail=1; }

# Case 3: non-numeric argument exits non-zero.
TMUX="fake" PATH="$stubdir:$PATH" "$script" abc >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: non-numeric arg fails" || { echo "FAIL: non-numeric should exit non-zero"; fail=1; }

# Case 4: run outside tmux ($TMUX unset) exits non-zero.
PATH="$stubdir:$PATH" env -u TMUX "$script" 42 >/dev/null 2>&1; [ $? -ne 0 ] \
  && echo "ok: outside tmux fails" || { echo "FAIL: outside tmux should exit non-zero"; fail=1; }

exit "$fail"
