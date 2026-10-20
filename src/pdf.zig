//! Document API and the PDF 1.7 file writer (Type 0 / CIDFontType2 / Identity-H).

const std = @import("std");
const zpdf = @import("root.zig");
const sfnt = @import("sfnt.zig");
const instancer = @import("instancer.zig");
const text_map = @import("text_map.zig");
const winansi = @import("winansi.zig");
const image = @import("image.zig");
const ManagedList = std.array_list.Managed;

pub const FontId = enum(u32) { _ };
pub const PageId = enum(u32) { _ };
/// A place reserved on a page by reserveLater, drawn by drawTextLater.
pub const LaterId = enum(u32) { _ };
/// An image added by addImage, drawn by drawImage.
pub const ImageId = enum(u32) { _ };

/// A DeviceRGB colour, each component from 0 to 1. Every drawing call takes one;
/// a component outside 0..1, or not finite, is error.InvalidColor.
pub const Color = struct {
    r: f64,
    g: f64,
    b: f64,

    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Color = .{ .r = 1, .g = 1, .b = 1 };

    fn check(c: Color) !void {
        for ([3]f64{ c.r, c.g, c.b }) |v| {
            if (!(v >= 0 and v <= 1)) return error.InvalidColor;
        }
    }
};

/// One drawing call on the open page, in call order: later ops paint over earlier ones.
/// Its slices live in the Document's page arena until its page ends.
const DrawOp = union(enum) {
    text: TextOp,
    line: struct { x1: f64, y1: f64, x2: f64, y2: f64, width: f64, color: Color },
    rect: struct { x: f64, y: f64, width: f64, height: f64, paint: Paint, color: Color },
    /// A reserveLater: paints the form XObject with this object number.
    later: u32,
    /// A drawImage: paints images[index], whose object is `object`, through `matrix` (cm).
    image: struct { index: u32, object: u32, matrix: [6]f64 },
};

const Paint = union(enum) {
    fill,
    /// The outline, with this line width.
    stroke: f64,
};

/// One drawText.
const TextOp = struct {
    font_id: FontId,
    size_pt: f64,
    x_pt: f64,
    y_pt: f64,
    color: Color,
    text: union(enum) {
        /// An embedded font's line: shaped glyphs and their CIDs and ActualText.
        shaped: struct { glyphs: []const zpdf.Glyph, mapping: text_map.Mapping },
        /// A standard font's line: WinAnsi bytes, drawn left to right.
        winansi: []const u8,
    },
};

/// The 12 standard text fonts every PDF reader provides (ISO 32000-1 9.6.2.2). They are named,
/// not embedded, and draw WinAnsi text with no shaping: the fast path for plain Latin text.
/// Symbol and ZapfDingbats, the other two standard fonts, have their own encodings and are left out.
pub const StandardFont = enum {
    helvetica,
    helvetica_bold,
    helvetica_oblique,
    helvetica_bold_oblique,
    times_roman,
    times_bold,
    times_italic,
    times_bold_italic,
    courier,
    courier_bold,
    courier_oblique,
    courier_bold_oblique,

    /// The /BaseFont name the PDF uses.
    pub fn baseFont(self: StandardFont) []const u8 {
        return switch (self) {
            .helvetica => "Helvetica",
            .helvetica_bold => "Helvetica-Bold",
            .helvetica_oblique => "Helvetica-Oblique",
            .helvetica_bold_oblique => "Helvetica-BoldOblique",
            .times_roman => "Times-Roman",
            .times_bold => "Times-Bold",
            .times_italic => "Times-Italic",
            .times_bold_italic => "Times-BoldItalic",
            .courier => "Courier",
            .courier_bold => "Courier-Bold",
            .courier_oblique => "Courier-Oblique",
            .courier_bold_oblique => "Courier-BoldOblique",
        };
    }
};

/// The page between beginPage and endPage; the document has at most one.
const OpenPage = struct {
    id: PageId,
    width_pt: f64,
    height_pt: f64,
    /// Its page object; the content stream is the next number.
    object: u32,
    /// In the page arena.
    ops: std.ArrayList(DrawOp) = .empty,
};

/// One reserveLater: a form XObject the page paints, written by drawTextLater.
const Later = struct {
    object: u32,
    /// Its page's size: the form's /BBox, so it draws in page coordinates.
    width_pt: f64,
    height_pt: f64,
    written: bool = false,
};

/// What an added image leaves in the document: its pixels are already written.
const DocImage = struct {
    object: u32,
    shown_width: u32,
    shown_height: u32,
    orientation: image.Orientation,
};

const DocFont = union(enum) {
    embedded: EmbeddedFont,
    standard: StandardFont,
};

const EmbeddedFont = struct {
    /// Borrowed from the caller of addFont.
    font: *zpdf.Font,
    /// The font's tables, opened and checked once by addFont (sfnt.open
    /// validates every loca entry, so opening per drawText cost more than
    /// shaping did). Slices into `font.bytes`.
    face: sfnt.Face,
    used: std.DynamicBitSet,
    cids: text_map.CidRegistry,
    /// drawText's earlier results for this font, by cacheKey: report text
    /// repeats ("0", "CS", a vendor name), and a hit skips shaping and
    /// mapping. The values live in the document's cache_arena; the map's
    /// table is in gpa. Cleared by endPage when the arena passes its budget.
    shapes: std.StringHashMapUnmanaged(CachedShape) = .empty,
};

/// One cached drawText result. Its CIDs are this font's for good: an entry is
/// added only when its drawText succeeds, so its CIDs and used glyphs are
/// never rolled back.
const CachedShape = struct {
    glyphs: []const zpdf.Glyph,
    mapping: text_map.Mapping,
};

/// The shape cache key: everything zpdf.shape's result depends on besides the
/// font. Size and position are not in it, because shaping is in font units.
fn cacheKey(allocator: std.mem.Allocator, utf8: []const u8, options: zpdf.ShapeOptions) ![]u8 {
    // A ShapeOptions field left out of the key would make a hit return
    // another option's glyphs; a new field must be added here.
    comptime std.debug.assert(@typeInfo(zpdf.ShapeOptions).@"struct".field_names.len == 2);
    const key = try allocator.alloc(u8, 8 + utf8.len);
    std.mem.writeInt(u32, key[0..4], @backingInt(options.paragraph_direction), .little);
    std.mem.writeInt(u32, key[4..8], options.language, .little);
    @memcpy(key[8..], utf8);
    return key;
}

/// A PDF written page by page, so memory holds one page's drawing at a time.
///
/// How to use it:
///   var doc = try Document.begin(gpa, writer, .{ .compress = true });  // writes the header
///   defer doc.deinit();
///   const font = try doc.addFont(&loaded_font);        // or addStandardFont(.helvetica)
///   const logo = try doc.addImage(png_or_jpeg_bytes);   // written now; drawn by id
///   const page = try doc.beginPage(612, 792);           // one page open at a time
///   try doc.drawText(page, font, 24, 72, 720, .black, "office", .{});
///   try doc.drawImage(page, logo, 72, 600, 144, 72);    // bottom-left, then size, in points
///   try doc.endPage(page);                              // writes the page, frees its drawing
///   try doc.finish();                                   // fonts, page tree, catalog, xref
/// `writer` must stay valid until finish; finish flushes zpdf's buffer into it, and the caller
/// flushes the writer itself. Fonts are written by finish, because a font's subset needs every
/// glyph the document uses. Pages are numbered 0, 1, 2... in beginPage order.
///
/// Failure: drawText and drawShaped change nothing when they fail. A failed write (endPage,
/// finish) leaves a partial file, so the document then refuses every call with
/// error.DocumentFailed; deinit is still required. After finish, calls are
/// error.DocumentFinished.
/// Document.cache_budget's starting value; see cache_arena.
pub const default_cache_budget: usize = 1 << 20;
/// Document.max_image_bytes's starting value. image.decodePng says what counts against it.
pub const default_max_image_bytes: usize = 64 << 20;

