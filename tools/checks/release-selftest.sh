#!/usr/bin/env bash
# Self-test of `just release` (tools/release.sh) on scratch remotes: a throwaway clone of this repository under TMPDIR
# carrying this tree's justfile and tools/, bare repositories for the package's origin and gitea and for the
# registry's, a throwaway depot ahead of the default one (so LocalRegistry loads from the default) with a registry name
# of its own (so no registration can reach the family's registry), the wiki's scan lists, and a fake `just` first on
# PATH that records each test call with the HEAD it runs at, fails the tests when FAKE_TIER_FAIL=1, commits to the
# checkout during the tests when FAKE_TIER_MOVE=1, tags the checkout's HEAD~1 as $FAKE_TIER_TAG during the tests when
# that is set, and hands every other recipe (push, _jl-hostq _jl-register) to the real one, so each registration is a
# hostq job on this Mac. Nothing leaves this Mac; the checkout's own tags and remotes are never touched.
# RELEASE_SELFTEST_STOP_AFTER=<run> stops after that run; RELEASE_SELFTEST_SCRIPT=<file> tests that file as
# tools/release.sh (a mutant).
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2
real_just=$(command -v just) || {
  echo "release-selftest: no just on PATH" >&2
  exit 2
}
wiki=${DAIDALOS_WIKI:-$(git config daidalos.wiki || true)}
[ -n "$wiki" ] && [ -d "$wiki/tools/split" ] || {
  echo "release-selftest: no wiki named; run just hooks-install <path of the wiki's checkout>" >&2
  exit 2
}
export DAIDALOS_WIKI=$wiki
script=${RELEASE_SELFTEST_SCRIPT:-tools/release.sh}
stop_after=${RELEASE_SELFTEST_STOP_AFTER:-}

tt=$(mktemp -d "${TMPDIR:-/tmp}/family-release-selftest-XXXXXX") || exit 2
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
  chmod -R u+w "$tt" 2> /dev/null
  rm -rf -- "$tt"
}
trap cleanup EXIT
pkg=$tt/pkg depot=$tt/depot record=$tt/tiers out=$tt/out
name=ReleaseSelftest$$
clone=$depot/registries/$name
fails=0
nocheck() { git -C "$1" -c core.hooksPath=/dev/null "${@:2}"; }

# the fixture: this tree's release tooling committed on main of a throwaway clone, published to the scratch bares
for b in origin gitea registry-origin registry-gitea; do git init -q --bare "$tt/$b.git" || exit 2; done
git clone -q --no-local --no-tags "$(pwd)" "$pkg" && nocheck "$pkg" checkout -q -B main || exit 2
cp justfile "$pkg/justfile" && rm -rf "$pkg/tools" || exit 2
git ls-files -z --cached --others --exclude-standard tools | while IFS= read -r -d '' f; do
  mkdir -p "$pkg/$(dirname "$f")" && cp -p "$f" "$pkg/$f"
done
cp "$script" "$pkg/tools/release.sh" || exit 2
# the fixture's own first version 0.1.0, whatever version this tree carries, so the runs below never move
# (the version's value replaced, so a CRLF line keeps its carriage return, as upstream's DoubleFloats writes it)
sed -i '' 's/^version = "[^"]*"/version = "0.1.0"/' "$pkg/Project.toml" || exit 2
pkgname=$(tr -d '\r' < "$pkg/Project.toml" | sed -n 's/^name = "\(.*\)"$/\1/p')
entry=${pkgname:0:1}/$pkgname
# --allow-empty: from a clean committed checkout the copies change nothing, and the fixture's commit is still made
nocheck "$pkg" add -A && nocheck "$pkg" commit -q --allow-empty -m "probe: the release tooling under test" || exit 2
git -C "$pkg" remote set-url origin "$tt/origin.git" && git -C "$pkg" remote add gitea "$tt/gitea.git" || exit 2
publish() { git -C "$pkg" push -q origin main && git -C "$pkg" push -q gitea main; }
publish || exit 2

