//! LSP features: hover, completion, formatting, inlay hints, JSON conversion.

const std = @import("std");
const ArrayList = std.array_list.Managed;
const parser = @import("parser.zig");
const lex = @import("lexer.zig");
const Node = parser.Node;
const NodeKind = parser.NodeKind;
const Token = lex.Token;
const TK = lex.TokKind;

const ListWriter = struct {
    sb: *ArrayList(u8),

    fn writeAll(self: ListWriter, bytes: []const u8) !void {
        try self.sb.appendSlice(bytes);
    }

    fn writeByte(self: ListWriter, byte: u8) !void {
        try self.sb.append(byte);
    }

    fn print(self: ListWriter, comptime fmt: []const u8, args: anytype) !void {
        const rendered = try std.fmt.allocPrint(self.sb.allocator, fmt, args);
        defer self.sb.allocator.free(rendered);
        try self.writeAll(rendered);
    }
};

fn listWriter(sb: *ArrayList(u8)) ListWriter {
    return .{ .sb = sb };
}

// ── Hover ──────────────────────────────────────────────────────────────────────

pub fn hoverInfo(root: Node, line: u32, col: u32, alloc: std.mem.Allocator) ![]const u8 {
    const n = findNodeAt(root, line, col) orelse return try std.fmt.allocPrint(alloc, "", .{});
    return hoverNode(n, alloc);
}

fn hoverNode(n: Node, alloc: std.mem.Allocator) ![]const u8 {
    switch (n.kind) {
        .field => {
            var sb = ArrayList(u8).init(alloc);
            const w = listWriter(&sb);
            try w.print("**Field** `{s}`", .{n.token.value});
            if (n.children.len > 0) {
                const c = n.children[0];
                switch (c.kind) {
                    .type_annot => try w.print(" @ `{s}`", .{c.token.value}),
                    .schema => try w.writeAll(" @ nested object"),
                    .array_schema => try w.writeAll(" @ object array"),
                    else => {},
                }
            }
            return sb.toOwnedSlice();
        },
        .type_annot => {
            const t = n.token.value;
            if (std.mem.eql(u8, t, "int"))
                return "**Type** `int`\n\nInteger value (e.g., `42`, `-100`)";
            if (std.mem.eql(u8, t, "float"))
                return "**Type** `float`\n\nFloating-point value (e.g., `3.14`)";
            if (std.mem.eql(u8, t, "str"))
                return "**Type** `str`\n\nString value (quoted or unquoted)";
            if (std.mem.eql(u8, t, "bool"))
                return "**Type** `bool`\n\nBoolean: `true` or `false`";
            return try std.fmt.allocPrint(alloc, "**Type** `{s}`", .{t});
        },
        .schema => {
            var sb = ArrayList(u8).init(alloc);
            const w = listWriter(&sb);
            const fields = schemaFields(n);
            try w.print("**Schema** — {d} field(s)\n\n", .{fields.len});
            for (fields) |f| {
                try w.print("- `{s}`", .{f.token.value});
                if (f.children.len > 0 and f.children[0].kind == .type_annot)
                    try w.print(" @ {s}", .{f.children[0].token.value});
                try w.writeAll("\n");
            }
            return sb.toOwnedSlice();
        },
        .tuple => return "**Data Tuple** `(...)`\n\nOrdered values matching the schema fields.",
        .array => return "**Array** `[...]`",
        .value => {
            const t = n.token;
            switch (t.kind) {
                .number => return try std.fmt.allocPrint(alloc, "**Number** `{s}`", .{t.value}),
                .bool_val => return try std.fmt.allocPrint(alloc, "**Boolean** `{s}`", .{t.value}),
                .string => return "**Quoted String**",
                else => {
                    const trimmed = std.mem.trim(u8, t.value, " \t");
                    if (trimmed.len == 0) return "**Null** — empty value";
                    return try std.fmt.allocPrint(alloc, "**String** `{s}`", .{trimmed});
                },
            }
        },
        else => return try std.fmt.allocPrint(alloc, "", .{}),
    }
}

// ── Completion ─────────────────────────────────────────────────────────────────

pub const CompItem = struct {
    label: []const u8,
    kind: u8, // LSP kind: 1=Text 6=Variable 12=Value 14=Keyword 15=Snippet
    detail: []const u8,
    insert_text: []const u8,
};

pub fn complete(root: Node, line: u32, col: u32, alloc: std.mem.Allocator) ![]CompItem {
    const ctx = findContext(root, line, col);
    return switch (ctx) {
        .schema_type => typeCompletions(alloc),
        .schema_field => schemaKwCompletions(alloc),
        .data_value => dataValueCompletions(alloc),
        .top_level => topLevelCompletions(alloc),
        else => &.{},
    };
}

const CompCtx = enum { unknown, schema_type, schema_field, data_value, top_level };

fn findContext(root: Node, line: u32, col: u32) CompCtx {
    const n = findNodeAt(root, line, col) orelse return .top_level;
    return switch (n.kind) {
        .schema => .schema_field,
        .field => .schema_field,
        .type_annot => .schema_type,
        .tuple, .value, .array => .data_value,
        else => .top_level,
    };
}

fn typeCompletions(alloc: std.mem.Allocator) ![]CompItem {
    const items = &[_]CompItem{
        .{ .label = "int", .kind = 14, .detail = "Integer type", .insert_text = "int" },
        .{ .label = "float", .kind = 14, .detail = "Float type", .insert_text = "float" },
        .{ .label = "str", .kind = 14, .detail = "String type", .insert_text = "str" },
        .{ .label = "bool", .kind = 14, .detail = "Boolean type", .insert_text = "bool" },
        .{ .label = "{...}", .kind = 14, .detail = "Nested object schema", .insert_text = "{$1}" },
        .{ .label = "[...]", .kind = 14, .detail = "Array type", .insert_text = "[$1]" },
    };
    const out = try alloc.alloc(CompItem, items.len);
    @memcpy(out, items);
    return out;
}

fn schemaKwCompletions(alloc: std.mem.Allocator) ![]CompItem {
    const items = &[_]CompItem{
        .{ .label = "field", .kind = 6, .detail = "Add a field", .insert_text = "field" },
    };
    const out = try alloc.alloc(CompItem, 1);
    out[0] = items[0];
    return out;
}

