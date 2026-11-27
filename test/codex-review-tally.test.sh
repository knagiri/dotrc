#!/usr/bin/env bash
# Tests for bin/codex-review-tally. gh and mise are PATH stubs; XDG_STATE_HOME
# points into the sandbox, so the comparison log is written there. Verdict and
# codex-output fixtures are generated here. No test framework; run with bash.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
bin="$here/../bin/codex-review-tally"
fail=0

work="$(mktemp -d -p /tmp)"
trap 'sandbox_cleanup; rm -rf "$work"' EXIT
stub="$work/stub"; mkdir -p "$stub"

# gh stub: `repo view` prints the repo, `pr view` the head sha (what the
# wrapper's --jq would yield). GH_FAIL=1 makes every call fail.
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
[ "${GH_FAIL:-0}" = 1 ] && { echo "HTTP 500" >&2; exit 1; }
[ "${GH_FAIL_PRVIEW:-0}" = 1 ] && [ "$1 $2" = "pr view" ] && { echo "HTTP 500" >&2; exit 1; }
case "$1 $2" in
  "repo view") echo "example-org/example-repo" ;;
  "pr view") echo "0123456789abcdef0123456789abcdef01234567" ;;
  *) echo "unexpected gh call: $*" >&2; exit 99 ;;
esac
STUB
cat >"$stub/mise" <<'STUB'
#!/usr/bin/env bash
dir=""
while [ $# -gt 0 ]; do
  case "$1" in -C) dir="$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac
done
cd "${dir:-.}" && exec "$@"
STUB
chmod +x "$stub/gh" "$stub/mise"

export XDG_STATE_HOME="$work/state"
log="$XDG_STATE_HOME/codex-review/compare.jsonl"

ok() { echo "ok: $1"; }
ng() { echo "FAIL: $1 (rc=$rc stdout=$(cat "$work/stdout" 2>/dev/null) stderr=$(cat "$work/stderr" 2>/dev/null))"; fail=1; }

sha=0123456789abcdef0123456789abcdef01234567
# cx_out <dir> <perspective> <pr> <sha> <input> <cached> <output>: a codex-review success output.
cx_out() {
  printf '{"perspective":"%s","pr":%s,"head_sha":"%s","findings":[],"usage":{"input_tokens":%s,"cached_input_tokens":%s,"output_tokens":%s}}\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" >"$1/$2.json"
}
# mk_cdir <dir> <pr>: code-reviewer succeeded; pr-test-analyzer's file is empty
# (what a failed codex-review leaves when its stdout is redirected to a file);
# comment-analyzer: codex ran, toolkit did not succeed.
mk_cdir() {
  mkdir -p "$1"
  cx_out "$1" code-reviewer "$2" "$sha" 100 40 7
  : >"$1/pr-test-analyzer.json"
  cx_out "$1" comment-analyzer "$2" "$sha" 5 1 3
}
cdir="$work/codex"; mk_cdir "$cdir" 42

verdict="$work/verdict.json"
cat >"$verdict" <<'EOF'
{
  "findings_to_fix": [
    {"summary": "both-1", "source": "codex:code-reviewer, pr-review-toolkit:code-reviewer, self", "severity": "high"},
    {"summary": "toolkit-1", "source": "pr-review-toolkit:code-reviewer", "severity": "medium", "specialist_severity": "Important"},
    {"summary": "codex-1", "source": "codex:code-reviewer", "severity": "low"},
    {"summary": "unpaired-tk", "source": "pr-review-toolkit:pr-test-analyzer", "severity": "medium"},
    {"summary": "unpaired-cx", "source": "codex:comment-analyzer", "severity": "low"},
    {"summary": "self-only", "source": "self", "severity": "high"},
    {"summary": "bot-only", "source": "copilot-pull-request-reviewer", "severity": "low"}
  ],
  "findings_gated": [
    {"summary": "gated-blocker", "source": "pr-review-toolkit:code-reviewer", "blocker": true, "severity": "high"},
    {"summary": "gated-rejected", "source": "codex:code-reviewer", "blocker": false, "severity": "low"},
    {"summary": "gated-rejected-both", "source": "pr-review-toolkit:code-reviewer, codex:code-reviewer", "blocker": false, "severity": "low"}
  ],
  "threads_pending": [],
  "pr_dispositions": []
}
EOF

