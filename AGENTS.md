# Repository Guidelines

## Project Structure

- `src/main.zig` contains the executable entry point; `src/root.zig` exposes the library module and imports the integrated tests.
- `src/storage/` holds the Pager and B+ tree implementation plus their tests. `src/storage/node_test.zig` is an interface test draft and is not yet part of the build.
- `docs/storage.md` describes the current page and tree format; `docs/now.md` tracks implementation status; `docs/ai/` contains development advice.

## Build, Test, and Run

Use Zig **0.16.0** (`zig version` prints the version).

- `zig build` builds and installs the executable into `zig-out/`.
- `zig build test` runs tests imported by the library and executable roots.
- `zig build run -- arg1` builds and runs the executable, passing optional arguments.
- `zig fmt src/` formats Zig source. Run it on changed files before submitting.

## Coding Style

Follow `zig fmt` output and use Zig 0.16 standard library APIs. Use `PascalCase` for types, `camelCase` for functions, and the existing `snake_case` style for layout constants. Keep storage comments concise and in Chinese to match the storage modules. Database pages are byte arrays: encode multi-byte fields explicitly, and do not persist Zig structs directly.

## Testing

Write behavior-focused Zig `test` blocks with descriptive names. Use `std.testing.tmpDir` for file-backed tests and ensure Pager instances are closed. Add integrated tests through the test import block in `src/root.zig`; run `zig build test` afterward. The node interface draft currently references methods that are not implemented, so leave it unintegrated until those APIs exist.

## Commits and Pull Requests

No Git history is available here to establish a commit convention. Use a short imperative subject, for example `Add leaf split handling`. Pull requests should summarize behavior changes, list verification commands and results, and update `docs/storage.md` when page formats or storage behavior change.
