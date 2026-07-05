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

### Naming

- camelCase for functions and methods
- lower-case snake_case for variables, parameters, and constants
- PascalCase for types, structs, and enums
- prefer `const foo: Type = .{ .field = value };` over `const foo = Type{ .field = value };`
- pass allocators explicitly; use `errdefer` for cleanup on error
- when an import property is referenced more than once in a file (e.g. `std.os.linux.errno`), introduce a file-scope or local `const` alias and use it throughout instead of repeating the dotted path
- use underscores as digit separators in integer literals with 4 or more digits (e.g. `1_000`, `2_000`)

### Control flow

- Use early return (or early `continue` inside loops) to guard against the non-primary case and keep the main path at the lowest nesting level. Prefer `if (!condition) return;` over `if (condition) { … }` when the body is the rest of the function or loop iteration. The same applies to `if/else`: when one branch is short and the other is the main path, put the short case first with an exit so the main body is un-nested. When `return`/`continue` are not available mid-function, use a Zig labeled block (`label: { if (guard) break :label; … }`).
- Expand long `if/else if` chains to block form rather than one-liners.

### Layout

- preferred file order: `//!` module doc comment, `const Self = @This();`, imports, `const log = std.log.scoped(...)`
- Sort `@import` declarations alphabetically (std first, then local by filename).
- Sort consecutive `const`/`var` declarations alphabetically (type aliases, file-scope constants, buffer declarations) when their order does not affect semantics.
- Sort struct field declarations alphabetically.
- Sort functions and methods alphabetically within each file or struct.
- Sort enum variants alphabetically; add a trailing comma after the last variant.
- Add a trailing comma after the last element of any multi-element struct, array, or tuple literal so `zig fmt` expands each element to its own line.
- After any control flow block (`if`, `for`, `while`) add a blank line if more code follows in the same scope.
- Before any control flow block (`if`, `for`, `while`) add a blank line if code precedes it in the same scope.
- Add a blank line before a `return` if there is any code before it in the same scope.

### Documentation

- Use Zig doc-comments everywhere: `//!` at the top of every file to describe the module, `///` before every function, type, public constant, and enum variant. Keep plain `//` only for inline notes and section dividers inside function bodies.
- Comments should explain why, not what.

### Tests

- keep tests inline with the code they cover; register them in `src/main.zig`

## Safety

- Add assertions at API boundaries and state transitions; avoid trivial assertions.
- Keep functions small and push pure computation into helpers.

## After any code change

1. Format: `zig build fmt`
2. Test: `zig build test`
3. Update `README.md` if the change affects user-visible behaviour.

## Build steps

- `zig build` — compile
- `zig build check` — type-check without producing an artifact
- `zig build run -- <args>` — compile and run (e.g. `-- prompt --shell fish --status 0`)
