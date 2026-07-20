# whetū

An opinionated, zero-config, async cross-shell prompt (fish/bash/zsh) in Zig 0.17.
The binary is installed as the ASCII command `whetuu` (whetū is Māori for "star").

The prompt format and module set are hardcoded — there is intentionally no config
file. A single compiled binary renders the whole prompt by running every module
concurrently via `std.Io` (`Io.async` → `Future`, backed by `Io.Threaded`).

## Working approach

- Before writing any code, identify unclear or ambiguous requirements and ask about them. The goal is a complete picture of the task before implementation begins.
- When adding or changing code, look for opportunities to extract reusable helpers and avoid duplication. Shared logic belongs in a single place (e.g. escape-wrapping lives only in `style.zig`).
- When fixing a bug, add a test that would have caught it to prevent regression.

## Zig Style

Follow Zig master's own conventions: the official Style Guide in the language
reference plus the practices observed in current `std`. Where the two conflict
with personal habit, Zig wins.

### Naming

- camelCase for functions and methods; TitleCase for types and for functions
  that return a `type`; snake_case for everything else (variables, parameters,
  constants, namespaces).
- Acronyms and initialisms follow the same casing rules as ordinary words
  (`readU32Be`, `XmlParser`), even two-letter ones.
- Avoid filler words in type names: `Value`, `Data`, `Context`, `Manager`,
  `State`, `utils`, `misc`. Everything is a value and all logic manages state —
  such words communicate nothing.
- Choose names based on the fully-qualified namespace and avoid redundant
  segments (`json.Value`, not `json.JsonValue`).
- No underscore prefixes. Prefer verbose names at outer scopes and abbreviated
  names at inner scopes.
- Method receivers are short names derived from the type (`w: *Writer`,
  `env: Env`, `list: *DoublyLinkedList`) — never `self`.
- File names: a file that is a struct with top-level fields is `TitleCase.zig`;
  a namespace file is `snake_case.zig`. Directories are snake_case.
- prefer `const foo: Type = .{ .field = value };` and decl literals
  (`.empty`, `.init`) over `const foo = Type{ … };`
- pass allocators explicitly; use `errdefer` for cleanup on error
- when an import property is referenced more than once in a file (e.g.
  `std.os.linux.errno`), introduce a file-scope or local `const` alias and use
  it throughout instead of repeating the dotted path
- use underscores as digit separators in integer literals with 4 or more digits
  (e.g. `1_000`, `2_000`)

### Control flow

- Use early return (or early `continue` inside loops) to guard against the non-primary case and keep the main path at the lowest nesting level. Prefer `if (!condition) return;` over `if (condition) { … }` when the body is the rest of the function or loop iteration. The same applies to `if/else`: when one branch is short and the other is the main path, put the short case first with an exit so the main body is un-nested. When `return`/`continue` are not available mid-function, use a Zig labeled block (`label: { if (guard) break :label; … }`).
- Expand long `if/else if` chains to block form rather than one-liners.

### Layout

- `zig fmt` is authoritative: 4-space indent, braces on the same line, aim for
  100 columns. Add a trailing comma after the last element of any list longer
  than two so `zig fmt` expands each element to its own line.
- File order: `//!` module doc comment; for a file-as-struct,
  `const TypeName = @This();` named after the type (never `Self`); imports;
  file-scope constants; fields; declarations. `Self` is acceptable only inside
  generic `fn (comptime T: type) type` factories.
- Imports are grouped, not alphabetized: `builtin` (with comptime-derived
  consts), then `std`, then aliases of std declarations
  (`const assert = std.debug.assert;`), then local file imports.
- Order declarations logically, not alphabetically: struct fields in meaning or
  dependency order (`r, g, b`, not `b, g, r`), related functions adjacent, the
  public API reading top-down before its helpers, enum variants in whatever
  order the domain suggests.
- Keep code compact: no systematic blank lines around control flow or before
  `return`. Use a blank line only to separate logical steps within a function.

### Documentation

- `//!` top-level doc comment on every file; `///` on public declarations and
  anything non-obvious. Omit information that is redundant given the name of
  the thing being documented; duplicating a doc comment across similar
  functions is fine.
- Use the word "assume" for invariants whose violation is unchecked illegal
  behavior, and "assert" for invariants checked by a safety check or explicit
  `assert`.
- Comments should explain why, not what.

### Tests

- keep tests inline with the code they cover; register them in `src/main.zig`

## Safety

- Add assertions at API boundaries and state transitions; avoid trivial assertions.
- Keep functions small and push pure computation into helpers.

## After any code change

1. Format: `zig build fmt`
2. Test: `zig build test`
3. Update `README.md` — always re-read it after a change and reconcile it with
   the new behaviour. Anything user-visible (features, flags, keybindings,
   output format, shell integration, storage paths) must be reflected there in
   the same change; also fix any statement the change has made stale. Only
   purely internal refactors leave the README untouched.

`README.md` is for users. It covers installing, shell setup, the commands, and
the history picker. Release and maintenance workflow lives in `RELEASING.md`.
Keep that out of the README, and reconcile it in the same change when the
release targets, build steps, or publishing flow move.

## Prose style

Applies to `README.md`, `RELEASING.md` and this file. Documentation is read once
by someone deciding whether to use whetuu, so it has to be plain.

- Short, simple sentences. One idea each.
- **No semicolons.** Split the sentence, or use a full stop.
- **No hyphenated compounds** in prose: write "no configuration" rather than
  "zero-config", "works across shells" rather than "cross-shell", "type check"
  rather than "type-check". This does not apply to code, flags, file names or
  target triples (`--duration-ms`, `x86_64-linux-musl`, `zig-out`).
- Prefer a full stop to a dash when joining two thoughts.
- Say the thing, then explain it. Do not build up to the point.

## Build steps

- `zig build` — compile
- `zig build check` — type-check without producing an artifact
- `zig build run -- <args>` — compile and run (e.g. `-- prompt --shell fish --status 0`)
- `zig build release` — cross-compile + package a tarball per target into
  `zig-out/release/`; `-Dversion=vX.Y.Z` stamps `whetuu --version`
- `zig build demo` — re-record `docs/demo.cast` and render the README's
  `docs/demo.gif` (see `RELEASING.md`); run it whenever the prompt or picker
  changes visibly
- `zig build bump -- vX.Y.Z` — set `.version` in `build.zig.zon` and nothing else
- `zig build publish -- vX.Y.Z` — cut a release end to end: bump, commit, push
  `main`, wait for CI on that commit, then tag and push the tag (see
  `RELEASING.md`). The tag comes after `--`; `-Dversion` is only for stamping a
  local `release` build.

The published target list lives in `release_targets` in `build.zig`, and both CI
workflows call `zig build release`, so it is the only place a target is named.
