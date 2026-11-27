#!/usr/bin/env bash
# Tests for the grant gate of bin/gh-automerge: a PR whose diff changes a
# settings file or the frontmatter of a SKILL.md / agent definition must not be
# merged (exit 5, nothing issued), and an unreadable diff must stop it too.
# gh and mise are PATH stubs; the gh stub never forwards to the real gh, and
# `pr merge` only appends its argv to a log. No test framework; run with bash.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
bindir="$here/../bin"
fail=0

work="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$work"' EXIT
stub="$work/stub"; mkdir -p "$stub"

BASE=1111111111111111111111111111111111111111
HEAD=2222222222222222222222222222222222222222

# gh stub. The PR is described by files under $GH_FIX:
#   diff            -- what `pr diff` prints (GH_DIFF_FAIL=1: print it, exit 1)
#   files/<sha>/<path> -- what `api repos/{owner}/{repo}/contents/<path>?ref=<sha>`
#                      returns; a missing file is a 404
# `pr view` prints the "<base> <head>" line the wrapper's --jq would produce.
# `pr merge` appends its argv to $GH_MERGE_LOG and succeeds
# (one `[arg]` per line, so each call starts with `[pr]`).
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") echo "$GH_BASE $GH_HEAD"; exit 0 ;;
  "pr diff") cat "$GH_FIX/diff"; [ "${GH_DIFF_FAIL:-0}" = 1 ] && { echo "HTTP 502" >&2; exit 1; }; exit 0 ;;
  "pr merge")
    printf '[%s]\n' "$@" >>"$GH_MERGE_LOG"
    # GH_AUTO_CLEAN=1: refuse --auto the way GitHub does for a clean PR.
    if [ "${GH_AUTO_CLEAN:-0}" = 1 ] && [[ " $* " == *" --auto "* ]]; then
      echo "Pull request is in clean status" >&2; exit 1
    fi
    exit 0 ;;
esac
if [ "$1" = api ]; then
  ep="$2"; ep="${ep#repos/\{owner\}/\{repo\}/contents/}"
  path="${ep%%\?ref=*}"; sha="${ep##*\?ref=}"
  f="$GH_FIX/files/$sha/$path"
  [ -f "$f" ] && { cat "$f"; exit 0; }
  echo "gh: Not Found (HTTP 404)" >&2; exit 1
fi
echo "gh stub: unexpected call: $*" >&2
exit 1
STUB
# Stands in for `mise exec -C <dir> -- <cmd>` so the real mise is never reached.
cat >"$stub/mise" <<'STUB'
#!/usr/bin/env bash
dir=""
while [ $# -gt 0 ]; do
  case "$1" in -C) dir="$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac
done
cd "${dir:-.}" && exec "$@"
STUB
chmod +x "$stub/gh" "$stub/mise"

# ---- fixtures ---------------------------------------------------------------
fix="$work/fix"
mkfix() {  # mkfix <name>; diff on stdin
  mkdir -p "$fix/$1/files/$BASE" "$fix/$1/files/$HEAD"
  cat >"$fix/$1/diff"
}
put() {  # put <fixture> <sha> <path>; content on stdin
  mkdir -p "$(dirname "$fix/$1/files/$2/$3")"
  cat >"$fix/$1/files/$2/$3"
}
skill=dot/claude/skills/foo/SKILL.md

