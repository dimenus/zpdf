//! zpdf's C ABI: one list of exports that both builds have, zpdf.wasm (for the browser) and
//! libzpdf (a native shared library, for .NET and C). `zig build abi` writes zpdf.h and a C#
//! file of declarations from src/abi.zig (tools/gen-abi.zig), each export with its doc comment.
//!
//! Calls. Every number is little-endian. An export that can fail returns an i32 status: 0 on
//! success, else a negative code (`error_codes`; zpdf_error_name gives its name). Outputs go
//! through pointers the caller passes, and each is set to 0 before anything else, so after a
//! failure it reads 0. A null output pointer, or a null input pointer with a length above 0, is
//! InvalidPointer.
//!
//! Contexts. Every export except zpdf_abi_version, zpdf_error_name and zpdf_context_new takes a
//! context first. zpdf_context_new and zpdf_alloc return a pointer, null on failure; every other
//! export that can fail returns a status. A context owns its handles and its buffers. Two contexts share nothing, so two
//! threads can each use their own context at the same time. One context must not be used by two
//! threads at the same time: a call that finds another call running in its context returns
//! ContextBusy and does nothing. That check is a guard against misuse, not a lock.
//!
//! Buffers. Inputs stay the caller's; zpdf copies what it keeps (a font file, a PDF to read). A
//! returned buffer (out_ptr, out_len) is the caller's until it gives it back with
//! zpdf_free(ctx, ptr, len). A buffer of length 0 has a null pointer and needs no free. The
//! context records every buffer it gives out: freeing one it did not give, or with another
//! length, is InvalidPointer, and zpdf_context_free refuses with BuffersOutstanding while any is
//! still out. A buffer holds wire records (AxisRecord and the others below) one after another at
//! no particular alignment, so read each field unaligned.
//!
//! Sinks. zpdf_doc_new_sink makes a document that writes into the caller's Sink instead of a
//! buffer, in the way MuPDF's fz_output does: the PDF goes out as it is written, so the caller
//! holds neither the document nor a page's bytes for long. zpdf calls the sink's write only
//! during a zpdf call on that document's context, on the calling thread, and never after
//! zpdf_doc_close. write gets at most 64 KiB per call. zpdf_doc_new_sink (the header),
//! zpdf_doc_add_image, zpdf_doc_end_page, zpdf_doc_draw_text_later and zpdf_doc_finish pass on all
//! that is written before they return, so each can fail with SinkFailed. A caller-buffer sink is
//! asked for memory instead (get_buffer) and given back what zpdf wrote into it (commit), so the
//! PDF goes straight into the caller's memory; when any zpdf call on its document returns, zpdf
//! holds none of that memory, so a caller may flush or reuse it between calls (a PipeWriter's
//! FlushAsync). The callbacks must not call zpdf on the same context (ContextBusy). A write that fails ends the call with SinkFailed and fails
//! the document (DocumentFailed after that); the caller's own error stays on its side of the
//! ABI, in what `user` points at. zpdf_doc_take and zpdf_doc_finish give a sink document's
//! caller no bytes: they went to the sink.
//!
//! Handles. A u32 that names one open object (a font, a document or a reader), never 0. It is
//! valid from the call that returned it until its close. After that, and for a handle of another
//! kind, every export returns InvalidHandle. Up to 1024 objects are open at once per context
//! (TooManyHandles).
//!
//! Units. Fonts: font units, y up. Documents: points in PDF space (y up from the bottom of the
//! page); a rectangle's (x, y) is its bottom-left corner. r, g, b: DeviceRGB, each 0 to 1
//! (zpdf.Color). zpdf.Document says what each drawing call accepts. Reader: default user space,
//! as zpdf.read says.
//!
//! A defect inside zpdf. Both builds are ReleaseSafe, with kb's C undefined behaviour set to
//! trap, so a defect in Zig or kb stops the call instead of going on with bad state.
//!   - wasm: the instance traps. Its state is then unknown, and it never gets back the stack that
//!     the trapping frames used, so the caller must drop the instance and every handle it made.
//!     Before that, zpdf_wasm_panic_ptr() and zpdf_wasm_panic_len() give the Zig panic message,
//!     when the trap was one (the length is 0 otherwise).
//!   - native: the process ends. Zig's panic handler prints the message to stderr and aborts.
//!     This is on purpose: after a defect the library's state is unknown, and no caller can
//!     recover from that inside the same process.

const std = @import("std");
const builtin = @import("builtin");
const zpdf = @import("root.zig");
const sfnt = @import("sfnt.zig");
const text_layout = @import("text_layout.zig");
const BlockCache = @import("block_cache.zig").BlockCache;
const Counting = @import("counting.zig").Counting;
const abi_options = @import("abi_options");

const is_wasm = builtin.target.cpu.arch == .wasm32;

/// Changes when an export, a wire record or an error code changes. A caller checks it once,
/// when it loads the library.
pub const abi_version: u32 = 9;

/// The hash of the ABI that abi_version names (surfaceHash). The test "exports: the ABI surface
/// is the one abi_version names" fails when they differ: then bump abi_version and set this to
/// the hash the test prints.
const abi_surface: u64 = 0xd9a170196310e197;

comptime {
    // The records are written with their in-memory bytes; every target zpdf builds for
    // (wasm32, x86_64, aarch64) is little-endian.
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

/// zpdf_font_axes: one per axis, in fvar order.
pub const AxisRecord = extern struct {
    tag: [4]u8,
    min_value: f32,
    default_value: f32,
    max_value: f32,
    /// Bit 0: hidden.
    flags: u32,
};

/// zpdf_font_shape: this, then one ShapedGlyph per glyph. The pen after the last glyph.
pub const ShapeHeader = extern struct {
    pen_x: i32,
    pen_y: i32,
};

/// zpdf_font_wrap: this, then line_count LineRecords.
pub const WrapHeader = extern struct {
    line_count: u32,
    reserved: u32,
};

/// One wrapped line: bytes start to start + len of the text, without its trailing spaces or its
/// line break, and its width in points.
pub const LineRecord = extern struct {
    start: u32,
    len: u32,
    width: f64,
};

/// zpdf_font_wrap's flags: break a word wider than the line between characters.
const wrap_break_words: u32 = 1;

/// In kb's order. The origin is zpdf.Pen's, the rule the PDF uses.
pub const ShapedGlyph = extern struct {
    id: u32,
    /// The index of the codepoint the glyph's cluster starts at.
    cluster: u32,
    x: i32,
    y: i32,
};

/// zpdf_font_glyph_path: one per command, nonzero fill. The outline the PDF embeds at the font's
/// instance (zpdf.Outlines); TrueType only.
pub const PathRecord = extern struct {
    /// 0 move to (v0, v1), 1 line to (v0, v1), 2 quadratic with control (v0, v1) to (v2, v3),
    /// 3 close. Unused values are 0.
    kind: u32,
    reserved: u32,
    v: [4]f64,
};

/// zpdf_doc_new_sink: where a document writes, in one of two modes. Push: `write` is set, and zpdf
/// hands over bytes it owns. Caller buffers: `get_buffer` and `commit` are set, and zpdf writes
/// into memory the caller lends it (a PipeWriter's GetMemory, say), so the caller copies nothing.
/// Exactly one mode: anything else is InvalidPointer. zpdf copies the pointers; `user` must stay
/// valid until zpdf_doc_close, and zpdf never frees it.
pub const Sink = extern struct {
    /// The caller's: zpdf passes it to the callbacks and never reads it.
    user: ?*anyopaque,
    /// Push: takes all `len` bytes (never 0) and returns 0, or returns non-zero, which fails the
    /// document (SinkFailed). `bytes` is valid only during the call.
    write: ?*const fn (user: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) i32 = null,
    /// Caller buffers: sets `*buffer` and `*len` to memory zpdf may write, at least `min_len`
    /// bytes (never 0; at most 64 KiB is asked for), and returns 0; non-zero fails the document.
    /// zpdf writes the PDF's next bytes into it and gives it back with commit.
    get_buffer: ?*const fn (user: ?*anyopaque, min_len: usize, buffer: *?[*]u8, len: *usize) callconv(.c) i32 = null,
    /// Caller buffers: the first `len` bytes of the last buffer are the PDF's next bytes (`len`
    /// may be 0). zpdf does not touch that buffer again. Non-zero fails the document.
    commit: ?*const fn (user: ?*anyopaque, len: usize) callconv(.c) i32 = null,

    const Mode = enum { push, buffers };

    fn mode(s: Sink) ?Mode {
        if (s.write != null and s.get_buffer == null and s.commit == null) return .push;
        if (s.write == null and s.get_buffer != null and s.commit != null) return .buffers;
        return null;
    }
};

/// zpdf_reader_page.
pub const PageInfo = extern struct {
    /// [x0 y0 x1 y1], inherited, with x0 <= x1 and y0 <= y1.
    media_box: [4]f64,
    /// The media box when the page has none.
    crop_box: [4]f64,
    /// Degrees clockwise: 0, 90, 180 or 270.
    rotate: u32,
    reserved: u32,
};

/// zpdf_reader_page_text: this, then run_count RunRecords, then glyph_count GlyphRecords, then
/// strings_len bytes of UTF-8 that the runs point into.
pub const TextHeader = extern struct {
    run_count: u32,
    glyph_count: u32,
    /// zpdf.read.PageText.unplaced_actual_text.
    unplaced_actual_text: u32,
    strings_len: u32,
};

/// One zpdf.read.TextRun, in the order the page draws them.
pub const RunRecord = extern struct {
    /// The origin of the run's first glyph.
    x: f64,
    y: f64,
    size: f64,
    /// NaN when a glyph's width is unknown.
    width: f64,
    /// The run's text: bytes in the strings area.
    text_offset: u32,
    text_len: u32,
    /// The font's /BaseFont, possibly empty: bytes in the strings area.
    font_offset: u32,
    font_len: u32,
    /// The run's glyphs: GlyphRecords first_glyph to first_glyph + glyph_count.
    first_glyph: u32,
    glyph_count: u32,
    /// Codes with no Unicode mapping; each is U+FFFD in the text.
    unmapped: u32,
    /// The RunFlag bits.
    flags: u32,
};

/// RunRecord.flags: a run has the bit 1 << n for each flag n that is true of it.
pub const RunFlag = enum(u5) {
    /// The text is the span's /ActualText (zpdf.read.TextRun.actual_text).
    actual_text = 0,
    /// Vertical writing (zpdf.read.TextRun.vertical): each glyph moves the text position along
    /// text space's y axis, and a glyph's position is its vertical origin.
    vertical = 1,
    /// Drawn by an annotation's appearance stream (zpdf.read.TextRun.annotation), such as a form
    /// field's value, not by the page's content stream.
    annotation = 2,
};

fn runFlags(run: zpdf.read.TextRun) u32 {
    var flags: u32 = 0;
    if (run.actual_text) flags |= 1 << @backingInt(RunFlag.actual_text);
    if (run.vertical) flags |= 1 << @backingInt(RunFlag.vertical);
    if (run.annotation) flags |= 1 << @backingInt(RunFlag.annotation);
    return flags;
}

pub const GlyphRecord = extern struct {
    x: f64,
    y: f64,
    /// Where the glyph's characters start in the run's text (bytes); 0 in an ActualText run.
    text_at: u32,
    reserved: u32,
};

comptime {
    // No padding: the bytes written are exactly the fields.
    for (.{ .{ AxisRecord, 20 }, .{ ShapeHeader, 8 }, .{ ShapedGlyph, 16 }, .{ PathRecord, 40 }, .{ PageInfo, 72 }, .{ TextHeader, 16 }, .{ RunRecord, 64 }, .{ GlyphRecord, 24 } }) |r| {
        std.debug.assert(@sizeOf(r[0]) == r[1]);
    }
}

fn putRecord(out: []u8, at: usize, record: anytype) void {
    @memcpy(out[at..][0..@sizeOf(@TypeOf(record))], std.mem.asBytes(&record));
}

const slot_bits = 10;
const slot_count = 1 << slot_bits;
const max_generation: u32 = (1 << (32 - slot_bits)) - 1;
const no_slot = std.math.maxInt(u32);

pub const Kind = enum(u8) { free, font, document, reader };

/// Open objects by handle. A handle is (generation << 10) | slot. Closing bumps the
/// slot's generation, so every copy of the old handle stops matching at once. A
/// slot returns to the free list only when its object is destroyed (no references
/// left); a slot whose generation is used up is never reused, so a handle can never
/// name a later object. The free list runs through the dead slots, as the Zig
/// compiler's InternPool keeps its namespace free list, so closing never allocates.
pub const Table = struct {
    slots: [slot_count]Slot = undefined,
    /// Slots below this have been used at least once.
    used: u32 = 0,
    free_head: u32 = no_slot,

    const Slot = struct {
        generation: u32,
        kind: Kind,
        /// False once the handle is closed; the object can outlive it (refs).
        open: bool,
        /// Documents that use this font.
        refs: u32,
        object: ?*anyopaque,
        next_free: u32,
    };

    fn acquire(self: *Table, kind: Kind, object: *anyopaque) !u32 {
        const index = if (self.free_head != no_slot) blk: {
            const i = self.free_head;
            self.free_head = self.slots[i].next_free;
            break :blk i;
        } else if (self.used < slot_count) blk: {
            const i = self.used;
            self.used += 1;
            self.slots[i] = .{ .generation = 1, .kind = .free, .open = false, .refs = 0, .object = null, .next_free = no_slot };
            break :blk i;
        } else return error.TooManyHandles;
        const s = &self.slots[index];
        s.* = .{ .generation = s.generation, .kind = kind, .open = true, .refs = 0, .object = object, .next_free = no_slot };
        return (s.generation << slot_bits) | index;
    }

    /// The slot `handle` names, if it is open and of `kind`.
    fn lookup(self: *Table, handle: u32, kind: Kind) !*Slot {
        const index = handle & (slot_count - 1);
        if (index >= self.used) return error.InvalidHandle;
        const s = &self.slots[index];
        if (!s.open or s.kind != kind or s.generation != handle >> slot_bits) return error.InvalidHandle;
        return s;
    }

    /// Ends `handle`. Returns the object when nothing else holds it, for the caller
    /// to destroy; null when a document still does.
    fn close(self: *Table, handle: u32, kind: Kind) !?*anyopaque {
        const s = try self.lookup(handle, kind);
        s.open = false;
        if (s.generation < max_generation) s.generation += 1;
        if (s.refs != 0) return null;
        return self.release(s);
    }

    fn retain(s: *Slot) void {
        s.refs += 1;
    }

    /// Drops one reference; returns the object when it was the last and the handle
    /// is closed.
    fn unref(self: *Table, index: u32) ?*anyopaque {
        const s = &self.slots[index];
        s.refs -= 1;
        if (s.refs != 0 or s.open) return null;
        return self.release(s);
    }

    fn release(self: *Table, s: *Slot) *anyopaque {
        const object = s.object.?;
        s.object = null;
        s.kind = .free;
        // A slot whose generation is used up stays out of the free list for good.
        if (s.generation < max_generation) {
            s.next_free = self.free_head;
            self.free_head = @intCast(s - &self.slots[0]);
        }
        return object;
    }

    fn indexOf(self: *Table, s: *const Slot) u32 {
        return @intCast(s - &self.slots[0]);
    }
};

const FontObject = struct {
    /// A font file the caller opened, or one of the standard fonts, which has no file: it can be
    /// measured, wrapped and added to a document, and nothing else (NotEmbedded).
    font: union(enum) { embedded: zpdf.Font, standard: zpdf.StandardFont },
    /// Made on the first glyph path.
    outlines: ?zpdf.Outlines = null,

    fn embedded(f: *FontObject) error{NotEmbedded}!*zpdf.Font {
        return switch (f.font) {
            .embedded => |*e| e,
            .standard => error.NotEmbedded,
        };
    }

    fn layoutFont(f: *FontObject) text_layout.FontRef {
        return switch (f.font) {
            .embedded => |*e| .{ .embedded = e },
            .standard => |s| .{ .standard = s },
        };
    }
};

const DocObject = struct {
    doc: zpdf.Document,
    /// Where the document writes: a buffer the caller takes the PDF from (zpdf_doc_take,
    /// zpdf_doc_finish), or the caller's sink. The Document points at it, so the object stays
    /// where it was created.
    out: union(enum) { buffer: std.Io.Writer.Allocating, sink: SinkWriter, caller: CallerBufferWriter },
    /// The font slots this document holds a reference on.
    font_slots: std.ArrayList(u32) = .empty,

    fn writer(d: *DocObject) *std.Io.Writer {
        return switch (d.out) {
            .buffer => |*b| &b.writer,
            .sink => |*s| &s.interface,
            .caller => |*c| &c.interface,
        };
    }

    /// What a failed write is to the caller: a buffer fails only when it cannot grow; a sink,
    /// when the caller's write said so.
    fn writeError(d: *const DocObject, err: anyerror) anyerror {
        if (err != error.WriteFailed) return err;
        return switch (d.out) {
            .buffer => error.OutOfMemory,
            .sink, .caller => error.SinkFailed,
        };
    }
};

/// zpdf_doc_new_sink's sink buffer: what a push sink's write gets at most per call, and the most
/// a caller-buffer sink is asked for at once.
const sink_buffer_len = 64 * 1024;

/// A caller-buffer Sink as a std.Io.Writer whose buffer is the caller's memory: zpdf.Document's
/// bytes are written straight into it. drain gives the filled buffer back (commit), asks for the
/// next (get_buffer), and moves as much of `data` in as fits. flush gives the buffer back and
/// holds none, which every zpdf call on such a document does before it returns.
const CallerBufferWriter = struct {
    sink: Sink,
    interface: std.Io.Writer,

    fn init(sink: Sink) CallerBufferWriter {
        return .{ .sink = sink, .interface = .{ .vtable = &.{ .drain = drain, .flush = flush }, .buffer = &.{} } };
    }

    /// Commits what is written and drops the buffer.
    fn release(c: *CallerBufferWriter) std.Io.Writer.Error!void {
        const w = &c.interface;
        if (w.buffer.len == 0) return;
        const n = w.end;
        w.buffer = &.{};
        w.end = 0;
        if (c.sink.commit.?(c.sink.user, n) != 0) return error.WriteFailed;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const c: *CallerBufferWriter = @alignCast(@fieldParentPtr("interface", w));
        try c.release();
        const want = @max(1, @min(std.Io.Writer.countSplat(data, splat), sink_buffer_len));
        var ptr: ?[*]u8 = null;
        var len: usize = 0;
        if (c.sink.get_buffer.?(c.sink.user, want, &ptr, &len) != 0) return error.WriteFailed;
        // A buffer smaller than asked for, or none, is the caller's defect: refused, not trusted.
        if (ptr == null or len < want) return error.WriteFailed;
        w.buffer = ptr.?[0..len];
        // As much of data as fits, the last slice `splat` times.
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            const take = @min(bytes.len, w.buffer.len - w.end);
            @memcpy(w.buffer[w.end..][0..take], bytes[0..take]);
            w.end += take;
            n += take;
            if (take < bytes.len) return n;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            const take = @min(pattern.len, w.buffer.len - w.end);
            @memcpy(w.buffer[w.end..][0..take], pattern[0..take]);
            w.end += take;
            n += take;
            if (take < pattern.len) return n;
        }
        return n;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const c: *CallerBufferWriter = @alignCast(@fieldParentPtr("interface", w));
        try c.release();
    }
};

