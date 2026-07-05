# whetū

*whetū* is Māori for "star" — fitting, since a star is the default prompt
character. The binary is installed as the ASCII command `whetuu`.

An opinionated, **zero-config** cross-shell prompt written in Zig 0.17.

There is nothing to configure: a single compiled binary renders one curated
prompt, the same for everyone. Every module runs concurrently via `std.Io`
(`Io.async` → `Future`, backed by `Io.Threaded`), so a full render — including a
`git` call and a toolchain version probe — completes in a few milliseconds.

```
~/dev/lsnav ·  main [!4] ·  v0.17.0 · ⏱ 5.0s
 (star, in Zig orange)
```

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