fn dataValueCompletions(alloc: std.mem.Allocator) ![]CompItem {
    const out = try alloc.alloc(CompItem, 2);
    out[0] = .{ .label = "true", .kind = 12, .detail = "Boolean true", .insert_text = "true" };
    out[1] = .{ .label = "false", .kind = 12, .detail = "Boolean false", .insert_text = "false" };
    return out;
}

fn topLevelCompletions(alloc: std.mem.Allocator) ![]CompItem {
    const out = try alloc.alloc(CompItem, 3);
    out[0] = .{ .label = "{schema}:(data)", .kind = 15, .detail = "Single object", .insert_text = "{$1}:($2)" };
    out[1] = .{ .label = "[{schema}]:(data)", .kind = 15, .detail = "Object array", .insert_text = "[{$1}]:($2)" };
    out[2] = .{ .label = "[values]", .kind = 15, .detail = "Plain array", .insert_text = "[$1]" };
    return out;
}

// ── Format ─────────────────────────────────────────────────────────────────────

const MAX_LINE = 100;
const INDENT = "    ";
const EXPAND_ALL_CONTAINERS = true;

const CommentAttach = struct {
    anchor: u32,
    trailing: bool,
    text: []const u8,
    used: bool = false,
};

const CommentCtx = struct {
    items: []CommentAttach,

    fn deinit(self: *CommentCtx, alloc: std.mem.Allocator) void {
        alloc.free(self.items);
    }
};

pub fn format(src: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    var result = try parser.parse(src, alloc);
    defer result.deinit();
    var comments = try collectComments(src, alloc);
    defer comments.deinit(alloc);
    var sb = ArrayList(u8).init(alloc);
    try formatNode(result.root, 0, &sb, &comments);
    return sb.toOwnedSlice();
}

fn collectComments(src: []const u8, alloc: std.mem.Allocator) !CommentCtx {
    var lx = lex.Lexer.init(src);
    const toks = try lx.all(alloc);
    defer alloc.free(toks);

    var items = ArrayList(CommentAttach).init(alloc);
    for (toks, 0..) |tok, i| {
        if (tok.kind != .comment) continue;

        var prev: ?Token = null;
        var j = i;
        while (j > 0) {
            j -= 1;
            const t = toks[j];
            if (t.kind == .newline) break;
            if (t.kind == .comment or t.kind == .eof) continue;
            if (!canOwnTrailingComment(t.kind)) continue;
            prev = t;
            break;
        }
        if (prev) |p| {
            try items.append(.{ .anchor = p.end_off, .trailing = true, .text = tok.value });
            continue;
        }

        var next: ?Token = null;
        var k = i + 1;
        while (k < toks.len) : (k += 1) {
            const t = toks[k];
            if (t.kind == .comment or t.kind == .newline or t.kind == .eof) continue;
            next = t;
            break;
        }
        if (next) |n| {
            try items.append(.{ .anchor = n.offset, .trailing = false, .text = tok.value });
        }
    }
    return .{ .items = try items.toOwnedSlice() };
}

fn canOwnTrailingComment(kind: TK) bool {
    return switch (kind) {
        .ident, .type_hint, .string, .number, .bool_val, .plain_str, .rbrace, .rparen, .rbracket => true,
        else => false,
    };
}

fn emitLeadingComments(anchor: u32, lvl: usize, sb: *ArrayList(u8), comments: *CommentCtx) !void {
    const w = listWriter(sb);
    for (comments.items) |*item| {
        if (item.used or item.trailing or item.anchor != anchor) continue;
        try indent(lvl, sb);
        try w.writeAll(item.text);
        try w.writeAll("\n");
        item.used = true;
    }
}

fn emitTrailingComments(anchor: u32, sb: *ArrayList(u8), comments: *CommentCtx) !void {
    const w = listWriter(sb);
    for (comments.items) |*item| {
        if (item.used or !item.trailing or item.anchor != anchor) continue;
        try w.writeAll(" ");
        try w.writeAll(item.text);
        item.used = true;
    }
}

fn lastTokenEnd(n: Node) u32 {
    return switch (n.kind) {
        .field, .schema, .tuple, .array, .array_schema => if (n.children.len > 0) lastTokenEnd(n.children[n.children.len - 1]) else n.token.end_off,
        else => n.token.end_off,
    };
}

fn formatInline(n: Node, sb: *ArrayList(u8), comments: *CommentCtx) !void {
    const w = listWriter(sb);
    switch (n.kind) {
        .schema => {
            try w.writeAll("{");
            for (n.children, 0..) |c, i| {
                if (i > 0) try w.writeAll(", ");
                try formatInline(c, sb, comments);
            }
            try w.writeAll("}");
            try emitTrailingComments(lastTokenEnd(n), sb, comments);
        },
        .field => {
            try w.writeAll(n.token.value);
            if (n.children.len > 0) {
                const c = n.children[0];
                if (c.kind == .type_annot) {
                    try w.print("@{s}", .{c.token.value});
                } else if (c.kind == .schema) {
                    try w.writeAll("@");
                    try formatInline(c, sb, comments);
                } else if (c.kind == .array_schema) {
                    try w.writeAll("@[");
                    if (c.children.len > 0) try formatInline(c.children[0], sb, comments);
                    try w.writeAll("]");
                }
            }
            try emitTrailingComments(lastTokenEnd(n), sb, comments);
        },
        .tuple => {
            try w.writeAll("(");
            for (n.children, 0..) |c, i| {
                if (i > 0) try w.writeAll(", ");
                try formatInline(c, sb, comments);
            }
            try w.writeAll(")");
            try emitTrailingComments(lastTokenEnd(n), sb, comments);
        },
        .array => {
            try w.writeAll("[");
            for (n.children, 0..) |c, i| {
                if (i > 0) try w.writeAll(", ");
                try formatInline(c, sb, comments);
            }
            try w.writeAll("]");
            try emitTrailingComments(lastTokenEnd(n), sb, comments);
        },
        .value => {
            try w.writeAll(std.mem.trim(u8, n.token.value, " \t"));
            try emitTrailingComments(lastTokenEnd(n), sb, comments);
        },
        .type_annot => try w.writeAll(n.token.value),
        .array_schema => {
            try w.writeAll("[");
            if (n.children.len > 0) try formatInline(n.children[0], sb, comments);
            try w.writeAll("]");
            try emitTrailingComments(lastTokenEnd(n), sb, comments);
        },
        else => {},
    }
}

