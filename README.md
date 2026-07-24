# 🌟 whetū

[![CI](https://github.com/yamafaktory/whetuu/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/yamafaktory/whetuu/actions/workflows/ci.yml)
[![version](https://img.shields.io/github/v/release/yamafaktory/whetuu?sort=semver&display_name=tag&label=version)](https://github.com/yamafaktory/whetuu/releases/latest)
[![license](https://img.shields.io/github/license/yamafaktory/whetuu)](LICENSE)

An opinionated, zero-config cross-shell prompt written in Zig.

*whetū* is Māori for "star". A star is the default prompt character, using the
Nerd Font glyph `nf-md-star_face`. The binary is installed as `whetuu`.

Pronounced **feh-TOO** (`/fɛˈtuː/`). In Māori `wh` is an *f* sound, not a *w*.
The macron in `ū` makes that vowel long, and a long vowel takes the stress, so
it falls on the second syllable. The ASCII name doubles the `u` to write that
same long vowel.

There is nothing to configure. One compiled binary renders one curated prompt,
the same for everyone. Every module that reads the disk runs at the same time
via `std.Io`, so a render costs about what its slowest probe costs. See
[Performance](#performance).

> **Requires a [Nerd Font](https://www.nerdfonts.com/).** The prompt uses Nerd
> Font glyphs for the git branch, language logos, and the prompt character.
> Without one those glyphs show as tofu boxes.

![A terminal session. The prompt tracks the branch, git status and toolchain
version. The history picker then filters and runs a command](docs/demo.gif)

[Website](https://yamafaktory.github.io/whetuu/) · [Install](#install) ·
[Performance](#performance) · [Security](#security)

## Modules

Left to right, each shown only when relevant:

| Module        | Shows                                                                       |
|---------------|-----------------------------------------------------------------------------|
| `user_host`   | `user@host` in bold green, only over SSH (`$SSH_CONNECTION`/`$SSH_TTY`) or when root, and then in bold red as a warning |
| `directory`   | Current directory, with `$HOME` collapsed to `~`. Keeps the anchor plus as many trailing directories as fit the width (`~/…/projects/client`) |
| `git` branch  | Branch glyph and current branch (or `(detached)`), in magenta               |
| `git` state   | Any operation underway, in yellow: `(rebasing 2/7)`, `(merging)`, `(cherry-picking)`, `(reverting)`, `(bisecting)`. Read straight from `.git`, with no extra subprocess |
| `git` status  | `[=conflicts $stashes +staged !modified ?untracked ⇡ahead ⇣behind]`         |
| `language`    | Logo and toolchain version in the brand color, for 39 languages and tools. Detected from a project manifest (`Cargo.toml`, `mix.exs`, …), a source file extension (`*.odin`, `*.rkt`, …), or an infra marker (`flake.nix`, `Dockerfile`, `*.tf` for Terraform and OpenTofu) |
| `cmd_duration`| Timer glyph and `<time>` when the last command ran for 2 s or more          |
| `character`   | A star, purple by default, or in the language brand color. Turns red after a failed command |

## Performance

A prompt runs before every command, so you pay its cost constantly. Numbers from
`hyperfine --warmup 40 --runs 400` on a 13th gen i9-13900H, ReleaseFast build,
with the toolchain version cache warm, pinned to the performance cores on an
otherwise idle machine:

| Directory | Render | For comparison |
|---|---|---|
| No repo, no toolchain | **2.3 ms** ± 0.7 | — |
| Zig repo, 35 files | **3.0 ms** ± 0.9 | `zig version` alone: 3.1 ms |
| Monorepo, 8259 files | **20.2 ms** ± 2.5 | `git status` alone: 19.3 ms |

Two things do most of the work. The probes overlap, so a render costs about what
the slowest one costs rather than the sum of all of them. In the monorepo the
whole prompt takes about as long as `git status` on its own.

Toolchain versions are also cached, keyed on the binary path, mtime and size.
The first prompt in a project pays for the probe. Later ones read a small file
instead. Upgrading a toolchain changes its mtime, which drops the stale entry.
What that saves depends on the toolchain. A slow `--version` call is well worth
skipping. A fast one is already hidden behind the git probe running alongside
it, which is why the Zig repo above lands within noise of `zig version` itself.

Reproduce it with:

```sh
hyperfine --warmup 40 --runs 400 \
  'whetuu prompt --shell fish --status 0 --duration-ms 0 --width 100'
```

Pin the run on a laptop that mixes performance and efficiency cores, with
`taskset -c 0-11` on Linux or its equivalent. Left to the scheduler, the same
measurement spreads across a factor of two and tells you nothing.

**A slow repository cannot hang your shell.** Both subprocesses are bounded. The
`git` call gets 250 ms and the toolchain probe gets 200 ms. They run at the same
time, so the worst case is the larger of the two, not the sum. Given a `git`
that hangs for 30 s, the prompt still returns in 257 ms. It simply drops the git
segment.

In a large repository, almost all of that time is `git status`, and most of that
is the scan for untracked files. Speeding it up is git's job, not whetuu's.
Turning on git's untracked cache cut `git status` from 13.5 ms to 5.7 ms on a
test repository of 8000 files:

```sh
git config core.untrackedCache true
```

## Security

whetuu reads your repository and prints a line. Here is what that involves.

- **No network access.** The binary has no socket, HTTP or DNS code. There is no
  telemetry and no update check.
- **Every path is one the spec already names.** The binary goes in
  `~/.local/bin`, the history store under `$XDG_DATA_HOME` and the version cache
  under `$XDG_CACHE_HOME`. whetuu creates no directory of its own in `$HOME`.
  Run `whetuu paths` to see both data locations, and whether each file exists
  yet. [Uninstall](#uninstall) lists what to remove.
- **The installer edits one file, once.** It appends an `init` line to the
  config of the shell in `$SHELL`, guarded so a second run changes nothing. Not
  the config of a shell you do not use. A `PATH` line joins it only when
  `~/.local/bin` is not already on your `PATH`. Set `WHETUU_NO_MODIFY=1` and it
  prints them instead.
- **No config file.** whetuu has none, so there is no config parser and no
  format for anything to smuggle through. Running, it writes two files. One is
  the history
  store. The other is a version cache at `~/.cache/whetuu/versions`, or under
  `$XDG_CACHE_HOME` when that is set. The cache holds toolchain version strings
  and nothing else. Delete it whenever you like.
- **Two subprocesses, both bounded.** `git status --porcelain=2 --branch -z`,
  and the version command of the detected toolchain (`zig version`,
  `node --version`, …). Nothing else is executed.
- **The history store is `0600`**, set again on every append. Command lines
  routinely contain paths and secrets. The store lives at
  `~/.local/share/whetuu/history`, or under `$XDG_DATA_HOME` when that is set.
  It usually is not set, on macOS or Linux.
- **A leading space keeps a command out of the store.** Shells have used this
  convention for decades:

  ```sh
   curl -H "Authorization: Bearer $TOKEN" https://api.example.com
  ```

  This works in fish, zsh and bash. bash needs help, because its `history`
  output has already lost the indentation by the time whetuu sees the command.
  So the bash integration adds `ignorespace` to your `HISTCONTROL` and keeps any
  value you already had. The command then stays out of bash's history too.

- **Anything else is stored in plaintext.** Paste a token into a `curl` without
  that leading space and the whole line is written to the store, as long as the
  command succeeds. File permissions are the only protection. Nothing is
  redacted. Keep secrets in environment variables or a credentials file, as you
  would with your shell's own history.

  Only commands that exited `0` are stored. Treat that as noise reduction for
  the picker, not a safeguard. It filters out your typos, not your working
  `curl`.

One thing to know. The language module picks which toolchain to probe from the
files in the current directory. So entering an untrusted repository can make
whetuu run something like `node --version`. It runs the binary your `PATH`
resolves, never one from the repository. If you keep `.` in your `PATH` that
distinction goes away, and it goes away for every other tool you run too.

## Install

Two ways. Neither is more supported than the other.

### Download the binary

Prebuilt binaries are on the
[releases page](https://github.com/yamafaktory/whetuu/releases), with a
`SHA256SUMS` file to verify them:

| Platform | Target |
|---|---|
| Linux x86-64 | `x86_64-linux-musl`, static, no runtime dependencies |
| Linux ARM64 | `aarch64-linux-musl`, static, no runtime dependencies |
| macOS Apple Silicon | `aarch64-macos` |
| macOS Intel | `x86_64-macos` |

```sh
sha256sum -c SHA256SUMS --ignore-missing
tar -xzf whetuu-<version>-<target>.tar.gz
mv whetuu ~/.local/bin/
```

Then add one line to your shell config, which [Shell setup](#shell-setup)
covers. That is the whole thing. The installer below does exactly this and
nothing more.

The macOS binaries are unsigned. Download one in a browser and Gatekeeper
quarantines it, so the first run fails with *"cannot be opened because the
developer cannot be verified"*. Clear the flag once with
`xattr -d com.apple.quarantine "$(command -v whetuu)"`. Downloading with `curl`
or `wget` avoids the attribute entirely.

### Run the installer

```sh
curl --proto '=https' --tlsv1.2 -fsSL https://yamafaktory.github.io/whetuu/install.sh | sh
```

It detects your platform, checks the download against the published
`SHA256SUMS`, puts the binary in `~/.local/bin`, and adds the init line to the
config of the shell in `$SHELL`. A `PATH` line joins it only when `~/.local/bin`
is not already on your `PATH`, which on most systems it is. Running it twice
changes nothing.

[Read it first](https://yamafaktory.github.io/whetuu/install.sh) if you would
rather not pipe to a shell, or take the download route above instead. The script
saves you a `uname` and a checksum check. It is not a way to verify anything you
could not verify yourself, and if this repository were compromised the script
would be too.

`WHETUU_NO_MODIFY=1` prints the lines instead of writing them.
`WHETUU_INSTALL_DIR` puts the binary somewhere else, and then the shell config
is left alone.

### Uninstall

```sh
rm ~/.local/bin/whetuu
rm -rf ~/.local/share/whetuu ~/.cache/whetuu
```

Then delete the `# whetuu` block from your shell config. The first line removes
the program. The second removes the history store and the version cache, which
live under the XDG directories rather than next to the binary. Run
`whetuu paths` before you delete anything and it prints both locations, in case
`$XDG_DATA_HOME` or `$XDG_CACHE_HOME` moves them on your machine.

### From source

Needs Zig 0.17 (dev), see `minimum_zig_version` in `build.zig.zon` for the exact
nightly:

```sh
git clone https://github.com/yamafaktory/whetuu.git
cd whetuu
zig build --release=fast
mv zig-out/bin/whetuu ~/.local/bin/
```

Other build steps:

```sh
zig build test         # run the unit tests
zig build check        # type check only
zig build fmt          # format all source files
zig build run          # build and run without installing
```

Maintainers: see [`RELEASING.md`](RELEASING.md) for cutting a release.

## Shell setup

The installer already did this. This section is for a download or source
install, for `WHETUU_NO_MODIFY=1`, or for a shell whose config it could not
find.

Add the matching line to your shell config, then restart the shell. Add
`~/.local/bin` to your `PATH` first if it is not there already:

**fish** — `~/.config/fish/config.fish`
```fish
whetuu init fish | source
```

**bash** — `~/.bashrc` (needs bash 5 or newer for command timing)
```bash
eval "$(whetuu init bash)"
```

**zsh** — `~/.zshrc`
```zsh
eval "$(whetuu init zsh)"
```

`whetuu init <shell>` prints the integration script. The shell hook then calls
`whetuu prompt …` on every prompt, passing the last exit status, the command
duration, and the terminal width.

Run `whetuu init <shell>` by hand and it prints the line above instead, with the
file it belongs in. Several hundred lines of shell answer nothing when you are
looking at a terminal. Pipe or substitute it, as the lines above do, and you get
the script. `whetuu init fish | less` reads it.

## Usage

Day to day there is nothing to run. The shell hook drives everything, and the
history picker is on the up arrow. The full command surface:

| Command | Does |
|---|---|
| `whetuu` | Print the command list |
| `whetuu --version` | Print the version |
| `whetuu init <fish\|bash\|zsh>` | Print the shell integration script, meant to be `source`d or `eval`ed. Prints the setup line instead when run straight into a terminal |
| `whetuu prompt` | Render one prompt. Called by the shell hook, not by you |
| `whetuu history` | Open the interactive history picker |
| `whetuu history add -- <command>` | Record a finished command. Called by the shell hook |
| `whetuu paths` | Print where the history store and version cache live, and whether each file exists yet |

`prompt` and `history add` take flags that only the init scripts pass, namely
exit status, duration and width. That is why they are left out here.

`whetuu paths` marks a file that is not there yet rather than hiding it. A fresh
install has neither until the first command is recorded and the first toolchain
version is cached. With neither `$HOME` nor the matching XDG variable set it says
so, because then whetuu has nowhere to write.

## History

whetuu keeps its own command history. It is one file, shared by all three
shells, at `~/.local/share/whetuu/history`. It moves under `$XDG_DATA_HOME` when
that variable is set. macOS uses the same path rather than `~/Library`, so the
store stays put when you share a dotfiles setup across machines.

A command is recorded once it finishes, and only when it exited with status 0.
Typos and failed runs never enter the store. Prefix a command with a space to
keep it out of the store entirely. Every command is stored together with the
directory it ran in.

The command that just broke is not lost. When a command does not exit 0, it
appears at the top of the picker, in red. Pick it to fix and run it again.
Cancel and it is still there the next time you open the picker. It lives in
memory until you run another command, and never reaches the store.

All three integrations bind the **up arrow** to the picker. Anything already
typed on the command line carries over into the search field. The picker opens
on the current directory's history, which is the set of commands you actually
run in this project. It falls back to all history when the directory has none
yet. A bar at the top names both scopes and highlights the active one, like
`~/dev/whetuu | all`.

- **type to filter** — every word must match, ignoring case
- **↑ / ↓** — move the selection, where ↑ goes further back in time
- **Ctrl+G** — switch between this directory's history and all history
- **Tab** — copy the selected command into the search field, with a trailing
  space, so you can edit it or append flags before running
- **Enter** — run the selected command. When nothing matches the search text any
  more, say after you added a flag, it runs the text as typed
- **Esc / Ctrl-C** — cancel, leaving whatever you had typed on the command line

The picker behaves the same in all three shells.

The list grows upward from the bottom. The most recent command sits just above
the search line and older ones climb from there. Each row is prefixed with how
long ago it ran, like `5m`, `2h` or `3d`. The selected row is highlighted across
the full width in the prompt's star purple.

Commands are syntax highlighted. The program name, flags, paths, variables,
quoted strings and operators each get their own color, so a long row reads at a
glance. The colors come from your terminal theme rather than from whetuu, so the
picker matches the palette you already run. The selected row switches to lighter
tints of the same colors, which stay readable on the purple.

Paths are recognized by how they are written, like `/tmp/out`, `./build` or
`~/dev`. A bare `src` stays plain. whetuu never touches the filesystem to render
a row, so it cannot know that one is a directory.

A command wider than the terminal loses its middle to a `…` rather than its end.
Both the program name and the tail stay on screen. That is what keeps a run of
commands sharing one long prefix apart, like several `cd <long path> && git …`
entries that differ only in the part a plain cut would drop.

Rows are drawn on one line. Runs of spaces, tabs and newlines each collapse to a
single space, so a command written across several lines stays readable in the
list. This changes the row only. Enter and Tab both give you back the command
exactly as it was recorded.

The picker draws on `/dev/tty`, so nothing but the chosen command reaches
stdout. Duplicates are collapsed per directory, so the same command run in two
projects keeps its own recency in each.

## License

[MIT](LICENSE)
