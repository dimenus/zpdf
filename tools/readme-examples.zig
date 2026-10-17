//! Fails when a README code example differs from the tested code it shows.
//!
//!     readme-examples <README.md> <source file>
//!
//! In the README, `<!-- example: <name> -->` comes just before a fenced code block. In the source
//! file (a test that compiles and runs), the same code sits between `// readme: <name>` and
//! `// readme: end`, indented as the code around it. Each named block must equal the source's,
//! once the source's common indentation is removed, and every name must appear on both sides.

const std = @import("std");

const Examples = std.StringArrayHashMapUnmanaged([]const u8);

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: readme-examples <README.md> <source file>\n", .{});
        std.process.exit(2);
    }
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const readme = try readmeExamples(arena, try cwd.readFileAlloc(io, args[1], arena, .limited(1 << 22)));
    const source = try sourceExamples(arena, try cwd.readFileAlloc(io, args[2], arena, .limited(1 << 22)));
    // A parse that found nothing would compare nothing and pass; that is a failure instead.
    if (readme.count() == 0) fail("{s}: no `<!-- example: name -->` blocks", .{args[1]});

    var bad = false;
    for (readme.keys(), readme.values()) |name, code| {
        const tested = source.get(name) orelse {
            std.debug.print("{s}: example \"{s}\" has no `// readme: {s}` block in {s}\n", .{ args[1], name, name, args[2] });
            bad = true;
            continue;
        };
        if (!std.mem.eql(u8, code, tested)) {
            std.debug.print("{s}: example \"{s}\" differs from {s}'s; copy the tested code into the README\n", .{ args[1], name, args[2] });
            bad = true;
        }
    }
    for (source.keys()) |name| if (!readme.contains(name)) {
        std.debug.print("{s}: block \"{s}\" is shown nowhere in {s}\n", .{ args[2], name, args[1] });
        bad = true;
    };
    if (bad) std.process.exit(1);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

/// Each `<!-- example: name -->` and the fenced block that follows it: its lines, without the
/// fences.
fn readmeExamples(arena: std.mem.Allocator, text: []const u8) !Examples {
    var out: Examples = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const prefix = "<!-- example: ";
        if (!std.mem.startsWith(u8, line, prefix) or !std.mem.endsWith(u8, line, " -->")) continue;
        const name = line[prefix.len .. line.len - " -->".len];
        const fence = lines.next() orelse fail("README: example \"{s}\" ends the file", .{name});
        if (!std.mem.startsWith(u8, fence, "```")) fail("README: example \"{s}\" is not followed by a code block", .{name});
        var code: std.ArrayList(u8) = .empty;
        while (lines.next()) |body| {
            if (std.mem.eql(u8, body, "```")) break;
            try code.appendSlice(arena, body);
            try code.append(arena, '\n');
        } else fail("README: example \"{s}\" has no closing fence", .{name});
        if (try out.fetchPut(arena, name, code.items)) |_| fail("README: example \"{s}\" appears twice", .{name});
    }
    return out;
}

/// Each `// readme: name` ... `// readme: end` block, with the common indentation removed.
fn sourceExamples(arena: std.mem.Allocator, text: []const u8) !Examples {
    var out: Examples = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        const prefix = "// readme: ";
        if (!std.mem.startsWith(u8, trimmed, prefix)) continue;
        const name = trimmed[prefix.len..];
        if (std.mem.eql(u8, name, "end")) fail("source: `// readme: end` with no block open", .{});
        var body: std.ArrayList([]const u8) = .empty;
        while (lines.next()) |inner| {
            if (std.mem.eql(u8, std.mem.trim(u8, inner, " \r"), "// readme: end")) break;
            try body.append(arena, std.mem.trimEnd(u8, inner, "\r"));
        } else fail("source: block \"{s}\" has no `// readme: end`", .{name});
        var indent: usize = std.math.maxInt(usize);
        for (body.items) |b| {
            if (std.mem.trim(u8, b, " ").len == 0) continue;
            indent = @min(indent, b.len - std.mem.trimStart(u8, b, " ").len);
        }
        var code: std.ArrayList(u8) = .empty;
        for (body.items) |b| {
            if (b.len >= indent) try code.appendSlice(arena, b[indent..]);
            try code.append(arena, '\n');
        }
        if (try out.fetchPut(arena, name, code.items)) |_| fail("source: block \"{s}\" appears twice", .{name});
    }
    return out;
}