/// A Sink as a std.Io.Writer, so zpdf.Document writes into it as into any writer. drain follows
/// std.Io.Writer.VTable.drain, in the way std's Writer.Discarding does: the buffered bytes first,
/// then each slice of `data`, the last one `splat` times.
const SinkWriter = struct {
    sink: Sink,
    interface: std.Io.Writer,

    fn init(sink: Sink, buffer: []u8) SinkWriter {
        return .{ .sink = sink, .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    fn emit(s: *SinkWriter, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len == 0) return;
        if (s.sink.write.?(s.sink.user, bytes.ptr, bytes.len) != 0) return error.WriteFailed;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const s: *SinkWriter = @alignCast(@fieldParentPtr("interface", w));
        try s.emit(w.buffered());
        w.end = 0;
        const slice = data[0 .. data.len - 1];
        const pattern = data[slice.len];
        var written: usize = 0;
        for (slice) |bytes| {
            try s.emit(bytes);
            written += bytes.len;
        }
        for (0..splat) |_| {
            try s.emit(pattern);
            written += pattern.len;
        }
        return written;
    }
};

const ReaderObject = struct {
    /// The reader borrows the PDF's bytes; this is the copy it borrows from.
    bytes: []u8,
    reader: zpdf.read.Reader,
};

/// Everything the exports do, over one allocator and one handle table. A Context holds one;
/// tests use their own.
pub const Runtime = struct {
    gpa: std.mem.Allocator,
    table: Table = .{},

    pub fn fontOpen(rt: *Runtime, bytes: []const u8, index: i32, variation_records: []const u8) !u32 {
        const variations = try parseVariationRecords(rt.gpa, variation_records);
        defer rt.gpa.free(variations);
        const object = try rt.gpa.create(FontObject);
        errdefer rt.gpa.destroy(object);
        object.* = .{ .font = .{ .embedded = try zpdf.Font.init(rt.gpa, bytes, index, variations) } };
        errdefer object.font.embedded.deinit();
        return rt.table.acquire(.font, object);
    }

    pub fn fontOpenStandard(rt: *Runtime, standard: u32) !u32 {
        const standard_font = std.enums.fromInt(zpdf.StandardFont, standard) orelse return error.InvalidFont;
        const object = try rt.gpa.create(FontObject);
        errdefer rt.gpa.destroy(object);
        object.* = .{ .font = .{ .standard = standard_font } };
        return rt.table.acquire(.font, object);
    }

    pub fn fontClose(rt: *Runtime, handle: u32) !void {
        if (try rt.table.close(handle, .font)) |object| rt.destroyFont(@ptrCast(@alignCast(object)));
    }

    fn destroyFont(rt: *Runtime, object: *FontObject) void {
        if (object.outlines) |*o| o.deinit();
        switch (object.font) {
            .embedded => |*e| e.deinit(),
            .standard => {},
        }
        rt.gpa.destroy(object);
    }

    fn font(rt: *Runtime, handle: u32) !*FontObject {
        return @ptrCast(@alignCast((try rt.table.lookup(handle, .font)).object.?));
    }

    pub fn fontUnitsPerEm(rt: *Runtime, handle: u32) !u16 {
        const f = try (try rt.font(handle)).embedded();
        return sfnt.unitsPerEm(f.bytes, f.index);
    }

    /// AxisRecords, owned by rt.gpa.
    pub fn fontAxes(rt: *Runtime, handle: u32) ![]u8 {
        const f = try (try rt.font(handle)).embedded();
        const axes = try f.axes(rt.gpa);
        defer rt.gpa.free(axes);
        const out = try rt.gpa.alloc(u8, axes.len * @sizeOf(AxisRecord));
        for (axes, 0..) |axis, i| putRecord(out, i * @sizeOf(AxisRecord), AxisRecord{
            .tag = axis.tag,
            .min_value = axis.minimum,
            .default_value = axis.default,
            .max_value = axis.maximum,
            .flags = @intFromBool(axis.hidden),
        });
        return out;
    }

    /// A ShapeHeader then ShapedGlyphs, owned by rt.gpa.
    pub fn fontShape(rt: *Runtime, handle: u32, text: []const u8, direction: u32) ![]u8 {
        const f = try (try rt.font(handle)).embedded();
        var shaped = try zpdf.shape(rt.gpa, f, text, .{ .paragraph_direction = try toDirection(direction) });
        defer shaped.deinit(rt.gpa);
        const out = try rt.gpa.alloc(u8, @sizeOf(ShapeHeader) + shaped.glyphs.len * @sizeOf(ShapedGlyph));
        errdefer rt.gpa.free(out);
        var pen: zpdf.Pen = .{};
        for (shaped.glyphs, 0..) |glyph, i| {
            const origin = pen.place(glyph);
            putRecord(out, @sizeOf(ShapeHeader) + i * @sizeOf(ShapedGlyph), ShapedGlyph{
                .id = glyph.id,
                .cluster = glyph.cluster,
                .x = std.math.cast(i32, origin.x) orelse return error.InvalidNumber,
                .y = std.math.cast(i32, origin.y) orelse return error.InvalidNumber,
            });
        }
        putRecord(out, 0, ShapeHeader{
            .pen_x = std.math.cast(i32, pen.x) orelse return error.InvalidNumber,
            .pen_y = std.math.cast(i32, pen.y) orelse return error.InvalidNumber,
        });
        return out;
    }

    /// Glyph `gid`'s PathRecords, owned by rt.gpa.
    pub fn fontGlyphPath(rt: *Runtime, handle: u32, gid: u32) ![]u8 {
        const f = try rt.font(handle);
        const e = try f.embedded();
        if (f.outlines == null) f.outlines = try e.outlines(rt.gpa);
        const commands = try f.outlines.?.path(rt.gpa, std.math.cast(u16, gid) orelse return error.InvalidFont);
        defer rt.gpa.free(commands);
        const out = try rt.gpa.alloc(u8, commands.len * @sizeOf(PathRecord));
        for (commands, 0..) |c, i| {
            const kind: u32, const v: [4]f64 = switch (c) {
                .move => |p| .{ 0, .{ p.x, p.y, 0, 0 } },
                .line => |p| .{ 1, .{ p.x, p.y, 0, 0 } },
                .quad => |q| .{ 2, .{ q.control.x, q.control.y, q.to.x, q.to.y } },
                .close => .{ 3, .{ 0, 0, 0, 0 } },
            };
            putRecord(out, i * @sizeOf(PathRecord), PathRecord{ .kind = kind, .reserved = 0, .v = v });
        }
        return out;
    }

    pub fn docNew(rt: *Runtime, compress: bool) !u32 {
        const object = try rt.gpa.create(DocObject);
        errdefer rt.gpa.destroy(object);
        object.* = .{ .doc = undefined, .out = .{ .buffer = .init(rt.gpa) } };
        errdefer object.out.buffer.deinit();
        object.doc = zpdf.Document.begin(rt.gpa, object.writer(), .{ .compress = compress }) catch |err|
            return object.writeError(err);
        errdefer object.doc.deinit();
        return rt.table.acquire(.document, object);
    }

    /// A document that writes into `sink` (zpdf_doc_new_sink says how) instead of a buffer.
    pub fn docNewSink(rt: *Runtime, compress: bool, sink: Sink) !u32 {
        const mode = sink.mode() orelse return error.InvalidPointer;
        const object = try rt.gpa.create(DocObject);
        errdefer rt.gpa.destroy(object);
        switch (mode) {
            .push => object.* = .{ .doc = undefined, .out = .{ .sink = .init(sink, try rt.gpa.alloc(u8, sink_buffer_len)) } },
            .buffers => object.* = .{ .doc = undefined, .out = .{ .caller = .init(sink) } },
        }
        errdefer if (object.out == .sink) rt.gpa.free(object.out.sink.interface.buffer);
        object.doc = zpdf.Document.begin(rt.gpa, object.writer(), .{ .compress = compress }) catch |err|
            return object.writeError(err);
        errdefer object.doc.deinit();
        // The header is out, and no caller buffer is held when this returns.
        object.doc.flushOutput() catch |err| return object.writeError(err);
        return rt.table.acquire(.document, object);
    }

    fn doc(rt: *Runtime, handle: u32) !*DocObject {
        return @ptrCast(@alignCast((try rt.table.lookup(handle, .document)).object.?));
    }

    /// Adds the font to the document, which holds it until the document closes.
    pub fn docAddFont(rt: *Runtime, doc_handle: u32, font_handle: u32) !u32 {
        const d = try rt.doc(doc_handle);
        const font_slot = try rt.table.lookup(font_handle, .font);
        const f: *FontObject = @ptrCast(@alignCast(font_slot.object.?));
        try d.font_slots.ensureUnusedCapacity(rt.gpa, 1);
        const id = switch (f.font) {
            .embedded => |*e| try d.doc.addFont(e),
            .standard => |standard| try d.doc.addStandardFont(standard),
        };
        d.font_slots.appendAssumeCapacity(rt.table.indexOf(font_slot));
        Table.retain(font_slot);
        return @backingInt(id);
    }

    /// The width of `text` at `size` points, as one run (text_layout.measure).
    pub fn fontMeasure(rt: *Runtime, handle: u32, size: f64, text: []const u8, direction: u32) !f64 {
        const f = try rt.font(handle);
        return text_layout.measure(rt.gpa, f.layoutFont(), size, text, .{ .paragraph_direction = try toDirection(direction) });
    }

    pub fn fontVerticalMetrics(rt: *Runtime, handle: u32) !text_layout.VerticalMetrics {
        return text_layout.verticalMetrics((try rt.font(handle)).layoutFont());
    }

    pub fn fontFirstMissing(rt: *Runtime, handle: u32, text: []const u8, direction: u32) !usize {
        const f = try rt.font(handle);
        return text_layout.firstMissing(rt.gpa, f.layoutFont(), text, .{ .paragraph_direction = try toDirection(direction) });
    }

    pub fn fontFit(rt: *Runtime, handle: u32, size: f64, text: []const u8, direction: u32, max_width: f64) !text_layout.Fit {
        const f = try rt.font(handle);
        return text_layout.fit(rt.gpa, f.layoutFont(), size, text, max_width, .{ .paragraph_direction = try toDirection(direction) });
    }

    /// The font's name, owned by rt.gpa: a standard font's base font name, an embedded font's
    /// PostScript name at its instance (the PDF's /BaseFont after the subset prefix).
    pub fn fontName(rt: *Runtime, handle: u32) ![]u8 {
        const f = try rt.font(handle);
        switch (f.font) {
            .standard => |standard| return rt.gpa.dupe(u8, standard.baseFont()),
            .embedded => |*e| {
                const name = try e.postscriptName(try sfnt.open(e.bytes, e.index));
                return rt.gpa.dupe(u8, name.slice());
            },
        }
    }

    /// A WrapHeader then LineRecords (text_layout.wrap), owned by rt.gpa.
    pub fn fontWrap(rt: *Runtime, handle: u32, size: f64, text: []const u8, direction: u32, max_width: f64, flags: u32) ![]u8 {
        const f = try rt.font(handle);
        if (flags & ~@as(u32, wrap_break_words) != 0) return error.InvalidNumber;
        const lines = try text_layout.wrap(rt.gpa, f.layoutFont(), size, text, max_width, .{
            .shape = .{ .paragraph_direction = try toDirection(direction) },
            .break_words = flags & wrap_break_words != 0,
        });
        defer rt.gpa.free(lines);
        const out = try rt.gpa.alloc(u8, @sizeOf(WrapHeader) + lines.len * @sizeOf(LineRecord));
        putRecord(out, 0, WrapHeader{ .line_count = @intCast(lines.len), .reserved = 0 });
        for (lines, 0..) |l, i| putRecord(out, @sizeOf(WrapHeader) + i * @sizeOf(LineRecord), LineRecord{
            .start = l.start,
            .len = l.len,
            .width = l.width,
        });
        return out;
    }

    pub fn docBeginPage(rt: *Runtime, handle: u32, width: f64, height: f64) !u32 {
        const d = try rt.doc(handle);
        return @backingInt(try d.doc.beginPage(width, height));
    }

    pub fn docDrawText(rt: *Runtime, handle: u32, page: u32, font_id: u32, size: f64, x: f64, y: f64, color: zpdf.Color, text: []const u8, direction: u32) !void {
        const d = try rt.doc(handle);
        const dir = try toDirection(direction);
        try d.doc.drawText(@fromBackingInt(@intCast(page)), @fromBackingInt(@intCast(font_id)), size, x, y, color, text, .{ .paragraph_direction = dir });
    }

    pub fn docReserveLater(rt: *Runtime, handle: u32, page: u32) !u32 {
        const d = try rt.doc(handle);
        return @backingInt(try d.doc.reserveLater(@fromBackingInt(@intCast(page))));
    }

    pub fn docDrawTextLater(rt: *Runtime, handle: u32, later: u32, font_id: u32, size: f64, x: f64, y: f64, color: zpdf.Color, text: []const u8, direction: u32) !void {
        const d = try rt.doc(handle);
        const dir = try toDirection(direction);
        d.doc.drawTextLater(@fromBackingInt(@intCast(later)), @fromBackingInt(@intCast(font_id)), size, x, y, color, text, .{ .paragraph_direction = dir }) catch |err| return d.writeError(err);
        // It writes its form now: a sink has it, and no caller buffer is held, on return.
        if (d.out != .buffer) d.doc.flushOutput() catch |err| return d.writeError(err);
    }

    /// Adds and writes the image (zpdf.Document.addImage); with a sink, its bytes have reached the
    /// sink when this returns.
    pub fn docAddImage(rt: *Runtime, handle: u32, bytes: []const u8) !u32 {
        const d = try rt.doc(handle);
        const id = d.doc.addImage(bytes) catch |err| return d.writeError(err);
        if (d.out != .buffer) d.doc.flushOutput() catch |err| return d.writeError(err);
        return @backingInt(id);
    }

    pub fn docImageSize(rt: *Runtime, handle: u32, image: u32) !struct { width: u32, height: u32 } {
        const d = try rt.doc(handle);
        const size = try d.doc.imageSize(@fromBackingInt(image));
        return .{ .width = size.width, .height = size.height };
    }

    pub fn docDrawImage(rt: *Runtime, handle: u32, page: u32, image: u32, x: f64, y: f64, width: f64, height: f64) !void {
        const d = try rt.doc(handle);
        try d.doc.drawImage(@fromBackingInt(@intCast(page)), @fromBackingInt(image), x, y, width, height);
    }

    pub fn docAddLink(rt: *Runtime, handle: u32, page: u32, x: f64, y: f64, width: f64, height: f64, target: zpdf.LinkTarget) !void {
        const d = try rt.doc(handle);
        try d.doc.addLink(@fromBackingInt(@intCast(page)), x, y, width, height, target);
    }

    /// The bookmark's id is its zpdf.BookmarkId + 1, so that a parent of 0 is the top level.
    pub fn docAddBookmark(rt: *Runtime, handle: u32, parent: u32, title: []const u8, dest: zpdf.Destination, open: bool) !u32 {
        const d = try rt.doc(handle);
        const p: ?zpdf.BookmarkId = if (parent == 0) null else @fromBackingInt(parent - 1);
        return @backingInt(try d.doc.addBookmark(p, title, dest, open)) + 1;
    }

    pub fn docDrawLine(rt: *Runtime, handle: u32, page: u32, x1: f64, y1: f64, x2: f64, y2: f64, width: f64, color: zpdf.Color) !void {
        const d = try rt.doc(handle);
        try d.doc.drawLine(@fromBackingInt(@intCast(page)), x1, y1, x2, y2, width, color);
    }

    pub fn docFillRect(rt: *Runtime, handle: u32, page: u32, x: f64, y: f64, width: f64, height: f64, color: zpdf.Color) !void {
        const d = try rt.doc(handle);
        try d.doc.fillRect(@fromBackingInt(@intCast(page)), x, y, width, height, color);
    }

    pub fn docStrokeRect(rt: *Runtime, handle: u32, page: u32, x: f64, y: f64, width: f64, height: f64, line_width: f64, color: zpdf.Color) !void {
        const d = try rt.doc(handle);
        try d.doc.strokeRect(@fromBackingInt(@intCast(page)), x, y, width, height, line_width, color);
    }

    /// Writes the page; with a sink, its bytes have reached the sink when this returns.
    pub fn docEndPage(rt: *Runtime, handle: u32, page: u32) !void {
        const d = try rt.doc(handle);
        d.doc.endPage(@fromBackingInt(@intCast(page))) catch |err| return d.writeError(err);
        if (d.out != .buffer) d.doc.flushOutput() catch |err| return d.writeError(err);
    }

    /// What the document has written since the last take, owned by rt.gpa. Empty for a sink
    /// document: its bytes went to the sink.
    pub fn docTake(rt: *Runtime, handle: u32) ![]u8 {
        const d = try rt.doc(handle);
        switch (d.out) {
            .buffer => |*b| {
                d.doc.flushOutput() catch |err| return d.writeError(err);
                return b.toOwnedSlice();
            },
            .sink, .caller => return rt.gpa.alloc(u8, 0),
        }
    }

    /// Finishes the document; the rest of the PDF (all of it when nothing was taken), owned by
    /// rt.gpa. For a sink document, the rest goes to the sink and this is empty.
    pub fn docFinish(rt: *Runtime, handle: u32) ![]u8 {
        const d = try rt.doc(handle);
        d.doc.finish() catch |err| return d.writeError(err);
        switch (d.out) {
            .buffer => |*b| return b.toOwnedSlice(),
            .sink, .caller => return rt.gpa.alloc(u8, 0),
        }
    }

    pub fn docClose(rt: *Runtime, handle: u32) !void {
        const object: *DocObject = @ptrCast(@alignCast((try rt.table.close(handle, .document)).?));
        object.doc.deinit();
        switch (object.out) {
            .buffer => |*b| b.deinit(),
            .sink => |s| rt.gpa.free(s.interface.buffer),
            // Every call gave the caller's buffer back before it returned.
            .caller => {},
        }
        for (object.font_slots.items) |index| {
            if (rt.table.unref(index)) |f| rt.destroyFont(@ptrCast(@alignCast(f)));
        }
        object.font_slots.deinit(rt.gpa);
        rt.gpa.destroy(object);
    }

    /// Opens a copy of `bytes` with zpdf.read's default limits.
    pub fn readerOpen(rt: *Runtime, bytes: []const u8) !u32 {
        const object = try rt.gpa.create(ReaderObject);
        errdefer rt.gpa.destroy(object);
        object.bytes = try rt.gpa.dupe(u8, bytes);
        errdefer rt.gpa.free(object.bytes);
        object.reader = try zpdf.read.Reader.open(rt.gpa, object.bytes, .{});
        errdefer object.reader.deinit();
        return rt.table.acquire(.reader, object);
    }

    fn reader(rt: *Runtime, handle: u32) !*ReaderObject {
        return @ptrCast(@alignCast((try rt.table.lookup(handle, .reader)).object.?));
    }

    pub fn readerClose(rt: *Runtime, handle: u32) !void {
        const object: *ReaderObject = @ptrCast(@alignCast((try rt.table.close(handle, .reader)).?));
        object.reader.deinit();
        rt.gpa.free(object.bytes);
        rt.gpa.destroy(object);
    }

    pub fn readerPageCount(rt: *Runtime, handle: u32) !u32 {
        const r = try rt.reader(handle);
        return std.math.cast(u32, r.reader.pageCount()) orelse error.TooLarge;
    }

    /// Page `index`; InvalidPage past the last.
    pub fn readerPage(rt: *Runtime, handle: u32, index: u32) !PageInfo {
        const r = try rt.reader(handle);
        if (index >= r.reader.pageCount()) return error.InvalidPage;
        const page = r.reader.page(index);
        return .{ .media_box = page.media_box, .crop_box = page.crop_box, .rotate = page.rotate, .reserved = 0 };
    }

    /// Page `index`'s text as a TextHeader and what follows it, owned by rt.gpa.
    pub fn readerPageText(rt: *Runtime, handle: u32, index: u32) ![]u8 {
        const r = try rt.reader(handle);
        if (index >= r.reader.pageCount()) return error.InvalidPage;
        // Encoded straight from the reader's work memory: copying the runs into a PageText first
        // took many allocations of 64 KiB or more a page, each a system call under an allocator
        // that maps large blocks directly (std.heap.smp_allocator).
        const page_runs = try r.reader.pageRuns(index);
        defer r.reader.endPageRuns();
        return encodePageText(rt.gpa, page_runs.runs, page_runs.unplaced_actual_text);
    }

    /// Closes every open handle (documents first, so their fonts are released).
    pub fn deinit(rt: *Runtime) void {
        for ([_]Kind{ .document, .font, .reader }) |kind| {
            for (rt.table.slots[0..rt.table.used], 0..) |s, i| {
                if (!s.open or s.kind != kind) continue;
                const handle = (s.generation << slot_bits) | @as(u32, @intCast(i));
                switch (kind) {
                    .document => rt.docClose(handle) catch unreachable,
                    .font => rt.fontClose(handle) catch unreachable,
                    .reader => rt.readerClose(handle) catch unreachable,
                    .free => unreachable,
                }
            }
        }
        rt.* = undefined;
    }
};

/// The wire form of zpdf_reader_page_text (TextHeader says it), owned by `gpa`. Each font name
/// is in the strings area once.
pub fn encodePageText(gpa: std.mem.Allocator, runs: []const zpdf.read.TextRun, unplaced_actual_text: u32) ![]u8 {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var strings: std.ArrayList(u8) = .empty;
    var font_at: std.StringHashMapUnmanaged(u32) = .empty;
    const run_at = try arena.alloc(struct { text: u32, font: u32 }, runs.len);
    var glyph_count: usize = 0;
    for (runs, run_at) |run, *at| {
        at.text = std.math.cast(u32, strings.items.len) orelse return error.TooLarge;
        try strings.appendSlice(arena, run.text);
        const font_entry = try font_at.getOrPut(arena, run.font);
        if (!font_entry.found_existing) {
            font_entry.value_ptr.* = std.math.cast(u32, strings.items.len) orelse return error.TooLarge;
            try strings.appendSlice(arena, run.font);
        }
        at.font = font_entry.value_ptr.*;
        glyph_count += run.glyphs.len;
    }
    const header: TextHeader = .{
        .run_count = std.math.cast(u32, runs.len) orelse return error.TooLarge,
        .glyph_count = std.math.cast(u32, glyph_count) orelse return error.TooLarge,
        .unplaced_actual_text = unplaced_actual_text,
        .strings_len = std.math.cast(u32, strings.items.len) orelse return error.TooLarge,
    };
    const runs_start = @sizeOf(TextHeader);
    const glyphs_start = runs_start + runs.len * @sizeOf(RunRecord);
    const strings_start = glyphs_start + glyph_count * @sizeOf(GlyphRecord);
    const out = try gpa.alloc(u8, strings_start + strings.items.len);
    putRecord(out, 0, header);
    var glyph: u32 = 0;
    for (runs, run_at, 0..) |run, at, i| {
        putRecord(out, runs_start + i * @sizeOf(RunRecord), RunRecord{
            .x = run.x,
            .y = run.y,
            .size = run.size,
            .width = run.width orelse std.math.nan(f64),
            .text_offset = at.text,
            .text_len = @intCast(run.text.len),
            .font_offset = at.font,
            .font_len = @intCast(run.font.len),
            .first_glyph = glyph,
            .glyph_count = @intCast(run.glyphs.len),
            .unmapped = run.unmapped,
            .flags = runFlags(run),
        });
        for (run.glyphs) |g| {
            putRecord(out, glyphs_start + glyph * @sizeOf(GlyphRecord), GlyphRecord{ .x = g.x, .y = g.y, .text_at = g.text_at, .reserved = 0 });
            glyph += 1;
        }
    }
    @memcpy(out[strings_start..], strings.items);
    return out;
}

/// The variations' wire form: 8 bytes each, the 4 tag bytes then a little-endian
/// f32. Owned by `allocator`.
pub fn parseVariationRecords(allocator: std.mem.Allocator, records: []const u8) ![]zpdf.Variation {
    if (records.len % 8 != 0) return error.InvalidVariation;
    const out = try allocator.alloc(zpdf.Variation, records.len / 8);
    for (out, 0..) |*v, i| {
        const record = records[i * 8 ..][0..8];
        v.* = .{ .tag = record[0..4].*, .value = @bitCast(std.mem.readInt(u32, record[4..8], .little)) };
    }
    return out;
}

/// Every error an export can return, with its code. A code never changes meaning; a new error
/// takes the next free code. Any other error is unknown_code.
pub const error_codes = [_]struct { anyerror, i32 }{
    .{ error.OutOfMemory, -1 },
    .{ error.InvalidUtf8, -2 },
    .{ error.InvalidFont, -3 },
    .{ error.TooManyOperations, -4 },
    .{ error.TooManyCids, -5 },
    .{ error.UnsupportedShaping, -6 },
    .{ error.UnsupportedFontFormat, -7 },
    .{ error.InvalidPage, -8 },
    .{ error.InvalidNumber, -9 },
    .{ error.WriteFailed, -10 },
    .{ error.UnsupportedAvarVersion, -11 },
    .{ error.DuplicateVariationTag, -12 },
    .{ error.InvalidVariation, -13 },
    .{ error.InvalidHandle, -14 },
    .{ error.TooManyHandles, -15 },
    .{ error.InvalidDirection, -16 },
    .{ error.FontMismatch, -17 },
    .{ error.PageOpen, -18 },
    .{ error.DocumentFinished, -19 },
    .{ error.DocumentFailed, -20 },
    .{ error.NotWinAnsi, -21 },
    .{ error.InvalidColor, -22 },
    .{ error.InvalidLater, -23 },
    .{ error.LaterDrawn, -24 },
    .{ error.LaterNotDrawn, -25 },
    .{ error.Malformed, -26 },
    .{ error.PasswordRequired, -27 },
    .{ error.UnsupportedFilter, -28 },
    .{ error.UnsupportedFont, -29 },
    .{ error.TooDeep, -30 },
    .{ error.TooLarge, -31 },
    .{ error.InvalidPointer, -32 },
    .{ error.ContextBusy, -33 },
    .{ error.BuffersOutstanding, -34 },
    .{ error.SinkFailed, -35 },
    .{ error.NotEmbedded, -36 },
    .{ error.InvalidImage, -37 },
    .{ error.UnsupportedImage, -38 },
    .{ error.UnsupportedEncryption, -39 },
    .{ error.MissingPage, -40 },
    .{ error.InvalidUri, -41 },
    .{ error.InvalidBookmark, -42 },
};
pub const unknown_code: i32 = -127;

comptime {
    @setEvalBranchQuota(10_000);
    for (error_codes, 0..) |a, i| {
        std.debug.assert(a[1] < 0 and a[1] != unknown_code);
        for (error_codes[i + 1 ..]) |b| std.debug.assert(a[0] != b[0] and a[1] != b[1]);
    }
}

pub fn mapError(err: anyerror) i32 {
    inline for (error_codes) |e| {
        if (err == e[0]) return e[1];
    }
    return unknown_code;
}

/// One caller's zpdf: a Runtime, the buffers it gave out, and the guard against two threads.
pub const Context = struct {
    /// magic_value while the context lives, so a freed or foreign pointer is usually refused.
    magic: u32,
    busy: Busy,
    /// Allocates the context and its buffer records; not counted in live_bytes.
    base: std.mem.Allocator,
    /// Native builds: freed large blocks kept for reuse, under `counting`, so live_bytes counts
    /// only what is in use (block_cache.zig says why). wasm's allocator keeps them itself.
    blocks: BlockCache,
    counting: Counting,
    rt: Runtime,
    /// Each buffer the caller holds, pointer to length.
    buffers: std.AutoHashMapUnmanaged(usize, usize),

    const magic_value: u32 = 0x4644505a;

    /// The most freed large-block bytes a context keeps for reuse: several pages' output and work
    /// blocks, with what is above given back.
    const max_cached_block_bytes = 8 << 20;

    /// An atomic flag; a plain one where there is one thread (wasm32 has no atomics).
    const Busy = if (builtin.single_threaded) struct {
        value: bool = false,
        fn swap(self: *@This(), v: bool) bool {
            defer self.value = v;
            return self.value;
        }
        fn store(self: *@This(), v: bool) void {
            self.value = v;
        }
    } else struct {
        value: std.atomic.Value(bool) = .init(false),
        fn swap(self: *@This(), v: bool) bool {
            return self.value.swap(v, .acquire);
        }
        fn store(self: *@This(), v: bool) void {
            self.value.store(v, .release);
        }
    };

    pub fn create(base: std.mem.Allocator) !*Context {
        const c = try base.create(Context);
        c.* = .{ .magic = magic_value, .busy = .{}, .base = base, .blocks = .init(base, max_cached_block_bytes), .counting = .{ .child = base }, .rt = undefined, .buffers = .empty };
        if (!is_wasm) c.counting.child = c.blocks.allocator();
        c.rt = .{ .gpa = c.counting.allocator() };
        return c;
    }

    /// Closes every handle and frees the context. Buffers still out are not freed.
    pub fn destroy(c: *Context) void {
        c.rt.deinit();
        c.blocks.deinit();
        c.buffers.deinit(c.base);
        c.magic = 0;
        c.base.destroy(c);
    }

    fn enter(ctx: ?*Context) !*Context {
        const c = ctx orelse return error.InvalidHandle;
        if (c.magic != magic_value) return error.InvalidHandle;
        if (c.busy.swap(true)) return error.ContextBusy;
        return c;
    }

    fn leave(c: *Context) void {
        c.busy.store(false);
    }

    /// Hands `bytes` (from rt.gpa) to the caller. Needs room for one more record: reserve it
    /// before the work, so a finished document's PDF cannot be lost to a full table.
    fn give(c: *Context, out: OutBuffer, bytes: []u8) void {
        if (bytes.len == 0) {
            c.rt.gpa.free(bytes);
            return;
        }
        c.buffers.putAssumeCapacityNoClobber(@intFromPtr(bytes.ptr), bytes.len);
        out.ptr.* = bytes.ptr;
        out.len.* = bytes.len;
    }

    fn reserveBuffer(c: *Context) !void {
        try c.buffers.ensureUnusedCapacity(c.base, 1);
    }

    fn takeBack(c: *Context, ptr: ?[*]u8, len: usize) !void {
        if (len == 0) return;
        const p = ptr orelse return error.InvalidPointer;
        const entry = c.buffers.getEntry(@intFromPtr(p)) orelse return error.InvalidPointer;
        if (entry.value_ptr.* != len) return error.InvalidPointer;
        c.buffers.removeByPtr(entry.key_ptr);
        c.rt.gpa.free(p[0..len]);
    }
};

/// The pointer `ptr` with `len` bytes; null is allowed only for 0 bytes.
fn input(ptr: ?[*]const u8, len: usize) ![]const u8 {
    if (len == 0) return &.{};
    return (ptr orelse return error.InvalidPointer)[0..len];
}

/// The output `p`, set to zero.
fn output(comptime T: type, p: ?*T) !*T {
    const out = p orelse return error.InvalidPointer;
    out.* = std.mem.zeroes(T);
    return out;
}

const OutBuffer = struct { ptr: *?[*]u8, len: *usize };

fn outputBuffer(ptr: ?*?[*]u8, len: ?*usize) !OutBuffer {
    // Both are zeroed before either is refused; output() zeroes the pointer before the length
    // is looked at.
    if (len) |l| l.* = 0;
    return .{ .ptr = try output(?[*]u8, ptr), .len = try output(usize, len) };
}

fn rgb(r: f64, g: f64, b: f64) zpdf.Color {
    return .{ .r = r, .g = g, .b = b };
}

/// zpdf.wasm's panic message, for JS to read before it drops the instance.
var panic_buf: [512]u8 = undefined;
var panic_len: usize = 0;

/// An export's direction number (0 from the text, 1 left to right, 2 right to left) as zpdf's.
/// Any other number is InvalidDirection whichever font draws the text: a standard font is not
/// shaped, so zpdf.shape's own check never sees it.
fn toDirection(n: u32) error{InvalidDirection}!zpdf.Direction {
    return switch (n) {
        0 => .dont_know,
        1 => .ltr,
        2 => .rtl,
        else => error.InvalidDirection,
    };
}

/// zpdf.wasm's panic handler (see `panic` in root.zig): keeps the message, then traps.
pub fn capturePanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    const n = @min(msg.len, panic_buf.len);
    @memcpy(panic_buf[0..n], msg[0..n]);
    panic_len = n;
    @trap();
}

