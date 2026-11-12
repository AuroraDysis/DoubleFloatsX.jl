#!/usr/bin/env bash
# `just release VERSION`: the annotated tag vVERSION of the published release commit, tested, pushed through the
# outgoing scan (`just push`), its tree registered in the family's registry and the registry published through the
# same scan; one transaction, resumable, run from the repository's root. Nothing is read from a working file where a
# commit holds it. The registry is private, so its addresses and name are never written in this public repository:
# each is read from the environment, else from this clone's git config, and a missing one stops the release before
# anything runs. Variables (the self-test sets them), each with its git config key:
#   DAIDALOS_REGISTRY_GITHUB  daidalos.registry-github  the registry's GitHub URL
#   DAIDALOS_REGISTRY_GITEA   daidalos.registry-gitea   the registry's gitea mirror URL
#   DAIDALOS_REGISTRY_NAME    daidalos.registry-name    the registry's name, its clone's directory in the depot
#   DAIDALOS_PKG_GITHUB       (none)  the package's repository for the registry; default the origin remote's URL
#   DAIDALOS_PKG_DEPOT        (none)  the depot whose registries/<name> is the clone; default the first entry of
#                                     JULIA_DEPOT_PATH, else ~/.julia
set -uo pipefail
no() {
  echo "release: $*" >&2
  exit 1
}
[ $# = 1 ] && [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || no "usage: just release X.Y.Z"
version=$1
tag=v$version
cd "$(git rev-parse --show-toplevel)" || exit 1

setting() { # <variable> <git config key>: the environment's value, else this clone's git config, else nothing
  local v=${!1:-}
  [ -n "$v" ] || v=$(git config "$2" || true)
  printf '%s' "$v"
}
github=${DAIDALOS_PKG_GITHUB:-$(git remote get-url origin)} || no "no origin remote"
git remote get-url gitea > /dev/null || no "no gitea remote"
registry_github=$(setting DAIDALOS_REGISTRY_GITHUB daidalos.registry-github)
registry_gitea=$(setting DAIDALOS_REGISTRY_GITEA daidalos.registry-gitea)
name=$(setting DAIDALOS_REGISTRY_NAME daidalos.registry-name)
[ -n "$registry_github" ] && [ -n "$registry_gitea" ] && [ -n "$name" ] ||
  no "the registry is not named: set daidalos.registry-github, daidalos.registry-gitea and daidalos.registry-name (git config) or their DAIDALOS_REGISTRY_* variables; nothing tested or published"
depot=${DAIDALOS_PKG_DEPOT:-${JULIA_DEPOT_PATH%%:*}}
depot=${depot:-$HOME/.julia}
clone=$depot/registries/$name
wiki=${DAIDALOS_WIKI:-$(git config daidalos.wiki || true)}
for list in tools/split/confidential_scan.py tools/split/confidential-words.txt tools/split/confidential-allow.txt tools/split/confidential-identities.txt tools/mirrors/refs.tsv; do
  [ -n "$wiki" ] && [ -r "$wiki/$list" ] ||
    no "set DAIDALOS_WIKI to the wiki's checkout, or run \`just hooks-install <path>\`; its tools/split/ holds the confidential scan and its lists"
done

clean() { [ -z "$(git -C "$1" status --porcelain)" ]; }
# the tree a Versions.toml blob gives VERSION, empty when it lists no VERSION
tree_of() {
  git -C "$clone" show "$1:$entry/Versions.toml" 2> /dev/null |
    awk -v v="[\"$version\"]" '$0 == v { on = 1; next } /^\[/ { on = 0 } on && /^git-tree-sha1/ { gsub(/[" ]/, ""); split($0, a, "="); print a[2] }'
}
# the tag on a remote: absent, lightweight, or the commit its ^{} line names
remote_tag() {
  local lines
  lines=$(git ls-remote "$1" "refs/tags/$tag" "refs/tags/$tag^{}") || {
    echo unreadable
    return
  }
  if [ -z "$lines" ]; then
    echo absent
  elif peeled=$(awk -v r="refs/tags/$tag^{}" '$2 == r { print $1 }' <<< "$lines") && [ -n "$peeled" ]; then
    echo "$peeled"
  else
    echo lightweight
  fi
}
# a remote's main, empty when it has none, "unreadable" when the lookup fails
remote_main() {
  local line
  line=$(git ls-remote "$1" refs/heads/main) || {
    echo unreadable
    return
  }
  cut -f1 <<< "$line"
}
# the local tag, when it exists: annotated and peeling to REL (at the start, and again after the tests)
check_local_tag() {
  git rev-parse -q --verify "refs/tags/$tag" > /dev/null || return 0
  [ "$(git cat-file -t "refs/tags/$tag")" = tag ] || no "the local $tag is a lightweight tag; delete it (git tag -d $tag)"
  local peel
  peel=$(git rev-parse "refs/tags/$tag^{commit}")
  [ "$peel" = "$rel" ] || no "the local $tag peels to $peel, not $rel"
}
# a registry commit's entry for the package: its UUID, no subdir, the package's repository
check_package() {
  local package
  package=$(git -C "$clone" show "$1:$entry/Package.toml") || no "$1 has no $entry/Package.toml"
  ! grep -q '^subdir' <<< "$package" || no "$1's $entry/Package.toml carries a subdir"
  grep -qFx "uuid = \"$uuid\"" <<< "$package" || no "$1's $entry/Package.toml does not name uuid = \"$uuid\""
  grep -qFx "repo = \"$github\"" <<< "$package" || no "$1's $entry/Package.toml does not name repo = \"$github\""
}
# this repository's copy of the scan, refused unless it equals the wiki's master
cmp -s tools/checks/confidential_scan.py "$wiki/tools/split/confidential_scan.py" ||
  no "tools/checks/confidential_scan.py differs from the wiki's master $wiki/tools/split/confidential_scan.py, or is missing: copy the master over it and commit it, the sync commit; nothing published"
# the registry is the family's private registry: its commits are scanned with policy library, as every library's are
scan() {
  python3 tools/checks/confidential_scan.py --policy library \
    --words "$wiki/tools/split/confidential-words.txt" --allow "$wiki/tools/split/confidential-allow.txt" \
    --identities "$wiki/tools/split/confidential-identities.txt" --refs "$wiki/tools/mirrors/refs.tsv" "$@"
}

# 1. the preconditions; nothing is published
clean . || no "the checkout is not clean (untracked files included); commit or remove them first"
rel=$(git rev-parse HEAD)
[ "$(git symbolic-ref -q --short HEAD)" = main ] || no "HEAD is not on main"
git fetch -q --prune origin main || no "git fetch origin main failed"
git merge-base --is-ancestor "$rel" origin/main || no "$rel is not on origin's main; publish it with just push main first"
# the package's name, UUID and version as committed at REL, carriage returns dropped (upstream's DoubleFloats writes
# Project.toml with CRLF line ends, which the line patterns below would not match); grep reads to the end (one that
# stops at its match closes the pipe, and under pipefail git's SIGPIPE fails the check); -F, so that the version's
# dots match only dots
project=$(git show "$rel:Project.toml" | tr -d '\r') || no "no Project.toml at $rel"
grep -Fx "version = \"$version\"" <<< "$project" > /dev/null || no "Project.toml at $rel does not carry version = \"$version\""
pkg=$(sed -n 's/^name = "\(.*\)"$/\1/p' <<< "$project")
uuid=$(sed -n 's/^uuid = "\(.*\)"$/\1/p' <<< "$project")
[ -n "$pkg" ] && [ -n "$uuid" ] || no "Project.toml at $rel names no package or UUID"
entry=${pkg:0:1}/$pkg
rel_tree=$(git rev-parse "$rel^{tree}")
check_local_tag
for r in origin gitea; do
  t=$(remote_tag "$r")
  case $t in
    absent | "$rel") ;;
    lightweight) no "$r holds a lightweight $tag; only an annotated tag is a release" ;;
    *) no "$r's $tag peels to '$t', not $rel" ;;
  esac
