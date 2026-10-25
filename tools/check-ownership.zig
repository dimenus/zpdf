//! Fails when a function that takes an `Allocator` and returns a slice returns, on some path,
//! memory that did not come from that allocator.
//!
//!     check-ownership <file.zig>...
//!
//! The caller of such a function frees what it gets, so one path that returns something else
//! is a bad free waiting for the input that takes it. Two shapes are found, from the syntax
//! alone (std.zig.Ast):
//! - a literal: `return "abc";`, `return &.{x};`, or another string or array literal. An empty
//!   one is allowed: freeing a zero-length slice does nothing (Allocator.free), except under a
//!   sentinel type (`[:0]u8`), where it is still found.
//! - a parameter or a part of one: `return raw;`, `return stream.data;`, `return input[1..];`.
//!   `dupe` it, or say in the type that the result may borrow: take a
//!   `*std.heap.ArenaAllocator` (or a type holding one, as src/read.zig's Scope does) instead of
//!   an `Allocator`, so the caller has no allocation to free.
//!
//! A function counts when a parameter's type is `Allocator` (its last name; `ArenaAllocator` is
//! not) and its return type has a slice (`[]`) in it. What the syntax cannot see is not found:
//! a struct holding slices, a local that aliases a parameter, a branch of an `if` or `orelse`,
//! memory from another allocator than the one passed. So a pass is a floor, not a proof. A
//! function nested in another is checked on its own.

const std = @import("std");
const Ast = std.zig.Ast;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: check-ownership <file.zig>...\n", .{});
        std.process.exit(2);
    }
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    var found: usize = 0;
    var checked: usize = 0;
    for (args[1..]) |path| {
        const source = try cwd.readFileAllocOptions(io, path, arena, .limited(1 << 24), .of(u8), 0);
        var tree = try Ast.parse(arena, source, .{});
        if (tree.errors.len != 0) {
            std.debug.print("{s}: does not parse\n", .{path});
            std.process.exit(2);
        }
        const r = try checkTree(arena, &tree);
        checked += r.checked;
        for (r.findings) |f| {
            const loc = tree.tokenLocation(0, f.token);
            std.debug.print("{s}:{d}: {s} returns {s} `{s}`, but takes an allocator and returns a slice\n", .{
                path, loc.line + 1, f.function, @tagName(f.kind), f.expr,
            });
        }
        found += r.findings.len;
    }
    // A run that saw no function of this kind checked nothing; say so instead of passing.
    if (checked == 0) {
        std.debug.print("check-ownership: no function takes an allocator and returns a slice\n", .{});
        std.process.exit(1);
    }
    if (found != 0) std.process.exit(1);
}

const Kind = enum { literal, parameter };

const Finding = struct {
    function: []const u8,
    token: Ast.TokenIndex,
    kind: Kind,
    expr: []const u8,
};

const Result = struct { checked: usize, findings: []const Finding };

fn checkTree(arena: std.mem.Allocator, tree: *const Ast) !Result {
    // Each function body's token range, so a `return` is given to the innermost one.
    const Body = struct { node: Ast.Node.Index, first: Ast.TokenIndex, last: Ast.TokenIndex };
    var bodies: std.ArrayList(Body) = .empty;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .fn_decl) continue;
        const body = tree.nodeData(node).node_and_node[1];
        try bodies.append(arena, .{ .node = node, .first = tree.firstToken(body), .last = tree.lastToken(body) });
    }

    var findings: std.ArrayList(Finding) = .empty;
    var checked: usize = 0;
    for (bodies.items) |b| {
        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, b.node).?;
        const ret = proto.ast.return_type.unwrap() orelse continue;
        const ret_source = tree.getNodeSource(ret);
        if (std.mem.indexOf(u8, ret_source, "[]") == null and std.mem.indexOf(u8, ret_source, "[:") == null) continue;
        const sentinel = std.mem.indexOf(u8, ret_source, "[:") != null;

        var params: std.ArrayList([]const u8) = .empty;
        var takes_allocator = false;
        var it = proto.iterate(tree);
        while (it.next()) |p| {
            const ty = p.type_expr orelse continue;
            if (isAllocator(tree.getNodeSource(ty))) {
                takes_allocator = true;
            } else if (p.name_token) |t| try params.append(arena, tree.tokenSlice(t));
        }
        if (!takes_allocator) continue;
        checked += 1;

        var t = b.first;
        while (t <= b.last) : (t += 1) {
            if (tree.tokenTag(t) != .keyword_return) continue;
            if (!innermost(bodies.items, b, t)) continue;
            const end = exprEnd(tree, t + 1, b.last);
            if (end == t + 1) continue; // `return;`
            const kind = classify(tree, t + 1, end, params.items, sentinel) orelse continue;
            const first = tree.tokenStart(t + 1);
            const last = tree.tokenStart(end - 1) + tree.tokenSlice(end - 1).len;
            try findings.append(arena, .{
                .function = if (proto.name_token) |n| tree.tokenSlice(n) else "(anonymous)",
                .token = t,
                .kind = kind,
                .expr = tree.source[first..last],
            });
        }
    }
    return .{ .checked = checked, .findings = findings.items };
}

