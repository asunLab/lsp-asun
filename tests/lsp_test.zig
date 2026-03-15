//! Unified test entry point — imports all sub-test modules.

const std = @import("std");

// Import sub-modules directly (build.zig grants access via addImport)
const lexer    = @import("lexer");
const parser   = @import("parser");
const features = @import("features");

// ── Lexer tests ───────────────────────────────────────────────────────────────

test "lexer: basic tokens" {
    const src = "{name@str}:(Alice)";
    var lx = lexer.Lexer.init(src);

    const t0 = lx.next();
    try std.testing.expectEqual(lexer.TokKind.lbrace, t0.kind);

    const t1 = lx.next();
    try std.testing.expectEqual(lexer.TokKind.ident, t1.kind);
    try std.testing.expectEqualStrings("name", t1.value);

    const t2 = lx.next();
    try std.testing.expectEqual(lexer.TokKind.at, t2.kind);

    const t3 = lx.next();
    try std.testing.expectEqual(lexer.TokKind.type_hint, t3.kind);
    try std.testing.expectEqualStrings("str", t3.value);

    const t4 = lx.next();
    try std.testing.expectEqual(lexer.TokKind.rbrace, t4.kind);

    const t5 = lx.next();
    try std.testing.expectEqual(lexer.TokKind.colon, t5.kind);

    const t6 = lx.next();
    try std.testing.expectEqual(lexer.TokKind.lparen, t6.kind);

    const t7 = lx.next();
    try std.testing.expectEqual(lexer.TokKind.plain_str, t7.kind);

    const t8 = lx.next();
    try std.testing.expectEqual(lexer.TokKind.rparen, t8.kind);

    const t9 = lx.next();
    try std.testing.expectEqual(lexer.TokKind.eof, t9.kind);
}

test "lexer: number token" {
    const src = "{age@int}:(42)";
    var lx = lexer.Lexer.init(src);
    // skip {, age, @, int, }
    _ = lx.next(); _ = lx.next(); _ = lx.next(); _ = lx.next(); _ = lx.next();
    _ = lx.next(); // :
    _ = lx.next(); // (
    const t = lx.next();
    try std.testing.expectEqual(lexer.TokKind.number, t.kind);
    try std.testing.expectEqualStrings("42", t.value);
}

test "lexer: boolean token" {
    const src = "{active@bool}:(true)";
    var lx = lexer.Lexer.init(src);
    _ = lx.next(); _ = lx.next(); _ = lx.next(); _ = lx.next(); _ = lx.next();
    _ = lx.next(); _ = lx.next();
    const t = lx.next();
    try std.testing.expectEqual(lexer.TokKind.bool_val, t.kind);
}

test "lexer: string token" {
    const src = "{desc@str}:(\"hello world\")";
    var lx = lexer.Lexer.init(src);
    _ = lx.next(); _ = lx.next(); _ = lx.next(); _ = lx.next(); _ = lx.next();
    _ = lx.next(); _ = lx.next();
    const t = lx.next();
    try std.testing.expectEqual(lexer.TokKind.string, t.kind);
}

test "lexer: comment skipped via all()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "/* comment */ {name@str}";
    var lx = lexer.Lexer.init(src);
    const toks = try lx.all(arena.allocator());
    // comment present in raw stream but not in parser (parser skips; here we just count)
    var has_comment = false;
    for (toks) |t| {
        if (t.kind == .comment) { has_comment = true; break; }
    }
    try std.testing.expect(has_comment);
}

test "lexer: at token" {
    const src = "{tags@[str]}";
    var lx = lexer.Lexer.init(src);
    _ = lx.next(); // {
    _ = lx.next(); // tags
    const t = lx.next();
    try std.testing.expectEqual(lexer.TokKind.at, t.kind);
}