run() {
  env PATH="$stub:$PATH" "$bin" "$@" >"$work/stdout" 2>"$work/stderr"
  rc=$?
}

run 42 "$verdict" code-reviewer,pr-test-analyzer "$cdir"
rec="$(tail -n 1 "$log" 2>/dev/null)"
check() { jq -e "$1" <<<"$rec" >/dev/null 2>&1; }
[ "$rc" = 0 ] && check '.repo == "example-org/example-repo" and .pr == 42 and (.head_sha | length) == 40' \
  && ok "record carries repo, PR and head sha" || ng "record header"
check '.pairs == ["code-reviewer"] and .codex_failed == ["pr-test-analyzer"] and .toolkit_failed == ["comment-analyzer"]' \
  && ok "pairs only perspectives both sides completed" || ng "pairs: $rec"
check '.adopted.both == 1' && ok "mixed codex/toolkit/self source counts as both" || ng "both: $rec"
check '.adopted.toolkit_only == 2 and ([.toolkit_only_items[].summary] | sort) == ["gated-blocker", "toolkit-1"]' \
  && ok "toolkit-only items (incl. gated blocker) are adopted and listed" || ng "toolkit_only: $rec"
check '.adopted.codex_only == 1 and [.codex_only_items[].summary] == ["codex-1"]' \
  && ok "codex-only item is adopted and listed" || ng "codex_only: $rec"
check '.adopted.unpaired == 2' && ok "findings of half-failed perspectives are unpaired" || ng "unpaired: $rec"
check '.not_adopted == {"toolkit_only": 0, "codex_only": 1, "both": 1, "unpaired": 0}' \
  && ok "blocker:false gated findings are not adopted" || ng "not_adopted: $rec"
check '([.adopted[]] | add) == 6' && ok "self / bot-only findings are not counted" || ng "self/bot: $rec"
check '.codex_usage == {"input_tokens": 105, "cached_input_tokens": 41, "output_tokens": 10}' \
  && ok "codex usage is summed over successful outputs" || ng "usage: $rec"
check '.toolkit_only_items[] | select(.summary == "toolkit-1") | .specialist_severity == "Important"' \
  && ok "items keep severity and specialist_severity" || ng "item fields: $rec"

# Argument and input errors.
run 42 "$verdict" code-simplifier "$cdir"
[ "$rc" = 1 ] && ok "unknown toolkit perspective is rejected" || ng "bad toolkit-ok"
printf 'not json' >"$work/bad.json"
run 42 "$work/bad.json" code-reviewer "$cdir"
[ "$rc" = 1 ] && ok "unparsable verdict is rejected" || ng "bad verdict"
run 42 "$verdict" code-reviewer "$work/nodir"
[ "$rc" = 1 ] && ok "missing codex dir is rejected" || ng "missing dir"
run abc "$verdict" code-reviewer "$cdir"
[ "$rc" = 1 ] && ok "non-numeric PR is rejected" || ng "bad PR"
before="$(wc -l <"$log")"
GH_FAIL=1 run 42 "$verdict" code-reviewer "$cdir"
[ "$rc" = 2 ] && [ "$(wc -l <"$log")" = "$before" ] && ok "gh failure exits 2 and appends nothing" || ng "gh failure"

# A gh pr view failure alone (repo view fine) also exits 2 and appends nothing.
before="$(wc -l <"$log")"
GH_FAIL_PRVIEW=1 run 42 "$verdict" code-reviewer "$cdir"
[ "$rc" = 2 ] && [ "$(wc -l <"$log")" = "$before" ] && ok "pr view failure alone exits 2 and appends nothing" || ng "pr view failure"

# A verdict whose findings_gated is not an array is rejected.
printf '%s\n' '{"findings_to_fix":[],"findings_gated":"x"}' >"$work/badshape.json"
run 42 "$work/badshape.json" code-reviewer "$cdir"
[ "$rc" = 1 ] && ok "verdict with non-array findings_gated is rejected" || ng "bad verdict shape"