/// Where a new context's memory comes from (zpdf.read.system_allocator says which, per build).
const base_allocator = zpdf.read.system_allocator;

/// The exports both builds have. tools/gen-abi.zig writes zpdf.h and the C# declarations from
/// these: each doc comment goes with its function.
pub const exports = struct {
    /// abi_version. A caller checks it once, when it loads the library.
    pub fn zpdf_abi_version() callconv(.c) u32 {
        return abi_version;
    }

    /// The name of error code `code` ("InvalidFont"), "Unknown" for unknown_code, or null for a
    /// code zpdf never returns. The string is static.
    pub fn zpdf_error_name(code: i32) callconv(.c) ?[*:0]const u8 {
        if (code == unknown_code) return "Unknown";
        inline for (error_codes) |e| {
            if (code == e[1]) return @errorName(e[0]);
        }
        return null;
    }

    /// A new context, for zpdf_context_free to free; null when out of memory. It returns the
    /// pointer, not a status, because a wasm caller has no memory of its own to receive it.
    pub fn zpdf_context_new() callconv(.c) ?*Context {
        return Context.create(base_allocator) catch null;
    }

    /// Closes every handle in the context and frees it. BuffersOutstanding, with nothing done,
    /// while a buffer the context gave out has not been freed.
    pub fn zpdf_context_free(ctx: ?*Context) callconv(.c) i32 {
        const c = Context.enter(ctx) catch |err| return mapError(err);
        if (c.buffers.count() != 0) {
            c.leave();
            return mapError(error.BuffersOutstanding);
        }
        c.destroy();
        return 0;
    }

    /// A buffer of `len` bytes for the caller to fill, freed with zpdf_free; null for 0 bytes,
    /// when out of memory, or for a context zpdf_live_bytes refuses. For wasm, where an input
    /// must be in the instance's memory, and where it returns the pointer for the reason
    /// zpdf_context_new does. A native caller passes its own memory instead.
    pub fn zpdf_alloc(ctx: ?*Context, len: usize) callconv(.c) ?[*]u8 {
        const c = Context.enter(ctx) catch return null;
        defer c.leave();
        if (len == 0) return null;
        c.reserveBuffer() catch return null;
        const bytes = c.rt.gpa.alloc(u8, len) catch return null;
        c.buffers.putAssumeCapacityNoClobber(@intFromPtr(bytes.ptr), len);
        return bytes.ptr;
    }

    /// Gives back a buffer from zpdf_alloc or from an output, with the length it had.
    pub fn zpdf_free(ctx: ?*Context, ptr: ?[*]u8, len: usize) callconv(.c) i32 {
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.takeBack(ptr, len) catch |err| return mapError(err);
        return 0;
    }

    /// Bytes the context has allocated and not freed: its objects and the buffers the caller
    /// holds, kb's memory included. In wasm the memory itself never shrinks: freed memory is
    /// reused, not returned to the browser.
    pub fn zpdf_live_bytes(ctx: ?*Context, out: ?*usize) callconv(.c) i32 {
        const o = output(usize, out) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        o.* = c.counting.live;
        return 0;
    }

    /// Opens a font file (TrueType or OpenType; `index` picks a face of a collection). The
    /// bytes are copied. `variations`: 8 bytes each, the 4 tag bytes then an f32, with
    /// zpdf.Font.init's rules.
    pub fn zpdf_font_open(ctx: ?*Context, bytes: ?[*]const u8, len: usize, index: i32, variations: ?[*]const u8, variations_len: usize, out: ?*u32) callconv(.c) i32 {
        const o = output(u32, out) catch |err| return mapError(err);
        const font = input(bytes, len) catch |err| return mapError(err);
        const records = input(variations, variations_len) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        o.* = c.rt.fontOpen(font, index, records) catch |err| return mapError(err);
        return 0;
    }

    /// One of the standard fonts as a font handle: standard is zpdf.StandardFont's order (0
    /// Helvetica ... 11 Courier-BoldOblique). It can be measured, wrapped and added to a document;
    /// shaping, outlines, axes and units per em need a font file (NotEmbedded).
    pub fn zpdf_font_open_standard(ctx: ?*Context, standard: u32, out: ?*u32) callconv(.c) i32 {
        const o = output(u32, out) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        o.* = c.rt.fontOpenStandard(standard) catch |err| return mapError(err);
        return 0;
    }

    /// A document that uses the font keeps it alive until the document closes.
    pub fn zpdf_font_close(ctx: ?*Context, font: u32) callconv(.c) i32 {
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.rt.fontClose(font) catch |err| return mapError(err);
        return 0;
    }

    pub fn zpdf_font_units_per_em(ctx: ?*Context, font: u32, out: ?*u32) callconv(.c) i32 {
        const o = output(u32, out) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        o.* = c.rt.fontUnitsPerEm(font) catch |err| return mapError(err);
        return 0;
    }

    /// The width of `text` (UTF-8) at `size` points, as one run with no breaks, in points.
    /// direction as in zpdf_font_shape. A standard font's text must be WinAnsi (NotWinAnsi).
    pub fn zpdf_font_measure(ctx: ?*Context, font: u32, size: f64, text: ?[*]const u8, len: usize, direction: u32, out: ?*f64) callconv(.c) i32 {
        const o = output(f64, out) catch |err| return mapError(err);
        const t = input(text, len) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        o.* = c.rt.fontMeasure(font, size, t, direction) catch |err| return mapError(err);
        return 0;
    }

    /// The lines `text` (UTF-8) wraps to at `max_width` points: a WrapHeader, then a LineRecord
    /// per line. The rules are zpdf.text_layout's: breaks after spaces and around CJK, forced
    /// breaks at line ends, trailing spaces dropped. flags bit 0 breaks a word wider than the line
    /// between characters; without it such a word stands alone on a line wider than max_width.
    pub fn zpdf_font_wrap(ctx: ?*Context, font: u32, size: f64, text: ?[*]const u8, len: usize, direction: u32, max_width: f64, flags: u32, out_ptr: ?*?[*]u8, out_len: ?*usize) callconv(.c) i32 {
        const o = outputBuffer(out_ptr, out_len) catch |err| return mapError(err);
        const t = input(text, len) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.reserveBuffer() catch |err| return mapError(err);
        c.give(o, c.rt.fontWrap(font, size, t, direction, max_width, flags) catch |err| return mapError(err));
        return 0;
    }

    /// How far the font reaches above and below the baseline, in em (1.0 is the font size): a
    /// standard font's AFM Ascender and Descender, an embedded font's hhea ascender and descender
    /// at its instance. The descender is below the baseline, so usually negative.
    pub fn zpdf_font_vertical_metrics(ctx: ?*Context, font: u32, out_ascender: ?*f64, out_descender: ?*f64) callconv(.c) i32 {
        const a = output(f64, out_ascender) catch |err| return mapError(err);
        const d = output(f64, out_descender) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        const v = c.rt.fontVerticalMetrics(font) catch |err| return mapError(err);
        a.* = v.ascender;
        d.* = v.descender;
        return 0;
    }

    /// The byte offset in `text` (UTF-8) of the first character the font cannot draw, or len when
    /// it can draw them all. A standard font draws WinAnsi characters; an embedded font cannot draw
    /// a character its shaping maps to glyph 0. direction as in zpdf_font_shape.
    pub fn zpdf_font_first_missing(ctx: ?*Context, font: u32, text: ?[*]const u8, len: usize, direction: u32, out: ?*usize) callconv(.c) i32 {
        const o = output(usize, out) catch |err| return mapError(err);
        const t = input(text, len) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        o.* = c.rt.fontFirstMissing(font, t, direction) catch |err| return mapError(err);
        return 0;
    }

    /// The longest prefix of `text` (UTF-8) that fits `max_width` points at `size`, as one run:
    /// its length in bytes (always at the end of a character) and its width, the one
    /// zpdf_font_measure gives it. For truncating with an ellipsis, pass the width less the
    /// ellipsis's. max_width is finite and not negative (InvalidNumber).
    pub fn zpdf_font_fit(ctx: ?*Context, font: u32, size: f64, text: ?[*]const u8, len: usize, direction: u32, max_width: f64, out_len: ?*usize, out_width: ?*f64) callconv(.c) i32 {
        const l = output(usize, out_len) catch |err| return mapError(err);
        const w = output(f64, out_width) catch |err| return mapError(err);
        const t = input(text, len) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        const kept = c.rt.fontFit(font, size, t, direction, max_width) catch |err| return mapError(err);
        l.* = kept.len;
        w.* = kept.width;
        return 0;
    }

    /// The font's name as ASCII: a standard font's base font name (Helvetica-Bold), an embedded
    /// font's PostScript name at its instance. A buffer the caller frees with zpdf_free.
    pub fn zpdf_font_name(ctx: ?*Context, font: u32, out_ptr: ?*?[*]u8, out_len: ?*usize) callconv(.c) i32 {
        const o = outputBuffer(out_ptr, out_len) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.reserveBuffer() catch |err| return mapError(err);
        c.give(o, c.rt.fontName(font) catch |err| return mapError(err));
        return 0;
    }

    /// AxisRecords, one per axis.
    pub fn zpdf_font_axes(ctx: ?*Context, font: u32, out_ptr: ?*?[*]u8, out_len: ?*usize) callconv(.c) i32 {
        const o = outputBuffer(out_ptr, out_len) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.reserveBuffer() catch |err| return mapError(err);
        c.give(o, c.rt.fontAxes(font) catch |err| return mapError(err));
        return 0;
    }

    /// Shapes one line of UTF-8. direction: 0 from the text, 1 left to right, 2 right to left.
    /// A ShapeHeader, then a ShapedGlyph per glyph.
    pub fn zpdf_font_shape(ctx: ?*Context, font: u32, text: ?[*]const u8, len: usize, direction: u32, out_ptr: ?*?[*]u8, out_len: ?*usize) callconv(.c) i32 {
        const o = outputBuffer(out_ptr, out_len) catch |err| return mapError(err);
        const t = input(text, len) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.reserveBuffer() catch |err| return mapError(err);
        c.give(o, c.rt.fontShape(font, t, direction) catch |err| return mapError(err));
        return 0;
    }

    /// Glyph `glyph`'s outline as PathRecords.
    pub fn zpdf_font_glyph_path(ctx: ?*Context, font: u32, glyph: u32, out_ptr: ?*?[*]u8, out_len: ?*usize) callconv(.c) i32 {
        const o = outputBuffer(out_ptr, out_len) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.reserveBuffer() catch |err| return mapError(err);
        c.give(o, c.rt.fontGlyphPath(font, glyph) catch |err| return mapError(err));
        return 0;
    }

    /// A new document (zpdf.Document: one page open at a time; each page is written when it
    /// ends, the fonts and the rest by zpdf_doc_finish). compress: 0 for plain streams, else
    /// Flate.
    pub fn zpdf_doc_new(ctx: ?*Context, compress: u32, out: ?*u32) callconv(.c) i32 {
        const o = output(u32, out) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        o.* = c.rt.docNew(compress != 0) catch |err| return mapError(err);
        return 0;
    }

    /// A new document that writes into `sink` instead of a buffer (the module doc's Sinks says
    /// how). `sink` is copied, and must be in exactly one mode (Sink says). compress: as
    /// zpdf_doc_new's.
    pub fn zpdf_doc_new_sink(ctx: ?*Context, compress: u32, sink: ?*const Sink, out: ?*u32) callconv(.c) i32 {
        const o = output(u32, out) catch |err| return mapError(err);
        const s = sink orelse return mapError(error.InvalidPointer);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        o.* = c.rt.docNewSink(compress != 0, s.*) catch |err| return mapError(err);
        return 0;
    }

    /// The document's id for the font, for drawing.
    pub fn zpdf_doc_add_font(ctx: ?*Context, doc: u32, font: u32, out_font_id: ?*u32) callconv(.c) i32 {
        const o = output(u32, out_font_id) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        o.* = c.rt.docAddFont(doc, font) catch |err| return mapError(err);
        return 0;
    }

    pub fn zpdf_doc_begin_page(ctx: ?*Context, doc: u32, width: f64, height: f64, out_page_id: ?*u32) callconv(.c) i32 {
        const o = output(u32, out_page_id) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        o.* = c.rt.docBeginPage(doc, width, height) catch |err| return mapError(err);
        return 0;
    }

    /// One line of UTF-8 at (x, y). direction as in zpdf_font_shape.
    pub fn zpdf_doc_draw_text(ctx: ?*Context, doc: u32, page_id: u32, font_id: u32, size: f64, x: f64, y: f64, r: f64, g: f64, b: f64, text: ?[*]const u8, len: usize, direction: u32) callconv(.c) i32 {
        const t = input(text, len) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.rt.docDrawText(doc, page_id, font_id, size, x, y, rgb(r, g, b), t, direction) catch |err| return mapError(err);
        return 0;
    }

    /// A place on the page for text drawn later, such as "Page 3 of 12" (zpdf.Document's
    /// reserveLater). Every place must be drawn before zpdf_doc_finish.
    pub fn zpdf_doc_reserve_later(ctx: ?*Context, doc: u32, page_id: u32, out_later_id: ?*u32) callconv(.c) i32 {
        const o = output(u32, out_later_id) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        o.* = c.rt.docReserveLater(doc, page_id) catch |err| return mapError(err);
        return 0;
    }

    /// Draws the text of a place from zpdf_doc_reserve_later, once; its page can have ended.
    pub fn zpdf_doc_draw_text_later(ctx: ?*Context, doc: u32, later_id: u32, font_id: u32, size: f64, x: f64, y: f64, r: f64, g: f64, b: f64, text: ?[*]const u8, len: usize, direction: u32) callconv(.c) i32 {
        const t = input(text, len) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.rt.docDrawTextLater(doc, later_id, font_id, size, x, y, rgb(r, g, b), t, direction) catch |err| return mapError(err);
        return 0;
    }

    /// Adds a JPEG or PNG image to the document and writes it now (zpdf.Document.addImage; the
    /// bytes are read only during the call). The id draws it on any page of this document. A file
    /// zpdf refuses is InvalidImage, UnsupportedImage or TooLarge, and adds nothing.
    pub fn zpdf_doc_add_image(ctx: ?*Context, doc: u32, bytes: ?[*]const u8, len: usize, out_image_id: ?*u32) callconv(.c) i32 {
        const o = output(u32, out_image_id) catch |err| return mapError(err);
        const b = input(bytes, len) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        o.* = c.rt.docAddImage(doc, b) catch |err| return mapError(err);
        return 0;
    }

    /// The image's size in pixels as it is shown, after its Exif orientation.
    pub fn zpdf_doc_image_size(ctx: ?*Context, doc: u32, image_id: u32, out_width: ?*u32, out_height: ?*u32) callconv(.c) i32 {
        const w = output(u32, out_width) catch |err| return mapError(err);
        const h = output(u32, out_height) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        const size = c.rt.docImageSize(doc, image_id) catch |err| return mapError(err);
        w.* = size.width;
        h.* = size.height;
        return 0;
    }

    /// Draws the image stretched over the rectangle with bottom-left (x, y), turned as its Exif
    /// orientation says.
    pub fn zpdf_doc_draw_image(ctx: ?*Context, doc: u32, page_id: u32, image_id: u32, x: f64, y: f64, width: f64, height: f64) callconv(.c) i32 {
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.rt.docDrawImage(doc, page_id, image_id, x, y, width, height) catch |err| return mapError(err);
        return 0;
    }

    /// Makes the rectangle with bottom-left (x, y), width by height, on the open page a link to a
    /// URI: printable ASCII with no space (percent-encode the rest), else InvalidUri. The area has
    /// no border: draw what shows it (zpdf.Document's addLink).
    pub fn zpdf_doc_add_link_uri(ctx: ?*Context, doc: u32, page_id: u32, x: f64, y: f64, width: f64, height: f64, uri: ?[*]const u8, len: usize) callconv(.c) i32 {
        const u = input(uri, len) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.rt.docAddLink(doc, page_id, x, y, width, height, .{ .uri = u }) catch |err| return mapError(err);
        return 0;
    }

    /// The same, a link to page target_page (0 is the first; a page not begun yet is allowed)
    /// shown with (dest_x, dest_y) at the window's top left, the zoom unchanged. zpdf_doc_finish
    /// is MissingPage while a page a link or bookmark goes to has not been begun.
    pub fn zpdf_doc_add_link_page(ctx: ?*Context, doc: u32, page_id: u32, x: f64, y: f64, width: f64, height: f64, target_page: u32, dest_x: f64, dest_y: f64) callconv(.c) i32 {
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.rt.docAddLink(doc, page_id, x, y, width, height, .{ .page = .{ .page_index = target_page, .x = dest_x, .y = dest_y } }) catch |err| return mapError(err);
        return 0;
    }

    /// Adds a bookmark titled with UTF-8 `title` that goes to target_page as in
    /// zpdf_doc_add_link_page: at the top level when parent is 0, else as the last child of the
    /// bookmark whose id parent is (InvalidBookmark otherwise). open (0 or 1) shows its children
    /// at first. Ids start at 1. Any time before zpdf_doc_finish, a page open or not.
    pub fn zpdf_doc_add_bookmark(ctx: ?*Context, doc: u32, parent: u32, title: ?[*]const u8, len: usize, target_page: u32, dest_x: f64, dest_y: f64, open: u32, out_bookmark_id: ?*u32) callconv(.c) i32 {
        const o = output(u32, out_bookmark_id) catch |err| return mapError(err);
        const t = input(title, len) catch |err| return mapError(err);
        if (open > 1) return mapError(error.InvalidNumber);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        o.* = c.rt.docAddBookmark(doc, parent, t, .{ .page_index = target_page, .x = dest_x, .y = dest_y }, open == 1) catch |err| return mapError(err);
        return 0;
    }

    pub fn zpdf_doc_draw_line(ctx: ?*Context, doc: u32, page_id: u32, x1: f64, y1: f64, x2: f64, y2: f64, width: f64, r: f64, g: f64, b: f64) callconv(.c) i32 {
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.rt.docDrawLine(doc, page_id, x1, y1, x2, y2, width, rgb(r, g, b)) catch |err| return mapError(err);
        return 0;
    }

    pub fn zpdf_doc_fill_rect(ctx: ?*Context, doc: u32, page_id: u32, x: f64, y: f64, width: f64, height: f64, r: f64, g: f64, b: f64) callconv(.c) i32 {
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.rt.docFillRect(doc, page_id, x, y, width, height, rgb(r, g, b)) catch |err| return mapError(err);
        return 0;
    }

    pub fn zpdf_doc_stroke_rect(ctx: ?*Context, doc: u32, page_id: u32, x: f64, y: f64, width: f64, height: f64, line_width: f64, r: f64, g: f64, b: f64) callconv(.c) i32 {
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.rt.docStrokeRect(doc, page_id, x, y, width, height, line_width, rgb(r, g, b)) catch |err| return mapError(err);
        return 0;
    }

    /// Writes the page and frees its drawing.
    pub fn zpdf_doc_end_page(ctx: ?*Context, doc: u32, page_id: u32) callconv(.c) i32 {
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.rt.docEndPage(doc, page_id) catch |err| return mapError(err);
        return 0;
    }

    /// The bytes the document has written since the last take, or since it began: a null
    /// buffer when there are none. Take after each zpdf_doc_end_page and pass the bytes on, and
    /// the context holds one page of the PDF, not the document. The bytes of every take and then
    /// of zpdf_doc_finish, in order, are the PDF.
    pub fn zpdf_doc_take(ctx: ?*Context, doc: u32, out_ptr: ?*?[*]u8, out_len: ?*usize) callconv(.c) i32 {
        const o = outputBuffer(out_ptr, out_len) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.reserveBuffer() catch |err| return mapError(err);
        c.give(o, c.rt.docTake(doc) catch |err| return mapError(err));
        return 0;
    }

    /// The rest of the PDF after the last zpdf_doc_take (the whole PDF when nothing was taken),
    /// once.
    pub fn zpdf_doc_finish(ctx: ?*Context, doc: u32, out_ptr: ?*?[*]u8, out_len: ?*usize) callconv(.c) i32 {
        const o = outputBuffer(out_ptr, out_len) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.reserveBuffer() catch |err| return mapError(err);
        c.give(o, c.rt.docFinish(doc) catch |err| return mapError(err));
        return 0;
    }

    pub fn zpdf_doc_close(ctx: ?*Context, doc: u32) callconv(.c) i32 {
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.rt.docClose(doc) catch |err| return mapError(err);
        return 0;
    }

    /// Opens a PDF to read (zpdf.read.Reader, default limits). The bytes are copied. An encrypted
    /// file opens when its user password is empty, as most are; one that needs a password is
    /// PasswordRequired, one with an encryption zpdf does not read UnsupportedEncryption, and a
    /// file it cannot parse Malformed and the others.
    pub fn zpdf_reader_open(ctx: ?*Context, bytes: ?[*]const u8, len: usize, out: ?*u32) callconv(.c) i32 {
        const o = output(u32, out) catch |err| return mapError(err);
        const pdf = input(bytes, len) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        o.* = c.rt.readerOpen(pdf) catch |err| return mapError(err);
        return 0;
    }

    pub fn zpdf_reader_close(ctx: ?*Context, reader: u32) callconv(.c) i32 {
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.rt.readerClose(reader) catch |err| return mapError(err);
        return 0;
    }

    pub fn zpdf_reader_page_count(ctx: ?*Context, reader: u32, out: ?*u32) callconv(.c) i32 {
        const o = output(u32, out) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        o.* = c.rt.readerPageCount(reader) catch |err| return mapError(err);
        return 0;
    }

    /// Page `index` (from 0). InvalidPage past the last page.
    pub fn zpdf_reader_page(ctx: ?*Context, reader: u32, index: u32, out: ?*PageInfo) callconv(.c) i32 {
        const o = output(PageInfo, out) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        o.* = c.rt.readerPage(reader, index) catch |err| return mapError(err);
        return 0;
    }

    /// The text page `index` draws: a TextHeader and what it says follows. A page that cannot
    /// be read fails with the reader's error, and the other pages stay readable.
    pub fn zpdf_reader_page_text(ctx: ?*Context, reader: u32, index: u32, out_ptr: ?*?[*]u8, out_len: ?*usize) callconv(.c) i32 {
        const o = outputBuffer(out_ptr, out_len) catch |err| return mapError(err);
        const c = Context.enter(ctx) catch |err| return mapError(err);
        defer c.leave();
        c.reserveBuffer() catch |err| return mapError(err);
        c.give(o, c.rt.readerPageText(reader, index) catch |err| return mapError(err));
        return 0;
    }
};

