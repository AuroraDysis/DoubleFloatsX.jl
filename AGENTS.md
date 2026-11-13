# DoubleFloatsX.jl - repository operating contract

The package `DoubleFloatsX`: upstream's DoubleFloats.jl (`Double64`, `Double32`, `Double16` and the parametric
`DoubleFloat{T}`) under its own name and UUID, carrying upstream's history, maintained by the family so that these
types are correct across their whole range and certified by the family's public test package
`ExtendedPrecisionTests` (https://github.com/AuroraDysis/ExtendedPrecisionTests.jl). Upstream, its admitted release
and the patches carried on it are in `UPSTREAM.toml`; what changed for a user is `README.md`, "Differences from
upstream". The rules this code follows are kept in the family's wiki, the checkout this clone names (the
environment's `DAIDALOS_WIKI`, else `git config daidalos.wiki`, set by `just hooks-install <path>`); this repository
holds their enforcement.

## Standing operator orders

These orders outrank any task prompt. If your prompt asks for something one of them forbids, stop before doing the
work and report the conflict.

- This repository is public. Nothing confidential enters it, its history and commit messages included: no
  closed-source code or anything read from it; no credentials, host addresses or names, cluster or queue job ids,
  user or account names or home paths; no unpublished results, private correspondence or personal data; no name of a
  private repository, no id or slug of a page of the family's wiki, no local path. Tooling that needs a private
  address or path (the registry, the wiki) reads it from an environment variable or this clone's git config, never
  from a literal. The commit guard, the message guard, `just push` and `just release` scan for the rest with this
  repository's copy of the confidential scan and the wiki's lists, and each first refuses a copy that differs from
  the wiki's master (`cmp`): a master change refuses every commit, push and release until the sync commit.
- No contact with upstream, of any kind: no issue, pull request, comment or e-mail, and nothing pushed. The `upstream`
  remote fetches only (its push URL is disabled); upstream's defects are recorded as fact in the family's wiki, never
  reported.
- Upstream's files keep upstream's style, so a change to them reads as the change alone; the family's formatter
  applies to the family's scope only (below).

## The two scopes

- **Upstream's files**: every path upstream's tree holds at the admitted commit (`UPSTREAM.toml` `[upstream]
  commit`), the package's name in a path mapped back to upstream's (`src/DoubleFloatsX.jl` is upstream's
  `src/DoubleFloats.jl`). They keep upstream's formatting and checks: the guard's size, binary and debris checks skip
  a blob equal to upstream's at the same path, and the confidential scan reads every changed one whole.
- **The family's scope**: every other tracked path, computed, never hand-listed: `just scope` (`tools/family-scope.sh`;
  the guard computes the same over the staged paths). Its Julia is formatted by JuliaFormatter, at its newest release
  pinned in `format/`'s manifest, with the blue style of `.JuliaFormatter.toml`.

## Repository-wide constraints

Tags name the enforcement: `[HARD - pre-commit]` the commit guard `.githooks/pre-commit` and the message guard
`.githooks/commit-msg`; `[GUIDANCE]` convention, a deviation needs one line of reason in the commit.

- `[HARD - pre-commit]` No blob over 1 MB, no binary artefact or image, no debris, no new top-level entry outside the
  allowlist in `.githooks/pre-commit` (upstream's top-level entries are allowed), upstream's own blobs exempt; the
  confidential scan, policy fork with the shared and the forks' allow lists joined, over every staged blob but
  upstream's own, every path and every message; the family's scope's `.jl` formatted. Bypass only with `--no-verify`
  and the reason in the message.
- `[GUIDANCE]` Identity: the package is `DoubleFloatsX` with UUID `949356e3-18ca-4f00-99f2-e8b6fcaa5048`, never
  upstream's; the exported type names stay upstream's. Every change of a contract a user sees gets a regression id
  (`DFX-NNN`), a row in the README's "Differences from upstream", an `UPSTREAM.toml` `[[patch]]` row and a `NOTICE`
  line.
- `[GUIDANCE]` Versions are the family's SemVer (`0.x` until the qualified `1.0.0`), each an annotated tag `vX.Y.Z` registered
  in the family's registry by `just release`; upstream's tags are kept as `upstream/<tag>`.
- `[GUIDANCE]` Julia on the operator's Macs: a single process measured under 1.5 GiB that finishes in minutes runs
  directly (the package's test suite, 0.81 GB and 53 s, may); the release's steps go through hostq (`just _jl-hostq
  <recipe>`).
- `[GUIDANCE]` Commits: one logical unit each, the body says why; never commit what breaks a passing test. A push
  goes only through `just push <ref>`, on the controller's word.
- `[GUIDANCE]` Everything in the repository is English.

## Commands

- `just hooks-install <wiki>` once per clone; `just guard-test` (the guards and `just push` on a synthetic
  repository); `just release-test` (the release on scratch remotes; its registrations are hostq jobs).
- `just scope`; `just jl-format [paths]` and `just jl-fmt-check [paths]` (the family's scope by default); `just lint`.
- `just _jl-hostq test` (upstream's suite through hostq).
- `just push <ref>`; `just release X.Y.Z` (the controller's: the release commit published by `just push main` first;
  the tests at it, the annotated tag pushed through the scan, the registration in the family's registry, named by
  `git config daidalos.registry-github`, `daidalos.registry-gitea` and `daidalos.registry-name`, and its
  publication, one resumable transaction).
