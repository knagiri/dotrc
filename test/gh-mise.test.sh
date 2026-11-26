#!/usr/bin/env bash
# Tests for gh_mise_main_root (bin/lib/gh-mise.sh): it resolves the MAIN working
# tree from anywhere in a checkout, so `gh_mise_use "$(gh_mise_main_root)"`
# keeps a linked worktree's mise config out of gh's environment. The wrapper
# plumbing of gh_mise itself is covered by test/gh-wrappers.test.sh.
# No test framework; run with bash.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
lib="$here/../bin/lib/gh-mise.sh"
fail=0

tmp="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"

# The dotrc layout: linked worktrees live inside the main checkout, under
# .worktrees/<name>, so mise walking up from a worktree also passes the main
# checkout -- which is why the worktree's own config must not be read at all.
main="$tmp/main"
git init -q -b main "$main"
git -C "$main" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
mkdir -p "$main/sub"
git -C "$main" worktree add -q -b wt "$main/.worktrees/wt" 2>/dev/null
wt="$main/.worktrees/wt"
mkdir -p "$wt/sub"

# Runs gh_mise_main_root in a fresh shell from <cwd>; prints its output, keeps its rc.
main_root() {  # main_root <lib> <cwd> [<dir arg>]
  # shellcheck disable=SC1090  # the lib or a mutant of it
  ( cd "$2" && . "$1" && gh_mise_main_root "${@:3}" )
}

check() {  # check <desc> <expected output> <lib> <cwd> [<dir arg>]
  local out rc
  out="$(main_root "${@:3}")"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "$2" ]; then echo "ok: $1"
  else echo "FAIL: $1 (rc=$rc out=$out)"; fail=1; fi
}
check "main root from the main checkout" "$main" "$lib" "$main"
check "main root from a subdirectory of the main checkout" "$main" "$lib" "$main/sub"
check "main root from a linked worktree" "$main" "$lib" "$wt"
check "main root from a subdirectory of a linked worktree" "$main" "$lib" "$wt/sub"
check "main root of an explicit <dir> argument" "$main" "$lib" "$tmp" "$wt/sub"

refuses() {  # refuses <desc> <lib> <cwd> [<dir arg>]
  local out rc
  out="$(main_root "${@:2}" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then echo "ok: $1"
  else echo "FAIL: $1 (rc=$rc out=$out)"; fail=1; fi
}
mkdir -p "$tmp/plain"
refuses "outside a checkout it fails with no output" "$lib" "$tmp/plain"

# A submodule's common dir is <super>/.git/modules/<name>, whose parent is no
# working tree; resolving it to a directory there would be wrong.
sub_src="$tmp/subsrc"
git init -q -b main "$sub_src"
git -C "$sub_src" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$main" -c protocol.file.allow=always submodule add -q "$sub_src" mod 2>/dev/null
if [ -d "$main/mod" ] && [ -f "$main/mod/.git" ]; then
  refuses "inside a submodule it fails rather than naming .git/modules" "$lib" "$main/mod"
else echo "FAIL: could not set up the submodule fixture"; fail=1; fi

# A bare repo lying inside another checkout: its common dir's parent IS in a
# working tree, just not as that tree's toplevel. Only the `top = main` check
# refuses it (the submodule above is already refused by show-toplevel failing).
git init -q --bare "$main/sub/bare.git"
refuses "a bare repo nested in a checkout fails rather than naming its parent" "$lib" "$main/sub/bare.git"

# Discrimination (evidence-over-guesswork §4). gh_mise_main_root is a new
# function, so its checks are mutated one at a time; `cmp` keeps a sed that
# matched nothing from making a mutant a no-op.
mutant() {  # mutant <name> <sed expression> -> path of the mutated lib
  local m="$tmp/mutant-$1.sh"
  sed "$2" "$lib" >"$m"
  if cmp -s "$lib" "$m"; then
    echo "FAIL: mutant '$1' is identical to gh-mise.sh; the check is a no-op" >&2; fail=1
  fi
  printf '%s\n' "$m"
}
# Resolving the toplevel instead of the common dir yields the worktree itself.
m_toplevel="$(mutant toplevel '/^gh_mise_main_root()/,/^}/s|--path-format=absolute --git-common-dir|--path-format=absolute --git-dir|')"
out="$(main_root "$m_toplevel" "$wt/sub")"
[ "$out" != "$main" ] \
  && echo "ok: mutant 'toplevel' resolves a worktree to itself (the linked-worktree case is discriminating)" \
  || { echo "FAIL: mutant 'toplevel' still resolved $out"; fail=1; }