/// The exports only zpdf.wasm has.
const wasm_exports = struct {
    pub fn zpdf_wasm_panic_ptr() callconv(.c) usize {
        return @intFromPtr(&panic_buf);
    }

    pub fn zpdf_wasm_panic_len() callconv(.c) usize {
        return panic_len;
    }

    /// Only in the test build (zpdf-test.wasm): a Zig panic on demand, for the
    /// browser test of the trap policy.
    pub fn zpdf_wasm_test_panic() callconv(.c) void {
        @panic("zpdf_wasm_test_panic");
    }

    /// Only in the test build: recursion `depth` deep with frames too small to
    /// touch the wasm stack, so the engine's own stack limit stops it, with a
    /// RangeError, not a RuntimeError.
    pub fn zpdf_wasm_test_recurse(depth: u32) callconv(.c) u32 {
        return test_recurse(depth);
    }
};

// Called through a mutable pointer, so the optimizer cannot turn the recursion
// into a loop.
var test_recurse: *const fn (u32) callconv(.c) u32 = &testRecurse;
fn testRecurse(depth: u32) callconv(.c) u32 {
    if (depth == 0) return 0;
    // A volatile read: the pointer is never written, and without this the
    // optimizer would call testRecurse directly and make the recursion a loop.
    const next = @as(*const volatile @TypeOf(test_recurse), &test_recurse).*;
    return 1 +% next(depth - 1);
}