mkdir -p "$tt/bin"
cat > "$tt/bin/just" << EOF
#!/usr/bin/env bash
# the self-test's just: the tests recorded with the HEAD they run at, failed or moving the checkout on request
if [ "\${1:-}" = _jl-hostq ] && [ "\${2:-}" = test ]; then
  echo "\$2 \$(git rev-parse HEAD)" >> "$record"
  [ "\${FAKE_TIER_FAIL:-0}" = 1 ] && exit 1
  if [ "\${FAKE_TIER_MOVE:-0}" = 1 ]; then
    git -C "$pkg" -c core.hooksPath=/dev/null commit -q --allow-empty -m "probe: the checkout moved while the tests ran"
  fi
  if [ -n "\${FAKE_TIER_TAG:-}" ]; then
    git -C "$pkg" -c core.hooksPath=/dev/null tag -a "\$FAKE_TIER_TAG" -m "probe: a tag made while the tests ran" HEAD~1
  fi
  exit 0
fi
exec "$real_just" "\$@"
EOF
chmod +x "$tt/bin/just"
touch "$record"

release() {
  (cd "$pkg" && PATH="$tt/bin:$PATH" DAIDALOS_REGISTRY_GITHUB="${REGISTRY_GITHUB-$tt/registry-origin.git}" \
    DAIDALOS_REGISTRY_GITEA="$tt/registry-gitea.git" DAIDALOS_REGISTRY_NAME="$name" DAIDALOS_PKG_DEPOT="$depot" \
    bash tools/release.sh "$1") > "$out" 2>&1
}
bump() {
  sed -i '' "s/^version = \"[^\"]*\"/version = \"$1\"/" "$pkg/Project.toml" &&
    nocheck "$pkg" commit -q -am "probe: v$1" && publish
}
refs() { for b in origin gitea registry-origin registry-gitea; do git -C "$tt/$b.git" for-each-ref; done; }
tiers() { wc -l < "$record" | tr -d ' '; }
# "tag <commit>" for an annotated tag on that bare, "commit <commit>" for a lightweight one, nothing when absent
bare_tag() { git -C "$tt/$1.git" for-each-ref --format='%(objecttype) %(*objectname)%(objectname)' "refs/tags/$2" | awk '{ print $1, substr($2, 1, 40) }'; }
registered_tree() {
  git -C "$tt/$1.git" show "main:$entry/Versions.toml" 2> /dev/null |
    awk -v v="[\"$2\"]" '$0 == v { on = 1; next } /^\[/ { on = 0 } on && /^git-tree-sha1/ { gsub(/[" ]/, ""); split($0, a, "="); print a[2] }'
}
# one run's verdict: its name, the failures found (empty passes), the output text it must print
verdict() {
  local run=$1 problems=$2 text=$3
  if [ -z "$problems" ] && grep -qF -- "$text" "$out"; then
    echo "PASS ($run)"
  else
    echo "FAIL ($run):${problems:- the output lacks '$text'}"
    sed 's/^/    /' "$out" | tail -20
    fails=$((fails + 1))
  fi
  [ "$run" != "$stop_after" ] || finish
}
finish() {
  echo
  if [ "$fails" -eq 0 ]; then echo "release-selftest: all runs behave"; else echo "release-selftest: $fails run(s) failed"; fi
  [ "$fails" -eq 0 ]
  exit
}
# what a complete release of VERSION at REL leaves: annotated tags peeling to REL on both bares, both registry bares
# at one commit whose entry gives VERSION REL's tree, no subdir
released() {
  local version=$1 rel=$2 problems=""
  for b in origin gitea; do [ "$(bare_tag "$b" "v$version")" = "tag $rel" ] || problems+=" $b's v$version is '$(bare_tag "$b" "v$version")', not an annotated tag at $rel;"; done
  local head
  head=$(git -C "$tt/registry-origin.git" rev-parse -q --verify refs/heads/main)
  [ -n "$head" ] && [ "$(git -C "$tt/registry-gitea.git" rev-parse -q --verify refs/heads/main)" = "$head" ] || problems+=" the registry bares differ;"
  [ "$(registered_tree registry-origin "$version")" = "$(git -C "$pkg" rev-parse "$rel^{tree}")" ] || problems+=" the registry's tree for $version is not $rel's;"
  ! git -C "$tt/registry-origin.git" show "main:$entry/Package.toml" 2> /dev/null | grep -q '^subdir' || problems+=" Package.toml has a subdir;"
  printf '%s' "$problems"
}
at_rel() { # every test call since line $1 recorded at $2
  local problems=""
  while read -r what head; do [ "$head" = "$2" ] || problems+=" $what ran at $head, not $2;"; done < <(tail -n "+$(($1 + 1))" "$record")
  printf '%s' "$problems"
}

