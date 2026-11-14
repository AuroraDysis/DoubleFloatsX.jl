# The repository's recipes. Upstream's files keep upstream's style and checks; the family's scope (tools/family-scope.sh)
# gets the family's formatter. On the operator's Macs a development run goes directly when it is a single process
# measured under 1.5 GiB that finishes in minutes; the release's tests and its registration go through hostq
# (`just _jl-hostq <recipe> ...`).

# The memory a hostq job of `_jl-hostq` asks, in GiB; empty, the recipe's own: `test` test_mem below, `_jl-register` 1
# (a LocalRegistry registration peaked at 0.51 GB resident, 8.7 s, 2026-11-12, plus about 100 %). Set on the command
# line to override (`just hostq_mem=2 _jl-hostq test`)
hostq_mem := ""

# The memory of `_jl-hostq test`, in GiB: the suite peaked at 1.42 GB resident (one process, with Gamma,
# HypergeometricFunctions and TaylorIntegration in the test targets and the loggamma fixture of 2733 points, a
# hostq job of 2026-11-14), plus about 40 %
test_mem := "2"

# List the recipes
default:
    @just --list

# Install the git hooks for this clone (core.hooksPath=.githooks) and name the wiki checkout whose master confidential scan the gates compare this repository's copy with and whose lists the scan reads (git config daidalos.wiki); with no WIKI the one already set is kept
hooks-install WIKI="":
    #!/usr/bin/env bash
    set -euo pipefail
    git config core.hooksPath .githooks
    if [ -n "{{WIKI}}" ]; then
        [ -d "{{WIKI}}/tools/split" ] || { echo "hooks-install: {{WIKI}} has no tools/split/; name the wiki's checkout" >&2; exit 1; }
        git config daidalos.wiki "$(cd "{{WIKI}}" && pwd)"
    fi
    wiki=$(git config daidalos.wiki || true)
    [ -n "$wiki" ] || { echo "hooks-install: no wiki named; run just hooks-install <path of the wiki's checkout>" >&2; exit 1; }
    echo "core.hooksPath -> .githooks; daidalos.wiki -> $wiki"

# Self-test of the commit guard, the message guard and `just push`, in the fork and the family modes, on a synthetic repository under TMPDIR
guard-test:
    bash tools/checks/guard-selftest.sh

# Self-test of `just release` on scratch remotes and a throwaway depot; its registrations run through hostq on this Mac
release-test:
    bash tools/checks/release-selftest.sh

# The family's scope, one tracked path per line: the paths upstream's tree at the admitted commit does not hold
scope:
    @bash tools/family-scope.sh