/// Exports every function in `exports`, and on wasm32 those in `wasm_exports`
/// (zpdf_wasm_test_* only in the test build). root.zig calls this from a comptime block.
pub fn exportAll() void {
    inline for (@typeInfo(exports).@"struct".decl_names) |name| {
        @export(&@field(exports, name), .{ .name = name });
    }
    if (!is_wasm) return;
    inline for (@typeInfo(wasm_exports).@"struct".decl_names) |name| {
        if (comptime std.mem.startsWith(u8, name, "zpdf_wasm_test_") and !abi_options.test_exports) continue;
        @export(&@field(wasm_exports, name), .{ .name = name });
    }
}

test "Table: a closed, stale or wrong-kind handle is InvalidHandle, and handles are never 0" {
    var table: Table = .{};
    var a: u8 = 0;
    var b: u8 = 0;
    const h1 = try table.acquire(.font, &a);
    try std.testing.expect(h1 != 0);
    try std.testing.expect((try table.lookup(h1, .font)).object == @as(*anyopaque, &a));
    try std.testing.expectError(error.InvalidHandle, table.lookup(h1, .document));
    try std.testing.expectError(error.InvalidHandle, table.lookup(0, .font));
    try std.testing.expect(try table.close(h1, .font) == @as(*anyopaque, &a));
    try std.testing.expectError(error.InvalidHandle, table.lookup(h1, .font));
    try std.testing.expectError(error.InvalidHandle, table.close(h1, .font));
    // The slot is reused under a new generation; the old handle stays dead.
    const h2 = try table.acquire(.font, &b);
    try std.testing.expectEqual(h1 & (slot_count - 1), h2 & (slot_count - 1));
    try std.testing.expect(h1 != h2);
    try std.testing.expectError(error.InvalidHandle, table.lookup(h1, .font));
    _ = try table.lookup(h2, .font);
}

test "Table: a referenced font outlives its handle; a used-up generation is never reused" {
    var table: Table = .{};
    var x: u8 = 0;
    const h = try table.acquire(.font, &x);
    const s = try table.lookup(h, .font);
    Table.retain(s);
    try std.testing.expect(try table.close(h, .font) == null);
    try std.testing.expectError(error.InvalidHandle, table.lookup(h, .font));
    try std.testing.expect(table.unref(table.indexOf(s)) == @as(*anyopaque, &x));
    try std.testing.expectEqual(@as(u32, 0), table.free_head);

    const last = try table.acquire(.font, &x);
    table.slots[last & (slot_count - 1)].generation = max_generation;
    const at_max = (max_generation << slot_bits) | (last & (slot_count - 1));
    _ = try table.close(at_max, .font);
    try std.testing.expectEqual(no_slot, table.free_head);
    try std.testing.expectError(error.InvalidHandle, table.lookup(at_max, .font));
    const next = try table.acquire(.font, &x);
    try std.testing.expect(next & (slot_count - 1) != last & (slot_count - 1));
}

test "Table: TooManyHandles past 1024 open objects" {
    var table: Table = .{};
    var x: u8 = 0;
    for (0..slot_count) |_| _ = try table.acquire(.document, &x);
    try std.testing.expectError(error.TooManyHandles, table.acquire(.document, &x));
}

fn loadTestFont(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
}

test "Runtime: the wire results equal the Zig API's, and closing everything frees every byte" {
    const options = @import("build_options");
    const bytes = try loadTestFont(options.test_font_variable);
    defer std.testing.allocator.free(bytes);
    var records: [16]u8 = undefined;
    @memcpy(records[0..4], "opsz");
    std.mem.writeInt(u32, records[4..8], @bitCast(@as(f32, 144)), .little);
    @memcpy(records[8..12], "wght");
    std.mem.writeInt(u32, records[12..16], @bitCast(@as(f32, 100)), .little);
    const variations = [_]zpdf.Variation{ .{ .tag = "opsz".*, .value = 144 }, .{ .tag = "wght".*, .value = 100 } };

    var count: Counting = .{ .child = std.testing.allocator };
    var r: Runtime = .{ .gpa = count.allocator() };
    defer r.deinit();
    const f = try r.fontOpen(bytes, 0, &records);

    // The direct API, for comparison.
    var font = try zpdf.Font.init(std.testing.allocator, bytes, 0, &variations);
    defer font.deinit();

    try std.testing.expectEqual(@as(u16, 2000), try r.fontUnitsPerEm(f));

    const wire = try r.fontShape(f, "office", 0);
    var shaped = try zpdf.shape(std.testing.allocator, &font, "office", .{});
    defer shaped.deinit(std.testing.allocator);
    try std.testing.expectEqual(8 + shaped.glyphs.len * 16, wire.len);
    var pen: zpdf.Pen = .{};
    for (shaped.glyphs, 0..) |g, i| {
        const o = pen.place(g);
        const rec = wire[8 + i * 16 ..][0..16];
        try std.testing.expectEqual(@as(u32, g.id), std.mem.readInt(u32, rec[0..4], .little));
        try std.testing.expectEqual(g.cluster, std.mem.readInt(u32, rec[4..8], .little));
        try std.testing.expectEqual(o.x, std.mem.readInt(i32, rec[8..12], .little));
        try std.testing.expectEqual(o.y, std.mem.readInt(i32, rec[12..16], .little));
    }
    try std.testing.expectEqual(pen.x, std.mem.readInt(i32, wire[0..4], .little));

    var outlines = try font.outlines(std.testing.allocator);
    defer outlines.deinit();
    const want_path = try outlines.path(std.testing.allocator, shaped.glyphs[0].id);
    defer std.testing.allocator.free(want_path);
    const path = try r.fontGlyphPath(f, shaped.glyphs[0].id);
    try std.testing.expectEqual(want_path.len * 40, path.len);
    for (want_path, 0..) |c, i| {
        const rec = path[i * 40 ..][0..40];
        const x: f64 = @bitCast(std.mem.readInt(u64, rec[8..16], .little));
        switch (c) {
            .move => |p| try std.testing.expect(std.mem.readInt(u32, rec[0..4], .little) == 0 and x == p.x),
            .line => |p| try std.testing.expect(std.mem.readInt(u32, rec[0..4], .little) == 1 and x == p.x),
            .quad => |q| try std.testing.expect(std.mem.readInt(u32, rec[0..4], .little) == 2 and x == q.control.x),
            .close => try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, rec[0..4], .little)),
        }
    }

    // A document through handles writes the PDF the Document API writes.
    const d = try r.docNew(true);
    const id = try r.docAddFont(d, f);
    const page = try r.docBeginPage(d, 612, 792);
    const teal: zpdf.Color = .{ .r = 0, .g = 0.5, .b = 0.5 };
    try r.docDrawText(d, page, id, 24, 72, 720, .black, "office", 0);
    try r.docDrawText(d, page, id, 12, 72, 700, teal, "office", 0);
    try r.docDrawLine(d, page, 72, 690, 540, 690, 0.5, teal);
    try r.docFillRect(d, page, 72, 600, 100, 50, teal);
    try r.docStrokeRect(d, page, 72, 600, 100, 50, 2, .black);
    try std.testing.expectError(error.InvalidColor, r.docFillRect(d, page, 72, 600, 100, 50, .{ .r = 2, .g = 0, .b = 0 }));
    const later = try r.docReserveLater(d, page);
    // The font handle closes first; the document keeps the font alive.
    try r.fontClose(f);
    try std.testing.expectError(error.InvalidHandle, r.fontShape(f, "x", 0));
    try r.docEndPage(d, page);
    try std.testing.expectError(error.LaterNotDrawn, r.docFinish(d));
    try r.docDrawTextLater(d, later, id, 9, 300, 40, teal, "Page 1 of 1", 0);
    try std.testing.expectError(error.LaterDrawn, r.docDrawTextLater(d, later, id, 9, 300, 40, teal, "Page 1 of 1", 0));
    const pdf = try r.docFinish(d);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var direct = try zpdf.Document.begin(std.testing.allocator, &aw.writer, .{ .compress = true });
    defer direct.deinit();
    const did = try direct.addFont(&font);
    const dpage = try direct.beginPage(612, 792);
    try direct.drawText(dpage, did, 24, 72, 720, .black, "office", .{});
    try direct.drawText(dpage, did, 12, 72, 700, teal, "office", .{});
    try direct.drawLine(dpage, 72, 690, 540, 690, 0.5, teal);
    try direct.fillRect(dpage, 72, 600, 100, 50, teal);
    try direct.strokeRect(dpage, 72, 600, 100, 50, 2, .black);
    const dlater = try direct.reserveLater(dpage);
    try direct.endPage(dpage);
    try direct.drawTextLater(dlater, did, 9, 300, 40, teal, "Page 1 of 1", .{});
    try direct.finish();
    try std.testing.expectEqualSlices(u8, aw.written(), pdf);

    r.gpa.free(pdf);
    r.gpa.free(path);
    r.gpa.free(wire);
    try r.docClose(d);
    // Every buffer is freed and every object closed: nothing is left.
    try std.testing.expectEqual(@as(usize, 0), count.live);
}

test "fontOpen refuses bad variation records, and a failed open leaks nothing" {
    const options = @import("build_options");
    const bytes = try loadTestFont(options.test_font_variable);
    defer std.testing.allocator.free(bytes);
    var count: Counting = .{ .child = std.testing.allocator };
    var r: Runtime = .{ .gpa = count.allocator() };
    defer r.deinit();
    var records: [16]u8 = undefined;
    @memcpy(records[0..4], "opsz");
    std.mem.writeInt(u32, records[4..8], @bitCast(@as(f32, 144)), .little);
    @memcpy(records[8..12], "wght");
    std.mem.writeInt(u32, records[12..16], @bitCast(std.math.nan(f32)), .little);
    try std.testing.expectError(error.InvalidVariation, r.fontOpen(bytes, 0, records[0..7]));
    try std.testing.expectError(error.InvalidNumber, r.fontOpen(bytes, 0, &records));
    std.mem.writeInt(u32, records[12..16], @bitCast(@as(f32, 100)), .little);
    @memcpy(records[8..12], "opsz");
    try std.testing.expectError(error.DuplicateVariationTag, r.fontOpen(bytes, 0, &records));
    try std.testing.expectError(error.InvalidFont, r.fontOpen("not a font", 0, &.{}));
    try std.testing.expectEqual(@as(usize, 0), count.live);
    try std.testing.expectEqual(@as(i32, -14), mapError(error.InvalidHandle));
    try std.testing.expectEqual(@as(i32, -15), mapError(error.TooManyHandles));
}

