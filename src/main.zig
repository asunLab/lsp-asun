//! Entry point — CLI flags + LSP stdio mode.

const std = @import("std");
const features = @import("features.zig");
const server = @import("server.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--stdio") or std.mem.eql(u8, arg, "-stdio")) {
            // stdio mode is always used; flag accepted for LSP client compatibility
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-version")) {
            try std.fs.File.stdout().writeAll("lsp-asun 0.1.0\n");
            return;
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-format")) {
            const src = try readStdin(alloc);
            defer alloc.free(src);
            const out = try features.format(src, alloc);
            defer alloc.free(out);
            try std.fs.File.stdout().writeAll(out);
            return;
        } else if (std.mem.eql(u8, arg, "--compress") or std.mem.eql(u8, arg, "-compress")) {
            const src = try readStdin(alloc);
            defer alloc.free(src);
            const out = try features.compress(src, alloc);
            defer alloc.free(out);
            try std.fs.File.stdout().writeAll(out);
            return;
        } else if (std.mem.eql(u8, arg, "--to-json") or std.mem.eql(u8, arg, "-to-json")) {
            const src = try readStdin(alloc);
            defer alloc.free(src);
            const out = features.asunToJson(src, alloc) catch |err| {
                std.debug.print("error: {}\n", .{err});
                std.process.exit(1);
            };
            defer alloc.free(out);
            try std.fs.File.stdout().writeAll(out);
            return;
        } else if (std.mem.eql(u8, arg, "--from-json") or std.mem.eql(u8, arg, "-from-json")) {
            const src = try readStdin(alloc);
            defer alloc.free(src);
            const out = features.jsonToAsun(src, alloc) catch |err| {
                std.debug.print("error: {}\n", .{err});
                std.process.exit(1);
            };
            defer alloc.free(out);
            try std.fs.File.stdout().writeAll(out);
            return;
        }
    }

    // Default: run LSP server over stdio
    var srv = server.Server.init(alloc);
    defer srv.deinit();
    try srv.run();
}

fn readStdin(alloc: std.mem.Allocator) ![]u8 {
    return std.fs.File.stdin().readToEndAlloc(alloc, 1 << 24);
}