# Codex outputs that are not what codex-review prints for this PR and head
# commit are failures, not completions.
stale="$work/stale"; mkdir -p "$stale"
cx_out "$stale" code-reviewer 41 "$sha" 1 1 1                                  # other PR
cx_out "$stale" pr-test-analyzer 42 ffffffffffffffffffffffffffffffffffffffff 1 1 1  # other head commit
printf '%s\n' '{"perspective":"comment-analyzer","findings":[]}' >"$stale/comment-analyzer.json"  # no pr / head_sha (old format)
printf 'not json at all\n' >"$stale/silent-failure-hunter.json"                 # non-JSON, non-empty
printf '%s\n' '{"perspective":"code-reviewer","pr":42,"head_sha":"'"$sha"'","findings":[]}' >"$stale/type-design-analyzer.json"  # perspective != file name
run 42 "$verdict" code-reviewer,pr-test-analyzer,comment-analyzer,silent-failure-hunter,type-design-analyzer "$stale"
rec="$(tail -n 1 "$log")"
check '.pairs == [] and (.codex_failed | sort) == ["code-reviewer","comment-analyzer","pr-test-analyzer","silent-failure-hunter","type-design-analyzer"]' \
  && ok "stale, other-PR, non-JSON and mislabelled codex outputs are codex_failed" || ng "stale outputs: $rec"
printf '%s\n' '{"perspective":"code-reviewer","pr":42,"head_sha":"'"$sha"'","findings":"x"}' >"$stale/code-reviewer.json"
run 42 "$verdict" code-reviewer "$stale"
rec="$(tail -n 1 "$log")"
check '.pairs == [] and .codex_failed == ["code-reviewer"]' \
  && ok "codex output with non-array findings is codex_failed" || ng "non-array findings: $rec"
# A file with several JSON values is not a codex-review output, even if its last value is valid.
multi="$work/multi"; mkdir -p "$multi"
cx_out "$multi" code-reviewer 42 "$sha" 1 1 1
{ printf '%s\n' '{"x":1}'; cat "$multi/code-reviewer.json"; } >"$multi/x" && mv "$multi/x" "$multi/code-reviewer.json"
run 42 "$verdict" code-reviewer "$multi"
rec="$(tail -n 1 "$log")"
[ "$rc" = 0 ] && check '.pairs == [] and .codex_failed == ["code-reviewer"]' \
  && ok "codex output with several JSON values is codex_failed" || ng "multiple values: $rec"
# Two objects that would each be accepted alone are not accepted when concatenated.
cx_out "$multi" code-reviewer 42 "$sha" 1 1 1
cat "$multi/code-reviewer.json" "$multi/code-reviewer.json" >"$multi/x" && mv "$multi/x" "$multi/code-reviewer.json"
run 42 "$verdict" code-reviewer "$multi"
rec="$(tail -n 1 "$log")"
[ "$rc" = 0 ] && check '.pairs == [] and .codex_failed == ["code-reviewer"]' \
  && ok "two valid JSON objects in one output are codex_failed" || ng "two valid values: $rec"

# Classification of mixed origins (any, not all; paired origins only). code-reviewer
# and silent-failure-hunter are paired; comment-analyzer's codex side failed.
cdir2="$work/codex2"; mkdir -p "$cdir2"
cx_out "$cdir2" code-reviewer 42 "$sha" 1 1 1
cx_out "$cdir2" silent-failure-hunter 42 "$sha" 1 1 1
verdict2="$work/verdict2.json"
cat >"$verdict2" <<'JSON'
{"findings_to_fix": [
  {"summary": "m-a", "source": "pr-review-toolkit:code-reviewer, codex:comment-analyzer", "severity": "low"},
  {"summary": "m-b", "source": "pr-review-toolkit:comment-analyzer, codex:code-reviewer", "severity": "low"},
  {"summary": "m-c", "source": "pr-review-toolkit:code-reviewer, codex:silent-failure-hunter", "severity": "low"},
  {"summary": "m-d", "source": "pr-review-toolkit:code-reviewer, pr-review-toolkit:comment-analyzer", "severity": "low"},
  {"summary": "m-e", "source": "pr-review-toolkit:comment-analyzer, codex:comment-analyzer", "severity": "low"}
], "findings_gated": []}
JSON
run 42 "$verdict2" code-reviewer,comment-analyzer,silent-failure-hunter "$cdir2"
rec="$(tail -n 1 "$log")"
check '.pairs == ["code-reviewer","silent-failure-hunter"] and .adopted == {"toolkit_only": 2, "codex_only": 1, "both": 1, "unpaired": 1}' \
  && ok "mixed paired / unpaired and cross-perspective origins are classified by paired origins (any)" || ng "mixed origins: $rec"