test "exports: a busy context, a null pointer and a buffer the context did not give are refused; context_free waits for every buffer" {
    const e = exports;
    const ok: i32 = 0;
    const c = try Context.create(std.testing.allocator);
    var freed = false;
    defer if (!freed) c.destroy();

    var doc: u32 = 99;
    try std.testing.expectEqual(mapError(error.InvalidPointer), e.zpdf_doc_new(c, 1, null));
    try std.testing.expectEqual(ok, e.zpdf_doc_new(c, 1, &doc));
    var standard: u32 = 0;
    try std.testing.expectEqual(ok, e.zpdf_font_open_standard(c, 0, &standard));
    var font_id: u32 = 0;
    try std.testing.expectEqual(ok, e.zpdf_doc_add_font(c, doc, standard, &font_id));

    // Another call running in the context: refused, the output still zeroed.
    var page: u32 = 99;
    c.busy.store(true);
    try std.testing.expectEqual(mapError(error.ContextBusy), e.zpdf_doc_begin_page(c, doc, 612, 792, &page));
    try std.testing.expectEqual(@as(u32, 0), page);
    c.busy.store(false);
    try std.testing.expectEqual(mapError(error.InvalidHandle), e.zpdf_doc_begin_page(null, doc, 612, 792, &page));
    const magic = c.magic;
    c.magic = 0;
    try std.testing.expectEqual(mapError(error.InvalidHandle), e.zpdf_doc_begin_page(c, doc, 612, 792, &page));
    c.magic = magic;
    try std.testing.expectEqual(ok, e.zpdf_doc_begin_page(c, doc, 612, 792, &page));

    try std.testing.expectEqual(mapError(error.InvalidPointer), e.zpdf_doc_draw_text(c, doc, page, font_id, 12, 72, 720, 0, 0, 0, null, 2, 0));
    try std.testing.expectEqual(ok, e.zpdf_doc_draw_text(c, doc, page, font_id, 12, 72, 720, 0, 0, 0, null, 0, 0));
    try std.testing.expectEqual(ok, e.zpdf_doc_draw_text(c, doc, page, font_id, 12, 72, 720, 0, 0, 0, "Hi", 2, 0));
    try std.testing.expectEqual(ok, e.zpdf_doc_end_page(c, doc, page));

    var len: usize = 99;
    try std.testing.expectEqual(mapError(error.InvalidPointer), e.zpdf_doc_finish(c, doc, null, &len));
    try std.testing.expectEqual(@as(usize, 0), len);
    var ptr: ?[*]u8 = null;
    try std.testing.expectEqual(ok, e.zpdf_doc_finish(c, doc, &ptr, &len));
    try std.testing.expect(len > 0 and ptr != null);
    try std.testing.expectEqualStrings("%PDF-", ptr.?[0..5]);

    try std.testing.expectEqual(mapError(error.BuffersOutstanding), e.zpdf_context_free(c));
    try std.testing.expectEqual(mapError(error.InvalidPointer), e.zpdf_free(c, ptr, len - 1));
    var other: [4]u8 = undefined;
    try std.testing.expectEqual(mapError(error.InvalidPointer), e.zpdf_free(c, &other, other.len));
    try std.testing.expectEqual(ok, e.zpdf_free(c, ptr, len));
    try std.testing.expectEqual(mapError(error.InvalidPointer), e.zpdf_free(c, ptr, len));

    try std.testing.expectEqual(@as(?[*]u8, null), e.zpdf_alloc(c, 0));
    try std.testing.expectEqual(ok, e.zpdf_free(c, null, 0));
    const input_buffer = e.zpdf_alloc(c, 3).?;
    try std.testing.expectEqual(mapError(error.BuffersOutstanding), e.zpdf_context_free(c));
    try std.testing.expectEqual(ok, e.zpdf_free(c, input_buffer, 3));

    // The document is still open; freeing the context closes it.
    try std.testing.expectEqual(ok, e.zpdf_context_free(c));
    freed = true;
}

test "exports: error names, unknown codes and the ABI version" {
    try std.testing.expectEqualStrings("InvalidFont", std.mem.span(exports.zpdf_error_name(-3).?));
    try std.testing.expectEqualStrings("BuffersOutstanding", std.mem.span(exports.zpdf_error_name(mapError(error.BuffersOutstanding)).?));
    try std.testing.expectEqualStrings("Unknown", std.mem.span(exports.zpdf_error_name(unknown_code).?));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), exports.zpdf_error_name(-126));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), exports.zpdf_error_name(0));
    try std.testing.expectEqual(unknown_code, mapError(error.SomethingElse));
    try std.testing.expectEqual(abi_version, exports.zpdf_abi_version());
}

/// Each export's name and signature, each wire record's fields with their types and offsets and
/// its size, and the error codes: what a caller built against one abi_version depends on. Doc
/// comments and parameter names are not part of it.
fn surfaceHash() u64 {
    var h = std.hash.Wyhash.init(0);
    inline for (@typeInfo(exports).@"struct".decl_names) |name| {
        h.update(name);
        h.update(@typeName(@TypeOf(@field(exports, name))));
    }
    inline for (@typeInfo(@This()).@"struct".decl_names) |name| {
        const T = @field(@This(), name);
        if (@TypeOf(T) != type) continue;
        switch (@typeInfo(T)) {
            .@"struct" => |s| if (s.layout == .@"extern") {
                h.update(name);
                inline for (s.field_names, s.field_types) |field, F| {
                    h.update(field);
                    h.update(@typeName(F));
                    h.update(std.mem.asBytes(&@as(u64, @offsetOf(T, field))));
                }
                h.update(std.mem.asBytes(&@as(u64, @sizeOf(T))));
            },
            else => {},
        }
    }
    for (error_codes) |e| {
        h.update(@errorName(e[0]));
        h.update(std.mem.asBytes(&e[1]));
    }
    const flags = @typeInfo(RunFlag).@"enum";
    inline for (flags.field_names, flags.field_values) |name, value| {
        h.update(name);
        h.update(std.mem.asBytes(&@as(u64, value)));
    }
    return h.final();
}

test "exports: the ABI surface is the one abi_version names" {
    const now = surfaceHash();
    if (now != abi_surface) {
        std.debug.print("the C ABI changed (surface 0x{x}): bump abi_version and set abi_surface to that\n", .{now});
        return error.AbiChangedWithoutVersion;
    }
}

test "exports: measure and wrap give text_layout's answers, for a standard font and a font file" {
    const e = exports;
    const ok: i32 = 0;
    const gpa = std.testing.allocator;
    const options = @import("build_options");
    const font_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.test_font_roboto, gpa, .unlimited);
    defer gpa.free(font_bytes);
    const c = e.zpdf_context_new().?;
    defer _ = e.zpdf_context_free(c);

    var helvetica: u32 = 0;
    try std.testing.expectEqual(ok, e.zpdf_font_open_standard(c, 0, &helvetica));
    var width: f64 = 0;
    try std.testing.expectEqual(ok, e.zpdf_font_measure(c, helvetica, 10, "Hello", 5, 0, &width));
    try std.testing.expectApproxEqAbs(22.78, width, 1e-9);

    // A standard font has no file: what needs one is refused, and nothing comes out.
    var upem: u32 = 99;
    try std.testing.expectEqual(mapError(error.NotEmbedded), e.zpdf_font_units_per_em(c, helvetica, &upem));
    try std.testing.expectEqual(@as(u32, 0), upem);
    var shaped: ?[*]u8 = null;
    var shaped_len: usize = 0;
    try std.testing.expectEqual(mapError(error.NotEmbedded), e.zpdf_font_shape(c, helvetica, "a", 1, 0, &shaped, &shaped_len));
    try std.testing.expectEqual(mapError(error.InvalidFont), e.zpdf_font_open_standard(c, 12, &upem));
    try std.testing.expectEqual(mapError(error.NotWinAnsi), e.zpdf_font_measure(c, helvetica, 10, "\u{4E00}", 3, 0, &width));

    var roboto: u32 = 0;
    try std.testing.expectEqual(ok, e.zpdf_font_open(c, font_bytes.ptr, font_bytes.len, 0, null, 0, &roboto));
    const text = "one two three four five six\nseven";
    for ([_]u32{ helvetica, roboto }) |font| {
        const f = try c.rt.font(font);
        var out: ?[*]u8 = null;
        var out_len: usize = 0;
        try std.testing.expectEqual(ok, e.zpdf_font_wrap(c, font, 12, text, text.len, 0, 60, 1, &out, &out_len));
        const bytes = out.?[0..out_len];
        defer _ = e.zpdf_free(c, out, out_len);
        const want = try text_layout.wrap(gpa, f.layoutFont(), 12, text, 60, .{ .break_words = true });
        defer gpa.free(want);
        try std.testing.expect(want.len > 2);
        const header = readRecord(WrapHeader, bytes, 0);
        try std.testing.expectEqual(@as(u32, @intCast(want.len)), header.line_count);
        try std.testing.expectEqual(@sizeOf(WrapHeader) + want.len * @sizeOf(LineRecord), bytes.len);
        for (want, 0..) |line, i| {
            const got = readRecord(LineRecord, bytes, @sizeOf(WrapHeader) + i * @sizeOf(LineRecord));
            try std.testing.expectEqual(line.start, got.start);
            try std.testing.expectEqual(line.len, got.len);
            try std.testing.expectEqual(line.width, got.width);
            var measured: f64 = 0;
            try std.testing.expectEqual(ok, e.zpdf_font_measure(c, font, 12, text[got.start..].ptr, got.len, 0, &measured));
            try std.testing.expectApproxEqAbs(got.width, measured, 1e-9);
        }
        // Only bit 0 means anything; another bit is a caller this version does not understand.
        try std.testing.expectEqual(mapError(error.InvalidNumber), e.zpdf_font_wrap(c, font, 12, text, text.len, 0, 60, 2, &out, &out_len));
    }

    // A document takes either kind through one call, and keeps it after the handle closes.
    var doc: u32 = 0;
    try std.testing.expectEqual(ok, e.zpdf_doc_new(c, 0, &doc));
    var helvetica_id: u32 = 0;
    var roboto_id: u32 = 0;
    try std.testing.expectEqual(ok, e.zpdf_doc_add_font(c, doc, helvetica, &helvetica_id));
    try std.testing.expectEqual(ok, e.zpdf_doc_add_font(c, doc, roboto, &roboto_id));
    try std.testing.expectEqual(ok, e.zpdf_font_close(c, helvetica));
    try std.testing.expectEqual(ok, e.zpdf_font_close(c, roboto));
    var page: u32 = 0;
    try std.testing.expectEqual(ok, e.zpdf_doc_begin_page(c, doc, 612, 792, &page));
    try std.testing.expectEqual(ok, e.zpdf_doc_draw_text(c, doc, page, helvetica_id, 12, 72, 720, 0, 0, 0, "Hello", 5, 0));
    try std.testing.expectEqual(ok, e.zpdf_doc_draw_text(c, doc, page, roboto_id, 12, 72, 700, 0, 0, 0, "Hello", 5, 0));
    try std.testing.expectEqual(ok, e.zpdf_doc_end_page(c, doc, page));
    var pdf: ?[*]u8 = null;
    var pdf_len: usize = 0;
    try std.testing.expectEqual(ok, e.zpdf_doc_finish(c, doc, &pdf, &pdf_len));
    defer _ = e.zpdf_free(c, pdf, pdf_len);
    try std.testing.expect(std.mem.indexOf(u8, pdf.?[0..pdf_len], "/BaseFont /Helvetica") != null);
    try std.testing.expectEqual(ok, e.zpdf_doc_close(c, doc));
}

test "exports: vertical metrics, first missing, fit and name give text_layout's answers" {
    const e = exports;
    const ok: i32 = 0;
    const gpa = std.testing.allocator;
    const options = @import("build_options");
    const font_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.test_font_roboto, gpa, .unlimited);
    defer gpa.free(font_bytes);
    const c = e.zpdf_context_new().?;
    defer _ = e.zpdf_context_free(c);

    var courier: u32 = 0;
    try std.testing.expectEqual(ok, e.zpdf_font_open_standard(c, @backingInt(zpdf.StandardFont.courier_bold), &courier));
    var roboto: u32 = 0;
    try std.testing.expectEqual(ok, e.zpdf_font_open(c, font_bytes.ptr, font_bytes.len, 0, null, 0, &roboto));

    var ascender: f64 = 0;
    var descender: f64 = 0;
    try std.testing.expectEqual(ok, e.zpdf_font_vertical_metrics(c, courier, &ascender, &descender));
    try std.testing.expectEqual(@as(f64, 0.629), ascender);
    try std.testing.expectEqual(@as(f64, -0.157), descender);
    try std.testing.expectEqual(ok, e.zpdf_font_vertical_metrics(c, roboto, &ascender, &descender));
    try std.testing.expectEqual(1900.0 / 2048.0, ascender);
    try std.testing.expectEqual(mapError(error.InvalidPointer), e.zpdf_font_vertical_metrics(c, roboto, &ascender, null));

    var missing: usize = 99;
    try std.testing.expectEqual(ok, e.zpdf_font_first_missing(c, courier, "ab\u{3A9}", 4, 0, &missing));
    try std.testing.expectEqual(@as(usize, 2), missing);
    try std.testing.expectEqual(ok, e.zpdf_font_first_missing(c, roboto, "ab\u{3A9}", 4, 0, &missing));
    try std.testing.expectEqual(@as(usize, 4), missing);

    // Courier is 600 thousandths a character: at 10pt, 6pt each, so 20pt keeps 3.
    var kept: usize = 0;
    var width: f64 = 0;
    try std.testing.expectEqual(ok, e.zpdf_font_fit(c, courier, 10, "abcdef", 6, 0, 20, &kept, &width));
    try std.testing.expectEqual(@as(usize, 3), kept);
    try std.testing.expectEqual(@as(f64, 18), width);
    try std.testing.expectEqual(mapError(error.InvalidNumber), e.zpdf_font_fit(c, courier, 10, "abcdef", 6, 0, -1, &kept, &width));
    try std.testing.expectEqual(@as(usize, 0), kept);

    for ([_]struct { font: u32, name: []const u8 }{ .{ .font = courier, .name = "Courier-Bold" }, .{ .font = roboto, .name = "Roboto-Regular" } }) |want| {
        var name: ?[*]u8 = null;
        var name_len: usize = 0;
        try std.testing.expectEqual(ok, e.zpdf_font_name(c, want.font, &name, &name_len));
        defer _ = e.zpdf_free(c, name, name_len);
        try std.testing.expectEqualStrings(want.name, name.?[0..name_len]);
    }
}

fn readRecord(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.bytesToValue(T, bytes[at..][0..@sizeOf(T)]);
}

test "exports: a PDF read through the ABI gives the reader's pages and runs" {
    const e = exports;
    const ok: i32 = 0;
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const path = try std.fmt.allocPrint(gpa, "{s}/objstm.pdf", .{options.read_fixtures});
    defer gpa.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(1 << 24));
    defer gpa.free(bytes);
    var direct = try zpdf.read.Reader.open(gpa, bytes, .{});
    defer direct.deinit();

    const c = try Context.create(gpa);
    defer c.destroy();
    var reader: u32 = 0;
    try std.testing.expectEqual(mapError(error.Malformed), e.zpdf_reader_open(c, "not a pdf", 9, &reader));
    try std.testing.expectEqual(ok, e.zpdf_reader_open(c, bytes.ptr, bytes.len, &reader));
    var count: u32 = 0;
    try std.testing.expectEqual(ok, e.zpdf_reader_page_count(c, reader, &count));
    try std.testing.expectEqual(direct.pageCount(), count);
    try std.testing.expect(count >= 2);
    var info: PageInfo = undefined;
    try std.testing.expectEqual(mapError(error.InvalidPage), e.zpdf_reader_page(c, reader, count, &info));
    var ptr: ?[*]u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(mapError(error.InvalidPage), e.zpdf_reader_page_text(c, reader, count, &ptr, &len));

    var runs_seen: usize = 0;
    for (0..count) |i| {
        const page = direct.page(i);
        try std.testing.expectEqual(ok, e.zpdf_reader_page(c, reader, @intCast(i), &info));
        try std.testing.expectEqualSlices(f64, &page.media_box, &info.media_box);
        try std.testing.expectEqualSlices(f64, &page.crop_box, &info.crop_box);
        try std.testing.expectEqual(@as(u32, page.rotate), info.rotate);

        var want = try direct.pageText(gpa, i);
        defer want.deinit();
        try std.testing.expectEqual(ok, e.zpdf_reader_page_text(c, reader, @intCast(i), &ptr, &len));
        const wire = ptr.?[0..len];
        defer _ = e.zpdf_free(c, ptr, len);
        const header = readRecord(TextHeader, wire, 0);
        try std.testing.expectEqual(want.runs.len, header.run_count);
        try std.testing.expectEqual(want.unplaced_actual_text, header.unplaced_actual_text);
        const glyphs_at = @sizeOf(TextHeader) + header.run_count * @sizeOf(RunRecord);
        const strings_at = glyphs_at + header.glyph_count * @sizeOf(GlyphRecord);
        try std.testing.expectEqual(wire.len, strings_at + header.strings_len);
        const strings = wire[strings_at..];
        var glyphs: u32 = 0;
        for (want.runs, 0..) |run, j| {
            const r = readRecord(RunRecord, wire, @sizeOf(TextHeader) + j * @sizeOf(RunRecord));
            try std.testing.expectEqualStrings(run.text, strings[r.text_offset..][0..r.text_len]);
            try std.testing.expectEqualStrings(run.font, strings[r.font_offset..][0..r.font_len]);
            try std.testing.expectEqual(run.x, r.x);
            try std.testing.expectEqual(run.y, r.y);
            try std.testing.expectEqual(run.size, r.size);
            if (run.width) |w| try std.testing.expectEqual(w, r.width) else try std.testing.expect(std.math.isNan(r.width));
            try std.testing.expectEqual(run.unmapped, r.unmapped);
            try std.testing.expectEqual(runFlags(run), r.flags);
            try std.testing.expectEqual(glyphs, r.first_glyph);
            try std.testing.expectEqual(run.glyphs.len, r.glyph_count);
            for (run.glyphs, 0..) |g, k| {
                const wg = readRecord(GlyphRecord, wire, glyphs_at + (r.first_glyph + k) * @sizeOf(GlyphRecord));
                try std.testing.expectEqual(g.x, wg.x);
                try std.testing.expectEqual(g.y, wg.y);
                try std.testing.expectEqual(g.text_at, wg.text_at);
            }
            glyphs += r.glyph_count;
        }
        try std.testing.expectEqual(header.glyph_count, glyphs);
        runs_seen += want.runs.len;
    }
    try std.testing.expect(runs_seen > 0);
    try std.testing.expectEqual(ok, e.zpdf_reader_close(c, reader));
    try std.testing.expectEqual(mapError(error.InvalidHandle), e.zpdf_reader_page_count(c, reader, &count));
}