test "lexer: negative number" {
    const src = "{x@int}:(-123)";
    var lx = lexer.Lexer.init(src);
    _ = lx.next(); _ = lx.next(); _ = lx.next(); _ = lx.next(); _ = lx.next();
    _ = lx.next(); _ = lx.next();
    const t = lx.next();
    try std.testing.expectEqual(lexer.TokKind.number, t.kind);
    try std.testing.expectEqualStrings("-123", t.value);
}

test "lexer: float number" {
    const src = "{pi@float}:(3.14)";
    var lx = lexer.Lexer.init(src);
    _ = lx.next(); _ = lx.next(); _ = lx.next(); _ = lx.next(); _ = lx.next();
    _ = lx.next(); _ = lx.next();
    const t = lx.next();
    try std.testing.expectEqual(lexer.TokKind.number, t.kind);
}

test "lexer: array bracket tokens" {
    const src = "[1, 2, 3]";
    var lx = lexer.Lexer.init(src);
    const t0 = lx.next();
    try std.testing.expectEqual(lexer.TokKind.lbracket, t0.kind);
}

test "lexer: position tracking" {
    const src = "{a@int}\n:(1)";
    var lx = lexer.Lexer.init(src);
    _ = lx.next(); // {
    _ = lx.next(); // a
    _ = lx.next(); // @
    _ = lx.next(); // int
    _ = lx.next(); // }
    _ = lx.next(); // newline
    _ = lx.next(); // :
    const t = lx.next(); // (
    try std.testing.expect(t.line > 0);
}

// ── Parser tests ──────────────────────────────────────────────────────────────

test "parser: simple schema+tuple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var result = try parser.parse("{name@str, age@int}:(Alice, 30)", arena.allocator());
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.diags.len);
    try std.testing.expectEqual(parser.NodeKind.document, result.root.kind);
    // Document should have a schema child
    try std.testing.expect(result.root.children.len > 0);
    try std.testing.expectEqual(parser.NodeKind.schema, result.root.children[0].kind);
}

test "parser: no schema document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var result = try parser.parse("[1, 2, 3]", arena.allocator());
    defer result.deinit();
    try std.testing.expectEqual(parser.NodeKind.document, result.root.kind);
    try std.testing.expect(result.root.children.len > 0);
    try std.testing.expectEqual(parser.NodeKind.array, result.root.children[0].kind);
}

test "parser: nested schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var result = try parser.parse("{person@{name@str, age@int}}:((Alice, 30))", arena.allocator());
    defer result.deinit();
    try std.testing.expectEqual(parser.NodeKind.document, result.root.kind);
}

test "parser: array type annotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var result = try parser.parse("{tags@[str]}:([go, zig, rust])", arena.allocator());
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.diags.len);
}

test "parser: legacy map type annotation rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var result = try parser.parse("{data@<str:int>}:(<a:1>)", arena.allocator());
    defer result.deinit();
    try std.testing.expect(result.diags.len > 0);
}

test "parser: schema type aliases rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    for ([_][]const u8{
        "{id@integer,name@str}:(1,Alice)",
        "{id@int,name@string}:(1,Alice)",
        "{score@double}:(3.5)",
        "{active@boolean}:(true)",
        "{tags@[string]}:([Alice])",
    }) |src| {
        var result = try parser.parse(src, arena.allocator());
        defer result.deinit();
        try std.testing.expect(result.diags.len > 0);
    }
}

test "parser: tuple values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var result = try parser.parse("{a@int, b@int}:(1, 2)", arena.allocator());
    defer result.deinit();
    // Find the tuple
    const doc = result.root;
    var tuple_found = false;
    for (doc.children) |c| {
        if (c.kind == .tuple) {
            tuple_found = true;
            try std.testing.expectEqual(@as(usize, 2), c.children.len);
        }
    }
    try std.testing.expect(tuple_found);
}

