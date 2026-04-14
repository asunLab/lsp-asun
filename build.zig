const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    // ── Native LSP binary ──────────────────────────────────────────────────
    const src_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "lsp-asun",
        .root_module = src_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run asun-lsp");
    run_step.dependOn(&run_cmd.step);

    // ── Tests ──────────────────────────────────────────────────────────────
    // Build a module graph so all @import("parser.zig") / @import("lexer.zig")
    // resolve to the SAME module instance and don't produce type mismatches.
    const lexer_mod = b.createModule(.{
        .root_source_file = b.path("src/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });
    const parser_mod = b.createModule(.{
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser_mod.addImport("lexer.zig", lexer_mod);

    const features_mod = b.createModule(.{
        .root_source_file = b.path("src/features.zig"),
        .target = target,
        .optimize = optimize,
    });
    features_mod.addImport("lexer.zig", lexer_mod);
    features_mod.addImport("parser.zig", parser_mod);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/lsp_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("lexer", lexer_mod);
    test_mod.addImport("parser", parser_mod);
    test_mod.addImport("features", features_mod);
    const lib_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // ── WASM build ─────────────────────────────────────────────────────────
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const wasm = b.addExecutable(.{
        .name = "asun-lsp",
        .root_module = wasm_mod,
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    // Install WASM to zig-out/wasm/
    const wasm_install = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });
    const wasm_step = b.step("wasm", "Build WASM module");
    wasm_step.dependOn(&wasm_install.step);
}