test "encodePageText: an unknown width is NaN, flags and counts are kept, a font name is stored once" {
    const gpa = std.testing.allocator;
    const glyphs_a = [_]zpdf.read.Glyph{ .{ .x = 1, .y = 2, .text_at = 0 }, .{ .x = 3, .y = 4, .text_at = 1 } };
    const glyphs_b = [_]zpdf.read.Glyph{.{ .x = 5, .y = 6, .text_at = 0 }};
    const runs = [_]zpdf.read.TextRun{
        .{ .text = "ab", .x = 1, .y = 2, .size = 10, .width = null, .font = "F", .unmapped = 1, .glyphs = &glyphs_a, .actual_text = false, .vertical = true, .annotation = true },
        .{ .text = "c", .x = 5, .y = 6, .size = 12, .width = 7, .font = "F", .unmapped = 0, .glyphs = &glyphs_b, .actual_text = true, .vertical = false, .annotation = false },
    };
    const wire = try encodePageText(gpa, &runs, 2);
    defer gpa.free(wire);
    const header = readRecord(TextHeader, wire, 0);
    try std.testing.expectEqual(TextHeader{ .run_count = 2, .glyph_count = 3, .unplaced_actual_text = 2, .strings_len = 4 }, header);
    const a = readRecord(RunRecord, wire, @sizeOf(TextHeader));
    const b = readRecord(RunRecord, wire, @sizeOf(TextHeader) + @sizeOf(RunRecord));
    try std.testing.expect(std.math.isNan(a.width));
    try std.testing.expectEqual(@as(f64, 7), b.width);
    try std.testing.expectEqual(@as(u32, 2 | 4), a.flags);
    try std.testing.expectEqual(@as(u32, 1), b.flags);
    try std.testing.expectEqual(@as(u32, 1), a.unmapped);
    try std.testing.expectEqual(@as(u32, 0), a.first_glyph);
    try std.testing.expectEqual(@as(u32, 2), b.first_glyph);
    try std.testing.expectEqual(@as(u32, 1), b.glyph_count);
    try std.testing.expectEqual(a.font_offset, b.font_offset);
    const glyphs_at = @sizeOf(TextHeader) + 2 * @sizeOf(RunRecord);
    const last = readRecord(GlyphRecord, wire, glyphs_at + 2 * @sizeOf(GlyphRecord));
    try std.testing.expectEqual(@as(f64, 5), last.x);
    const strings = wire[glyphs_at + 3 * @sizeOf(GlyphRecord) ..];
    try std.testing.expectEqualStrings("abFc", strings);
}

test "stream and free: writing and reading many pages, memory follows one page" {
    const gpa = std.testing.allocator;
    const options = @import("build_options");
    const font_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.test_font_roboto, gpa, .unlimited);
    defer gpa.free(font_bytes);
    const c = try Context.create(gpa);
    defer c.destroy();
    const pages = 200;

    // Write, taking the output after each page, as a caller that streams the PDF does.
    var pdf: std.ArrayList(u8) = .empty;
    defer pdf.deinit(gpa);
    const f = try c.rt.fontOpen(font_bytes, 0, &.{});
    const d = try c.rt.docNew(true);
    const id = try c.rt.docAddFont(d, f);
    var write_live: [pages]usize = undefined;
    var line: [64]u8 = undefined;
    for (0..pages) |p| {
        const page = try c.rt.docBeginPage(d, 612, 792);
        // The same lines on every page, so the shape cache stays one page's size.
        for (0..50) |l| try c.rt.docDrawText(d, page, id, 10, 36, 760 - @as(f64, @floatFromInt(l)) * 14, .black, try std.fmt.bufPrint(&line, "Line {d} office AVA", .{l}), 0);
        try c.rt.docEndPage(d, page);
        const taken = try c.rt.docTake(d);
        defer c.rt.gpa.free(taken);
        // take passes on what zpdf buffered, so the first page is out at once.
        if (p == 0) try std.testing.expectStringStartsWith(taken, "%PDF-");
        try pdf.appendSlice(gpa, taken);
        write_live[p] = c.counting.live - taken.len;
    }
    const rest = try c.rt.docFinish(d);
    try pdf.appendSlice(gpa, rest);
    c.rt.gpa.free(rest);
    try c.rt.docClose(d);
    try c.rt.fontClose(f);

    // Read it back one page at a time.
    const r = try c.rt.readerOpen(pdf.items);
    var read_live: [pages]usize = undefined;
    var read_peak: [pages]usize = undefined;
    var cached: [pages]usize = undefined;
    const reader_object = try c.rt.reader(r);
    for (0..pages) |p| {
        c.counting.peak = c.counting.live;
        const wire = try c.rt.readerPageText(r, @intCast(p));
        c.rt.gpa.free(wire);
        read_live[p] = c.counting.live;
        read_peak[p] = c.counting.peak;
        cached[p] = reader_object.reader.cache.count();
    }
    // Writing: what stays per page is its xref offset and page tree entry (measured: about 28
    // bytes), well under one page of output (about 790 bytes here). A document held whole would
    // grow by its pages' output.
    const per_page_limit = 64;
    try std.testing.expect(pdf.items.len / pages > per_page_limit * 4);
    try std.testing.expect(write_live[pages - 1] - write_live[9] <= per_page_limit * (pages - 10));
    // Reading: after the first page (which loads the font), each page leaves nothing behind, and
    // no page needs more working memory than the early pages did. The peak is a bound, not one
    // value: the same page's peak can differ by allocator state (on aarch64 Linux with glibc it
    // alternates between two values, 18 KB apart, from page to page), while working memory kept
    // by mistake would grow with the page number and pass the bound.
    const early_peak = std.mem.max(usize, read_peak[1..11]);
    for (1..pages) |p| {
        try std.testing.expectEqual(read_live[1], read_live[p]);
        try std.testing.expect(read_peak[p] <= early_peak);
        // A page's content streams are read once and not cached. A cached one costs only some
        // 150 bytes in an arena that grows by chunks, so live bytes alone would not show it
        // until a chunk fills (about 1000 pages here).
        try std.testing.expectEqual(cached[1], cached[p]);
    }
    // Every page was read, and the text is there.
    try std.testing.expectEqual(@as(u32, pages), try c.rt.readerPageCount(r));
}

test "stream and free: a page's tokens are freed operator by operator" {
    // One page of k dash-pattern operators, then 2k. Each operator's operands are freed after it
    // runs, so the page's peak grows by about its content (decoded once), not by its operands.
    // An array allocates its elements (a number or a keyword token allocates nothing, so `cm`
    // operators would not show this): 8 elements take several times the 22 bytes of content.
    // The stream is unfiltered, so it is read where it lies in the file and only the tokens use
    // work memory. The line of text at the end must come back: the parser ran through every
    // operator, so a flat peak is the tokens being freed, not a page that was not read.
    const gpa = std.testing.allocator;
    var peaks: [2]usize = undefined;
    var sizes: [2]usize = undefined;
    for ([_]usize{ 5000, 10000 }, 0..) |k, n| {
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(gpa);
        for (0..k) |_| try content.appendSlice(gpa, "[1 2 3 4 5 6 7 8] 0 d\n");
        try content.appendSlice(gpa, "BT /F1 12 Tf 72 720 Td (the end) Tj ET\n");
        const stream = try std.fmt.allocPrint(gpa, "<< /Length {d} >>\nstream\n{s}\nendstream", .{ content.items.len, content.items });
        defer gpa.free(stream);
        const pdf = try zpdf.read.test_util.build(gpa, &.{
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>",
            "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            stream,
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        }, "");
        defer gpa.free(pdf);
        const c = try Context.create(gpa);
        defer c.destroy();
        const r = try c.rt.readerOpen(pdf);
        // From the memory live before the page, not after it: the reader keeps up to
        // max_retained_work of page work for the next page, so "after" is not "before".
        const before = c.counting.live;
        c.counting.peak = before;
        const wire = try c.rt.readerPageText(r, 0);
        defer c.rt.gpa.free(wire);
        try std.testing.expect(std.mem.indexOf(u8, wire, "the end") != null);
        peaks[n] = c.counting.peak - before;
        sizes[n] = content.items.len;
    }
    // Kept operands would grow the peak by several times the content; freed, it stays flat.
    try std.testing.expect(peaks[1] <= peaks[0] + 4 * (sizes[1] - sizes[0]));
}

test "stream and free: after the first page, zpdf_reader_page_text asks the base allocator for no large block" {
    // Pages of 600 runs, 6600 glyphs: their work and their text are each well over 64 KiB, and
    // the work stays under max_retained_work (a page that needs more gets one more block a page,
    // by design). The page text is encoded straight from the reader's work memory, and the output
    // buffer the caller frees goes back to the context's block cache, so a caller that frees each
    // page before the next makes no large request of the base allocator after the first page.
    // Copying the runs into a PageText first took many such requests a page, and a fresh output
    // buffer one more: an mmap each under std.heap.smp_allocator.
    const gpa = std.testing.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    for (0..600) |i| try raw.print(gpa, "BT /F1 9 Tf 1 0 0 1 36 {d} Tm (Hello {d:0>5}) Tj ET\n", .{ 20 + i, i });
    const stream = try std.fmt.allocPrint(gpa, "<< /Length {d} >>\nstream\n{s}\nendstream", .{ raw.items.len, raw.items });
    defer gpa.free(stream);
    const pdf = try zpdf.read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R 6 0 R] /Count 4 /MediaBox [0 0 612 792] >>",
        "<< /Type /Page /Parent 2 0 R /Contents 7 0 R /Resources << /Font << /F1 8 0 R >> >> >>",
        "<< /Type /Page /Parent 2 0 R /Contents 7 0 R /Resources << /Font << /F1 8 0 R >> >> >>",
        "<< /Type /Page /Parent 2 0 R /Contents 7 0 R /Resources << /Font << /F1 8 0 R >> >> >>",
        "<< /Type /Page /Parent 2 0 R /Contents 7 0 R /Resources << /Font << /F1 8 0 R >> >> >>",
        stream,
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
    }, "");
    defer gpa.free(pdf);
    const Large = struct {
        child: std.mem.Allocator,
        count: usize = 0,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }
        fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (len >= 64 * 1024) self.count += 1;
            return self.child.rawAlloc(len, a, ra);
        }
        // Not counted: growing in place under std.heap.smp_allocator either stays inside its
        // pages or fails, with no system call (PageAllocator.realloc, may_move = false).
        fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.child.rawResize(m, a, n, ra);
        }
        fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (n > m.len and n >= 64 * 1024) self.count += 1;
            return self.child.rawRemap(m, a, n, ra);
        }
        fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.child.rawFree(m, a, ra);
        }
    };
    var large: Large = .{ .child = gpa };
    const c = try Context.create(large.allocator());
    defer c.destroy();
    const r = try c.rt.readerOpen(pdf);
    for (0..4) |i| {
        if (i == 1) {
            // The first page did need large blocks, so a zero below is the reuse.
            try std.testing.expect(large.count > 1);
            large.count = 0;
        }
        const wire = try c.rt.readerPageText(r, @intCast(i));
        defer c.rt.gpa.free(wire);
        try std.testing.expect(wire.len >= 64 * 1024);
        try std.testing.expect(std.mem.indexOf(u8, wire, "Hello 00599") != null);
    }
    try std.testing.expectEqual(@as(usize, 0), large.count);
    try c.rt.readerClose(r);
}

/// A test sink: keeps what it is given, fails after `fail_after` bytes, and can call zpdf from
/// inside write to check that the context refuses it.
const TestSink = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    calls: usize = 0,
    longest: usize = 0,
    fail_after: usize = std.math.maxInt(usize),
    reenter: ?*Context = null,
    reenter_rc: i32 = 0,

    fn write(user: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) i32 {
        const s: *TestSink = @ptrCast(@alignCast(user.?));
        s.calls += 1;
        s.longest = @max(s.longest, len);
        if (s.reenter) |c| {
            var live: usize = 0;
            s.reenter_rc = exports.zpdf_live_bytes(c, &live);
        }
        if (s.bytes.items.len + len > s.fail_after) return -1;
        s.bytes.appendSlice(s.gpa, bytes[0..len]) catch return -1;
        return 0;
    }

    fn sink(s: *TestSink) Sink {
        return .{ .user = s, .write = write };
    }
};

/// Two pages of text in an embedded font, then a later text; `after_page` runs after each end.
fn drawTwoPages(rt: *Runtime, d: u32, font: u32, after_page: anytype) !void {
    const id = try rt.docAddFont(d, font);
    var line: [32]u8 = undefined;
    var later: u32 = 0;
    for (0..2) |p| {
        const page = try rt.docBeginPage(d, 612, 792);
        for (0..40) |l| try rt.docDrawText(d, page, id, 10, 36, 760 - @as(f64, @floatFromInt(l)) * 14, .black, try std.fmt.bufPrint(&line, "page {d} line {d} office", .{ p, l }), 0);
        if (p == 0) later = try rt.docReserveLater(d, page);
        try rt.docEndPage(d, page);
        try after_page.call();
    }
    try rt.docDrawTextLater(d, later, id, 9, 300, 40, .black, "Page 1 of 2", 0);
}

test "sinks: a sink document writes what a buffered one does, each page by its end_page" {
    const gpa = std.testing.allocator;
    const options = @import("build_options");
    const font_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.test_font_roboto, gpa, .unlimited);
    defer gpa.free(font_bytes);
    const c = try Context.create(gpa);
    defer c.destroy();
    const f = try c.rt.fontOpen(font_bytes, 0, &.{});

    // The buffered document, taken after each page.
    var taken: std.ArrayList(u8) = .empty;
    defer taken.deinit(gpa);
    var taken_at_page: [2]usize = undefined;
    const buffered = try c.rt.docNew(true);
    const Take = struct {
        rt: *Runtime,
        d: u32,
        out: *std.ArrayList(u8),
        at: *[2]usize,
        n: usize = 0,
        fn call(self: *@This()) !void {
            const bytes = try self.rt.docTake(self.d);
            defer self.rt.gpa.free(bytes);
            try self.out.appendSlice(std.testing.allocator, bytes);
            self.at[self.n] = self.out.items.len;
            self.n += 1;
        }
    };
    var take: Take = .{ .rt = &c.rt, .d = buffered, .out = &taken, .at = &taken_at_page };
    try drawTwoPages(&c.rt, buffered, f, &take);
    const rest = try c.rt.docFinish(buffered);
    try taken.appendSlice(gpa, rest);
    c.rt.gpa.free(rest);

    // The same through a sink: each page's bytes are there when end_page returns.
    var collector: TestSink = .{ .gpa = gpa };
    defer collector.bytes.deinit(gpa);
    const sinked = try c.rt.docNewSink(true, collector.sink());
    const Check = struct {
        sink: *TestSink,
        at: *[2]usize,
        n: usize = 0,
        fn call(self: *@This()) !void {
            try std.testing.expectEqual(self.at[self.n], self.sink.bytes.items.len);
            self.n += 1;
        }
    };
    var check: Check = .{ .sink = &collector, .at = &taken_at_page };
    try drawTwoPages(&c.rt, sinked, f, &check);
    const none = try c.rt.docTake(sinked);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    c.rt.gpa.free(none);
    const nothing = try c.rt.docFinish(sinked);
    try std.testing.expectEqual(@as(usize, 0), nothing.len);
    c.rt.gpa.free(nothing);

    try std.testing.expectEqualSlices(u8, taken.items, collector.bytes.items);
    try std.testing.expect(collector.longest <= sink_buffer_len);
    try std.testing.expect(collector.calls >= 3);
    try c.rt.docClose(buffered);
    try c.rt.docClose(sinked);
    try c.rt.fontClose(f);
}

test "sinks: a failing write is SinkFailed then DocumentFailed; a null sink or write is refused; write cannot re-enter" {
    const e = exports;
    const gpa = std.testing.allocator;
    const options = @import("build_options");
    const font_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.test_font_roboto, gpa, .unlimited);
    defer gpa.free(font_bytes);
    const c = try Context.create(gpa);
    defer c.destroy();
    const f = try c.rt.fontOpen(font_bytes, 0, &.{});

    var d: u32 = 0;
    try std.testing.expectEqual(mapError(error.InvalidPointer), e.zpdf_doc_new_sink(c, 1, null, &d));
    const no_write: Sink = .{ .user = null, .write = null };
    try std.testing.expectEqual(mapError(error.InvalidPointer), e.zpdf_doc_new_sink(c, 1, &no_write, &d));

    var failing: TestSink = .{ .gpa = gpa, .fail_after = 100, .reenter = c };
    defer failing.bytes.deinit(gpa);
    const sink = failing.sink();
    try std.testing.expectEqual(@as(i32, 0), e.zpdf_doc_new_sink(c, 1, &sink, &d));
    var id: u32 = 0;
    try std.testing.expectEqual(@as(i32, 0), e.zpdf_doc_add_font(c, d, f, &id));
    var page: u32 = 0;
    try std.testing.expectEqual(@as(i32, 0), e.zpdf_doc_begin_page(c, d, 612, 792, &page));
    try std.testing.expectEqual(@as(i32, 0), e.zpdf_doc_draw_text(c, d, page, id, 12, 72, 720, 0, 0, 0, "office", 6, 0));
    try std.testing.expectEqual(mapError(error.SinkFailed), e.zpdf_doc_end_page(c, d, page));
    try std.testing.expectEqual(@as(i32, -35), mapError(error.SinkFailed));
    // write ran inside a zpdf call, so its own call on the context was refused.
    try std.testing.expectEqual(mapError(error.ContextBusy), failing.reenter_rc);
    try std.testing.expectEqual(mapError(error.DocumentFailed), e.zpdf_doc_begin_page(c, d, 612, 792, &page));
    var ptr: ?[*]u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(mapError(error.DocumentFailed), e.zpdf_doc_finish(c, d, &ptr, &len));
    try std.testing.expect(failing.bytes.items.len <= 100);
    try std.testing.expectEqual(@as(i32, 0), e.zpdf_doc_close(c, d));
    try c.rt.fontClose(f);
}

