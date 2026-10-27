# Repository Guidelines

## Project Structure

- `src/main.zig` starts the REPL; `src/root.zig` exposes library modules and imports integrated tests.
- `src/sql/` contains AST, Lexer, Parser, Binder, Planner and tests. The Parser supports the first SQL subset; execution currently covers `CREATE TABLE` and `INSERT`.
- `src/catalog/` stores table schemas in the persistent catalog page; `src/execution/` contains the direct executor; `src/shell/` contains the REPL and dot commands.
- `src/storage/` holds Pager, Record, Table and B+ tree implementation and tests. `src/storage/node_test.zig` is integrated.
- `NOW.md` tracks implementation status; `docs/storage.md` describes page formats and storage behavior; `docs/ai/` contains development advice.

## Build, Test, and Run

Use Zig **0.16.0** (`zig version` prints the version).

- `zig build` builds and installs the executable into `zig-out/`.
- `zig build test` runs tests imported by the library and executable roots.
- `zig build run -- [database-path]` starts the REPL; the default database file is `sqzite.db` in the current directory.
- `zig fmt src/` formats Zig source. Run it on changed files before submitting.

## Coding Style

Follow `zig fmt` output and use Zig 0.16 standard library APIs. Use `PascalCase` for types, `camelCase` for functions, and the existing `snake_case` style for layout constants. Keep storage comments concise and in Chinese to match the storage modules. Database pages are byte arrays: encode multi-byte fields explicitly, and do not persist Zig structs directly.

## Testing

Write behavior-focused Zig `test` blocks with descriptive names. Use `std.testing.tmpDir` for file-backed tests and ensure Pager instances are closed. Add integrated tests through the test import block in `src/root.zig`; run `zig build test` afterward.

## Commits and Pull Requests

No Git history is available here to establish a commit convention. Use a short imperative subject, for example `Add leaf split handling`. Pull requests should summarize behavior changes, list verification commands and results, update `NOW.md` when project status changes, and update `docs/storage.md` when page formats or storage behavior change.
