#!/usr/bin/env bash
# Self-test of the commit guard (.githooks/pre-commit), the message guard (.githooks/commit-msg) and `just push`
# (tools/push.sh), in both modes, on a synthetic repository under TMPDIR: never this checkout's index, refs or remotes.
#   - The synthetic upstream commit holds an upstream-style (unformatted) Julia file under the package's name
#     (src/Up.jl, which the family renames to src/UpX.jl), a text file with an e-mail address in it (upstream's public
#     text), a top-level data/ entry and an upstream tag; the family's commits add this tree's tooling and an
#     UPSTREAM.toml naming that commit (the fork mode), or carry no UPSTREAM.toml (the family mode).
#   - The guards read a throwaway wiki: copies of the named wiki's master scan and its lists, with one extra private
#     row in refs.tsv, so no scenario depends on a word of the real lists; every refused literal is joined from two
#     halves at run time, so this file passes the scan it tests.
#   - Each refused scenario must print the message of the check it exercises, so a refusal by another check is not
#     counted as a pass.
set -u
src=$(git rev-parse --show-toplevel) || exit 2
real=${DAIDALOS_WIKI:-$(git -C "$src" config daidalos.wiki || true)}
[ -n "$real" ] && [ -d "$real/tools/split" ] || {
  echo "guard-selftest: no wiki named; run just hooks-install <path of the wiki's checkout>" >&2
  exit 2
}
tt=$(mktemp -d "${TMPDIR:-/tmp}/family-guard-selftest-XXXXXX") || exit 2
trap 'rm -rf -- "$tt"' EXIT
out=$tt/out

# the throwaway wiki and the refused literals, each joined at run time
fake=$tt/wiki
mkdir -p "$fake/tools/split" "$fake/tools/mirrors"
cp "$real"/tools/split/confidential{_scan.py,-words.txt,-allow.txt,-allow-fork.txt,-identities.txt} "$fake/tools/split/" || exit 2
private=zork
private+=probecode
{
  cat "$real/tools/mirrors/refs.tsv"
  printf '%s\t%s\t%s\t%s\t%s\n' "$private" "https://example.invalid/x.git" "$(printf '0%.0s' {1..40})" "guard-selftest" private
} > "$fake/tools/mirrors/refs.tsv"
mail=probe
mail+=@example.org
export DAIDALOS_WIKI=$fake

fails=0
report() { # report <name> <expected-exit> <got> [<required-substring>]
  if [ "$3" != "$2" ]; then
    echo "FAIL  $1 (exit $3, wanted $2)"
    sed 's/^/      /' "$out"
    fails=$((fails + 1))
  elif [ -n "${4:-}" ] && ! grep -qF -- "$4" "$out"; then
    echo "FAIL  $1 (exit $3 as wanted, but not by the check that prints '$4')"
    sed 's/^/      /' "$out"
    fails=$((fails + 1))
  else
    echo "PASS  $1"
  fi
}
g() { git -C "$repo" -c core.hooksPath=/dev/null "$@"; }
guard() { # guard <name> <expected-exit> [<required-substring>]: the guard on the repository's index as staged
  (cd "$repo" && bash .githooks/pre-commit) > "$out" 2>&1
  report "$1" "$2" "$?" "${3:-}"
}
message() { # message <name> <expected-exit> <text> [<required-substring>]: the message guard on that text
  printf '%s\n' "$3" > "$tt/msg"
  (cd "$repo" && bash .githooks/commit-msg "$tt/msg") > "$out" 2>&1
  report "$1" "$2" "$?" "${4:-}"
}
put() { mkdir -p "$repo/$(dirname "$1")" && printf '%s\n' "$2" > "$repo/$1" && g add -- "$1"; }
reset() { g reset -q --hard && g clean -qfdx; }
# a repository holding this tree's tooling (and the format/ environment the guard's formatter runs from)
tooling() {
  mkdir -p "$repo/tools/checks"
  cp -R "$src/.githooks" "$src/format" "$src/.JuliaFormatter.toml" "$repo/" &&
    cp "$src/tools/push.sh" "$repo/tools/" && cp "$src/tools/checks/confidential_scan.py" "$repo/tools/checks/" &&
    g add .githooks format .JuliaFormatter.toml tools
}

# ---- the fork mode
repo=$tt/fork
git init -q -b main "$repo" || exit 2
mkdir -p "$repo/src" "$repo/data"
printf 'module Up\nf(x)=x+1\nend\n' > "$repo/src/Up.jl"
printf 'upstream data\n' > "$repo/data/a.txt"
printf 'Contact: %s\n' "$mail" > "$repo/data/contact.txt"
printf 'name = "Up"\n' > "$repo/Project.toml"
g add -A && g commit -qm "upstream: the release" && g tag -a upstream/v1.0.0 -m "upstream v1.0.0" || exit 2
upc=$(g rev-parse HEAD)
upstream_toml="[upstream]
name = \"Up\"
commit = \"$upc\"

