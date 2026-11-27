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
RUN_ENV=()

work="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$work"' EXIT
stub="$work/stub"; mkdir -p "$stub"

BASE=1111111111111111111111111111111111111111
HEAD=2222222222222222222222222222222222222222

# gh stub. The PR is described by files under $GH_FIX:
#   diff            -- what `api repos/{owner}/{repo}/compare/<base>...<head>` prints with the diff
#                      media type (GH_DIFF_FAIL=1: print it, exit 1). Any other range is a 404,
#                      so a diff that is not taken between $GH_BASE and $GH_HEAD cannot be read;
#                      each compare endpoint is appended to $GH_API_LOG.
#   files/<sha>/<path> -- what `api repos/{owner}/{repo}/contents/<path>?ref=<sha>`
#                      returns; a missing file is a 404
# `pr view` prints what the wrapper's --jq would produce: the "<base> <head>" line
# (GH_VIEW_FAIL=1: the call fails).
# `pr merge` appends its argv to $GH_MERGE_LOG and succeeds
# (one `[arg]` per line, so each call starts with `[pr]`).
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    [ "${GH_VIEW_FAIL:-0}" = 1 ] && { echo "HTTP 500" >&2; exit 1; }
    echo "$GH_BASE $GH_HEAD"
    exit 0 ;;
  "pr merge")
    printf '[%s]\n' "$@" >>"$GH_MERGE_LOG"
    # GH_AUTO_CLEAN=1: refuse --auto the way GitHub does for a clean PR.
    if [ "${GH_AUTO_CLEAN:-0}" = 1 ] && [[ " $* " == *" --auto "* ]]; then
      echo "Pull request is in clean status" >&2; exit 1
    fi
    exit 0 ;;