pub const Document = struct {
    /// Lists that grow, and the per-font state that a failed drawText rolls
    /// back (used-glyph bits, the CID registry).
    gpa: std.mem.Allocator,
    /// The open page's drawing. Written only after a drawText has passed every
    /// check, so a failed drawText adds no op data; an OutOfMemory while
    /// copying can leave unreachable bytes here. Reset by endPage.
    page_arena: std.heap.ArenaAllocator,
    /// The shape cache's keys and values (EmbeddedFont.shapes). An op on the
    /// open page can point into it, so it is only cleared by endPage, after
    /// the page is written, and only when it holds more than cache_budget.
    cache_arena: std.heap.ArenaAllocator,
    cache_budget: usize = default_cache_budget,
    /// One drawText's working memory: shaping, mapping, checks. Reset at the
    /// start of every drawText.
    scratch: std.heap.ArenaAllocator,
    /// One endPage's or finish's working memory (a page's content stream, one
    /// font's subset). Reset after each.
    write_scratch: std.heap.ArenaAllocator,
    /// When set, drawText allocates through these instead of the arenas above.
    /// A caller can bound drawText's memory this way; a test wraps the arenas
    /// with FailingAllocator to fail each allocation, which failing `gpa`
    /// cannot do because an arena takes memory from its child in large blocks.
    scratch_allocator: ?std.mem.Allocator = null,
    page_allocator: ?std.mem.Allocator = null,
    cache_allocator: ?std.mem.Allocator = null,
    fonts: ManagedList(DocFont),
    /// Each font's first object number, given when a finished page first uses
    /// it; a font no page used gets none and is not written.
    font_objects: std.ArrayList(?u32) = .empty,
    /// The page object of every finished page, in order: the /Kids array.
    page_objects: std.ArrayList(u32) = .empty,
    open: ?OpenPage = null,
    /// Every reserveLater, by LaterId.
    laters: std.ArrayList(Later) = .empty,
    /// How many of `laters` drawTextLater has not written yet; finish needs 0.
    laters_open: u32 = 0,
    /// Every addImage, by ImageId.
    images: std.ArrayList(DocImage) = .empty,
    /// The most memory one addImage may hold while it decodes a PNG (image.decode's max_bytes);
    /// a PNG that needs more is error.TooLarge. A JPEG is not decoded and is not limited.
    max_image_bytes: usize = default_max_image_bytes,
    objects: ObjectWriter,
    /// The next free object number. 1 is the catalog and 2 the page tree,
    /// written by finish.
    next_object: u32 = 3,
    state: enum { writing, finished, failed } = .writing,

    pub fn begin(gpa: std.mem.Allocator, w: *std.Io.Writer, options: WriteOptions) !Document {
        const buffer = try gpa.alloc(u8, 4096);
        errdefer gpa.free(buffer);
        var deflate: ?*Deflate = null;
        if (options.compress) {
            const d = try gpa.create(Deflate);
            // Compress.init asserts its sink has room for at least 9 bytes.
            d.out = std.Io.Writer.Allocating.initCapacity(gpa, Deflate.kept_capacity) catch |err| {
                gpa.destroy(d);
                return err;
            };
            deflate = d;
        }
        var doc: Document = .{
            .gpa = gpa,
            .page_arena = .init(gpa),
            .cache_arena = .init(gpa),
            .scratch = .init(gpa),
            .write_scratch = .init(gpa),
            .fonts = ManagedList(DocFont).init(gpa),
            .objects = .{ .counted = .initHasher(w, .{}, buffer), .deflate = deflate },
        };
        errdefer doc.deinit();
        try doc.objects.out().writeAll("%PDF-1.7\n%\x80\x81\x82\x83\n");
        return doc;
    }

    pub fn deinit(self: *Document) void {
        for (self.fonts.items) |*f| switch (f.*) {
            .embedded => |*e| {
                e.used.deinit();
                e.cids.deinit();
                e.shapes.deinit(self.gpa);
            },
            .standard => {},
        };
        self.fonts.deinit();
        self.font_objects.deinit(self.gpa);
        self.page_objects.deinit(self.gpa);
        self.laters.deinit(self.gpa);
        self.images.deinit(self.gpa);
        self.objects.offsets.deinit(self.gpa);
        if (self.objects.deflate) |d| {
            d.out.deinit();
            self.gpa.destroy(d);
        }
        self.gpa.free(self.objects.counted.writer.buffer);
        self.scratch.deinit();
        self.page_arena.deinit();
        self.cache_arena.deinit();
        self.write_scratch.deinit();
        self.* = undefined;
    }

    /// endPage's write: the page object, then its content stream. A font the
    /// page uses gets its object numbers here, on first use.
    fn writePage(self: *Document, open: *const OpenPage) !void {
        const scratch = self.write_scratch.allocator();
        const out = self.objects.out();
        _ = try self.objects.begin(self.gpa, open.object);
        try out.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ");
        try writeReal(out, open.width_pt);
        try out.writeByte(' ');
        try writeReal(out, open.height_pt);
        try out.print("] /Contents {d} 0 R ", .{open.object + 1});
        try self.writeResources(scratch, out, open.ops.items);
        try out.writeAll(">>\n");
        try self.objects.end();
        try self.objects.stream(self.gpa, open.object + 1, "", try self.content(scratch, .{}, open.ops.items), null);
    }

    /// The /Resources entry for `ops`, ending with ' ': each font they draw with, and each
    /// reserveLater form and image they paint, once however often it is drawn. A font gets its
    /// object numbers here, on first use.
    fn writeResources(self: *Document, scratch: std.mem.Allocator, out: *std.Io.Writer, ops: []const DrawOp) !void {
        const seen = try scratch.alloc(bool, self.fonts.items.len);
        @memset(seen, false);
        try out.writeAll("/Resources << /Font << ");
        var xobjects = false;
        for (ops) |*draw_op| {
            const op = switch (draw_op.*) {
                .text => |*text_op| text_op,
                .later, .image => {
                    xobjects = true;
                    continue;
                },
                .line, .rect => continue,
            };
            const fi = @backingInt(op.font_id);
            if (seen[fi]) continue;
            seen[fi] = true;
            const base = self.font_objects.items[fi] orelse blk: {
                // An embedded font is 6 objects: Type0, CIDFontType2,
                // FontDescriptor, FontFile2, CIDToGIDMap, ToUnicode. A
                // standard font is 1.
                const n = self.next_object;
                self.next_object += switch (self.fonts.items[fi]) {
                    .embedded => 6,
                    .standard => 1,
                };
                self.font_objects.items[fi] = n;
                break :blk n;
            };
            try out.print("/F{d} {d} 0 R ", .{ fi + 1, base });
        }
        try out.writeAll(">> ");
        if (xobjects) {
            const seen_images = try scratch.alloc(bool, self.images.items.len);
            @memset(seen_images, false);
            try out.writeAll("/XObject << ");
            for (ops) |op| switch (op) {
                .later => |object| try out.print("/X{d} {d} 0 R ", .{ object, object }),
                .image => |im| {
                    if (seen_images[im.index]) continue;
                    seen_images[im.index] = true;
                    try out.print("/X{d} {d} 0 R ", .{ im.object, im.object });
                },
                .text, .line, .rect => {},
            };
            try out.writeAll(">> ");
        }
        try out.writeAll(">> ");
    }

    /// The content stream of `ops`, in `scratch`. The stream's /Length comes before its
    /// data, so the content is built first.
    fn content(self: *Document, scratch: std.mem.Allocator, start: GraphicsState, ops: []const DrawOp) ![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(scratch);
        var state = start;
        for (ops) |*op| {
            writeDrawOp(scratch, &aw.writer, &state, op, self.fonts.items) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                else => |e| return e,
            };
        }
        return aw.written();
    }

    /// finish's write: every used font, the page tree, the catalog, the xref.
    fn writeEnd(self: *Document) !void {
        const out = self.objects.out();
        for (self.fonts.items, self.font_objects.items) |*doc_font, maybe_base| {
            const base = maybe_base orelse continue;
            defer _ = self.write_scratch.reset(.retain_capacity);
            const scratch = self.write_scratch.allocator();
            const df = switch (doc_font.*) {
                .standard => |std_font| {
                    _ = try self.objects.begin(self.gpa, base);
                    try out.print("<< /Type /Font /Subtype /Type1 /BaseFont /{s} /Encoding /WinAnsiEncoding >>\n", .{std_font.baseFont()});
                    try self.objects.end();
                    continue;
                },
                .embedded => |*e| e,
            };
            const face = df.face;

            var seeds: std.ArrayList(u16) = .empty;
            var gid: u16 = 0;
            while (gid < df.used.capacity()) : (gid += 1) {
                if (df.used.isSet(gid)) try seeds.append(scratch, gid);
            }
            var used_set = try sfnt.collectUsed(scratch, face, seeds.items);
            const prefix = sfnt.subsetPrefix(try sfnt.sortedUsedGids(scratch, &used_set), df.font.normalized);
            const desc = try fontDescription(scratch, face, df.font, seeds.items);
            const subset = desc.subset;
            const ps_name = desc.name.slice();

            _ = try self.objects.begin(self.gpa, base);
            try out.print("<< /Type /Font /Subtype /Type0 /BaseFont /{s}+{s} /Encoding /Identity-H /DescendantFonts [{d} 0 R] /ToUnicode {d} 0 R >>\n", .{
                &prefix, ps_name, base + 1, base + 5,
            });
            try self.objects.end();

            _ = try self.objects.begin(self.gpa, base + 1);
            try out.print("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /{s}+{s} /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor {d} 0 R /W ", .{
                &prefix, ps_name, base + 2,
            });
            try writeWArray(out, df, face);
            try out.print(" /CIDToGIDMap {d} 0 R >>\n", .{base + 4});
            try self.objects.end();

            _ = try self.objects.begin(self.gpa, base + 2);
            try out.print("<< /Type /FontDescriptor /FontName /{s}+{s} /Flags 4 /FontBBox [{d} {d} {d} {d}] /ItalicAngle ", .{
                &prefix,
                ps_name,
                face.toThousandths(desc.bbox[0]),
                face.toThousandths(desc.bbox[1]),
                face.toThousandths(desc.bbox[2]),
                face.toThousandths(desc.bbox[3]),
            });
            try writeReal(out, face.italicAngle());
            try out.print(" /Ascent {d} /Descent {d} /CapHeight {d} /StemV 80 /FontFile2 {d} 0 R >>\n", .{
                face.toThousandths(desc.ascent),
                face.toThousandths(desc.descent),
                face.toThousandths(desc.cap_height),
                base + 3,
            });
            try self.objects.end();

            try self.objects.stream(self.gpa, base + 3, "", subset, subset.len);

            // CIDToGIDMap: one big-endian u16 GID per CID, CID 0 included.
            const map = try scratch.alloc(u8, (df.cids.count() + 1) * 2);
            for (0..df.cids.count() + 1) |cid| std.mem.writeInt(u16, map[cid * 2 ..][0..2], df.cids.gidForCid(@intCast(cid)), .big);
            try self.objects.stream(self.gpa, base + 4, "", map, null);

            var cmap: std.Io.Writer.Allocating = .init(scratch);
            text_map.writeToUnicode(&cmap.writer, &df.cids) catch return error.OutOfMemory;
            try self.objects.stream(self.gpa, base + 5, "", cmap.written(), null);
        }

        // /Count comes before /Kids: a reader that reads only the start of this object (a
        // page-count check that reads 256 bytes) still finds it with many pages.
        _ = try self.objects.begin(self.gpa, 2);
        try out.print("<< /Type /Pages /Count {d} /Kids [", .{self.page_objects.items.len});
        for (self.page_objects.items, 0..) |obj, i| {
            if (i != 0) try out.writeByte(' ');
            try out.print("{d} 0 R", .{obj});
        }
        try out.writeAll("] >>\n");
        try self.objects.end();

        _ = try self.objects.begin(self.gpa, 1);
        try out.writeAll("<< /Type /Catalog /Pages 2 0 R >>\n");
        try self.objects.end();

        // Every number below next_object was given to an object that is now
        // written; a gap would be a zpdf defect, and a reader would fail on it.
        const n_obj = self.next_object - 1;
        if (self.objects.offsets.items.len != n_obj) return error.Unexpected;
        const xref_at = self.objects.at();
        try out.print("xref\n0 {d}\n", .{n_obj + 1});
        try out.writeAll("0000000000 65535 f \n");
        for (self.objects.offsets.items) |off| {
            if (off == 0) return error.Unexpected;
            try out.print("{d:0>10} 00000 n \n", .{off});
        }
        try out.print("trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ n_obj + 1, xref_at });
        try self.flushAll();
    }

    fn checkWriting(self: *const Document) !void {
        switch (self.state) {
            .writing => {},
            .finished => return error.DocumentFinished,
            .failed => return error.DocumentFailed,
        }
    }

    /// Adds `font`, one instance of one face (zpdf.Font.init says how
    /// variations make the instance). The document borrows it: `font` must
    /// outlive every drawText, drawShaped, endPage and finish of this document, and the
    /// document never deinits it. Adding the same Font twice gives two FontIds,
    /// each with its own subset, as two Fonts of the same file do. An instance
    /// other than the default embeds instanced outlines (fontDescription);
    /// they are made, and the font's gvar and glyf entries of the embedded
    /// glyphs checked, when `finish` writes the fonts, so a broken gvar makes
    /// `finish` return error.InvalidFont.
    pub fn addFont(self: *Document, font: *zpdf.Font) !FontId {
        try self.checkWriting();
        try self.font_objects.ensureUnusedCapacity(self.gpa, 1);
        const face = try sfnt.open(font.bytes, font.index);
        var used = try std.DynamicBitSet.initEmpty(self.gpa, face.num_glyphs);
        errdefer used.deinit();
        var cids = text_map.CidRegistry.init(self.gpa);
        errdefer cids.deinit();
        try self.fonts.append(.{ .embedded = .{
            .font = font,
            .face = face,
            .used = used,
            .cids = cids,
        } });
        self.font_objects.appendAssumeCapacity(null);
        return @fromBackingInt(@intCast(self.fonts.items.len - 1));
    }

    /// Adds one of the 12 standard fonts. It is named, not embedded: every reader draws it
    /// with a font of its own (Helvetica may be Arial or Nimbus Sans), and only WinAnsi text
    /// can be drawn with it (see drawText). A PDF/A or PDF/UA file may not use one.
    pub fn addStandardFont(self: *Document, font: StandardFont) !FontId {
        try self.checkWriting();
        try self.font_objects.ensureUnusedCapacity(self.gpa, 1);
        try self.fonts.append(.{ .standard = font });
        self.font_objects.appendAssumeCapacity(null);
        return @fromBackingInt(@intCast(self.fonts.items.len - 1));
    }

    /// Opens the next page. error.PageOpen while another page is open.
    pub fn beginPage(self: *Document, width_pt: f64, height_pt: f64) !PageId {
        try self.checkWriting();
        if (self.open != null) return error.PageOpen;
        try checkPdfReal(width_pt);
        try checkPdfReal(height_pt);
        // A MediaBox with no area is not a page a viewer can show.
        if (!(width_pt > 0) or !(height_pt > 0)) return error.InvalidNumber;
        self.open = .{
            .id = @fromBackingInt(@intCast(self.page_objects.items.len)),
            .width_pt = width_pt,
            .height_pt = height_pt,
            .object = self.next_object,
        };
        self.next_object += 2;
        return self.open.?.id;
    }

    /// Writes `page` (its object, its content stream) and frees its drawing.
    /// `page` must be the open page (else error.InvalidPage).
    pub fn endPage(self: *Document, page: PageId) !void {
        try self.checkWriting();
        const open = self.open orelse return error.InvalidPage;
        if (open.id != page) return error.InvalidPage;
        try self.page_objects.ensureUnusedCapacity(self.gpa, 1);
        defer _ = self.write_scratch.reset(.retain_capacity);
        self.writePage(&open) catch |err| {
            self.state = .failed;
            return err;
        };
        self.page_objects.appendAssumeCapacity(open.object);
        self.open = null;
        _ = self.page_arena.reset(.retain_capacity);
        if (self.cache_arena.queryCapacity() > self.cache_budget) {
            for (self.fonts.items) |*f| switch (f.*) {
                .embedded => |*e| e.shapes.clearRetainingCapacity(),
                .standard => {},
            };
            _ = self.cache_arena.reset(.{ .retain_with_limit = self.cache_budget });
        }
    }

    /// Writes the fonts, the page tree, the catalog and the xref, and flushes
    /// zpdf's buffer into the writer. error.PageOpen while a page is open.
    pub fn finish(self: *Document) !void {
        try self.checkWriting();
        if (self.open != null) return error.PageOpen;
        if (self.laters_open != 0) return error.LaterNotDrawn;
        self.writeEnd() catch |err| {
            self.state = .failed;
            return err;
        };
        self.state = .finished;
    }

    /// Passes what zpdf has buffered on to the writer given to begin, and flushes that writer,
    /// so a caller can hand the PDF on while it is written (libzpdf's zpdf_doc_take and sinks,
    /// after each endPage) and hold one page, not the document. A failed write fails the
    /// document, as endPage's does.
    pub fn flushOutput(self: *Document) !void {
        try self.checkWriting();
        self.flushAll() catch |err| {
            self.state = .failed;
            return err;
        };
    }

    fn flushAll(self: *Document) !void {
        try self.objects.out().flush();
        try self.objects.counted.out.flush();
    }

    pub fn drawText(
        self: *Document,
        page_id: PageId,
        font_id: FontId,
        size_pt: f64,
        x_pt: f64,
        y_pt: f64,
        color: Color,
        utf8: []const u8,
        options: zpdf.ShapeOptions,
    ) !void {
        try self.checkPage(page_id);
        try self.drawTextInto(&self.open.?.ops, font_id, size_pt, x_pt, y_pt, color, utf8, options);
    }

    /// Reserves a place on the open page, at this point of its drawing order, for text that
    /// can only be drawn later: "Page 3 of 12" before the page count is known. Draw it with
    /// drawTextLater, before finish (which refuses with error.LaterNotDrawn while one is
    /// left). It is a form XObject: the page writes a reference to it now, and the form's
    /// content is written by drawTextLater, so nothing in the file is rewritten and the
    /// output can be compressed and streamed. It costs one object number until drawn.
    pub fn reserveLater(self: *Document, page_id: PageId) !LaterId {
        try self.checkPage(page_id);
        const open = &self.open.?;
        const arena = self.page_allocator orelse self.page_arena.allocator();
        try open.ops.ensureUnusedCapacity(arena, 1);
        try self.laters.ensureUnusedCapacity(self.gpa, 1);
        const object = self.next_object;
        self.next_object += 1;
        self.laters.appendAssumeCapacity(.{ .object = object, .width_pt = open.width_pt, .height_pt = open.height_pt });
        self.laters_open += 1;
        open.ops.appendAssumeCapacity(.{ .later = object });
        return @fromBackingInt(@intCast(self.laters.items.len - 1));
    }

    /// Draws the text of a reserveLater place, as drawText would on its page (same
    /// coordinates, fonts, colour and checks), and writes it. Once per place:
    /// error.LaterDrawn the second time, error.InvalidLater for an id this document did not
    /// give. Can be called while a page is open, and after the place's page has ended.
    /// A failed check draws nothing; a failed write fails the document, as endPage's does.
    pub fn drawTextLater(
        self: *Document,
        later_id: LaterId,
        font_id: FontId,
        size_pt: f64,
        x_pt: f64,
        y_pt: f64,
        color: Color,
        utf8: []const u8,
        options: zpdf.ShapeOptions,
    ) !void {
        try self.checkWriting();
        const index = @backingInt(later_id);
        if (index >= self.laters.items.len) return error.InvalidLater;
        const later = &self.laters.items[index];
        if (later.written) return error.LaterDrawn;
        var ops: std.ArrayList(DrawOp) = .empty;
        const arena = self.page_allocator orelse self.page_arena.allocator();
        try ops.ensureTotalCapacity(arena, 1);
        try self.drawTextInto(&ops, font_id, size_pt, x_pt, y_pt, color, utf8, options);
        defer _ = self.write_scratch.reset(.retain_capacity);
        self.writeLater(later, ops.items) catch |err| {
            self.state = .failed;
            return err;
        };
        later.written = true;
        self.laters_open -= 1;
        // With no page open, nothing else holds the page arena; with one open, the
        // op's bytes are freed when that page ends.
        if (self.open == null) _ = self.page_arena.reset(.retain_capacity);
    }

    fn writeLater(self: *Document, later: *const Later, ops: []const DrawOp) !void {
        const scratch = self.write_scratch.allocator();
        var dict: std.Io.Writer.Allocating = .init(scratch);
        dict.writer.writeAll("/Type /XObject /Subtype /Form /BBox [0 0 ") catch return error.OutOfMemory;
        writeReals(&dict.writer, &.{ later.width_pt, later.height_pt }) catch return error.OutOfMemory;
        dict.writer.writeAll("] ") catch return error.OutOfMemory;
        self.writeResources(scratch, &dict.writer, ops) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
        try self.objects.stream(self.gpa, later.object, dict.written(), try self.content(scratch, .unknown, ops), null);
    }

    /// drawText's work after the target is checked: the text op, appended to `ops`. A
    /// failed call changes nothing.
    fn drawTextInto(
        self: *Document,
        ops: *std.ArrayList(DrawOp),
        font_id: FontId,
        size_pt: f64,
        x_pt: f64,
        y_pt: f64,
        color: Color,
        utf8: []const u8,
        options: zpdf.ShapeOptions,
    ) !void {
        const doc_font = try self.checkTextArgs(font_id, size_pt, x_pt, y_pt, color);
        _ = self.scratch.reset(.retain_capacity);
        const scratch = self.scratch_allocator orelse self.scratch.allocator();
        switch (doc_font.*) {
            .embedded => |*e| {
                const key = try cacheKey(scratch, utf8, options);
                if (e.shapes.get(key)) |hit| {
                    try checkDrawReals(size_pt, hit.glyphs, e.face, e.font);
                    const arena = self.page_allocator orelse self.page_arena.allocator();
                    try ops.ensureUnusedCapacity(arena, 1);
                    ops.appendAssumeCapacity(.{ .text = .{
                        .font_id = font_id,
                        .size_pt = size_pt,
                        .x_pt = x_pt,
                        .y_pt = y_pt,
                        .color = color,
                        .text = .{ .shaped = .{ .glyphs = hit.glyphs, .mapping = hit.mapping } },
                    } });
                    return;
                }
                const shaped = try zpdf.shape(scratch, e.font, utf8, options);
                try self.addShaped(ops, font_id, size_pt, x_pt, y_pt, color, shaped, key);
            },
            .standard => try self.addWinAnsi(ops, font_id, size_pt, x_pt, y_pt, color, utf8, options),
        }
    }

    /// A standard font's line: the WinAnsi bytes of `utf8`, drawn left to right with no shaping.
    /// error.NotWinAnsi when a character has no WinAnsi byte (never a substitute); an RTL
    /// paragraph direction is error.UnsupportedShaping, as a standard font cannot reorder text.
    fn addWinAnsi(
        self: *Document,
        ops: *std.ArrayList(DrawOp),
        font_id: FontId,
        size_pt: f64,
        x_pt: f64,
        y_pt: f64,
        color: Color,
        utf8: []const u8,
        options: zpdf.ShapeOptions,
    ) !void {
        if (options.paragraph_direction == .rtl) return error.UnsupportedShaping;
        const scratch = self.scratch_allocator orelse self.scratch.allocator();
        const bytes = try winansi.encodeUtf8(scratch, utf8);
        const arena = self.page_allocator orelse self.page_arena.allocator();
        try ops.ensureUnusedCapacity(arena, 1);
        ops.appendAssumeCapacity(.{ .text = .{
            .font_id = font_id,
            .size_pt = size_pt,
            .x_pt = x_pt,
            .y_pt = y_pt,
            .color = color,
            .text = .{ .winansi = try arena.dupe(u8, bytes) },
        } });
    }

    /// drawText for a line the caller has already shaped with zpdf.shape, so
    /// one shaping can feed both a PDF and another consumer. `shaped` must
    /// come from the Font that `font_id` was added with (else
    /// error.FontMismatch); it stays the caller's. Like drawText, a failed
    /// call leaves the document as it was.
    pub fn drawShaped(
        self: *Document,
        page_id: PageId,
        font_id: FontId,
        size_pt: f64,
        x_pt: f64,
        y_pt: f64,
        color: Color,
        shaped: zpdf.ShapeResult,
    ) !void {
        try self.checkPage(page_id);
        _ = try self.checkTextArgs(font_id, size_pt, x_pt, y_pt, color);
        _ = self.scratch.reset(.retain_capacity);
        // Not cached: the options `shaped` was made with are not known here.
        try self.addShaped(&self.open.?.ops, font_id, size_pt, x_pt, y_pt, color, shaped, null);
    }

    fn checkTextArgs(self: *Document, font_id: FontId, size_pt: f64, x_pt: f64, y_pt: f64, color: Color) !*DocFont {
        if (@backingInt(font_id) >= self.fonts.items.len) return error.InvalidFont;
        try checkPdfReal(size_pt);
        try checkPdfReal(x_pt);
        try checkPdfReal(y_pt);
        try color.check();
        return &self.fonts.items[@backingInt(font_id)];
    }

    /// `page_id` is the open page of a document still being written.
    fn checkPage(self: *const Document, page_id: PageId) !void {
        try self.checkWriting();
        const open = self.open orelse return error.InvalidPage;
        if (open.id != page_id) return error.InvalidPage;
    }

    /// A straight line from (x1, y1) to (x2, y2), in points, PDF space (y up from the
    /// page's bottom), `width_pt` wide with square-cut (butt) ends. The stroke is centred
    /// on the line, so half of it lies on each side. Nothing is clipped: a line off the
    /// page is written and does not show. error.InvalidNumber when `width_pt` is below
    /// 0.0001 (zpdf writes 4 decimals, and a width written as 0 means "the thinnest line
    /// the device can draw", which differs between devices). A failed call draws nothing.
    pub fn drawLine(self: *Document, page_id: PageId, x1: f64, y1: f64, x2: f64, y2: f64, width_pt: f64, color: Color) !void {
        try self.checkPage(page_id);
        for ([_]f64{ x1, y1, x2, y2 }) |v| try checkPdfReal(v);
        try checkLineWidth(width_pt);
        try color.check();
        try self.appendOp(.{ .line = .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .width = width_pt, .color = color } });
    }

    /// Fills the rectangle whose bottom-left corner is (x, y), in points, PDF space.
    /// A negative width or height is error.InvalidNumber; 0 is allowed and paints
    /// nothing. A failed call draws nothing.
    pub fn fillRect(self: *Document, page_id: PageId, x: f64, y: f64, width: f64, height: f64, color: Color) !void {
        try self.checkPage(page_id);
        try checkRect(x, y, width, height);
        try color.check();
        try self.appendOp(.{ .rect = .{ .x = x, .y = y, .width = width, .height = height, .paint = .fill, .color = color } });
    }

    /// Strokes the outline of the rectangle fillRect would fill, `line_width_pt` wide,
    /// centred on the edges (drawLine's rules for the width).
    pub fn strokeRect(self: *Document, page_id: PageId, x: f64, y: f64, width: f64, height: f64, line_width_pt: f64, color: Color) !void {
        try self.checkPage(page_id);
        try checkRect(x, y, width, height);
        try checkLineWidth(line_width_pt);
        try color.check();
        try self.appendOp(.{ .rect = .{ .x = x, .y = y, .width = width, .height = height, .paint = .{ .stroke = line_width_pt }, .color = color } });
    }

    /// Adds a JPEG or PNG image (image.zig says which files it takes and what it refuses) and
    /// writes it now, so the document keeps its size and object number and not its pixels: an
    /// image drawn on every page is in the file once. An image that is never drawn is still in
    /// the file. `bytes` are read only during the call. Can be called while a page is open. A
    /// refused image changes nothing; a failed write fails the document, as endPage's does.
    pub fn addImage(self: *Document, bytes: []const u8) !ImageId {
        try self.checkWriting();
        try self.images.ensureUnusedCapacity(self.gpa, 1);
        // Decoded with gpa and freed on return, not in write_scratch: a reset arena keeps its
        // capacity, and a decoded image would stay held until the document ends (stream and
        // free). The arena holds only the dictionaries' text.
        var img = try image.decode(self.gpa, bytes, self.max_image_bytes);
        defer img.deinit(self.gpa);
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const object = self.next_object;
        self.next_object += if (img.alpha != null) 2 else 1;
        self.writeImage(arena.allocator(), object, img) catch |err| {
            self.state = .failed;
            return err;
        };
        self.objects.trim();
        const shown = img.shownSize();
        self.images.appendAssumeCapacity(.{ .object = object, .shown_width = shown[0], .shown_height = shown[1], .orientation = img.orientation });
        return @fromBackingInt(@intCast(self.images.items.len - 1));
    }

    /// The image's size in pixels as it is shown, after its Exif orientation: what drawImage's
    /// width and height keep the aspect ratio of. error.InvalidImage for an id this document did
    /// not give.
    pub fn imageSize(self: *const Document, image_id: ImageId) !struct { width: u32, height: u32 } {
        const index = @backingInt(image_id);
        if (index >= self.images.items.len) return error.InvalidImage;
        const im = self.images.items[index];
        return .{ .width = im.shown_width, .height = im.shown_height };
    }

    /// Draws `image_id` stretched to fill the rectangle whose bottom-left corner is (x, y), in
    /// points, PDF space, turned as its Exif orientation says. A `width` or `height` below
    /// 0.0001 is error.InvalidNumber (drawLine's reason). error.InvalidImage for an id this
    /// document did not give. A failed call draws nothing.
    pub fn drawImage(self: *Document, page_id: PageId, image_id: ImageId, x: f64, y: f64, width: f64, height: f64) !void {
        try self.checkPage(page_id);
        const index = @backingInt(image_id);
        if (index >= self.images.items.len) return error.InvalidImage;
        try checkPdfReal(x);
        try checkPdfReal(y);
        try checkLineWidth(width);
        try checkLineWidth(height);
        const im = self.images.items[index];
        const matrix = im.orientation.matrix(x, y, width, height);
        for (matrix) |v| try checkPdfReal(v);
        try self.appendOp(.{ .image = .{ .index = index, .object = im.object, .matrix = matrix } });
    }

    /// addImage's write: the image XObject, and its soft mask as the next object.
    fn writeImage(self: *Document, scratch: std.mem.Allocator, object: u32, img: image.Image) !void {
        var dict: std.Io.Writer.Allocating = .init(scratch);
        writeImageDict(&dict.writer, img, object) catch return error.OutOfMemory;
        switch (img.encoding) {
            .dct => try self.objects.encodedStream(self.gpa, object, dict.written(), "/DCTDecode", img.data),
            .samples => try self.objects.stream(self.gpa, object, dict.written(), img.data, null),
        }
        const alpha = img.alpha orelse return;
        const mask = try std.fmt.allocPrint(scratch, "/Type /XObject /Subtype /Image /Width {d} /Height {d} /ColorSpace /DeviceGray /BitsPerComponent {d} ", .{
            img.width, img.height, img.alpha_bits,
        });
        try self.objects.stream(self.gpa, object + 1, mask, alpha, null);
    }

    fn appendOp(self: *Document, op: DrawOp) !void {
        const arena = self.page_allocator orelse self.page_arena.allocator();
        try self.open.?.ops.append(arena, op);
    }

    /// The rest of drawText, after checkDrawArgs and the scratch reset.
    /// Every check runs before the document changes.
    fn addShaped(
        self: *Document,
        ops: *std.ArrayList(DrawOp),
        font_id: FontId,
        size_pt: f64,
        x_pt: f64,
        y_pt: f64,
        color: Color,
        shaped: zpdf.ShapeResult,
        /// When set, the result is also added to the font's shape cache under
        /// this key (in scratch).
        cache_key: ?[]const u8,
    ) !void {
        const doc_font = switch (self.fonts.items[@backingInt(font_id)]) {
            .embedded => |*e| e,
            .standard => return error.FontMismatch,
        };
        if (shaped.font_id != doc_font.font.id) return error.FontMismatch;
        const scratch = self.scratch_allocator orelse self.scratch.allocator();

        // A vertical advance is refused before the pen runs, because a pen
        // that moved in y would make checkDrawReals judge the wrong rise.
        for (shaped.glyphs) |glyph| {
            if (glyph.advance_y != 0) return error.UnsupportedShaping;
            if (glyph.id >= doc_font.used.capacity()) return error.InvalidFont;
        }
        try checkDrawReals(size_pt, shaped.glyphs, doc_font.face, doc_font.font);

        const cps = try text_map.utf8ToCodepoints(scratch, shaped.text);

        const cid_before = doc_font.cids.count();
        errdefer doc_font.cids.truncate(cid_before);
        const mapping = try text_map.map(scratch, cps, shaped.glyphs, shaped.runs, &doc_font.cids);

        var new_used = ManagedList(u16).init(scratch);
        errdefer for (new_used.items) |gid| doc_font.used.unset(gid);
        for (shaped.glyphs) |glyph| {
            if (doc_font.used.isSet(glyph.id)) continue;
            try new_used.append(glyph.id);
            doc_font.used.set(glyph.id);
        }

        // Every check has passed. Reserve the op slot and the cache slot, then
        // copy what the op keeps out of scratch, so nothing after the copy can
        // fail. A cached result is copied once, into the cache arena, and the
        // op points at that copy.
        const page_arena = self.page_allocator orelse self.page_arena.allocator();
        const arena = if (cache_key != null) self.cache_allocator orelse self.cache_arena.allocator() else page_arena;
        try ops.ensureUnusedCapacity(page_arena, 1);
        if (cache_key != null) try doc_font.shapes.ensureUnusedCapacity(self.gpa, 1);
        const spans = try arena.dupe(text_map.ActualTextSpan, mapping.spans);
        for (spans) |*span| span.text = try arena.dupe(u21, span.text);
        const kept: CachedShape = .{
            .glyphs = try arena.dupe(zpdf.Glyph, shaped.glyphs),
            .mapping = .{ .cids = try arena.dupe(u16, mapping.cids), .spans = spans },
        };
        if (cache_key) |key| doc_font.shapes.putAssumeCapacityNoClobber(try arena.dupe(u8, key), kept);
        ops.appendAssumeCapacity(.{ .text = .{
            .font_id = font_id,
            .size_pt = size_pt,
            .x_pt = x_pt,
            .y_pt = y_pt,
            .color = color,
            .text = .{ .shaped = .{ .glyphs = kept.glyphs, .mapping = kept.mapping } },
        } });
    }
};

pub const WriteOptions = struct {
    /// Compress every stream with zlib (/FlateDecode), as PDF readers expect.
    /// Off writes the same objects uncompressed, for reading the file by eye
    /// and for byte comparison with older output.
    compress: bool,
};

/// zlib state for one document, reused for every stream. Allocated, not on
/// the stack: the std encoder is about 224 KiB.
const Deflate = struct {
    window: [std.compress.flate.max_window_len]u8,
    encoder: std.compress.flate.Compress,
    /// One stream's compressed bytes; /Length must be written before them.
    out: std.Io.Writer.Allocating,

    /// What `out` may keep between streams. A page's content and a font subset fit; an image can
    /// be far larger, and ObjectWriter.trim lets that go.
    const kept_capacity = 64 * 1024;
};

/// A std hasher that only counts, so `std.Io.Writer.Hashed` passes bytes
/// through to the caller's writer and tells us the offset of each object.
const ByteCount = struct {
    n: u64 = 0,

    pub fn update(self: *ByteCount, bytes: []const u8) void {
        self.n += bytes.len;
    }
};