[package]
name = \"UpX\""
tooling || exit 2
put UPSTREAM.toml "$upstream_toml"
g mv src/Up.jl src/UpX.jl
guard "fork: the tooling, UPSTREAM.toml and upstream's file renamed unchanged pass" 0
g commit -qm "family: the tooling and the rename" || exit 2

put src/UpX.jl "$(printf 'module UpX\nf(x)=x+2\nend')"
guard "fork: an upstream file changed in upstream's style passes the formatter" 0
reset
put tools/x.jl "f(x)=x+1"
guard "fork: the family's unformatted Julia is refused" 1 "differences in the staged version"
reset
put tools/contact.txt "$mail"
guard "fork: an address in a family file is refused" 1 "the confidential scan (policy fork)"
reset
put data/contact.txt "$(printf 'Contact: %s\nMore.' "$mail")"
guard "fork: an upstream file changed is scanned whole, its upstream address included" 1 "the confidential scan (policy fork)"
reset
put tools/notes.md "built on $private"
guard "fork: a private code's name is refused" 1 "the confidential scan (policy fork)"
reset
put tools/a.log "debris"
guard "fork: the family's debris is refused" 1 "debris, not a source file"
reset
put data/b.txt "more data"
guard "fork: a file under upstream's top-level entry passes" 0
reset
put junk/a.txt "x"
guard "fork: a new top-level entry is refused" 1 "new top-level entry 'junk'"
reset
put tools/checks/confidential_scan.py "import sys; sys.exit(0)"
put tools/contact.txt "$mail"
guard "fork: a weakened scan copy is refused" 1 "differs from the wiki's master"
reset
g rm -q tools/checks/confidential_scan.py && mkdir -p "$repo/tools/checks" && ln -s "$fake/tools/split/confidential_scan.py" "$repo/tools/checks/confidential_scan.py" &&
  g add tools/checks/confidential_scan.py
guard "fork: a scan copy linked to the master outside the tree is refused" 1 "which leaves the staged tree"
reset
put UPSTREAM.toml "${upstream_toml/$upc/$(printf 'a%.0s' {1..40})}"
guard "fork: UPSTREAM.toml naming a commit this clone lacks is refused" 1 "is not in this clone"
reset
put tools/x.txt "x"
(cd "$repo" && DAIDALOS_WIKI=$tt/none bash .githooks/pre-commit) > "$out" 2>&1
report "fork: no wiki refuses" 1 "$?" "set DAIDALOS_WIKI"
reset
message "fork: a clean message with the agent trailer passes" 0 "$(printf 'A change\n\nCo-Authored-By: Claude Opus 5.5 <noreply@%s>' anthropic.com)"
message "fork: an address in a message is refused" 1 "Contact $mail" "the confidential scan (policy fork) refused the message"

# just push in the fork: upstream's history (an address in its file) is excluded through the upstream/* tag; a family
# commit carrying an address is refused and leaves both remotes unchanged
for b in origin gitea; do git init -q --bare "$tt/$b.git" && g remote add "$b" "$tt/$b.git"; done
push() { (cd "$repo" && bash tools/push.sh "$1") > "$out" 2>&1; }
push main
report "fork push: the family's commits over upstream's history publish" 0 "$?" "push: refs/heads/main at"
[ "$(git -C "$tt/origin.git" rev-parse main)" = "$(g rev-parse main)" ] || {
  echo "FAIL  fork push: origin's main is not the pushed commit"
  fails=$((fails + 1))
}
put tools/contact.txt "$mail" && g commit -qm "probe: an address committed past the guard"
before=$(git -C "$tt/origin.git" rev-parse main; git -C "$tt/gitea.git" rev-parse main)
push main
report "fork push: a commit carrying an address is refused" 1 "$?" "the outgoing scan (policy fork)"
[ "$(git -C "$tt/origin.git" rev-parse main; git -C "$tt/gitea.git" rev-parse main)" = "$before" ] || {
  echo "FAIL  fork push: a remote changed on a refused push"
  fails=$((fails + 1))
}

# ---- the family mode: no UPSTREAM.toml, every path the family's, policy library
repo=$tt/family
git init -q -b main "$repo" || exit 2
tooling || exit 2
guard "family: the tooling alone passes" 0
g commit -qm "family: the tooling" || exit 2
put src/x.jl "f(x)=x+1"
guard "family: unformatted Julia anywhere is refused" 1 "differences in the staged version"
reset
put src/x.jl "$(printf 'f(x) = x + 1')"
guard "family: formatted Julia passes" 0
reset
put README.md "$mail"
guard "family: an address is refused" 1 "the confidential scan (policy library)"
reset
message "family: an address in a message is refused" 1 "Contact $mail" "the confidential scan (policy library) refused the message"

echo
if [ "$fails" -eq 0 ]; then echo "guard-selftest: all scenarios behave"; else echo "guard-selftest: $fails scenario(s) failed"; fi
[ "$fails" -eq 0 ]
