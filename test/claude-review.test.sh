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

# Case 1: a numeric PR builds the expected new-window command, and the prompt
# is passed as ONE argv element (quoting preserved).
out="$(TMUX_ARGS_FILE="$stubdir/args" TMUX="fake" PATH="$stubdir:$PATH" "$script" 42 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] \
  && grep -qxF '[new-window]' "$stubdir/args" \
  && grep -qxF '[review-pr42]' "$stubdir/args" \
  && grep -qxF '[claude]' "$stubdir/args" \
  && grep -qxF '[-p]' "$stubdir/args" \
  && grep -qxF '[--permission-mode]' "$stubdir/args" \
  && grep -qxF '[acceptEdits]' "$stubdir/args" \
  && grep -qxF '[/pr-review-merge 42]' "$stubdir/args"; then
  echo "ok: numeric PR builds new-window command with single-arg prompt"
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