# (a00) the registry not named: refused before anything runs, nothing published
state=$(refs) before=$(tiers)
REGISTRY_GITHUB="" release 0.1.0
problems=$( [ $? != 0 ] || echo " exit 0;")
[ "$(refs)" = "$state" ] || problems+=" a bare changed;"
[ "$(tiers)" = "$before" ] || problems+=" the tests ran;"
verdict a00 "$problems" "the registry is not named"

# (a0) the registry unreadable (no such repository), no clone in the depot: refused before the tests, nothing published
state=$(refs) before=$(tiers)
REGISTRY_GITHUB=$tt/missing.git release 0.1.0
problems=$( [ $? != 0 ] || echo " exit 0;")
[ "$(refs)" = "$state" ] || problems+=" a bare changed;"
[ "$(tiers)" = "$before" ] || problems+=" the tests ran;"
[ ! -d "$clone" ] || problems+=" a registry clone was made;"
verdict a0 "$problems" "cannot be read"

# (a) 0.1.0 as committed and pushed, the registry bares empty: created, tagged, pushed, registered, published
rel=$(git -C "$pkg" rev-parse HEAD) before=$(tiers)
release 0.1.0
problems=$( [ $? = 0 ] || echo " exit nonzero;")$(released 0.1.0 "$rel")$(at_rel "$before" "$rel")
[ "$(($(tiers) - before))" = 1 ] || problems+=" not one test call;"
verdict a "$problems" "v0.1.0 released at $rel"

# (b) a bump to 0.1.1, committed and pushed: the second release, a second registry entry
bump 0.1.1 || exit 2
rel=$(git -C "$pkg" rev-parse HEAD)
release 0.1.1
problems=$( [ $? = 0 ] || echo " exit nonzero;")$(released 0.1.1 "$rel")$(released 0.1.0 "$(git -C "$pkg" rev-parse "v0.1.0^{commit}")")
verdict b "$problems" "v0.1.1 released at $rel"

# (c) 0.1.1 again: nothing runs, nothing changes
state=$(refs) before=$(tiers)
release 0.1.1
problems=$( [ $? = 0 ] || echo " exit nonzero;")
[ "$(refs)" = "$state" ] || problems+=" a bare changed;"
[ "$(tiers)" = "$before" ] || problems+=" the tests ran;"
verdict c "$problems" "v0.1.1 already released at $rel"

# (c2) complete but invalid: the clone's commit, published to both registry bares, gives Package.toml a wrong repo
# and a subdir; the rerun refused before the tests instead of the no-op
registry_heads=$(git -C "$tt/registry-origin.git" rev-parse refs/heads/main)
sed -i '' 's|^repo = .*|repo = "https://example.invalid/wrong.git"|' "$clone/$entry/Package.toml" &&
  printf 'subdir = "probe"\n' >> "$clone/$entry/Package.toml" &&
  nocheck "$clone" commit -q -am "probe: the package entry made invalid" &&
  git -C "$clone" push -q origin HEAD:refs/heads/main && git -C "$clone" push -q gitea HEAD:refs/heads/main || exit 2
