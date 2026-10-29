#!/usr/bin/env bash
# Static checks on how dot/claude/skills/ meets dot/claude/settings.json.
#
# (a) A skill's `allowed-tools` must not list bare `Bash` or `Edit`. Allowing
#     Skill(<name>) pre-approves everything in that list for the turn, so a bare
#     entry turns into "any command / any edit, no prompt".
# (b) Every skill directory must have a Skill(<name>) allow rule (or sit on the
#     exclusion list below), so an unattended delegate does not freeze on an
#     approval prompt; and every Skill(<name>) rule must name a skill that
#     exists, so dead rules do not pile up.
#
# The checks run against the real tree, then against fixtures generated here
# that reproduce each failure, to show the checks actually discriminate. No
# test framework; run with bash. SKILLS_DIR / SETTINGS_JSON override the real
# tree. Part of the discrimination fixtures is derived from the override targets
# too, and assumes the current tree's shape (they sed pr-review-loop's
# allowed-tools line and drop Skill(implement-and-review)), so pointing the
# override at a different revision can produce FAILs there.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
skills_dir="${SKILLS_DIR:-$here/../dot/claude/skills}"
settings="${SETTINGS_JSON:-$here/../dot/claude/settings.json}"
fail=0

tmp="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$tmp"' EXIT

# Skills deliberately left out of the Skill(...) allowlist, each with a reason.
# No skill is excluded at present. check_skill_allow also fails if an excluded
# skill gains a Skill(...) allow, or if the name no longer exists.
excluded_skills=""

# Prints the allowed-tools entries of a SKILL.md frontmatter, one per line.
# Accepts the inline form (`a, b c`, optionally `[a, b]`) and the YAML block
# list form (`- a` lines). Parenthesised arguments are kept attached to their
# tool name, so `Bash(git status *)` stays one entry.
allowed_tools() {  # allowed_tools <SKILL.md>
  awk '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    inlist && /^[[:space:]]*-[[:space:]]*/ { sub(/^[[:space:]]*-[[:space:]]*/, ""); print; next }
    { inlist = 0 }
    /^allowed-tools:/ {
      sub(/^allowed-tools:[[:space:]]*/, "")
      if ($0 == "") inlist = 1; else print
    }
  ' "$1" | awk '
    {
      # Split on commas, whitespace and flow-sequence brackets outside parens.
      depth = 0; tok = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "(") depth++
        if (c == ")" && depth > 0) depth--
        if (depth == 0 && (c == "," || c == " " || c == "\t" || c == "[" || c == "]")) {
          if (tok != "") print tok; tok = ""
        } else tok = tok c
      }
      if (tok != "") print tok
    }
  ' | tr -d "\"'"
}

# (a) Prints each SKILL.md whose allowed-tools contain a bare Bash or Edit.
# Bare Write is deliberately not checked: my-create-pr may write a temp file
# under $CLAUDE_JOB_DIR (only as the fallback when textlint lacks --stdin). That
# directory is decided at run time, so a literal Edit(<path>) cannot name it and
# there is no narrower form to require instead.
# Whole-tool forms count as bare: `Bash(*)` is documented as equivalent to
# `Bash` (https://code.claude.com/docs/en/permissions); `Bash()`, `Bash(:*)`
# and `Edit(*)` / `Edit(**)` are treated the same as conservative whole-tool
# grants (not documented as equivalent for Edit, but as broad in effect).
check_bare_tools() {  # check_bare_tools <skills dir>
  local f bare_re='(Bash|Edit)(\((\*|\*\*|:\*)?\))?'
  for f in "$1"/*/SKILL.md; do
    [ -f "$f" ] || continue
    if allowed_tools "$f" | grep -qxE "$bare_re"; then
      echo "$f: allowed-tools has bare $(allowed_tools "$f" | grep -xE "$bare_re" | paste -sd, -)"
    fi
  done
}

# (b) Prints skills lacking a Skill(...) allow rule, and Skill(...) rules
# naming no skill. Plugin skills (`plugin:skill`) live elsewhere and are
# skipped. Directories without SKILL.md are not skills.
check_skill_allow() {  # check_skill_allow <skills dir> <settings.json>
  local allowed d name
  allowed="$(jq -r '.permissions.allow[] | select(startswith("Skill(")) | ltrimstr("Skill(") | rtrimstr(")")' "$2")" || {
    echo "$2: cannot read .permissions.allow"; return
  }
  for name in $excluded_skills; do
    [ -f "$1/$name/SKILL.md" ] || echo "stale exclusion: $name has no $1/$name/SKILL.md"
    printf '%s\n' "$allowed" | grep -qxF "$name" && echo "excluded but allowed: Skill($name)"
  done
  for d in "$1"/*/; do
    [ -f "$d/SKILL.md" ] || continue
    name="$(basename "$d")"
    printf '%s\n' $excluded_skills | grep -qxF "$name" && continue
    printf '%s\n' "$allowed" | grep -qxF "$name" || echo "missing allow: Skill($name)"
  done
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in *:*) continue ;; esac
    [ -f "$1/$name/SKILL.md" ] || echo "dead allow: Skill($name) has no $1/$name/SKILL.md"
  done <<<"$allowed"
}

# --- Real tree -----------------------------------------------------------------

out="$(check_bare_tools "$skills_dir")"
if [ -z "$out" ]; then echo "ok: no skill lists bare Bash/Edit in allowed-tools"
else echo "FAIL: bare tools in allowed-tools:"; printf '%s\n' "$out"; fail=1; fi