fn nodeWidth(n: Node) isize {
    switch (n.kind) {
        .document, .single_object, .object_array => return -1,
        .schema => {
            var total: isize = 2;
            for (n.children, 0..) |c, i| {
                if (i > 0) total += 2;
                const w = nodeWidth(c);
                if (w < 0) return -1;
                total += w;
            }
            return total;
        },
        .field => {
            var total: isize = @intCast(n.token.value.len);
            if (n.children.len > 0) {
                const c = n.children[0];
                if (c.kind == .type_annot) {
                    total += 1 + @as(isize, @intCast(c.token.value.len));
                } else if (c.kind == .schema) {
                    const w = nodeWidth(c);
                    if (w < 0) return -1;
                    total += 1 + w;
                } else if (c.kind == .array_schema) {
                    if (c.children.len > 0) {
                        const w = nodeWidth(c.children[0]);
                        if (w < 0) return -1;
                        total += 3 + w;
                    }
                }
            }
            return total;
        },
        .tuple, .array => {
            var total: isize = 2;
            for (n.children, 0..) |c, i| {
                if (i > 0) total += 2;
                const w = nodeWidth(c);
                if (w < 0) return -1;
                total += w;
            }
            return total;
        },
        .value => return @intCast(std.mem.trim(u8, n.token.value, " \t").len),
        else => return 0,
    }
}

fn isComplex(n: Node) bool {
    const w = nodeWidth(n);
    return w < 0 or w > MAX_LINE;
}

fn shouldExpand(n: Node, lvl: usize) bool {
    return switch (n.kind) {
        .schema, .tuple, .array => EXPAND_ALL_CONTAINERS or lvl == 0 or isComplex(n),
        else => isComplex(n),
    };
}

fn indent(level: usize, sb: *ArrayList(u8)) !void {
    var i: usize = 0;
    while (i < level) : (i += 1) try sb.appendSlice(INDENT);
}

fn formatNode(n: Node, lvl: usize, sb: *ArrayList(u8), comments: *CommentCtx) !void {
    const w = listWriter(sb);
    switch (n.kind) {
        .document => {
            if (n.children.len == 0) return;
            const first = n.children[0];
            const has_schema = (first.kind == .schema or first.kind == .array_schema);
            if (has_schema) {
                try emitLeadingComments(first.token.offset, lvl, sb, comments);
                if (first.kind == .array_schema) {
                    try w.writeAll("[");
                    if (first.children.len > 0) try formatNode(first.children[0], lvl, sb, comments);
                    try w.writeAll("]");
                } else {
                    try formatNode(first, lvl, sb, comments);
                }
                try w.writeAll(":");
                const rows = n.children[1..];
                for (rows, 0..) |c, ri| {
                    if (ri > 0) try w.writeAll(",");
                    try w.writeAll("\n");
                    try emitLeadingComments(c.token.offset, lvl, sb, comments);
                    try formatNode(c, lvl, sb, comments);
                }
                try w.writeAll("\n");
            } else {
                for (n.children) |c| {
                    try emitLeadingComments(c.token.offset, lvl, sb, comments);
                    try formatNode(c, lvl, sb, comments);
                }
            }
        },
        .schema => {
            if (!shouldExpand(n, lvl)) {
                try formatInline(n, sb, comments);
            } else {
                try w.writeAll("{\n");
                for (n.children, 0..) |c, i| {
                    try emitLeadingComments(c.token.offset, lvl + 1, sb, comments);
                    try indent(lvl + 1, sb);
                    try formatNode(c, lvl + 1, sb, comments);
                    if (i < n.children.len - 1) try w.writeAll(",");
                    try w.writeAll("\n");
                }
                try indent(lvl, sb);
                try w.writeAll("}");
                try emitTrailingComments(lastTokenEnd(n), sb, comments);
            }
        },
        .field => {
            try w.writeAll(n.token.value);
            if (n.children.len > 0) {
                const c = n.children[0];
                if (c.kind == .type_annot) {
                    try w.print("@{s}", .{c.token.value});
                } else if (c.kind == .schema) {
                    try w.writeAll("@");
                    try formatNode(c, lvl, sb, comments);
                } else if (c.kind == .array_schema) {
                    try w.writeAll("@[");
                    if (c.children.len > 0) try formatNode(c.children[0], lvl, sb, comments);
                    try w.writeAll("]");
                }
            }
            try emitTrailingComments(lastTokenEnd(n), sb, comments);
        },
        .tuple => {
            if (!shouldExpand(n, lvl)) {
                try formatInline(n, sb, comments);
            } else {
                try w.writeAll("(\n");
                for (n.children, 0..) |c, i| {
                    try emitLeadingComments(c.token.offset, lvl + 1, sb, comments);
                    try indent(lvl + 1, sb);
                    try formatNode(c, lvl + 1, sb, comments);
                    if (i < n.children.len - 1) try w.writeAll(",");
                    try w.writeAll("\n");
                }
                try indent(lvl, sb);
                try w.writeAll(")");
                try emitTrailingComments(lastTokenEnd(n), sb, comments);
            }
        },
        .array => {
            if (!shouldExpand(n, lvl)) {
                try formatInline(n, sb, comments);
            } else {
                try w.writeAll("[\n");
                for (n.children, 0..) |c, i| {
                    try emitLeadingComments(c.token.offset, lvl + 1, sb, comments);
                    try indent(lvl + 1, sb);
                    try formatNode(c, lvl + 1, sb, comments);
                    if (i < n.children.len - 1) try w.writeAll(",");
                    try w.writeAll("\n");
                }
                try indent(lvl, sb);
                try w.writeAll("]");
                try emitTrailingComments(lastTokenEnd(n), sb, comments);
            }
        },
        .array_schema => {
            try w.writeAll("[");
            if (n.children.len > 0) try formatNode(n.children[0], lvl, sb, comments);
            try w.writeAll("]");
            try emitTrailingComments(lastTokenEnd(n), sb, comments);
        },
        .value => {
            try w.writeAll(std.mem.trim(u8, n.token.value, " \t"));
            try emitTrailingComments(lastTokenEnd(n), sb, comments);
        },
        .type_annot => try w.writeAll(n.token.value),
        else => {},
    }
}

// ── Compress ───────────────────────────────────────────────────────────────────

pub fn compress(src: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    var result = try parser.parse(src, alloc);
    defer result.deinit();
    var sb = ArrayList(u8).init(alloc);
    try compressNode(result.root, &sb);
    return sb.toOwnedSlice();
}