done
# an unreadable registry is no empty one: both remotes answer before anything is tested or published
registry_head=$(git ls-remote "$registry_github" refs/heads/main) ||
  no "the registry $registry_github cannot be read (git ls-remote failed); nothing tested or published"
git ls-remote "$registry_gitea" refs/heads/main > /dev/null ||
  no "the registry $registry_gitea cannot be read (git ls-remote failed); nothing tested or published"
if [ ! -d "$clone" ] && [ -n "$registry_head" ]; then
  git clone -q "$registry_github" "$clone" || no "git clone $registry_github failed"
fi
if [ -d "$clone" ]; then
  clean "$clone" || no "the registry clone $clone is not clean (untracked files included); commit or remove the changes"
  registered=$(tree_of HEAD)
  [ -z "$registered" ] || [ "$registered" = "$rel_tree" ] ||
    no "$name already holds $version with tree $registered, not $rel's $rel_tree"
  git -C "$clone" cat-file -e "HEAD:$entry/Package.toml" 2> /dev/null && check_package HEAD
  if [ -n "$registered" ] && [ "$(remote_tag origin)" = "$rel" ] && [ "$(remote_tag gitea)" = "$rel" ]; then
    head=$(git -C "$clone" rev-parse HEAD)
    if [ "$(remote_main "$registry_github")" = "$head" ] && [ "$(remote_main "$registry_gitea")" = "$head" ]; then
      echo "release: $tag already released at $rel"
      exit 0
    fi
  fi
