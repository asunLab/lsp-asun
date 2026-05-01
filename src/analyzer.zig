//! Semantic analysis — validates field names and schema/data consistency.

const std = @import("std");
const ArrayList = std.array_list.Managed;
const parser = @import("parser.zig");
const Node = parser.Node;
const NodeKind = parser.NodeKind;
const Diag = parser.Diag;
const Severity = parser.Severity;

pub fn analyze(root: Node, alloc: std.mem.Allocator) ![]Diag {
    var diags = ArrayList(Diag).init(alloc);
    var a = Analyzer{ .diags = &diags, .alloc = alloc };
    try a.walkDoc(root);
    return diags.toOwnedSlice();
}

const Analyzer = struct {
    diags: *ArrayList(Diag),
    alloc: std.mem.Allocator,
    schema_field_count: usize = 0,

    fn addDiag(self: *Analyzer, d: Diag) void {
        self.diags.append(d) catch {};
    }

    fn walkDoc(self: *Analyzer, node: Node) !void {
        if (node.kind != .document) return;
        var schema_fields: usize = 0;
        var schema_found = false;

        for (node.children) |child| {
            if (child.kind == .schema or child.kind == .array_schema) {
                schema_found = true;
                const target = if (child.kind == .array_schema and child.children.len > 0) child.children[0] else child;
                schema_fields = target.children.len;
                try self.walkSchema(target);
            } else if (child.kind == .tuple) {
                if (schema_found) {
                    const got = child.children.len;
                    if (got != schema_fields) {
                        self.addDiag(.{
                            .message = std.fmt.allocPrint(
                                self.alloc,
                                "tuple has {d} values but schema has {d} fields",
                                .{ got, schema_fields },
                            ) catch "count mismatch",
                            .line = child.token.line,
                            .col = child.token.col,
                            .end_line = child.token.end_line,
                            .end_col = child.token.end_col,
                            .severity = .err,
                        });
                    }
                }
            }
        }
    }

    fn walkSchema(self: *Analyzer, schema: Node) !void {
        for (schema.children) |field| {
            if (field.kind != .field) continue;
            try self.checkFieldName(field);
            if (field.children.len > 0 and field.children[0].kind == .schema) {
                try self.walkSchema(field.children[0]);
            } else if (field.children.len > 0 and field.children[0].kind == .array_schema and field.children[0].children.len > 0) {
                try self.walkSchema(field.children[0].children[0]);
            }
        }
    }

    fn checkFieldName(self: *Analyzer, field: Node) !void {
        if (field.token.kind == .string) {
            // Quoted field names are allowed to contain spaces and other non-delimiter characters.
            return;
        }
        const name = field.token.value;
        for (name) |ch| {
            const ok = (ch >= 'a' and ch <= 'z') or
                       (ch >= 'A' and ch <= 'Z') or
                       (ch >= '0' and ch <= '9') or
                       ch == '_';
            if (!ok) {
                self.addDiag(.{
                    .message = std.fmt.allocPrint(
                        self.alloc,
                        "invalid character '{c}' in field name '{s}'",
                        .{ ch, name },
                    ) catch "invalid field name char",
                    .line = field.token.line,
                    .col = field.token.col,
                    .end_line = field.token.end_line,
                    .end_col = field.token.end_col,
                    .severity = .err,
                });
                return;
            }
        }
    }
};
