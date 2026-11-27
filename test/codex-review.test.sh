#!/usr/bin/env bash
# Tests for bin/codex-review. gh, mise and codex are PATH stubs: the codex stub
# records its argv and stdin and writes CODEX_STUB_OUT to the -o file; it never
# forwards to the real codex, so no review is ever sent anywhere and ~/.codex is
# never touched. No test framework; run with bash.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
bin="$here/../bin/codex-review"
fail=0

work="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$work"' EXIT
stub="$work/stub"; mkdir -p "$stub"
nocodex="$work/nocodex"; mkdir -p "$nocodex"

# gh stub: `pr diff` prints a diff, `pr view` prints the PR metadata JSON.
# GH_FAIL=1 makes every call fail.
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
[ "${GH_FAIL:-0}" = 1 ] && { echo "HTTP 500" >&2; exit 1; }
case "$1 $2" in
  "pr diff") printf '%s\n' 'diff --git a/x.sh b/x.sh' '+echo DIFF_MARKER' ;;
  "pr view") printf '%s\n' '{"title":"T","body":"BODY_MARKER","baseRefName":"main","headRefOid":"abc"}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 99 ;;
esac
STUB
# mise stub: run the command after `--` in the -C dir, as mise exec does.
cat >"$stub/mise" <<'STUB'
#!/usr/bin/env bash
dir=""
while [ $# -gt 0 ]; do
  case "$1" in -C) dir="$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac
done
cd "${dir:-.}" && exec "$@"
STUB
# codex stub. `login status` exits CODEX_STUB_LOGIN_RC. `exec` appends its argv
# (one `[arg]` per line) to $CODEX_ARGS, copies stdin to $CODEX_STDIN, writes
# $CODEX_STUB_OUT to the file after -o, prints a turn.completed event, sleeps
# CODEX_STUB_SLEEP seconds and exits CODEX_STUB_RC.
cat >"$stub/codex" <<'STUB'
#!/usr/bin/env bash
if [ "$1 ${2:-}" = "login status" ]; then exit "${CODEX_STUB_LOGIN_RC:-0}"; fi
[ "$1" = exec ] || { echo "unexpected codex call: $*" >&2; exit 99; }
printf '[%s]\n' "$@" >>"$CODEX_ARGS"
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
cat >"$CODEX_STDIN"
[ -n "$out" ] && printf '%s' "${CODEX_STUB_OUT-}" >"$out"
echo '{"type":"thread.started"}'
echo '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":2}}'
sleep "${CODEX_STUB_SLEEP:-0}"
exit "${CODEX_STUB_RC:-0}"
STUB
chmod +x "$stub/gh" "$stub/mise" "$stub/codex"
cp "$stub/gh" "$stub/mise" "$nocodex/"

# Two versions of the toolkit plugin; sort -V must pick 1.0.10 over 1.0.9 (plain sort would not).
plugins="$work/plugins"
for v in 1.0.9 1.0.10; do
  mkdir -p "$plugins/$v/agents"
  printf '%s\n' '---' 'name: code-reviewer' 'description: FRONTMATTER_MARKER' '---' '' "BODY_OF_$v" \
    >"$plugins/$v/agents/code-reviewer.md"
done

good='{"findings":[{"title":"t1","detail":"d1","severity_label":"Important","file":"x.sh","line":3,"confidence":0.8}]}'

# run <args...>: runs the wrapper with fresh logs; sets rc, out (stdout file).
run() {
  : >"$work/args"; rm -f "$work/stdin"
  out="$work/stdout"
  env CODEX_ARGS="$work/args" CODEX_STDIN="$work/stdin" \
    CODEX_REVIEW_PLUGIN_ROOT="$plugins" PATH="$stub:$PATH" \
    "$bin" "$@" >"$out" 2>"$work/stderr"
  rc=$?
}
ok() { echo "ok: $1"; }
ng() { echo "FAIL: $1 (rc=$rc stdout=$(cat "$out") stderr=$(cat "$work/stderr"))"; fail=1; }
codex_ran() { grep -qxF '[exec]' "$work/args"; }

run 42 code-simplifier
[ "$rc" = 1 ] && ! codex_ran && ok "code-simplifier is rejected" || ng "code-simplifier"

run 42 nonexistent
[ "$rc" = 1 ] && ! codex_ran && ok "unknown perspective is rejected" || ng "unknown perspective"

run abc code-reviewer
[ "$rc" = 1 ] && ok "non-numeric PR is rejected" || ng "non-numeric PR"

run 42 code-reviewer --sandbox
[ "$rc" = 1 ] && ! codex_ran && ok "a flag in the prohibitions slot is rejected" || ng "flag passthrough"

run 42 code-reviewer "$work/missing-file"
[ "$rc" = 1 ] && ! codex_ran && ok "unreadable prohibitions file is rejected" || ng "missing prohibitions file"

# A readable file outside the temp dirs (this test file itself, in the checkout)
# must not be shipped to codex.
TMPDIR="$work" CODEX_STUB_OUT="$good" run 42 code-reviewer "$here/codex-review.test.sh"
[ "$rc" = 1 ] && ! codex_ran && ok "prohibitions file outside the temp dirs is rejected" || ng "outside temp dir"
# A symlink inside the temp dir pointing outside it is resolved first.
ln -s "$here/codex-review.test.sh" "$work/link-out"
TMPDIR="$work" CODEX_STUB_OUT="$good" run 42 code-reviewer "$work/link-out"
[ "$rc" = 1 ] && ! codex_ran && ok "symlink escaping the temp dir is rejected" || ng "symlink escape"