fn compressNode(n: Node, sb: *ArrayList(u8)) !void {
    const w = listWriter(sb);
    switch (n.kind) {
        .document => {
            if (n.children.len == 0) return;
            const first = n.children[0];
            const has_schema = (first.kind == .schema or first.kind == .array_schema);
            if (has_schema) {
                if (first.kind == .array_schema) {
                    try w.writeAll("[");
                    if (first.children.len > 0) try compressNode(first.children[0], sb);
                    try w.writeAll("]");
                } else {
                    try compressNode(first, sb);
                }
                try w.writeAll(":");
                for (n.children[1..], 0..) |c, ri| {
                    if (ri > 0) try w.writeAll(",");
                    try compressNode(c, sb);
                }
            } else {
                for (n.children) |c| try compressNode(c, sb);
            }
        },
        .schema => {
            try w.writeAll("{");
            for (n.children, 0..) |c, i| {
                if (i > 0) try w.writeAll(",");
                try compressNode(c, sb);
            }
            try w.writeAll("}");
        },
        .field => {
            try w.writeAll(n.token.value);
            if (n.children.len > 0) {
                const c = n.children[0];
                if (c.kind == .type_annot) {
                    try w.print("@{s}", .{c.token.value});
                } else if (c.kind == .schema) {
                    try w.writeAll("@");
                    try compressNode(c, sb);
                } else if (c.kind == .array_schema) {
                    try w.writeAll("@[");
                    if (c.children.len > 0) try compressNode(c.children[0], sb);
                    try w.writeAll("]");
                }
            }
        },
        .tuple => {
            try w.writeAll("(");
            for (n.children, 0..) |c, i| {
                if (i > 0) try w.writeAll(",");
                try compressNode(c, sb);
            }
            try w.writeAll(")");
        },
        .array => {
            try w.writeAll("[");
            for (n.children, 0..) |c, i| {
                if (i > 0) try w.writeAll(",");
                try compressNode(c, sb);
            }
            try w.writeAll("]");
        },
        .array_schema => {
            try w.writeAll("[");
            if (n.children.len > 0) try compressNode(n.children[0], sb);
            try w.writeAll("]");
        },
        .value => try w.writeAll(std.mem.trim(u8, n.token.value, " \t")),
        .type_annot => try w.writeAll(n.token.value),
        else => {},
    }
}

// ── Inlay Hints ────────────────────────────────────────────────────────────────

pub const InlayHint = struct {
    line: u32,
    col: u32,
    label: []const u8,
};

pub const CursorInfo = struct {
    path: []const u8,
    type_label: []const u8,
    line: u32,
    col: u32,
    end_line: u32,
    end_col: u32,
};

pub fn inlayHints(root: Node, alloc: std.mem.Allocator) ![]InlayHint {
    var hints = ArrayList(InlayHint).init(alloc);
    try walkHints(root, &hints, alloc);
    return hints.toOwnedSlice();
}

fn walkHints(n: Node, hints: *ArrayList(InlayHint), alloc: std.mem.Allocator) !void {
    // Walk any schema+tuple pairs at document level
    if (n.kind == .document) {
        var schema_node: ?Node = null;
        for (n.children) |c| {
            if (c.kind == .schema or c.kind == .array_schema) {
                schema_node = c;
            } else if (c.kind == .tuple) {
                if (schema_node) |s| {
                    try tupleHints(s, c, hints, alloc);
                }
            }
        }
        return; // children already walked via tupleHints recursion
    }
    for (n.children) |c| try walkHints(c, hints, alloc);
}

fn schemaFields(n: Node) []Node {
    if (n.kind == .schema) {
        return n.children; // children are fields
    }
    if (n.kind == .array_schema and n.children.len > 0) {
        return schemaFields(n.children[0]);
    }
    return &.{};
}

fn tupleHints(schema: Node, tuple: Node, hints: *ArrayList(InlayHint), alloc: std.mem.Allocator) !void {
    if (tuple.kind != .tuple) return;
    const fields = schemaFields(schema);
    for (tuple.children, 0..) |child, i| {
        if (i >= fields.len) break;
        const field = fields[i];
        const field_name = field.token.value;
        const label = try std.fmt.allocPrint(alloc, "{s}:", .{field_name});
        try hints.append(.{ .line = child.token.line, .col = child.token.col, .label = label });
        // Recurse into nested schemas
        if (field.children.len > 0) {
            const ftype = field.children[0];
            if (ftype.kind == .schema and child.kind == .tuple) {
                try tupleHints(ftype, child, hints, alloc);
            } else if (ftype.kind == .array_schema and child.kind == .array) {
                const inner = if (ftype.children.len > 0) ftype.children[0] else ftype;
                for (child.children) |elem| {
                    if (elem.kind == .tuple) try tupleHints(inner, elem, hints, alloc);
                }
            }
        }
    }
}

pub fn cursorInfo(root: Node, line: u32, col: u32, alloc: std.mem.Allocator) !?CursorInfo {
    var infos = ArrayList(CursorInfo).init(alloc);
    try collectCursorInfos(root, &infos, alloc);
    return pickCursorInfo(infos.items, line, col);
}

const Span = struct {
    line: u32,
    col: u32,
    end_line: u32,
    end_col: u32,
};

fn collectCursorInfos(root: Node, infos: *ArrayList(CursorInfo), alloc: std.mem.Allocator) !void {
    if (root.kind != .document) return;
    if (root.children.len == 0) return;

    const first = root.children[0];
    if (first.kind == .array_schema) {
        const inner = if (first.children.len > 0) first.children[0] else first;
        var row_index: usize = 0;
        for (root.children[1..]) |child| {
            if (child.kind != .tuple) continue;
            const path = try pathIndex(alloc, "$", row_index);
            try collectTypedCursorInfos(inner, child, path, infos, alloc);
            row_index += 1;
        }
        return;
    }

    if (first.kind == .schema) {
        var row_count: usize = 0;
        for (root.children[1..]) |child| {
            if (child.kind == .tuple) row_count += 1;
        }

        var row_index: usize = 0;
        for (root.children[1..]) |child| {
            if (child.kind != .tuple) continue;
            const path = if (row_count > 1)
                try pathIndex(alloc, "$", row_index)
            else
                try alloc.dupe(u8, "$");
            try collectTypedCursorInfos(first, child, path, infos, alloc);
            row_index += 1;
        }
        return;
    }

    for (root.children, 0..) |child, idx| {
        const path = if (root.children.len > 1)
            try pathIndex(alloc, "$", idx)
        else
            try alloc.dupe(u8, "$");
        try collectUntypedCursorInfos(child, path, infos, alloc);
    }
}