fi

# 2. the package's tests at REL on a snapshot that _jl-hostq ships, never the caller's checkout; then the checkout
#    rechecked
snapshot=.worktrees/release-$tag
git worktree remove --force "$snapshot" 2> /dev/null
git worktree add -q --detach "$snapshot" "$rel" || no "git worktree add $snapshot failed"
(cd "$snapshot" && just _jl-hostq test)
tests=$?
git worktree remove --force "$snapshot"
[ "$tests" = 0 ] || no "the tests failed at $rel; nothing tagged, pushed or registered"
[ "$(git rev-parse HEAD)" = "$rel" ] && clean . || no "the checkout moved or changed while the tests ran; nothing tagged"
check_local_tag # a tag made while the tests ran is checked as one found at the start

# 3. the tag, its object captured
git rev-parse -q --verify "refs/tags/$tag" > /dev/null || git tag -a "$tag" -m "$tag" "$rel" || no "git tag failed"
tag_object=$(git rev-parse "refs/tags/$tag")

# 4. the push through the outgoing scan of that object, then each remote's tag read back as that object at REL
[ "$(git rev-parse "refs/tags/$tag")" = "$tag_object" ] || no "the local $tag changed before the push"
just push "$tag" || no "just push $tag refused or failed; the registry is unchanged"
for r in origin gitea; do
  [ "$(git ls-remote "$r" "refs/tags/$tag" | cut -f1)" = "$tag_object" ] && [ "$(remote_tag "$r")" = "$rel" ] ||
    no "$r's $tag is not the tag object $tag_object at $rel after the push"
done

# 5. the registration, in the depot's clone, publishing nothing; at the registry's first version it is created there
if [ ! -d "$clone" ] || [ -z "$(tree_of HEAD)" ]; then
  [ "$(git rev-parse HEAD)" = "$rel" ] && clean . || no "the checkout moved or changed before the registration"
  [ ! -d "$clone" ] || clean "$clone" || no "the registry clone $clone is not clean"
  just _jl-hostq _jl-register "$name" "$registry_github" "$github" "$depot" || no "the registration failed (above)"
fi
git -C "$clone" remote get-url gitea > /dev/null 2>&1 || git -C "$clone" remote add gitea "$registry_gitea"

# 6. the registry's publication: the captured commit validated, scanned, pushed alone, read back
clean "$clone" || no "the registry clone $clone is not clean after the registration"
rc=$(git -C "$clone" rev-parse HEAD)
[ "$(tree_of "$rc")" = "$rel_tree" ] || no "$rc's $entry/Versions.toml does not give $version the tree $rel_tree"
check_package "$rc"
for r in origin gitea; do
  [ -z "$(remote_main "$(git -C "$clone" remote get-url "$r")")" ] || git -C "$clone" fetch -q "$r" ||
    no "git fetch $r of the registry failed"
done
scan --range "$clone" "$rc" --not --remotes=origin || no "the outgoing scan refused the registry's commits (above); nothing published"
scan --object "$clone" "$rc" || no "the scan refused the registry commit $rc (above); nothing published"
for r in origin gitea; do
  url=$(git -C "$clone" remote get-url "$r")
  [ "$(remote_main "$url")" = "$rc" ] && continue
  git -C "$clone" push -q --no-follow-tags --recurse-submodules=no "$r" "$rc:refs/heads/main" ||
    no "git push of the registry to $r failed; rerun just release $version"
done

# 7. asserted from the remotes and the captured commits
[ "$(git rev-parse "$tag^{tree}")" = "$rel_tree" ] || no "$tag's tree is not $rel's"
for r in origin gitea; do
  [ "$(remote_tag "$r")" = "$rel" ] || no "$r's $tag does not peel to $rel"
done
for url in "$registry_github" "$registry_gitea"; do
  [ "$(remote_main "$url")" = "$rc" ] || no "$url's main is not $rc"
done
echo "release: $tag released at $rel, registry at $rc"
