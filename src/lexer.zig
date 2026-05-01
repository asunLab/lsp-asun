//! Lexer — tokenises ASUN source.
//! Matches the token set from the Go asun-lsp implementation.

const std = @import("std");
const ArrayList = std.array_list.Managed;

// ── Token types ────────────────────────────────────────────────────────────────

pub const TokKind = enum(u8) {
    lbrace, // {
    rbrace, // }
    lparen, // (
    rparen, // )
    lbracket, // [
    rbracket, // ]
    colon, // :
    at, // @
    comma, // ,
    ident, // field name
    type_hint, // int str float bool
    string, // "..."
    number, // integer or float literal
    bool_val, // true / false
    plain_str, // unquoted value token
    comment, // /* ... */
    newline, // \n
    eof,
    err,
};

pub const Token = struct {
    kind: TokKind,
    value: []const u8, // slice into source
    line: u32, // 0-based
    col: u32, // 0-based byte col
    end_line: u32,
    end_col: u32,
    offset: u32,
    end_off: u32,
};

// ── Lexer ──────────────────────────────────────────────────────────────────────

pub const Lexer = struct {
    src: []const u8,
    pos: u32 = 0,
    line: u32 = 0,
    col: u32 = 0,
    in_schema: bool = false,

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src };
    }

    fn peek(self: *Lexer) u8 {
        if (self.pos >= self.src.len) return 0;
        return self.src[self.pos];
    }

    fn advance(self: *Lexer, n: u32) void {
        var i: u32 = 0;
        while (i < n and self.pos < self.src.len) : (i += 1) {
            if (self.src[self.pos] == '\n') {
                self.line += 1;
                self.col = 0;
            } else {
                self.col += 1;
            }
            self.pos += 1;
        }
    }

    fn skipWsNoNl(self: *Lexer) void {
        while (self.pos < self.src.len) {
            const b = self.src[self.pos];
            if (b == ' ' or b == '\t' or b == '\r') {
                self.advance(1);
            } else break;
        }
    }

    fn tok(self: *Lexer, kind: TokKind, start: u32, sl: u32, sc: u32) Token {
        return .{
            .kind = kind,
            .value = self.src[start..self.pos],
            .line = sl,
            .col = sc,
            .end_line = self.line,
            .end_col = self.col,
            .offset = start,
            .end_off = self.pos,
        };
    }

    pub fn next(self: *Lexer) Token {
        self.skipWsNoNl();
        if (self.pos >= self.src.len) {
            return .{ .kind = .eof, .value = "", .line = self.line, .col = self.col, .end_line = self.line, .end_col = self.col, .offset = self.pos, .end_off = self.pos };
        }

        const start = self.pos;
        const sl = self.line;
        const sc = self.col;
        const b = self.src[self.pos];

        if (b == '\n') {
            self.advance(1);
            return self.tok(.newline, start, sl, sc);
        }

        // Comment /* ... */
        if (b == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '*') {
            return self.lexComment(start, sl, sc);
        }

        switch (b) {
            '{' => {
                self.advance(1);
                self.in_schema = true;
                return self.tok(.lbrace, start, sl, sc);
            },
            '}' => {
                self.advance(1);
                return self.tok(.rbrace, start, sl, sc);
            },
            '(' => {
                self.advance(1);
                self.in_schema = false;
                return self.tok(.lparen, start, sl, sc);
            },
            ')' => {
                self.advance(1);
                return self.tok(.rparen, start, sl, sc);
            },
            '[' => {
                self.advance(1);
                return self.tok(.lbracket, start, sl, sc);
            },
            ']' => {
                self.advance(1);
                return self.tok(.rbracket, start, sl, sc);
            },
            ':' => {
                self.advance(1);
                return self.tok(.colon, start, sl, sc);
            },
            '@' => {
                self.advance(1);
                return self.tok(.at, start, sl, sc);
            },
            ',' => {
                self.advance(1);
                return self.tok(.comma, start, sl, sc);
            },
            '"' => return self.lexString(start, sl, sc),
            else => {},
        }

        if (self.in_schema) return self.lexSchemaWord(start, sl, sc);
        return self.lexDataValue(start, sl, sc);
    }

    fn lexComment(self: *Lexer, start: u32, sl: u32, sc: u32) Token {
        self.advance(2); // skip /*
        const rest = self.src[self.pos..];
        if (std.mem.indexOf(u8, rest, "*/")) |idx| {
            self.advance(@intCast(idx + 2));
        } else {
            while (self.pos < self.src.len) self.advance(1);
            return self.tok(.err, start, sl, sc);
        }
        return self.tok(.comment, start, sl, sc);
    }

    fn lexString(self: *Lexer, start: u32, sl: u32, sc: u32) Token {
        self.advance(1); // skip opening "
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\\') {
                self.advance(2);
                continue;
            }
            if (c == '"') {
                self.advance(1);
                return self.tok(.string, start, sl, sc);
            }
            self.advance(1);
        }
        return self.tok(.err, start, sl, sc);
    }

    fn isIdentChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_';
    }

    fn lexSchemaWord(self: *Lexer, start: u32, sl: u32, sc: u32) Token {
        while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) {
            self.advance(1);
        }
        if (self.pos == start) {
            self.advance(1);
            return self.tok(.err, start, sl, sc);
        }
        const word = self.src[start..self.pos];
        if (std.mem.eql(u8, word, "int") or
            std.mem.eql(u8, word, "float") or
            std.mem.eql(u8, word, "str") or
            std.mem.eql(u8, word, "bool"))
        {
            return self.tok(.type_hint, start, sl, sc);
        }
        return self.tok(.ident, start, sl, sc);
    }

    fn lexDataValue(self: *Lexer, start: u32, sl: u32, sc: u32) Token {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ',' or c == ')' or c == ']' or c == '(' or c == '[' or
                c == '\n' or c == '\r') break;
            if (c == '\\' and self.pos + 1 < self.src.len) {
                self.advance(2);
                continue;
            }
            if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '*') break;
            self.advance(1);
        }
        const raw = self.src[start..self.pos];
        const trimmed = std.mem.trimEnd(u8, raw, " \t");
        if (trimmed.len == 0) return self.tok(.plain_str, start, sl, sc);
        if (std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "false"))
            return self.tok(.bool_val, start, sl, sc);
        if (isNumber(trimmed)) return self.tok(.number, start, sl, sc);
        return self.tok(.plain_str, start, sl, sc);
    }

    /// Collect all tokens until EOF.
    pub fn all(self: *Lexer, alloc: std.mem.Allocator) ![]Token {
        var list = ArrayList(Token).init(alloc);
        while (true) {
            const t = self.next();
            try list.append(t);
            if (t.kind == .eof or t.kind == .err) break;
        }
        return list.toOwnedSlice();
    }
};

pub fn isNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[i] == '-') i += 1;
    if (i >= s.len or s[i] < '0' or s[i] > '9') return false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        if (i >= s.len or s[i] < '0' or s[i] > '9') return false;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '-' or s[i] == '+')) i += 1;
        const exp_start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i == exp_start) return false;
    }
    return i == s.len;
}