fn collectTypedCursorInfos(schema_node: Node, value_node: Node, path: []const u8, infos: *ArrayList(CursorInfo), alloc: std.mem.Allocator) !void {
    const type_label = try typeLabelForNode(schema_node, alloc);
    try appendCursorInfo(infos, value_node, path, type_label);

    switch (schema_node.kind) {
        .schema => {
            if (value_node.kind != .tuple) return;
            const fields = schemaFields(schema_node);
            for (value_node.children, 0..) |child, i| {
                if (i >= fields.len) break;
                const field = fields[i];
                const child_path = try pathField(alloc, path, field.token.value);
                if (field.children.len > 0) {
                    try collectTypedCursorInfos(field.children[0], child, child_path, infos, alloc);
                } else {
                    try collectUntypedCursorInfos(child, child_path, infos, alloc);
                }
            }
        },
        .array_schema => {
            if (value_node.kind != .array) return;
            const inner = if (schema_node.children.len > 0) schema_node.children[0] else schema_node;
            for (value_node.children, 0..) |child, i| {
                const child_path = try pathIndex(alloc, path, i);
                try collectTypedCursorInfos(inner, child, child_path, infos, alloc);
            }
        },
        else => {},
    }
}

fn collectUntypedCursorInfos(value_node: Node, path: []const u8, infos: *ArrayList(CursorInfo), alloc: std.mem.Allocator) !void {
    const type_label = try inferTypeLabel(value_node, alloc);
    try appendCursorInfo(infos, value_node, path, type_label);

    switch (value_node.kind) {
        .tuple, .array => {
            for (value_node.children, 0..) |child, i| {
                const child_path = try pathIndex(alloc, path, i);
                try collectUntypedCursorInfos(child, child_path, infos, alloc);
            }
        },
        else => {},
    }
}

fn appendCursorInfo(infos: *ArrayList(CursorInfo), node: Node, path: []const u8, type_label: []const u8) !void {
    const span = nodeSpan(node);
    try infos.append(.{
        .path = path,
        .type_label = type_label,
        .line = span.line,
        .col = span.col,
        .end_line = span.end_line,
        .end_col = span.end_col,
    });
}

fn typeLabelForNode(node: Node, alloc: std.mem.Allocator) ![]const u8 {
    return switch (node.kind) {
        .type_annot => try alloc.dupe(u8, node.token.value),
        .schema => try alloc.dupe(u8, "object"),
        .array_schema => blk: {
            const inner = if (node.children.len > 0) node.children[0] else node;
            const inner_label = try typeLabelForNode(inner, alloc);
            break :blk try std.fmt.allocPrint(alloc, "array<{s}>", .{inner_label});
        },
        else => try inferTypeLabel(node, alloc),
    };
}

fn inferTypeLabel(node: Node, alloc: std.mem.Allocator) ![]const u8 {
    return switch (node.kind) {
        .tuple => try alloc.dupe(u8, "tuple"),
        .array => try alloc.dupe(u8, "array"),
        .value => switch (node.token.kind) {
            .number => if (std.mem.indexOfAny(u8, node.token.value, ".eE")) |_|
                try alloc.dupe(u8, "float")
            else
                try alloc.dupe(u8, "int"),
            .bool_val => try alloc.dupe(u8, "bool"),
            .string, .plain_str, .ident => try alloc.dupe(u8, "str"),
            else => try alloc.dupe(u8, "value"),
        },
        else => try alloc.dupe(u8, "value"),
    };
}

fn pathField(alloc: std.mem.Allocator, base: []const u8, field_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}.{s}", .{ base, field_name });
}

fn pathIndex(alloc: std.mem.Allocator, base: []const u8, index: usize) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}[{d}]", .{ base, index });
}

fn nodeSpan(node: Node) Span {
    var span = Span{
        .line = node.token.line,
        .col = node.token.col,
        .end_line = node.token.end_line,
        .end_col = node.token.end_col,
    };
    for (node.children) |child| {
        const child_span = nodeSpan(child);
        if (child_span.line < span.line or (child_span.line == span.line and child_span.col < span.col)) {
            span.line = child_span.line;
            span.col = child_span.col;
        }
        if (child_span.end_line > span.end_line or (child_span.end_line == span.end_line and child_span.end_col > span.end_col)) {
            span.end_line = child_span.end_line;
            span.end_col = child_span.end_col;
        }
    }
    return span;
}

fn pickCursorInfo(infos: []const CursorInfo, line: u32, col: u32) ?CursorInfo {
    var best_exact: ?CursorInfo = null;
    var best_exact_score: u64 = std.math.maxInt(u64);
    var best_line: ?CursorInfo = null;
    var best_line_score: u64 = std.math.maxInt(u64);

    for (infos) |info| {
        const score = spanScore(info);
        if (spanContains(info, line, col)) {
            if (score <= best_exact_score) {
                best_exact = info;
                best_exact_score = score;
            }
        } else if (line >= info.line and line <= info.end_line) {
            if (score <= best_line_score) {
                best_line = info;
                best_line_score = score;
            }
        }
    }
    return best_exact orelse best_line;
}

fn spanContains(info: CursorInfo, line: u32, col: u32) bool {
    const start_ok = info.line < line or (info.line == line and info.col <= col);
    const end_ok = info.end_line > line or (info.end_line == line and info.end_col >= col);
    return start_ok and end_ok;
}

fn spanScore(info: CursorInfo) u64 {
    const line_span: u64 = @as(u64, info.end_line - info.line) * 10000;
    const col_span: u64 = if (info.end_line == info.line)
        @as(u64, info.end_col - info.col)
    else
        @as(u64, info.end_col + info.col);
    return line_span + col_span;
}

// ── ASUN → JSON ────────────────────────────────────────────────────────────────

pub fn asunToJson(src: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    var result = try parser.parse(src, alloc);
    defer result.deinit();

    // Check for parse errors
    for (result.diags) |d| {
        if (d.severity == .err)
            return error.ParseError;
    }

    var sb = ArrayList(u8).init(alloc);
    try nodeToJson(result.root, &sb, alloc, 0);
    return sb.toOwnedSlice();
}