# Malformed sources: trimmed names and "/" separators still count; typos and bare
# perspective names are reported, not silently bucketed or dropped.
cdir3="$work/codex3"; mkdir -p "$cdir3"; cx_out "$cdir3" code-reviewer 42 "$sha" 1 1 1
verdict3="$work/verdict3.json"
cat >"$verdict3" <<'JSON'
{"findings_to_fix": [
  {"summary": "s-space", "source": "codex: code-reviewer", "severity": "low"},
  {"summary": "s-typo", "source": "codex:code-reviewr, self", "severity": "low"},
  {"summary": "s-bare", "source": "silent-failure-hunter", "severity": "low"},
  {"summary": "s-slash", "source": "pr-review-toolkit:code-reviewer / codex:code-reviewer", "severity": "low"}
], "findings_gated": []}
JSON
run 42 "$verdict3" code-reviewer "$cdir3"
rec="$(tail -n 1 "$log")"
check '.adopted == {"toolkit_only": 0, "codex_only": 1, "both": 1, "unpaired": 0} and .malformed == {"count": 2, "items": ["s-typo", "s-bare"]}' \
  && grep -qF 'malformed' "$work/stderr" \
  && ok "malformed sources are reported; spaced and slash-separated origins count" || ng "malformed: $rec"

# An empty toolkit-ok list pairs nothing.
run 42 "$verdict" "" "$cdir"
[ "$rc" = 0 ] && jq -e '.pairs == [] and .adopted.both == 0 and .adopted.unpaired == 6' <<<"$(tail -n 1 "$log")" >/dev/null \
  && ok "empty toolkit-ok makes every specialist finding unpaired" || ng "empty toolkit-ok: $(tail -n 1 "$log")"

# Appending keeps one JSON record per line whatever the log ends with.
append_case() {  # <name> <setup: none|empty|newline|nonewline>
  rm -rf "$XDG_STATE_HOME"
  case "$2" in
    none) ;;
    empty) mkdir -p "${log%/*}"; : >"$log" ;;
    newline) mkdir -p "${log%/*}"; printf '%s\n' '{"old":1}' >"$log" ;;
    nonewline) mkdir -p "${log%/*}"; printf '%s' '{"old":1}' >"$log" ;;
  esac
  local want
  case "$2" in none|empty) want=1 ;; *) want=2 ;; esac
  run 42 "$verdict" code-reviewer "$cdir"
  if [ "$rc" = 0 ] && [ "$(wc -l <"$log")" = "$want" ] && jq -c . "$log" >/dev/null 2>&1 \
    && [ "$(jq -s length "$log")" = "$want" ]; then
    ok "append to $1 log keeps one record per line"
  else ng "append $1: $(cat "$log")"; fi
}
append_case "missing" none
append_case "empty" empty
append_case "newline-terminated" newline
append_case "unterminated" nonewline

# --summary totals every record.
rm -rf "$XDG_STATE_HOME"
cdir43="$work/codex43"; mk_cdir "$cdir43" 43
run 42 "$verdict" code-reviewer,pr-test-analyzer "$cdir"
run 43 "$verdict" code-reviewer,pr-test-analyzer "$cdir43"
run --summary
if [ "$rc" = 0 ] && jq -e '.records == 2 and .prs == 2 and .adopted.both == 2 and .adopted.toolkit_only == 4
    and .not_adopted.codex_only == 2 and .codex_usage.output_tokens == 20
    and .toolkit_only_by_severity == {"high": 2, "medium": 2}' "$work/stdout" >/dev/null; then
  ok "--summary totals the records"
else ng "--summary"; fi
# Re-running a PR adds a record but not a PR.
run 42 "$verdict" code-reviewer,pr-test-analyzer "$cdir"
run --summary
[ "$rc" = 0 ] && jq -e '.records == 3 and .prs == 2' "$work/stdout" >/dev/null \
  && ok "--summary counts records and distinct PRs separately" || ng "--summary records vs prs"
# A broken log line is a distinct failure, not a jq exit code.
printf 'garbage\n' >>"$log"
run --summary
[ "$rc" = 3 ] && ok "--summary over a broken log line exits 3" || ng "--summary broken log"
rm -rf "$XDG_STATE_HOME"
run --summary
[ "$rc" = 0 ] && jq -e '.records == 0 and .prs == 0' "$work/stdout" >/dev/null && ok "--summary with no log reports zero" || ng "--summary empty"

exit "$fail"
