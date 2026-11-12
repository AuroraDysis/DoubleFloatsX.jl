#!/usr/bin/env bash
# The family's scope, one tracked path per line: in a fork (a committed UPSTREAM.toml), every tracked path that
# upstream's tree at the admitted commit does not hold, the package's name in a path mapped back to upstream's (so a
# renamed upstream file stays upstream's); in a family package, every tracked path. Upstream's files keep upstream's
# style; the family's get the family's formatter. The commit guard computes the same scope over the staged paths.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.quotePath GIT_CONFIG_VALUE_0=false
if [ ! -f UPSTREAM.toml ]; then
  git ls-files
  exit
fi
read -r upc from to < <(python3 -c '
import tomllib
t = tomllib.load(open("UPSTREAM.toml", "rb"))
print(t["upstream"]["commit"], t["upstream"]["name"], t["package"]["name"])')
held=$(git ls-tree -r --name-only "$upc")
git ls-files | while IFS= read -r f; do
  grep -qxF -- "${f//$to/$from}" <<< "$held" || printf '%s\n' "$f"
done