state=$(refs) before=$(tiers)
release 0.1.1
problems=$( [ $? != 0 ] || echo " exit 0;")
[ "$(refs)" = "$state" ] || problems+=" a bare changed;"
[ "$(tiers)" = "$before" ] || problems+=" the tests ran;"
verdict c2 "$problems" "Package.toml carries a subdir"
git -C "$clone" reset -q --hard HEAD~1 && git -C "$clone" update-ref refs/remotes/origin/main "$registry_heads" &&
  git -C "$clone" update-ref refs/remotes/gitea/main "$registry_heads" &&
  git -C "$tt/registry-origin.git" update-ref refs/heads/main "$registry_heads" &&
  git -C "$tt/registry-gitea.git" update-ref refs/heads/main "$registry_heads" || exit 2
# (c3) the same with only a near miss: the repo line's dot before git another character, refused
sed -i '' 's|^repo = "\(.*\)\.git"$|repo = "\1xgit"|' "$clone/$entry/Package.toml" &&
  nocheck "$clone" commit -q -am "probe: the repo line a near miss" &&
  git -C "$clone" push -q origin HEAD:refs/heads/main && git -C "$clone" push -q gitea HEAD:refs/heads/main || exit 2
state=$(refs) before=$(tiers)
release 0.1.1
problems=$( [ $? != 0 ] || echo " exit 0;")
[ "$(refs)" = "$state" ] || problems+=" a bare changed;"
[ "$(tiers)" = "$before" ] || problems+=" the tests ran;"
verdict c3 "$problems" "Package.toml does not name repo"
git -C "$clone" reset -q --hard HEAD~1 && git -C "$clone" update-ref refs/remotes/origin/main "$registry_heads" &&
  git -C "$clone" update-ref refs/remotes/gitea/main "$registry_heads" &&
  git -C "$tt/registry-origin.git" update-ref refs/heads/main "$registry_heads" &&
  git -C "$tt/registry-gitea.git" update-ref refs/heads/main "$registry_heads" || exit 2
# (c4) the same with only the UUID another package's, the subdir and repo lines right: refused before the tests
sed -i '' 's|^uuid = .*|uuid = "00000000-0000-4000-8000-000000000000"|' "$clone/$entry/Package.toml" &&
  nocheck "$clone" commit -q -am "probe: the package entry under another UUID" &&
  git -C "$clone" push -q origin HEAD:refs/heads/main && git -C "$clone" push -q gitea HEAD:refs/heads/main || exit 2
state=$(refs) before=$(tiers)
release 0.1.1
problems=$( [ $? != 0 ] || echo " exit 0;")
[ "$(refs)" = "$state" ] || problems+=" a bare changed;"
[ "$(tiers)" = "$before" ] || problems+=" the tests ran;"
verdict c4 "$problems" "Package.toml does not name uuid"
git -C "$clone" reset -q --hard HEAD~1 && git -C "$clone" update-ref refs/remotes/origin/main "$registry_heads" &&
  git -C "$clone" update-ref refs/remotes/gitea/main "$registry_heads" &&
  git -C "$tt/registry-origin.git" update-ref refs/heads/main "$registry_heads" &&
  git -C "$tt/registry-gitea.git" update-ref refs/heads/main "$registry_heads" || exit 2