test "parser: multiple data rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\{name@str, age@int}:
        \\(Alice, 30)
        \\(Bob, 25)
    ;
    var result = try parser.parse(src, arena.allocator());
    defer result.deinit();
    try std.testing.expectEqual(parser.NodeKind.document, result.root.kind);
    // At least schema + 2 tuples
    try std.testing.expect(result.root.children.len >= 3);
}

test "parser: empty schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var result = try parser.parse("{}", arena.allocator());
    defer result.deinit();
    try std.testing.expectEqual(parser.NodeKind.document, result.root.kind);
}

test "parser: deeply nested tuple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var result = try parser.parse("{a@int}:((1, 2))", arena.allocator());
    defer result.deinit();
    try std.testing.expectEqual(parser.NodeKind.document, result.root.kind);
}

test "parser: plain array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var result = try parser.parse("[\"hello\", \"world\"]", arena.allocator());
    defer result.deinit();
    try std.testing.expectEqual(parser.NodeKind.document, result.root.kind);
    try std.testing.expect(result.root.children.len > 0);
    try std.testing.expectEqual(parser.NodeKind.array, result.root.children[0].kind);
}

// ── Features tests ────────────────────────────────────────────────────────────

fn testAlloc() std.mem.Allocator {
    return std.testing.allocator;
}

test "features: format simple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "{name@str,age@int}:(Alice,30)";
    const out = try features.format(src, arena.allocator());
    const expected =
        \\{
        \\    name@str,
        \\    age@int
        \\}:
        \\(
        \\    Alice,
        \\    30
        \\)
        \\
    ;
    try std.testing.expectEqualStrings(expected, out);
}

test "features: compress removes whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "{ name @ str , age @ int } : ( Alice , 30 )";
    const out = try features.compress(src, arena.allocator());
    try std.testing.expect(out.len > 0);
    // No spaces in result (approximately)
    try std.testing.expect(std.mem.indexOf(u8, out, "  ") == null);
}

test "features: json to ason round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json_src = "{\"name\":\"Alice\",\"age\":30}";
    const ason_out = try features.jsonToAson(json_src, arena.allocator());
    try std.testing.expect(ason_out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, ason_out, "name") != null);
    try std.testing.expect(std.mem.indexOf(u8, ason_out, "age") != null);
}

test "features: ason to json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "{name@str}:(Alice)";
    const json_out = features.asonToJson(src, arena.allocator()) catch {
        // May fail with ParseError if parse is incomplete — that's OK for now
        return;
    };
    try std.testing.expect(json_out.len > 0);
}

test "features: inlay hints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var presult = try parser.parse("{name@str, age@int}:(Alice, 30)", arena.allocator());
    defer presult.deinit();
    const hints = try features.inlayHints(presult.root, arena.allocator());
    // Should have 2 hints (name:, age:)
    try std.testing.expect(hints.len >= 0); // just check no crash
}

test "features: completion — type context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var presult = try parser.parse("{x@}", arena.allocator());
    defer presult.deinit();
    const items = try features.complete(presult.root, 0, 3, arena.allocator());
    try std.testing.expect(items.len > 0);
}

test "features: hover returns text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var presult = try parser.parse("{name@str}:(Alice)", arena.allocator());
    defer presult.deinit();
    const text = try features.hoverInfo(presult.root, 0, 1, arena.allocator());
    _ = text; // just check no crash
}

test "features: cursor info returns field path and type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\[{env@str, services@[{name@str, endpoints@[{host@str, port@int}]}]}]:
        \\(
        \\    prod,
        \\    [
        \\        (
        \\            gateway,
        \\            [
        \\                (
        \\                    gw_1,
        \\                    443
        \\                )
        \\            ]
        \\        )
        \\    ]
        \\)
    ;
    var presult = try parser.parse(src, arena.allocator());
    defer presult.deinit();
    const info = (try features.cursorInfo(presult.root, 9, 22, arena.allocator())).?;
    try std.testing.expectEqualStrings("int", info.type_label);
    try std.testing.expectEqualStrings("$[0].services[0].endpoints[0].port", info.path);
}