fn nodeToJson(n: Node, sb: *ArrayList(u8), alloc: std.mem.Allocator, _indent: usize) error{OutOfMemory}!void {
    const w = listWriter(sb);
    switch (n.kind) {
        .document => {
            if (n.children.len == 0) {
                try w.writeAll("null");
                return;
            }
            const first = n.children[0];
            if (first.kind == .schema or first.kind == .array_schema) {
                var data_count: usize = 0;
                for (n.children[1..]) |c| {
                    if (c.kind == .tuple) data_count += 1;
                }
                if (first.kind == .array_schema) {
                    // [{schema}]:(tuple),(tuple)... → JSON array of objects
                    const inner_schema = if (first.children.len > 0) first.children[0] else first;
                    try w.writeAll("[");
                    var first_elem = true;
                    for (n.children[1..]) |c| {
                        if (c.kind == .tuple) {
                            if (!first_elem) try w.writeAll(", ");
                            first_elem = false;
                            try schemaAndTupleToJson(inner_schema, c, sb, alloc, 0);
                        }
                    }
                    try w.writeAll("]");
                    return;
                }
                // Plain schema
                if (data_count == 1) {
                    for (n.children[1..]) |c| {
                        if (c.kind == .tuple) {
                            try schemaAndTupleToJson(first, c, sb, alloc, 0);
                            return;
                        }
                    }
                } else if (data_count > 1) {
                    try w.writeAll("[");
                    var first_elem = true;
                    for (n.children[1..]) |c| {
                        if (c.kind == .tuple) {
                            if (!first_elem) try w.writeAll(", ");
                            first_elem = false;
                            try schemaAndTupleToJson(first, c, sb, alloc, 0);
                        }
                    }
                    try w.writeAll("]");
                    return;
                }
            }
            try nodeToJson(n.children[0], sb, alloc, _indent);
        },
        .schema => {
            // schema with a following tuple is a single object
            try w.writeAll("{}");
        },
        .tuple => {
            // tuple without context, emit as array
            try w.writeAll("[");
            for (n.children, 0..) |c, i| {
                if (i > 0) try w.writeAll(", ");
                try nodeToJson(c, sb, alloc, _indent);
            }
            try w.writeAll("]");
        },
        .array => {
            try w.writeAll("[");
            for (n.children, 0..) |c, i| {
                if (i > 0) try w.writeAll(", ");
                try nodeToJson(c, sb, alloc, _indent);
            }
            try w.writeAll("]");
        },
        .value => try valueToJson(n.token, sb),
        else => try w.writeAll("null"),
    }
}

fn schemaAndTupleToJson(schema: Node, tuple: Node, sb: *ArrayList(u8), alloc: std.mem.Allocator, lvl: usize) !void {
    _ = lvl;
    const w = listWriter(sb);
    const fields = schemaFields(schema);
    try w.writeAll("{");
    for (fields, 0..) |f, i| {
        if (i > 0) try w.writeAll(", ");
        try writeJsonFieldName(f.token, sb);
        try w.writeAll(": ");
        if (i < tuple.children.len) {
            const child = tuple.children[i];
            if (f.children.len > 0) {
                const ftype = f.children[0];
                if (ftype.kind == .schema and child.kind == .tuple) {
                    // Nested object
                    try schemaAndTupleToJson(ftype, child, sb, alloc, 0);
                    continue;
                } else if (ftype.kind == .array_schema and child.kind == .array) {
                    // Array of sub-objects: [{subSchema}] paired with [(t1),(t2),...]
                    const inner = if (ftype.children.len > 0) ftype.children[0] else ftype;
                    try w.writeAll("[");
                    for (child.children, 0..) |elem, ei| {
                        if (ei > 0) try w.writeAll(", ");
                        if (elem.kind == .tuple) {
                            try schemaAndTupleToJson(inner, elem, sb, alloc, 0);
                        } else {
                            try nodeToJson(elem, sb, alloc, 0);
                        }
                    }
                    try w.writeAll("]");
                    continue;
                }
            }
            try nodeToJson(child, sb, alloc, 0);
        } else {
            try w.writeAll("null");
        }
    }
    try w.writeAll("}");
}

fn writeJsonFieldName(t: Token, sb: *ArrayList(u8)) !void {
    const w = listWriter(sb);
    switch (t.kind) {
        .string => try w.writeAll(t.value),
        else => try w.print("\"{s}\"", .{t.value}),
    }
}

fn valueToJson(t: Token, sb: *ArrayList(u8)) !void {
    const w = listWriter(sb);
    switch (t.kind) {
        .number => try w.writeAll(t.value),
        .bool_val => try w.writeAll(t.value),
        .string => {
            // value already includes quotes, just emit
            try w.writeAll(t.value);
        },
        else => {
            const v = std.mem.trim(u8, t.value, " \t");
            if (v.len == 0) {
                try w.writeAll("null");
            } else if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "false")) {
                try w.writeAll(v);
            } else if (lex.isNumber(v)) {
                try w.writeAll(v);
            } else {
                // Output as JSON string
                try w.writeByte('"');
                for (v) |c| {
                    if (c == '"') try w.writeAll("\\\"") else if (c == '\\') try w.writeAll("\\\\") else if (c == '\n') try w.writeAll("\\n") else try w.writeByte(c);
                }
                try w.writeByte('"');
            }
        },
    }
}

// ── JSON → ASUN ────────────────────────────────────────────────────────────────

pub fn jsonToAsun(src: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const tmp = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, tmp, src, .{});
    defer parsed.deinit();
    var sb = ArrayList(u8).init(tmp);
    try jsonValueToAsun(parsed.value, &sb, tmp);
    return try alloc.dupe(u8, sb.items);
}

fn jsonValueToAsun(v: std.json.Value, sb: *ArrayList(u8), alloc: std.mem.Allocator) error{OutOfMemory}!void {
    const w = listWriter(sb);
    switch (v) {
        .null => try w.writeAll(""),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .string => |s| {
            if (needsQuote(s)) {
                try writeAsunString(w, s);
            } else {
                try w.writeAll(s);
            }
        },
        .object => |obj| try jsonObjectToAsun(obj, sb, alloc),
        .array => |arr| try jsonArrayToAsun(arr.items, sb, alloc),
        .number_string => |s| try w.writeAll(s),
    }
}