/// Writes numbered objects and records where each starts, for the xref table.
/// Objects are written in any order (a page before the fonts and page tree it
/// points at); `offsets[n - 1]` is object n's, 0 until it is written.
const ObjectWriter = struct {
    counted: std.Io.Writer.Hashed(ByteCount),
    offsets: std.ArrayList(u64) = .empty,
    deflate: ?*Deflate,

    fn out(self: *ObjectWriter) *std.Io.Writer {
        return &self.counted.writer;
    }

    fn at(self: *const ObjectWriter) u64 {
        return self.counted.hasher.n + self.counted.writer.end;
    }

    /// The body written next must end with '\n'; `end` writes "endobj".
    fn begin(self: *ObjectWriter, gpa: std.mem.Allocator, number: u32) !*std.Io.Writer {
        if (self.offsets.items.len < number) try self.offsets.appendNTimes(gpa, 0, number - self.offsets.items.len);
        std.debug.assert(self.offsets.items[number - 1] == 0);
        self.offsets.items[number - 1] = self.at();
        try self.out().print("{d} 0 obj\n", .{number});
        return self.out();
    }

    fn end(self: *ObjectWriter) !void {
        try self.out().writeAll("endobj\n");
    }

    /// `length1` is the FontFile2 /Length1: the uncompressed font length.
    /// `dict` is written into the stream's dictionary before /Length: "" or entries ending in ' '.
    fn stream(self: *ObjectWriter, arena: std.mem.Allocator, number: u32, dict: []const u8, data: []const u8, length1: ?usize) !void {
        var body = data;
        var filter: []const u8 = "";
        if (self.deflate) |d| {
            // The encoder's only sink is `d.out`, which fails only when it
            // cannot grow.
            d.out.clearRetainingCapacity();
            // Compress.init asserts its sink has room for at least 9 bytes; after trim it has none.
            d.out.ensureTotalCapacity(16) catch return error.OutOfMemory;
            d.encoder = std.compress.flate.Compress.init(&d.out.writer, &d.window, .zlib, .default) catch return error.OutOfMemory;
            d.encoder.writer.writeAll(data) catch return error.OutOfMemory;
            d.encoder.finish() catch return error.OutOfMemory;
            body = d.out.written();
            filter = " /Filter /FlateDecode";
        }
        const w = try self.begin(arena, number);
        try w.print("<< {s}/Length {d}{s}", .{ dict, body.len, filter });
        if (length1) |l1| try w.print(" /Length1 {d}", .{l1});
        try w.writeAll(" >>\nstream\n");
        try w.writeAll(body);
        try w.writeAll("\nendstream\n");
        try self.end();
    }

    /// Frees the compressed-stream buffer when one stream grew it past Deflate.kept_capacity, so
    /// a large image's compressed bytes are not held until the document ends.
    fn trim(self: *ObjectWriter) void {
        const d = self.deflate orelse return;
        if (d.out.writer.buffer.len <= Deflate.kept_capacity) return;
        const gpa = d.out.allocator;
        d.out.deinit();
        d.out = .init(gpa);
    }

    /// A stream whose data is already encoded with `filter` (a JPEG's "/DCTDecode"): written as
    /// it is, whether or not the document compresses. `dict` as stream's.
    fn encodedStream(self: *ObjectWriter, gpa: std.mem.Allocator, number: u32, dict: []const u8, filter: []const u8, data: []const u8) !void {
        const w = try self.begin(gpa, number);
        try w.print("<< {s}/Length {d} /Filter {s} >>\nstream\n", .{ dict, data.len, filter });
        try w.writeAll(data);
        try w.writeAll("\nendstream\n");
        try self.end();
    }
};

/// An image XObject's dictionary entries before /Length, each ending in ' ' (ISO 32000-1 8.9.5).
/// `object` is the image's own number; its soft mask, when it has one, is the next.
fn writeImageDict(w: *std.Io.Writer, img: image.Image, object: u32) !void {
    try w.print("/Type /XObject /Subtype /Image /Width {d} /Height {d} /ColorSpace ", .{ img.width, img.height });
    switch (img.color) {
        .gray => try w.writeAll("/DeviceGray"),
        .rgb => try w.writeAll("/DeviceRGB"),
        .cmyk_inverted => try w.writeAll("/DeviceCMYK"),
        .indexed => |palette| {
            try w.print("[/Indexed /DeviceRGB {d} <", .{palette.len / 3 - 1});
            for (palette) |byte| try w.print("{x:0>2}", .{byte});
            try w.writeAll(">]");
        },
    }
    try w.print(" /BitsPerComponent {d} ", .{img.bits});
    // PDF readers draw the samples as they are; this maps 0 to full ink, as JPEG viewers read a
    // CMYK JPEG (image.zig's module doc).
    if (img.color == .cmyk_inverted) try w.writeAll("/Decode [1 0 1 0 1 0 1 0] ");
    if (img.alpha != null) try w.print("/SMask {d} 0 R ", .{object + 1});
    if (img.color_key) |key| {
        // One range per component; a range of one value masks exactly that colour.
        try w.writeAll("/Mask [");
        for (key.values[0..key.len], 0..) |v, i| {
            if (i != 0) try w.writeByte(' ');
            try w.print("{d} {d}", .{ v, v });
        }
        try w.writeAll("] ");
    }
}

/// What the font objects of one embedded font say about it: its FontFile2
/// bytes, PostScript name and FontDescriptor metrics.
const FontDescription = struct {
    subset: []const u8,
    name: sfnt.InstanceName,
    bbox: [4]i32,
    ascent: i32,
    descent: i32,
    cap_height: i32,
};

/// The default instance of a variable font, and a font with no axes, embed
/// the glyf subset as it is, with the font's own name and metrics. Any other
/// instance embeds instanced outlines (instancer.subsetInstance) and takes:
/// - the PostScript name of Adobe TN 5902 (sfnt.instancePostscriptName);
/// - FontBBox: the union of the instanced glyphs' bounds (the subset's head);
/// - Ascent, Descent, CapHeight: hhea's ascender and descender and OS/2's
///   sCapHeight plus kb's MVAR deltas for "hasc", "hdsc" and "cpht"
///   (zpdf.Font.metricDelta). HarfBuzz applies "hasc" and "hdsc" to hhea's
///   values as well as OS/2's, and so does fontTools' instancer.
/// - hmtx advances: the instanced phantom points when the font has no HVAR
///   (kb's advance, and so /W, comes from the same phantom points), and kb's
///   advance when it has HVAR, so the embedded font and /W agree. Fraunces'
///   gvar gives two glyphs no phantom deltas that its HVAR does vary.
/// ItalicAngle stays post's: MVAR has no tag for it, and fontTools leaves it.
fn fontDescription(scratch: std.mem.Allocator, face: sfnt.Face, font: *const zpdf.Font, seeds: []const u16) !FontDescription {
    const vertical = try font.verticalMetrics(face);
    if (!font.isInstanced()) {
        return .{
            .subset = try sfnt.subset(scratch, face, seeds),
            .name = try font.postscriptName(face),
            .bbox = .{ face.x_min, face.y_min, face.x_max, face.y_max },
            .ascent = vertical.ascent,
            .descent = vertical.descent,
            .cap_height = face.cap_height,
        };
    }
    // kb takes advances from gvar's phantom points when the font has no HVAR,
    // so there the subset's own phantom points give the /W widths; with HVAR,
    // kb's advance is the width, and the subset's hmtx says the same.
    const advances: ?instancer.AdvanceSource = if (try sfnt.faceTable(face, "HVAR") != null)
        .{ .context = font, .advance = kbAdvance }
    else
        null;
    const inst = try instancer.subsetInstance(scratch, face, seeds, font.normalized, advances);
    return .{
        .subset = inst.bytes,
        .name = try font.postscriptName(face),
        .bbox = .{ inst.x_min, inst.y_min, inst.x_max, inst.y_max },
        .ascent = vertical.ascent,
        .descent = vertical.descent,
        .cap_height = @as(i32, face.cap_height) + try font.metricDelta("cpht"),
    };
}

fn kbAdvance(context: *const anyopaque, gid: u16) i32 {
    const font: *const zpdf.Font = @ptrCast(@alignCast(context));
    return font.glyphAdvanceX(gid);
}

/// `scratch` holds the per-glyph span markers, freed with the caller's arena.
/// Each glyph's width is the one /W gives its CID (`glyphWidth`), so a reader
/// that advances by /W lands where the TJ adjustments say.
fn writeDrawOp(scratch: std.mem.Allocator, out: *std.Io.Writer, state: *GraphicsState, draw_op: *const DrawOp, fonts: []const DocFont) !void {
    const op = switch (draw_op.*) {
        .text => |*text_op| text_op,
        .line => |l| {
            try state.setStroke(out, l.color, l.width);
            try writeReals(out, &.{ l.x1, l.y1 });
            try out.writeAll(" m ");
            try writeReals(out, &.{ l.x2, l.y2 });
            return out.writeAll(" l S\n");
        },
        .later => |object| return out.print("/X{d} Do\n", .{object}),
        // q/Q keeps the cm to this image; nothing inside changes the state GraphicsState tracks.
        .image => |im| {
            try out.writeAll("q\n");
            try writeReals(out, &im.matrix);
            return out.print(" cm\n/X{d} Do\nQ\n", .{im.object});
        },
        .rect => |r| {
            switch (r.paint) {
                .fill => try state.setFill(out, r.color),
                .stroke => |width| try state.setStroke(out, r.color, width),
            }
            try writeReals(out, &.{ r.x, r.y, r.width, r.height });
            return out.writeAll(switch (r.paint) {
                .fill => " re f\n",
                .stroke => " re S\n",
            });
        },
    };
    const doc_font = &fonts[@backingInt(op.font_id)];
    try state.setFill(out, op.color);
    try out.print("BT\n/F{d} ", .{@backingInt(op.font_id) + 1});
    try writeReal(out, op.size_pt);
    try out.writeAll(" Tf\n1 0 0 1 ");
    try writeReal(out, op.x_pt);
    try out.writeByte(' ');
    try writeReal(out, op.y_pt);
    try out.writeAll(" Tm\n");
    switch (op.text) {
        .winansi => |bytes| {
            try writeLiteralString(out, bytes);
            try out.writeAll(" Tj\nET\n");
        },
        .shaped => |shaped| try writeShaped(scratch, out, shaped.glyphs, shaped.mapping, doc_font.embedded.face, doc_font.embedded.font, op.size_pt),
    }
}

/// The colours and line width the content stream has set so far. An operator is
/// written only when a drawing call needs a different value, so a page drawn all in
/// black writes none. It starts at the PDF's initial graphics state (ISO 32000-1
/// 8.4.1): black fill and stroke, line width 1. Only an image uses q/Q, and it sets
/// none of these inside, so the state runs through the whole content stream.
const GraphicsState = struct {
    /// null: not known, so the next call writes it. A form XObject starts so, because
    /// it inherits whatever state the page has where it is painted (ISO 32000-1 8.10.1).
    fill: ?Color = .black,
    stroke: ?Color = .black,
    line_width: ?f64 = 1,

    const unknown: GraphicsState = .{ .fill = null, .stroke = null, .line_width = null };

    fn setFill(self: *GraphicsState, out: *std.Io.Writer, c: Color) !void {
        if (self.fill != null and std.meta.eql(self.fill.?, c)) return;
        try writeReals(out, &.{ c.r, c.g, c.b });
        try out.writeAll(" rg\n");
        self.fill = c;
    }

    fn setStroke(self: *GraphicsState, out: *std.Io.Writer, c: Color, width: f64) !void {
        if (self.stroke == null or !std.meta.eql(self.stroke.?, c)) {
            try writeReals(out, &.{ c.r, c.g, c.b });
            try out.writeAll(" RG\n");
            self.stroke = c;
        }
        if (self.line_width == null or self.line_width.? != width) {
            try writeReal(out, width);
            try out.writeAll(" w\n");
            self.line_width = width;
        }
    }
};

/// `values`, separated by spaces.
fn writeReals(out: *std.Io.Writer, values: []const f64) !void {
    for (values, 0..) |v, i| {
        if (i != 0) try out.writeByte(' ');
        try writeReal(out, v);
    }
}

/// A PDF literal string: `(`, `)` and `\` escaped, and every byte outside printable ASCII
/// written as a three-digit octal escape, so the content stream stays ASCII.
fn writeLiteralString(out: *std.Io.Writer, bytes: []const u8) !void {
    try out.writeByte('(');
    for (bytes) |b| switch (b) {
        '(', ')', '\\' => try out.print("\\{c}", .{b}),
        0x20...0x27, 0x2A...0x5B, 0x5D...0x7E => try out.writeByte(b),
        else => try out.print("\\{o:0>3}", .{b}),
    };
    try out.writeByte(')');
}

/// The TJ arrays of a shaped line, with its ActualText spans; BT, Tf and Tm are written.
fn writeShaped(
    scratch: std.mem.Allocator,
    out: *std.Io.Writer,
    glyphs: []const zpdf.Glyph,
    mapping: text_map.Mapping,
    face: sfnt.Face,
    font: *const zpdf.Font,
    size_pt: f64,
) !void {
    const n = glyphs.len;
    const start_at = try scratch.alloc(?*const text_map.ActualTextSpan, n);
    @memset(start_at, null);
    const end_at = try scratch.alloc(bool, n);
    @memset(end_at, false);
    for (mapping.spans) |*s| {
        if (s.start < n) start_at[s.start] = s;
        if (s.end > 0 and s.end - 1 < n) end_at[s.end - 1] = true;
    }

    var pen: TjPen = .init(face, font, size_pt);
    var tj_open = false;
    var rise: f64 = 0;

    for (glyphs, mapping.cids, 0..) |glyph, cid, gi| {
        const span_start = start_at[gi];
        const placed = try pen.place(glyph);
        const wanted_rise = placed.rise;

        if (span_start) |span| {
            try closeTj(out, &tj_open);
            try out.writeAll("/Span << /ActualText <");
            try text_map.writeUtf16BeHex(out, span.text, true);
            try out.writeAll("> >> BDC\n");
        }
        if (wanted_rise != rise) {
            try closeTj(out, &tj_open);
            try writeReal(out, wanted_rise);
            try out.writeAll(" Ts\n");
            rise = wanted_rise;
        }

        try openTj(out, &tj_open);
        if (placed.adj != 0) {
            try writeReal(out, placed.adj);
            try out.writeByte(' ');
        }
        try out.print("<{X:0>4}>", .{cid});

        if (rise != 0) {
            try closeTj(out, &tj_open);
            try out.writeAll("0 Ts\n");
            rise = 0;
        }
        if (end_at[gi]) {
            try closeTj(out, &tj_open);
            try out.writeAll("EMC\n");
        }
    }
    try closeTj(out, &tj_open);
    if (rise != 0) try out.writeAll("0 Ts\n");
    try out.writeAll("ET\n");
}

fn openTj(out: *std.Io.Writer, open: *bool) !void {
    if (!open.*) {
        try out.writeByte('[');
        open.* = true;
    }
}

fn closeTj(out: *std.Io.Writer, open: *bool) !void {
    if (open.*) {
        try out.writeAll("] TJ\n");
        open.* = false;
    }
}

fn writeWArray(out: *std.Io.Writer, df: *const EmbeddedFont, face: sfnt.Face) !void {
    const max_cid: u16 = @intCast(df.cids.count());
    try out.writeAll("[ 0 [");
    var cid: u16 = 0;
    while (cid <= max_cid) : (cid += 1) {
        if (cid != 0) try out.writeByte(' ');
        try out.print("{d}", .{try glyphWidth(face, df.font, df.cids.gidForCid(cid))});
    }
    try out.writeAll("] ]");
}

/// A glyph's PDF width (/W, and the TJ arithmetic): kb's advance at the font's
/// instance, before GPOS, in thousandths of an em. kb owns metrics, so the
/// width is the one shaping started from; at the default instance, and for a
/// font with no axes, that is the hmtx advance.
fn glyphWidth(face: sfnt.Face, font: *const zpdf.Font, gid: u16) !i32 {
    if (gid >= face.num_glyphs) return error.InvalidFont;
    return face.toThousandths(font.glyphAdvanceX(gid));
}

fn round4(v: f64) f64 {
    return @round(v * 10000.0) / 10000.0;
}

/// User sizes, coordinates, page sizes, and every real endPage and finish print.
const max_pdf_real: f64 = 1e9;

fn checkLineWidth(width_pt: f64) !void {
    try checkPdfReal(width_pt);
    if (!(width_pt >= 0.0001)) return error.InvalidNumber;
}

fn checkRect(x: f64, y: f64, width: f64, height: f64) !void {
    for ([_]f64{ x, y, width, height }) |v| try checkPdfReal(v);
    if (width < 0 or height < 0) return error.InvalidNumber;
}

fn checkPdfReal(v: f64) !void {
    if (!std.math.isFinite(v)) return error.InvalidNumber;
    if (@abs(v) > max_pdf_real) return error.InvalidNumber;
}

/// The TJ pen of one drawText, glyph by glyph. checkDrawReals and writeDrawOp
/// both run it, so the reals drawText checks are the reals endPage prints.
///
/// Positions are absolute: each glyph's TJ number moves the PDF pen from where
/// /W widths left it to the shaped position (pen_x + offset_x), so rounding
/// never accumulates along a line.
const TjPen = struct {
    face: sfnt.Face,
    font: *const zpdf.Font,
    size_pt: f64,
    upem: f64,
    /// The shaped pen, in font units.
    pen: zpdf.Pen = .{},
    /// Where the PDF pen is, in thousandths of an em.
    pdf_em1000: f64 = 0,

    fn init(face: sfnt.Face, font: *const zpdf.Font, size_pt: f64) TjPen {
        return .{ .face = face, .font = font, .size_pt = size_pt, .upem = @floatFromInt(face.units_per_em) };
    }

    const Placed = struct {
        /// The glyph's text rise (Ts), in points.
        rise: f64,
        /// The TJ number written before the glyph; 0 writes none.
        adj: f64,
    };

    /// Places `glyph` and moves the pen past it by its /W width.
    fn place(self: *TjPen, glyph: zpdf.Glyph) !Placed {
        const origin = self.pen.place(glyph);
        const rise = @as(f64, @floatFromInt(origin.y)) * self.size_pt / self.upem;
        const wanted = @as(f64, @floatFromInt(origin.x)) * 1000.0 / self.upem;
        const adj = round4(self.pdf_em1000 - wanted);
        if (adj != 0) self.pdf_em1000 -= adj;
        self.pdf_em1000 += @floatFromInt(try glyphWidth(self.face, self.font, glyph.id));
        return .{ .rise = rise, .adj = adj };
    }
};

fn checkDrawReals(size_pt: f64, glyphs: []const zpdf.Glyph, face: sfnt.Face, font: *const zpdf.Font) !void {
    var pen: TjPen = .init(face, font, size_pt);
    var rise: f64 = 0;
    for (glyphs) |glyph| {
        const placed = try pen.place(glyph);
        if (placed.rise != rise) {
            try checkPdfReal(placed.rise);
            rise = placed.rise;
        }
        if (placed.adj != 0) try checkPdfReal(placed.adj);
        if (rise != 0) rise = 0;
    }
}

/// A PDF real: at most 4 decimals, no exponent, no trailing zeros, and "0"
/// for anything that rounds to zero (so never "-0"). Printed as integers:
/// std's float `{d}` gives the same text but is slower, and a page prints
/// one real for most glyphs.
fn writeReal(out: *std.Io.Writer, v: f64) !void {
    try checkPdfReal(v);
    const n: u64 = @intFromFloat(@round(@abs(v) * 10000.0));
    if (n == 0) return out.writeByte('0');
    if (v < 0) try out.writeByte('-');
    var frac = n % 10000;
    if (frac == 0) return out.print("{d}", .{n / 10000});
    var digits: usize = 4;
    while (frac % 10 == 0) : (digits -= 1) frac /= 10;
    try out.print("{d}.{d:0>[2]}", .{ n / 10000, frac, digits });
}

/// "AV" 200 times, for tests (std's form of a repeated string, as in std/tar.zig).
const av_200: *const [400]u8 = blk: {
    const pairs: [200][2]u8 = @splat("AV".*);
    break :blk @ptrCast(&pairs);
};

test "beginPage and drawText reject non-finite and huge numbers, and beginPage a size with no area" {
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_latin);
    defer std.testing.allocator.free(bytes);
    var td_doc: TestDoc = undefined;
    try td_doc.init(std.testing.allocator, true);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    var loaded_font = try zpdf.Font.init(std.testing.allocator, bytes, 0, &.{});
    defer loaded_font.deinit();
    const font = try doc.addFont(&loaded_font);
    try std.testing.expectError(error.InvalidNumber, doc.beginPage(std.math.inf(f64), 792));
    try std.testing.expectError(error.InvalidNumber, doc.beginPage(std.math.nan(f64), 792));
    try std.testing.expectError(error.InvalidNumber, doc.beginPage(1e15, 792));
    try std.testing.expectError(error.InvalidNumber, doc.beginPage(1e9 + 1e6, 792));
    try std.testing.expectError(error.InvalidNumber, doc.beginPage(0, 792));
    try std.testing.expectError(error.InvalidNumber, doc.beginPage(612, -0.0));
    try std.testing.expectError(error.InvalidNumber, doc.beginPage(-612, 792));
    const page = try doc.beginPage(1e9, 792);
    try std.testing.expectError(error.InvalidNumber, doc.drawText(page, font, std.math.inf(f64), 72, 720, .black, "a", .{}));
    try std.testing.expectError(error.InvalidNumber, doc.drawText(page, font, std.math.nan(f64), 72, 720, .black, "a", .{}));
    try std.testing.expectError(error.InvalidNumber, doc.drawText(page, font, 24, 1e15, 720, .black, "a", .{}));
    try std.testing.expectError(error.InvalidNumber, doc.drawText(page, font, 1e9 + 1e6, 72, 720, .black, "a", .{}));
    try std.testing.expectError(error.InvalidNumber, doc.drawText(page, font, 922337203685477.6, 72, 720, .black, "a", .{}));
    try doc.drawText(page, font, 1e9, 72, 720, .black, "a", .{});
    try std.testing.expectError(error.InvalidPage, doc.drawText(@fromBackingInt(@intCast(9)), font, 24, 72, 720, .black, "a", .{}));
    const written = try td_doc.finishOwned(std.testing.allocator);
    defer std.testing.allocator.free(written);
    try std.testing.expect(written.len > 0);
}

test "the page tree gives /Count within its first bytes, before /Kids" {
    const gpa = std.testing.allocator;
    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, true);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    for (0..40) |_| try doc.endPage(try doc.beginPage(612, 792));
    try doc.finish();
    var parsed = try E2e.parse(gpa, td_doc.aw.written());
    defer parsed.deinit(gpa);
    try std.testing.expect(std.mem.startsWith(u8, try parsed.objectBody(2), "<< /Type /Pages /Count 40 /Kids [3 0 R 5 0 R "));
}

test "lines, rectangles and colours are written in call order, each state change once" {
    const gpa = std.testing.allocator;
    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, true);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    const helv = try doc.addStandardFont(.helvetica);
    const red: Color = .{ .r = 1, .g = 0, .b = 0 };
    const blue: Color = .{ .r = 0, .g = 0, .b = 1 };
    const page = try doc.beginPage(612, 792);
    try doc.fillRect(page, 10, 20, 30, 40, red);
    try doc.strokeRect(page, 10, 20, 30, 40, 0.5, blue);
    try doc.drawLine(page, 0, 0, 100, 50.25, 0.5, blue);
    try doc.drawLine(page, 1, 2, 3, 4, 1, .black);
    try doc.drawText(page, helv, 12, 72, 700, red, "A", .{});
    try doc.drawText(page, helv, 12, 72, 680, .black, "B", .{});
    try doc.fillRect(page, 0, 0, 0, 0, .{ .r = 0.25, .g = 0.25, .b = 0.25 });
    try doc.endPage(page);
    try doc.finish();
    var parsed = try E2e.parse(gpa, td_doc.aw.written());
    defer parsed.deinit(gpa);
    try std.testing.expectEqualStrings(
        "1 0 0 rg\n10 20 30 40 re f\n" ++
            "0 0 1 RG\n0.5 w\n10 20 30 40 re S\n" ++
            "0 0 m 100 50.25 l S\n" ++
            "0 0 0 RG\n1 w\n1 2 m 3 4 l S\n" ++
            "BT\n/F1 12 Tf\n1 0 0 1 72 700 Tm\n(A) Tj\nET\n" ++
            "0 0 0 rg\nBT\n/F1 12 Tf\n1 0 0 1 72 680 Tm\n(B) Tj\nET\n" ++
            "0.25 0.25 0.25 rg\n0 0 0 0 re f\n",
        try parsed.streamData(4),
    );
}