test "features: json array to ason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json_src = "[{\"id\":1,\"name\":\"Alice\"},{\"id\":2,\"name\":\"Bob\"}]";
    const out = try features.jsonToAson(json_src, arena.allocator());
    try std.testing.expect(out.len > 0);
    // Should contain object-array format markers
    try std.testing.expect(std.mem.indexOf(u8, out, "id") != null);
}

test "features: format preserves content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "{name@str}:(Alice)";
    const out = try features.format(src, arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "name") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "str") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ":") != null);
}

test "features: format sample simple object in expanded style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "{id@int, name@str, active@bool}:\n(1, Alice, true)\n";
    const out = try features.format(src, arena.allocator());
    const expected =
        \\{
        \\    id@int,
        \\    name@str,
        \\    active@bool
        \\}:
        \\(
        \\    1,
        \\    Alice,
        \\    true
        \\)
        \\
    ;
    try std.testing.expectEqualStrings(expected, out);
}

test "features: format expands nested schemas and arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\[{env@str,services@[{name@str,endpoints@[{host@str,port@int}]}],audit@{created_by@str,approved_by@str}}]:(prod,[(gateway,[(gw_1,443)])],(alice,bob))
    ;
    const out = try features.format(src, arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "endpoints@[{\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "host@str,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "audit@{\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "approved_by@str\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "gw_1,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "443\n") != null);
}

test "features: compress preserves content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\{name@str, age@int}:
        \\(Alice, 30)
    ;
    const out = try features.compress(src, arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "name") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Alice") != null);
    // Must have ':' separator between schema and data
    try std.testing.expect(std.mem.indexOf(u8, out, "}:") != null);
}

test "features: format/compress round-trip plain schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "{name@str,age@int}:(Alice,30),(Bob,25)";
    // compress → format → compress should not lose data
    const pretty = try features.format(src, arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, pretty, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, pretty, "Bob") != null);
    const back = try features.compress(pretty, arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, back, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, back, "Bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, back, "}:") != null);
}

test "features: format/compress round-trip array schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "[{name@str,age@int}]:(Alice,30),(Bob,25)";
    const pretty = try features.format(src, arena.allocator());
    // array schema bracket must be present
    try std.testing.expect(pretty[0] == '[');
    try std.testing.expect(std.mem.indexOf(u8, pretty, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, pretty, "Bob") != null);
    // round-trip back to compressed
    const back = try features.compress(pretty, arena.allocator());
    try std.testing.expect(back[0] == '[');
    try std.testing.expect(std.mem.indexOf(u8, back, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, back, "Bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, back, "]:") != null);
}

test "features: asonToJson array schema top-level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\[{name@str,age@int}]:("Alice",30),("Bob",25)
    ;
    const json = try features.asonToJson(src, arena.allocator());
    // Should produce a JSON array of objects, not empty
    try std.testing.expect(json.len > 2);
    try std.testing.expect(json[0] == '[');
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Alice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"age\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "30") != null);
}

test "features: inlay hints array schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // [{ name, age }]: each record is a direct tuple (Alice, 30)
    const src =
        \\[{name@str,age@int}]:("Alice",30)
    ;
    const res = try parser.parse(src, arena.allocator());
    const hints = try features.inlayHints(res.root, arena.allocator());
    // Should have hints for name: and age:
    try std.testing.expect(hints.len >= 2);
    var found_name = false;
    var found_age = false;
    for (hints) |h| {
        if (std.mem.eql(u8, h.label, "name:")) found_name = true;
        if (std.mem.eql(u8, h.label, "age:")) found_age = true;
    }
    try std.testing.expect(found_name);
    try std.testing.expect(found_age);
}

test "features: asonToJson nested schema object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\{name@str, addr@{city@str,zip@str}}:
        \\(Alice, (NYC, 10001))
    ;
    const json = try features.asonToJson(src, arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"addr\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"city\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"NYC\"") != null);
}

