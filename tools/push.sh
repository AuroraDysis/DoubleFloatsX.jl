#!/usr/bin/env bash
# `just push REF`: publish REF to origin and gitea after the outgoing confidential scan of REF's object, read once at
# the start: the commits, blobs, paths, messages and identities it brings beyond what origin holds (and, in a fork,
# beyond upstream's history: the local upstream branches and the upstream/* tags, public bytes carrying nothing of the
# family's), and the object itself (an annotated tag's message and tagger); then both pushes of REF alone at that
# scanned object (no tag followed, no submodule), then each remote's object id for REF compared with the local one. A
# hit pushes nothing. The policy is the commit guard's: fork with the two allow lists joined when REF's tree holds
# UPSTREAM.toml, library otherwise. upstream is never fetched or pushed here.
set -uo pipefail
no() {
  echo "push: $*" >&2
  exit 1
}
[ $# = 1 ] || no "usage: just push REF"
cd "$(git rev-parse --show-toplevel)" || exit 1
wiki=${DAIDALOS_WIKI:-$(git config daidalos.wiki || true)}
for list in tools/split/confidential_scan.py tools/split/confidential-words.txt tools/split/confidential-allow.txt tools/split/confidential-allow-fork.txt tools/split/confidential-identities.txt tools/mirrors/refs.tsv; do
  [ -n "$wiki" ] && [ -r "$wiki/$list" ] ||
    no "set DAIDALOS_WIKI to the wiki's checkout, or run \`just hooks-install <path>\`; its tools/split/ holds the confidential scan and its lists"
done
full=$(git rev-parse --symbolic-full-name "$1") && [ -n "$full" ] || no "$1 names no branch or tag"
obj=$(git rev-parse "$full")
for r in origin gitea; do
  git remote get-url "$r" > /dev/null 2>&1 || no "no remote $r"
  git fetch -q "$r" || no "git fetch $r failed"
done
cmp -s tools/checks/confidential_scan.py "$wiki/tools/split/confidential_scan.py" ||
  no "tools/checks/confidential_scan.py differs from the wiki's master $wiki/tools/split/confidential_scan.py, or is missing: copy the master over it and commit it, the sync commit; nothing pushed"
allow=$(mktemp "${TMPDIR:-/tmp}/family-push-allow-XXXXXX") || no "no temporary file for the allow list"
trap 'rm -f "$allow"' EXIT
exclude=(--not --remotes=origin)
if git cat-file -e "$obj^{commit}:UPSTREAM.toml" 2> /dev/null; then
  policy=fork
  awk 1 "$wiki/tools/split/confidential-allow.txt" "$wiki/tools/split/confidential-allow-fork.txt" > "$allow" ||
    no "the wiki's two allow lists cannot be joined into one (above); nothing pushed"
  exclude+=(--remotes=upstream --glob=refs/tags/upstream/*)
else
  policy=library
  cp "$wiki/tools/split/confidential-allow.txt" "$allow" || no "the allow list cannot be copied; nothing pushed"
fi
scan() {
  python3 tools/checks/confidential_scan.py --policy "$policy" \
    --words "$wiki/tools/split/confidential-words.txt" --allow "$allow" \
    --identities "$wiki/tools/split/confidential-identities.txt" --refs "$wiki/tools/mirrors/refs.tsv" "$@"
}
# both scans read the object captured above, never the name, which another terminal may move meanwhile: what is pushed
# below is what was scanned; a tag on a published commit is the object scan's, the range naming no ref
scan --range . "$obj" "${exclude[@]}" || no "the outgoing scan (policy $policy) of $full at $obj refused it (above); nothing pushed"
scan --object . "$obj" || no "the scan of $full's own object $obj refused it (above); nothing pushed"
# the scanned object to REF and nothing else: no tag followed (push.followTags would add the annotated tags of REF's
# history, which the range scan does not see) and no submodule pushed; an explicit refspec ignores remote.<name>.push
# and push.default, and a remote with mirror = true refuses it
for r in origin gitea; do
  git push --no-follow-tags --recurse-submodules=no "$r" "$obj:$full" || no "git push $r $full failed"
done
for r in origin gitea; do
  got=$(git ls-remote "$r" "$full" | cut -f1)
  [ "$got" = "$obj" ] || no "$r holds '$got' for $full, not $obj"
done
echo "push: $full at $obj on origin and gitea"