test "addImage writes the image at once; each page names it once and paints it through its matrix" {
    const gpa = std.testing.allocator;
    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, false);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    const png = try loadTestImage(gpa, "pngsuite/basn6a08.png");
    defer gpa.free(png);
    const png_image = try doc.addImage(png);
    // Objects 3 (the image) and 4 (its soft mask) are written before any page exists.
    try std.testing.expect(doc.objects.offsets.items[2] != 0 and doc.objects.offsets.items[3] != 0);
    try std.testing.expectEqual(32, (try doc.imageSize(png_image)).width);
    const first = try doc.beginPage(612, 792);
    try doc.drawImage(first, png_image, 10, 20, 64, 32);
    try doc.drawImage(first, png_image, 100, 200, 32, 32);
    try doc.endPage(first);
    const second = try doc.beginPage(612, 792);
    try doc.drawImage(second, png_image, 0, 0, 1.5, 2.25);
    try doc.endPage(second);
    try doc.finish();
    var parsed = try E2e.parse(gpa, td_doc.aw.written());
    defer parsed.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, try parsed.objectBody(3), "/SMask 4 0 R ") != null);
    try std.testing.expectEqual(1, std.mem.count(u8, try parsed.objectBody(5), "/X3 3 0 R"));
    try std.testing.expectEqualStrings("q\n64 0 0 32 10 20 cm\n/X3 Do\nQ\nq\n32 0 0 32 100 200 cm\n/X3 Do\nQ\n", try parsed.streamData(6));
    try std.testing.expectEqualStrings("q\n1.5 0 0 2.25 0 0 cm\n/X3 Do\nQ\n", try parsed.streamData(8));
}

test "addImage keeps none of an image's memory once it returns" {
    const gpa = std.testing.allocator;
    // 1024 x 1024 RGBA with alpha 128 everywhere: 4 MiB of pixels, split into a colour plane and
    // a soft mask, each compressed.
    const side = 1024;
    const rows = try gpa.alloc(u8, side * (1 + side * 4));
    defer gpa.free(rows);
    for (0..side) |y| {
        const row = rows[y * (1 + side * 4) ..][0 .. 1 + side * 4];
        row[0] = 0;
        for (0..side) |x| row[1 + x * 4 ..][0..4].* = .{ @truncate(x), @truncate(y), @truncate(x ^ y), 128 };
    }
    var file_arena: std.heap.ArenaAllocator = .init(gpa);
    defer file_arena.deinit();
    const png = try image.testPng(file_arena.allocator(), .{ .width = side, .height = side, .depth = 8, .color_type = 6, .interlaced = false }, &.{.{ "IDAT", try image.testZlib(file_arena.allocator(), rows) }});

    var counting: @import("abi.zig").Counting = .{ .child = gpa };
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var doc = try Document.begin(counting.allocator(), &discard.writer, .{ .compress = true });
    defer doc.deinit();
    const before = counting.live;
    counting.peak = before;
    _ = try doc.addImage(png);
    // It did the work: the inflated rows, 4 MiB and a filter byte per row, were held.
    try std.testing.expect(counting.peak - before > 4 << 20);
    // In place: the rows, the 1 MiB alpha plane, the zlib window and the compressed streams. A
    // second full copy of the image (3 MiB of colour or more) would pass 8 MiB.
    try std.testing.expect(counting.peak - before < 8 << 20);
    // And let it all go: the image's record and its xref offsets are what stays.
    try std.testing.expect(counting.live < before + 1024);
}

test "a CMYK JPEG is written as it is, with the /Decode that reads it inverted as viewers do" {
    const gpa = std.testing.allocator;
    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, true);
    defer td_doc.deinit();
    const cmyk = try loadTestImage(gpa, "jpeg/cmyk.jpg");
    defer gpa.free(cmyk);
    const gray = try loadTestImage(gpa, "jpeg/gray.jpg");
    defer gpa.free(gray);
    _ = try td_doc.doc.addImage(cmyk);
    _ = try td_doc.doc.addImage(gray);
    const pdf = try td_doc.finishOwned(gpa);
    defer gpa.free(pdf);
    var parsed = try E2e.parse(gpa, pdf);
    defer parsed.deinit(gpa);
    const cmyk_dict = try parsed.objectBody(3);
    try std.testing.expect(std.mem.indexOf(u8, cmyk_dict, "/ColorSpace /DeviceCMYK /BitsPerComponent 8 /Decode [1 0 1 0 1 0 1 0] ") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmyk_dict, "/Filter /DCTDecode") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, cmyk) != null);
    try std.testing.expect(std.mem.indexOf(u8, try parsed.objectBody(4), "/Decode") == null);
}

test "a refused addImage or drawImage writes nothing and changes nothing" {
    const gpa = std.testing.allocator;
    const png = try loadTestImage(gpa, "pngsuite/basn6a08.png");
    defer gpa.free(png);
    var plain: TestDoc = undefined;
    try plain.init(gpa, true);
    defer plain.deinit();
    const one = try plain.doc.addImage(png);
    const plain_mirrored = try loadTestImage(gpa, "exif/orient-2.png");
    defer gpa.free(plain_mirrored);
    const plain_page = try plain.doc.beginPage(100, 100);
    _ = try plain.doc.addImage(plain_mirrored);
    try plain.doc.drawImage(plain_page, one, 0, 0, 10, 10);
    const want = try plain.finishOwned(gpa);
    defer gpa.free(want);

    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, true);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    try std.testing.expectError(error.UnsupportedImage, doc.addImage("GIF89a"));
    try std.testing.expectError(error.InvalidImage, doc.addImage(png[0 .. png.len - 20]));
    try std.testing.expectError(error.TooLarge, blk: {
        doc.max_image_bytes = 100;
        defer doc.max_image_bytes = default_max_image_bytes;
        break :blk doc.addImage(png);
    });
    const png_image = try doc.addImage(png);
    try std.testing.expectError(error.InvalidImage, doc.imageSize(@fromBackingInt(1)));
    const page = try doc.beginPage(100, 100);
    try std.testing.expectError(error.InvalidImage, doc.drawImage(page, @fromBackingInt(1), 0, 0, 10, 10));
    try std.testing.expectError(error.InvalidNumber, doc.drawImage(page, png_image, 0, 0, 0, 10));
    try std.testing.expectError(error.InvalidNumber, doc.drawImage(page, png_image, 0, 0, 10, std.math.nan(f64)));
    // A mirrored image's matrix prints x + width: each number is in range, and that one is not.
    const mirrored_png = try loadTestImage(gpa, "exif/orient-2.png");
    defer gpa.free(mirrored_png);
    const mirrored = try doc.addImage(mirrored_png);
    try std.testing.expectError(error.InvalidNumber, doc.drawImage(page, mirrored, max_pdf_real, 0, 10, 10));
    try doc.drawImage(page, png_image, 0, 0, 10, 10);
    const got = try td_doc.finishOwned(gpa);
    defer gpa.free(got);
    try std.testing.expectEqualSlices(u8, want, got);
}

test "reserveLater and drawTextLater write Page N of M as forms the pages paint" {
    const gpa = std.testing.allocator;
    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, true);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    const helv = try doc.addStandardFont(.helvetica);
    var laters: [3]LaterId = undefined;
    for (&laters) |*later| {
        const page = try doc.beginPage(612, 792);
        // The page's fill colour is red where the form is painted; the form must still
        // draw black, so it sets its colour itself.
        try doc.fillRect(page, 0, 0, 612, 20, .{ .r = 1, .g = 0, .b = 0 });
        later.* = try doc.reserveLater(page);
        try doc.endPage(page);
    }
    try std.testing.expectError(error.LaterNotDrawn, doc.finish());
    for (laters, 1..) |later, n| {
        var buf: [32]u8 = undefined;
        try doc.drawTextLater(later, helv, 9, 300, 30, .black, try std.fmt.bufPrint(&buf, "Page {d} of {d}", .{ n, laters.len }), .{});
    }
    try doc.finish();

    var parsed = try E2e.parse(gpa, td_doc.aw.written());
    defer parsed.deinit(gpa);
    // Page 0 is objects 3 and 4 and its form 5; the font is numbered when the first form is
    // written, after the three pages (6 to 11).
    try E2e.expectContains(try parsed.objectBody(3), "/Resources << /Font << >> /XObject << /X5 5 0 R >> >> >>");
    try std.testing.expectEqualStrings("1 0 0 rg\n0 0 612 20 re f\n/X5 Do\n", try parsed.streamData(4));
    try std.testing.expect(std.mem.startsWith(u8, try parsed.objectBody(5), "<< /Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources << /Font << /F1 12 0 R >> >> /Length "));
    try std.testing.expectEqualStrings("0 0 0 rg\nBT\n/F1 9 Tf\n1 0 0 1 300 30 Tm\n(Page 1 of 3) Tj\nET\n", try parsed.streamData(5));
    try E2e.expectContains(try parsed.objectBody(9), "/XObject << /X11 11 0 R >>");
    try E2e.expectContains(try parsed.streamData(11), "(Page 3 of 3) Tj");
    try E2e.expectContains(try parsed.objectBody(2), "/Count 3 ");
}

test "drawTextLater draws an embedded font's glyphs into its subset and ToUnicode" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const bytes = try E2e.load(options.test_font_roboto);
    defer gpa.free(bytes);
    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, true);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    var loaded_font = try zpdf.Font.init(gpa, bytes, 0, &.{});
    defer loaded_font.deinit();
    const font = try doc.addFont(&loaded_font);
    const page = try doc.beginPage(612, 792);
    try doc.drawText(page, font, 12, 72, 700, .black, "abc", .{});
    const later = try doc.reserveLater(page);
    // Drawn while its page is still open.
    try doc.drawTextLater(later, font, 12, 72, 680, .black, "XYZ", .{});
    try doc.endPage(page);
    try doc.finish();
    var parsed = try E2e.parse(gpa, td_doc.aw.written());
    defer parsed.deinit(gpa);
    // Page 3, content 4, form 5, font 6 to 11 (ToUnicode 11). X, Y and Z are only in the form.
    try E2e.expectContains(try parsed.objectBody(5), "/Font << /F1 6 0 R >>");
    const to_unicode = try parsed.streamData(11);
    for ([_][]const u8{ "<0061>", "<0058>", "<0059>", "<005A>" }) |cp| try E2e.expectContains(to_unicode, cp);
    const subset = try sfnt.open(try parsed.streamData(9), 0);
    try std.testing.expect(subset.num_glyphs >= 7);
}

test "drawTextLater while a page is open leaves that page's drawing intact" {
    const gpa = std.testing.allocator;
    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, true);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    const helv = try doc.addStandardFont(.helvetica);
    const first = try doc.beginPage(612, 792);
    const later = try doc.reserveLater(first);
    try doc.endPage(first);
    const page = try doc.beginPage(612, 792);
    try doc.drawText(page, helv, 9, 72, 700, .black, "before", .{});
    try doc.drawTextLater(later, helv, 9, 72, 30, .black, "later", .{});
    // These allocate in the page arena after drawTextLater, where the page's op list lives.
    for (0..8) |_| try doc.drawText(page, helv, 9, 72, 680, .black, "after after after after", .{});
    try doc.endPage(page);
    try doc.finish();
    var parsed = try E2e.parse(gpa, td_doc.aw.written());
    defer parsed.deinit(gpa);
    // Pages 3 and 6, contents 4 and 7, form 5.
    const content = try parsed.streamData(7);
    try std.testing.expect(std.mem.startsWith(u8, content, "BT\n/F1 9 Tf\n1 0 0 1 72 700 Tm\n(before) Tj\nET\n"));
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, content, "(after after after after) Tj"));
    try E2e.expectContains(try parsed.streamData(5), "(later) Tj");
}

test "reserveLater and drawTextLater refuse bad calls, and a refused call draws nothing" {
    const gpa = std.testing.allocator;
    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, false);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    const helv = try doc.addStandardFont(.helvetica);
    try std.testing.expectError(error.InvalidPage, doc.reserveLater(@fromBackingInt(@intCast(0))));
    const page = try doc.beginPage(612, 792);
    try std.testing.expectError(error.InvalidPage, doc.reserveLater(@fromBackingInt(@intCast(1))));
    const later = try doc.reserveLater(page);
    try std.testing.expectError(error.InvalidLater, doc.drawTextLater(@fromBackingInt(@intCast(1)), helv, 9, 0, 0, .black, "x", .{}));
    try std.testing.expectError(error.InvalidFont, doc.drawTextLater(later, @fromBackingInt(@intCast(7)), 9, 0, 0, .black, "x", .{}));
    try std.testing.expectError(error.NotWinAnsi, doc.drawTextLater(later, helv, 9, 0, 0, .black, "\u{0142}", .{}));
    try std.testing.expectError(error.InvalidColor, doc.drawTextLater(later, helv, 9, 0, 0, .{ .r = 2, .g = 0, .b = 0 }, "x", .{}));
    try std.testing.expectError(error.InvalidNumber, doc.drawTextLater(later, helv, std.math.inf(f64), 0, 0, .black, "x", .{}));
    try doc.endPage(page);
    try std.testing.expectError(error.LaterNotDrawn, doc.finish());
    // The refused calls left the place open; it is drawn once.
    try doc.drawTextLater(later, helv, 9, 0, 0, .black, "x", .{});
    try std.testing.expectError(error.LaterDrawn, doc.drawTextLater(later, helv, 9, 0, 0, .black, "x", .{}));
    try doc.finish();
    try std.testing.expectError(error.DocumentFinished, doc.drawTextLater(later, helv, 9, 0, 0, .black, "x", .{}));
    try std.testing.expectError(error.DocumentFinished, doc.reserveLater(page));
}

test "drawLine, fillRect, strokeRect and drawText refuse bad arguments and then draw nothing" {
    const gpa = std.testing.allocator;
    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, false);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    const helv = try doc.addStandardFont(.helvetica);
    const page = try doc.beginPage(612, 792);
    const ops = &doc.open.?.ops;
    const bad_colors = [_]Color{
        .{ .r = 1.5, .g = 0, .b = 0 },
        .{ .r = 0, .g = -0.1, .b = 0 },
        .{ .r = 0, .g = 0, .b = std.math.nan(f64) },
        .{ .r = std.math.inf(f64), .g = 0, .b = 0 },
    };
    for (bad_colors) |c| {
        try std.testing.expectError(error.InvalidColor, doc.drawText(page, helv, 12, 72, 700, c, "a", .{}));
        try std.testing.expectError(error.InvalidColor, doc.drawLine(page, 0, 0, 1, 1, 1, c));
        try std.testing.expectError(error.InvalidColor, doc.fillRect(page, 0, 0, 1, 1, c));
        try std.testing.expectError(error.InvalidColor, doc.strokeRect(page, 0, 0, 1, 1, 1, c));
    }
    try std.testing.expectError(error.InvalidNumber, doc.fillRect(page, 0, 0, -1, 1, .black));
    try std.testing.expectError(error.InvalidNumber, doc.strokeRect(page, 0, 0, 1, -1, 1, .black));
    try std.testing.expectError(error.InvalidNumber, doc.fillRect(page, std.math.nan(f64), 0, 1, 1, .black));
    try std.testing.expectError(error.InvalidNumber, doc.drawLine(page, 0, 0, 1, 1e10, 1, .black));
    try std.testing.expectError(error.InvalidNumber, doc.drawLine(page, 0, 0, 1, 1, 0, .black));
    // Written with 4 decimals, this width would be "0", the device's thinnest line.
    try std.testing.expectError(error.InvalidNumber, doc.drawLine(page, 0, 0, 1, 1, 0.00004, .black));
    try std.testing.expectError(error.InvalidNumber, doc.strokeRect(page, 0, 0, 1, 1, -1, .black));
    try std.testing.expectError(error.InvalidPage, doc.drawLine(@fromBackingInt(@intCast(1)), 0, 0, 1, 1, 1, .black));
    try std.testing.expectError(error.InvalidPage, doc.fillRect(@fromBackingInt(@intCast(1)), 0, 0, 1, 1, .black));
    try std.testing.expectError(error.InvalidPage, doc.strokeRect(@fromBackingInt(@intCast(1)), 0, 0, 1, 1, 1, .black));
    try std.testing.expectEqual(@as(usize, 0), ops.items.len);

    // The smallest width zpdf accepts, and the edges of the colour range, are drawn.
    try doc.drawLine(page, 0, 0, 1, 1, 0.0001, .{ .r = 0, .g = 1, .b = 0 });
    try doc.fillRect(page, 0, 0, 0, 0, .white);
    try std.testing.expectEqual(@as(usize, 2), ops.items.len);
    try doc.endPage(page);
    try std.testing.expectError(error.InvalidPage, doc.drawLine(page, 0, 0, 1, 1, 1, .black));
    try doc.finish();
    try std.testing.expectError(error.DocumentFinished, doc.fillRect(page, 0, 0, 1, 1, .black));
}

test "one page open at a time; a finished or failed document refuses every call" {
    const gpa = std.testing.allocator;
    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, false);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    const helv = try doc.addStandardFont(.helvetica);
    try std.testing.expectError(error.InvalidPage, doc.endPage(@fromBackingInt(@intCast(0))));
    const p0 = try doc.beginPage(612, 792);
    try std.testing.expectError(error.PageOpen, doc.beginPage(612, 792));
    try std.testing.expectError(error.PageOpen, doc.finish());
    try std.testing.expectError(error.InvalidPage, doc.endPage(@fromBackingInt(@intCast(1))));
    try doc.drawText(p0, helv, 12, 72, 720, .black, "a", .{});
    try doc.endPage(p0);
    try std.testing.expectError(error.InvalidPage, doc.endPage(p0));
    const p1 = try doc.beginPage(612, 792);
    try std.testing.expectEqual(@as(u32, 1), @backingInt(p1));
    // A page already written takes no more drawing.
    try std.testing.expectError(error.InvalidPage, doc.drawText(p0, helv, 12, 72, 700, .black, "b", .{}));
    try doc.endPage(p1);
    try doc.finish();
    try E2e.expectContains(td_doc.aw.written(), "/Count 2");
    try std.testing.expectError(error.DocumentFinished, doc.finish());
    try std.testing.expectError(error.DocumentFinished, doc.beginPage(612, 792));
    try std.testing.expectError(error.DocumentFinished, doc.addStandardFont(.courier));
    try std.testing.expectError(error.DocumentFinished, doc.drawText(p1, helv, 12, 72, 700, .black, "b", .{}));

    // A sink that fails partway leaves a partial file, so nothing after it is written.
    var sink: Trickle = .{ .gpa = gpa, .limit = 10 };
    defer sink.taken.deinit(gpa);
    var failed = try Document.begin(gpa, &sink.writer, .{ .compress = false });
    defer failed.deinit();
    const f = try failed.addStandardFont(.helvetica);
    const page = try failed.beginPage(612, 792);
    try failed.drawText(page, f, 12, 72, 720, .black, "a", .{});
    try failed.endPage(page);
    try std.testing.expectError(error.WriteFailed, failed.finish());
    try std.testing.expectError(error.DocumentFailed, failed.finish());
    try std.testing.expectError(error.DocumentFailed, failed.beginPage(612, 792));
    try std.testing.expectError(error.DocumentFailed, failed.addStandardFont(.courier));

    // The same when endPage is the write that fails: a page larger than zpdf's buffer
    // reaches the sink before finish.
    var page_sink: Trickle = .{ .gpa = gpa, .limit = 10 };
    defer page_sink.taken.deinit(gpa);
    var failed_page = try Document.begin(gpa, &page_sink.writer, .{ .compress = false });
    defer failed_page.deinit();
    const fp = try failed_page.addStandardFont(.helvetica);
    const big = try failed_page.beginPage(612, 792);
    const text = printableAscii();
    for (0..100) |_| try failed_page.drawText(big, fp, 12, 72, 720, .black, &text, .{});
    try std.testing.expectError(error.WriteFailed, failed_page.endPage(big));
    try std.testing.expectError(error.DocumentFailed, failed_page.endPage(big));
    try std.testing.expectError(error.DocumentFailed, failed_page.drawText(big, fp, 12, 72, 720, .black, "a", .{}));
    try std.testing.expectError(error.DocumentFailed, failed_page.finish());
}

fn testGlyph(offset_x: i32, offset_y: i32, advance_x: i32) zpdf.Glyph {
    return .{
        .id = 0,
        ._reserved0 = 0,
        .cluster = 0,
        .advance_x = advance_x,
        .advance_y = 0,
        .offset_x = offset_x,
        .offset_y = offset_y,
    };
}

test "checkDrawReals rejects a Ts several em at size 1e9" {
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_latin);
    defer std.testing.allocator.free(bytes);
    const face = try sfnt.open(bytes, 0);
    var font = try zpdf.Font.init(std.testing.allocator, bytes, 0, &.{});
    defer font.deinit();
    const em: i32 = face.units_per_em;
    const glyphs = [_]zpdf.Glyph{testGlyph(0, em * 4, 0)};
    try std.testing.expectError(error.InvalidNumber, checkDrawReals(1e9, &glyphs, face, &font));
}

test "checkDrawReals rejects a TJ number past 1e9 thousandths of an em" {
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_latin);
    defer std.testing.allocator.free(bytes);
    var face = try sfnt.open(bytes, 0);
    var font = try zpdf.Font.init(std.testing.allocator, bytes, 0, &.{});
    defer font.deinit();
    // A TJ number does not scale with the size: at 16 units per em an x
    // offset of 2^31-1 units is about 1.3e11 thousandths.
    face.units_per_em = 16;
    const far = [_]zpdf.Glyph{testGlyph(std.math.maxInt(i32), 0, 0)};
    try std.testing.expectError(error.InvalidNumber, checkDrawReals(1, &far, face, &font));
    // 1e9 thousandths is 1.6e7 units here; just inside passes.
    const near = [_]zpdf.Glyph{testGlyph(-16_000_000, 0, 0)};
    try checkDrawReals(1, &near, face, &font);
}