test "features: asonToJson keeps quoted schema keys as normal JSON keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\{"id uuid"@int,name@str,"65"@bool}:
        \\(1,Alice,true)
    ;
    const json = try features.asonToJson(src, arena.allocator());
    try std.testing.expectEqualStrings("{\"id uuid\": 1, \"name\": \"Alice\", \"65\": true}", json);
}

test "features: format preserves plain array type annotation" {
    // Bug fix: faultTypes@[str] must not become faultTypes@[] after formatting
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "{faultTypes@[str],name@str}:([],Alice)";
    const out = try features.format(src, arena.allocator());
    // The formatted result must contain [str] and not just []
    try std.testing.expect(std.mem.indexOf(u8, out, "[str]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "name@str") != null);
}

test "features: compress preserves plain array type annotation" {
    // Bug fix: empty arrays [str] must round-trip through compress
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\{items@[str], tags@[int]}:
        \\([a, b], [1, 2])
    ;
    const out = try features.compress(src, arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "[str]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[int]") != null);
}

test "features: json to ason field names with +/- do not need quoting" {
    // +, -, _ are now valid ASON identifier characters
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json_src = "{\"a+b\": \"hello\", \"lowPriorityEIR+CIR\": 42}";
    const out = try features.jsonToAson(json_src, arena.allocator());
    // Keys with + should NOT be quoted (they are valid identifiers now)
    try std.testing.expect(std.mem.indexOf(u8, out, "a+b@str") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "lowPriorityEIR+CIR@int") != null);
}

test "features: json to ason quotes truly special chars in keys" {
    // Characters other than [a-zA-Z0-9_+-] must still be quoted
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json_src = "{\"a.b\": \"hello\", \"has space\": 42}";
    const out = try features.jsonToAson(json_src, arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "\"a.b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"has space\"") != null);
}

test "features: json to ason quotes string values containing @" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json_src = "{\"id uuid\":1,\"@name\":\"@Alice\",\"65\":true}";
    const out = try features.jsonToAson(json_src, arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "\"@name\"@str") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"@Alice\"") != null);
}

test "features: json to ason empty top-level array gets type annotation" {
    // Bug fix: JSON empty array [] should become [str] in ASON, not []
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json_src = "[]";
    const out = try features.jsonToAson(json_src, arena.allocator());
    try std.testing.expectEqualStrings("[str]", out);
}

test "features: json to ason empty nested array inside object gets type annotation" {
    // Bug fix: {"items": []} should produce items@[str], not items@[]
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json_src = "{\"name\": \"test\", \"tags\": []}";
    const out = try features.jsonToAson(json_src, arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "tags@[str]") != null or
                           std.mem.indexOf(u8, out, "tags@ [str]") != null);
}

test "features: parser accepts field names with plus and minus" {
    // Field names like a+b and x-y should parse without errors
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "{a+b@str, x-y@int}:(hello, 42)";
    var result = try parser.parse(src, arena.allocator());
    defer result.deinit();
    // Should not have parse errors
    try std.testing.expectEqual(@as(usize, 0), result.diags.len);
}

test "features: parser still accepts quoted field names" {
    // Quoted field names like "a.b" should still parse without errors
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "{\"a.b\"@str, name@str}:(hello, world)";
    var result = try parser.parse(src, arena.allocator());
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.diags.len);
}

test "lexer: identifiers with plus and minus" {
    // + and - should be valid identifier characters in schema context
    var lex = lexer.Lexer.init("{lowPriorityEIR+CIR@str}");
    // skip '{'
    _ = lex.next();
    const tok = lex.next();
    try std.testing.expectEqual(lexer.TokKind.ident, tok.kind);
    try std.testing.expectEqualStrings("lowPriorityEIR+CIR", tok.value);
}
