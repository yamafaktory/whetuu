# Releasing

Maintainer notes. Users only need the
[install instructions](README.md#install).

## Cut a release

One command, start to finish:

```sh
zig build publish -- v0.1.0
```

It runs the local tests and builds every release target, then:

1. checks the tree is clean, you are on `main`, `main` matches `origin/main`,
   and the tag does not already exist
2. bumps `.version` in `build.zig.zon` and commits it as `Release v0.1.0`
   (skipped when already correct)
3. pushes `main`
4. waits for CI to pass **on that exact commit**, polling the public GitHub API
   (needs `curl` and `python3`; no token, since the repo is public)
5. tags and pushes the tag

Step 5 is what triggers
[`.github/workflows/release.yml`](.github/workflows/release.yml). The workflow
re-runs the tests on a clean checkout, runs `zig build release -Dversion=<tag>`,
and attaches the four tarballs plus a `SHA256SUMS` file with generated release
notes. Nothing that ships is built from your working tree.

The command returns as soon as the tag is pushed; the release itself appears a
few minutes later, at
[Actions](https://github.com/yamafaktory/whetuu/actions) and then
[Releases](https://github.com/yamafaktory/whetuu/releases).

## The changelog

[`CHANGELOG.md`](CHANGELOG.md) tracks every release in the repository, so the
history is readable without the releases page and travels with a clone.

It is generated, never edited. `zig build publish` regenerates it with the
pending tag and commits it alongside the version bump, so a release cannot ship
a stale one. Nothing to remember and nothing to rename.

```sh
zig build changelog        # preview, with what has landed under Unreleased
```

**The commit subject is the changelog entry.** That is the whole input, so
write the subject for a user of whetuu, in the imperative, and the entry needs
no further work. Detail that only a maintainer wants goes in the commit body,
which never appears in the file.

Sections come from the leading verb. `Add` files under Added, `Fix` under
Fixed, `Remove` under Removed, everything else under Changed. Getting that
wrong costs a heading, never an entry.

A commit that changes nothing a user can observe goes in
[`tools/changelog-skip.txt`](tools/changelog-skip.txt) by full SHA. Reach for
it rarely. A subject worth publishing is the better fix, and the list only
exists because the early history predates the rule.

## Releases that need a migration step

Generated notes are a list of commit titles. They have no room for "here is what
to do to your machine before this works". A release that moves a path or changes
an install location writes that in `release_notes/<tag>.md`:

```sh
$EDITOR release_notes/v0.1.6.md
```

Commit it before tagging. The release workflow picks up the file matching the
tag and GitHub puts it above the generated list. Nothing to run by hand, and no
`gh` on your machine. A tag with no matching file publishes as it always did, so
most releases need nothing here.

A pre-release falls back to the stable version it rehearses. Tagging
`v0.1.6-rc.1` publishes `release_notes/v0.1.6.md`, which is what makes the
rehearsal worth doing. Name a file after the full pre-release tag to override
that.

A release note and a changelog entry are not the same thing. `CHANGELOG.md`
records what changed. `release_notes/<tag>.md` tells the reader what to do about
it, and only exists for releases that ask something of them. A release that
needs both repeats the summary, which is the right trade: one is read in a
clone, the other on the releases page, and neither reader has the other open.

Keep the file to what the reader has to do. It does not belong in `README.md`.
That file describes the current version to someone deciding whether to use
whetuu, and a note aimed at people upgrading from one specific old version goes
stale on the next release. Where the upgrade can be detected at runtime, say it
there too. The installer checking for a leftover `~/.whetuu` reaches the
affected user at the moment it matters and nobody else.

## Pre-releases

A tag with a semver suffix is published as a GitHub pre-release, so it never
becomes the "latest" release the install docs point people at:

```sh
zig build publish -- v0.1.0-rc.1
```

Use one to rehearse the whole pipeline, or to get a build in front of someone
before committing to the version. Everything else is identical — same four
targets, same checksums, same stamped binary.

## What it refuses to do

These are all checked before anything is written, so a run rejected here leaves
nothing behind locally or on the remote:

- the version is missing, `dev`, or not shaped like `v1.2.3` / `v1.2.3-rc.1`
- the working tree is dirty
- the current branch is not `main`
- `main` and `origin/main` disagree — starting level keeps the bump the only
  commit publishing adds
- the tag already exists locally or on origin
- `origin` is not a GitHub remote, so CI cannot be verified

## If it fails partway

The bump commit is pushed (step 3) before CI is awaited (step 4), so a failure
after that point leaves `main` one commit ahead with no tag:

- **CI fails** — fix it, commit, and re-run the same command. The bump is
  already in place, so it just pushes the fix, waits again, and tags.
- **CI times out** (20 minutes) — re-run once it finishes.
- **The tag push fails** — the local tag is deleted again so a retry is not
  blocked by leftover state.

Nothing here needs a force-push; re-running is always the recovery.

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

## The site

`docs/` is served by GitHub Pages from `main`, so the site redeploys on every
push. There is no release step for it. That also means `docs/install.sh` goes
live the moment it is pushed, while the binary it downloads is whichever release
is currently latest.

So cut the release before pushing a change to the installer or to the install
instructions, or the site will describe a binary nobody can get yet.

## Regenerating the demo

`docs/demo.gif` in the README is rendered from `docs/demo.cast`. Whenever the
status line or the picker changes visibly, re-record both:

```sh
zig build demo
```

That builds the binary, records a fresh cast, and renders the GIF. Needs
`python3`, `fish`, [`agg`](https://github.com/asciinema/agg)
(`cargo install --git https://github.com/asciinema/agg`), and a Nerd Font; it
refuses to run rather than emitting a GIF full of tofu boxes if any is missing.

- `WHETUU_DEMO_FONT` overrides the font (default `MesloLGS Nerd Font Mono`)
- `WHETUU_DEMO_FONT_SIZE` overrides the size (default `16`)

Always look at the result before committing. Pacing, colour and glyph coverage
are exactly what a diff cannot tell you, and a GIF that renders as boxes still
builds successfully.

`tools/record-demo.py` drives a real fish session in a throwaway repo, so the
output is genuine — only the keystrokes and their timing are scripted. Edit that
file to change what the demo does. It uses fish because the up-arrow picker
binding ships only in the fish integration; a bash recording would silently show
plain shell history instead of the picker.

## macOS artifacts are unsigned

Nothing in the pipeline code-signs or notarizes the Mach-O builds, so a user who
downloads a tarball in a browser gets a Gatekeeper prompt on first run and has to
clear `com.apple.quarantine` by hand — the README documents the workaround.

Removing that friction needs an Apple Developer account, a Developer ID
certificate in the repository secrets, and `codesign` + `notarytool` steps in the
release workflow. Worth doing if macOS becomes a primary target; until then the
quarantine note is the trade.

## Undo a release

Delete the release from the
[releases page](https://github.com/yamafaktory/whetuu/releases) (or
`gh release delete v0.1.0 --yes` if you have `gh`), then drop the tag:

```sh
git push origin :refs/tags/v0.1.0
git tag -d v0.1.0
```

Then fix and publish again. The `Release v0.1.0` commit stays on `main` — the
next `publish` bumps over it rather than needing it reverted.

## Versioning

The tag name is the single source of truth — it flows through `-Dversion` into
`build_options` and is what `whetuu --version` prints.

`build.zig.zon`'s `.version` is package metadata, read only by the Zig package
manager when another project depends on whetuu; it does not feed the binary.
`publish` bumps it automatically (minus the leading `v`, since the field takes a
bare semver), so it cannot drift from the tag. `zig build bump -- vX.Y.Z` does
just that step on its own, if you ever want it separately.
