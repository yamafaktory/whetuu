# Releasing

Maintainer notes. Users only need the
[install instructions](README.md#install).

## Cut a release

```sh
zig build publish -- v0.1.0
```

That runs the tests, builds every release target, then tags the current commit
and pushes the tag — which is what triggers
[`.github/workflows/release.yml`](.github/workflows/release.yml). The workflow
re-runs the tests on a clean checkout, runs `zig build release -Dversion=<tag>`,
and attaches the four tarballs plus a `SHA256SUMS` file with generated release
notes. Nothing that ships is built from your working tree.

The command returns as soon as the tag is pushed; the release itself appears a
few minutes later.

```sh
gh run watch             # follow the build
gh release view v0.1.0   # confirm the artifacts
```

## What it refuses to do

Every check runs before any tag is created, so a rejected run leaves nothing
behind locally or on the remote:

- the version is missing, `dev`, or not shaped like `v1.2.3` / `v1.2.3-rc.1`
- the working tree is dirty
- the current branch is not `main`
- `main` and `origin/main` disagree — the workflow checks out the *tag*, so a
  commit that only exists locally would publish from something nobody can see
- the tag already exists locally or on origin

If the push itself fails, the local tag is deleted again so a retry is not
blocked by leftover state.

Tags are annotated, and signed when `tag.gpgsign` is enabled — expect a
passphrase prompt unless the GPG agent is already unlocked.

## Building artifacts without publishing

```sh
zig build release                    # tarballs marked "dev"
zig build release -Dversion=v0.1.0   # stamped
```

Writes a stripped, `ReleaseFast` tarball per target to `zig-out/release/`. The
target list lives in `build.zig` (`release_targets`), and CI calls this same
step, so a local run produces exactly what gets published.

Adding a target is a one-line edit there; CI cross-compiles the whole list on
every push, which is what catches a platform-specific regression (a
`std.os.linux` call, say) before it reaches a release.

## macOS artifacts are unsigned

Nothing in the pipeline code-signs or notarizes the Mach-O builds, so a user who
downloads a tarball in a browser gets a Gatekeeper prompt on first run and has to
clear `com.apple.quarantine` by hand — the README documents the workaround.

Removing that friction needs an Apple Developer account, a Developer ID
certificate in the repository secrets, and `codesign` + `notarytool` steps in the
release workflow. Worth doing if macOS becomes a primary target; until then the
quarantine note is the trade.

## Undo a release

```sh
gh release delete v0.1.0 --yes
git push origin :refs/tags/v0.1.0
git tag -d v0.1.0
```

Then fix and publish again.

## Versioning

The tag name is the single source of truth — it flows through `-Dversion` into
`build_options` and is what `whetuu --version` prints. `build.zig.zon` carries a
separate `.version` field that does not feed the binary.