# the refusals of 0.1.2: each before any push, every bare unchanged
bump 0.1.2 || exit 2
rel=$(git -C "$pkg" rev-parse HEAD) prev=$(git -C "$pkg" rev-parse HEAD~1)
refused() { # run, output text, whether the tests may have run (yes|no)
  local code=$1 state before problems=""
  state=$(refs) before=$(tiers)
  release 0.1.2
  [ $? != 0 ] || problems+=" exit 0;"
  [ "$(refs)" = "$state" ] || problems+=" a bare changed;"
  [ "$3" = yes ] || [ "$(tiers)" = "$before" ] || problems+=" the tests ran;"
  verdict "$code" "$problems" "$2"
}
# (d0) near misses published on main: a version line and a section whose dots are other characters, each refused
near_miss() { # run, output text, the version line
  sed -i '' "s/^version = \"[^\"]*\"/$3/" "$pkg/Project.toml" &&
    nocheck "$pkg" commit -q -am "probe: a near miss" && publish || exit 2
  refused "$1" "$2" no
  git -C "$pkg" reset -q --hard "$rel" && git -C "$pkg" push -q -f origin main && git -C "$pkg" push -q -f gitea main || exit 2
}
near_miss d0 'does not carry version = "0.1.2"' 'version = "0x1x2"'
# (d) a local annotated v0.1.2 on the 0.1.1 commit
nocheck "$pkg" tag -a v0.1.2 -m v0.1.2 "$prev" || exit 2
refused d "v0.1.2 peels to $prev, not $rel" no
git -C "$pkg" tag -d v0.1.2 > /dev/null
# (d2) a local lightweight v0.1.2 at REL
git -C "$pkg" tag v0.1.2 "$rel" || exit 2
refused d2 "the local v0.1.2 is a lightweight tag" no
git -C "$pkg" tag -d v0.1.2 > /dev/null
# (d3) a lightweight v0.1.2 at REL on the origin bare only
git -C "$tt/origin.git" update-ref refs/tags/v0.1.2 "$rel" || exit 2
refused d3 "origin holds a lightweight v0.1.2" no
git -C "$tt/origin.git" update-ref -d refs/tags/v0.1.2
# (d4) an annotated v0.1.2 on the gitea bare peeling to the 0.1.1 commit
nocheck "$pkg" tag -a v0.1.2 -m v0.1.2 "$prev" && git -C "$pkg" push -q gitea refs/tags/v0.1.2 &&
  git -C "$pkg" tag -d v0.1.2 > /dev/null || exit 2
refused d4 "gitea's v0.1.2 peels to '$prev', not $rel" no
git -C "$tt/gitea.git" update-ref -d refs/tags/v0.1.2
# (e) a failing test run
export FAKE_TIER_FAIL=1
refused e "the tests failed at $rel" yes
unset FAKE_TIER_FAIL
git -C "$pkg" rev-parse -q --verify refs/tags/v0.1.2 > /dev/null && echo "FAIL (e): a local tag was made" && fails=$((fails + 1))
# (e2) the checkout moved while the tests ran: refused before the tag, and the tests ran at REL all the same
export FAKE_TIER_MOVE=1
start=$(tiers)
refused e2-refusal "the checkout moved or changed while the tests ran" yes
unset FAKE_TIER_MOVE
problems=$(at_rel "$start" "$rel")
git -C "$pkg" rev-parse -q --verify refs/tags/v0.1.2 > /dev/null && problems+=" a local tag was made;"
echo "the tests ran at $rel" >> "$out"
verdict e2 "$problems" "the tests ran at"
git -C "$pkg" reset -q --hard "$rel"
# (e3) an annotated v0.1.2 on the 0.1.1 commit made while the tests ran: refused after the tests, before any push
export FAKE_TIER_TAG=v0.1.2
refused e3 "the local v0.1.2 peels to $prev, not $rel" yes
unset FAKE_TIER_TAG
git -C "$pkg" tag -d v0.1.2 > /dev/null

# (f) the package's gitea bare read-only: GitHub has the tag, the registry is unchanged; writable again, the rerun resumes
registry_state=$(git -C "$tt/registry-origin.git" for-each-ref; git -C "$tt/registry-gitea.git" for-each-ref)
chmod -R a-w "$tt/gitea.git"
release 0.1.2
code=$?
chmod -R u+w "$tt/gitea.git"
problems=$( [ $code != 0 ] || echo " exit 0;")
[ "$(bare_tag origin v0.1.2)" = "tag $rel" ] || problems+=" origin lacks the tag;"
[ -z "$(bare_tag gitea v0.1.2)" ] || problems+=" gitea has the tag;"
[ "$(git -C "$tt/registry-origin.git" for-each-ref; git -C "$tt/registry-gitea.git" for-each-ref)" = "$registry_state" ] ||
  problems+=" the registry changed;"
