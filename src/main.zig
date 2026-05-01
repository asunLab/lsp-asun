//! Entry point — CLI flags + LSP stdio mode.

const std = @import("std");
const features = @import("features.zig");
const server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer args.deinit();
    _ = args.skip();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--stdio") or std.mem.eql(u8, arg, "-stdio")) {
            // stdio mode is always used; flag accepted for LSP client compatibility
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-version")) {
            try writeStdout(init.io, "lsp-asun 0.1.0\n");
            return;
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-format")) {
            const src = try readStdin(init.io, alloc);
            defer alloc.free(src);
            const out = try features.format(src, alloc);
            defer alloc.free(out);
            try writeStdout(init.io, out);
            return;
        } else if (std.mem.eql(u8, arg, "--compress") or std.mem.eql(u8, arg, "-compress")) {
            const src = try readStdin(init.io, alloc);
            defer alloc.free(src);
            const out = try features.compress(src, alloc);
            defer alloc.free(out);
            try writeStdout(init.io, out);
            return;
        } else if (std.mem.eql(u8, arg, "--to-json") or std.mem.eql(u8, arg, "-to-json")) {
            const src = try readStdin(init.io, alloc);
            defer alloc.free(src);
            const out = features.asunToJson(src, alloc) catch |err| {
                std.debug.print("error: {}\n", .{err});
                std.process.exit(1);
            };
            defer alloc.free(out);
            try writeStdout(init.io, out);
            return;
        } else if (std.mem.eql(u8, arg, "--from-json") or std.mem.eql(u8, arg, "-from-json")) {
            const src = try readStdin(init.io, alloc);
            defer alloc.free(src);
            const out = features.jsonToAsun(src, alloc) catch |err| {
                std.debug.print("error: {}\n", .{err});
                std.process.exit(1);
            };
            defer alloc.free(out);
            try writeStdout(init.io, out);
            return;
        }
    }

    // Default: run LSP server over stdio
    var srv = server.Server.init(alloc, init.io);
    defer srv.deinit();
    try srv.run();
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.writeStreamingAll(.stdout(), io, bytes);
}

fn readStdin(io: std.Io, alloc: std.mem.Allocator) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    var file_buf: [4096]u8 = undefined;
    var file_reader = std.Io.File.stdin().readerStreaming(io, &file_buf);
    while (true) {
        var buf: [4096]u8 = undefined;
        const n = try file_reader.interface.readSliceShort(&buf);
        if (n == 0) break;
        if (out.items.len + n > (1 << 24)) return error.StreamTooLong;
        try out.appendSlice(buf[0..n]);
    }
    return out.toOwnedSlice();
}