mkfix settings <<'EOF'
diff --git a/dot/claude/settings.json b/dot/claude/settings.json
index 1111111..2222222 100644
--- a/dot/claude/settings.json
+++ b/dot/claude/settings.json
@@ -3,1 +3,2 @@
     "allow": [
+      "Bash(curl *)",
EOF

mkfix allowed_tools <<EOF
diff --git a/$skill b/$skill
index 1111111..2222222 100644
--- a/$skill
+++ b/$skill
@@ -2,4 +2,4 @@
 name: foo
 description: use when foo
-allowed-tools: Read
+allowed-tools: Read, Bash
 ---
EOF
printf -- '---\nname: foo\ndescription: use when foo\nallowed-tools: Read\n---\n\n# foo\n' \
  | put allowed_tools "$BASE" "$skill"
printf -- '---\nname: foo\ndescription: use when foo\nallowed-tools: Read, Bash\n---\n\n# foo\n' \
  | put allowed_tools "$HEAD" "$skill"

mkfix new_skill <<EOF
diff --git a/$skill b/$skill
new file mode 100644
index 0000000..2222222
--- /dev/null
+++ b/$skill
@@ -0,0 +1,5 @@
+---
+name: foo
+allowed-tools: Bash
+---
+# foo
EOF
printf -- '---\nname: foo\nallowed-tools: Bash\n---\n# foo\n' | put new_skill "$HEAD" "$skill"

# The hunk starts at line 1 and its context includes the frontmatter: only the
# position of the changed line decides, which is what the gate must get right.
mkfix body_only <<EOF
diff --git a/$skill b/$skill
index 1111111..2222222 100644
--- a/$skill
+++ b/$skill
@@ -1,7 +1,7 @@
 ---
 name: foo
 allowed-tools: Read
 ---

 # foo
-old body
+new body
EOF
printf -- '---\nname: foo\nallowed-tools: Read\n---\n\n# foo\nold body\n' | put body_only "$BASE" "$skill"
printf -- '---\nname: foo\nallowed-tools: Read\n---\n\n# foo\nnew body\n' | put body_only "$HEAD" "$skill"

mkfix unrelated <<'EOF'
diff --git a/README.md b/README.md
index 1111111..2222222 100644
--- a/README.md
+++ b/README.md
@@ -1 +1 @@
-a
+b
EOF

# `pr diff` fails after printing a harmless-looking partial diff, so only the
# exit status of the diff read can stop it.
cp -r "$fix/unrelated" "$fix/diff_fail"

mkfix agent <<'EOF'
diff --git a/dot/claude/agents/impl.md b/dot/claude/agents/impl.md
index 1111111..2222222 100644
--- a/dot/claude/agents/impl.md
+++ b/dot/claude/agents/impl.md
@@ -2,3 +2,3 @@
 name: impl
-tools: Read
+tools: Read, Bash
 ---
EOF
printf -- '---\nname: impl\ntools: Read\n---\nbody\n' | put agent "$BASE" dot/claude/agents/impl.md
printf -- '---\nname: impl\ntools: Read, Bash\n---\nbody\n' | put agent "$HEAD" dot/claude/agents/impl.md

mkfix empty </dev/null

# ---- runner -----------------------------------------------------------------
run() {  # run <bindir> <fixture> -> sets rc, out (stderr), merge log in $work/merges
  : >"$work/merges"
  out="$(env GH_FIX="$fix/$2" GH_BASE="$BASE" GH_HEAD="$HEAD" GH_MERGE_LOG="$work/merges" \
    GH_DIFF_FAIL="$([ "$2" = diff_fail ] && echo 1 || echo 0)" \
    PATH="$stub:$PATH" "$1/gh-automerge" 42 2>&1 >/dev/null)"
  rc=$?
}
merged() { [ -s "$work/merges" ]; }

# stopped <bindir> <fixture> <text expected on stderr>
stopped() {
  run "$1" "$2"
  [ "$rc" -eq 5 ] && ! merged && grep -qF -- "$3" <<<"$out" \
    && grep -qF 'wait for a human to approve' <<<"$out"
}
# passed <bindir> <fixture>: merged once, with the head pinned
passed() {
  run "$1" "$2"
  [ "$rc" -eq 0 ] && merged && grep -qxF '[--auto]' "$work/merges" \
    && grep -qxF '[--match-head-commit]' "$work/merges" && grep -qxF "[$HEAD]" "$work/merges"
}

# The clean-status fallback (direct merge) must pin the head too: two merge
# calls, the second without --auto, each with --match-head-commit <head>.
check_fallback_pin() {
  : >"$work/merges"
  out="$(env GH_FIX="$fix/unrelated" GH_BASE="$BASE" GH_HEAD="$HEAD" GH_MERGE_LOG="$work/merges" \
    GH_AUTO_CLEAN=1 PATH="$stub:$PATH" "$1/gh-automerge" 42 2>&1 >/dev/null)"
  rc=$?
  [ "$rc" -eq 0 ] && [ "$(grep -cxF '[pr]' "$work/merges")" -eq 2 ] \
    && [ "$(grep -cxF '[--auto]' "$work/merges")" -eq 1 ] \
    && [ "$(grep -cxF '[--match-head-commit]' "$work/merges")" -eq 2 ] \
    && [ "$(grep -cxF "[$HEAD]" "$work/merges")" -eq 2 ]
}
check_settings()      { stopped "$1" settings dot/claude/settings.json; }
check_allowed_tools() { stopped "$1" allowed_tools "$skill: frontmatter changed"; }
check_new_skill()     { stopped "$1" new_skill "$skill: new file"; }
check_body_only()     { passed "$1" body_only; }
check_unrelated()     { passed "$1" unrelated; }
check_diff_fail()     { stopped "$1" diff_fail "could not read the diff"; }
check_agent()         { stopped "$1" agent "dot/claude/agents/impl.md: frontmatter changed"; }
check_empty()         { stopped "$1" empty "has no file"; }

# Control: the gh the wrapper reaches is the stub, and the merge call lands in
# its log (so the mutants below cannot reach a real merge).
if [ "$(PATH="$stub:$PATH" command -v gh)" = "$stub/gh" ] && check_unrelated "$bindir"; then
  echo "ok: control: gh resolves to the stub and the merge call is captured by it"
else echo "FAIL: control: gh=$(PATH="$stub:$PATH" command -v gh) rc=$rc out=$out"; fail=1; fi

for c in settings allowed_tools new_skill body_only unrelated diff_fail agent empty fallback_pin; do
  if "check_$c" "$bindir"; then echo "ok: gh-automerge gate: $c"
  else echo "FAIL: gh-automerge gate: $c rc=$rc out=$out merges=$(cat "$work/merges")"; fail=1; fi
done

# ---- discrimination (evidence-over-guesswork §4) ----------------------------
# The gate is new code, so each condition is broken one at a time and the
# fixture covering it must fail. `cmp` catches a sed that matched nothing.
mutant() {  # mutant <name> <check fn> <sed expression>...
  local name="$1" check="$2" d="$work/mutant-$1"; shift 2
  local args=() e
  for e in "$@"; do args+=(-e "$e"); done
  rm -rf "$d"; mkdir -p "$d"; cp -a "$bindir/." "$d/"
  sed "${args[@]}" "$bindir/gh-automerge" >"$d/gh-automerge"; chmod +x "$d/gh-automerge"
  if cmp -s "$bindir/gh-automerge" "$d/gh-automerge"; then
    echo "FAIL: mutant '$name' is identical; the check is a no-op"; fail=1
  elif ! "$check" "$d"; then echo "ok: mutant '$name' is caught by $check"
  else echo "FAIL: mutant '$name' still passes $check"; fail=1; fi
}
mutant nosettings check_settings 's/^is_settings() { .*/is_settings() { false; }/'
mutant nofmfile check_allowed_tools 's/^  \[\[ "\${b,,}" == skill.md \]\] && return 0/  false/'
mutant nofmfile_agent check_agent 's/^  \[\[ "\$p" =~ (^|\/)agents\/\[^\/\]+\\.md\$ \]\] && return 0/  :/'
mutant nocompare check_allowed_tools 's/\[ "\$fb" = "\$fh" \] ||/true ||/'
mutant nofmextract check_allowed_tools 's/^    NR == 1 { l = \$0;/    NR == 1 { exit 0; l = $0;/'
mutant nodifffail check_diff_fail 's/|| gate_refuse "could not read the diff/|| true "could not read the diff/'
mutant noempty check_empty 's/^\[ "\$nfiles" -gt 0 \] ||/true ||/'
mutant exit1 check_settings 's/^  exit 5$/  exit 1/'
mutant nopin check_unrelated 's/ --match-head-commit "\$head_oid" "\$pr" 2>/ "$pr" 2>/'
mutant nopin_fallback check_fallback_pin 's/^gh_mise pr merge --merge --match-head-commit "\$head_oid" "\$pr"$/gh_mise pr merge --merge "$pr"/'
# A new SKILL.md is stopped three ways: the created-file branch, the
# path-mismatch branch (the old path is empty) and the base-side fetch failing
# (fail closed). Breaking one leaves the PR stopped for another reason, which
# only the reason text tells apart; all three together must let it merge.
mutant nocreated check_new_skill \
  's/^  if \[ "\$f_created" -eq 1 \] || \[ -z "\$old" \]; then/  if false; then/'
check_new_skill_stops() { run "$1" new_skill; [ "$rc" -eq 5 ] && ! merged; }
mutant nonewfile check_new_skill_stops \
  's/^  if \[ "\$f_created" -eq 1 \] || \[ -z "\$old" \]; then/  if false; then/' \
  's/^  if \[ "\$f_renamed" -eq 1 \] || \[ "\$old" != "\$new" \]; then/  if false; then/' \
  's/^    reasons+=("\$new: frontmatter could not be compared/    true || reasons+=("$new: frontmatter could not be compared/'

exit "$fail"