test "checkDrawReals accepts a 500-pair TJ that only the printed adj stays in range" {
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_latin);
    defer std.testing.allocator.free(bytes);
    var face = try sfnt.open(bytes, 0);
    var font = try zpdf.Font.init(std.testing.allocator, bytes, 0, &.{});
    defer font.deinit();
    face.units_per_em = 16;
    var glyphs: [500]zpdf.Glyph = undefined;
    for (&glyphs) |*g| g.* = testGlyph(-32768, 0, 32768);
    try checkDrawReals(24, &glyphs, face, &font);
}

test "MediaBox uses at most 4 decimal places" {
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_latin);
    defer std.testing.allocator.free(bytes);
    var td_doc: TestDoc = undefined;
    try td_doc.init(std.testing.allocator, true);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    var unused_font1 = try zpdf.Font.init(std.testing.allocator, bytes, 0, &.{});
    defer unused_font1.deinit();
    _ = try doc.addFont(&unused_font1);
    _ = try doc.beginPage(595.2755905511812, 841.8897637795276);
    const written = try td_doc.finishOwned(std.testing.allocator);
    defer std.testing.allocator.free(written);
    try E2e.expectContains(written, "/MediaBox [0 0 595.2756 841.8898]");
}

test "writeReal prints at most 4 decimals, no trailing zeros, and never -0" {
    const cases = [_]struct { f64, []const u8 }{
        .{ 0, "0" },
        .{ -0.0, "0" },
        .{ -0.00004, "0" },
        .{ 0.00004, "0" },
        .{ -0.00005, "-0.0001" },
        .{ 612, "612" },
        .{ 1.5, "1.5" },
        .{ -12.25, "-12.25" },
        .{ 595.2755905511812, "595.2756" },
        .{ 999999999.99995, "1000000000" },
        .{ -1e9, "-1000000000" },
    };
    for (cases) |c| {
        var buf: [32]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try writeReal(&w, c[0]);
        try std.testing.expectEqualStrings(c[1], w.buffered());
    }
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.InvalidNumber, writeReal(&w, 1e9 + 1));
}

test "CIDs are written as 4 uppercase hex digits" {
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_roboto);
    defer std.testing.allocator.free(bytes);
    var td_doc: TestDoc = undefined;
    try td_doc.init(std.testing.allocator, true);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    var loaded_font = try zpdf.Font.init(std.testing.allocator, bytes, 0, &.{});
    defer loaded_font.deinit();
    const font = try doc.addFont(&loaded_font);
    const page = try doc.beginPage(612, 792);
    // 94 different glyphs, so CIDs 10 to 15 (hex A to F) are used.
    const text = printableAscii();
    try doc.drawText(page, font, 12, 72, 700, .black, &text, .{});
    const pdf = try td_doc.finishOwned(std.testing.allocator);
    defer std.testing.allocator.free(pdf);
    var parsed = try E2e.parse(std.testing.allocator, pdf);
    defer parsed.deinit(std.testing.allocator);
    const content = try parsed.streamData(4);
    try E2e.expectContains(content, "<000A>");
    try E2e.expectContains(content, "<005E>");
    try std.testing.expect(std.mem.indexOf(u8, content, "<000a>") == null);
}

test "Document writes a PDF header for one word" {
    const options = @import("build_options");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.test_font_roboto, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);

    var td_doc: TestDoc = undefined;
    try td_doc.init(std.testing.allocator, true);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    var loaded_font = try zpdf.Font.init(std.testing.allocator, bytes, 0, &.{});
    defer loaded_font.deinit();
    const font = try doc.addFont(&loaded_font);
    const page = try doc.beginPage(612, 792);
    try doc.drawText(page, font, 24, 72, 720, .black, "office", .{});

    const written = try td_doc.finishOwned(std.testing.allocator);

    defer std.testing.allocator.free(written);
    const pdf = written;
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.7\n%"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "\nxref\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, pdf, "%%EOF\n"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Font /Subtype /Type0") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Encoding /Identity-H") != null);
}

const E2e = if (!@import("builtin").is_test) struct {} else struct {
    const Parsed = struct {
        bytes: []const u8,
        offsets: []u32,
        size: u32,
        xref_at: u32,
        /// Holds inflated stream data until deinit.
        inflated: *std.heap.ArenaAllocator,

        fn deinit(self: *Parsed, gpa: std.mem.Allocator) void {
            gpa.free(self.offsets);
            self.inflated.deinit();
            gpa.destroy(self.inflated);
            self.* = undefined;
        }

        fn objectBody(self: Parsed, num: u32) ![]const u8 {
            if (num == 0 or num > self.offsets.len) return error.TestUnexpectedResult;
            const off = self.offsets[num - 1];
            if (off >= self.bytes.len) return error.TestUnexpectedResult;
            var rest = self.bytes[off..];
            var buf: [16]u8 = undefined;
            const head = std.fmt.bufPrint(&buf, "{d} 0 obj\n", .{num}) catch return error.TestUnexpectedResult;
            if (!std.mem.startsWith(u8, rest, head)) return error.TestUnexpectedResult;
            rest = rest[head.len..];
            // A stream's dictionary ends in ">>\nstream\n" before any
            // "\nendobj\n"; searching further would find the next object's.
            const endobj = std.mem.indexOf(u8, rest, "\nendobj\n") orelse return error.TestUnexpectedResult;
            const stream_at = std.mem.indexOf(u8, rest, ">>\nstream\n");
            if (stream_at != null and stream_at.? < endobj) {
                const at = stream_at.?;
                const length = try E2e.dictU32(rest, "/Length ");
                const start = at + ">>\nstream\n".len;
                const end = start + length;
                if (end > rest.len) return error.TestUnexpectedResult;
                if (!std.mem.startsWith(u8, rest[end..], "\nendstream\nendobj\n")) return error.TestUnexpectedResult;
                return rest[0 .. end + "\nendstream".len];
            }
            return rest[0..endobj];
        }

        /// The stream's data as a reader sees it: inflated when the
        /// dictionary names /FlateDecode, which must then use all /Length
        /// bytes and pass the zlib checksum.
        fn streamData(self: Parsed, num: u32) ![]const u8 {
            const body = try self.objectBody(num);
            const length = try E2e.dictU32(body, "/Length ");
            const marker = ">>\nstream\n";
            const at = std.mem.indexOf(u8, body, marker) orelse return error.TestUnexpectedResult;
            const start = at + marker.len;
            if (start + length > body.len) return error.TestUnexpectedResult;
            const raw = body[start .. start + length];
            if (std.mem.indexOf(u8, body[0..at], "/Filter /FlateDecode") == null) return raw;
            const a = self.inflated.allocator();
            var in: std.Io.Reader = .fixed(raw);
            const window = try a.alloc(u8, std.compress.flate.max_window_len);
            var inflate: std.compress.flate.Decompress = .init(&in, .zlib, window);
            const data = try inflate.reader.allocRemaining(a, .unlimited);
            if (in.bufferedLen() != 0) return error.TestUnexpectedResult;
            return data;
        }
    };

    fn dictU32(body: []const u8, key: []const u8) !u32 {
        const at = std.mem.indexOf(u8, body, key) orelse return error.TestUnexpectedResult;
        const rest = body[at + key.len ..];
        var i: usize = 0;
        while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
        if (i == 0) return error.TestUnexpectedResult;
        return std.fmt.parseInt(u32, rest[0..i], 10);
    }

    fn parse(gpa: std.mem.Allocator, pdf: []const u8) !Parsed {
        if (!std.mem.startsWith(u8, pdf, "%PDF-1.7\n%")) return error.TestUnexpectedResult;
        if (pdf.len < 14) return error.TestUnexpectedResult;
        if (pdf[10] < 128 or pdf[11] < 128 or pdf[12] < 128 or pdf[13] < 128) return error.TestUnexpectedResult;
        if (!std.mem.endsWith(u8, pdf, "%%EOF\n")) return error.TestUnexpectedResult;

        const sx = std.mem.lastIndexOf(u8, pdf, "\nstartxref\n") orelse return error.TestUnexpectedResult;
        const after = pdf[sx + "\nstartxref\n".len ..];
        const nl = std.mem.indexOfScalar(u8, after, '\n') orelse return error.TestUnexpectedResult;
        const xref_at = try std.fmt.parseInt(u32, after[0..nl], 10);
        if (xref_at >= pdf.len) return error.TestUnexpectedResult;
        const xref = pdf[xref_at..];
        if (!std.mem.startsWith(u8, xref, "xref\n0 ")) return error.TestUnexpectedResult;
        const rest = xref["xref\n0 ".len..];
        const sp = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.TestUnexpectedResult;
        const size = try std.fmt.parseInt(u32, rest[0..sp], 10);
        if (size < 2) return error.TestUnexpectedResult;

        var offsets = try gpa.alloc(u32, size - 1);
        errdefer gpa.free(offsets);
        const inflated = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(inflated);
        inflated.* = .init(gpa);
        var line_start = sp + 1;
        // free entry
        if (!std.mem.startsWith(u8, rest[line_start..], "0000000000 65535 f \n")) return error.TestUnexpectedResult;
        line_start += 20;
        var i: u32 = 0;
        while (i < size - 1) : (i += 1) {
            if (line_start + 20 > rest.len) return error.TestUnexpectedResult;
            const line = rest[line_start .. line_start + 20];
            if (line[10] != ' ' or !std.mem.eql(u8, line[11..19], "00000 n ") or line[19] != '\n') {
                return error.TestUnexpectedResult;
            }
            offsets[i] = try std.fmt.parseInt(u32, line[0..10], 10);
            var buf: [16]u8 = undefined;
            const head = std.fmt.bufPrint(&buf, "{d} 0 obj\n", .{i + 1}) catch return error.TestUnexpectedResult;
            if (offsets[i] >= pdf.len or !std.mem.startsWith(u8, pdf[offsets[i]..], head)) {
                return error.TestUnexpectedResult;
            }
            line_start += 20;
        }
        return .{ .bytes = pdf, .offsets = offsets, .size = size, .xref_at = xref_at, .inflated = inflated };
    }

    fn load(path: []const u8) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
    }

    fn writePdf(font_bytes: []const u8, text: []const u8, direction: zpdf.Direction, variations: []const zpdf.Variation) ![]u8 {
        var td_doc: TestDoc = undefined;
        try td_doc.init(std.testing.allocator, true);
        defer td_doc.deinit();
        const doc = &td_doc.doc;
        var loaded_font = try zpdf.Font.init(std.testing.allocator, font_bytes, 0, variations);
        defer loaded_font.deinit();
        const font = try doc.addFont(&loaded_font);
        const page = try doc.beginPage(612, 792);
        try doc.drawText(page, font, 24, 72, 720, .black, text, .{ .paragraph_direction = direction });
        return td_doc.finishOwned(std.testing.allocator);
    }

    fn checkIdentityH(p: Parsed, orig_bytes: []const u8, variations: []const zpdf.Variation) !void {
        const type0 = try p.objectBody(5);
        try std.testing.expect(std.mem.indexOf(u8, type0, "/Subtype /Type0") != null);
        try std.testing.expect(std.mem.indexOf(u8, type0, "/Encoding /Identity-H") != null);
        try std.testing.expect(std.mem.indexOf(u8, type0, "/ToUnicode 10 0 R") != null);
        const cid = try p.objectBody(6);
        try std.testing.expect(std.mem.indexOf(u8, cid, "/Subtype /CIDFontType2") != null);
        try std.testing.expect(std.mem.indexOf(u8, cid, "/Ordering (Identity)") != null);
        try std.testing.expect(std.mem.indexOf(u8, cid, "/CIDToGIDMap 9 0 R") != null);
        try std.testing.expect(std.mem.indexOf(u8, cid, "/W [") != null);
        const desc = try p.objectBody(7);
        try std.testing.expect(std.mem.indexOf(u8, desc, "/Flags 4") != null);
        try std.testing.expect(std.mem.indexOf(u8, desc, "/StemV 80") != null);
        try std.testing.expect(std.mem.indexOf(u8, desc, "/FontFile2 8 0 R") != null);
        const subset = try p.streamData(8);
        const face = try sfnt.open(subset, 0);
        try std.testing.expectEqual(@as(i16, 1), face.loca_format);
        const cmap = try p.streamData(10);
        try std.testing.expect(std.mem.indexOf(u8, cmap, "begincmap") != null);
        try std.testing.expect(std.mem.indexOf(u8, cmap, "endcodespacerange") != null);
        const contents = try p.streamData(4);
        try std.testing.expect(std.mem.startsWith(u8, contents, "BT\n"));
        try std.testing.expect(std.mem.endsWith(u8, contents, "ET\n") or std.mem.endsWith(u8, contents, "ET"));
        try checkCidToGidWAndSubset(p, orig_bytes, variations);
        try checkTrailer(p);
    }

    fn gidForCid(map: []const u8, cid: u16) !u16 {
        const off = @as(usize, cid) * 2;
        if (off + 2 > map.len) return error.TestUnexpectedResult;
        return std.mem.readInt(u16, map[off..][0..2], .big);
    }

    /// /W must hold, for each CID, the width of its glyph: the hmtx advance
    /// for a font drawn with no variations, read here straight from the file;
    /// with variations, kb's advance at the instance (kbts_GetGlyphAdvanceX
    /// through a Font loaded here), and then at least one width must differ
    /// from hmtx, or the instance never reached the PDF.
    fn checkCidToGidWAndSubset(p: Parsed, orig_bytes: []const u8, variations: []const zpdf.Variation) !void {
        const orig = try sfnt.open(orig_bytes, 0);
        var instance = try zpdf.Font.init(std.testing.allocator, orig_bytes, 0, variations);
        defer instance.deinit();
        var n_varied: usize = 0;
        const map = try p.streamData(9);
        if (map.len < 2 or map.len % 2 != 0) return error.TestUnexpectedResult;
        const n_cids = map.len / 2;
        try std.testing.expectEqual(@as(u16, 0), try gidForCid(map, 0));

        const cid_obj = try p.objectBody(6);
        const w_mark = "/W [ 0 [";
        const w_at = std.mem.indexOf(u8, cid_obj, w_mark) orelse return error.TestUnexpectedResult;
        const w_rest = cid_obj[w_at + w_mark.len ..];
        const w_end = std.mem.indexOf(u8, w_rest, "] ]") orelse return error.TestUnexpectedResult;
        var n_w: usize = 0;
        var it = std.mem.tokenizeScalar(u8, w_rest[0..w_end], ' ');
        var cid: u16 = 0;
        while (it.next()) |tok| : (cid += 1) {
            if (cid >= n_cids) return error.TestUnexpectedResult;
            const gid = try gidForCid(map, cid);
            const hmtx_w = orig.toThousandths(@intCast(try sfnt.glyphAdvance(orig, gid)));
            const want_w = if (variations.len == 0) hmtx_w else orig.toThousandths(instance.glyphAdvanceX(gid));
            const got_w = try std.fmt.parseInt(i32, tok, 10);
            try std.testing.expectEqual(want_w, got_w);
            if (got_w != hmtx_w) n_varied += 1;
            n_w += 1;
        }
        try std.testing.expectEqual(n_cids, n_w);
        if (variations.len != 0) try std.testing.expect(n_varied > 0);

        const subset = try p.streamData(8);
        const sub = try sfnt.open(subset, 0);
        try std.testing.expectEqual(orig.num_glyphs, sub.num_glyphs);
        try std.testing.expectEqual(@as(i16, 1), sub.loca_format);

        var seeds = ManagedList(u16).init(std.testing.allocator);
        defer seeds.deinit();
        cid = 0;
        while (cid < n_cids) : (cid += 1) {
            try seeds.append(try gidForCid(map, cid));
        }
        var collected = try sfnt.collectUsed(std.testing.allocator, orig, seeds.items);
        defer collected.deinit();
        const sorted = try sfnt.sortedUsedGids(std.testing.allocator, &collected);
        defer std.testing.allocator.free(sorted);
        const prefix = sfnt.subsetPrefix(sorted, instance.normalized);
        if (instance.isInstanced()) return checkInstancedSubset(p, orig, &instance, seeds.items, &collected, &prefix);
        var gid: u16 = 0;
        while (gid < orig.num_glyphs) : (gid += 1) {
            const got = try sfnt.glyphData(sub, gid);
            if (collected.isSet(gid)) {
                try std.testing.expectEqualSlices(u8, try sfnt.glyphData(orig, gid), got);
            } else {
                try std.testing.expectEqual(@as(usize, 0), got.len);
            }
        }

        const ps = orig.postscriptName();
        var base_buf: [80]u8 = undefined;
        const base = std.fmt.bufPrint(&base_buf, "/BaseFont /{s}+{s}", .{ prefix, ps }) catch return error.TestUnexpectedResult;
        try expectContains(try p.objectBody(5), base);
        try expectContains(try p.objectBody(7), "/FontName /");
        try expectContains(try p.objectBody(7), ps);

        var bbox_buf: [96]u8 = undefined;
        const bbox = std.fmt.bufPrint(&bbox_buf, "/FontBBox [{d} {d} {d} {d}]", .{
            orig.toThousandths(orig.x_min),
            orig.toThousandths(orig.y_min),
            orig.toThousandths(orig.x_max),
            orig.toThousandths(orig.y_max),
        }) catch return error.TestUnexpectedResult;
        const desc = try p.objectBody(7);
        try expectContains(desc, bbox);
        var metric_buf: [80]u8 = undefined;
        try expectContains(desc, std.fmt.bufPrint(&metric_buf, "/Ascent {d}", .{orig.toThousandths(orig.ascent)}) catch return error.TestUnexpectedResult);
        try expectContains(desc, std.fmt.bufPrint(&metric_buf, "/Descent {d}", .{orig.toThousandths(orig.descent)}) catch return error.TestUnexpectedResult);
        try expectContains(desc, std.fmt.bufPrint(&metric_buf, "/CapHeight {d}", .{orig.toThousandths(orig.cap_height)}) catch return error.TestUnexpectedResult);
    }

    /// A font drawn at an instance that is not the default embeds instanced
    /// outlines. Its glyphs must be instancer.subsetInstance's (which the
    /// fontTools oracle test checks), its hmtx advance must be kb's advance,
    /// the width /W was made from, and it must carry no hinting or variation
    /// table. Name and metrics follow fontDescription.
    fn checkInstancedSubset(p: Parsed, orig: sfnt.Face, instance: *const zpdf.Font, seeds: []const u16, collected: *const std.DynamicBitSet, prefix: *const [6]u8) !void {
        const gpa = std.testing.allocator;
        const subset = try p.streamData(8);
        const sub = try sfnt.open(subset, 0);
        const tables = [_]*const [4]u8{ "glyf", "head", "hhea", "hmtx", "loca", "maxp" };
        try std.testing.expectEqual(@as(u16, tables.len), std.mem.readInt(u16, subset[4..6], .big));
        for (tables) |tag| try std.testing.expect(try sfnt.faceTable(sub, tag) != null);

        const want = try instancer.subsetInstance(gpa, orig, seeds, instance.normalized, null);
        defer gpa.free(want.bytes);
        const want_face = try sfnt.open(want.bytes, 0);
        var n_moved: usize = 0;
        var gid: u16 = 0;
        while (gid < orig.num_glyphs) : (gid += 1) {
            const got = try sfnt.glyphData(sub, gid);
            try std.testing.expectEqualSlices(u8, try sfnt.glyphData(want_face, gid), got);
            if (!collected.isSet(gid)) {
                try std.testing.expectEqual(@as(usize, 0), got.len);
                continue;
            }
            try std.testing.expectEqual(instance.glyphAdvanceX(gid), @as(i32, try sfnt.glyphAdvance(sub, gid)));
            if (!std.mem.eql(u8, got, try sfnt.glyphData(orig, gid))) n_moved += 1;
        }
        try std.testing.expect(n_moved > 0);

        const name = try sfnt.instancePostscriptName(orig, instance.coordinates);
        var base_buf: [160]u8 = undefined;
        try expectContains(try p.objectBody(5), std.fmt.bufPrint(&base_buf, "/BaseFont /{s}+{s} ", .{ prefix, name.slice() }) catch return error.TestUnexpectedResult);
        const desc = try p.objectBody(7);
        try expectContains(desc, std.fmt.bufPrint(&base_buf, "/FontName /{s}+{s} ", .{ prefix, name.slice() }) catch return error.TestUnexpectedResult);
        try expectContains(desc, std.fmt.bufPrint(&base_buf, "/FontBBox [{d} {d} {d} {d}]", .{
            orig.toThousandths(sub.x_min),
            orig.toThousandths(sub.y_min),
            orig.toThousandths(sub.x_max),
            orig.toThousandths(sub.y_max),
        }) catch return error.TestUnexpectedResult);
        try expectContains(desc, std.fmt.bufPrint(&base_buf, "/Ascent {d} ", .{orig.toThousandths(orig.ascent + try instance.metricDelta("hasc"))}) catch return error.TestUnexpectedResult);
        try expectContains(desc, std.fmt.bufPrint(&base_buf, "/Descent {d} ", .{orig.toThousandths(orig.descent + try instance.metricDelta("hdsc"))}) catch return error.TestUnexpectedResult);
        try expectContains(desc, std.fmt.bufPrint(&base_buf, "/CapHeight {d} ", .{orig.toThousandths(orig.cap_height + try instance.metricDelta("cpht"))}) catch return error.TestUnexpectedResult);
    }

    fn checkTrailer(p: Parsed) !void {
        var buf: [64]u8 = undefined;
        const trailer = std.fmt.bufPrint(&buf, "trailer\n<< /Size {d} /Root 1 0 R >>\n", .{p.size}) catch return error.TestUnexpectedResult;
        try expectContains(p.bytes, trailer);
        try expectContains(try p.objectBody(1), "/Type /Catalog");
    }

    /// The widths of object `cid_obj`'s /W, in CID order from 0.
    fn widths(gpa: std.mem.Allocator, p: Parsed, cid_obj: u32) ![]i32 {
        const body = try p.objectBody(cid_obj);
        const w_mark = "/W [ 0 [";
        const w_at = std.mem.indexOf(u8, body, w_mark) orelse return error.TestUnexpectedResult;
        const w_rest = body[w_at + w_mark.len ..];
        const w_end = std.mem.indexOf(u8, w_rest, "] ]") orelse return error.TestUnexpectedResult;
        var list: std.ArrayList(i32) = .empty;
        errdefer list.deinit(gpa);
        var it = std.mem.tokenizeScalar(u8, w_rest[0..w_end], ' ');
        while (it.next()) |tok| try list.append(gpa, try std.fmt.parseInt(i32, tok, 10));
        return list.toOwnedSlice(gpa);
    }

    /// Where a reader draws each glyph of a content stream: x in thousandths
    /// of an em from the Tm origin, and the text rise in points. It follows
    /// the PDF rules for TJ (a CID moves the pen by its /W width, a number
    /// moves it back by number/1000 em) and Ts, and skips the marked-content
    /// operators zpdf writes. One BT block, one font.
    const Drawn = struct { cid: u16, x: f64, rise: f64 };

    fn drawnGlyphs(gpa: std.mem.Allocator, content: []const u8, w: []const i32) ![]Drawn {
        var list: std.ArrayList(Drawn) = .empty;
        errdefer list.deinit(gpa);
        const tm = std.mem.indexOf(u8, content, " Tm\n") orelse return error.TestUnexpectedResult;
        var rest = content[tm + " Tm\n".len ..];
        var pen: f64 = 0;
        var rise: f64 = 0;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.TestUnexpectedResult;
            const line = rest[0..nl];
            rest = rest[nl + 1 ..];
            if (std.mem.eql(u8, line, "ET")) return list.toOwnedSlice(gpa);
            if (std.mem.endsWith(u8, line, " Ts")) {
                rise = try std.fmt.parseFloat(f64, line[0 .. line.len - " Ts".len]);
            } else if (std.mem.startsWith(u8, line, "[") and std.mem.endsWith(u8, line, "] TJ")) {
                const body = line[1 .. line.len - "] TJ".len];
                var i: usize = 0;
                while (i < body.len) {
                    if (body[i] == ' ') {
                        i += 1;
                    } else if (body[i] == '<') {
                        const cid = try std.fmt.parseInt(u16, body[i + 1 .. i + 5], 16);
                        if (body[i + 5] != '>') return error.TestUnexpectedResult;
                        if (cid >= w.len) return error.TestUnexpectedResult;
                        try list.append(gpa, .{ .cid = cid, .x = pen, .rise = rise });
                        pen += @floatFromInt(w[cid]);
                        i += 6;
                    } else {
                        var j = i;
                        while (j < body.len and body[j] != ' ' and body[j] != '<') j += 1;
                        pen -= try std.fmt.parseFloat(f64, body[i..j]);
                        i = j;
                    }
                }
            } else if (!std.mem.endsWith(u8, line, " BDC") and !std.mem.eql(u8, line, "EMC")) {
                return error.TestUnexpectedResult;
            }
        }
        return error.TestUnexpectedResult;
    }

    /// The glyphs of the PDF's first page are drawn where `glyphs` (font
    /// units, `upem` per em, drawn at `size_pt`) puts them: x within the
    /// 4-decimal rounding of a TJ number, the rise exactly as printed.
    fn expectDrawnAt(gpa: std.mem.Allocator, p: Parsed, glyphs: []const [4]i32, upem: f64, size_pt: f64) !void {
        const w = try widths(gpa, p, 6);
        defer gpa.free(w);
        const drawn = try drawnGlyphs(gpa, try p.streamData(4), w);
        defer gpa.free(drawn);
        try std.testing.expectEqual(glyphs.len, drawn.len);
        var pen_x: i64 = 0;
        for (glyphs, drawn) |g, d| {
            const want_x = @as(f64, @floatFromInt(pen_x + g[2])) * 1000.0 / upem;
            try std.testing.expectApproxEqAbs(want_x, d.x, 0.0001);
            const want_rise = round4(@as(f64, @floatFromInt(g[3])) * size_pt / upem);
            try std.testing.expectEqual(want_rise, d.rise);
            pen_x += g[1];
        }
    }

    fn expectContains(hay: []const u8, needle: []const u8) !void {
        try std.testing.expect(std.mem.indexOf(u8, hay, needle) != null);
    }
};

