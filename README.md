# 🌟 whetū

*whetū* is Māori for "star" — fitting, since a star (the Nerd Font glyph
`nf-md-star_face`) is the default prompt character. The binary is installed as
the ASCII command `whetuu`.

Pronounced **FEH-too** (`/ˈfɛ.tuː/`) — stress the first syllable. In Māori `wh`
is an *f* sound, not a *w*, and the macron in `ū` makes that vowel long, which
is why the ASCII spelling doubles it: `whetuu`.

An opinionated, **zero-config** cross-shell prompt written in Zig 0.17.

There is nothing to configure: a single compiled binary renders one curated
prompt, the same for everyone. Every module runs concurrently via `std.Io`
(`Io.async` → `Future`, backed by `Io.Threaded`), so a full render — including a
`git` call and a toolchain version probe — completes in a few milliseconds.

> **Requires a [Nerd Font](https://www.nerdfonts.com/).** The prompt uses Nerd
> Font glyphs for the git branch, language logos, and the prompt character.
> Without one those glyphs show as tofu boxes.

## Modules

Left to right, each shown only when relevant:

| Module        | Shows                                                                       |
|---------------|-----------------------------------------------------------------------------|
| `user_host`   | `user@host` in bold green — only over SSH (`$SSH_CONNECTION`/`$SSH_TTY`) or when root (then bold red as a warning) |
| `directory`   | Current directory, `$HOME` collapsed to `~`; keeps the anchor + as many trailing dirs as fit the width (`~/…/projects/client`) |
| `git` branch  | Branch glyph + current branch (or `(detached)`), in magenta                 |
| `git` state   | In-progress operation in yellow while one is underway: `(rebasing 2/7)`, `(merging)`, `(cherry-picking)`, `(reverting)`, `(bisecting)` — read straight from `.git`, no extra subprocess |
| `git` status  | `[=conflicts $stashes +staged !modified ?untracked ⇡ahead ⇣behind]`         |
| `language`    | Logo + toolchain version in the brand color — 39 languages & tools, detected from a project manifest (`Cargo.toml`, `mix.exs`, …), a source-file extension (`*.odin`, `*.rkt`, …), or an infra marker (`flake.nix`, `Dockerfile`, `*.tf` for Terraform/OpenTofu) |
| `cmd_duration`| Timer glyph + `<time>` when the last command ran ≥ 2 s                      |
| `character`   | A star, purple by default or in the project's language brand color — forced red after a failed command |

## Install

Prebuilt binaries are published on the
[releases page](https://github.com/yamafaktory/whetuu/releases) for:

| Platform | Target |
|---|---|
| Linux x86-64 | `x86_64-linux-musl` (static, no runtime dependencies) |
| Linux ARM64 | `aarch64-linux-musl` (static, no runtime dependencies) |
| macOS Apple Silicon | `aarch64-macos` |
| macOS Intel | `x86_64-macos` |

Download the tarball for your platform, unpack it, and move the binary to any
directory on your `PATH`:

```sh
tar -xzf whetuu-<version>-<target>.tar.gz
sudo mv whetuu /usr/local/bin/
```

Each release also ships a `SHA256SUMS` file if you want to verify the download.

> **macOS: the binaries are unsigned.** If you download the tarball in a
> browser, Gatekeeper quarantines it and the first run fails with *"cannot be
> opened because the developer cannot be verified"*. Clear the flag once:
>
> ```sh
> xattr -d com.apple.quarantine "$(command -v whetuu)"
> ```
>
> Downloading with `curl` or `wget` avoids the quarantine attribute entirely.

Check it worked — `whetuu` with no arguments prints the command list:

```sh
whetuu
whetuu --version
```

Then wire it into your shell — see [Shell setup](#shell-setup).

### From source

Needs Zig 0.17 (dev) — see `minimum_zig_version` in `build.zig.zon` for the
exact nightly.

```sh
git clone https://github.com/yamafaktory/whetuu.git
cd whetuu
zig build -Doptimize=ReleaseFast
sudo mv zig-out/bin/whetuu /usr/local/bin/
```

Other build steps:

```sh
zig build test         # run the unit tests
zig build check        # type-check only
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

**bash** — `~/.bashrc` (needs bash 5+ for command timing)
```bash
eval "$(whetuu init bash)"
```

**zsh** — `~/.zshrc`
```zsh
eval "$(whetuu init zsh)"
```

`whetuu init <shell>` prints the integration script; the shell hook calls
`whetuu prompt …` on every prompt, passing the last exit status, command
duration, and terminal width.

## Usage

Day to day there is nothing to run: the shell hook drives everything, and the
only command you invoke by hand is the history picker (bound to **up-arrow**
under fish). The full command surface:

| Command | Does |
|---|---|
| `whetuu` | Print the command list |
| `whetuu --version` | Print the version |
| `whetuu init <fish\|bash\|zsh>` | Print the shell integration script — meant to be `source`d / `eval`ed |
| `whetuu prompt` | Render one prompt; called by the shell hook, not by you |
| `whetuu history` | Open the interactive history picker |
| `whetuu history add -- <command>` | Record a finished command; called by the shell hook |

`prompt` and `history add` take flags that only the init scripts pass (exit
status, duration, width), which is why they're omitted here.

## History

whetuu keeps its own command history — a single, deduplicated, cross-shell
store at `$XDG_DATA_HOME/whetuu/history` (or `~/.local/share/whetuu/history`).
macOS uses that same XDG path rather than `~/Library`, so the store stays put
when a dotfiles setup is shared across machines.
Commands are recorded after they finish and only when they exited with status
0, so typos and failed runs never clutter the picker. Each command is recorded
together with the directory it ran in.
The fish integration records every command there and binds **up-arrow** to an
interactive picker; anything already typed on the command line carries over
into the picker's search field. The picker opens scoped to the **current
directory's history** — the commands you actually run in this project — and
falls back to all history when the directory has none yet. A bar at the top of
the screen shows both scopes with the active one highlighted —
`~/dev/whetuu | all`:

- **type to filter** — each space-separated word must match (case-insensitive)
- **↑ / ↓** — move the selection (↑ goes further back in time)
- **Ctrl+G** — toggle the scope between this directory's history and all
  history
- **Tab** — copy the selected command into the search field (plus a trailing
  space) to edit it or append flags before running
- **Enter** — run the chosen command immediately; when nothing matches the
  search text anymore (e.g. after adding new flags), run the text as typed
- **Esc / Ctrl-C** — cancel

The list is bottom-anchored: the most recent command sits just above the search
line, older commands climb upward, each prefixed with how long ago it ran
(`5m`, `2h`, `3d`). The selected row is highlighted full-width in the
prompt's star purple. The picker draws on `/dev/tty`, so nothing but the chosen
command reaches stdout. Duplicates are collapsed per directory, so the same
command run in two projects keeps its own recency in each; there is no
configuration. All three shells (fish, bash, zsh) record into the shared store.