esac
if [ "$1" = api ]; then
  case "$2" in
    repos/\{owner\}/\{repo\}/compare/*)
      echo "$2" >>"$GH_API_LOG"
      [ "$2" = "repos/{owner}/{repo}/compare/$GH_BASE...$GH_HEAD" ] \
        || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
      cat "$GH_FIX/diff"; [ "${GH_DIFF_FAIL:-0}" = 1 ] && { echo "HTTP 502" >&2; exit 1; }; exit 0 ;;
  esac
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

# The hunk starts at line 1 and its context includes the frontmatter, but the base and
# head frontmatter are equal, so it passes: the gate compares frontmatter, it does not
# go by where the hunk lies.
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

# the diff read fails after printing a harmless-looking partial diff, so only the
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

# ---- fixtures for the cases a review round added ----------------------------
cmd=dot/claude/commands/x.md
mkfix cmd_fm <<EOF
diff --git a/$cmd b/$cmd
index 1111111..2222222 100644
--- a/$cmd
+++ b/$cmd
@@ -2,3 +2,3 @@
 description: x
-allowed-tools: Read
+allowed-tools: Read, Bash
 ---
EOF
printf -- '---\ndescription: x\nallowed-tools: Read\n---\nbody\n' | put cmd_fm "$BASE" "$cmd"
printf -- '---\ndescription: x\nallowed-tools: Read, Bash\n---\nbody\n' | put cmd_fm "$HEAD" "$cmd"

sub=dot/claude/agents/sub/x.md
mkfix agent_sub <<EOF
diff --git a/$sub b/$sub
index 1111111..2222222 100644
--- a/$sub
+++ b/$sub
@@ -2,3 +2,3 @@
 name: x
-tools: Read
+tools: Read, Bash
 ---
EOF
printf -- '---\nname: x\ntools: Read\n---\nbody\n' | put agent_sub "$BASE" "$sub"
printf -- '---\nname: x\ntools: Read, Bash\n---\nbody\n' | put agent_sub "$HEAD" "$sub"

# Frontmatter that does not open on line 1 cannot be read, so an in-place change
# cannot be compared: two empty extractions must not count as equal.
mkfix blank_first <<EOF
diff --git a/$skill b/$skill
index 1111111..2222222 100644
--- a/$skill
+++ b/$skill
@@ -3,1 +3,1 @@
-allowed-tools: Read
+allowed-tools: Read, Bash
EOF
printf -- '\n---\nallowed-tools: Read\n---\nbody\n' | put blank_first "$BASE" "$skill"
printf -- '\n---\nallowed-tools: Read, Bash\n---\nbody\n' | put blank_first "$HEAD" "$skill"

# A symlink swapped in for a SKILL.md: both sides read as the same frontmatter, so only
# the mode (120000) can stop it.
mkfix symlink_mode <<EOF
diff --git a/$skill b/$skill
old mode 100644
new mode 120000
EOF
mkfix symlink_index <<EOF
diff --git a/$skill b/$skill
index 1111111..2222222 120000
--- a/$skill
+++ b/$skill
@@ -1,1 +1,1 @@
-a
+b
EOF
for n in symlink_mode symlink_index; do
  printf -- '---\nname: foo\n---\nbody\n' | put $n "$BASE" "$skill"
  printf -- '---\nname: foo\n---\nbody\n' | put $n "$HEAD" "$skill"
done

# A symlink whose path matches no frontmatter file name: only the mode can stop it. A link
# named like a skill directory exposes every SKILL.md under its target.
mkfix symlink_other <<'EOF2'
diff --git a/dot/claude/skills/newlink b/dot/claude/skills/newlink
new file mode 120000
index 0000000..2222222
--- /dev/null
+++ b/dot/claude/skills/newlink
@@ -0,0 +1 @@
+../../../elsewhere/skills
\ No newline at end of file
EOF2
mkfix symlink_other_idx <<'EOF2'
diff --git a/dot/claude/agents/dirlink b/dot/claude/agents/dirlink
index 1111111..2222222 120000
--- a/dot/claude/agents/dirlink
+++ b/dot/claude/agents/dirlink
@@ -1 +1 @@
-old
+new
EOF2

# A grant change first and a harmless file last: the first block must be flushed when the
# second header starts.
mkfix multi <<'EOF'
diff --git a/dot/claude/settings.json b/dot/claude/settings.json
index 1111111..2222222 100644
--- a/dot/claude/settings.json
+++ b/dot/claude/settings.json
@@ -3,1 +3,2 @@
     "allow": [
+      "Bash(curl *)",
diff --git a/README.md b/README.md
index 1111111..2222222 100644
--- a/README.md
+++ b/README.md
@@ -1 +1 @@
-a
+b
EOF

# 100% similarity renames and a copy have no ---/+++ lines: only rename/copy from/to.
mkfix rename_settings <<'EOF'
diff --git a/old.md b/dot/claude/settings.json
similarity index 100%
rename from old.md
rename to dot/claude/settings.json
EOF
mkfix rename_skill <<EOF
diff --git a/old.md b/$skill
similarity index 100%
rename from old.md
rename to $skill
EOF
mkfix copy_skill <<EOF
diff --git a/dot/claude/skills/bar/SKILL.md b/$skill
similarity index 100%
copy from dot/claude/skills/bar/SKILL.md
copy to $skill
EOF

# In place, but the head side of the file cannot be fetched.
mkfix head_404 <<EOF
diff --git a/$skill b/$skill
index 1111111..2222222 100644
--- a/$skill
+++ b/$skill
@@ -5,1 +5,1 @@
-old body
+new body
EOF
printf -- '---\nname: foo\n---\nold body\n' | put head_404 "$BASE" "$skill"

mkdiff_for() {  # mkdiff_for <fixture> <path>: a one-line change of <path>
  mkfix "$1" <<EOF
diff --git a/$2 b/$2
index 1111111..2222222 100644
--- a/$2
+++ b/$2
@@ -1 +1 @@
-a
+b
EOF
}
mkdiff_for settings_local dot/claude/settings.local.json
mkdiff_for settings_managed etc/managed-settings.json
mkdiff_for mysettings dot/mysettings.json

# A body of about 200KB: awk stops at the closing `---`, so a pipe into it would be hit by
# SIGPIPE.
mkfix big_body <<EOF
diff --git a/$skill b/$skill
index 1111111..2222222 100644
--- a/$skill
+++ b/$skill
@@ -9999,1 +9999,1 @@
-old
+new
EOF
for s in "$BASE:old" "$HEAD:new"; do
  { printf -- '---\nname: foo\nallowed-tools: Read\n---\n'
    yes 'body line xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' | head -n 6000
    echo "${s#*:}"; } | put big_body "${s%%:*}" "$skill"
done
[ "$(wc -c <"$fix/big_body/files/$BASE/$skill")" -gt 200000 ] || echo "FAIL: big_body fixture is too small"

mkfix deleted_skill <<EOF
diff --git a/$skill b/$skill
deleted file mode 100644
index 1111111..0000000
--- a/$skill
+++ /dev/null
@@ -1,4 +0,0 @@
----
-name: foo
----
-body
EOF
printf -- '---\nname: foo\n---\nbody\n' | put deleted_skill "$BASE" "$skill"

mkfix mode_settings <<'EOF'
diff --git a/dot/claude/settings.json b/dot/claude/settings.json
old mode 100644
new mode 100755
EOF
mkfix mode_readme <<'EOF'
diff --git a/README.md b/README.md
old mode 100644
new mode 100755
EOF
mkfix binary <<'EOF'
diff --git a/img.png b/img.png
index 1111111..2222222 100644
Binary files a/img.png and b/img.png differ
EOF
mkfix quoted <<'EOF'
diff --git a/a.md "b/sub/q\303\266.md"
similarity index 100%
rename from a.md
rename to "sub/q\303\266.md"
EOF
mkfix weird_line <<'EOF'
diff --git a/README.md b/README.md
index 1111111..2222222 100644
--- weird/README.md
+++ b/README.md
@@ -1 +1 @@
-a
+b
EOF
mkfix preamble <<'EOF'
some text before the first header
diff --git a/README.md b/README.md
index 1111111..2222222 100644
--- a/README.md
+++ b/README.md
@@ -1 +1 @@
-a
+b
EOF
# Removing a line `-- a/...` shows up in the diff as `--- a/...`, inside a hunk.
mkfix hunk_dash <<'EOF'
diff --git a/README.md b/README.md
index 1111111..2222222 100644
--- a/README.md
+++ b/README.md
@@ -1,2 +1,1 @@
-keep
--- a/dot/claude/settings.json
EOF

# ---- runner -----------------------------------------------------------------
run() {  # run <bindir> <fixture> -> sets rc, out (stderr), merge log in $work/merges
  # RUN_ENV (an array of VAR=value) adds to the stub's environment for one check.
  : >"$work/merges"; : >"$work/api"
  out="$(env GH_FIX="$fix/$2" GH_BASE="$BASE" GH_HEAD="$HEAD" GH_MERGE_LOG="$work/merges" \
    GH_API_LOG="$work/api" GH_DIFF_FAIL="$([ "$2" = diff_fail ] && echo 1 || echo 0)" "${RUN_ENV[@]}" \
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
  : >"$work/merges"; : >"$work/api"
  out="$(env GH_FIX="$fix/unrelated" GH_BASE="$BASE" GH_HEAD="$HEAD" GH_MERGE_LOG="$work/merges" GH_API_LOG="$work/api" \
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
check_cmd_fm()        { stopped "$1" cmd_fm "$cmd: frontmatter changed"; }
check_agent_sub()     { stopped "$1" agent_sub "$sub: frontmatter changed"; }
check_blank_first()   { stopped "$1" blank_first "frontmatter could not be compared"; }
check_symlink() {
  stopped "$1" symlink_mode "symlink (mode 120000)" && stopped "$1" symlink_index "symlink (mode 120000)"
}
check_symlink_other() {
  stopped "$1" symlink_other "dot/claude/skills/newlink" && stopped "$1" symlink_other_idx "dot/claude/agents/dirlink"
}
check_multi()         { stopped "$1" multi dot/claude/settings.json; }
check_rename_settings() { stopped "$1" rename_settings "dot/claude/settings.json: settings file"; }
check_rename_skill()  { stopped "$1" rename_skill "renamed / copied file with frontmatter"; }
check_copy_skill()    { stopped "$1" copy_skill "renamed / copied file with frontmatter"; }
check_head_404()      { stopped "$1" head_404 "frontmatter could not be compared"; }
check_settings_names() {
  stopped "$1" settings_local settings.local.json && stopped "$1" settings_managed managed-settings.json \
    && passed "$1" mysettings
}
check_big_body()      { passed "$1" big_body; }
check_deleted_skill() { stopped "$1" deleted_skill "$skill: deleted file with frontmatter"; }
# Stops, whatever the reason: for the mutants that remove every guard of one case.
check_deleted_skill_stops() { run "$1" deleted_skill; [ "$rc" -eq 5 ] && ! merged; }
check_mode_settings() { stopped "$1" mode_settings "dot/claude/settings.json: settings file"; }
check_mode_readme()   { passed "$1" mode_readme; }
check_binary()        { passed "$1" binary; }
check_quoted()        { stopped "$1" quoted "quoted path"; }
check_weird_line()    { stopped "$1" weird_line "unparseable diff line"; }
check_preamble()      { stopped "$1" preamble "text before the first file header"; }
check_hunk_dash()     { passed "$1" hunk_dash; }
check_view_fail() {
  RUN_ENV=(GH_VIEW_FAIL=1); stopped "$1" unrelated "could not read the base/head commits"
  local r=$?; RUN_ENV=(); return $r
}
check_view_null() {
  RUN_ENV=(GH_BASE=null GH_HEAD=null); stopped "$1" unrelated "unexpected base/head commits"
  local r=$?; RUN_ENV=(); return $r
}
# The diff is read between the SHAs that get pinned (the stub 404s any other range).
check_compare_range() {
  passed "$1" unrelated && [ "$(cat "$work/api")" = "repos/{owner}/{repo}/compare/$BASE...$HEAD" ]
}

# Control: the gh the wrapper reaches is the stub, and the merge call lands in
# its log (so the mutants below cannot reach a real merge).
if [ "$(PATH="$stub:$PATH" command -v gh)" = "$stub/gh" ] && check_unrelated "$bindir"; then
  echo "ok: control: gh resolves to the stub and the merge call is captured by it"
else echo "FAIL: control: gh=$(PATH="$stub:$PATH" command -v gh) rc=$rc out=$out"; fail=1; fi

for c in settings allowed_tools new_skill body_only unrelated diff_fail agent empty fallback_pin \
  cmd_fm agent_sub blank_first symlink symlink_other multi rename_settings rename_skill copy_skill head_404 \
  settings_names big_body deleted_skill mode_settings mode_readme binary quoted weird_line \
  preamble hunk_dash view_fail view_null compare_range; do
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
  elif ! bash -n "$d/gh-automerge" 2>/dev/null; then
    echo "FAIL: mutant '$name' does not parse; it would be caught for the wrong reason"; fail=1
  elif ! "$check" "$d"; then echo "ok: mutant '$name' is caught by $check"
  else echo "FAIL: mutant '$name' still passes $check"; fail=1; fi
}
mutant nosettings check_settings 's/^is_settings() { .*/is_settings() { false; }/'
mutant nofmfile check_allowed_tools 's/^  \[\[ "\${b,,}" == skill.md \]\] && return 0/  false/'
mutant nofmfile_agent check_agent 's#^  \[\[ "\$p" =~ (^|/)agents/\.+\\\.md\$ \]\] && return 0#  :#'
mutant nocompare check_allowed_tools 's/\[ "\$fb" = "\$fh" \] ||/true ||/'
# Extraction that finds nothing and still succeeds (two edits: awk's exit 3 on a file
# without frontmatter would otherwise stop it for another reason).
mutant nofmextract check_allowed_tools 's/^    NR == 1 { l = \$0;/    NR == 1 { exit 0; l = $0;/' \
  's/END { if (!open) exit 3; if (!closed) exit 2 }/END { }/'
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

