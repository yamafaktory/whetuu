# Changelog

Every released version, newest first. Generated from the commit history by
`zig build changelog`, so it is never edited by hand.

## v0.1.6 — 2026-07-24

### Changed

- Install to ~/.local/bin, the path the XDG spec names
- Call it a status line instead of a prompt
- Generate the changelog from the commit history
- Publish hand-written notes with a release that needs them

### Fixed

- Fix the stress in the pronunciation note
- Fix the picker running the entry Tab copied instead of the edit

## v0.1.5 — 2026-07-23

### Added

- Add a square mark for listings

### Changed

- Render the social card from the page's own styles
- Widen the landing page text
- Give the site a command table and document what paths reports
- Recall the last failed command from the history picker

## v0.1.4 — 2026-07-23

### Added

- Add an install script and a landing page

### Changed

- Print the setup line on a terminal and add a paths command

## v0.1.3 — 2026-07-23

### Changed

- Redraw the picker only when the frame changes
- Redraw and filter the picker only when something changed
- Reserve the history containers before deduping
- Spawn tasks only for the modules that read the disk
- Re-measure the performance table on pinned cores

## v0.1.2 — 2026-07-23

### Changed

- Syntax highlight the picker and fit rows to the terminal

## v0.1.1 — 2026-07-20

### Added

- Add a demo recording and a step to regenerate it

### Changed

- Show editing a picker entry in the demo
- Cache toolchain versions between prompts
- Skip commands prefixed with a space
- Bind the up arrow to the picker in bash and zsh

## v0.1.0 — 2026-07-20

### Added

- Add command history with an interactive picker
- Add SSH-aware user@host segment
- Add macOS support and automate releases
- Add badges and MIT license

### Changed

- Update to Zig master, expand language detection, and overhaul history
- Scope the history picker to the current directory
- Show in-progress git operation and stash count
- Decode every key in a pasted input burst