fn sortedKeys(obj: std.json.ObjectMap, alloc: std.mem.Allocator) error{OutOfMemory}![][]const u8 {
    var keys = ArrayList([]const u8).init(alloc);
    var it = obj.iterator();
    while (it.next()) |e| try keys.append(e.key_ptr.*);
    const S = struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    };
    std.mem.sort([]const u8, keys.items, {}, S.lessThan);
    return keys.toOwnedSlice();
}

const FieldPair = struct { schema: []const u8, data: []const u8 };

fn jsonObjectToAsun(obj: std.json.ObjectMap, sb: *ArrayList(u8), alloc: std.mem.Allocator) error{OutOfMemory}!void {
    const w = listWriter(sb);
    if (obj.count() == 0) {
        try w.writeAll("{}:()");
        return;
    }
    const keys = try sortedKeys(obj, alloc);
    var schema_parts = ArrayList(u8).init(alloc);
    var data_parts = ArrayList(u8).init(alloc);
    const sw = listWriter(&schema_parts);
    const dw = listWriter(&data_parts);

    for (keys, 0..) |k, i| {
        const val = obj.get(k) orelse .null;
        if (i > 0) {
            try sw.writeAll(",");
            try dw.writeAll(",");
        }
        const pair = try jsonFieldToAsun(k, val, alloc);
        try sw.writeAll(pair.schema);
        try dw.writeAll(pair.data);
    }
    try w.print("{{{s}}}:({s})", .{ schema_parts.items, data_parts.items });
}

fn jsonFieldToAsun(key: []const u8, val: std.json.Value, alloc: std.mem.Allocator) error{OutOfMemory}!FieldPair {
    var s = ArrayList(u8).init(alloc);
    var d = ArrayList(u8).init(alloc);
    const sw = listWriter(&s);
    const dw = listWriter(&d);
    switch (val) {
        .null => {
            try writeFieldName(sw, key);
            try sw.writeAll("@str");
        },
        .bool => |b| {
            try writeFieldName(sw, key);
            try sw.writeAll("@bool");
            try dw.writeAll(if (b) "true" else "false");
        },
        .integer => |i| {
            try writeFieldName(sw, key);
            try sw.writeAll("@int");
            try dw.print("{d}", .{i});
        },
        .float => |f| {
            try writeFieldName(sw, key);
            try sw.writeAll("@float");
            try dw.print("{d}", .{f});
        },
        .string => |str| {
            try writeFieldName(sw, key);
            try sw.writeAll("@str");
            if (needsQuote(str)) {
                try writeAsunString(dw, str);
            } else {
                try dw.writeAll(str);
            }
        },
        .object => |obj| {
            var inner_s = ArrayList(u8).init(alloc);
            var inner_d = ArrayList(u8).init(alloc);
            const ks = try sortedKeys(obj, alloc);
            for (ks, 0..) |ik, i| {
                const iv = obj.get(ik) orelse .null;
                const p2 = try jsonFieldToAsun(ik, iv, alloc);
                if (i > 0) {
                    try listWriter(&inner_s).writeAll(",");
                    try listWriter(&inner_d).writeAll(",");
                }
                try listWriter(&inner_s).writeAll(p2.schema);
                try listWriter(&inner_d).writeAll(p2.data);
            }
            try writeFieldName(sw, key);
            try sw.print("@{{{s}}}", .{inner_s.items});
            try dw.print("({s})", .{inner_d.items});
        },
        .array => |arr| {
            const items = arr.items;
            if (items.len > 0) {
                switch (items[0]) {
                    .object => |first_obj| {
                        const ks = try sortedKeys(first_obj, alloc);
                        var inner_s = ArrayList(u8).init(alloc);
                        for (ks, 0..) |ik, i| {
                            const iv = first_obj.get(ik) orelse .null;
                            const p2 = try jsonFieldToAsun(ik, iv, alloc);
                            if (i > 0) try listWriter(&inner_s).writeAll(",");
                            try listWriter(&inner_s).writeAll(p2.schema);
                        }
                        try writeFieldName(sw, key);
                        try sw.print("@[{{{s}}}]", .{inner_s.items});
                        // data: array of tuples
                        var dat = ArrayList(u8).init(alloc);
                        try listWriter(&dat).writeAll("[");
                        for (items, 0..) |elem, ei| {
                            if (ei > 0) try listWriter(&dat).writeAll(",");
                            switch (elem) {
                                .object => |eobj| {
                                    var td = ArrayList(u8).init(alloc);
                                    for (ks, 0..) |ik, kIdx| {
                                        const iv = eobj.get(ik) orelse .null;
                                        const p2 = try jsonFieldToAsun(ik, iv, alloc);
                                        if (kIdx > 0) try listWriter(&td).writeAll(",");
                                        try listWriter(&td).writeAll(p2.data);
                                    }
                                    try listWriter(&dat).print("({s})", .{td.items});
                                },
                                else => try jsonValueToAsun(elem, &dat, alloc),
                            }
                        }
                        try listWriter(&dat).writeAll("]");
                        try dw.writeAll(dat.items);
                        return FieldPair{ .schema = try s.toOwnedSlice(), .data = try d.toOwnedSlice() };
                    },
                    else => {},
                }
            }
            // plain array
            const elem_type = inferArrayType(items);
            try writeFieldName(sw, key);
            try sw.print("@[{s}]", .{elem_type});
            var elems = ArrayList(u8).init(alloc);
            try listWriter(&elems).writeAll("[");
            for (items, 0..) |elem, i| {
                if (i > 0) try listWriter(&elems).writeAll(",");
                try jsonValueToAsun(elem, &elems, alloc);
            }
            if (items.len > 0 and items[items.len - 1] == .null) try listWriter(&elems).writeAll(",");
            try listWriter(&elems).writeAll("]");
            try dw.writeAll(elems.items);
        },
        .number_string => |ns| {
            try writeFieldName(sw, key);
            try sw.writeAll("@str");
            try dw.writeAll(ns);
        },
    }
    return FieldPair{ .schema = try s.toOwnedSlice(), .data = try d.toOwnedSlice() };
}

