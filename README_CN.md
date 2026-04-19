# lsp-asun

`lsp-asun` 是 ASUN 的 Zig 版语言服务器，同时也是编辑器相关能力的公共运行时，包括格式化、压缩以及 ASUN/JSON 双向转换。

它遵循当前 ASUN 语法：标量类型提示使用 `@`，复杂字段保留 `@{...}` / `@[...]` 结构支架。

## 作用

- 通过 stdio 运行标准 LSP 服务
- 输出语法解析与语义分析诊断信息
- 提供悬停、补全、语义高亮和 Inlay Hints
- 对 ASUN 文档进行格式化和压缩
- 支持 ASUN 转 JSON、JSON 转 ASUN
- 提供可用于浏览器或嵌入场景的 WASM 构建产物

## 当前支持的能力

原生 LSP 服务当前支持：

- `textDocument/didOpen`
- `textDocument/didChange`
- `textDocument/didClose`
- `textDocument/hover`
- `textDocument/completion`
- `textDocument/formatting`
- `textDocument/semanticTokens/full`
- `textDocument/inlayHint`
- `workspace/executeCommand`

VS Code 插件当前会通过 `workspace/executeCommand` 调用这些命令：

- `asun.compress`
- `asun.toJSON`
- `asun.fromJSON`

## 环境要求

- Zig `0.15.0` 或更高版本

最低 Zig 版本来自 `build.zig.zon`。

## 构建

构建当前平台的本地二进制：

```bash
cd lsp-asun
zig build
```

输出位置：

```text
zig-out/bin/lsp-asun
```

构建优化后的发布版本：

```bash
zig build --release=safe
```

交叉编译到其他目标平台：

```bash
zig build -Dtarget=x86_64-linux --release=safe
zig build -Dtarget=aarch64-macos --release=safe
```

## 运行

如果没有传入转换类参数，程序默认以 stdio 模式启动 LSP 服务。

```bash
./zig-out/bin/lsp-asun
```

也可以显式传入兼容参数：

```bash
./zig-out/bin/lsp-asun --stdio
```

查看版本：

```bash
./zig-out/bin/lsp-asun --version
```

## 命令行工具模式

这个二进制也可以作为过滤器使用：从 stdin 读入内容，处理后写到 stdout。

格式化：

```bash
printf '%s\n' '{name@str,age@int}:(Alice,30)' | ./zig-out/bin/lsp-asun --format
```

压缩：

```bash
printf '%s\n' '{name@str, age@int}:\n  (Alice, 30)' | ./zig-out/bin/lsp-asun --compress
```

ASUN 转 JSON：

```bash
printf '%s\n' '{name@str,age@int}:(Alice,30)' | ./zig-out/bin/lsp-asun --to-json
```

JSON 转 ASUN：

```bash
printf '%s\n' '{"name":"Alice","age":30}' | ./zig-out/bin/lsp-asun --from-json
```

## 测试

运行单元测试和集成风格测试：

```bash
cd lsp-asun
zig build test
```

## WASM 构建

构建 WebAssembly 产物：

```bash
cd lsp-asun
zig build wasm
```

预期输出：

```text
zig-out/wasm/asun-lsp.wasm
```

本地可执行文件名是 `lsp-asun`，而当前 WASM 产物文件名仍然是 `asun-lsp.wasm`。

WASM 目标当前暴露这些能力：

- 校验
- 格式化
- 压缩
- ASUN 转 JSON
- JSON 转 ASUN
- 基础补全

## 与 VS Code 插件的关系

`../plugin_vscode` 下的扩展会通过 stdio 启动这个二进制。常见打包流程通常是：

1. 构建 `lsp-asun`
2. 把二进制复制到 `plugin_vscode/server/`
3. 扩展宿主进程用 `-stdio` 启动它

插件还会通过 `workspace/executeCommand` 调用：

- `asun.compress`
- `asun.toJSON`
- `asun.fromJSON`

## 目录结构

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

## 说明

- 默认传输方式就是 stdio。
- 诊断信息同时包含解析错误和语义检查结果。
- 这个目录是 Zig 版 LSP 的主实现目录，编辑器打包时应把这里视为 `lsp-asun` 二进制的来源。
- 当前 WASM 输出文件名仍然是 `asun-lsp.wasm`，和本地可执行文件名不完全一致。