test "e2e: office ligature in Roboto" {
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_roboto);
    defer std.testing.allocator.free(bytes);
    const pdf = try E2e.writePdf(bytes, "office", .dont_know, &.{});
    defer std.testing.allocator.free(pdf);
    var parsed = try E2e.parse(std.testing.allocator, pdf);
    defer parsed.deinit(std.testing.allocator);
    try E2e.checkIdentityH(parsed, bytes, &.{});
    try E2e.expectContains(try parsed.streamData(10), "<0002> <006600660069>");
    try E2e.expectContains(try parsed.streamData(4), "[<0001>-0.3125 <0002>0.4844 <0003>-0.4375 <0004>] TJ");
}

test "e2e: combining acute in Roboto" {
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_roboto);
    defer std.testing.allocator.free(bytes);
    const pdf = try E2e.writePdf(bytes, "e\u{0301}", .dont_know, &.{});
    defer std.testing.allocator.free(pdf);
    var parsed = try E2e.parse(std.testing.allocator, pdf);
    defer parsed.deinit(std.testing.allocator);
    try E2e.checkIdentityH(parsed, bytes, &.{});
    try E2e.expectContains(try parsed.streamData(10), "<0001> <00650301>");
}

test "e2e: Devanagari ki kssa" {
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_noto_devanagari);
    defer std.testing.allocator.free(bytes);
    const pdf = try E2e.writePdf(bytes, "कि क्ष", .ltr, &.{});
    defer std.testing.allocator.free(pdf);
    var parsed = try E2e.parse(std.testing.allocator, pdf);
    defer parsed.deinit(std.testing.allocator);
    try E2e.checkIdentityH(parsed, bytes, &.{});
    try E2e.expectContains(try parsed.streamData(4), "/ActualText <FEFF0915093F>");
    try E2e.expectContains(try parsed.streamData(10), "<0001> <093F>");
    try E2e.expectContains(try parsed.streamData(10), "<0002> <0915>");
    try E2e.expectContains(try parsed.streamData(10), "<0004> <0915094D0937>");
}

test "e2e: Arabic bismillah" {
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_amiri);
    defer std.testing.allocator.free(bytes);
    const pdf = try E2e.writePdf(bytes, "بسم الله", .rtl, &.{});
    defer std.testing.allocator.free(pdf);
    var parsed = try E2e.parse(std.testing.allocator, pdf);
    defer parsed.deinit(std.testing.allocator);
    try E2e.checkIdentityH(parsed, bytes, &.{});
    const contents = try parsed.streamData(4);
    try std.testing.expect(std.mem.indexOf(u8, contents, "/ActualText") == null);
    try E2e.expectContains(try parsed.streamData(10), "<0001> <0647>");
    try E2e.expectContains(try parsed.streamData(10), "<0008> <0628>");
}

test "e2e: Hebrew shalom olam" {
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_noto_hebrew);
    defer std.testing.allocator.free(bytes);
    const pdf = try E2e.writePdf(bytes, "שלום עולם", .rtl, &.{});
    defer std.testing.allocator.free(pdf);
    var parsed = try E2e.parse(std.testing.allocator, pdf);
    defer parsed.deinit(std.testing.allocator);
    try E2e.checkIdentityH(parsed, bytes, &.{});
    const contents = try parsed.streamData(4);
    try std.testing.expect(std.mem.indexOf(u8, contents, "/ActualText") == null);
    try E2e.expectContains(try parsed.streamData(10), "<0001> <05DD>");
    try E2e.expectContains(try parsed.streamData(10), "<0006> <05E9>");
}

test "e2e: hello space shalom on one line" {
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_noto_hebrew);
    defer std.testing.allocator.free(bytes);
    const pdf = try E2e.writePdf(bytes, "hello שלום", .dont_know, &.{});
    defer std.testing.allocator.free(pdf);
    var parsed = try E2e.parse(std.testing.allocator, pdf);
    defer parsed.deinit(std.testing.allocator);
    try E2e.checkIdentityH(parsed, bytes, &.{});
    const contents = try parsed.streamData(4);
    try E2e.expectContains(contents, "<0001><0002><0003><0003><0004><0005><0006><0007><0008><0009>");
    try std.testing.expect(std.mem.indexOf(u8, contents, "/ActualText") == null);
    try E2e.expectContains(try parsed.streamData(10), "<0001> <0068>");
    try E2e.expectContains(try parsed.streamData(10), "<0009> <05E9>");
}

test "e2e: AVA kerning uses positive TJ adjustments against absolute origin" {
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_roboto);
    defer std.testing.allocator.free(bytes);
    const pdf = try E2e.writePdf(bytes, "AVA", .dont_know, &.{});
    defer std.testing.allocator.free(pdf);
    var parsed = try E2e.parse(std.testing.allocator, pdf);
    defer parsed.deinit(std.testing.allocator);
    try E2e.checkIdentityH(parsed, bytes, &.{});
    try E2e.expectContains(try parsed.streamData(4), "[<0001>42.1367 <0002>36.3906 <0001>] TJ");
}

test "e2e: Ts then 0 Ts for a non-zero offset_y" {
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_amiri);
    defer std.testing.allocator.free(bytes);
    const pdf = try E2e.writePdf(bytes, "بٔ", .rtl, &.{});
    defer std.testing.allocator.free(pdf);
    var parsed = try E2e.parse(std.testing.allocator, pdf);
    defer parsed.deinit(std.testing.allocator);
    try E2e.checkIdentityH(parsed, bytes, &.{});
    const contents = try parsed.streamData(4);
    try E2e.expectContains(contents, "8.088 Ts\n[-461 <0001>] TJ\n0 Ts\n[461 <0002>] TJ");
}

test "e2e: one GID with two CIDs in CMap and CIDToGIDMap" {
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_latin);
    defer std.testing.allocator.free(bytes);
    const pdf = try E2e.writePdf(bytes, "b\u{200C}b", .dont_know, &.{});
    defer std.testing.allocator.free(pdf);
    var parsed = try E2e.parse(std.testing.allocator, pdf);
    defer parsed.deinit(std.testing.allocator);
    try E2e.checkIdentityH(parsed, bytes, &.{});
    try E2e.expectContains(try parsed.streamData(10), "<0001> <0062200C>");
    try E2e.expectContains(try parsed.streamData(10), "<0002> <0062>");
    const map = try parsed.streamData(9);
    try std.testing.expectEqual(try E2e.gidForCid(map, 1), try E2e.gidForCid(map, 2));
}

test "long line TJ positions are absolute" {
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_roboto);
    defer std.testing.allocator.free(bytes);
    const text = av_200;
    const pdf = try E2e.writePdf(bytes, text, .dont_know, &.{});
    defer std.testing.allocator.free(pdf);
    var parsed = try E2e.parse(std.testing.allocator, pdf);
    defer parsed.deinit(std.testing.allocator);

    var font = try zpdf.Font.init(std.testing.allocator, bytes, 0, &.{});
    defer font.deinit();
    var shaped = try zpdf.shape(std.testing.allocator, &font, text, .{});
    defer shaped.deinit(std.testing.allocator);
    const face = try sfnt.open(bytes, 0);
    const upem: f64 = @floatFromInt(face.units_per_em);

    const contents = try parsed.streamData(4);
    const brack = std.mem.indexOf(u8, contents, "[") orelse return error.TestUnexpectedResult;
    const tj = std.mem.indexOf(u8, contents[brack..], "] TJ") orelse return error.TestUnexpectedResult;
    const body = contents[brack + 1 .. brack + tj];

    var pdf_pen: f64 = 0;
    var gi: usize = 0;
    var i: usize = 0;
    var pen_x: i64 = 0;
    while (i < body.len) {
        while (i < body.len and body[i] == ' ') i += 1;
        if (i >= body.len) break;
        if (body[i] == '<') {
            const gt = std.mem.indexOfScalar(u8, body[i..], '>') orelse return error.TestUnexpectedResult;
            if (gi >= shaped.glyphs.len) return error.TestUnexpectedResult;
            const glyph = shaped.glyphs[gi];
            const wanted = @as(f64, @floatFromInt(pen_x + glyph.offset_x)) * 1000.0 / upem;
            try std.testing.expectApproxEqAbs(wanted, pdf_pen, 0.0001);
            const w_val = face.toThousandths(@intCast(try sfnt.glyphAdvance(face, glyph.id)));
            pdf_pen += @floatFromInt(w_val);
            pen_x += glyph.advance_x;
            gi += 1;
            i += gt + 1;
        } else {
            var j = i;
            if (body[j] == '-') j += 1;
            while (j < body.len and (std.ascii.isDigit(body[j]) or body[j] == '.')) j += 1;
            const adj = try std.fmt.parseFloat(f64, body[i..j]);
            pdf_pen -= adj;
            i = j;
        }
    }
    try std.testing.expectEqual(shaped.glyphs.len, gi);
}

test "e2e: same document twice is the same bytes" {
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_roboto);
    defer std.testing.allocator.free(bytes);
    const a = try E2e.writePdf(bytes, "office", .dont_know, &.{});
    defer std.testing.allocator.free(a);
    const b = try E2e.writePdf(bytes, "office", .dont_know, &.{});
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
}

test "e2e: CFF addFont is UnsupportedFontFormat" {
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_cff);
    defer std.testing.allocator.free(bytes);
    // kb shapes CFF, so the Font loads; the PDF writer embeds only TrueType.
    var font = try zpdf.Font.init(std.testing.allocator, bytes, 0, &.{});
    defer font.deinit();
    var td_doc: TestDoc = undefined;
    try td_doc.init(std.testing.allocator, true);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    try std.testing.expectError(error.UnsupportedFontFormat, doc.addFont(&font));
}

test "an instanced subset's hmtx is kb's advance, the /W source, for every glyph" {
    // fontDescription is what finish embeds. Every glyph of each oracle font is
    // embedded, at each oracle instance; for a font with HVAR the advance is
    // kb's, without HVAR the phantom points' (which the no-HVAR drift test
    // checks against kb). Either way it must equal glyphWidth's source.
    const gpa = std.testing.allocator;
    inline for (instancer.oracle_cases) |case| {
        var font = try instancer.loadInstance(gpa, instancer.oracleFontPath(case.font), case.variations);
        defer font.deinit();
        const face = try sfnt.open(font.bytes, 0);
        const seed = try gpa.alloc(u16, face.num_glyphs);
        defer gpa.free(seed);
        for (seed, 0..) |*s, i| s.* = @intCast(i);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const desc = try fontDescription(arena.allocator(), face, &font, seed);
        const sub = try sfnt.open(desc.subset, 0);
        var gid: u16 = 0;
        while (gid < face.num_glyphs) : (gid += 1) {
            try std.testing.expectEqual(font.glyphAdvanceX(gid), @as(i32, try sfnt.glyphAdvance(sub, gid)));
        }
    }
}

test "an instance's FontDescriptor metrics take kb's MVAR deltas" {
    // playwrite_mm.subset.ttf's MVAR varies hasc, hdsc and cpht. The deltas
    // are fontTools' instancer's (fontTools 4.67.0, instantiateVariableFont):
    // default OS/2 typo 1275/-375, cap 875, hhea 1275/-375; YEXT=1000 gives
    // 2040/-1020, cap 1500, hhea 2040/-1020; YEXT=700,slnt=18 gives
    // 1673/-710, cap 1200.
    const gpa = std.testing.allocator;
    const Case = struct { variations: []const u8, hasc: i32, hdsc: i32, cpht: i32 };
    const cases = [_]Case{
        .{ .variations = "YEXT=1000", .hasc = 765, .hdsc = -645, .cpht = 625 },
        .{ .variations = "YEXT=700,slnt=18", .hasc = 398, .hdsc = -335, .cpht = 325 },
        .{ .variations = "", .hasc = 0, .hdsc = 0, .cpht = 0 },
    };
    for (cases) |case| {
        var font = try instancer.loadInstance(gpa, @import("build_options").test_font_playwrite, case.variations);
        defer font.deinit();
        try std.testing.expectEqual(case.hasc, try font.metricDelta("hasc"));
        try std.testing.expectEqual(case.hdsc, try font.metricDelta("hdsc"));
        try std.testing.expectEqual(case.cpht, try font.metricDelta("cpht"));
        const face = try sfnt.open(font.bytes, 0);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const desc = try fontDescription(arena.allocator(), face, &font, &.{});
        try std.testing.expectEqual(@as(i32, face.ascent) + case.hasc, desc.ascent);
        try std.testing.expectEqual(@as(i32, face.descent) + case.hdsc, desc.descent);
        try std.testing.expectEqual(@as(i32, face.cap_height) + case.cpht, desc.cap_height);
    }
    // A font whose MVAR has none of the three tags (Noto Sans VF: stro, xhgt).
    var noto = try instancer.loadInstance(gpa, @import("build_options").test_font_noto_sans_vf, "wght=900");
    defer noto.deinit();
    try std.testing.expectEqual(0, try noto.metricDelta("hasc"));
    try std.testing.expectEqual(0, try noto.metricDelta("cpht"));
    // No MVAR at all (Fraunces): kb returns the static cap height at both
    // vectors, and the delta is still 0.
    var fraunces = try instancer.loadInstance(gpa, @import("build_options").test_font_variable, "wght=100");
    defer fraunces.deinit();
    try std.testing.expectEqual(0, try fraunces.metricDelta("cpht"));
    try std.testing.expectEqual(0, try fraunces.metricDelta("hasc"));
}

test "e2e: a variable font at an instance: /W from kb, glyphs drawn where HarfBuzz puts them" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const Case = struct {
        path: []const u8,
        text: []const u8,
        variations: []const zpdf.Variation,
        /// id, x_advance, x_offset, y_offset: HarfBuzz's output for the line.
        hb: []const [4]i32,
    };
    const cases = [_]Case{
        // HVAR, avar, ligatures. cd harfbuzz/test && hb-shape --no-glyph-names --variations=opsz=144,wght=100 subset/data/fonts/Fraunces.ttf --unicodes=U+0066,U+006C,U+0075,U+0066,U+0066,U+0079,U+0020,U+006F,U+0066,U+0066,U+0069,U+0063,U+0065
        // [477=0+803|54=2+903|475=3+868|58=5+811|1=6+350|47=7+914|478=8+1237|31=11+737|33=12+751]
        .{ .path = options.test_font_variable, .text = "fluffy office", .variations = &.{ .{ .tag = "opsz".*, .value = 144 }, .{ .tag = "wght".*, .value = 100 } }, .hb = &.{ .{ 477, 803, 0, 0 }, .{ 54, 903, 0, 0 }, .{ 475, 868, 0, 0 }, .{ 58, 811, 0, 0 }, .{ 1, 350, 0, 0 }, .{ 47, 914, 0, 0 }, .{ 478, 1237, 0, 0 }, .{ 31, 737, 0, 0 }, .{ 33, 751, 0, 0 } } },
        // HVAR, 13 axes. cd harfbuzz/test && hb-shape --no-glyph-names --variations=wght=650,opsz=36 subset/data/fonts/RobotoFlex-Variable.ttf --unicodes=U+006F,U+0066,U+0066,U+0069,U+0063,U+0065,U+0020,U+006D,U+0069,U+006E,U+0069,U+006D,U+0075,U+006D
        // [82=0+1157|555=1+1790|70=4+1078|72=5+1084|3=6+480|80=7+1753|76=8+523|81=9+1142|76=10+523|80=11+1753|88=12+1141|80=13+1753]
        .{ .path = options.test_font_roboto_flex, .text = "office minimum", .variations = &.{ .{ .tag = "wght".*, .value = 650 }, .{ .tag = "opsz".*, .value = 36 } }, .hb = &.{ .{ 82, 1157, 0, 0 }, .{ 555, 1790, 0, 0 }, .{ 70, 1078, 0, 0 }, .{ 72, 1084, 0, 0 }, .{ 3, 480, 0, 0 }, .{ 80, 1753, 0, 0 }, .{ 76, 523, 0, 0 }, .{ 81, 1142, 0, 0 }, .{ 76, 523, 0, 0 }, .{ 80, 1753, 0, 0 }, .{ 88, 1141, 0, 0 }, .{ 80, 1753, 0, 0 } } },
        // gvar phantom points (no HVAR), a mark with varied x and y offsets.
        // cd harfbuzz/test && hb-shape --no-glyph-names --variations=wght=900,wdth=70 shape/data/text-rendering-tests/fonts/TestGPOSFour.ttf --unicodes=U+0634,U+0652
        // [12=0@614,389+0|5=0+1242]
        .{ .path = options.test_font_gpos_four, .text = "\u{0634}\u{0652}", .variations = &.{ .{ .tag = "wght".*, .value = 900 }, .{ .tag = "wdth".*, .value = 70 } }, .hb = &.{ .{ 12, 0, 614, 389 }, .{ 5, 1242, 0, 0 } } },
    };
    inline for (cases) |case| {
        const bytes = try E2e.load(case.path);
        defer gpa.free(bytes);
        const pdf = try E2e.writePdf(bytes, case.text, .dont_know, case.variations);
        defer gpa.free(pdf);
        var parsed = try E2e.parse(gpa, pdf);
        defer parsed.deinit(gpa);
        try E2e.checkIdentityH(parsed, bytes, case.variations);
        const face = try sfnt.open(bytes, 0);
        try E2e.expectDrawnAt(gpa, parsed, case.hb, @floatFromInt(face.units_per_em), 24);
    }
}

test "e2e: TJ positions of static fonts reproduce the shaped glyphs, read through /W" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const Case = struct { path: []const u8, text: []const u8, direction: zpdf.Direction };
    // Kerning, marks with offsets (Ts), RTL, and a long line.
    const cases = [_]Case{
        .{ .path = options.test_font_roboto, .text = "AVATAR office Tolkien", .direction = .dont_know },
        .{ .path = options.test_font_amiri, .text = "\u{0628}\u{0654}", .direction = .rtl },
        .{ .path = options.test_font_noto_devanagari, .text = "\u{0915}\u{093F} \u{0915}\u{094D}\u{0937}", .direction = .ltr },
        .{ .path = options.test_font_roboto, .text = av_200, .direction = .dont_know },
    };
    inline for (cases) |case| {
        const bytes = try E2e.load(case.path);
        defer gpa.free(bytes);
        const pdf = try E2e.writePdf(bytes, case.text, case.direction, &.{});
        defer gpa.free(pdf);
        var parsed = try E2e.parse(gpa, pdf);
        defer parsed.deinit(gpa);
        var font = try zpdf.Font.init(gpa, bytes, 0, &.{});
        defer font.deinit();
        var shaped = try zpdf.shape(gpa, &font, case.text, .{ .paragraph_direction = case.direction });
        defer shaped.deinit(gpa);
        const glyphs = try gpa.alloc([4]i32, shaped.glyphs.len);
        defer gpa.free(glyphs);
        for (glyphs, shaped.glyphs) |*g, s| g.* = .{ s.id, s.advance_x, s.offset_x, s.offset_y };
        const face = try sfnt.open(bytes, 0);
        try E2e.expectDrawnAt(gpa, parsed, glyphs, @floatFromInt(face.units_per_em), 24);
    }
}