/// Whether a parameter type is std.mem.Allocator: its last name is `Allocator`, so
/// `?std.mem.Allocator` is and `*std.heap.ArenaAllocator` is not.
fn isAllocator(ty: []const u8) bool {
    var end = ty.len;
    while (end > 0 and !isIdentChar(ty[end - 1])) end -= 1;
    var start = end;
    while (start > 0 and isIdentChar(ty[start - 1])) start -= 1;
    return std.mem.eql(u8, ty[start..end], "Allocator");
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Whether no function body inside `outer` contains token `t`.
fn innermost(bodies: anytype, outer: anytype, t: Ast.TokenIndex) bool {
    for (bodies) |b| {
        if (b.node == outer.node) continue;
        if (b.first >= outer.first and b.last <= outer.last and t >= b.first and t <= b.last) return false;
    }
    return true;
}

/// The token after a return's expression: its `;` at depth 0, or the `}` or `,` that closes the
/// block or switch prong it is in.
fn exprEnd(tree: *const Ast, start: Ast.TokenIndex, limit: Ast.TokenIndex) Ast.TokenIndex {
    var depth: usize = 0;
    var t = start;
    while (t <= limit) : (t += 1) switch (tree.tokenTag(t)) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => {
            if (depth == 0) return t;
            depth -= 1;
        },
        .semicolon, .comma => if (depth == 0) return t,
        else => {},
    };
    return t;
}

/// What the expression tokens [start, end) return, when it is one of the shapes found.
/// `sentinel`: the return type has one, so an empty literal is found too.
fn classify(tree: *const Ast, start: Ast.TokenIndex, end: Ast.TokenIndex, params: []const []const u8, sentinel: bool) ?Kind {
    switch (tree.tokenTag(start)) {
        .string_literal, .multiline_string_literal_line => {
            for (start + 1..end) |t| switch (tree.tokenTag(@intCast(t))) {
                .multiline_string_literal_line => {},
                else => return null,
            };
            const empty = end == start + 1 and std.mem.eql(u8, tree.tokenSlice(start), "\"\"");
            return if (empty and !sentinel) null else .literal;
        },
        // `&.{ ... }` or `&[_]T{ ... }`: an array literal, which is no allocation either.
        .ampersand => {
            const next = tree.tokenTag(start + 1);
            const literal = (next == .period and tree.tokenTag(start + 2) == .l_brace) or
                (next == .l_bracket and tree.tokenTag(end - 1) == .r_brace);
            if (!literal) return null;
            const empty = tree.tokenTag(end - 1) == .r_brace and tree.tokenTag(end - 2) == .l_brace;
            return if (empty and !sentinel) null else .literal;
        },
        .identifier => {
            const name = tree.tokenSlice(start);
            for (params) |p| {
                if (!std.mem.eql(u8, p, name)) continue;
                // Only `.field`, `.?`, `.*` and `[a..b]` after it: a part of the parameter, not
                // a call that made something new from it.
                var t = start + 1;
                while (t < end) : (t += 1) switch (tree.tokenTag(t)) {
                    .period, .identifier, .question_mark, .period_asterisk => {},
                    .l_bracket => {
                        var sliced = false;
                        while (t < end and tree.tokenTag(t) != .r_bracket) : (t += 1) {
                            if (tree.tokenTag(t) == .ellipsis2) sliced = true;
                            if (tree.tokenTag(t) == .l_paren) return null;
                        }
                        if (!sliced) return null;
                    },
                    else => return null,
                };
                return .parameter;
            }
            return null;
        },
        else => return null,
    }
}

test "each shape is found where an Allocator is passed, and nowhere else" {
    const source =
        \\const std = @import("std");
        \\const Allocator = std.mem.Allocator;
        \\fn param(gpa: Allocator, raw: []const u8) ![]const u8 { if (raw.len == 0) return gpa.dupe(u8, "x"); return raw; }
        \\fn field(gpa: std.mem.Allocator, s: S) []const u8 { _ = gpa; return s.data; }
        \\fn sliced(gpa: ?Allocator, in: []const u8) []const u8 { _ = gpa; return in[1..]; }
        \\fn literal(gpa: Allocator) []const u8 { _ = gpa; return "abc"; }
        \\fn array(gpa: Allocator) []const u32 { _ = gpa; return &.{ 1, 2 }; }
        \\fn sentinel(gpa: Allocator) [:0]const u8 { _ = gpa; return ""; }
        \\fn empty(gpa: Allocator) []const u8 { _ = gpa; return ""; }
        \\fn empty_array(gpa: Allocator) []const u32 { _ = gpa; return &.{}; }
        \\fn arena(a: *std.heap.ArenaAllocator, raw: []const u8) []const u8 { _ = a; return raw; }
        \\fn call(gpa: Allocator, raw: []const u8) ![]u8 { return gpa.dupe(u8, raw[1..]); }
        \\fn no_slice(gpa: Allocator, n: u32) u32 { _ = gpa; return n; }
        \\fn outer(gpa: Allocator, raw: []const u8) ![]u8 {
        \\    const inner = struct { fn f(raw: []const u8) []const u8 { return raw; } };
        \\    return gpa.dupe(u8, inner.f(raw));
        \\}
    ;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var tree = try Ast.parse(arena_state.allocator(), source, .{});
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    const r = try checkTree(arena_state.allocator(), &tree);
    // param, field, sliced, literal, array, sentinel, empty, empty_array, call, outer; not
    // arena, no_slice, or outer's inner function, whose `return raw` is its own.
    try std.testing.expectEqual(@as(usize, 10), r.checked);
    const want = [_]struct { []const u8, Kind }{
        .{ "param", .parameter },
        .{ "field", .parameter },
        .{ "sliced", .parameter },
        .{ "literal", .literal },
        .{ "array", .literal },
        .{ "sentinel", .literal },
    };
    try std.testing.expectEqual(want.len, r.findings.len);
    for (want, r.findings) |w, f| {
        try std.testing.expectEqualStrings(w[0], f.function);
        try std.testing.expectEqual(w[1], f.kind);
    }
}