# Format the family's Julia files in place with the JuliaFormatter pinned in format/'s manifest and the style of .JuliaFormatter.toml, the paths defaulting to the family's scope; upstream's files are never formatted
[positional-arguments]
jl-format *PATHS:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ $# = 0 ]; then set -- $(bash tools/family-scope.sh | grep '\.jl$' || true); fi
    [ $# = 0 ] && { echo "jl-format: no Julia file in the family's scope"; exit 0; }
    JULIA_LOAD_PATH='@:@stdlib' julia --project=format --startup-file=no -e 'using JuliaFormatter; format(ARGS; throw_on_error=true)' -- "$@"

# Check that the JuliaFormatter pinned in format/'s manifest would change no .jl file of the family's scope (or the paths named): exit 1 naming the files, or on a missing environment or a loaded version other than the manifest's
[positional-arguments]
jl-fmt-check *PATHS:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ $# = 0 ]; then set -- $(bash tools/family-scope.sh | grep '\.jl$' || true); fi
    [ $# = 0 ] && { echo "jl-fmt-check: no Julia file in the family's scope"; exit 0; }
    JULIA_LOAD_PATH='@:@stdlib' julia --project=format --startup-file=no -e '
        using JuliaFormatter, TOML
        pin = VersionNumber(only(TOML.parsefile("format/Manifest.toml")["deps"]["JuliaFormatter"])["version"])
        pkgversion(JuliaFormatter) == pin || (println(stderr, "jl-fmt-check: JuliaFormatter ", pkgversion(JuliaFormatter), " loaded; format/Manifest.toml records ", pin); exit(1))
        bad = filter(f -> !format(f; overwrite=false, throw_on_error=true), ARGS)
        isempty(bad) || (println(stderr, "jl-fmt-check: JuliaFormatter ", pin, " would change: ", join(bad, ", ")); exit(1))
        println("jl-fmt-check: ", length(ARGS), " files formatted")' -- "$@"

# The package's own tests (upstream's suite), one Julia process
test:
    julia --project=. --startup-file=no -e 'using Pkg; Pkg.test()'

# Run a Julia recipe with its arguments as a hostq job through `ariadne queue`, on the host `git config daidalos.host` names (else the queue's pick in its mac pool) from a shipped copy of this checkout, except _jl-register, which writes the depot of this Mac and so runs on the local Mac in this tree; one thread, the memory `hostq_mem` names (else the recipe's own); prints the recipe's output and exits with its status
[positional-arguments]
_jl-hostq RECIPE *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    recipe=$1
    command -v ariadne > /dev/null || {
        echo "_jl-hostq: no ariadne on PATH, so no queue; where Julia may run directly: just $(printf '%q ' "$@")" >&2
        exit 1
    }
    host=$(git config daidalos.host || true)
    case $recipe in _jl-register) host=local ;; esac
    out=.scratch/$(date +%F)-jl-hostq/$recipe-$$
    # the memory: hostq_mem when set, else the recipe's own (the comments of hostq_mem and test_mem)
    mem="{{hostq_mem}}"
    [ -n "$mem" ] || case $recipe in test) mem={{test_mem}} ;; *) mem=1 ;; esac
    label=$(tr -d '\r' < Project.toml | sed -n 's/^name = "\(.*\)"$/\1/p' | tr '[:upper:]' '[:lower:]')
    job=$(ariadne queue submit --pool mac ${host:+--host "$host"} --threads 1 --mem "$mem" --expect 30 --label "$label:$recipe" --cwd . \
      --ship . --fetch "$out" \
      --env JULIA_NUM_THREADS=1 --env OPENBLAS_NUM_THREADS=1 --env JULIA_NUM_PRECOMPILE_TASKS=1 \
      -- bash -c "mkdir -p $out && { just $(printf '%q ' "$@"); echo \$? > $out/exit; } > $out/log 2>&1" |
      python3 -c 'import json, sys; print(json.load(sys.stdin)["job"])')
    echo "$recipe: hostq job $job on ${host:-the mac pool}" >&2
    waited=$(ariadne queue wait "$job") && wait_status=0 || wait_status=$?
    if [ -f "$out/exit" ]; then
        cat "$out/log"
        exit "$(cat "$out/exit")"
    fi
    [ ! -f "$out/log" ] || cat "$out/log" >&2
    printf '%s\n' "$waited" >&2
    ariadne queue status "$job" >&2
    echo "$recipe: hostq job $job left no exit status (queue wait exit $wait_status)" >&2
    exit 1

# The repository's own checks: the formatter over the family's scope and the confidential scan identical to the wiki's master copy
lint:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    just jl-fmt-check || rc=1
    wiki=${DAIDALOS_WIKI:-$(git config daidalos.wiki || true)}
    if [ -z "$wiki" ] || ! cmp tools/checks/confidential_scan.py "$wiki/tools/split/confidential_scan.py"; then
        echo "lint: tools/checks/confidential_scan.py differs from the wiki's tools/split/confidential_scan.py (or no wiki is named); copy the master" >&2
        rc=1
    fi
    [ "$rc" = 0 ] && echo "lint: ok"
    exit "$rc"

# Publish REF to origin and gitea after the outgoing confidential scan of REF's object (tools/push.sh); a hit pushes nothing; upstream is never pushed
push REF:
    bash tools/push.sh "{{REF}}"

# The release: the annotated tag vVERSION of HEAD, which `just push main` published first, after the package's tests at that commit; pushed through the outgoing scan and registered in the family's registry (named by git config, never written here), whose commit is scanned and pushed to GitHub and gitea; one transaction, resumable, run by the controller (tools/release.sh)
release VERSION:
    bash tools/release.sh "{{VERSION}}"

# Register this checkout's HEAD in the registry NAME of the depot DEPOT (created there from REGISTRY_URL when it has no clone) with REPO_URL as the package's repository, committing to the depot's clone and publishing nothing; `just release`'s registration, on this Mac only through `just _jl-hostq _jl-register ...`
[positional-arguments]
_jl-register NAME REGISTRY_URL REPO_URL DEPOT:
    JULIA_DEPOT_PATH="$4:" JULIA_PKG_PRECOMPILE_AUTO=0 julia --project=tools --startup-file=no -e 'using Pkg; Pkg.instantiate(); using LocalRegistry; name, registry_url, repo_url = ARGS; isdir(joinpath(first(DEPOT_PATH), "registries", name)) || create_registry(name, registry_url; description="The family registry", push=false); register(abspath("."); registry=name, repo=repo_url, push=false)' "$1" "$2" "$3"