test "e2e: one file at two instances is two fonts with their own prefix and widths" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const bytes = try E2e.load(options.test_font_noto_sans_vf);
    defer gpa.free(bytes);
    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, true);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    var regular_font = try zpdf.Font.init(gpa, bytes, 0, &.{});
    defer regular_font.deinit();
    const regular = try doc.addFont(&regular_font);
    var black_font = try zpdf.Font.init(gpa, bytes, 0, &.{.{ .tag = "wght".*, .value = 900 }});
    defer black_font.deinit();
    const black = try doc.addFont(&black_font);
    try std.testing.expect(regular != black);
    const page = try doc.beginPage(612, 792);
    try doc.drawText(page, regular, 24, 72, 720, .black, "abc", .{});
    try doc.drawText(page, black, 24, 72, 680, .black, "abc", .{});
    const pdf = try td_doc.finishOwned(gpa);
    defer gpa.free(pdf);
    var parsed = try E2e.parse(gpa, pdf);
    defer parsed.deinit(gpa);
    // Page 3, contents 4, then six objects per font: 5..10 and 11..16.
    const base_a = try parsed.objectBody(5);
    const base_b = try parsed.objectBody(11);
    const at_a = std.mem.indexOf(u8, base_a, "/BaseFont /") orelse return error.TestUnexpectedResult;
    const at_b = std.mem.indexOf(u8, base_b, "/BaseFont /") orelse return error.TestUnexpectedResult;
    const prefix_a = base_a[at_a + "/BaseFont /".len ..][0..7];
    const prefix_b = base_b[at_b + "/BaseFont /".len ..][0..7];
    try std.testing.expect(prefix_a[6] == '+' and prefix_b[6] == '+');
    // The same glyphs are used, so only the instance tells the two apart.
    try std.testing.expect(!std.mem.eql(u8, prefix_a, prefix_b));
    const w_a = try E2e.widths(gpa, parsed, 6);
    defer gpa.free(w_a);
    const w_b = try E2e.widths(gpa, parsed, 12);
    defer gpa.free(w_b);
    // hb-shape --no-glyph-names --features=-kern --variations=wght=900 subset/data/fonts/NotoSans-VF.abc.ttf --unicodes=U+0061,U+0062,U+0063
    // [1=0+623|2=1+643|3=2+539], and with no variations [1=0+561|2=1+615|3=2+480]; 1000 units per em.
    try std.testing.expectEqualSlices(i32, &.{ w_a[0], 561, 615, 480 }, w_a);
    try std.testing.expectEqualSlices(i32, &.{ w_b[0], 623, 643, 539 }, w_b);
}

test "RTL ActualText spans are written when appended in logical (reverse kb) order" {
    // Spans in logical order: kb 2..4 first, then kb 0..2. A cursor that only
    // advances would emit the second span and drop the first.
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_latin);
    defer std.testing.allocator.free(bytes);
    const face = try sfnt.open(bytes, 0);
    var font = try zpdf.Font.init(std.testing.allocator, bytes, 0, &.{});
    defer font.deinit();

    const gpa = std.testing.allocator;
    const glyphs = try gpa.dupe(zpdf.Glyph, &.{
        .{ .id = 1, ._reserved0 = 0, .cluster = 2, .advance_x = 500, .advance_y = 0, .offset_x = 0, .offset_y = 0 },
        .{ .id = 1, ._reserved0 = 0, .cluster = 2, .advance_x = 500, .advance_y = 0, .offset_x = 0, .offset_y = 0 },
        .{ .id = 1, ._reserved0 = 0, .cluster = 0, .advance_x = 500, .advance_y = 0, .offset_x = 0, .offset_y = 0 },
        .{ .id = 1, ._reserved0 = 0, .cluster = 0, .advance_x = 500, .advance_y = 0, .offset_x = 0, .offset_y = 0 },
    });
    defer gpa.free(glyphs);
    const cids = try gpa.dupe(u16, &.{ 1, 2, 3, 4 });
    defer gpa.free(cids);
    const t0 = try gpa.dupe(u21, &.{ 'c', 'd' });
    const t1 = try gpa.dupe(u21, &.{ 'a', 'b' });
    const spans = try gpa.dupe(text_map.ActualTextSpan, &.{
        .{ .start = 2, .end = 4, .text = t0 },
        .{ .start = 0, .end = 2, .text = t1 },
    });
    defer {
        gpa.free(t0);
        gpa.free(t1);
        gpa.free(spans);
    }
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeShaped(scratch.allocator(), &aw.writer, glyphs, .{ .cids = cids, .spans = spans }, face, &font, 24);
    const out = aw.written();
    try E2e.expectContains(out, "/ActualText <FEFF00610062>");
    try E2e.expectContains(out, "/ActualText <FEFF00630064>");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, " BDC\n"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "EMC\n"));
}

test "every allocation failure in building and writing a document is OutOfMemory or changes nothing" {
    const fonts = try loadThreeFonts();
    defer for (fonts) |f| std.testing.allocator.free(f);
    // Three documents, because they fail in different places. The long one runs with every
    // in-place resize refused, so each growing buffer takes its allocating path.
    //
    // Under Zig 0.16, one injected failure in the one-word document landed on write_scratch's
    // reset, whose allocating fallback fails without changing the output, and this test required
    // that. Under 0.17 none does (measured: one-word 37 failed, 0 unchanged; long page with
    // resizes refused 83 failed, 0 unchanged), and the cause was not found. zpdf has no code on
    // that path: it discards reset's result, which ArenaAllocator.reset documents as leaving
    // the arena fully usable. So a run that succeeds after a failure is still checked for the
    // same bytes, but no longer required to occur.
    const one_word = try checkWriteAllocationFailures(&fonts, buildOneWordDoc, false);
    const images = try checkWriteAllocationFailures(&fonts, buildImageDoc, true);
    try std.testing.expect(images.failed > 10);
    const two_page = try checkWriteAllocationFailures(&fonts, buildTwoPageDoc, false);
    const long_page = try checkWriteAllocationFailures(&fonts, buildLongPageDoc, true);
    try std.testing.expect(one_word.failed > 20);
    try std.testing.expect(two_page.failed > 50);
    try std.testing.expect(long_page.failed > 50);
}

/// A page of 60 lines, then a second page.
fn buildLongPageDoc(doc: *Document, fonts: *[3]zpdf.Font) !void {
    const font = try doc.addFont(&fonts[1]);
    const first = try doc.beginPage(612, 792);
    var line: [48]u8 = undefined;
    for (0..60) |i| try doc.drawText(first, font, 10, 36, 770 - @as(f64, @floatFromInt(i)) * 12, .black, try std.fmt.bufPrint(&line, "line {d} office AVA", .{i}), .{});
    try doc.endPage(first);
    const second = try doc.beginPage(612, 792);
    try doc.drawText(second, font, 10, 36, 770, .black, "end", .{});
}

/// An RGBA PNG (an image and its soft mask), a JPEG, both drawn on one page, the PNG twice.
fn buildImageDoc(doc: *Document, fonts: *[3]zpdf.Font) !void {
    _ = fonts;
    const gpa = std.testing.allocator;
    const png = try loadTestImage(gpa, "pngsuite/basn6a08.png");
    defer gpa.free(png);
    const jpeg = try loadTestImage(gpa, "exif/orient-6.jpg");
    defer gpa.free(jpeg);
    const a = try doc.addImage(png);
    const b = try doc.addImage(jpeg);
    const page = try doc.beginPage(612, 792);
    try doc.drawImage(page, a, 10, 10, 32, 32);
    try doc.drawImage(page, b, 50, 10, 32, 16);
    try doc.drawImage(page, a, 90, 10, 64, 64);
}

/// A file under tests/images, owned by `gpa`.
fn loadTestImage(gpa: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    const options = @import("build_options");
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, options.image_fixtures, .{});
    defer dir.close(std.testing.io);
    return dir.readFileAlloc(std.testing.io, sub_path, gpa, .limited(1 << 20));
}

fn buildOneWordDoc(doc: *Document, fonts: *[3]zpdf.Font) !void {
    const font = try doc.addFont(&fonts[0]);
    const page = try doc.beginPage(612, 792);
    try doc.drawText(page, font, 24, 72, 720, .black, "a", .{});
}

/// Fails allocation i of the document's allocator, for every i until a run
/// has no failure. Each run must end in OutOfMemory, or succeed and write
/// exactly the bytes of a run with no failure.
///
/// std.testing.checkAllAllocationFailures does not fit: endPage and finish
/// reset write_scratch with .retain_capacity, and when that reset cannot allocate
/// the combined block it falls back to an empty arena and returns false.
/// checkAll calls that a swallowed failure, but the output does not change.
///
/// `refuse_resizes`: every in-place resize fails, so each growing buffer takes the path that
/// allocates a new block and copies.
fn checkWriteAllocationFailures(
    fonts: *const [3][]const u8,
    comptime build: fn (*Document, *[3]zpdf.Font) anyerror!void,
    refuse_resizes: bool,
) !struct { failed: usize, unchanged: usize } {
    const gpa = std.testing.allocator;
    const Scenario = struct {
        /// Returns the written PDF, owned by the test allocator.
        fn run(allocator: std.mem.Allocator, font_bytes: *const [3][]const u8) ![]u8 {
            var loaded = try initThreeFonts(allocator, font_bytes);
            defer deinitThreeFonts(&loaded);
            // The sink takes memory from the real test allocator and never
            // fails, so a WriteFailed here is an allocation failure that a
            // write reported as a sink failure.
            var sink: Trickle = .{ .gpa = std.testing.allocator };
            errdefer sink.taken.deinit(std.testing.allocator);
            var doc = try Document.begin(allocator, &sink.writer, .{ .compress = true });
            defer doc.deinit();
            // Rollback after a failed drawText is checked by the "leaves no
            // trace" tests; here only the error matters.
            try build(&doc, &loaded);
            if (doc.open) |open| try doc.endPage(open.id);
            try doc.finish();
            return sink.taken.toOwnedSlice(std.testing.allocator);
        }
    };
    const reference = try Scenario.run(gpa, fonts);
    defer gpa.free(reference);

    var failed: usize = 0;
    var unchanged: usize = 0;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(gpa, .{
            .fail_index = fail_index,
            .resize_fail_index = if (refuse_resizes) 0 else std.math.maxInt(usize),
        });
        if (Scenario.run(failing.allocator(), fonts)) |pdf| {
            defer gpa.free(pdf);
            try std.testing.expectEqualSlices(u8, reference, pdf);
            if (!failing.has_induced_failure) break;
            unchanged += 1;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failed += 1;
        }
    }
    return .{ .failed = failed, .unchanged = unchanged };
}

fn usedBitsEqual(a: std.DynamicBitSet, b: std.DynamicBitSet) bool {
    if (a.capacity() != b.capacity()) return false;
    var i: usize = 0;
    while (i < a.capacity()) : (i += 1) {
        if (a.isSet(i) != b.isSet(i)) return false;
    }
    return true;
}

const FailPoint = enum { gpa, scratch, cache };

fn printableAscii() [94]u8 {
    var text: [94]u8 = undefined;
    for (&text, 0..) |*ch, i| ch.* = @intCast(0x21 + i);
    return text;
}

/// Tests: a Document writing into memory. Init in place (the Document points at `aw`).
const TestDoc = struct {
    aw: std.Io.Writer.Allocating,
    doc: Document,

    fn init(self: *TestDoc, gpa: std.mem.Allocator, compress: bool) !void {
        self.aw = .init(gpa);
        errdefer self.aw.deinit();
        self.doc = try Document.begin(gpa, &self.aw.writer, .{ .compress = compress });
    }

    fn deinit(self: *TestDoc) void {
        self.doc.deinit();
        self.aw.deinit();
    }

    /// Ends the open page, if any, finishes, and returns a copy of the PDF.
    fn finishOwned(self: *TestDoc, gpa: std.mem.Allocator) ![]u8 {
        if (self.doc.open) |open| try self.doc.endPage(open.id);
        try self.doc.finish();
        return gpa.dupe(u8, self.aw.written());
    }
};

/// A second drawText fails at allocation i of one allocator, for every i until
/// it succeeds. After each failure the document must be exactly as the first
/// drawText left it (bits, CIDs, ops), and must then finish with the bytes of
/// a clean one-call document, or, with the same drawText run again, of a
/// clean two-call document. A finished document takes no more drawing, so each
/// failure index runs twice, once for each ending.
fn checkFailedDrawTextLeavesNoTrace(point: FailPoint) !void {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const bytes = try E2e.load(options.test_font_roboto);
    defer gpa.free(bytes);
    const text = printableAscii();

    var wants: [2][]u8 = undefined;
    for (&wants, 1..) |*want, calls| {
        var td_doc: TestDoc = undefined;
        try td_doc.init(gpa, true);
        defer td_doc.deinit();
        const doc = &td_doc.doc;
        var loaded_font = try zpdf.Font.init(gpa, bytes, 0, &.{});
        defer loaded_font.deinit();
        const font = try doc.addFont(&loaded_font);
        const page = try doc.beginPage(612, 792);
        try doc.drawText(page, font, 24, 72, 720, .black, "a", .{});
        if (calls == 2) {
            try doc.drawText(page, font, 12, 72, 680, .black, &text, .{});
            try std.testing.expect(doc.fonts.items[@backingInt(font)].embedded.used.count() > 64);
        }
        want.* = try td_doc.finishOwned(gpa);
    }
    defer for (wants) |w| gpa.free(w);

    var n_failed: usize = 0;
    var i: usize = 0;
    outer: while (true) : (i += 1) {
        for (wants, 1..) |want, calls| {
            var gpa_failing = std.testing.FailingAllocator.init(gpa, .{});
            var td_doc: TestDoc = undefined;
            try td_doc.init(gpa_failing.allocator(), true);
            defer td_doc.deinit();
            const doc = &td_doc.doc;
            var loaded_font = try zpdf.Font.init(gpa_failing.allocator(), bytes, 0, &.{});
            defer loaded_font.deinit();
            const font = try doc.addFont(&loaded_font);
            const page = try doc.beginPage(612, 792);
            try doc.drawText(page, font, 24, 72, 720, .black, "a", .{});

            var failing = std.testing.FailingAllocator.init(switch (point) {
                .gpa => gpa,
                .scratch => doc.scratch.allocator(),
                .cache => doc.cache_arena.allocator(),
            }, .{});
            switch (point) {
                .gpa => {},
                .scratch => doc.scratch_allocator = failing.allocator(),
                .cache => doc.cache_allocator = failing.allocator(),
            }
            const fa = if (point == .gpa) &gpa_failing else &failing;
            fa.fail_index = fa.alloc_index + i;

            const df = &doc.fonts.items[@backingInt(font)].embedded;
            var used_before = try df.used.clone(gpa);
            defer used_before.deinit();
            const cids_before = df.cids.count();
            const shapes_before = df.shapes.count();
            const ops_before = doc.open.?.ops.items.len;

            if (doc.drawText(page, font, 12, 72, 680, .black, &text, .{})) |_| {
                try std.testing.expect(!fa.has_induced_failure);
                break :outer;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expect(fa.has_induced_failure);
                if (calls == 1) n_failed += 1;
            }
            fa.fail_index = std.math.maxInt(usize);
            try std.testing.expect(usedBitsEqual(df.used, used_before));
            try std.testing.expectEqual(cids_before, df.cids.count());
            try std.testing.expectEqual(shapes_before, df.shapes.count());
            try std.testing.expectEqual(ops_before, doc.open.?.ops.items.len);
            if (calls == 2) try doc.drawText(page, font, 12, 72, 680, .black, &text, .{});
            const got = try td_doc.finishOwned(gpa);
            defer gpa.free(got);
            try std.testing.expectEqualSlices(u8, want, got);
        }
    }
    try std.testing.expect(n_failed > 0);
}

test "a failed drawText leaves no trace, at every gpa allocation" {
    try checkFailedDrawTextLeavesNoTrace(.gpa);
}

test "a failed drawText leaves no trace, at every scratch allocation" {
    try checkFailedDrawTextLeavesNoTrace(.scratch);
}

test "a failed drawText leaves no trace, at every cache arena allocation" {
    try checkFailedDrawTextLeavesNoTrace(.cache);
}

test "a drawText that cannot grow the page's op list leaves no trace, on a cache hit and a miss" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const bytes = try E2e.load(options.test_font_roboto);
    defer gpa.free(bytes);
    var loaded_font = try zpdf.Font.init(gpa, bytes, 0, &.{});
    defer loaded_font.deinit();
    for ([_][]const u8{ "hit", "miss" }) |text| {
        var td_doc: TestDoc = undefined;
        try td_doc.init(gpa, true);
        defer td_doc.deinit();
        const doc = &td_doc.doc;
        const font = try doc.addFont(&loaded_font);
        const page = try doc.beginPage(612, 792);
        try doc.drawText(page, font, 12, 72, 700, .black, "hit", .{});
        const ops = &doc.open.?.ops;
        while (ops.items.len < ops.capacity) try doc.drawText(page, font, 12, 72, 700, .black, "hit", .{});
        const df = &doc.fonts.items[@backingInt(font)].embedded;
        const n_ops = ops.items.len;
        const n_cids = df.cids.count();
        const n_shapes = df.shapes.count();

        var failing: std.testing.FailingAllocator = .init(doc.page_arena.allocator(), .{ .fail_index = 0 });
        doc.page_allocator = failing.allocator();
        try std.testing.expectError(error.OutOfMemory, doc.drawText(page, font, 12, 72, 700, .black, text, .{}));
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(n_ops, ops.items.len);
        try std.testing.expectEqual(n_cids, df.cids.count());
        try std.testing.expectEqual(n_shapes, df.shapes.count());
        doc.page_allocator = null;
        try doc.drawText(page, font, 12, 72, 700, .black, text, .{});
        try std.testing.expectEqual(n_ops + 1, ops.items.len);
    }
}

/// Fills memory with 0xAA before freeing it, so a read through a stale pointer
/// sees junk even where the test allocator keeps a small block mapped.
const PoisonOnFree = struct {
    child: std.mem.Allocator,

    fn allocator(self: *PoisonOnFree) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *PoisonOnFree = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *PoisonOnFree = @ptrCast(@alignCast(ctx));
        if (new_len < memory.len) @memset(memory[new_len..], 0xAA);
        return self.child.rawResize(memory, alignment, new_len, ra);
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        // Refuse, so a move always goes through alloc + free and the old
        // bytes are poisoned.
        return null;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *PoisonOnFree = @ptrCast(@alignCast(ctx));
        @memset(memory, 0xAA);
        self.child.rawFree(memory, alignment, ra);
    }
};

test "an op's data survives later drawTexts and a freed scratch" {
    const options = @import("build_options");
    var poison: PoisonOnFree = .{ .child = std.testing.allocator };
    const gpa = poison.allocator();
    const bytes = try E2e.load(options.test_font_noto_devanagari);
    defer gpa.free(bytes);
    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, true);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    var loaded_font = try zpdf.Font.init(gpa, bytes, 0, &.{});
    defer loaded_font.deinit();
    const font = try doc.addFont(&loaded_font);
    const page = try doc.beginPage(612, 792);
    // In "कि" the vowel sign is drawn before the consonant, so the op needs an
    // ActualText span as well as glyphs and CIDs.
    try doc.drawText(page, font, 24, 72, 720, .black, "\u{0915}\u{093F} \u{0915}\u{094D}\u{0937}", .{});
    const op = doc.open.?.ops.items[0];
    try std.testing.expect(op.text.text.shaped.mapping.spans.len > 0);
    const glyphs = try gpa.dupe(zpdf.Glyph, op.text.text.shaped.glyphs);
    defer gpa.free(glyphs);
    const cids = try gpa.dupe(u16, op.text.text.shaped.mapping.cids);
    defer gpa.free(cids);
    const span_text = try gpa.dupe(u21, op.text.text.shaped.mapping.spans[0].text);
    defer gpa.free(span_text);

    const more = printableAscii();
    for (0..3) |_| try doc.drawText(page, font, 12, 72, 600, .black, &more, .{});

    // Later drawTexts may not reuse the block an op's data would sit in if it
    // pointed into scratch, so a stale pointer can read correct bytes. Free
    // scratch outright: the test allocator then unmaps or poisons it, and a
    // stale read crashes or differs, here or when endPage writes the op.
    _ = doc.scratch.reset(.free_all);
    const op_after = doc.open.?.ops.items[0];
    try std.testing.expectEqualSlices(zpdf.Glyph, glyphs, op_after.text.text.shaped.glyphs);
    try std.testing.expectEqualSlices(u16, cids, op_after.text.text.shaped.mapping.cids);
    try std.testing.expectEqualSlices(u21, span_text, op_after.text.text.shaped.mapping.spans[0].text);
    gpa.free(try td_doc.finishOwned(gpa));
}

test "scratch does not grow when the same text is drawn again" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const bytes = try E2e.load(options.test_font_roboto);
    defer gpa.free(bytes);
    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, true);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    var loaded_font = try zpdf.Font.init(gpa, bytes, 0, &.{});
    defer loaded_font.deinit();
    const font = try doc.addFont(&loaded_font);
    const page = try doc.beginPage(612, 792);
    const text = printableAscii();
    try doc.drawText(page, font, 12, 72, 700, .black, &text, .{});
    const capacity = doc.scratch.queryCapacity();
    try std.testing.expect(capacity > 0);
    for (0..5) |_| try doc.drawText(page, font, 12, 72, 700, .black, &text, .{});
    try std.testing.expectEqual(capacity, doc.scratch.queryCapacity());

    // drawShaped resets scratch too: only the mapping goes there, so the same
    // line drawn again needs no new block.
    var shaped = try zpdf.shape(gpa, &loaded_font, &text, .{});
    defer shaped.deinit(gpa);
    for (0..5) |_| try doc.drawShaped(page, font, 12, 72, 700, .black, shaped);
    try std.testing.expectEqual(capacity, doc.scratch.queryCapacity());
}

test "a document's working memory does not grow from page to page" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const bytes = try E2e.load(options.test_font_roboto);
    defer gpa.free(bytes);
    var loaded_font = try zpdf.Font.init(gpa, bytes, 0, &.{});
    defer loaded_font.deinit();
    // The PDF goes to a sink that keeps nothing, so only the document's own memory counts.
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var doc = try Document.begin(gpa, &discard.writer, .{ .compress = true });
    defer doc.deinit();
    const font = try doc.addFont(&loaded_font);
    const text = printableAscii();
    var page_capacity: usize = 0;
    var write_capacity: usize = 0;
    for (0..30) |n| {
        const page = try doc.beginPage(612, 792);
        for (0..20) |line| try doc.drawText(page, font, 12, 72, 700 - 14 * @as(f64, @floatFromInt(line)), .black, &text, .{});
        try doc.endPage(page);
        // The first resets merge each arena's blocks into one; from the third page on, an
        // arena that is not reset per page shows up as growth.
        if (n == 2) {
            page_capacity = doc.page_arena.queryCapacity();
            write_capacity = doc.write_scratch.queryCapacity();
            try std.testing.expect(page_capacity > 0 and write_capacity > 0);
        } else if (n > 2) {
            try std.testing.expectEqual(page_capacity, doc.page_arena.queryCapacity());
            try std.testing.expectEqual(write_capacity, doc.write_scratch.queryCapacity());
        }
    }
    try doc.finish();
}