# ---- mutants for the cases a review round added -----------------------------
# `claude/commands` without the dot (this repo's dot/claude/ layout) and agents in a subdirectory.
mutant nocmd_nodot check_cmd_fm 's#\.?claude/commands#.claude/commands#'
mutant noagent_subdir check_agent_sub 's#agents/\.+\\\.md#agents/[^/]+\\.md#'
# Frontmatter not found must not read as "equal". Not-found is stopped twice in awk (no
# line 1 opener, then never closed), so both go.
mutant nofm_failclosed check_blank_first 's/END { if (!open) exit 3; if (!closed) exit 2 }/END { }/'
mutant nosymlink check_symlink 's/reasons+=("symlink (mode 120000): \$f_hdr") ;;/: ;;/'
mutant nosymlink_other check_symlink_other 's/reasons+=("symlink (mode 120000): \$f_hdr") ;;/: ;;/'
mutant noflush_on_header check_multi 's/^    flush_file$/    :/'
mutant norename_to check_rename_settings 's/^    "rename to "\*) .*/    "rename to "*)       : ;;/'
mutant norename_to_skill check_rename_skill 's/^    "rename to "\*) .*/    "rename to "*)       : ;;/'
mutant nocopy_to check_copy_skill 's/^    "copy to "\*) .*/    "copy to "*)         : ;;/'
mutant nocompare_reason check_head_404 \
  's/^    reasons+=("\$new: frontmatter could not be compared/    true || reasons+=("$new: frontmatter could not be compared/'