GH_FAIL=1 CODEX_STUB_OUT="$good" run 42 code-reviewer
[ "$rc" = 2 ] && ! codex_ran && [ ! -s "$out" ] && ok "gh failure exits 2 without running codex" || ng "gh failure"

CODEX_STUB_OUT="$good" run 42 pr-test-analyzer
[ "$rc" = 3 ] && ! codex_ran && ok "missing agent definition exits 3" || ng "missing definition"

# PATH without any codex at all: drop every entry holding one, so the real codex
# on this machine is neither found nor run.
nocodex_path="$nocodex"
IFS=: read -ra path_entries <<<"$PATH"
for e in "${path_entries[@]}"; do
  [ -n "$e" ] && [ -x "$e/codex" ] && continue
  nocodex_path="$nocodex_path:$e"
done
out="$work/stdout"
env CODEX_ARGS="$work/args" CODEX_STDIN="$work/stdin" CODEX_REVIEW_PLUGIN_ROOT="$plugins" \
  PATH="$nocodex_path" "$bin" 42 code-reviewer >"$out" 2>"$work/stderr"
rc=$?
[ "$rc" = 4 ] && [ ! -s "$out" ] && grep -qF 'not installed' "$work/stderr" \
  && ok "absent codex exits 4" || ng "absent codex"

CODEX_STUB_LOGIN_RC=1 CODEX_STUB_OUT="$good" run 42 code-reviewer
[ "$rc" = 4 ] && ! codex_ran && grep -qF 'not logged in' "$work/stderr" \
  && ok "logged-out codex exits 4" || ng "logged out"

# Happy path.
CODEX_STUB_OUT="$good" run 42 code-reviewer
if [ "$rc" = 0 ] \
  && jq -e '.perspective == "code-reviewer"' "$out" >/dev/null \
  && jq -e --argjson g "$good" '.findings == $g.findings' "$out" >/dev/null \
  && jq -e '.usage == {"input_tokens":10,"cached_input_tokens":4,"output_tokens":2}' "$out" >/dev/null; then
  ok "success prints perspective, findings and usage"
else ng "success output"; fi
# --sandbox must be immediately followed by read-only, not merely both present.
if grep -A1 -xF '[--sandbox]' "$work/args" | grep -qxF '[read-only]' \
  && grep -qxF '[--ephemeral]' "$work/args" \
  && grep -qxF '[--output-schema]' "$work/args" \
  && grep -qxF '[-o]' "$work/args"; then
  ok "codex runs with --sandbox read-only --ephemeral --output-schema -o"
else ng "codex argv: $(tr '\n' ' ' <"$work/args")"; fi
grep -qF 'multi_agent' "$work/args" && ng "multi-agent flag passed" || ok "no multi-agent flag"
if grep -qF 'BODY_OF_1.0.10' "$work/stdin" && ! grep -qF 'BODY_OF_1.0.9' "$work/stdin" \
  && ! grep -qF 'FRONTMATTER_MARKER' "$work/stdin"; then
  ok "prompt carries the newest definition body without frontmatter"
else ng "prompt definition: $(cat "$work/stdin")"; fi
if grep -qF 'DIFF_MARKER' "$work/stdin" && grep -qF 'BODY_MARKER' "$work/stdin" \
  && grep -qF 'not the local `git diff`' "$work/stdin"; then
  ok "prompt carries the PR diff, body and the not-local-diff scope"
else ng "prompt data"; fi

# Prohibitions are passed verbatim.
printf '%s\n' 'Never touch ~/.codex PROHIBITION_MARKER' >"$work/prohib"
TMPDIR="$work" CODEX_STUB_OUT="$good" run 42 code-reviewer "$work/prohib"
[ "$rc" = 0 ] && grep -qF 'Never touch ~/.codex PROHIBITION_MARKER' "$work/stdin" \
  && ok "prohibitions file reaches the prompt verbatim" || ng "prohibitions"

# Failures must never read as "no findings".
CODEX_STUB_OUT='' run 42 code-reviewer
[ "$rc" = 5 ] && [ ! -s "$out" ] && ok "empty -o output exits 5 with empty stdout" || ng "empty output"

CODEX_STUB_OUT='{"findings":"x"}' run 42 code-reviewer
[ "$rc" = 5 ] && [ ! -s "$out" ] && ok "schema mismatch exits 5" || ng "schema mismatch"

CODEX_STUB_OUT='{"findings":[{"title":"t"}]}' run 42 code-reviewer
[ "$rc" = 5 ] && [ ! -s "$out" ] && ok "finding missing required keys exits 5" || ng "missing keys"

CODEX_STUB_OUT='not json' run 42 code-reviewer
[ "$rc" = 5 ] && [ ! -s "$out" ] && ok "non-JSON output exits 5" || ng "non-JSON"

CODEX_STUB_OUT="$good" CODEX_STUB_RC=1 run 42 code-reviewer
[ "$rc" = 5 ] && [ ! -s "$out" ] && ok "codex non-zero exits 5" || ng "codex non-zero"

CODEX_STUB_OUT="$good" CODEX_STUB_SLEEP=5 CODEX_REVIEW_TIMEOUT=1 run 42 code-reviewer
[ "$rc" = 5 ] && [ ! -s "$out" ] && ok "timeout exits 5" || ng "timeout"

# An empty findings array is a valid, successful review.
CODEX_STUB_OUT='{"findings":[]}' run 42 code-reviewer
[ "$rc" = 0 ] && jq -e '.findings == []' "$out" >/dev/null && ok "empty findings succeed" || ng "empty findings"

exit "$fail"
