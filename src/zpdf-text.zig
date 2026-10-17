const std = @import("std");
const zpdf = @import("zpdf");

const usage =
    \\usage:
    \\  zpdf-text (<font> | --standard=NAME) [--index=N] [--variation=TAG=VALUE,...] [--size=PT]
    \\            [--direction=ltr|rtl] [--no-compress] --out=FILE (--unicodes=U+XXXX,... | --text-file=FILE)...
    \\
    \\--standard draws with one of the 12 standard fonts, named and not embedded, WinAnsi text only:
    \\helvetica, helvetica_bold, helvetica_oblique, helvetica_bold_oblique, times_roman, times_bold,
    \\times_italic, times_bold_italic, courier, courier_bold, courier_oblique, courier_bold_oblique.
    \\
    \\Each --unicodes is one line. --text-file is UTF-8, one line per line; an empty
    \\line takes its space but draws nothing. Lines are drawn in argument order.
    \\--no-compress writes streams without /FlateDecode, so the file can be read as text.
    \\--variation sets variable-font axes, as hb-shape --variations does: wght=700,wdth=80.
    \\It can be given more than once. A tag the font has no axis for is ignored, and a
    \\value outside the axis range is clamped to it.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var font_path: ?[]const u8 = null;
    var standard: ?zpdf.StandardFont = null;
    var index: i32 = 0;
    var size: f64 = 24;
    var direction: zpdf.Direction = .dont_know;
    var out_path: ?[]const u8 = null;
    var compress = true;
    var variations = std.array_list.Managed(zpdf.Variation).init(arena);
    var lines = std.array_list.Managed([]u8).init(arena);

    if (args.len < 2) {
        try writeStderr(io, usage);
        return 2;
    }

    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--index=")) {
            index = std.fmt.parseInt(i32, arg["--index=".len..], 10) catch {
                try writeStderr(io, "zpdf-text: invalid --index\n");
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--size=")) {
            size = std.fmt.parseFloat(f64, arg["--size=".len..]) catch {
                try writeStderr(io, "zpdf-text: invalid --size\n");
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--direction=")) {
            const d = arg["--direction=".len..];
            if (std.mem.eql(u8, d, "ltr")) {
                direction = .ltr;
            } else if (std.mem.eql(u8, d, "rtl")) {
                direction = .rtl;
            } else {
                try writeStderr(io, "zpdf-text: --direction must be ltr or rtl\n");
                return 2;
            }
        } else if (std.mem.startsWith(u8, arg, "--variation=")) {
            const parsed = zpdf.parseVariations(arena, arg["--variation=".len..]) catch {
                try writeStderr(io, "zpdf-text: invalid --variation, expected TAG=VALUE,...\n");
                return 2;
            };
            try variations.appendSlice(parsed);
        } else if (std.mem.eql(u8, arg, "--no-compress")) {
            compress = false;
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            out_path = arg["--out=".len..];
        } else if (std.mem.startsWith(u8, arg, "--unicodes=")) {
            const cps = parseUnicodes(arena, arg["--unicodes=".len..]) catch {
                try writeStderr(io, "zpdf-text: invalid --unicodes\n");
                return 2;
            };
            if (cps.len == 0) {
                try writeStderr(io, "zpdf-text: empty --unicodes list\n");
                return 2;
            }
            var utf8 = std.array_list.Managed(u8).init(arena);
            for (cps) |cp| {
                const cp21 = std.math.cast(u21, cp) orelse {
                    try writeStderr(io, "zpdf-text: invalid codepoint in --unicodes\n");
                    return 2;
                };
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp21, &buf) catch {
                    try writeStderr(io, "zpdf-text: invalid codepoint in --unicodes\n");
                    return 2;
                };
                try utf8.appendSlice(buf[0..n]);
            }
            try lines.append(try utf8.toOwnedSlice());
        } else if (std.mem.startsWith(u8, arg, "--text-file=")) {
            const text = std.Io.Dir.cwd().readFileAlloc(io, arg["--text-file=".len..], arena, .limited(256 * 1024 * 1024)) catch |err| {
                try printError(io, err);
                return 1;
            };
            if (!std.unicode.utf8ValidateSlice(text)) {
                try writeStderr(io, "zpdf-text: --text-file is not valid UTF-8\n");
                return 2;
            }
            var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
            while (it.next()) |line| {
                try lines.append(@constCast(std.mem.trimEnd(u8, line, "\r")));
            }
        } else if (std.mem.startsWith(u8, arg, "--standard=")) {
            standard = std.meta.stringToEnum(zpdf.StandardFont, arg["--standard=".len..]) orelse {
                try writeStderr(io, "zpdf-text: unknown --standard font\n");
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try writeStderr(io, usage);
            return 2;
        } else if (font_path == null) {
            font_path = arg;
        } else {
            try writeStderr(io, usage);
            return 2;
        }
    }

    // Exactly one of a font file and --standard; a standard font has no axes.
    if ((font_path == null) == (standard == null) or out_path == null or lines.items.len == 0 or
        (standard != null and variations.items.len != 0))
    {
        try writeStderr(io, usage);
        return 2;
    }

    var font: ?zpdf.Font = null;
    defer if (font) |*f| f.deinit();
    if (font_path) |path| {
        const font_bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024 * 1024));
        font = zpdf.Font.init(arena, font_bytes, index, variations.items) catch |err| {
            try printError(io, err);
            return 1;
        };
    }
    // The PDF streams into an unnamed file that replaces --out only once it
    // is complete, so a failed run leaves no partial PDF behind.
    var atomic = std.Io.Dir.cwd().createFileAtomic(io, out_path.?, .{ .replace = true }) catch |err| {
        try printError(io, err);
        return 1;
    };
    defer atomic.deinit(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var fw = atomic.file.writer(io, &file_buf);
    // A write error from zpdf is the file's; report the file's own error.
    const report = struct {
        fn f(fileIo: std.Io, fileWriter: *std.Io.File.Writer, err: anyerror) !void {
            try printError(fileIo, if (err == error.WriteFailed) fileWriter.err orelse err else err);
        }
    }.f;

    var doc = zpdf.Document.begin(arena, &fw.interface, .{ .compress = compress }) catch |err| {
        try report(io, &fw, err);
        return 1;
    };
    defer doc.deinit();
    const added = if (standard) |s| doc.addStandardFont(s) else doc.addFont(&font.?);
    const font_id = added catch |err| {
        try printError(io, err);
        return 1;
    };
    const page = doc.beginPage(612, 792) catch |err| {
        try printError(io, err);
        return 1;
    };

    var y: f64 = 720;
    const opts = zpdf.ShapeOptions{ .paragraph_direction = direction };
    for (lines.items) |line| {
        if (line.len == 0) {
            y -= 1.5 * size;
            continue;
        }
        doc.drawText(page, font_id, size, 72, y, .black, line, opts) catch |err| {
            try printError(io, err);
            return 1;
        };
        y -= 1.5 * size;
    }
    doc.endPage(page) catch |err| {
        try report(io, &fw, err);
        return 1;
    };
    doc.finish() catch |err| {
        try report(io, &fw, err);
        return 1;
    };
    fw.interface.flush() catch {
        try printError(io, fw.err orelse error.WriteFailed);
        return 1;
    };
    atomic.replace(io) catch |err| {
        try printError(io, err);
        return 1;
    };
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

fn writeStderr(io: std.Io, msg: []const u8) !void {
    var err_buf: [8 * 1024]u8 = undefined;
    var err_w: std.Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    try err_w.interface.writeAll(msg);
    try err_w.interface.flush();
}

fn printError(io: std.Io, err: anyerror) !void {
    var err_buf: [8 * 1024]u8 = undefined;
    var err_w: std.Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    try err_w.interface.print("zpdf-text: {t}\n", .{err});
    try err_w.interface.flush();
}
