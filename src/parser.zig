//! Parser — builds an AST from a token stream.

const std = @import("std");
const ArrayList = std.array_list.Managed;
const lex = @import("lexer.zig");
const Lexer = lex.Lexer;
const Token = lex.Token;
const TK = lex.TokKind;

// ── Diagnostic ─────────────────────────────────────────────────────────────────

pub const Severity = enum { err, warning, hint };

pub const Diag = struct {
    message: []const u8,
    line: u32,
    col: u32,
    end_line: u32,
    end_col: u32,
    severity: Severity,
};

// ── AST nodes ──────────────────────────────────────────────────────────────────

pub const NodeKind = enum {
    document,
    schema,
    field,
    type_annot,
    array_schema,
    single_object,
    object_array,
    tuple,
    array,
    value,
};

pub const Node = struct {
    kind: NodeKind,
    token: Token, // primary token
    children: []Node, // owned by arena
    // Typed fields overlaid via kind:
    // .field  → children[0] = type_annot / schema / array_schema when present
    // .schema → children = fields
    // .document → children[0] = schema if present, then data nodes
};

// ── Parser ─────────────────────────────────────────────────────────────────────

pub const ParseResult = struct {
    root: Node,
    diags: []Diag,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ParseResult) void {
        self.arena.deinit();
    }
};

pub fn parse(src: []const u8, backing: std.mem.Allocator) !ParseResult {
    var arena = std.heap.ArenaAllocator.init(backing);
    const alloc = arena.allocator();

    var lexer = Lexer.init(src);
    var diags = ArrayList(Diag).init(alloc);
    var p = Parser{
        .lexer = &lexer,
        .alloc = alloc,
        .diags = &diags,
        .src = src,
    };
    p.eat(); // prime look-ahead

    const root = try p.parseDocument();
    return ParseResult{
        .root = root,
        .diags = try diags.toOwnedSlice(),
        .arena = arena,
    };
}