test "sinks: the adapter keeps std.Io.Writer's drain contract (buffered bytes, slices, splat)" {
    const gpa = std.testing.allocator;
    var got: TestSink = .{ .gpa = gpa };
    defer got.bytes.deinit(gpa);
    var buffer: [4]u8 = undefined;
    var sw: SinkWriter = .init(got.sink(), &buffer);
    const w = &sw.interface;
    try w.writeAll("ab");
    // More than the buffer holds: the buffered "ab" goes first, then the slices in order.
    var data = [_][]const u8{ "cdef", "gh", "xy" };
    try w.writeSplatAll(&data, 3);
    try w.splatByteAll('z', 5);
    var none = [_][]const u8{ "12345", "never" };
    try w.writeSplatAll(&none, 0);
    try w.flush();
    try std.testing.expectEqualStrings("abcdefghxyxyxyzzzzz12345", got.bytes.items);

    // std's helpers may expand a splat before drain sees it; the contract lets a caller pass one.
    got.bytes.clearRetainingCapacity();
    try w.writeAll("q");
    var direct = [_][]const u8{ "r", "st" };
    try std.testing.expectEqual(@as(usize, 1 + 2 * 3), try w.vtable.drain(w, &direct, 3));
    try std.testing.expectEqualStrings("qrststst", got.bytes.items);

    // A failing write ends the drain with WriteFailed.
    var failing: TestSink = .{ .gpa = gpa, .fail_after = 3 };
    defer failing.bytes.deinit(gpa);
    var small: [2]u8 = undefined;
    var fw: SinkWriter = .init(failing.sink(), &small);
    try std.testing.expectError(error.WriteFailed, fw.interface.writeAll("abcdef"));
}

test "stream and free: reading a CJK font's page costs the file nothing for its collection's table" {
    // Adobe-Japan1's CID-to-Unicode table is static data (read_text.CidTable): a reader that
    // uses it allocates no copy. Parsed per file, it cost about 9 MB.
    const gpa = std.testing.allocator;
    const stream = "<< /Length 30 >>\nstream\nBT /F1 10 Tf <00220619> Tj ET\nendstream";
    const pdf = try zpdf.read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        stream,
        "<< /Type /Font /Subtype /Type0 /BaseFont /J /Encoding /Identity-H /DescendantFonts [<< /Type /Font /Subtype /CIDFontType0 /BaseFont /J /CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) /Supplement 7 >> >>] >>",
    }, "");
    defer gpa.free(pdf);
    const c = try Context.create(gpa);
    defer c.destroy();
    const r = try c.rt.readerOpen(pdf);
    const opened = c.counting.live;
    c.counting.peak = c.counting.live;
    const wire = try c.rt.readerPageText(r, 0);
    defer c.rt.gpa.free(wire);
    const text = readRecord(TextHeader, wire, 0);
    try std.testing.expectEqual(@as(u32, 1), text.run_count);
    const strings = wire[wire.len - text.strings_len ..];
    try std.testing.expect(std.mem.indexOf(u8, strings, "A\u{4E38}") != null);
    // The font and the page's result stay; a table would be megabytes.
    try std.testing.expect(c.counting.live - opened < 64 * 1024);
    try std.testing.expect(c.counting.peak - opened < 256 * 1024);
}

/// A caller-buffer test sink: lends `size`-byte buffers from its own memory, keeps what is
/// committed, and records whether zpdf holds a buffer (lent, not yet committed).
const TestCallerSink = struct {
    gpa: std.mem.Allocator,
    size: usize,
    bytes: std.ArrayList(u8) = .empty,
    lent: ?[]u8 = null,
    lends: usize = 0,
    fail_get: bool = false,
    fail_commit: bool = false,
    /// Lend less than asked (but never 0), a caller defect zpdf must refuse.
    short: bool = false,
    /// Lend 0 bytes, which zpdf could make no progress with.
    zero: bool = false,

    fn getBuffer(user: ?*anyopaque, min_len: usize, buffer: *?[*]u8, len: *usize) callconv(.c) i32 {
        const s: *TestCallerSink = @ptrCast(@alignCast(user.?));
        if (s.fail_get or s.lent != null) return -1;
        const n = if (s.zero) 0 else if (s.short) @max(1, min_len - 1) else @max(min_len, s.size);
        const memory = s.gpa.alloc(u8, n) catch return -1;
        s.lent = memory;
        s.lends += 1;
        buffer.* = memory.ptr;
        len.* = n;
        return 0;
    }

    fn commit(user: ?*anyopaque, len: usize) callconv(.c) i32 {
        const s: *TestCallerSink = @ptrCast(@alignCast(user.?));
        const memory = s.lent orelse return -1;
        defer {
            s.gpa.free(memory);
            s.lent = null;
        }
        if (s.fail_commit or len > memory.len) return -1;
        s.bytes.appendSlice(s.gpa, memory[0..len]) catch return -1;
        return 0;
    }

    fn sink(s: *TestCallerSink) Sink {
        return .{ .user = s, .write = null, .get_buffer = getBuffer, .commit = commit };
    }

    fn deinit(s: *TestCallerSink) void {
        if (s.lent) |m| s.gpa.free(m);
        s.bytes.deinit(s.gpa);
    }
};

test "sinks: a caller-buffer sink gets the buffered bytes in its own memory, and holds none between calls" {
    const gpa = std.testing.allocator;
    const options = @import("build_options");
    const font_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.test_font_roboto, gpa, .unlimited);
    defer gpa.free(font_bytes);
    const c = try Context.create(gpa);
    defer c.destroy();
    const f = try c.rt.fontOpen(font_bytes, 0, &.{});
    defer c.rt.fontClose(f) catch unreachable;

    // The buffered document, taken after each page.
    var taken: std.ArrayList(u8) = .empty;
    defer taken.deinit(gpa);
    var taken_at_page: [2]usize = undefined;
    const buffered = try c.rt.docNew(true);
    const Take = struct {
        rt: *Runtime,
        d: u32,
        out: *std.ArrayList(u8),
        at: *[2]usize,
        n: usize = 0,
        fn call(self: *@This()) !void {
            const bytes = try self.rt.docTake(self.d);
            defer self.rt.gpa.free(bytes);
            try self.out.appendSlice(std.testing.allocator, bytes);
            self.at[self.n] = self.out.items.len;
            self.n += 1;
        }
    };
    var take: Take = .{ .rt = &c.rt, .d = buffered, .out = &taken, .at = &taken_at_page };
    try drawTwoPages(&c.rt, buffered, f, &take);
    const rest = try c.rt.docFinish(buffered);
    try taken.appendSlice(gpa, rest);
    c.rt.gpa.free(rest);
    try c.rt.docClose(buffered);

    // Lent buffers of the size asked for, or of 64 KiB.
    for ([_]usize{ 1, 64 * 1024 }) |size| {
        var caller: TestCallerSink = .{ .gpa = gpa, .size = size };
        defer caller.deinit();
        const d = try c.rt.docNewSink(true, caller.sink());
        try std.testing.expect(caller.lent == null);
        const Check = struct {
            sink: *TestCallerSink,
            at: *[2]usize,
            n: usize = 0,
            fn call(self: *@This()) !void {
                try std.testing.expect(self.sink.lent == null);
                try std.testing.expectEqual(self.at[self.n], self.sink.bytes.items.len);
                self.n += 1;
            }
        };
        var check: Check = .{ .sink = &caller, .at = &taken_at_page };
        try drawTwoPages(&c.rt, d, f, &check);
        try std.testing.expect(caller.lent == null);
        const none = try c.rt.docFinish(d);
        try std.testing.expectEqual(@as(usize, 0), none.len);
        c.rt.gpa.free(none);
        try std.testing.expect(caller.lent == null);
        try std.testing.expectEqualSlices(u8, taken.items, caller.bytes.items);
        try c.rt.docClose(d);
    }
}

test "sinks: a caller-buffer sink's failures are SinkFailed, and a sink in both modes or neither is refused" {
    const e = exports;
    const gpa = std.testing.allocator;
    const c = try Context.create(gpa);
    defer c.destroy();
    var d: u32 = 0;
    var caller: TestCallerSink = .{ .gpa = gpa, .size = 64 };
    defer caller.deinit();
    var both = caller.sink();
    both.write = TestSink.write;
    try std.testing.expectEqual(mapError(error.InvalidPointer), e.zpdf_doc_new_sink(c, 1, &both, &d));
    var half = caller.sink();
    half.commit = null;
    try std.testing.expectEqual(mapError(error.InvalidPointer), e.zpdf_doc_new_sink(c, 1, &half, &d));
    const neither: Sink = .{ .user = null, .write = null, .get_buffer = null, .commit = null };
    try std.testing.expectEqual(mapError(error.InvalidPointer), e.zpdf_doc_new_sink(c, 1, &neither, &d));

    // get_buffer fails, lends too little, lends nothing, or commit fails: the header is the first
    // write.
    for (0..4) |case| {
        var bad: TestCallerSink = .{ .gpa = gpa, .size = 64, .fail_get = case == 0, .short = case == 1, .fail_commit = case == 2, .zero = case == 3 };
        defer bad.deinit();
        const sink = bad.sink();
        try std.testing.expectEqual(mapError(error.SinkFailed), e.zpdf_doc_new_sink(c, 1, &sink, &d));
    }
    try std.testing.expectEqual(@as(usize, 0), c.counting.live);
}

test "sinks: the caller-buffer adapter keeps std.Io.Writer's drain contract, past 64 KiB too" {
    const gpa = std.testing.allocator;
    var got: TestCallerSink = .{ .gpa = gpa, .size = 1 };
    defer got.deinit();
    var cw: CallerBufferWriter = .init(got.sink());
    const w = &cw.interface;
    // A write larger than the most zpdf asks for is moved in over several buffers.
    const big = try gpa.alloc(u8, 200_000);
    defer gpa.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
    try w.writeAll("ab");
    try w.writeAll(big);
    var data = [_][]const u8{ "cd", "xy" };
    try w.writeSplatAll(&data, 3);
    try std.testing.expectEqual(@as(usize, 1 + 2 * 3), try w.vtable.drain(w, &[_][]const u8{ "q", "rs" }, 3));
    // Several slices, each larger than the most zpdf asks for at once.
    var two_big = [_][]const u8{ big[0..70_000], big[70_000..140_000] };
    try w.writeVecAll(&two_big);
    try w.flush();
    try std.testing.expect(got.lent == null);
    try std.testing.expect(got.lends >= 4);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(gpa);
    try want.appendSlice(gpa, "ab");
    try want.appendSlice(gpa, big);
    try want.appendSlice(gpa, "cdxyxyxyqrsrsrs");
    try want.appendSlice(gpa, big[0..140_000]);
    try std.testing.expectEqualSlices(u8, want.items, got.bytes.items);
}

test "sinks: draw_text_later's form is in the caller's memory when it returns, even past zpdf's own buffer" {
    // A later text whose form is larger than zpdf's 64 KiB assembly buffer reaches the sink's
    // writer during the call; the call must give the caller's buffer back before it returns.
    const gpa = std.testing.allocator;
    const c = try Context.create(gpa);
    defer c.destroy();
    var caller: TestCallerSink = .{ .gpa = gpa, .size = 1 };
    defer caller.deinit();
    const d = try c.rt.docNewSink(false, caller.sink());
    const font = try c.rt.docAddFont(d, try c.rt.fontOpenStandard(0));
    const page = try c.rt.docBeginPage(d, 612, 792);
    const later = try c.rt.docReserveLater(d, page);
    try c.rt.docEndPage(d, page);
    const text = try gpa.alloc(u8, 100_000);
    defer gpa.free(text);
    @memset(text, 'W');
    const before = caller.bytes.items.len;
    try c.rt.docDrawTextLater(d, later, font, 9, 10, 40, .black, text, 0);
    try std.testing.expect(caller.lent == null);
    try std.testing.expect(caller.bytes.items.len - before > 64 * 1024);
    const none = try c.rt.docFinish(d);
    c.rt.gpa.free(none);
    try c.rt.docClose(d);
}

test "exports: links and bookmarks, their ids from 1, and their refusals' codes" {
    const gpa = std.testing.allocator;
    const c = try Context.create(gpa);
    defer c.destroy();
    const e = exports;
    var d: u32 = 0;
    try std.testing.expectEqual(@as(i32, 0), e.zpdf_doc_new(c, 0, &d));
    var page: u32 = 0;
    try std.testing.expectEqual(@as(i32, 0), e.zpdf_doc_begin_page(c, d, 612, 792, &page));
    const uri = "https://example.com/";
    try std.testing.expectEqual(@as(i32, 0), e.zpdf_doc_add_link_uri(c, d, page, 72, 700, 100, 12, uri, uri.len));
    try std.testing.expectEqual(mapError(error.InvalidUri), e.zpdf_doc_add_link_uri(c, d, page, 72, 700, 100, 12, "a b", 3));
    // To page 1, not begun yet.
    try std.testing.expectEqual(@as(i32, 0), e.zpdf_doc_add_link_page(c, d, page, 72, 680, 100, 12, 1, 0, 792));
    var top: u32 = 0;
    var child: u32 = 0;
    try std.testing.expectEqual(@as(i32, 0), e.zpdf_doc_add_bookmark(c, d, 0, "Top", 3, 0, 0, 792, 1, &top));
    try std.testing.expectEqual(@as(u32, 1), top);
    try std.testing.expectEqual(@as(i32, 0), e.zpdf_doc_add_bookmark(c, d, top, "Child", 5, 1, 0, 700, 0, &child));
    try std.testing.expectEqual(@as(u32, 2), child);
    try std.testing.expectEqual(mapError(error.InvalidBookmark), e.zpdf_doc_add_bookmark(c, d, 3, "x", 1, 0, 0, 0, 0, &child));
    try std.testing.expectEqual(mapError(error.InvalidNumber), e.zpdf_doc_add_bookmark(c, d, 0, "x", 1, 0, 0, 0, 2, &child));
    try std.testing.expectEqual(mapError(error.InvalidUtf8), e.zpdf_doc_add_bookmark(c, d, 0, "\xff", 1, 0, 0, 0, 0, &child));
    // A refused call's id is 0, as every output of a failed call is.
    try std.testing.expectEqual(@as(u32, 0), child);
    try std.testing.expectEqual(@as(i32, 0), e.zpdf_doc_end_page(c, d, page));
    var ptr: ?[*]u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(mapError(error.MissingPage), e.zpdf_doc_finish(c, d, &ptr, &len));
    try std.testing.expectEqualStrings("MissingPage", std.mem.span(e.zpdf_error_name(mapError(error.MissingPage)).?));
    try std.testing.expectEqual(@as(i32, 0), e.zpdf_doc_begin_page(c, d, 612, 792, &page));
    try std.testing.expectEqual(@as(i32, 0), e.zpdf_doc_end_page(c, d, page));
    try std.testing.expectEqual(@as(i32, 0), e.zpdf_doc_finish(c, d, &ptr, &len));
    const pdf = ptr.?[0..len];
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/URI (https://example.com/)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Outlines") != null);
    try std.testing.expectEqual(@as(i32, 0), e.zpdf_free(c, ptr, len));
    try std.testing.expectEqual(@as(i32, 0), e.zpdf_doc_close(c, d));
}

test "exports: a direction other than 0, 1 or 2 is InvalidDirection, for a standard font too" {
    const gpa = std.testing.allocator;
    const c = try Context.create(gpa);
    defer c.destroy();
    const d = try c.rt.docNew(false);
    const font = try c.rt.docAddFont(d, try c.rt.fontOpenStandard(0));
    const page = try c.rt.docBeginPage(d, 612, 792);
    const later = try c.rt.docReserveLater(d, page);
    for ([_]u32{ 3, 9, std.math.maxInt(u32) }) |bad| {
        try std.testing.expectError(error.InvalidDirection, c.rt.docDrawText(d, page, font, 9, 10, 40, .black, "a", bad));
        try std.testing.expectError(error.InvalidDirection, c.rt.docDrawTextLater(d, later, font, 9, 10, 40, .black, "a", bad));
    }
    // The refusals changed nothing: the document goes on.
    try c.rt.docDrawText(d, page, font, 9, 10, 40, .black, "a", 1);
    try c.rt.docEndPage(d, page);
    try c.rt.docDrawTextLater(d, later, font, 9, 10, 40, .black, "b", 0);
    const pdf = try c.rt.docFinish(d);
    c.rt.gpa.free(pdf);
    try c.rt.docClose(d);
}
