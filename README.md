# 🌟 whetū

[![CI](https://github.com/yamafaktory/whetuu/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/yamafaktory/whetuu/actions/workflows/ci.yml)
[![version](https://img.shields.io/github/v/release/yamafaktory/whetuu?sort=semver&display_name=tag&label=version)](https://github.com/yamafaktory/whetuu/releases/latest)
[![license](https://img.shields.io/github/license/yamafaktory/whetuu)](LICENSE)

A shell prompt for fish, bash and zsh, written in Zig 0.17.

*whetū* is Māori for "star". A star is the default prompt character, using the
Nerd Font glyph `nf-md-star_face`. The binary is installed as `whetuu`.

Pronounced **FEH-too** (`/ˈfɛ.tuː/`). Stress the first syllable. In Māori `wh`
is an *f* sound, not a *w*. The macron in `ū` makes that vowel long, which is
why the ASCII spelling doubles it.

There is nothing to configure. One compiled binary renders one curated prompt,
the same for everyone. Every module runs at the same time via `std.Io`, so a
render costs about what its slowest probe costs. See [Performance](#performance).

> **Requires a [Nerd Font](https://www.nerdfonts.com/).** The prompt uses Nerd
> Font glyphs for the git branch, language logos, and the prompt character.
> Without one those glyphs show as tofu boxes.

![A terminal session. The prompt tracks the branch, git status and toolchain
version. The history picker then filters and runs a command](docs/demo.gif)

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
with the toolchain version cache warm:

| Directory | Render | For comparison |
|---|---|---|
| No repo, no toolchain | **3.7 ms** ± 1.0 | — |
| Zig repo, 33 files | **6.2 ms** ± 3.1 | `zig version` alone: 8.5 ms |
| Monorepo, 8079 files | **33.2 ms** ± 7.5 | `git status` alone: 32.6 ms |

Two things do most of the work. Modules overlap, so a render costs about what
its slowest probe costs rather than the sum of all of them. In the monorepo the
whole prompt takes about as long as `git status` on its own.

Toolchain versions are also cached, keyed on the binary path, mtime and size.
That is why the Zig repo renders faster than a single `zig version` call. The
first prompt in a project pays for the probe. Later ones read a small file
instead. Upgrading a toolchain changes its mtime, which drops the stale entry.

Reproduce it with:

```sh
hyperfine --warmup 40 --runs 400 \
  'whetuu prompt --shell fish --status 0 --duration-ms 0 --width 100'
```

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
- **No config file.** So there is no config parser, and nothing in your dotfiles
  for another tool to write to. whetuu writes two files. One is the history
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

Prebuilt binaries are on the
[releases page](https://github.com/yamafaktory/whetuu/releases):

| Platform | Target |
|---|---|
| Linux x86-64 | `x86_64-linux-musl`, static, no runtime dependencies |
| Linux ARM64 | `aarch64-linux-musl`, static, no runtime dependencies |
| macOS Apple Silicon | `aarch64-macos` |
| macOS Intel | `x86_64-macos` |

Download the tarball for your platform, unpack it, and move the binary to any
directory on your `PATH`:

```sh
tar -xzf whetuu-<version>-<target>.tar.gz
sudo mv whetuu /usr/local/bin/
```

Every release also ships a `SHA256SUMS` file, if you want to verify the
download.

> **macOS: the binaries are unsigned.** Download the tarball in a browser and
> Gatekeeper quarantines it. The first run then fails with *"cannot be opened
> because the developer cannot be verified"*. Clear the flag once:
>
> ```sh
> xattr -d com.apple.quarantine "$(command -v whetuu)"
> ```
>
> Downloading with `curl` or `wget` avoids the quarantine attribute entirely.

Check it worked. Running `whetuu` with no arguments prints the command list:

```sh
whetuu
whetuu --version
```

Then wire it into your shell. See [Shell setup](#shell-setup).

### From source

Needs Zig 0.17 (dev). See `minimum_zig_version` in `build.zig.zon` for the exact
nightly.

```sh
git clone https://github.com/yamafaktory/whetuu.git
cd whetuu
zig build -Doptimize=ReleaseFast
sudo mv zig-out/bin/whetuu /usr/local/bin/
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

Add the matching line to your shell config, then restart the shell:

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

## Usage

Day to day there is nothing to run. The shell hook drives everything, and the
history picker is on the up arrow. The full command surface:

| Command | Does |
|---|---|
| `whetuu` | Print the command list |
| `whetuu --version` | Print the version |
| `whetuu init <fish\|bash\|zsh>` | Print the shell integration script, meant to be `source`d or `eval`ed |
| `whetuu prompt` | Render one prompt. Called by the shell hook, not by you |
| `whetuu history` | Open the interactive history picker |
| `whetuu history add -- <command>` | Record a finished command. Called by the shell hook |

`prompt` and `history add` take flags that only the init scripts pass, namely
exit status, duration and width. That is why they are left out here.

## History

whetuu keeps its own command history. It is one file, shared by all three
shells, at `~/.local/share/whetuu/history`. It moves under `$XDG_DATA_HOME` when
that variable is set. macOS uses the same path rather than `~/Library`, so the
store stays put when you share a dotfiles setup across machines.

A command is recorded once it finishes, and only when it exited with status 0.
Typos and failed runs never clutter the picker. Prefix a command with a space to
keep it out of the store entirely. Every command is stored together with the
directory it ran in.

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

The picker draws on `/dev/tty`, so nothing but the chosen command reaches
stdout. Duplicates are collapsed per directory, so the same command run in two
projects keeps its own recency in each.

## License

[MIT](LICENSE)