const Parser = struct {
    lexer: *Lexer,
    cur: Token = undefined,
    diags: *ArrayList(Diag),
    alloc: std.mem.Allocator,
    src: []const u8,

    fn eat(self: *Parser) void {
        while (true) {
            const t = self.lexer.next();
            if (t.kind == .comment) continue; // skip
            self.cur = t;
            return;
        }
    }

    fn eatNl(self: *Parser) void {
        while (self.cur.kind == .newline) self.eat();
    }

    fn expect(self: *Parser, kind: TK) ?Token {
        if (self.cur.kind == kind) {
            const t = self.cur;
            self.eat();
            return t;
        }
        self.diag("expected {s}", .{@tagName(kind)}, self.cur);
        return null;
    }

    fn diag(self: *Parser, comptime fmt: []const u8, args: anytype, t: Token) void {
        const msg = std.fmt.allocPrint(self.alloc, fmt, args) catch "error";
        self.diags.append(.{
            .message = msg,
            .line = t.line,
            .col = t.col,
            .end_line = t.end_line,
            .end_col = t.end_col,
            .severity = .err,
        }) catch {};
    }

    fn mkNode(self: *Parser, kind: NodeKind, token: Token, children: []Node) Node {
        _ = self;
        return .{ .kind = kind, .token = token, .children = children };
    }

    fn emptyValueNode(self: *Parser, token: Token) Node {
        var t = token;
        t.value = "";
        return self.mkNode(.value, t, self.noChildren());
    }

    fn noChildren(self: *Parser) []Node {
        _ = self;
        return &.{};
    }

    // ── Grammar ───────────────────────────────────────────────────────────────

    fn parseDocument(self: *Parser) error{OutOfMemory}!Node {
        self.eatNl();
        const docTok = self.cur;
        var children = ArrayList(Node).init(self.alloc);

        if (self.cur.kind == .lbrace) {
            const schema = try self.parseSchema();
            try children.append(schema);
            self.eatNl();
            if (self.cur.kind == .colon) self.eat(); // consume ':' separator
            // data rows — separated by commas and/or newlines
            while (self.cur.kind != .eof) {
                while (self.cur.kind == .newline or self.cur.kind == .comma) self.eat();
                if (self.cur.kind == .eof) break;
                const row = try self.parseDataRow();
                try children.append(row);
            }
        } else if (self.cur.kind == .lbracket and self.peekInsideBracket() == .lbrace) {
            // Array schema: [{field@type, ...}]:(data tuples)
            self.eat(); // consume [
            self.eatNl();
            const inner = try self.parseTypeAnnot(); // parses {field@type...}
            _ = self.expect(.rbracket);
            var ch_arr = try self.alloc.alloc(Node, 1);
            ch_arr[0] = inner;
            const arr_schema = self.mkNode(.array_schema, docTok, ch_arr);
            try children.append(arr_schema);
            self.eatNl();
            if (self.cur.kind == .colon) self.eat(); // consume ':' separator
            // data rows — separated by commas and/or newlines
            while (self.cur.kind != .eof) {
                while (self.cur.kind == .newline or self.cur.kind == .comma) self.eat();
                if (self.cur.kind == .eof) break;
                const row = try self.parseDataRow();
                try children.append(row);
            }
        } else {
            // schema-less document
            while (self.cur.kind != .eof) {
                const row = try self.parseDataRow();
                try children.append(row);
                self.eatNl();
            }
        }

        return self.mkNode(.document, docTok, try children.toOwnedSlice());
    }

    /// Peek at the first meaningful token inside the current `[` without consuming it.
    fn peekInsideBracket(self: *Parser) TK {
        var tmp = self.lexer.*;
        while (true) {
            const t = tmp.next();
            switch (t.kind) {
                .comment, .newline => continue,
                else => return t.kind,
            }
        }
    }

    fn parseSchema(self: *Parser) error{OutOfMemory}!Node {
        const tok = self.cur;
        _ = self.expect(.lbrace);
        self.eatNl();
        var fields = ArrayList(Node).init(self.alloc);
        while (self.cur.kind != .rbrace and self.cur.kind != .eof) {
            if (self.cur.kind == .newline or self.cur.kind == .comma) {
                self.eat();
                continue;
            }
            const f = try self.parseField();
            try fields.append(f);
        }
        _ = self.expect(.rbrace);
        return self.mkNode(.schema, tok, try fields.toOwnedSlice());
    }

    fn parseField(self: *Parser) error{OutOfMemory}!Node {
        const nameTok = self.cur;
        if (self.cur.kind != .ident and self.cur.kind != .string) {
            self.diag("expected field name", .{}, self.cur);
            self.eat();
            return self.mkNode(.field, nameTok, self.noChildren());
        }
        self.eat(); // consume ident or quoted string
        self.eatNl();
        if (self.cur.kind == .at) {
            self.eat();
            const ta = try self.parseTypeAnnot();
            self.eatNl();
            var ch = try self.alloc.alloc(Node, 1);
            ch[0] = ta;
            return self.mkNode(.field, nameTok, ch);
        }
        return self.mkNode(.field, nameTok, self.noChildren());
    }

    fn parseTypeAnnot(self: *Parser) error{OutOfMemory}!Node {
        const tok = self.cur;
        switch (self.cur.kind) {
            .type_hint => {
                const t = self.cur;
                self.eat();
                return self.mkNode(.type_annot, t, self.noChildren());
            },
            .lbracket => {
                return try self.parseArraySchema();
            },
            .lbrace => {
                return try self.parseSchema();
            },
            else => {
                self.diag("expected type annotation, got '{s}'", .{self.cur.value}, tok);
                const t = self.cur;
                self.eat();
                return self.mkNode(.type_annot, t, self.noChildren());
            },
        }
    }

    fn parseArraySchema(self: *Parser) error{OutOfMemory}!Node {
        const tok = self.cur;
        self.eat(); // consume [
        const inner = try self.parseTypeAnnot();
        _ = self.expect(.rbracket);
        var ch = try self.alloc.alloc(Node, 1);
        ch[0] = inner;
        return self.mkNode(.array_schema, tok, ch);
    }

    // A data row starts with ( for tuple/object-array, [ for array,
    // or is a bare value row.
    fn parseDataRow(self: *Parser) error{OutOfMemory}!Node {
        self.eatNl();
        if (self.cur.kind == .lparen) return self.parseTuple();
        if (self.cur.kind == .lbracket) return self.parseArray();
        return self.parseValue();
    }

    fn parseTuple(self: *Parser) error{OutOfMemory}!Node {
        const tok = self.cur;
        self.eat(); // (
        self.eatNl();
        var vals = ArrayList(Node).init(self.alloc);
        var prev_sep = true;
        while (self.cur.kind != .rparen and self.cur.kind != .eof) {
            if (self.cur.kind == .newline) {
                self.eat();
                continue;
            }
            if (self.cur.kind == .comma) {
                const comma = self.cur;
                if (prev_sep) try vals.append(self.emptyValueNode(comma));
                prev_sep = true;
                self.eat();
                continue;
            }
            const v = try self.parseValue();
            try vals.append(v);
            prev_sep = false;
        }
        _ = self.expect(.rparen);
        return self.mkNode(.tuple, tok, try vals.toOwnedSlice());
    }

    fn parseArray(self: *Parser) error{OutOfMemory}!Node {
        const tok = self.cur;
        self.eat(); // [
        self.eatNl();
        var vals = ArrayList(Node).init(self.alloc);
        var prev_sep = true;
        while (self.cur.kind != .rbracket and self.cur.kind != .eof) {
            if (self.cur.kind == .newline) {
                self.eat();
                continue;
            }
            if (self.cur.kind == .comma) {
                const comma = self.cur;
                if (prev_sep) try vals.append(self.emptyValueNode(comma));
                prev_sep = true;
                self.eat();
                continue;
            }
            const v = try self.parseValue();
            try vals.append(v);
            prev_sep = false;
        }
        _ = self.expect(.rbracket);
        return self.mkNode(.array, tok, try vals.toOwnedSlice());
    }

    fn parseValue(self: *Parser) error{OutOfMemory}!Node {
        const t = self.cur;
        switch (self.cur.kind) {
            .string, .number, .bool_val, .plain_str, .ident => {
                self.eat();
                return self.mkNode(.value, t, self.noChildren());
            },
            .lbrace => {
                self.diag("inline object data is not supported; use tuple data '(...)' matching the schema order", .{}, self.cur);
                return self.parseSchema();
            },
            .lparen => return self.parseTuple(),
            .lbracket => return self.parseArray(),
            else => {
                self.eat();
                return self.mkNode(.value, t, self.noChildren());
            },
        }
    }
};