out="$(check_skill_allow "$skills_dir" "$settings")"
if [ -z "$out" ]; then echo "ok: Skill(...) allow rules match the skills directory"
else echo "FAIL: Skill(...) allow rules out of sync:"; printf '%s\n' "$out"; fail=1; fi

# --- Discrimination: fixtures reproducing each failure --------------------------

mkskill() {  # mkskill <dir> <name> <frontmatter body...>
  local dir="$1/$2"; shift 2
  mkdir -p "$dir"
  { echo "---"; printf '%s\n' "$@"; echo "---"; echo; echo "# body"; } >"$dir/SKILL.md"
}

fx="$tmp/a"
mkskill "$fx" ok-inline "name: ok-inline" "allowed-tools: Bash(git status *), Read, Edit(docs/**)"
mkskill "$fx" ok-none "name: ok-none"
mkskill "$fx" ok-write "name: ok-write" "allowed-tools: Read, Write"
out="$(check_bare_tools "$fx")"
if [ -z "$out" ]; then echo "ok: parenthesised Bash/Edit, Write and no allowed-tools pass"
else echo "FAIL: false positive: $out"; fail=1; fi

for form in "allowed-tools: Bash, Read" "allowed-tools: Read Bash" "allowed-tools: [Read, \"Edit\"]" \
  "allowed-tools: Bash(*), Read" "allowed-tools: Read, Edit(**)" "allowed-tools: Read, Bash()"; do
  rm -rf "$fx"; mkskill "$fx" bad "name: bad" "$form"
  out="$(check_bare_tools "$fx")"
  case "$out" in *bad/SKILL.md*) echo "ok: catches '$form'" ;;
    *) echo "FAIL: missed '$form'"; fail=1 ;; esac
done

rm -rf "$fx"; mkskill "$fx" bad "name: bad" "allowed-tools:" "  - Read" "  - Bash" "description: x"
out="$(check_bare_tools "$fx")"
case "$out" in *bad/SKILL.md*) echo "ok: catches bare Bash in a YAML block list" ;;
  *) echo "FAIL: missed bare Bash in a YAML block list"; fail=1 ;; esac

# The old bare-Bash shape of pr-review-loop, applied to a copy of the real tree.
rm -rf "$fx"; cp -R "$skills_dir" "$fx"
sed -i 's/^allowed-tools: Read, Grep, Glob, Task$/allowed-tools: Bash, Read, Grep, Glob, Task/' "$fx/pr-review-loop/SKILL.md"
out="$(check_bare_tools "$fx")"
if ! grep -qx 'allowed-tools: Bash, Read, Grep, Glob, Task' "$fx/pr-review-loop/SKILL.md"; then
  echo "FAIL: could not reproduce the bare-Bash allowed-tools (sed did not apply)"; fail=1
else case "$out" in *pr-review-loop/SKILL.md*) echo "ok: catches the bare-Bash pr-review-loop allowed-tools" ;;
  *) echo "FAIL: missed the bare-Bash pr-review-loop allowed-tools"; fail=1 ;; esac; fi

jq '.permissions.allow -= ["Skill(implement-and-review)"]' "$settings" >"$tmp/settings.json"
out="$(check_skill_allow "$skills_dir" "$tmp/settings.json")"
case "$out" in *"missing allow: Skill(implement-and-review)"*) echo "ok: catches a missing Skill(implement-and-review) allow" ;;
  *) echo "FAIL: missed a missing Skill(implement-and-review) allow"; fail=1 ;; esac

# Exclude a real skill whose Skill(...) allow is present (added if missing).
jq '.permissions.allow |= (if index("Skill(my-commit)") then . else . + ["Skill(my-commit)"] end)' "$settings" >"$tmp/settings.json"
out="$(excluded_skills="my-commit" check_skill_allow "$skills_dir" "$tmp/settings.json")"
case "$out" in *"excluded but allowed: Skill(my-commit)"*) echo "ok: catches an excluded skill that gains a Skill(...) allow" ;;
  *) echo "FAIL: missed an excluded skill that gains a Skill(...) allow"; fail=1 ;; esac

# An excluded skill must not be reported as missing an allow even when its
# Skill(...) allow is absent (guards the `&& continue` exclusion branch).
jq '.permissions.allow -= ["Skill(my-commit)"]' "$settings" >"$tmp/settings.json"
out="$(excluded_skills="my-commit" check_skill_allow "$skills_dir" "$tmp/settings.json")"
if [ -z "$out" ]; then echo "ok: an excluded skill is not reported as missing an allow"
else echo "FAIL: excluded skill reported: $out"; fail=1; fi

out="$(excluded_skills="no-such-skill" check_skill_allow "$skills_dir" "$settings")"
case "$out" in *"stale exclusion: no-such-skill"*) echo "ok: catches a stale exclusion" ;;
  *) echo "FAIL: missed a stale exclusion"; fail=1 ;; esac

jq '.permissions.allow += ["Skill(no-such-skill)", "Skill(some-plugin:skill)"]' "$settings" >"$tmp/settings.json"
out="$(check_skill_allow "$skills_dir" "$tmp/settings.json")"
case "$out" in *"dead allow: Skill(no-such-skill)"*) echo "ok: catches a dead Skill(...) allow" ;;
  *) echo "FAIL: missed a dead Skill(...) allow"; fail=1 ;; esac
case "$out" in *some-plugin*) echo "FAIL: plugin skill flagged as dead"; fail=1 ;;
  *) echo "ok: plugin Skill(...) allow is not flagged" ;; esac

exit "$fail"
