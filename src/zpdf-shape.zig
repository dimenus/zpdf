const std = @import("std");
const zpdf = @import("zpdf");

const usage =
    \\usage:
    \\  zpdf-shape <font> [--variation=TAG=VALUE,...] --unicodes=U+XXXX,U+YYYY
    \\
    \\Prints the glyphs as hb-shape --no-glyph-names does, in font units:
    \\[gid=cluster@x_offset,y_offset+x_advance|...]. Clusters are codepoint
    \\indexes. --variation is as in zpdf-text.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len != 3 and args.len != 4) {
        try writeStderr(io, usage);
        return 2;
    }

    const font_path = args[1];
    var variations: []const zpdf.Variation = &.{};
    if (args.len == 4) {
        if (!std.mem.startsWith(u8, args[2], "--variation=")) {
            try writeStderr(io, usage);
            return 2;
        }
        variations = zpdf.parseVariations(arena, args[2]["--variation=".len..]) catch {
            try writeStderr(io, "zpdf-shape: invalid --variation, expected TAG=VALUE,...\n");
            return 2;
        };
    }
    const unicodes_arg = args[args.len - 1];
    if (!std.mem.startsWith(u8, unicodes_arg, "--unicodes=")) {
        try writeStderr(io, usage);
        return 2;
    }
    const cp_text = unicodes_arg["--unicodes=".len..];
    const cps = try parseUnicodes(arena, cp_text);
    if (cps.len == 0) {
        try writeStderr(io, "zpdf-shape: empty --unicodes list\n");
        return 2;
    }

    const font_bytes = try std.Io.Dir.cwd().readFileAlloc(io, font_path, arena, .limited(256 * 1024 * 1024));
    var font = zpdf.Font.init(arena, font_bytes, 0, variations) catch |err| {
        try printError(io, err);
        return 1;
    };
    defer font.deinit();

    var utf8 = std.array_list.Managed(u8).init(arena);
    defer utf8.deinit();
    for (cps) |cp| {
        const cp21 = std.math.cast(u21, cp) orelse {
            try writeStderr(io, "zpdf-shape: invalid codepoint in --unicodes\n");
            return 2;
        };
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp21, &buf) catch {
            try writeStderr(io, "zpdf-shape: invalid codepoint in --unicodes\n");
            return 2;
        };
        try utf8.appendSlice(buf[0..n]);
    }

    var shaped = zpdf.shape(arena, &font, utf8.items, .{}) catch |err| {
        try printError(io, err);
        return 1;
    };
    defer shaped.deinit(arena);

    var out_buf: [8 * 1024]u8 = undefined;
    var out_w: std.Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    try out_w.interface.print("{f}\n", .{RunFmt{ .glyphs = shaped.glyphs }});
    try out_w.interface.flush();
    return 0;
}

fn parseUnicodes(arena: std.mem.Allocator, text: []const u8) ![]u32 {
    var list = std.array_list.Managed(u32).init(arena);
    errdefer list.deinit();
    var it = std.mem.tokenizeAny(u8, text, ", \t");
    while (it.next()) |raw| {
        var hex = raw;
        if (std.mem.startsWith(u8, hex, "U+") or std.mem.startsWith(u8, hex, "u+") or std.mem.startsWith(u8, hex, "0x")) {
            hex = hex[2..];
        }
        try list.append(try std.fmt.parseInt(u32, hex, 16));
    }
    return list.toOwnedSlice();
}

const RunFmt = struct {
    glyphs: []const zpdf.Glyph,

    pub fn format(self: RunFmt, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeByte('[');
        for (self.glyphs, 0..) |g, i| {
            if (i > 0) try w.writeByte('|');
            try w.print("{d}={d}", .{ g.id, g.cluster });
            if (g.offset_x != 0 or g.offset_y != 0) {
                try w.print("@{d},{d}", .{ g.offset_x, g.offset_y });
            }
            try w.print("+{d}", .{g.advance_x});
            if (g.advance_y != 0) {
                try w.print(",{d}", .{g.advance_y});
            }
        }
        try w.writeByte(']');
    }
};

fn writeStderr(io: std.Io, msg: []const u8) !void {
    var err_buf: [8 * 1024]u8 = undefined;
    var err_w: std.Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    try err_w.interface.writeAll(msg);
    try err_w.interface.flush();
}

fn printError(io: std.Io, err: anyerror) !void {
    var err_buf: [8 * 1024]u8 = undefined;
    var err_w: std.Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    try err_w.interface.print("zpdf-shape: {t}\n", .{err});
    try err_w.interface.flush();
}