mutant narrow_settings check_settings_names \
  's/^is_settings() { .*/is_settings() { [[ "${1##*\/}" =~ ^settings\\.json$ ]]; }/'
# The old shape, a pipe into awk, is hit by SIGPIPE once the body is larger than the pipe buffer.
mutant pipe_into_awk check_big_body "s/frontmatter <<<\"\\\$c\"/printf '%s' \"\\\$c\" | frontmatter/"
mutant nodeleted check_deleted_skill \
  's/^  if \[ "\$f_deleted" -eq 1 \] || \[ -z "\$new" \]; then/  if false; then/'
# A deleted file is stopped by the deleted branch, the path mismatch and the failing
# head-side fetch; only removing all three lets it merge.
mutant nodeleted_all check_deleted_skill_stops \
  's/^  if \[ "\$f_deleted" -eq 1 \] || \[ -z "\$new" \]; then/  if false; then/' \
  's/^  if \[ "\$f_renamed" -eq 1 \] || \[ "\$old" != "\$new" \]; then/  if false; then/' \
  's/^    reasons+=("\$new: frontmatter could not be compared/    true || reasons+=("$new: frontmatter could not be compared/'
mutant nohdr_recover check_mode_settings \
  's/^      \[ "\${rest:0:n} b\/\${rest:0:n}" = "\$rest" \] && old=/      false \&\& old=/'
mutant noquoted check_quoted 's/^  case "\$old\$new" in .*/  :/'
mutant nounparseable check_weird_line 's/^    "--- "\*|"+++ "\*) *reasons+=.*/    "--- "*|"+++ "*)     : ;;/'
mutant nopreamble check_preamble 's/^  \[ -n "\$f_hdr" \] || { reasons+=.*/  :/'
mutant nohunk check_hunk_dash 's/^  \[ "\$in_hunk" -eq 1 \] && continue/  :/'
mutant noviewfail check_view_fail 's/|| gate_refuse "could not read the base\/head commits/|| true "could not read the base\/head commits/'
mutant nooid check_view_null 's/^\[\[ "\${base_oid:-}" =~ .* \\$/true \\/'
mutant twodot_compare check_compare_range 's#compare/\$base_oid\.\.\.\$head_oid#compare/$base_oid..$head_oid#'
mutant swapped_compare check_compare_range 's#compare/\$base_oid\.\.\.\$head_oid#compare/$head_oid...$base_oid#'

exit "$fail"