fn jsonArrayToAsun(items: []std.json.Value, sb: *ArrayList(u8), alloc: std.mem.Allocator) error{OutOfMemory}!void {
    const w = listWriter(sb);
    if (items.len == 0) {
        try w.writeAll("[str]");
        return;
    }
    // Array of objects → object-array format
    if (items[0] == .object) {
        const first_obj = items[0].object;
        const keys = try sortedKeys(first_obj, alloc);
        // Build the schema header once from the first element
        var schema_parts = ArrayList(u8).init(alloc);
        for (keys, 0..) |k, i| {
            const iv = first_obj.get(k) orelse .null;
            const p2 = try jsonFieldToAsun(k, iv, alloc);
            if (i > 0) try listWriter(&schema_parts).writeAll(",");
            try listWriter(&schema_parts).writeAll(p2.schema);
        }
        try w.print("[{{{s}}}]:\n", .{schema_parts.items});
        // Write each element as a tuple, using writeValueData to avoid
        // per-element schema+data slice allocations.
        for (items, 0..) |elem, ei| {
            try w.writeAll("  (");
            if (elem == .object) {
                const eobj = elem.object;
                for (keys, 0..) |k, i| {
                    if (i > 0) try w.writeAll(",");
                    const iv = eobj.get(k) orelse .null;
                    try writeValueData(iv, w, alloc);
                }
            }
            try w.writeAll(")");
            if (ei < items.len - 1) try w.writeAll(",");
            try w.writeAll("\n");
        }
        return;
    }
    // plain array
    try w.writeAll("[");
    for (items, 0..) |elem, i| {
        if (i > 0) try w.writeAll(",");
        try jsonValueToAsun(elem, sb, alloc);
    }
    if (items.len > 0 and items[items.len - 1] == .null) try w.writeAll(",");
    try w.writeAll("]");
}

/// Write only the data value (no schema prefix) directly to writer w.
/// Avoids allocating intermediate ArrayList buffers per element.
fn writeValueData(val: std.json.Value, w: anytype, alloc: std.mem.Allocator) error{OutOfMemory}!void {
    switch (val) {
        .null => {},
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .string => |s| {
            if (needsQuote(s)) {
                try writeAsunString(w, s);
            } else {
                try w.writeAll(s);
            }
        },
        .object => |obj| {
            try w.writeAll("(");
            const ks = try sortedKeys(obj, alloc);
            for (ks, 0..) |k, i| {
                if (i > 0) try w.writeAll(",");
                const iv = obj.get(k) orelse .null;
                try writeValueData(iv, w, alloc);
            }
            try w.writeAll(")");
        },
        .array => |arr| {
            if (arr.items.len > 0 and arr.items[0] == .object) {
                const first_obj = arr.items[0].object;
                const ks = try sortedKeys(first_obj, alloc);
                try w.writeAll("[");
                for (arr.items, 0..) |elem, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.writeAll("(");
                    if (elem == .object) {
                        const eobj = elem.object;
                        for (ks, 0..) |k, j| {
                            if (j > 0) try w.writeAll(",");
                            const iv = eobj.get(k) orelse .null;
                            try writeValueData(iv, w, alloc);
                        }
                    }
                    try w.writeAll(")");
                }
                try w.writeAll("]");
            } else {
                try w.writeAll("[");
                for (arr.items, 0..) |elem, i| {
                    if (i > 0) try w.writeAll(",");
                    var tmp = ArrayList(u8).init(alloc);
                    try jsonValueToAsun(elem, &tmp, alloc);
                    try w.writeAll(tmp.items);
                }
                if (arr.items.len > 0 and arr.items[arr.items.len - 1] == .null) try w.writeAll(",");
                try w.writeAll("]");
            }
        },
        .number_string => |ns| try w.writeAll(ns),
    }
}

fn inferArrayType(items: []std.json.Value) []const u8 {
    if (items.len == 0) return "str";
    switch (items[0]) {
        .integer => return "int",
        .float => return "float",
        .bool => return "bool",
        .string => return "str",
        else => return "str",
    }
}

fn isNumericLookalike(s: []const u8) bool {
    return lex.isNumber(s) or looksLikeLegacyNumber(s);
}

fn looksLikeLegacyNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    var start: usize = 0;
    if (s[0] == '-') start = 1;
    if (start >= s.len) return false;
    for (s[start..]) |c| {
        if (!std.ascii.isDigit(c) and c != '.') return false;
    }
    return true;
}

fn needsQuote(s: []const u8) bool {
    if (s.len == 0) return true;
    if (s[0] == ' ' or s[s.len - 1] == ' ') return true;
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false")) return true;
    if (std.mem.indexOf(u8, s, "/*") != null or std.mem.indexOf(u8, s, "*/") != null) return true;
    if (isNumericLookalike(s)) return true;
    for (s) |c| {
        if (c == ',' or c == ')' or c == '(' or c == '[' or c == ']' or
            c == '{' or c == '}' or c == ':' or c == '@' or
            c == '"' or c == '\\' or c <= 0x1f) return true;
    }
    return false;
}

fn writeAsunString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    const HEX = "0123456789abcdef";
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\t' => try w.writeAll("\\t"),
            '\r' => try w.writeAll("\\r"),
            else => {
                if (c <= 0x1f) {
                    try w.writeAll("\\u00");
                    try w.writeByte(HEX[c >> 4]);
                    try w.writeByte(HEX[c & 0xf]);
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

/// Check if a JSON key needs quoting to be a valid ASUN field name.
/// ASUN identifiers allow [a-zA-Z0-9_].
fn needsKeyQuote(s: []const u8) bool {
    if (s.len == 0) return true;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_';
        if (!ok) return true;
    }
    return false;
}

/// Write a field name to the writer, quoting it if necessary.
fn writeFieldName(w: anytype, key: []const u8) !void {
    if (needsKeyQuote(key)) {
        try w.writeByte('"');
        for (key) |c| {
            if (c == '"') {
                try w.writeAll("\\\"");
            } else if (c == '\\') {
                try w.writeAll("\\\\");
            } else try w.writeByte(c);
        }
        try w.writeByte('"');
    } else {
        try w.writeAll(key);
    }
}

// ── Find node at position ──────────────────────────────────────────────────────

pub fn findNodeAt(root: Node, line: u32, col: u32) ?Node {
    var best: ?Node = null;
    findNodeAtRecurse(root, line, col, &best);
    return best;
}

fn findNodeAtRecurse(n: Node, line: u32, col: u32, best: *?Node) void {
    const t = n.token;
    const start_ok = t.line < line or (t.line == line and t.col <= col);
    // Use the token itself as end (approximation)
    const end_ok = t.end_line > line or (t.end_line == line and t.end_col >= col);
    if (start_ok and end_ok) best.* = n;
    for (n.children) |c| findNodeAtRecurse(c, line, col, best);
}
