# whetū

*whetū* is Māori for "star" — fitting, since a star is the default prompt
character. The binary is installed as the ASCII command `whetuu`.

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
| `directory`   | Current directory, `$HOME` collapsed to `~`; keeps the anchor + as many trailing dirs as fit the width (`~/…/projects/client`) |
| `git` branch  | Branch glyph + current branch (or `(detached)`), in magenta                 |
| `git` status  | `[=conflicts +staged !modified ?untracked ⇡ahead ⇣behind]`                  |
| `language`    | Logo + version (zig, rust, node, python, go), in the brand color            |
| `cmd_duration`| `⏱ <time>` when the last command ran ≥ 2 s                                  |
| `character`   | A star, purple by default or in the project's language brand color — forced red after a failed command |

## Build

Requires Zig 0.17 (dev).

```sh
zig build              # binary at ./zig-out/bin/whetuu
zig build test         # run the unit tests
zig build check        # type-check only
```

Put `whetuu` on your `PATH` (e.g. copy `zig-out/bin/whetuu` somewhere on it).

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

## History

whetuu keeps its own command history — a single, deduplicated, cross-shell
store at `$XDG_DATA_HOME/whetuu/history` (or `~/.local/share/whetuu/history`).
The fish integration records every command there and binds **up-arrow** to an
interactive picker:

- **type to filter** — each space-separated word must match (case-insensitive)
- **↑ / ↓** — move the selection (↑ goes further back in time)
- **Enter** — run the chosen command immediately
- **Esc / Ctrl-C** — cancel

The list is bottom-anchored: the most recent command sits just above the search
line, older commands climb upward, each prefixed with how long ago it ran
(`5 mins ago`, `2 hours ago`). The selected row is highlighted full-width in the
prompt's star purple. The picker draws on `/dev/tty`, so nothing but the chosen
command reaches stdout. Duplicates are collapsed; there is no configuration.
(fish is wired up today; bash/zsh capture is a one-liner away.)