m_notop="$(mutant notop '/^gh_mise_main_root()/,/^}/s|\[ "\$top" = "\$main" \] \|\| return 1|:|')"
if out="$(main_root "$m_notop" "$main/sub/bare.git" 2>/dev/null)" && [ "$out" = "$main/sub" ]; then
  echo "ok: mutant 'notop' names the bare repo's parent (the nested-bare case is discriminating)"
else echo "FAIL: mutant 'notop' still refused the nested bare repo (out=$out)"; fail=1; fi

# With the real mise: a GH_TOKEN planted in the worktree's tracked mise.toml
# reaches gh when gh_mise runs in the worktree (gh_mise_repo_root, the existing
# behaviour) and does not when it runs in gh_mise_main_root. Two main-checkout
# variants cover both token sources: with mise.gh.local.toml gh gets its PAT;
# without it gh gets no GH_TOKEN and so falls to hosts.yml.
# Hermetic as in gh-wrappers.test.sh: trust via MISE_TRUSTED_CONFIG_PATHS, no
# global config, the config walk stops at $tmp, ambient MISE_ENV/GH_* removed.
realmise="$(command -v mise 2>/dev/null || true)"
if [ -z "$realmise" ]; then
  echo "skip: no real mise on PATH; the token-resolution cases need it"
else
  stub="$tmp/stub"; mkdir -p "$stub" "$tmp/cfg"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${GH_TOKEN:-}" >"$GH_TOKEN_FILE"\n' >"$stub/gh"
  chmod +x "$stub/gh"
  printf '[env]\nGH_TOKEN = "tok-from-worktree"\n' >"$wt/mise.toml"
  token_via() {  # token_via <lib> <resolver function> -> the GH_TOKEN gh saw
    : >"$tmp/token"
    ( cd "$wt/sub" && env -u MISE_ENV -u GH_TOKEN -u GITHUB_TOKEN \
        MISE_TRUSTED_CONFIG_PATHS="$tmp" MISE_CEILING_PATHS="$tmp" \
        MISE_GLOBAL_CONFIG_FILE="$tmp/none.toml" MISE_CONFIG_DIR="$tmp/cfg" \
        GH_TOKEN_FILE="$tmp/token" PATH="$stub:$PATH" \
        bash -c '. "$1" && gh_mise_use "$("$2")" && gh_mise pr view 1' _ "$1" "$2" ) >/dev/null 2>&1
    cat "$tmp/token"
  }

  # Control: the existing worktree-anchored resolution does pick up the plant,
  # so its absence below is not just a config mise never read.
  t="$(token_via "$lib" gh_mise_repo_root)"
  [ "$t" = tok-from-worktree ] \
    && echo "ok: control: anchored at the worktree, mise hands gh the worktree's GH_TOKEN" \
    || { echo "FAIL: control token=$t"; fail=1; }

  printf '[env]\nGH_TOKEN = "tok-personal"\n' >"$main/mise.gh.local.toml"
  t="$(token_via "$lib" gh_mise_main_root)"
  [ "$t" = tok-personal ] \
    && echo "ok: anchored at the main root, gh gets the main checkout's personal PAT, not the worktree's" \
    || { echo "FAIL: main root with mise.gh.local.toml token=$t"; fail=1; }

  rm "$main/mise.gh.local.toml"
  t="$(token_via "$lib" gh_mise_main_root)"
  [ -z "$t" ] \
    && echo "ok: anchored at the main root with no mise.gh.local.toml, gh gets no GH_TOKEN (hosts.yml)" \
    || { echo "FAIL: main root without mise.gh.local.toml token=$t"; fail=1; }

  t="$(token_via "$m_toplevel" gh_mise_main_root)"
  [ "$t" = tok-from-worktree ] \
    && echo "ok: mutant 'toplevel' lets the worktree's GH_TOKEN through (the case above is discriminating)" \
    || { echo "FAIL: mutant 'toplevel' token=$t"; fail=1; }
fi

exit "$fail"