test "shape cache: a hit draws what a miss drew, and options are part of the key" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const bytes = try E2e.load(options.test_font_noto_hebrew);
    defer gpa.free(bytes);
    var loaded_font = try zpdf.Font.init(gpa, bytes, 0, &.{});
    defer loaded_font.deinit();
    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, false);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    const font = try doc.addFont(&loaded_font);
    const df = &doc.fonts.items[@backingInt(font)].embedded;
    const page = try doc.beginPage(612, 792);
    // Mixed text: its glyph order depends on the paragraph direction.
    const text = "\u{05E9}\u{05DC}\u{05D5}\u{05DD} 12";
    try doc.drawText(page, font, 12, 72, 700, .black, text, .{ .paragraph_direction = .ltr });
    try doc.drawText(page, font, 12, 72, 680, .black, text, .{ .paragraph_direction = .rtl });
    try std.testing.expectEqual(@as(usize, 2), df.shapes.count());
    // No test font shapes differently by language, so the key is checked directly.
    const k1 = try cacheKey(gpa, "a", .{ .language = 1 });
    defer gpa.free(k1);
    const k2 = try cacheKey(gpa, "a", .{ .language = 2 });
    defer gpa.free(k2);
    try std.testing.expect(!std.mem.eql(u8, k1, k2));
    const ops = doc.open.?.ops.items;
    try std.testing.expect(!std.mem.eql(u16, ops[0].text.text.shaped.mapping.cids, ops[1].text.text.shaped.mapping.cids));

    // A hit at another size: no new entry, the same glyphs and CIDs as the miss.
    const cids_before = df.cids.count();
    try doc.drawText(page, font, 30, 72, 600, .black, text, .{ .paragraph_direction = .rtl });
    try std.testing.expectEqual(@as(usize, 2), df.shapes.count());
    try std.testing.expectEqual(cids_before, df.cids.count());
    // Read the ops again: the third drawText may have moved the list.
    const miss = doc.open.?.ops.items[1].text.text.shaped;
    const hit = doc.open.?.ops.items[2].text.text.shaped;
    try std.testing.expectEqualSlices(zpdf.Glyph, miss.glyphs, hit.glyphs);
    try std.testing.expectEqualSlices(u16, miss.mapping.cids, hit.mapping.cids);

    // A hit still runs the size checks. Shaped text with a rise of 4 em is
    // put in the cache by hand (no test font shapes one): at 1e9 pt the rise
    // passes the PDF real range and the hit is refused; at 12 pt it is drawn.
    const cache = doc.cache_arena.allocator();
    const em: i32 = df.face.units_per_em;
    try df.shapes.put(gpa, try cacheKey(cache, "x", .{}), .{
        .glyphs = try cache.dupe(zpdf.Glyph, &.{testGlyph(0, em * 4, 0)}),
        .mapping = .{ .cids = try cache.dupe(u16, &.{1}), .spans = &.{} },
    });
    const n_ops = doc.open.?.ops.items.len;
    try std.testing.expectError(error.InvalidNumber, doc.drawText(page, font, 1e9, 72, 600, .black, "x", .{}));
    try std.testing.expectEqual(n_ops, doc.open.?.ops.items.len);
    try doc.drawText(page, font, 12, 72, 600, .black, "x", .{});
    try std.testing.expectEqual(n_ops + 1, doc.open.?.ops.items.len);
}

test "shape cache: endPage clears it only when it holds more than its budget" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const bytes = try E2e.load(options.test_font_roboto);
    defer gpa.free(bytes);
    var loaded_font = try zpdf.Font.init(gpa, bytes, 0, &.{});
    defer loaded_font.deinit();
    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, true);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    const font = try doc.addFont(&loaded_font);
    const df = &doc.fonts.items[@backingInt(font)].embedded;

    var p = try doc.beginPage(612, 792);
    try doc.drawText(p, font, 12, 72, 700, .black, "kept", .{});
    try doc.endPage(p);
    try std.testing.expectEqual(@as(usize, 1), df.shapes.count());

    // Over budget: cleared after the page is written. The next page shapes
    // again, and the PDF reads the same as if nothing had been cleared.
    doc.cache_budget = 0;
    p = try doc.beginPage(612, 792);
    try doc.drawText(p, font, 12, 72, 700, .black, "kept", .{});
    try std.testing.expectEqual(@as(usize, 1), df.shapes.count());
    try doc.endPage(p);
    try std.testing.expectEqual(@as(usize, 0), df.shapes.count());
    p = try doc.beginPage(612, 792);
    try doc.drawText(p, font, 12, 72, 700, .black, "kept", .{});
    try std.testing.expectEqual(@as(usize, 1), df.shapes.count());
    const pdf = try td_doc.finishOwned(gpa);
    defer gpa.free(pdf);
    var parsed = try E2e.parse(gpa, pdf);
    defer parsed.deinit(gpa);
    // Content streams are objects 4, 12 and 14: the font takes 5 to 10 when
    // the first page ends.
    const first = try parsed.streamData(4);
    try std.testing.expectEqualStrings(first, try parsed.streamData(12));
    try std.testing.expectEqualStrings(first, try parsed.streamData(14));
}

/// Takes at most one byte per drain and has no buffer, so every partial-write
/// path of the writer in front of it runs. Fails once `limit` bytes are taken.
const Trickle = struct {
    gpa: std.mem.Allocator,
    limit: usize = std.math.maxInt(usize),
    taken: std.ArrayList(u8) = .empty,
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Trickle = @alignCast(@fieldParentPtr("writer", w));
        const byte = for (data[0 .. data.len - 1]) |d| {
            if (d.len > 0) break d[0];
        } else if (splat > 0 and data[data.len - 1].len > 0) data[data.len - 1][0] else return 0;
        if (self.taken.items.len >= self.limit) return error.WriteFailed;
        self.taken.append(self.gpa, byte) catch return error.WriteFailed;
        return 1;
    }
};

/// Two pages, three fonts, both pages ended. The first font is never drawn,
/// and the first page draws the third font, so font object numbers follow
/// first use on a finished page, not addFont order.
fn buildTwoPageDoc(doc: *Document, fonts: *[3]zpdf.Font) !void {
    _ = try doc.addFont(&fonts[0]);
    const roboto = try doc.addFont(&fonts[1]);
    const deva = try doc.addFont(&fonts[2]);
    const p1 = try doc.beginPage(612, 792);
    try doc.drawText(p1, deva, 24, 72, 720, .black, "\u{0915}\u{093F} \u{0915}\u{094D}\u{0937}", .{});
    try doc.endPage(p1);
    const p2 = try doc.beginPage(595.2756, 841.8898);
    try doc.drawText(p2, deva, 12, 72, 700, .black, "\u{0928}\u{092E}\u{0938}\u{094D}\u{0924}\u{0947}", .{});
    try doc.drawText(p2, roboto, 12.5, 72.25, 680, .black, "office AVA", .{});
    try doc.endPage(p2);
}

/// buildTwoPageDoc, written to `w` and flushed.
fn writeTwoPageDoc(gpa: std.mem.Allocator, w: *std.Io.Writer, compress: bool, fonts: *[3]zpdf.Font) !void {
    var doc = try Document.begin(gpa, w, .{ .compress = compress });
    defer doc.deinit();
    try buildTwoPageDoc(&doc, fonts);
    try doc.finish();
    try w.flush();
}

fn loadThreeFonts() ![3][]const u8 {
    const options = @import("build_options");
    const a = try E2e.load(options.test_font_latin);
    errdefer std.testing.allocator.free(a);
    const b = try E2e.load(options.test_font_roboto);
    errdefer std.testing.allocator.free(b);
    return .{ a, b, try E2e.load(options.test_font_noto_devanagari) };
}

/// Font.init for each of loadThreeFonts' files, with `allocator`, so a test
/// that fails allocations covers loading the fonts too.
fn initThreeFonts(allocator: std.mem.Allocator, bytes: *const [3][]const u8) ![3]zpdf.Font {
    var a = try zpdf.Font.init(allocator, bytes[0], 0, &.{});
    errdefer a.deinit();
    var b = try zpdf.Font.init(allocator, bytes[1], 0, &.{});
    errdefer b.deinit();
    return .{ a, b, try zpdf.Font.init(allocator, bytes[2], 0, &.{}) };
}

fn deinitThreeFonts(fonts: *[3]zpdf.Font) void {
    for (fonts) |*f| f.deinit();
}

test "a document streams the same bytes through a one-byte-at-a-time writer" {
    const gpa = std.testing.allocator;
    const font_bytes = try loadThreeFonts();
    defer for (font_bytes) |f| gpa.free(f);
    var fonts = try initThreeFonts(gpa, &font_bytes);
    defer deinitThreeFonts(&fonts);
    var whole_w: std.Io.Writer.Allocating = .init(gpa);
    defer whole_w.deinit();
    try writeTwoPageDoc(gpa, &whole_w.writer, true, &fonts);
    const whole = whole_w.written();
    var trickle: Trickle = .{ .gpa = gpa };
    defer trickle.taken.deinit(gpa);
    try writeTwoPageDoc(gpa, &trickle.writer, true, &fonts);
    try std.testing.expectEqualSlices(u8, whole, trickle.taken.items);

    // The xref must name the right offset for every object, and every stream
    // must be as long as its /Length says.
    var parsed = try E2e.parse(gpa, trickle.taken.items);
    defer parsed.deinit(gpa);
    // Catalog, Pages, 2 x (Page, Contents), 2 used fonts x 6.
    try std.testing.expectEqual(@as(u32, 2 + 2 * 2 + 2 * 6 + 1), parsed.size);
    for (1..parsed.size) |num| _ = try parsed.objectBody(@intCast(num));
    try E2e.expectContains(try parsed.objectBody(3), "/Font << /F3 5 0 R >>");
    try E2e.expectContains(try parsed.objectBody(11), "/Font << /F3 5 0 R /F2 13 0 R >>");
}

test "a document returns WriteFailed when the sink fails, wherever it fails" {
    const gpa = std.testing.allocator;
    const font_bytes = try loadThreeFonts();
    defer for (font_bytes) |f| gpa.free(f);
    var fonts = try initThreeFonts(gpa, &font_bytes);
    defer deinitThreeFonts(&fonts);
    var whole_w: std.Io.Writer.Allocating = .init(gpa);
    defer whole_w.deinit();
    try writeTwoPageDoc(gpa, &whole_w.writer, true, &fonts);
    const whole = whole_w.written();

    // Every byte offset would take minutes; a stride that is prime to the
    // object sizes still lands inside headers, streams and the xref.
    var limit: usize = 0;
    var n_checked: usize = 0;
    while (limit < whole.len) : (limit += 997) {
        var trickle: Trickle = .{ .gpa = gpa, .limit = limit };
        defer trickle.taken.deinit(gpa);
        try std.testing.expectError(error.WriteFailed, writeTwoPageDoc(gpa, &trickle.writer, true, &fonts));
        try std.testing.expectEqualSlices(u8, whole[0..limit], trickle.taken.items);
        n_checked += 1;
    }
    try std.testing.expect(n_checked > 10);
}

test "compressed and uncompressed documents hold the same objects" {
    const gpa = std.testing.allocator;
    const font_bytes = try loadThreeFonts();
    defer for (font_bytes) |f| gpa.free(f);
    var fonts = try initThreeFonts(gpa, &font_bytes);
    defer deinitThreeFonts(&fonts);
    var plain_w: std.Io.Writer.Allocating = .init(gpa);
    defer plain_w.deinit();
    try writeTwoPageDoc(gpa, &plain_w.writer, false, &fonts);
    var packed_w: std.Io.Writer.Allocating = .init(gpa);
    defer packed_w.deinit();
    try writeTwoPageDoc(gpa, &packed_w.writer, true, &fonts);

    var plain = try E2e.parse(gpa, plain_w.written());
    defer plain.deinit(gpa);
    var packed_pdf = try E2e.parse(gpa, packed_w.written());
    defer packed_pdf.deinit(gpa);
    try std.testing.expectEqual(plain.size, packed_pdf.size);
    try std.testing.expect(std.mem.indexOf(u8, plain.bytes, "/Filter") == null);

    var n_streams: usize = 0;
    for (1..plain.size) |i| {
        const num: u32 = @intCast(i);
        const plain_body = try plain.objectBody(num);
        const packed_body = try packed_pdf.objectBody(num);
        if (std.mem.indexOf(u8, plain_body, ">>\nstream\n") == null) {
            try std.testing.expectEqualStrings(plain_body, packed_body);
            continue;
        }
        n_streams += 1;
        try E2e.expectContains(packed_body, "/Filter /FlateDecode");
        try std.testing.expectEqualSlices(u8, try plain.streamData(num), try packed_pdf.streamData(num));
        // /Length1 is the uncompressed font length in both.
        if (std.mem.indexOf(u8, plain_body, "/Length1 ") != null) {
            try std.testing.expectEqual(try E2e.dictU32(plain_body, "/Length1 "), try E2e.dictU32(packed_body, "/Length1 "));
        }
    }
    // 2 content streams, and FontFile2, CIDToGIDMap and ToUnicode for each of the 2 used fonts.
    try std.testing.expectEqual(@as(usize, 2 + 2 * 3), n_streams);
    try std.testing.expect(packed_w.written().len * 2 < plain_w.written().len);
}

test "drawShaped writes the same PDF as drawText, and the text is the result's own copy" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const bytes = try E2e.load(options.test_font_noto_hebrew);
    defer gpa.free(bytes);
    var font = try zpdf.Font.init(gpa, bytes, 0, &.{});
    defer font.deinit();
    // Marks, RTL and Latin, so clusters, offsets and ActualText all matter.
    const text = "\u{05E9}\u{05B8}\u{05C1}\u{05DC}\u{05D5}\u{05B9}\u{05DD} office";

    var td_by_text: TestDoc = undefined;
    try td_by_text.init(gpa, true);
    defer td_by_text.deinit();
    const by_text = &td_by_text.doc;
    const id_a = try by_text.addFont(&font);
    const page_a = try by_text.beginPage(612, 792);
    try by_text.drawText(page_a, id_a, 24, 72, 720, .black, text, .{});
    const want = try td_by_text.finishOwned(gpa);
    defer gpa.free(want);

    var source = try gpa.dupe(u8, text);
    var shaped = try zpdf.shape(gpa, &font, source, .{});
    defer shaped.deinit(gpa);
    // The caller's buffer can change or go; the result keeps what was shaped.
    @memset(source, 'x');
    gpa.free(source);
    source = undefined;

    var td_by_shape: TestDoc = undefined;
    try td_by_shape.init(gpa, true);
    defer td_by_shape.deinit();
    const by_shape = &td_by_shape.doc;
    const id_b = try by_shape.addFont(&font);
    const page_b = try by_shape.beginPage(612, 792);
    try by_shape.drawShaped(page_b, id_b, 24, 72, 720, .black, shaped);
    const got = try td_by_shape.finishOwned(gpa);
    defer gpa.free(got);
    try std.testing.expectEqualSlices(u8, want, got);
}

test "drawShaped refuses a result from another Font or with a vertical advance, and changes nothing" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const bytes = try E2e.load(options.test_font_roboto);
    defer gpa.free(bytes);
    var font = try zpdf.Font.init(gpa, bytes, 0, &.{});
    defer font.deinit();
    // The same file loaded twice is two Fonts: glyph ids would agree here, but
    // a different instance of a variable font would not, so identity decides.
    var other = try zpdf.Font.init(gpa, bytes, 0, &.{});
    defer other.deinit();

    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, true);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    const id = try doc.addFont(&font);
    const page = try doc.beginPage(612, 792);
    try doc.drawText(page, id, 24, 72, 720, .black, "office", .{});
    const before = blk: {
        var td_want: TestDoc = undefined;
        try td_want.init(gpa, true);
        defer td_want.deinit();
        const want_page = try td_want.doc.beginPage(612, 792);
        try td_want.doc.drawText(want_page, try td_want.doc.addFont(&font), 24, 72, 720, .black, "office", .{});
        break :blk try td_want.finishOwned(gpa);
    };
    defer gpa.free(before);

    var from_other = try zpdf.shape(gpa, &other, "AVA", .{});
    defer from_other.deinit(gpa);
    try std.testing.expectError(error.FontMismatch, doc.drawShaped(page, id, 24, 72, 700, .black, from_other));

    // A vertical advance is refused as UnsupportedShaping before the pen runs.
    // Run through the pen first, the first glyph's huge advance_y would make
    // the second glyph's rise past the PDF real range (InvalidNumber).
    var vertical = try zpdf.shape(gpa, &font, "AV", .{});
    defer vertical.deinit(gpa);
    vertical.glyphs[0].advance_y = std.math.maxInt(i32);
    try std.testing.expectError(error.UnsupportedShaping, doc.drawShaped(page, id, 1e9, 72, 700, .black, vertical));

    const after = try td_doc.finishOwned(gpa);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

test "drawShaped refuses a result from an earlier Font at the same address" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const bytes = try E2e.load(options.test_font_noto_sans_vf);
    defer gpa.free(bytes);
    var font = try zpdf.Font.init(gpa, bytes, 0, &.{.{ .tag = "wght".*, .value = 900 }});
    var old = try zpdf.shape(gpa, &font, "abc", .{});
    defer old.deinit(gpa);
    font.deinit();
    // Another instance of the same file, in the same variable: same address,
    // same glyph ids, other advances.
    font = try zpdf.Font.init(gpa, bytes, 0, &.{.{ .tag = "wght".*, .value = 100 }});
    defer font.deinit();
    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, true);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    const id = try doc.addFont(&font);
    const page = try doc.beginPage(612, 792);
    try std.testing.expectError(error.FontMismatch, doc.drawShaped(page, id, 24, 72, 720, .black, old));
}

test "standard fonts: a Type1 font with WinAnsi text; refusals leave the document unchanged" {
    const gpa = std.testing.allocator;
    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, false);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    const unused = try doc.addStandardFont(.courier);
    _ = unused;
    const helv = try doc.addStandardFont(.helvetica_bold);
    const page = try doc.beginPage(612, 792);
    try doc.drawText(page, helv, 12, 72, 720, .black, "(a\\b) \u{20ac}\u{e9}", .{});
    const before = blk: {
        var td_want: TestDoc = undefined;
        try td_want.init(gpa, false);
        defer td_want.deinit();
        _ = try td_want.doc.addStandardFont(.courier);
        const want_helv = try td_want.doc.addStandardFont(.helvetica_bold);
        const want_page = try td_want.doc.beginPage(612, 792);
        try td_want.doc.drawText(want_page, want_helv, 12, 72, 720, .black, "(a\\b) \u{20ac}\u{e9}", .{});
        break :blk try td_want.finishOwned(gpa);
    };
    defer gpa.free(before);

    try std.testing.expectError(error.NotWinAnsi, doc.drawText(page, helv, 12, 72, 700, .black, "\u{142}", .{}));
    try std.testing.expectError(error.UnsupportedShaping, doc.drawText(page, helv, 12, 72, 700, .black, "abc", .{ .paragraph_direction = .rtl }));
    try std.testing.expectError(error.InvalidUtf8, doc.drawText(page, helv, 12, 72, 700, .black, "\xff", .{}));
    const options = @import("build_options");
    const bytes = try E2e.load(options.test_font_roboto);
    defer gpa.free(bytes);
    var roboto = try zpdf.Font.init(gpa, bytes, 0, &.{});
    defer roboto.deinit();
    var shaped = try zpdf.shape(gpa, &roboto, "abc", .{});
    defer shaped.deinit(gpa);
    try std.testing.expectError(error.FontMismatch, doc.drawShaped(page, helv, 12, 72, 700, .black, shaped));
    const after = try td_doc.finishOwned(gpa);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, before, after);

    // One font object, named and not embedded; Courier was never drawn, so it is not written.
    try E2e.expectContains(before, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>");
    try std.testing.expect(std.mem.indexOf(u8, before, "Courier") == null);
    try std.testing.expect(std.mem.indexOf(u8, before, "FontFile") == null);
    // ( ) \ escaped, bytes above ASCII as octal: the euro sign is 0x80, e-acute 0xE9.
    try E2e.expectContains(before, "(\\(a\\\\b\\) \\200\\351) Tj");
}

test "a standard font before an embedded font: every object is where the xref says" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const bytes = try E2e.load(options.test_font_roboto);
    defer gpa.free(bytes);
    var roboto = try zpdf.Font.init(gpa, bytes, 0, &.{});
    defer roboto.deinit();
    var td_doc: TestDoc = undefined;
    try td_doc.init(gpa, false);
    defer td_doc.deinit();
    const doc = &td_doc.doc;
    const times = try doc.addStandardFont(.times_roman);
    const embedded = try doc.addFont(&roboto);
    const helv = try doc.addStandardFont(.helvetica);
    const page = try doc.beginPage(612, 792);
    try doc.drawText(page, times, 12, 72, 720, .black, "Times", .{});
    try doc.drawText(page, embedded, 12, 72, 700, .black, "office", .{});
    try doc.drawText(page, helv, 12, 72, 680, .black, "Helvetica", .{});
    const pdf = try td_doc.finishOwned(gpa);
    defer gpa.free(pdf);
    var parsed = try E2e.parse(gpa, pdf);
    defer parsed.deinit(gpa);
    // Catalog, Pages, Page, Contents, Times (1), Roboto (6), Helvetica (1).
    try std.testing.expectEqual(@as(u32, 4 + 1 + 6 + 1 + 1), parsed.size);
    for (1..parsed.size) |num| _ = try parsed.objectBody(@intCast(num));
    try E2e.expectContains(try parsed.objectBody(5), "/BaseFont /Times-Roman");
    try E2e.expectContains(try parsed.objectBody(6), "/Subtype /Type0");
    try E2e.expectContains(try parsed.objectBody(12), "/BaseFont /Helvetica ");
    try E2e.expectContains(try parsed.objectBody(3), "/F1 5 0 R /F2 6 0 R /F3 12 0 R");
}