verdict f-refusal "$problems" "just push v0.1.2 refused or failed"
release 0.1.2
problems=$( [ $? = 0 ] || echo " exit nonzero;")$(released 0.1.2 "$rel")
verdict f "$problems" "v0.1.2 released at $rel"

# (g) 0.1.3 with the registry's gitea bare read-only: published on GitHub, the mirror refused; the rerun registers
# nothing again and pushes the mirror
bump 0.1.3 || exit 2
rel=$(git -C "$pkg" rev-parse HEAD)
chmod -R a-w "$tt/registry-gitea.git"
release 0.1.3
code=$?
chmod -R u+w "$tt/registry-gitea.git"
problems=$( [ $code != 0 ] || echo " exit 0;")
[ "$(registered_tree registry-origin 0.1.3)" = "$(git -C "$pkg" rev-parse "$rel^{tree}")" ] || problems+=" GitHub's registry lacks 0.1.3;"
[ -z "$(registered_tree registry-gitea 0.1.3)" ] || problems+=" gitea's registry has 0.1.3;"
verdict g-refusal "$problems" "git push of the registry to gitea failed"
registry_head=$(git -C "$clone" rev-parse HEAD)
release 0.1.3
problems=$( [ $? = 0 ] || echo " exit nonzero;")$(released 0.1.3 "$rel")
[ "$(git -C "$clone" rev-parse HEAD)" = "$registry_head" ] || problems+=" the rerun registered again;"
verdict g "$problems" "v0.1.3 released at $rel"

# (h) 0.1.3's entry edited to another tree and committed in the clone: the rerun refused
sed -i '' "/^\[\"0.1.3\"\]/,/^\[/ s/^git-tree-sha1 = .*/git-tree-sha1 = \"$(printf 'a%.0s' {1..40})\"/" "$clone/$entry/Versions.toml"
nocheck "$clone" commit -q -am "probe: the entry edited" || exit 2
state=$(refs)
release 0.1.3
problems=$( [ $? != 0 ] || echo " exit 0;")
[ "$(refs)" = "$state" ] || problems+=" a bare changed;"
verdict h "$problems" "already holds 0.1.3 with tree"
git -C "$clone" reset -q --hard HEAD~1

# (h2) a bump to 0.1.4 with an uncommitted entry for it at the right tree in the clone: refused before the tests
bump 0.1.4 || exit 2
rel=$(git -C "$pkg" rev-parse HEAD)
printf '\n["0.1.4"]\ngit-tree-sha1 = "%s"\n' "$(git -C "$pkg" rev-parse "$rel^{tree}")" >> "$clone/$entry/Versions.toml"
state=$(refs) before=$(tiers)
release 0.1.4
problems=$( [ $? != 0 ] || echo " exit 0;")
[ "$(refs)" = "$state" ] || problems+=" a bare changed;"
[ "$(tiers)" = "$before" ] || problems+=" the tests ran;"
verdict h2 "$problems" "the registry clone"
git -C "$clone" checkout -q -- .

# (i) the clone's author an identity the lists lack: the tag published, the registry commit refused before either push
registry_state=$(git -C "$tt/registry-origin.git" for-each-ref; git -C "$tt/registry-gitea.git" for-each-ref)
address=probe
address+=@example.invalid # joined at run time: the guard's scan refuses an address written whole
git -C "$clone" config user.name "Probe Person" && git -C "$clone" config user.email "$address"
release 0.1.4
code=$?
problems=$( [ $code != 0 ] || echo " exit 0;")
[ "$(bare_tag origin v0.1.4)" = "tag $rel" ] && [ "$(bare_tag gitea v0.1.4)" = "tag $rel" ] || problems+=" the tag is not on both bares;"
[ "$(git -C "$tt/registry-origin.git" for-each-ref; git -C "$tt/registry-gitea.git" for-each-ref)" = "$registry_state" ] ||
  problems+=" a registry bare changed;"
verdict i "$problems" "nothing published"

finish
