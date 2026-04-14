//! JSON-RPC 2.0 LSP server over stdio.

const std = @import("std");
const ArrayList = std.array_list.Managed;
const parser = @import("parser.zig");
const analyzer = @import("analyzer.zig");
const features = @import("features.zig");

// ── SemanticToken types / modifiers ───────────────────────────────────────────
// Types: keyword=0, type=1, variable=2, string=3, number=4, comment=5, operator=6, parameter=7

const SEM_KEYWORD = 0;
const SEM_TYPE = 1;
const SEM_VARIABLE = 2;
const SEM_STRING = 3;
const SEM_NUMBER = 4;
const SEM_COMMENT = 5;
const SEM_OPERATOR = 6;
const SEM_PARAMETER = 7;

// ── JSON helpers ───────────────────────────────────────────────────────────────

fn jsonStr(alloc: std.mem.Allocator, s: []const u8) !std.json.Value {
    return .{ .string = try alloc.dupe(u8, s) };
}

// ── Document store ─────────────────────────────────────────────────────────────

const Document = struct {
    uri: []u8,
    text: []u8,
};

// ── Server ─────────────────────────────────────────────────────────────────────

pub const Server = struct {
    alloc: std.mem.Allocator,
    initialized: bool = false,
    docs: std.StringHashMap(Document),
    in: std.fs.File,
    out: std.fs.File,
    shutdown_requested: bool = false,

    pub fn init(alloc: std.mem.Allocator) Server {
        return .{
            .alloc = alloc,
            .docs = std.StringHashMap(Document).init(alloc),
            .in = std.fs.File.stdin(),
            .out = std.fs.File.stdout(),
        };
    }

    pub fn deinit(self: *Server) void {
        var it = self.docs.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.value_ptr.uri);
            self.alloc.free(e.value_ptr.text);
        }
        self.docs.deinit();
    }

    // ── I/O ──────────────────────────────────────────────────────────────────

    fn readMessage(self: *Server, arena: std.mem.Allocator) !?[]const u8 {
        var reader = self.in.deprecatedReader();
        // Read headers
        var content_len: usize = 0;
        var buf: [512]u8 = undefined;
        while (true) {
            const line = reader.readUntilDelimiter(&buf, '\n') catch return null;
            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (trimmed.len == 0) break; // blank line after headers
            if (std.mem.startsWith(u8, trimmed, "Content-Length:")) {
                const val = std.mem.trim(u8, trimmed["Content-Length:".len..], " \t");
                content_len = std.fmt.parseInt(usize, val, 10) catch 0;
            }
        }
        if (content_len == 0) return null;
        const body = try arena.alloc(u8, content_len);
        try reader.readNoEof(body);
        return body;
    }

    fn sendRaw(self: *Server, body: []const u8) !void {
        var hdr_buf: [64]u8 = undefined;
        const hdr = try std.fmt.bufPrint(&hdr_buf, "Content-Length: {d}\r\n\r\n", .{body.len});
        try self.out.writeAll(hdr);
        try self.out.writeAll(body);
    }

    fn sendResult(self: *Server, id: std.json.Value, result: std.json.Value, arena: std.mem.Allocator) !void {
        var map = std.json.ObjectMap.init(arena);
        try map.put("jsonrpc", .{ .string = "2.0" });
        try map.put("id", id);
        try map.put("result", result);
        const body = try std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = map }, .{});
        try self.sendRaw(body);
    }

    fn sendError(self: *Server, id: std.json.Value, code: i32, msg: []const u8, arena: std.mem.Allocator) !void {
        var err_map = std.json.ObjectMap.init(arena);
        try err_map.put("code", .{ .integer = code });
        try err_map.put("message", .{ .string = msg });
        var map = std.json.ObjectMap.init(arena);
        try map.put("jsonrpc", .{ .string = "2.0" });
        try map.put("id", id);
        try map.put("error", .{ .object = err_map });
        const body = try std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = map }, .{});
        try self.sendRaw(body);
    }

    fn sendNotification(self: *Server, method: []const u8, params: std.json.Value, arena: std.mem.Allocator) !void {
        var map = std.json.ObjectMap.init(arena);
        try map.put("jsonrpc", .{ .string = "2.0" });
        try map.put("method", .{ .string = method });
        try map.put("params", params);
        const body = try std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = map }, .{});
        try self.sendRaw(body);
    }

    // ── Main loop ─────────────────────────────────────────────────────────────

    pub fn run(self: *Server) !void {
        while (!self.shutdown_requested) {
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const a = arena.allocator();

            const body = self.readMessage(a) catch break orelse break;
            const parsed = std.json.parseFromSlice(std.json.Value, a, body, .{}) catch continue;
            const msg = parsed.value;
            if (msg != .object) continue;
            const obj = msg.object;

            const method_val = obj.get("method") orelse continue;
            const method = if (method_val == .string) method_val.string else continue;
            const id = obj.get("id") orelse .null;
            const params = obj.get("params") orelse .null;

            self.dispatch(method, id, params, a) catch |err| {
                std.log.err("dispatch error: {}", .{err});
                self.sendError(id, -32603, "internal error", a) catch {};
            };
        }
    }

    fn dispatch(self: *Server, method: []const u8, id: std.json.Value, params: std.json.Value, a: std.mem.Allocator) !void {
        if (std.mem.eql(u8, method, "initialize")) {
            try self.handleInitialize(id, params, a);
        } else if (std.mem.eql(u8, method, "initialized")) {
            // no-op
        } else if (std.mem.eql(u8, method, "shutdown")) {
            self.shutdown_requested = true;
            try self.sendResult(id, .null, a);
        } else if (std.mem.eql(u8, method, "exit")) {
            std.process.exit(0);
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try self.handleDidOpen(params, a);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try self.handleDidChange(params, a);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            try self.handleDidClose(params);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try self.handleHover(id, params, a);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            try self.handleCompletion(id, params, a);
        } else if (std.mem.eql(u8, method, "textDocument/formatting")) {
            try self.handleFormatting(id, params, a);
        } else if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
            try self.handleSemanticTokens(id, params, a);
        } else if (std.mem.eql(u8, method, "textDocument/inlayHint")) {
            try self.handleInlayHint(id, params, a);
        } else if (std.mem.eql(u8, method, "asun/cursorInfo")) {
            try self.handleCursorInfo(id, params, a);
        } else if (std.mem.eql(u8, method, "workspace/executeCommand")) {
            try self.handleExecuteCommand(id, params, a);
        } else {
            // Unknown method — send null result for requests, ignore notifications
            if (id != .null) try self.sendResult(id, .null, a);
        }
    }

    // ── Handlers ──────────────────────────────────────────────────────────────

    fn handleInitialize(self: *Server, id: std.json.Value, _params: std.json.Value, a: std.mem.Allocator) !void {
        _ = _params;
        self.initialized = true;
        // Build capabilities
        var caps = std.json.ObjectMap.init(a);

        // TextDocumentSync=1 (full)
        try caps.put("textDocumentSync", .{ .integer = 1 });

        // Completion
        var comp_obj = std.json.ObjectMap.init(a);
        var triggers = std.json.Array.init(a);
        for ([_][]const u8{ ":", "{", "[", "(", "," }) |t| {
            try triggers.append(.{ .string = t });
        }
        try comp_obj.put("triggerCharacters", .{ .array = triggers });
        try caps.put("completionProvider", .{ .object = comp_obj });

        try caps.put("hoverProvider", .{ .bool = true });
        try caps.put("documentFormattingProvider", .{ .bool = true });
        try caps.put("inlayHintProvider", .{ .bool = true });

        // SemanticTokens — full only
        var sem_obj = std.json.ObjectMap.init(a);
        var sem_legend = std.json.ObjectMap.init(a);
        var tok_types = std.json.Array.init(a);
        for ([_][]const u8{ "keyword", "type", "variable", "string", "number", "comment", "operator", "parameter" }) |t| {
            try tok_types.append(.{ .string = t });
        }
        try sem_legend.put("tokenTypes", .{ .array = tok_types });
        try sem_legend.put("tokenModifiers", .{ .array = std.json.Array.init(a) });
        try sem_obj.put("legend", .{ .object = sem_legend });
        try sem_obj.put("full", .{ .bool = true });
        try caps.put("semanticTokensProvider", .{ .object = sem_obj });

        var result = std.json.ObjectMap.init(a);
        try result.put("capabilities", .{ .object = caps });
        var server_info = std.json.ObjectMap.init(a);
        try server_info.put("name", .{ .string = "lsp-asun" });
        try server_info.put("version", .{ .string = "0.1.0" });
        try result.put("serverInfo", .{ .object = server_info });

        try self.sendResult(id, .{ .object = result }, a);
    }

    fn getUri(params: std.json.Value) []const u8 {
        if (params != .object) return "";
        const td = params.object.get("textDocument") orelse return "";
        if (td != .object) return "";
        const uri = td.object.get("uri") orelse return "";
        return if (uri == .string) uri.string else "";
    }

    fn handleDidOpen(self: *Server, params: std.json.Value, a: std.mem.Allocator) !void {
        if (params != .object) return;
        const td = params.object.get("textDocument") orelse return;
        if (td != .object) return;
        const uri_v = td.object.get("uri") orelse return;
        const text_v = td.object.get("text") orelse std.json.Value{ .string = "" };
        const uri = if (uri_v == .string) uri_v.string else return;
        const text = if (text_v == .string) text_v.string else "";

        const doc = Document{
            .uri = try self.alloc.dupe(u8, uri),
            .text = try self.alloc.dupe(u8, text),
        };
        const result = try self.docs.getOrPut(doc.uri);
        if (result.found_existing) {
            self.alloc.free(result.value_ptr.uri);
            self.alloc.free(result.value_ptr.text);
        }
        result.value_ptr.* = doc;

        try self.publishDiagnostics(uri, text, a);
    }

    fn handleDidChange(self: *Server, params: std.json.Value, a: std.mem.Allocator) !void {
        if (params != .object) return;
        const td = params.object.get("textDocument") orelse return;
        if (td != .object) return;
        const uri_v = td.object.get("uri") orelse return;
        const uri = if (uri_v == .string) uri_v.string else return;
        const changes = params.object.get("contentChanges") orelse return;
        if (changes != .array) return;
        if (changes.array.items.len == 0) return;
        const last = changes.array.items[changes.array.items.len - 1];
        if (last != .object) return;
        const text_v = last.object.get("text") orelse std.json.Value{ .string = "" };
        const text = if (text_v == .string) text_v.string else "";

        if (self.docs.getPtr(uri)) |doc| {
            self.alloc.free(doc.text);
            doc.text = try self.alloc.dupe(u8, text);
        } else {
            const doc = Document{
                .uri = try self.alloc.dupe(u8, uri),
                .text = try self.alloc.dupe(u8, text),
            };
            try self.docs.put(doc.uri, doc);
        }
        try self.publishDiagnostics(uri, text, a);
    }

    fn handleDidClose(self: *Server, params: std.json.Value) !void {
        const uri = getUri(params);
        if (self.docs.fetchRemove(uri)) |kv| {
            self.alloc.free(kv.value.uri);
            self.alloc.free(kv.value.text);
        }
    }

    fn handleHover(self: *Server, id: std.json.Value, params: std.json.Value, a: std.mem.Allocator) !void {
        const uri = getUri(params);
        const doc = self.docs.get(uri) orelse {
            try self.sendResult(id, .null, a);
            return;
        };
        const pos = getPosition(params);

        var presult = try parser.parse(doc.text, a);
        defer presult.deinit();

        const text = try features.hoverInfo(presult.root, pos.line, pos.col, a);
        const info = try features.cursorInfo(presult.root, pos.line, pos.col, a);

        if (text.len == 0 and info == null) {
            try self.sendResult(id, .null, a);
            return;
        }

        const hover_text = blk: {
            if (info) |meta| {
                const summary = try std.fmt.allocPrint(a, "`{s} | {s}`", .{ meta.type_label, meta.path });
                if (text.len == 0) break :blk summary;
                break :blk try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ summary, text });
            }
            break :blk text;
        };

        var contents = std.json.ObjectMap.init(a);
        try contents.put("kind", .{ .string = "markdown" });
        try contents.put("value", .{ .string = hover_text });
        var result = std.json.ObjectMap.init(a);
        try result.put("contents", .{ .object = contents });

        try self.sendResult(id, .{ .object = result }, a);
    }

    fn handleCompletion(self: *Server, id: std.json.Value, params: std.json.Value, a: std.mem.Allocator) !void {
        const uri = getUri(params);
        const doc = self.docs.get(uri) orelse {
            try self.sendResult(id, .{ .array = std.json.Array.init(a) }, a);
            return;
        };
        const pos = getPosition(params);

        var presult = try parser.parse(doc.text, a);
        defer presult.deinit();

        const items = try features.complete(presult.root, pos.line, pos.col, a);
        var arr = std.json.Array.init(a);
        for (items) |item| {
            var obj = std.json.ObjectMap.init(a);
            try obj.put("label", .{ .string = item.label });
            try obj.put("kind", .{ .integer = @intCast(item.kind) });
            try obj.put("detail", .{ .string = item.detail });
            try obj.put("insertText", .{ .string = item.insert_text });
            try arr.append(.{ .object = obj });
        }
        try self.sendResult(id, .{ .array = arr }, a);
    }

    fn handleFormatting(self: *Server, id: std.json.Value, params: std.json.Value, a: std.mem.Allocator) !void {
        const uri = getUri(params);
        const doc = self.docs.get(uri) orelse {
            try self.sendResult(id, .null, a);
            return;
        };

        const formatted = features.format(doc.text, a) catch {
            try self.sendResult(id, .null, a);
            return;
        };

        // Return as a single "replace everything" text edit
        var edit = std.json.ObjectMap.init(a);
        var range = std.json.ObjectMap.init(a);
        var start = std.json.ObjectMap.init(a);
        try start.put("line", .{ .integer = 0 });
        try start.put("character", .{ .integer = 0 });
        var end_pos = std.json.ObjectMap.init(a);
        // Count lines in original
        const line_count = std.mem.count(u8, doc.text, "\n");
        try end_pos.put("line", .{ .integer = @intCast(line_count + 1) });
        try end_pos.put("character", .{ .integer = 0 });
        try range.put("start", .{ .object = start });
        try range.put("end", .{ .object = end_pos });
        try edit.put("range", .{ .object = range });
        try edit.put("newText", .{ .string = formatted });
        var arr = std.json.Array.init(a);
        try arr.append(.{ .object = edit });
        try self.sendResult(id, .{ .array = arr }, a);
    }

    fn handleSemanticTokens(self: *Server, id: std.json.Value, params: std.json.Value, a: std.mem.Allocator) !void {
        const uri = getUri(params);
        const doc = self.docs.get(uri) orelse {
            try self.sendResult(id, .null, a);
            return;
        };

        var lexer = @import("lexer.zig").Lexer.init(doc.text);
        const toks = try lexer.all(a);

        // Encode as LSP relative semantic token data [deltaLine, deltaStart, len, tokenType, tokenMods]
        var data = ArrayList(i64).init(a);
        var prev_line: u32 = 0;
        var prev_col: u32 = 0;
        var schema_depth: usize = 0;
        var expect_schema_field = false;

        for (toks) |tok| {
            const tok_type: ?u32 = switch (tok.kind) {
                .string => if (schema_depth > 0 and expect_schema_field) SEM_VARIABLE else SEM_STRING,
                .number => if (schema_depth > 0 and expect_schema_field) SEM_VARIABLE else SEM_NUMBER,
                .type_hint => SEM_TYPE,
                .ident => SEM_VARIABLE,
                .bool_val => SEM_PARAMETER,
                .comment => SEM_COMMENT,
                .colon, .comma, .at => SEM_OPERATOR,
                else => null,
            };
            if (tok_type == null) continue;

            const dl: i64 = @intCast(tok.line - prev_line);
            const ds: i64 = if (tok.line == prev_line) @intCast(tok.col - prev_col) else @intCast(tok.col);
            const length: i64 = @intCast(tok.end_off - tok.offset);
            try data.append(dl);
            try data.append(ds);
            try data.append(length);
            try data.append(@intCast(tok_type.?));
            try data.append(0); // no modifiers
            prev_line = tok.line;
            prev_col = tok.col;

            switch (tok.kind) {
                .lbrace => {
                    schema_depth += 1;
                    expect_schema_field = true;
                },
                .rbrace => {
                    if (schema_depth > 0) schema_depth -= 1;
                    expect_schema_field = schema_depth > 0;
                },
                .comma => {
                    if (schema_depth > 0) expect_schema_field = true;
                },
                .at => {
                    if (schema_depth > 0) expect_schema_field = false;
                },
                .ident, .string, .number => {
                    if (schema_depth > 0 and expect_schema_field) expect_schema_field = false;
                },
                else => {},
            }
        }

        var arr = std.json.Array.init(a);
        for (data.items) |v| try arr.append(.{ .integer = v });
        var result = std.json.ObjectMap.init(a);
        try result.put("data", .{ .array = arr });
        try self.sendResult(id, .{ .object = result }, a);
    }

    fn handleInlayHint(self: *Server, id: std.json.Value, params: std.json.Value, a: std.mem.Allocator) !void {
        const uri = getUri(params);
        const doc = self.docs.get(uri) orelse {
            try self.sendResult(id, .{ .array = std.json.Array.init(a) }, a);
            return;
        };

        var presult = try parser.parse(doc.text, a);
        defer presult.deinit();

        const hints = try features.inlayHints(presult.root, a);
        var arr = std.json.Array.init(a);
        for (hints) |h| {
            var obj = std.json.ObjectMap.init(a);
            var pos = std.json.ObjectMap.init(a);
            try pos.put("line", .{ .integer = @intCast(h.line) });
            try pos.put("character", .{ .integer = @intCast(h.col) });
            try obj.put("position", .{ .object = pos });
            try obj.put("label", .{ .string = h.label });
            try obj.put("kind", .{ .integer = 1 }); // Type
            try arr.append(.{ .object = obj });
        }
        try self.sendResult(id, .{ .array = arr }, a);
    }

    fn handleCursorInfo(self: *Server, id: std.json.Value, params: std.json.Value, a: std.mem.Allocator) !void {
        const uri = getUri(params);
        const doc = self.docs.get(uri) orelse {
            try self.sendResult(id, .null, a);
            return;
        };
        const pos = getPosition(params);

        var presult = try parser.parse(doc.text, a);
        defer presult.deinit();

        const info = try features.cursorInfo(presult.root, pos.line, pos.col, a);
        if (info == null) {
            try self.sendResult(id, .null, a);
            return;
        }

        var obj = std.json.ObjectMap.init(a);
        try obj.put("path", .{ .string = info.?.path });
        try obj.put("type", .{ .string = info.?.type_label });
        try obj.put("line", .{ .integer = @intCast(info.?.line) });
        try obj.put("character", .{ .integer = @intCast(info.?.col) });
        try self.sendResult(id, .{ .object = obj }, a);
    }

    fn handleExecuteCommand(self: *Server, id: std.json.Value, params: std.json.Value, a: std.mem.Allocator) !void {
        if (params != .object) {
            try self.sendResult(id, .null, a);
            return;
        }
        const cmd_v = params.object.get("command") orelse {
            try self.sendResult(id, .null, a);
            return;
        };
        const cmd = if (cmd_v == .string) cmd_v.string else {
            try self.sendResult(id, .null, a);
            return;
        };
        const args = params.object.get("arguments") orelse .null;

        // Extract first argument as a plain string (URI or raw text).
        // The extension sends arguments[0] as a plain string for all three commands.
        const arg0: []const u8 = blk: {
            if (args == .array and args.array.items.len > 0) {
                const arg = args.array.items[0];
                if (arg == .string) break :blk arg.string;
                // Legacy object form: { uri: "..." }
                if (arg == .object) {
                    if (arg.object.get("uri")) |u| {
                        if (u == .string) break :blk u.string;
                    }
                }
            }
            break :blk @as([]const u8, "");
        };

        if (std.mem.eql(u8, cmd, "asun.compress")) {
            // arg0 = URI of an open ASUN document
            const doc = self.docs.get(arg0) orelse {
                try self.sendResult(id, .null, a);
                return;
            };
            const out = features.compress(doc.text, a) catch {
                try self.sendResult(id, .null, a);
                return;
            };
            try self.sendResult(id, .{ .string = out }, a);
        } else if (std.mem.eql(u8, cmd, "asun.toJSON")) {
            // arg0 = URI of an open ASUN document
            const doc = self.docs.get(arg0) orelse {
                try self.sendResult(id, .null, a);
                return;
            };
            const out = features.asunToJson(doc.text, a) catch {
                try self.sendResult(id, .null, a);
                return;
            };
            try self.sendResult(id, .{ .string = out }, a);
        } else if (std.mem.eql(u8, cmd, "asun.fromJSON")) {
            // arg0 = raw JSON text (sent directly by the extension, not a URI)
            if (arg0.len == 0) {
                try self.sendResult(id, .null, a);
                return;
            }
            const out = features.jsonToAsun(arg0, a) catch {
                try self.sendResult(id, .null, a);
                return;
            };
            try self.sendResult(id, .{ .string = out }, a);
        } else {
            try self.sendResult(id, .null, a);
        }
    }

    // ── Diagnostics ───────────────────────────────────────────────────────────

    fn publishDiagnostics(self: *Server, uri: []const u8, text: []const u8, a: std.mem.Allocator) !void {
        var presult = try parser.parse(text, a);
        defer presult.deinit();

        const sem_diags = try analyzer.analyze(presult.root, a);
        var all_diags = ArrayList(parser.Diag).init(a);
        try all_diags.appendSlice(presult.diags);
        try all_diags.appendSlice(sem_diags);

        var arr = std.json.Array.init(a);
        for (all_diags.items) |d| {
            var obj = std.json.ObjectMap.init(a);
            var range = std.json.ObjectMap.init(a);
            var start = std.json.ObjectMap.init(a);
            var end_p = std.json.ObjectMap.init(a);
            try start.put("line", .{ .integer = @intCast(d.line) });
            try start.put("character", .{ .integer = @intCast(d.col) });
            try end_p.put("line", .{ .integer = @intCast(d.end_line) });
            try end_p.put("character", .{ .integer = @intCast(d.end_col) });
            try range.put("start", .{ .object = start });
            try range.put("end", .{ .object = end_p });
            try obj.put("range", .{ .object = range });
            const sev: i64 = if (d.severity == .err) 1 else if (d.severity == .warning) 2 else 3;
            try obj.put("severity", .{ .integer = sev });
            try obj.put("message", .{ .string = d.message });
            try obj.put("source", .{ .string = "lsp-asun" });
            try arr.append(.{ .object = obj });
        }

        var notif_params = std.json.ObjectMap.init(a);
        try notif_params.put("uri", .{ .string = uri });
        try notif_params.put("diagnostics", .{ .array = arr });
        try self.sendNotification("textDocument/publishDiagnostics", .{ .object = notif_params }, a);
    }
};

// ── Helpers ────────────────────────────────────────────────────────────────────

const Pos = struct { line: u32, col: u32 };

fn getPosition(params: std.json.Value) Pos {
    if (params != .object) return .{ .line = 0, .col = 0 };
    const pos = params.object.get("position") orelse return .{ .line = 0, .col = 0 };
    if (pos != .object) return .{ .line = 0, .col = 0 };
    const l = pos.object.get("line") orelse std.json.Value{ .integer = 0 };
    const c = pos.object.get("character") orelse std.json.Value{ .integer = 0 };
    return .{
        .line = @intCast(if (l == .integer) l.integer else 0),
        .col = @intCast(if (c == .integer) c.integer else 0),
    };
}
