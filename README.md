# lsp-asun

`lsp-asun` is the Zig-based language server for ASUN. It also acts as the shared runtime for editor-facing utilities such as formatting, compression, and ASUN/JSON conversion.

It follows the current ASUN syntax: scalar type hints use `@`, and complex fields keep `@{...}` / `@[...]`.

## What It Does

- Runs a standard Language Server Protocol server over stdio
- Publishes parser and semantic diagnostics
- Provides hover, completion, semantic tokens, and inlay hints
- Formats and compresses ASUN documents
- Converts ASUN to JSON and JSON back to ASUN
- Exposes a WASM build for browser or embedded integrations

## Main Capabilities

The native server currently supports:

- `textDocument/didOpen`
- `textDocument/didChange`
- `textDocument/didClose`
- `textDocument/hover`
- `textDocument/completion`
- `textDocument/formatting`
- `textDocument/semanticTokens/full`
- `textDocument/inlayHint`
- `workspace/executeCommand`

The custom commands used by the VS Code extension are:

- `asun.compress`
- `asun.toJSON`
- `asun.fromJSON`

## Requirements

- Zig `0.15.0` or newer

The minimum Zig version comes from `build.zig.zon`.

## Build

Build the native binary for your current platform:

```bash
cd lsp-asun
zig build
```

Output:

```text
zig-out/bin/lsp-asun
```

Build an optimized release binary:

```bash
zig build --release=safe
```

Cross-compile for another target:

```bash
zig build -Dtarget=x86_64-linux --release=safe
zig build -Dtarget=aarch64-macos --release=safe
```

## Run

If no transform flag is provided, the binary starts the LSP server over stdio.

```bash
./zig-out/bin/lsp-asun
```

You can also pass the compatibility flag explicitly:

```bash
./zig-out/bin/lsp-asun --stdio
```

Check the version:

```bash
./zig-out/bin/lsp-asun --version
```

## CLI Utilities

The same binary can be used as a filter that reads from stdin and writes to stdout.

Format:

```bash
printf '%s\n' '{name@str,age@int}:(Alice,30)' | ./zig-out/bin/lsp-asun --format
```

Compress:

```bash
printf '%s\n' '{name@str, age@int}:\n  (Alice, 30)' | ./zig-out/bin/lsp-asun --compress
```

ASUN to JSON:

```bash
printf '%s\n' '{name@str,age@int}:(Alice,30)' | ./zig-out/bin/lsp-asun --to-json
```

JSON to ASUN:

```bash
printf '%s\n' '{"name":"Alice","age":30}' | ./zig-out/bin/lsp-asun --from-json
```

## Test

Run the unit and integration-style tests:

```bash
cd lsp-asun
zig build test
```

## WASM Build

Build the WebAssembly artifact:

```bash
cd lsp-asun
zig build wasm
```

Expected output:

```text
zig-out/wasm/asun-lsp.wasm
```

The native executable is named `lsp-asun`, while the current WASM artifact is still named `asun-lsp.wasm`.

The WASM target exposes helpers for:

- validation
- formatting
- compression
- ASUN to JSON
- JSON to ASUN
- basic completion

## Integration With The VS Code Extension

The extension under `../plugin_vscode` launches this binary over stdio. In practice, packaging usually works like this:

1. Build `lsp-asun`
2. Copy the binary into `plugin_vscode/server/`
3. Start it from the extension host with `-stdio`

The extension also uses `workspace/executeCommand` to call:

- `asun.compress`
- `asun.toJSON`
- `asun.fromJSON`

## Project Layout

```text
lsp-asun/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig
│   ├── server.zig
│   ├── features.zig
│   ├── analyzer.zig
│   ├── lexer.zig
│   ├── parser.zig
│   └── wasm.zig
└── tests/
    └── lsp_test.zig
```

## Notes

- The default transport is stdio.
- Diagnostics include both parse errors and semantic checks.
- This directory is the canonical place for the Zig LSP implementation; editor packaging should treat it as the source of the `lsp-asun` binary.
- The current WASM output filename is `asun-lsp.wasm`, which differs from the native executable name.
