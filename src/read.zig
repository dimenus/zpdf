//! zpdf.read: reads a PDF's structure and pages, for PDFs from any writer.
//!
//! How to use it:
//!   var reader = try read.Reader.open(gpa, bytes, .{});  // bytes are borrowed; keep them alive
//!   defer reader.deinit();
//!   const n = reader.pageCount();
//!   const page = reader.page(0);                          // page.media_box, page.rotate
//!
//! What it reads (ISO 32000-1 7.5): the cross-reference data as a classic `xref` table or as a
//! cross-reference stream, object streams, incremental updates (every /Prev section; the newest
//! entry for an object wins), and hybrid files (/XRefStm). Stream filters: FlateDecode and
//! LZWDecode (with PNG and TIFF predictors), ASCIIHexDecode, ASCII85Decode. The page tree is walked from the
//! catalog; /Count is not trusted, and /Resources, /MediaBox, /CropBox and /Rotate are inherited.
//! A file whose %PDF- header is within its first 1024 bytes but not at byte 0 is read from the
//! header (Reader.headerAt).
//!
//! Encrypted files (7.6): the standard security handler, RC4 and AES (src/crypt.zig says which
//! revisions), opened with Options.password, which is empty unless given: the empty user password
//! opens most encrypted files. Strings are decrypted when their object is loaded from the file,
//! streams before their filters. Not decrypted, as the standard says: the encryption dictionary,
//! cross-reference streams, the objects inside an object stream (the whole stream is), a /Metadata
//! stream when /EncryptMetadata is false, a stream whose /Crypt filter is /Identity, and a
//! signature's /Contents.
//!
//! What it refuses, with an error and never with a guess:
//! - error.PasswordRequired: the file is encrypted, and Options.password is neither its user nor
//!   its owner password.
//! - error.UnsupportedEncryption: an encryption handler or revision src/crypt.zig does not read,
//!   or a crypt filter other than /Identity and /StdCF.
//! - error.UnsupportedFilter: a stream it must decode uses another filter.
//! - error.Malformed: anything else that does not follow the syntax, including a broken xref,
//!   a stream whose /Length does not reach `endstream`, and a reference cycle. There is no repair
//!   (no scanning the file for objects when the xref is wrong).
//! - error.TooDeep, error.TooLarge: nesting or decoded sizes past Options' limits.
//!
//! PDFs are untrusted input: every offset, count and length is checked against the file, and
//! nesting, chains and decoded sizes are bounded, so a hostile file gets an error, not a crash
//! or a hang.
//!
//! Memory: everything the reader parses lives in one arena that `deinit` frees; objects and
//! decoded streams it returns are valid until then.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const read_text = @import("read_text.zig");
const crypt = @import("crypt.zig");
pub const TextRun = read_text.TextRun;
pub const Glyph = read_text.Glyph;
pub const PageText = read_text.PageText;

pub const Options = struct {
    /// The largest stream it decodes, in bytes, after its filters.
    max_stream_bytes: usize = 256 << 20,
    /// The deepest nesting of arrays and dictionaries, and of the page tree.
    max_depth: u32 = 64,
    /// The most content-stream operators one pageText runs, forms included: a form drawn many
    /// times by forms drawn many times multiplies, and this bounds the work.
    max_operations: u32 = 1 << 24,
    /// The most glyphs one pageText returns.
    max_page_glyphs: u32 = 1 << 22,
    /// The bytes of page work (a page's decoded content streams, its glyph and text lists) the
    /// reader keeps when a page ends, so the next page reuses them instead of asking its allocator
    /// again. A page that needs more still gets it; what is above this is given back when it ends.
    /// The reader's memory still follows one page: it holds at most this much beyond the page being
    /// read. Without it, each page grew its working memory from nothing, which costs a system call
    /// per large block under an allocator that maps them directly (std.heap.smp_allocator).
    max_retained_work: usize = 1 << 20,
    /// The password for an encrypted file, UTF-8: tried as its user password, then as its owner
    /// password. Empty opens the files viewers open without asking (src/crypt.zig).
    password: []const u8 = "",
};

pub const Ref = struct { num: u32, gen: u16 };

pub const Object = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    real: f64,
    /// The decoded bytes of a literal or hex string.
    string: []const u8,
    /// Without the slash, #xx escapes decoded.
    name: []const u8,
    array: []const Object,
    dict: Dict,
    ref: Ref,
    stream: Stream,

    /// An integer or real as f64.
    pub fn number(self: Object) ?f64 {
        return switch (self) {
            .integer => |i| @floatFromInt(i),
            .real => |r| r,
            else => null,
        };
    }
};

pub const Dict = struct {
    entries: []const Entry = &.{},

    pub const Entry = struct { key: []const u8, value: Object };

    /// The value of `key`, unresolved. A key given twice: the first.
    pub fn get(self: Dict, key: []const u8) ?Object {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }
};

pub const Stream = struct {
    dict: Dict,
    /// The encoded bytes, a slice of the file; still encrypted in an encrypted file.
    raw: []const u8,
    /// The object it is, whose number and generation its decryption key is made from.
    ref: Ref,
};

pub const Error = error{ Malformed, PasswordRequired, UnsupportedEncryption, UnsupportedFilter, UnsupportedFont, TooDeep, TooLarge, OutOfMemory };

pub const Page = struct {
    /// The page dictionary, with inherited entries not merged in.
    dict: Dict,
    /// Inherited if the page has none; empty if no ancestor has one.
    resources: Dict,
    /// [x0 y0 x1 y1], inherited. Normalized so x0 <= x1 and y0 <= y1.
    media_box: [4]f64,
    /// Inherited; the media box when absent.
    crop_box: [4]f64,
    /// Degrees clockwise, a multiple of 90 in 0..270.
    rotate: u16,
};

const XrefEntry = union(enum) {
    /// Free in a newer section: reads as null, and older sections cannot give it.
    free,
    offset: struct { at: usize, gen: u16 },
    compressed: struct { stream: u32, index: u32 },
};

pub const Reader = struct {
    arena_state: *std.heap.ArenaAllocator,
    /// pageText's working memory, reset after each page down to options.max_retained_work.
    work_state: *std.heap.ArenaAllocator,
    bytes: []const u8,
    options: Options,
    xref: std.AutoHashMapUnmanaged(u32, XrefEntry) = .empty,
    trailer: Dict = .{},
    cache: std.AutoHashMapUnmanaged(u32, Object) = .empty,
    /// Objects being parsed now, to refuse a cycle (a /Length that refers to its own stream).
    loading: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Decoded object streams, by object number: their data and each object's offset in it.
    object_streams: std.AutoHashMapUnmanaged(u32, ObjectStream) = .empty,
    pages: std.ArrayList(Page) = .empty,
    /// Fonts read_text has parsed, by object number.
    fonts: std.AutoHashMapUnmanaged(u32, *read_text.Font) = .empty,
    /// The security handler of an encrypted file, set once its password is checked.
    crypt: ?crypt.Handler = null,
    /// The encryption dictionary's object number, when it is an indirect object: its strings are
    /// not encrypted.
    encrypt_num: ?u32 = null,

    /// `offsets`: object number then offset, per index; `ends`: where each object's bytes stop
    /// (the next object's offset, or the end), so a value cannot run into the next one.
    const ObjectStream = struct { data: []const u8, offsets: []const u32, ends: []const u32 };

    pub fn open(gpa: Allocator, bytes: []const u8, options: Options) Error!Reader {
        const arena_state = try gpa.create(std.heap.ArenaAllocator);
        arena_state.* = .init(gpa);
        const work_state = gpa.create(std.heap.ArenaAllocator) catch |err| {
            gpa.destroy(arena_state);
            return err;
        };
        work_state.* = .init(gpa);
        var self: Reader = .{ .arena_state = arena_state, .work_state = work_state, .bytes = bytes[headerAt(bytes)..], .options = options };
        errdefer self.deinit();
        try self.readXref();
        try self.openEncryption();
        try self.readPages();
        return self;
    }

    /// Where the file starts: at its %PDF- header when that is not at byte 0 but within the first
    /// 1024 bytes, as Adobe's readers allow (PDF 1.7 Reference, Appendix H, note 13), else 0. A web
    /// server that writes a tag or a byte order mark before a PDF leaves the PDF's own offsets
    /// counted from its header, so they are read from there. When they are not, the xref does not
    /// read, and the file is Malformed as before.
    fn headerAt(bytes: []const u8) usize {
        if (std.mem.startsWith(u8, bytes, "%PDF-")) return 0;
        return std.mem.indexOf(u8, bytes[0..@min(bytes.len, 1024)], "%PDF-") orelse 0;
    }

    pub fn deinit(self: *Reader) void {
        const gpa = self.arena_state.child_allocator;
        self.arena_state.deinit();
        gpa.destroy(self.arena_state);
        self.work_state.deinit();
        gpa.destroy(self.work_state);
        self.* = undefined;
    }

    fn arena(self: *Reader) Allocator {
        return self.arena_state.allocator();
    }

    /// The reader's own arena, for data that lives until deinit (read_text's fonts).
    pub fn arenaAllocator(self: *Reader) Allocator {
        return self.arena_state.allocator();
    }

    /// The scope of the reader's own arena: objects cached, results valid until deinit.
    pub fn documentScope(self: *Reader) Scope {
        return .{ .r = self, .arena = self.arena_state };
    }

    /// A scope in `arena`, which the caller resets or frees: results valid until then.
    pub fn scopeIn(self: *Reader, arena_state: *std.heap.ArenaAllocator) Scope {
        return .{ .r = self, .arena = arena_state };
    }

    /// The text page `index` draws, as runs (read_text.zig says what a run is). The result owns
    /// its memory: call its deinit. Fonts are parsed once and kept by the reader.
    pub fn pageText(self: *Reader, gpa: Allocator, index: usize) Error!PageText {
        return read_text.pageText(self, gpa, index);
    }

    /// pageText without the copy: the runs, their text, glyphs and font names are in the
    /// reader's work memory, valid until endPageRuns, the next pageRuns or pageText call, or
    /// deinit. For a caller that encodes them at once (the C ABI). Call endPageRuns when done: it
    /// gives the work memory back down to options.max_retained_work. The next page call does
    /// that first anyway, so the reader never holds more than one page's work.
    pub fn pageRuns(self: *Reader, index: usize) Error!read_text.PageRuns {
        return read_text.pageRuns(self, index);
    }

    pub fn endPageRuns(self: *Reader) void {
        read_text.endPageRuns(self);
    }

    pub fn pageCount(self: *const Reader) usize {
        return self.pages.items.len;
    }

    /// Page `index` (0-based); index must be below pageCount.
    pub fn page(self: *const Reader, index: usize) Page {
        return self.pages.items[index];
    }

    /// The trailer of the newest section: /Root, /Info, /ID.
    pub fn trailerDict(self: *const Reader) Dict {
        return self.trailer;
    }

    /// Object `num`, parsed once and cached. A free or missing object is null (7.3.10).
    pub fn object(self: *Reader, num: u32) Error!Object {
        return self.documentScope().load(num);
    }

    /// `obj`, with a reference followed to its object (a chain of references too).
    pub fn resolve(self: *Reader, obj: Object) Error!Object {
        return self.documentScope().resolve(obj);
    }

    /// dict[key], resolved; null when absent or null.
    pub fn getResolved(self: *Reader, dict: Dict, key: []const u8) Error!?Object {
        const v = dict.get(key) orelse return null;
        const r = try self.resolve(v);
        return if (r == .null) null else r;
    }

    /// The decoded data of `stream`, owned by the reader: valid until deinit, never freed by
    /// the caller. For data read once and dropped, decodeStream does not grow the reader.
    pub fn streamData(self: *Reader, stream: Stream) Error![]const u8 {
        return self.documentScope().decode(stream);
    }

    /// The decoded data of `stream`, owned by the caller: free it with `allocator`. Always a
    /// new allocation, also for a stream with no filter. The filters' intermediate buffers
    /// are freed before it returns.
    pub fn decodeStream(self: *Reader, allocator: Allocator, stream: Stream) Error![]u8 {
        var scratch: std.heap.ArenaAllocator = .init(self.arena_state.child_allocator);
        defer scratch.deinit();
        return allocator.dupe(u8, try self.scopeIn(&scratch).decode(stream));
    }

    fn intParam(self: *Reader, d: Dict, key: []const u8, default: i64) Error!i64 {
        const v = (try self.getResolved(d, key)) orelse return default;
        return switch (v) {
            .integer => |i| i,
            else => error.Malformed,
        };
    }

    // ---- encryption ----

    /// The trailer's /Encrypt read, and Options.password checked against it (src/crypt.zig). How
    /// /Encrypt is read follows MuPDF's pdf_new_crypt where the standard leaves room: a /Length
    /// under 40 is in bytes, not bits; a /CF entry's /Length is too; with no /CF, /StdCF is RC4;
    /// R5 and R6 use AES-256 whatever /CFM says, unless it is /None.
    fn openEncryption(self: *Reader) Error!void {
        const enc_obj = self.trailer.get("Encrypt") orelse return;
        if (enc_obj == .ref) {
            // Never in an object stream (7.5.7): that stream would be read undecrypted.
            const entry = self.xref.get(enc_obj.ref.num) orelse return error.Malformed;
            if (entry == .compressed) return error.Malformed;
            self.encrypt_num = enc_obj.ref.num;
        }
        const enc = switch (try self.resolve(enc_obj)) {
            .dict => |d| d,
            else => return error.Malformed,
        };
        if (!nameIs(try self.getResolved(enc, "Filter"), "Standard")) return error.UnsupportedEncryption;
        const v = try self.intParam(enc, "V", 0);
        const r = try self.intParam(enc, "R", -1);
        if (r < 0) return error.Malformed;
        // Before reading the rest, which differs by revision.
        if (r < 2 or r > 6) return error.UnsupportedEncryption;
        switch (v) {
            1, 2, 4, 5 => {},
            else => return error.UnsupportedEncryption,
        }
        var length: i64 = 40;
        if (v == 2 or v == 4) length = try keyBits(try self.intParam(enc, "Length", 40));
        var params: crypt.Params = .{
            .v = v,
            .r = r,
            .length = length,
            .o = try self.stringParam(enc, "O"),
            .u = try self.stringParam(enc, "U"),
            .oe = if (r >= 5) try self.stringParam(enc, "OE") else &.{},
            .ue = if (r >= 5) try self.stringParam(enc, "UE") else &.{},
            .p = try self.intParam(enc, "P", 0),
            .id = try self.firstId(),
            .encrypt_metadata = switch ((try self.getResolved(enc, "EncryptMetadata")) orelse Object{ .boolean = true }) {
                .boolean => |b| b,
                else => return error.Malformed,
            },
            .string_method = .rc4,
            .stream_method = .rc4,
            .std_cf_method = .rc4,
        };
        if (v == 4 or v == 5) {
            const cf: ?Dict = switch ((try self.getResolved(enc, "CF")) orelse Object.null) {
                .dict => |d| d,
                .null => null,
                else => return error.Malformed,
            };
            const stm = try self.cryptFilter(cf, try self.getResolved(enc, "StmF"), r, length);
            const str = try self.cryptFilter(cf, try self.getResolved(enc, "StrF"), r, length);
            const std_cf = try self.cryptFilter(cf, .{ .name = "StdCF" }, r, length);
            params.stream_method = stm.method;
            params.string_method = str.method;
            params.std_cf_method = std_cf.method;
            // The crypt filter gives the key length: the stream filter's, else the string's.
            if (stm.method != .none) {
                params.length = stm.length;
            } else if (str.method != .none) params.length = str.length;
        }
        // The objects loaded so far were read undecrypted: the encryption dictionary and what it
        // refers to, which are never decrypted, and a cross-reference stream's /Length, an integer.
        // An object stream read so early (for a /Length inside one) would stay cached undecrypted:
        // refused, not read wrong.
        if (self.object_streams.count() != 0) return error.Malformed;
        self.crypt = try crypt.Handler.authenticate(params, self.options.password);
    }

    /// The method and key length of the crypt filter `name` (/StmF or /StrF; /Identity when
    /// absent), from /CF (7.6.6).
    fn cryptFilter(self: *Reader, cf: ?Dict, name_obj: ?Object, r: i64, length: i64) Error!struct { method: crypt.Method, length: i64 } {
        const name = name_obj orelse return .{ .method = .none, .length = length };
        if (nameIs(name, "Identity")) return .{ .method = .none, .length = length };
        if (!nameIs(name, "StdCF")) return error.UnsupportedEncryption;
        const filters = cf orelse return .{ .method = .rc4, .length = length };
        const entry = switch ((try self.getResolved(filters, "StdCF")) orelse return error.Malformed) {
            .dict => |d| d,
            else => return error.Malformed,
        };
        const cfm = (try self.getResolved(entry, "CFM")) orelse Object{ .name = "None" };
        var method: crypt.Method = if (nameIs(cfm, "None"))
            .none
        else if (nameIs(cfm, "V2"))
            .rc4
        else if (nameIs(cfm, "AESV2"))
            .aesv2
        else if (nameIs(cfm, "AESV3"))
            .aesv3
        else
            return error.UnsupportedEncryption;
        if (r >= 5 and method != .none) method = .aesv3;
        const default: i64 = switch (method) {
            .aesv2 => 128,
            .aesv3 => 256,
            else => length,
        };
        const bits = try keyBits(try self.intParam(entry, "Length", default));
        return .{ .method = method, .length = bits };
    }

    /// A key length in bits; under 40 it was given in bytes, as some writers do.
    fn keyBits(n: i64) Error!i64 {
        const bits = if (n < 40) n * 8 else n;
        if (@mod(bits, 8) != 0) return error.Malformed;
        return bits;
    }

    fn stringParam(self: *Reader, d: Dict, key: []const u8) Error![]const u8 {
        return switch ((try self.getResolved(d, key)) orelse return error.Malformed) {
            .string => |s| s,
            else => error.Malformed,
        };
    }

    /// The first string of the trailer's /ID, or empty when there is none (MuPDF reads such a
    /// file with an empty one).
    fn firstId(self: *Reader) Error![]const u8 {
        const id = (try self.getResolved(self.trailer, "ID")) orelse return &.{};
        const items = switch (id) {
            .array => |a| a,
            else => return error.Malformed,
        };
        if (items.len == 0) return &.{};
        return switch (try self.resolve(items[0])) {
            .string => |s| s,
            else => error.Malformed,
        };
    }

    // ---- cross-reference data ----

    fn readXref(self: *Reader) Error!void {
        var at = try findStartXref(self.bytes);
        var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
        var newest = true;
        while (true) {
            if (seen.contains(at)) return error.Malformed;
            if (seen.count() >= 1024) return error.TooDeep;
            try seen.put(self.arena(), at, {});
            var frees: std.ArrayList(u32) = .empty;
            const trailer = try self.readXrefSection(at, &frees);
            if (newest) {
                self.trailer = trailer;
                newest = false;
            }
            // A hybrid file's table section names a stream holding more entries (7.5.8.4),
            // typically the objects in object streams, which the table marks free so older
            // readers skip them. The table's in-use entries win; its free entries are applied
            // after the stream's, so they cannot hide what the stream gives.
            if (trailer.get("XRefStm")) |x| switch (x) {
                .integer => |off| {
                    var none: std.ArrayList(u32) = .empty;
                    _ = try self.readXrefSection(try self.fileOffset(off), &none);
                },
                else => return error.Malformed,
            };
            for (frees.items) |num| {
                if (!self.xref.contains(num)) try self.freed(num);
            }
            const prev = trailer.get("Prev") orelse break;
            at = switch (prev) {
                .integer => |off| try self.fileOffset(off),
                else => return error.Malformed,
            };
        }
        if (self.trailer.get("Root") == null) return error.Malformed;
    }

    fn fileOffset(self: *const Reader, off: i64) Error!usize {
        if (off < 0 or off >= self.bytes.len) return error.Malformed;
        return @intCast(off);
    }

    /// One section at `at`: adds the entries not already known (newer sections are read first)
    /// and returns its trailer dictionary. A table's free entries go to `frees`, for the caller
    /// to apply after the section's /XRefStm.
    fn readXrefSection(self: *Reader, at: usize, frees: *std.ArrayList(u32)) Error!Dict {
        var lx: Lexer = .{ .src = self.bytes, .pos = at };
        const first = try lx.next(self.arena_state);
        if (first == .keyword and std.mem.eql(u8, first.keyword, "xref")) return self.readXrefTable(&lx, frees);
        // Otherwise a cross-reference stream: "n g obj << ... >> stream".
        lx.pos = at;
        const head = try parseIndirectHead(&lx, self.arena_state);
        var p: Parser = .{ .lx = &lx, .arena = self.arena_state, .max_depth = self.options.max_depth };
        const value = try p.parseValue(0);
        const stream = try self.documentScope().finishObject(&lx, value, head);
        const s = switch (stream) {
            .stream => |s| s,
            else => return error.Malformed,
        };
        if (!nameIs(s.dict.get("Type"), "XRef")) return error.Malformed;
        try self.readXrefStream(s);
        return s.dict;
    }

    fn readXrefTable(self: *Reader, lx: *Lexer, frees: *std.ArrayList(u32)) Error!Dict {
        while (true) {
            const t = try lx.next(self.arena_state);
            switch (t) {
                .keyword => |k| {
                    if (!std.mem.eql(u8, k, "trailer")) return error.Malformed;
                    var p: Parser = .{ .lx = lx, .arena = self.arena_state, .max_depth = self.options.max_depth };
                    return switch (try p.parseValue(0)) {
                        .dict => |d| d,
                        else => error.Malformed,
                    };
                },
                .integer => |start| {
                    const count = switch (try lx.next(self.arena_state)) {
                        .integer => |c| c,
                        else => return error.Malformed,
                    };
                    if (start < 0 or count < 0 or start > std.math.maxInt(u32) or count > std.math.maxInt(u32) or start + count > std.math.maxInt(u32)) return error.Malformed;
                    // Each entry is at least 18 bytes: a count past what the file holds is a lie.
                    if (@as(u64, @intCast(count)) * 18 > self.bytes.len - lx.pos) return error.Malformed;
                    var i: i64 = 0;
                    while (i < count) : (i += 1) {
                        const off = try lx.next(self.arena_state);
                        const gen = try lx.next(self.arena_state);
                        const kind = try lx.next(self.arena_state);
                        if (off != .integer or gen != .integer or kind != .keyword) return error.Malformed;
                        const num: u32 = @intCast(start + i);
                        if (std.mem.eql(u8, kind.keyword, "n")) {
                            if (num == 0) continue;
                            if (gen.integer < 0 or gen.integer > 65535) return error.Malformed;
                            const gop = try self.xref.getOrPut(self.arena(), num);
                            if (!gop.found_existing) gop.value_ptr.* = .{ .offset = .{ .at = try self.fileOffset(off.integer), .gen = @intCast(gen.integer) } };
                        } else if (std.mem.eql(u8, kind.keyword, "f")) {
                            // A free entry in a newer section hides older ones. It is applied
                            // after this section's /XRefStm, which may give the object instead.
                            if (num != 0) try frees.append(self.arena(), num);
                        } else return error.Malformed;
                    }
                },
                else => return error.Malformed,
            }
        }
    }

    fn freed(self: *Reader, num: u32) Error!void {
        try self.xref.put(self.arena(), num, .free);
    }

    fn readXrefStream(self: *Reader, s: Stream) Error!void {
        const w = switch (s.dict.get("W") orelse return error.Malformed) {
            .array => |a| a,
            else => return error.Malformed,
        };
        if (w.len != 3) return error.Malformed;
        var widths: [3]usize = undefined;
        for (w, 0..) |v, i| {
            const n = switch (v) {
                .integer => |n| n,
                else => return error.Malformed,
            };
            if (n < 0 or n > 8) return error.Malformed;
            widths[i] = @intCast(n);
        }
        const size = switch (s.dict.get("Size") orelse return error.Malformed) {
            .integer => |n| n,
            else => return error.Malformed,
        };
        if (size < 0 or size > std.math.maxInt(u32)) return error.Malformed;
        const default_index = [_]Object{ .{ .integer = 0 }, .{ .integer = size } };
        const index: []const Object = if (s.dict.get("Index")) |ix| switch (ix) {
            .array => |a| a,
            else => return error.Malformed,
        } else &default_index;
        if (index.len % 2 != 0) return error.Malformed;
        // The xref stream's own filters are direct objects: nothing to resolve yet.
        const data = try self.streamData(s);
        const entry_len = widths[0] + widths[1] + widths[2];
        if (entry_len == 0) return error.Malformed;
        var at: usize = 0;
        var pair: usize = 0;
        while (pair < index.len) : (pair += 2) {
            const start = switch (index[pair]) {
                .integer => |n| n,
                else => return error.Malformed,
            };
            const count = switch (index[pair + 1]) {
                .integer => |n| n,
                else => return error.Malformed,
            };
            if (start < 0 or count < 0 or start > std.math.maxInt(u32) or count > std.math.maxInt(u32) or start + count > std.math.maxInt(u32)) return error.Malformed;
            if (@as(u64, @intCast(count)) * entry_len > data.len - at) return error.Malformed;
            var i: i64 = 0;
            while (i < count) : (i += 1) {
                const field = data[at..][0..entry_len];
                at += entry_len;
                const kind = if (widths[0] == 0) 1 else std.mem.readVarInt(u64, field[0..widths[0]], .big);
                const f2 = std.mem.readVarInt(u64, field[widths[0]..][0..widths[1]], .big);
                const f3 = std.mem.readVarInt(u64, field[widths[0] + widths[1] ..][0..widths[2]], .big);
                const num: u32 = @intCast(start + i);
                if (num == 0) continue;
                switch (kind) {
                    0 => if (!self.xref.contains(num)) try self.freed(num),
                    1 => {
                        const gop = try self.xref.getOrPut(self.arena(), num);
                        if (!gop.found_existing) {
                            if (f2 >= self.bytes.len or f3 > 65535) return error.Malformed;
                            gop.value_ptr.* = .{ .offset = .{ .at = @intCast(f2), .gen = @intCast(f3) } };
                        }
                    },
                    2 => {
                        const gop = try self.xref.getOrPut(self.arena(), num);
                        if (!gop.found_existing) {
                            if (f2 == 0 or f2 > std.math.maxInt(u32) or f3 > std.math.maxInt(u32)) return error.Malformed;
                            gop.value_ptr.* = .{ .compressed = .{ .stream = @intCast(f2), .index = @intCast(f3) } };
                        }
                    },
                    // Other types are reserved; 7.5.8.3 says to read them as null.
                    else => if (!self.xref.contains(num)) try self.freed(num),
                }
            }
        }
    }

    // ---- objects ----

    fn objectStream(self: *Reader, num: u32) Error!ObjectStream {
        if (self.object_streams.get(num)) |os| return os;
        // An object stream must be an uncompressed object: one inside another is refused.
        const entry = self.xref.get(num) orelse return error.Malformed;
        if (entry != .offset) return error.Malformed;
        const s = switch (try self.object(num)) {
            .stream => |s| s,
            else => return error.Malformed,
        };
        if (!nameIs(s.dict.get("Type"), "ObjStm")) return error.Malformed;
        const n = switch ((try self.getResolved(s.dict, "N")) orelse return error.Malformed) {
            .integer => |v| v,
            else => return error.Malformed,
        };
        const first = switch ((try self.getResolved(s.dict, "First")) orelse return error.Malformed) {
            .integer => |v| v,
            else => return error.Malformed,
        };
        const data = try self.streamData(s);
        if (n < 0 or first < 0 or first > data.len or n > data.len) return error.Malformed;
        // Each header pair is at least "1 0" plus a separator: a count the header cannot hold is
        // refused before allocating for it.
        if (n * 3 > first + 1) return error.Malformed;
        const offsets = try self.arena().alloc(u32, @intCast(n * 2));
        var lx: Lexer = .{ .src = data[0..@intCast(first)], .pos = 0 };
        for (0..@intCast(n)) |i| {
            const obj_num = try lx.next(self.arena_state);
            const rel = try lx.next(self.arena_state);
            if (obj_num != .integer or rel != .integer) return error.Malformed;
            if (obj_num.integer < 0 or obj_num.integer > std.math.maxInt(u32)) return error.Malformed;
            if (rel.integer < 0 or rel.integer > data.len - @as(usize, @intCast(first))) return error.Malformed;
            offsets[i * 2] = @intCast(obj_num.integer);
            offsets[i * 2 + 1] = @intCast(first + rel.integer);
        }
        // Offsets increase (7.5.7): each object ends where the next begins.
        const ends = try self.arena().alloc(u32, @intCast(n));
        for (0..@intCast(n)) |i| {
            const off = offsets[i * 2 + 1];
            const next: u32 = if (i + 1 < n) offsets[(i + 1) * 2 + 1] else @intCast(data.len);
            if (next < off) return error.Malformed;
            ends[i] = next;
        }
        const os: ObjectStream = .{ .data = data, .offsets = offsets, .ends = ends };
        try self.object_streams.put(self.arena(), num, os);
        return os;
    }

    // ---- pages ----

    fn readPages(self: *Reader) Error!void {
        const catalog = switch (try self.resolve(self.trailer.get("Root").?)) {
            .dict => |d| d,
            else => return error.Malformed,
        };
        const root = catalog.get("Pages") orelse return error.Malformed;
        var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
        const none: Inherited = .{ .resources = .{}, .media_box = null, .crop_box = null, .rotate = 0 };
        try self.walkPages(root, none, &visited, 0);
    }

    const Inherited = struct { resources: Dict, media_box: ?[4]f64, crop_box: ?[4]f64, rotate: i64 };

    fn walkPages(self: *Reader, node_ref: Object, parent: Inherited, visited: *std.AutoHashMapUnmanaged(u32, void), depth: u32) Error!void {
        if (depth > self.options.max_depth) return error.TooDeep;
        if (node_ref == .ref) {
            if (visited.contains(node_ref.ref.num)) return error.Malformed;
            try visited.put(self.arena(), node_ref.ref.num, {});
        }
        const node = switch (try self.resolve(node_ref)) {
            .dict => |d| d,
            else => return error.Malformed,
        };
        var here = parent;
        if (try self.getResolved(node, "Resources")) |r| here.resources = switch (r) {
            .dict => |d| d,
            else => return error.Malformed,
        };
        if (try self.getResolved(node, "MediaBox")) |b| here.media_box = try self.rect(b);
        if (try self.getResolved(node, "CropBox")) |b| here.crop_box = try self.rect(b);
        if (try self.getResolved(node, "Rotate")) |r| here.rotate = switch (r) {
            .integer => |i| i,
            else => return error.Malformed,
        };
        // A node with /Kids is an intermediate node, whatever its /Type says.
        if (try self.getResolved(node, "Kids")) |kids_obj| {
            const kids = switch (kids_obj) {
                .array => |a| a,
                else => return error.Malformed,
            };
            for (kids) |kid| try self.walkPages(kid, here, visited, depth + 1);
            return;
        }
        const media = here.media_box orelse return error.Malformed;
        if (@mod(here.rotate, 90) != 0) return error.Malformed;
        try self.pages.append(self.arena(), .{
            .dict = node,
            .resources = here.resources,
            .media_box = media,
            .crop_box = here.crop_box orelse media,
            .rotate = @intCast(@mod(here.rotate, 360)),
        });
    }

    /// Scope.pageContents, owned by the caller: free it with `allocator`.
    pub fn pageContents(self: *Reader, allocator: Allocator, p: Page) Error!?[]u8 {
        var scratch: std.heap.ArenaAllocator = .init(self.arena_state.child_allocator);
        defer scratch.deinit();
        const content = (try self.scopeIn(&scratch).pageContents(p)) orelse return null;
        return try allocator.dupe(u8, content);
    }

    /// A rectangle (7.9.5): four finite numbers, normalized so x0 <= x1 and y0 <= y1.
    pub fn rect(self: *Reader, obj: Object) Error![4]f64 {
        const a = switch (obj) {
            .array => |a| a,
            else => return error.Malformed,
        };
        if (a.len != 4) return error.Malformed;
        var r: [4]f64 = undefined;
        for (a, 0..) |v, i| {
            r[i] = (try self.resolve(v)).number() orelse return error.Malformed;
            if (!std.math.isFinite(r[i])) return error.Malformed;
        }
        return .{ @min(r[0], r[2]), @min(r[1], r[3]), @max(r[0], r[2]), @max(r[1], r[3]) };
    }
};

/// Where the reader parses, decodes and decrypts into, and so how long what it returns lives.
///
/// What a Scope method returns is in `arena`, or is a slice of the file's bytes: valid while both
/// the arena and the file are, and never freed by the caller. Two kinds:
/// - Reader.documentScope, the reader's own arena: each object is parsed once and cached, and
///   results are valid until Reader.deinit.
/// - Reader.scopeIn, an arena the caller resets or frees: an object not cached yet is parsed for
///   this use only and not cached, so what one page reads once (its content streams) does not
///   grow the reader. What such an object refers to (a /Length, a /Filter, an object stream) is
///   still loaded through the document scope.
pub const Scope = struct {
    r: *Reader,
    arena: *std.heap.ArenaAllocator,

    /// Only the reader's own arena may fill its cache: any other one is reset while the cache
    /// would still hold what it parsed.
    fn caches(s: Scope) bool {
        return s.arena == s.r.arena_state;
    }

    fn allocator(s: Scope) Allocator {
        return s.arena.allocator();
    }

    /// Object `num`; a free or missing object is null (7.3.10).
    pub fn load(s: Scope, num: u32) Error!Object {
        const r = s.r;
        if (r.cache.get(num)) |o| return o;
        const entry = r.xref.get(num) orelse return .null;
        if (r.loading.contains(num)) return error.Malformed;
        // Loading one object can load another (a /Length, an object stream): bound the chain,
        // which a file of streams whose /Length each refers to the next would make deep.
        if (r.loading.count() >= r.options.max_depth) return error.TooDeep;
        try r.loading.put(r.arena(), num, {});
        defer _ = r.loading.remove(num);
        const obj = switch (entry) {
            .free => .null,
            .offset => |o| try s.parseIndirectAt(num, o.at, o.gen),
            .compressed => |c| try s.parseCompressed(num, c.stream, c.index),
        };
        if (s.caches()) try r.cache.put(r.arena(), num, obj);
        return obj;
    }

    /// `obj`, with a reference followed to its object (a chain of references too).
    pub fn resolve(s: Scope, obj: Object) Error!Object {
        var o = obj;
        var hops: u32 = 0;
        while (o == .ref) : (hops += 1) {
            if (hops >= s.r.options.max_depth) return error.TooDeep;
            // A reference whose generation is not the xref entry's names an object that no
            // longer exists: null (7.3.10). Objects in object streams have generation 0.
            const entry = s.r.xref.get(o.ref.num) orelse return .null;
            const gen: u16 = switch (entry) {
                .free => return .null,
                .offset => |e| e.gen,
                .compressed => 0,
            };
            if (gen != o.ref.gen) return .null;
            o = try s.load(o.ref.num);
        }
        return o;
    }

    /// The page's content: its /Contents streams decoded and joined with a newline (a content
    /// stream may be split anywhere between tokens, 7.8.2). null when the page has no /Contents
    /// (a blank page).
    pub fn pageContents(s: Scope, p: Page) Error!?[]const u8 {
        const contents = try s.resolve(p.dict.get("Contents") orelse return null);
        switch (contents) {
            .null => return null,
            .stream => |st| return try s.decode(st),
            .array => |parts| {
                var out: std.ArrayList(u8) = .empty;
                for (parts) |part| {
                    const st = switch (try s.resolve(part)) {
                        .stream => |st| st,
                        else => return error.Malformed,
                    };
                    try out.appendSlice(s.allocator(), try s.decode(st));
                    try out.append(s.allocator(), '\n');
                }
                return out.items;
            },
            else => return error.Malformed,
        }
    }

    /// The decoded data of `stream`.
    pub fn decode(s: Scope, stream: Stream) Error![]const u8 {
        const data = try s.decodeFilters(stream);
        // Every path, unfiltered included, keeps to the limit callers rely on.
        if (data.len > s.r.options.max_stream_bytes) return error.TooLarge;
        return data;
    }

    fn decodeFilters(s: Scope, stream: Stream) Error![]const u8 {
        const filter_obj = try s.r.getResolved(stream.dict, "Filter");
        const params = try s.r.getResolved(stream.dict, "DecodeParms");
        var data = try s.decryptStream(stream, filter_obj, params);
        const filters = filter_obj orelse return data;
        switch (filters) {
            .name => |n| data = try s.applyFilter(n, if (params) |p| p else .null, data),
            .array => |list| {
                if (list.len > 16) return error.TooDeep;
                for (list, 0..) |f, i| {
                    const name = switch (try s.r.resolve(f)) {
                        .name => |n| n,
                        else => return error.Malformed,
                    };
                    // A /Crypt filter comes first (7.4.10); decryptStream has applied it.
                    if (i > 0 and std.mem.eql(u8, name, "Crypt")) return error.Malformed;
                    const p: Object = if (params) |ps| switch (ps) {
                        .array => |pa| if (i < pa.len) try s.r.resolve(pa[i]) else .null,
                        else => return error.Malformed,
                    } else .null;
                    data = try s.applyFilter(name, p, data);
                }
            },
            else => return error.Malformed,
        }
        return data;
    }

    fn applyFilter(s: Scope, name: []const u8, params: Object, data: []const u8) Error![]const u8 {
        const a = s.allocator();
        const max = s.r.options.max_stream_bytes;
        if (std.mem.eql(u8, name, "FlateDecode") or std.mem.eql(u8, name, "Fl")) {
            const inflated = try inflate(a, data, max);
            return try s.unpredict(params, inflated);
        }
        if (std.mem.eql(u8, name, "LZWDecode") or std.mem.eql(u8, name, "LZW")) {
            const early_change = switch (params) {
                .dict => |d| try s.r.intParam(d, "EarlyChange", 1),
                .null => 1,
                else => return error.Malformed,
            };
            if (early_change != 0 and early_change != 1) return error.Malformed;
            const decoded = try lzw(a, data, early_change == 1, max);
            return try s.unpredict(params, decoded);
        }
        if (std.mem.eql(u8, name, "ASCIIHexDecode") or std.mem.eql(u8, name, "AHx")) return asciiHex(a, data, max);
        if (std.mem.eql(u8, name, "ASCII85Decode") or std.mem.eql(u8, name, "A85")) return ascii85(a, data, max);
        if (std.mem.eql(u8, name, "Crypt")) return data;
        return error.UnsupportedFilter;
    }

    /// The stream's data decrypted (7.6.2), or its raw bytes when the file is not
    /// encrypted or the stream is not: a cross-reference stream, a /Metadata stream when
    /// /EncryptMetadata is false, or one whose /Crypt filter is /Identity (7.4.10). A /Crypt
    /// filter names its crypt filter in its /DecodeParms /Name: /Identity when absent, or /StdCF.
    fn decryptStream(s: Scope, stream: Stream, filters: ?Object, params: ?Object) Error![]const u8 {
        const h = s.r.crypt orelse return stream.raw;
        if (nameIs(stream.dict.get("Type"), "XRef")) return stream.raw;
        if (!h.encrypt_metadata and nameIs(stream.dict.get("Type"), "Metadata")) return stream.raw;
        var method = h.stream_method;
        const first: ?Object = if (filters) |f| switch (f) {
            .name => f,
            .array => |list| if (list.len > 0) try s.r.resolve(list[0]) else null,
            else => null,
        } else null;
        if (first != null and nameIs(first, "Crypt")) {
            const p: ?Object = if (params) |ps| switch (ps) {
                .array => |pa| if (pa.len > 0) try s.r.resolve(pa[0]) else null,
                else => ps,
            } else null;
            const name: Object = if (p) |pd| switch (pd) {
                .dict => |d| (try s.r.getResolved(d, "Name")) orelse .{ .name = "Identity" },
                .null => .{ .name = "Identity" },
                else => return error.Malformed,
            } else .{ .name = "Identity" };
            if (nameIs(name, "Identity")) {
                method = .none;
            } else if (nameIs(name, "StdCF")) {
                method = h.std_cf_method;
            } else return error.UnsupportedEncryption;
        }
        return h.decrypt(s.arena, method, stream.ref.num, stream.ref.gen, stream.raw);
    }

    /// FlateDecode's and LZWDecode's /Predictor (7.4.4.4): 1 none, 2 TIFF, 10 to 15 PNG (each row says its own).
    fn unpredict(s: Scope, params: Object, data: []const u8) Error![]const u8 {
        const a = s.allocator();
        const p = switch (params) {
            .dict => |d| d,
            .null => return data,
            else => return error.Malformed,
        };
        const predictor = try s.r.intParam(p, "Predictor", 1);
        if (predictor == 1) return data;
        const colors = try s.r.intParam(p, "Colors", 1);
        const bpc = try s.r.intParam(p, "BitsPerComponent", 8);
        const columns = try s.r.intParam(p, "Columns", 1);
        if (colors < 1 or colors > 32 or columns < 1 or columns > 1 << 20) return error.Malformed;
        if (bpc != 1 and bpc != 2 and bpc != 4 and bpc != 8 and bpc != 16) return error.Malformed;
        const bits_per_pixel: usize = @intCast(colors * bpc);
        const row_len: usize = (bits_per_pixel * @as(usize, @intCast(columns)) + 7) / 8;
        // Bytes per complete pixel, rounded up: 3 colours of 4 bits are 2 bytes (PNG's rule).
        const bpp: usize = (bits_per_pixel + 7) / 8;
        if (predictor == 2) {
            // TIFF predictor 2, for 8-bit components only: each byte adds the one `bpp` before it.
            if (bpc != 8) return error.UnsupportedFilter;
            if (data.len % row_len != 0) return error.Malformed;
            const out = try a.dupe(u8, data);
            var row: usize = 0;
            while (row + row_len <= out.len) : (row += row_len) {
                for (bpp..row_len) |i| out[row + i] +%= out[row + i - bpp];
            }
            return out;
        }
        if (predictor < 10 or predictor > 15) return error.Malformed;
        // PNG: each row is one filter-type byte, then row_len bytes. A short row is refused.
        if (data.len % (row_len + 1) != 0) return error.Malformed;
        var out: std.ArrayList(u8) = .empty;
        try out.ensureTotalCapacity(a, data.len);
        var prev = try a.alloc(u8, row_len);
        @memset(prev, 0);
        var at: usize = 0;
        while (at < data.len) {
            const kind = data[at];
            at += 1;
            const n = @min(row_len, data.len - at);
            const row = data[at .. at + n];
            at += n;
            const start = out.items.len;
            for (row, 0..) |b, i| {
                const left: u8 = if (i >= bpp) out.items[start + i - bpp] else 0;
                const up = prev[i];
                const up_left: u8 = if (i >= bpp) prev[i - bpp] else 0;
                const v: u8 = switch (kind) {
                    0 => b,
                    1 => b +% left,
                    2 => b +% up,
                    3 => b +% @as(u8, @intCast((@as(u16, left) + up) / 2)),
                    4 => b +% paeth(left, up, up_left),
                    else => return error.Malformed,
                };
                out.appendAssumeCapacity(v);
            }
            @memcpy(prev[0..n], out.items[start..][0..n]);
        }
        return out.items;
    }

    fn parseIndirectAt(s: Scope, num: u32, at: usize, gen: u16) Error!Object {
        var lx: Lexer = .{ .src = s.r.bytes, .pos = at };
        const head = try parseIndirectHead(&lx, s.arena);
        if (head.num != num or head.gen != gen) return error.Malformed;
        var p: Parser = .{ .lx = &lx, .arena = s.arena, .max_depth = s.r.options.max_depth };
        const value = try p.parseValue(0);
        const obj = try s.finishObject(&lx, value, head);
        const h = s.r.crypt orelse return obj;
        if (s.r.encrypt_num == num) return obj;
        return s.decryptStrings(&h, obj, head);
    }

    /// `obj` with every string in it decrypted (7.6.2); a stream's dictionary too, not
    /// its data (decodeFilters does that). A signature's /Contents is not encrypted (7.6.2).
    fn decryptStrings(s: Scope, h: *const crypt.Handler, obj: Object, ref: Ref) Error!Object {
        switch (obj) {
            .string => |str| return .{ .string = try h.decryptString(s.arena, ref.num, ref.gen, str) },
            .array => |items| {
                const out = try s.allocator().alloc(Object, items.len);
                for (out, items) |*o, item| o.* = try s.decryptStrings(h, item, ref);
                return .{ .array = out };
            },
            .dict => |d| return .{ .dict = try s.decryptDict(h, d, ref) },
            .stream => |st| return .{ .stream = .{ .dict = try s.decryptDict(h, st.dict, ref), .raw = st.raw, .ref = st.ref } },
            else => return obj,
        }
    }

    fn decryptDict(s: Scope, h: *const crypt.Handler, d: Dict, ref: Ref) Error!Dict {
        // As MuPDF tells a signature: /Type /Sig with /Contents, /ByteRange and /Filter.
        const signature = nameIs(d.get("Type"), "Sig") and d.get("Contents") != null and
            d.get("ByteRange") != null and d.get("Filter") != null;
        const out = try s.allocator().alloc(Dict.Entry, d.entries.len);
        for (out, d.entries) |*o, e| {
            o.* = .{ .key = e.key, .value = if (signature and std.mem.eql(u8, e.key, "Contents")) e.value else try s.decryptStrings(h, e.value, ref) };
        }
        return .{ .entries = out };
    }

    /// After an indirect object's value: its stream, when `stream` follows a dictionary, then
    /// `endobj`, which must be there (7.3.10): without it, a value can run into the next object.
    fn finishObject(s: Scope, lx: *Lexer, value: Object, ref: Ref) Error!Object {
        const obj = try s.finishStream(lx, value, ref);
        const end = try lx.next(s.arena);
        if (!(end == .keyword and std.mem.eql(u8, end.keyword, "endobj"))) return error.Malformed;
        return obj;
    }

    /// `stream ... endstream` when it follows a dictionary.
    fn finishStream(s: Scope, lx: *Lexer, value: Object, ref: Ref) Error!Object {
        const dict = switch (value) {
            .dict => |d| d,
            else => return value,
        };
        const save = lx.pos;
        const t = try lx.next(s.arena);
        if (!(t == .keyword and std.mem.eql(u8, t.keyword, "stream"))) {
            lx.pos = save;
            return value;
        }
        // The keyword is followed by CRLF or LF (7.3.8.1); a lone CR is accepted too, nothing
        // else is.
        var start = lx.pos;
        const eol_at = start;
        if (start < s.r.bytes.len and s.r.bytes[start] == '\r') start += 1;
        if (start < s.r.bytes.len and s.r.bytes[start] == '\n') start += 1;
        if (start == eol_at) return error.Malformed;
        const length = switch (try s.r.resolve(dict.get("Length") orelse return error.Malformed)) {
            .integer => |n| n,
            else => return error.Malformed,
        };
        if (length < 0 or length > s.r.bytes.len - start) return error.Malformed;
        const end = start + @as(usize, @intCast(length));
        // After the data: white space (an end-of-line, 7.3.8.1), then `endstream` itself. Not a
        // comment and not anything else: a /Length that falls short must not still find it.
        var at = end;
        while (at < s.r.bytes.len and isWhite(s.r.bytes[at])) at += 1;
        const keyword = "endstream";
        if (!std.mem.startsWith(u8, s.r.bytes[at..], keyword)) return error.Malformed;
        at += keyword.len;
        if (at < s.r.bytes.len and isRegular(s.r.bytes[at])) return error.Malformed;
        lx.pos = at;
        return .{ .stream = .{ .dict = dict, .raw = s.r.bytes[start..end], .ref = ref } };
    }

    fn parseCompressed(s: Scope, num: u32, stream_num: u32, index: u32) Error!Object {
        const os = try s.r.objectStream(stream_num);
        if (index >= os.offsets.len / 2) return error.Malformed;
        if (os.offsets[index * 2] != num) return error.Malformed;
        const off = os.offsets[index * 2 + 1];
        if (off >= os.data.len) return error.Malformed;
        var lx: Lexer = .{ .src = os.data[0..os.ends[index]], .pos = off };
        var p: Parser = .{ .lx = &lx, .arena = s.arena, .max_depth = s.r.options.max_depth };
        // An object in an object stream is never a stream itself (7.5.7), and is all its extent
        // holds: anything after the value is refused.
        const value = try p.parseValue(0);
        if (try lx.next(s.arena) != .eof) return error.Malformed;
        return value;
    }
};

fn nameIs(obj: ?Object, name: []const u8) bool {
    const o = obj orelse return false;
    return o == .name and std.mem.eql(u8, o.name, name);
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// The offset after the last `startxref`, which must be in the file's last 1024 bytes.
fn findStartXref(bytes: []const u8) Error!usize {
    const tail_start = bytes.len -| 1024;
    const at = std.mem.lastIndexOf(u8, bytes[tail_start..], "startxref") orelse return error.Malformed;
    var lx: Lexer = .{ .src = bytes, .pos = tail_start + at + "startxref".len };
    var scratch: [64]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&scratch);
    var arena_state: std.heap.ArenaAllocator = .init(fba.allocator());
    const t = lx.next(&arena_state) catch return error.Malformed;
    if (t != .integer or t.integer < 0 or t.integer >= bytes.len) return error.Malformed;
    return @intCast(t.integer);
}

/// "n g obj" at the lexer's position.
fn parseIndirectHead(lx: *Lexer, a: *std.heap.ArenaAllocator) Error!Ref {
    const n = try lx.next(a);
    const g = try lx.next(a);
    const kw = try lx.next(a);
    if (n != .integer or g != .integer or kw != .keyword or !std.mem.eql(u8, kw.keyword, "obj")) return error.Malformed;
    if (n.integer <= 0 or n.integer > std.math.maxInt(u32) or g.integer < 0 or g.integer > 65535) return error.Malformed;
    return .{ .num = @intCast(n.integer), .gen = @intCast(g.integer) };
}

// ---- syntax ----

pub const Token = union(enum) {
    eof,
    integer: i64,
    real: f64,
    string: []const u8,
    name: []const u8,
    /// A regular-character run that is not a number: true, false, null, R, obj, stream, and
    /// the operators of a content stream.
    keyword: []const u8,
    array_open,
    array_close,
    dict_open,
    dict_close,
};

/// The three kinds of character (7.2.3): white space, delimiters, and the regular characters that
/// make up words. One table, so the lexer's inner loops do one lookup per byte.
const CharClass = enum(u2) { regular, white, delimiter };

const char_class: [256]CharClass = blk: {
    var t: [256]CharClass = @splat(.regular);
    for ([_]u8{ 0, 9, 10, 12, 13, 32 }) |c| t[c] = .white;
    for ("()<>[]{}/%") |c| t[c] = .delimiter;
    break :blk t;
};

pub inline fn isWhite(c: u8) bool {
    return char_class[c] == .white;
}

pub inline fn isDelimiter(c: u8) bool {
    return char_class[c] == .delimiter;
}

inline fn isRegular(c: u8) bool {
    return char_class[c] == .regular;
}

/// PDF tokens (ISO 32000-1 7.2, 7.3). Hex strings, literal strings with an escape, a parenthesis or
/// a CR, and escaped names are decoded into the arena `next` is given; keywords, numbers' text,
/// other literal strings and plain names are slices of `src`. So a token borrows from both: it is
/// valid while both live, and a payload is never freed.
pub const Lexer = struct {
    src: []const u8,
    pos: usize,

    pub fn skipWhite(self: *Lexer) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (isWhite(c)) {
                self.pos += 1;
            } else if (c == '%') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n' and self.src[self.pos] != '\r') self.pos += 1;
            } else break;
        }
    }

    pub fn next(self: *Lexer, arena: *std.heap.ArenaAllocator) Error!Token {
        const a = arena;
        self.skipWhite();
        if (self.pos >= self.src.len) return .eof;
        const c = self.src[self.pos];
        switch (c) {
            '[' => {
                self.pos += 1;
                return .array_open;
            },
            ']' => {
                self.pos += 1;
                return .array_close;
            },
            '<' => {
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '<') {
                    self.pos += 2;
                    return .dict_open;
                }
                return .{ .string = try self.hexString(a) };
            },
            '>' => {
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '>') {
                    self.pos += 2;
                    return .dict_close;
                }
                // Every refusal consumes the character, so a caller that skips bad tokens
                // (read_text's CMap parser) always moves on.
                self.pos += 1;
                return error.Malformed;
            },
            '(' => return .{ .string = try self.literalString(a) },
            '/' => {
                self.pos += 1;
                return .{ .name = try self.name(a) };
            },
            ')', '{', '}' => {
                // Braces only occur in PostScript calculator functions, which this reader
                // never parses as objects.
                self.pos += 1;
                return error.Malformed;
            },
            else => {},
        }
        const start = self.pos;
        while (self.pos < self.src.len and isRegular(self.src[self.pos])) self.pos += 1;
        const word = self.src[start..self.pos];
        if (isNumberStart(word[0])) return number(word);
        return .{ .keyword = word };
    }

    fn name(self: *Lexer, arena: *std.heap.ArenaAllocator) Error![]const u8 {
        const a = arena.allocator();
        const start = self.pos;
        var escaped = false;
        while (self.pos < self.src.len and isRegular(self.src[self.pos])) : (self.pos += 1) {
            if (self.src[self.pos] == '#') escaped = true;
        }
        const raw = self.src[start..self.pos];
        if (!escaped) return raw;
        var out = try a.alloc(u8, raw.len);
        var n: usize = 0;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '#' and i + 2 < raw.len) {
                const hi = hexValue(raw[i + 1]) orelse return error.Malformed;
                const lo = hexValue(raw[i + 2]) orelse return error.Malformed;
                out[n] = hi * 16 + lo;
                i += 2;
            } else if (raw[i] == '#') {
                return error.Malformed;
            } else out[n] = raw[i];
            n += 1;
        }
        return out[0..n];
    }

    fn hexString(self: *Lexer, arena: *std.heap.ArenaAllocator) Error![]const u8 {
        const a = arena.allocator();
        self.pos += 1;
        const end = std.mem.indexOfScalarPos(u8, self.src, self.pos, '>') orelse {
            self.pos = self.src.len;
            return error.Malformed;
        };
        const body = self.src[self.pos..end];
        // One byte per two digits, the last rounded up; white space only makes it shorter.
        const out = try a.alloc(u8, (body.len + 1) / 2);
        var n: usize = 0;
        var half: ?u8 = null;
        for (body, 0..) |c, i| {
            if (isWhite(c)) continue;
            const v = hex_value[c];
            if (v == 0xff) {
                // Past the bad character, as every refusal is.
                self.pos += i + 1;
                return error.Malformed;
            }
            if (half) |h| {
                out[n] = h * 16 + v;
                n += 1;
                half = null;
            } else half = v;
        }
        self.pos = end + 1;
        // An odd digit count: the last digit is followed by 0 (7.3.4.3).
        if (half) |h| {
            out[n] = h * 16;
            n += 1;
        }
        return out[0..n];
    }

    fn literalString(self: *Lexer, arena: *std.heap.ArenaAllocator) Error![]const u8 {
        const a = arena.allocator();
        self.pos += 1;
        // A string with no escape, nested parenthesis or CR is its bytes as they are.
        for (self.src[self.pos..], self.pos..) |c, j| switch (c) {
            ')' => {
                const plain = self.src[self.pos..j];
                self.pos = j + 1;
                return plain;
            },
            '(', '\\', '\r' => break,
            else => {},
        };
        var out: std.ArrayList(u8) = .empty;
        var depth: usize = 1;
        while (true) {
            if (self.pos >= self.src.len) return error.Malformed;
            const c = self.src[self.pos];
            self.pos += 1;
            switch (c) {
                '(' => {
                    depth += 1;
                    try out.append(a, c);
                },
                ')' => {
                    depth -= 1;
                    if (depth == 0) break;
                    try out.append(a, c);
                },
                '\r' => {
                    // An end-of-line in a string is read as one LF (7.3.4.2).
                    if (self.pos < self.src.len and self.src[self.pos] == '\n') self.pos += 1;
                    try out.append(a, '\n');
                },
                '\\' => {
                    if (self.pos >= self.src.len) return error.Malformed;
                    const e = self.src[self.pos];
                    self.pos += 1;
                    switch (e) {
                        'n' => try out.append(a, '\n'),
                        'r' => try out.append(a, '\r'),
                        't' => try out.append(a, '\t'),
                        'b' => try out.append(a, 8),
                        'f' => try out.append(a, 12),
                        '(', ')', '\\' => try out.append(a, e),
                        '\r' => {
                            if (self.pos < self.src.len and self.src[self.pos] == '\n') self.pos += 1;
                        },
                        '\n' => {},
                        '0'...'7' => {
                            // One to three octal digits (7.3.4.2).
                            const start = self.pos - 1;
                            while (self.pos < self.src.len and self.pos - start < 3 and
                                (std.fmt.charToDigit(self.src[self.pos], 8) catch null) != null) self.pos += 1;
                            const v = std.fmt.parseInt(u16, self.src[start..self.pos], 8) catch unreachable;
                            // Overflow (over \377) is ignored, keeping the low byte.
                            try out.append(a, @truncate(v));
                        },
                        // An unknown escape: the backslash is ignored.
                        else => try out.append(a, e),
                    }
                },
                else => try out.append(a, c),
            }
        }
        return out.items;
    }
};

pub fn isNumberStart(c: u8) bool {
    return std.ascii.isDigit(c) or c == '+' or c == '-' or c == '.';
}

fn number(word: []const u8) Error!Token {
    return numberFast(word) orelse numberSlow(word);
}

/// The common shapes, [+-]digits and [+-]digits.digits, read without std.fmt: an integer of at most
/// 18 digits, and a real of at most 15 digits with at most 22 after the point. Then the digits as an
/// integer and the power of ten are both exact as f64, so one division is the correctly rounded
/// value, the one numberSlow's parseFloat gives. Anything else (more digits, a lone sign or point,
/// a character that is not a digit) is left to numberSlow: null.
fn numberFast(word: []const u8) ?Token {
    const pow10 = comptime blk: {
        var t: [23]f64 = undefined;
        var v: f64 = 1;
        for (&t) |*e| {
            e.* = v;
            v *= 10;
        }
        break :blk t;
    };
    var i: usize = 0;
    const neg = word[0] == '-';
    if (word[0] == '-' or word[0] == '+') i = 1;
    var mantissa: u64 = 0;
    var digits: usize = 0;
    var point: ?usize = null;
    while (i < word.len) : (i += 1) {
        const c = word[i];
        if (c >= '0' and c <= '9') {
            if (digits == 18) return null;
            mantissa = mantissa * 10 + (c - '0');
            digits += 1;
        } else if (c == '.' and point == null) {
            point = digits;
        } else return null;
    }
    if (digits == 0) return null;
    const p = point orelse {
        const v: i64 = @intCast(mantissa);
        return .{ .integer = if (neg) -v else v };
    };
    const after = digits - p;
    if (digits > 15 or after > 22) return null;
    const v = @as(f64, @floatFromInt(mantissa)) / pow10[after];
    return .{ .real = if (neg) -v else v };
}

fn numberSlow(word: []const u8) Error!Token {
    for (word) |c| {
        if (!(std.ascii.isDigit(c) or c == '+' or c == '-' or c == '.')) return error.Malformed;
    }
    if (std.mem.indexOfScalar(u8, word, '.') == null) {
        if (std.fmt.parseInt(i64, word, 10)) |i| return .{ .integer = i } else |_| {}
    }
    // A sign only at the start (7.3.3); parseFloat would also take exponents, which PDF has not.
    for (word[1..]) |c| if (c == '+' or c == '-') return error.Malformed;
    const v = std.fmt.parseFloat(f64, word) catch return error.Malformed;
    if (!std.math.isFinite(v)) return error.Malformed;
    return .{ .real = v };
}

fn hexValue(c: u8) ?u8 {
    const v = hex_value[c];
    return if (v == 0xff) null else v;
}

/// Each byte's value as a hex digit, or 0xff.
const hex_value: [256]u8 = blk: {
    var t: [256]u8 = @splat(0xff);
    for ("0123456789", 0..) |c, i| t[c] = i;
    for ("abcdef", 10..) |c, i| t[c] = i;
    for ("ABCDEF", 10..) |c, i| t[c] = i;
    break :blk t;
};

/// Objects from tokens: arrays, dictionaries and `n g R` references.
pub const Parser = struct {
    lx: *Lexer,
    arena: *std.heap.ArenaAllocator,
    max_depth: u32,

    pub fn parseValue(self: *Parser, depth: u32) Error!Object {
        return self.fromToken(try self.lx.next(self.arena), depth);
    }

    fn notRef(self: *Parser, err: Error, save: usize, i: i64) Error!Object {
        if (err != error.Malformed) return err;
        self.lx.pos = save;
        return .{ .integer = i };
    }

    pub fn fromToken(self: *Parser, t: Token, depth: u32) Error!Object {
        switch (t) {
            .eof, .array_close, .dict_close => return error.Malformed,
            .real => |r| return .{ .real = r },
            .string => |s| return .{ .string = s },
            .name => |n| return .{ .name = n },
            .integer => |i| {
                // "n g R" is a reference; anything else leaves the lexer where it was. A token
                // that does not lex is not a reference either: its caller reads it again and
                // decides, so a content stream can skip `1 0.00-30 m` (read_text's Interp.run).
                const save = self.lx.pos;
                const g = self.lx.next(self.arena) catch |err| return self.notRef(err, save, i);
                if (g == .integer) {
                    const r = self.lx.next(self.arena) catch |err| return self.notRef(err, save, i);
                    if (r == .keyword and std.mem.eql(u8, r.keyword, "R")) {
                        if (i <= 0 or i > std.math.maxInt(u32) or g.integer < 0 or g.integer > 65535) return error.Malformed;
                        return .{ .ref = .{ .num = @intCast(i), .gen = @intCast(g.integer) } };
                    }
                }
                self.lx.pos = save;
                return .{ .integer = i };
            },
            .keyword => |k| {
                if (std.mem.eql(u8, k, "true")) return .{ .boolean = true };
                if (std.mem.eql(u8, k, "false")) return .{ .boolean = false };
                if (std.mem.eql(u8, k, "null")) return .null;
                return error.Malformed;
            },
            .array_open => {
                if (depth >= self.max_depth) return error.TooDeep;
                var items: std.ArrayList(Object) = .empty;
                while (true) {
                    const n = try self.lx.next(self.arena);
                    if (n == .array_close) break;
                    try items.append(self.arena.allocator(), try self.fromToken(n, depth + 1));
                }
                return .{ .array = items.items };
            },
            .dict_open => {
                if (depth >= self.max_depth) return error.TooDeep;
                var entries: std.ArrayList(Dict.Entry) = .empty;
                while (true) {
                    const k = try self.lx.next(self.arena);
                    if (k == .dict_close) break;
                    if (k != .name) return error.Malformed;
                    try entries.append(self.arena.allocator(), .{ .key = k.name, .value = try self.parseValue(depth + 1) });
                }
                return .{ .dict = .{ .entries = entries.items } };
            },
        }
    }
};

// ---- filters ----

/// FlateDecode: a zlib stream (RFC 1950), decoded by libdeflate (src/libdeflate_impl.c). Its
/// wrapper is read as std.compress.flate read it before: the header's method 8 and window code at
/// most 7, no FCHECK test, and a 4-byte trailer that must be there but is not compared with the
/// data's Adler-32. libdeflate decodes in one call into a buffer it is given (libdeflate.h,
/// libdeflate_deflate_decompress): the first is 8 times the input, which most streams fit, and a
/// stream that needs more is decoded again into one 4 times larger, up to `max`.
fn inflate(allocator: Allocator, data: []const u8, max: usize) Error![]u8 {
    if (data.len < 2 or data[0] & 0x0f != 8 or data[0] >> 4 > 7) return error.Malformed;
    const body = data[2..];
    const options: LibdeflateOptions = .{
        .sizeof_options = @sizeOf(LibdeflateOptions),
        .malloc_func = libdeflateMalloc,
        .free_func = libdeflateFree,
    };
    const d = libdeflate_alloc_decompressor_ex(&options) orelse return error.OutOfMemory;
    defer libdeflate_free_decompressor(d);
    var capacity = @min(max, body.len *| 8 +| 4096);
    while (true) {
        // Raw, so the buffer is not filled first (ReleaseSafe's Allocator.alloc writes 0xaa over a
        // new block): only what libdeflate writes is returned, and the unused part of the guess is
        // never touched, so it does not become resident memory.
        const len = @max(capacity, 1);
        const buf = allocator.rawAlloc(len, .@"1", @returnAddress()) orelse return error.OutOfMemory;
        var used_in: usize = 0;
        var used_out: usize = 0;
        const result = libdeflate_deflate_decompress_ex(d, body.ptr, body.len, buf, capacity, &used_in, &used_out);
        if (result == .success and body.len - used_in >= 4 and used_out > 0) {
            if (allocator.rawResize(buf[0..len], .@"1", used_out, @returnAddress())) return buf[0..used_out];
            defer allocator.rawFree(buf[0..len], .@"1", @returnAddress());
            return allocator.dupe(u8, buf[0..used_out]);
        }
        allocator.rawFree(buf[0..len], .@"1", @returnAddress());
        switch (result) {
            // The trailer is missing, or the data is empty.
            .success => return if (body.len - used_in >= 4) &.{} else error.Malformed,
            .insufficient_space => {
                if (capacity == max) return error.TooLarge;
                capacity = @min(max, capacity *| 4);
            },
            else => return error.Malformed,
        }
    }
}

const LibdeflateDecompressor = opaque {};
const LibdeflateResult = enum(c_int) { success = 0, bad_data = 1, short_output = 2, insufficient_space = 3, _ };
const LibdeflateOptions = extern struct {
    sizeof_options: usize,
    malloc_func: *const fn (usize) callconv(.c) ?*anyopaque,
    free_func: *const fn (?*anyopaque) callconv(.c) void,
};
extern fn libdeflate_alloc_decompressor_ex(options: *const LibdeflateOptions) ?*LibdeflateDecompressor;
extern fn libdeflate_free_decompressor(d: *LibdeflateDecompressor) void;
extern fn libdeflate_deflate_decompress_ex(d: *LibdeflateDecompressor, in: [*]const u8, in_len: usize, out: [*]u8, out_len: usize, used_in: *usize, used_out: *usize) LibdeflateResult;

/// The allocator for memory C code takes with no context to give it back by: the system's malloc
/// where zpdf links libc, smp_allocator on Linux, where libzpdf links none (build.zig,
/// nativeModule), and wasm_allocator in zpdf.wasm. src/abi.zig takes each context's memory from it.
pub const system_allocator = if (builtin.cpu.arch.isWasm())
    std.heap.wasm_allocator
else if (builtin.link_libc)
    std.heap.c_allocator
else
    std.heap.smp_allocator;

/// libdeflate's malloc and free, over system_allocator. free gets only the pointer, so each block
/// starts with its size; 16 bytes keep the block as aligned as malloc's, which libdeflate assumes
/// for its decompressor (libdeflate_alloc_decompressor_ex).
const libdeflate_header = 16;

/// Blocks libdeflate holds, which no testing allocator sees: a test checks it is 0 after its calls.
var libdeflate_blocks: std.atomic.Value(usize) = .init(0);

fn libdeflateMalloc(size: usize) callconv(.c) ?*anyopaque {
    const block = system_allocator.alignedAlloc(u8, .@"16", libdeflate_header + size) catch return null;
    std.mem.writeInt(usize, block[0..@sizeOf(usize)], block.len, .little);
    _ = libdeflate_blocks.fetchAdd(1, .monotonic);
    return block.ptr + libdeflate_header;
}

fn libdeflateFree(ptr: ?*anyopaque) callconv(.c) void {
    const p: [*]align(16) u8 = @alignCast(@as([*]u8, @ptrCast(ptr orelse return)) - libdeflate_header);
    _ = libdeflate_blocks.fetchSub(1, .monotonic);
    system_allocator.free(p[0..std.mem.readInt(usize, p[0..@sizeOf(usize)], .little)]);
}

/// LZWDecode (7.4.4.2): codes of 9 to 12 bits, most significant bit first. 256 clears the
/// table and 257 ends the data; the end code is required. Each code after the first adds a table
/// entry: the previous code's string and the first byte of this one's (of the previous one's when
/// the code is the entry being added). The code width grows when the next entry needs a wider
/// code, one entry early with /EarlyChange 1. A full table (4096 entries) must be cleared; one code
/// before the clear is read without adding an entry, as MuPDF reads it.
fn lzw(allocator: Allocator, data: []const u8, early_change: bool, max: usize) Error![]u8 {
    const Table = struct { prev: [4096]u16, last: [4096]u8, first: [4096]u8, len: [4096]u16 };
    const t = try allocator.create(Table);
    defer allocator.destroy(t);
    for (0..256) |i| {
        t.prev[i] = 0;
        t.last[i] = @intCast(i);
        t.first[i] = @intCast(i);
        t.len[i] = 1;
    }
    var out: std.ArrayList(u8) = .empty;
    var bits: u5 = 9;
    var next: u32 = 258;
    var prev: ?u16 = null;
    var full_code_read = false;
    var acc: u32 = 0;
    var held: u5 = 0;
    var pos: usize = 0;
    while (true) {
        while (held < bits) {
            if (pos == data.len) return error.Malformed;
            acc = acc << 8 | data[pos];
            pos += 1;
            held += 8;
        }
        held -= bits;
        const code: u16 = @intCast(acc >> held);
        acc &= (@as(u32, 1) << held) - 1;
        if (code == 257) break;
        if (code == 256) {
            bits = 9;
            next = 258;
            prev = null;
            full_code_read = false;
            continue;
        }
        if (prev) |p| {
            if (next == 4096) {
                if (full_code_read) return error.Malformed;
                full_code_read = true;
            } else {
                if (code > next) return error.Malformed;
                t.prev[next] = p;
                t.first[next] = t.first[p];
                t.len[next] = t.len[p] + 1;
                // When the code is this entry, its first byte is the one just set.
                t.last[next] = t.first[code];
                next += 1;
                if (bits < 12 and next + @intFromBool(early_change) >= @as(u32, 1) << bits) bits += 1;
            }
        } else if (code > 255) return error.Malformed;
        const n = t.len[code];
        if (out.items.len + n > max) return error.TooLarge;
        const s = try out.addManyAsSlice(allocator, n);
        var c = code;
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            s[i] = t.last[c];
            c = t.prev[c];
        }
        prev = code;
    }
    return out.items;
}

fn asciiHex(allocator: Allocator, data: []const u8, max: usize) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var half: ?u8 = null;
    var ended = false;
    for (data) |c| {
        if (c == '>') {
            ended = true;
            break;
        }
        if (isWhite(c)) continue;
        const v = hexValue(c) orelse return error.Malformed;
        if (half) |h| {
            if (out.items.len >= max) return error.TooLarge;
            try out.append(allocator, h * 16 + v);
            half = null;
        } else half = v;
    }
    // The end-of-data marker '>' is required (7.4.2).
    if (!ended) return error.Malformed;
    if (half) |h| {
        if (out.items.len >= max) return error.TooLarge;
        try out.append(allocator, h * 16);
    }
    return out.items;
}

fn ascii85(allocator: Allocator, data: []const u8, max: usize) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var ended = false;
    var group: [5]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (isWhite(c)) continue;
        if (c == '~') {
            // The end-of-data marker is "~>" (7.4.3).
            if (i + 1 >= data.len or data[i + 1] != '>') return error.Malformed;
            ended = true;
            break;
        }
        if (out.items.len + 4 > max) return error.TooLarge;
        if (c == 'z' and n == 0) {
            try out.appendNTimes(allocator, 0, 4);
            continue;
        }
        if (c < '!' or c > 'u') return error.Malformed;
        group[n] = c - '!';
        n += 1;
        if (n == 5) {
            try out.appendSlice(allocator, &try base85Group(group));
            n = 0;
        }
    }
    if (!ended) return error.Malformed;
    if (n == 1) return error.Malformed;
    if (n > 1) {
        // A final partial group is padded with 'u' and gives n - 1 bytes.
        for (n..5) |k| group[k] = 'u' - '!';
        const b = try base85Group(group);
        try out.appendSlice(allocator, b[0 .. n - 1]);
    }
    return out.items;
}

fn base85Group(g: [5]u8) Error![4]u8 {
    var v: u64 = 0;
    for (g) |d| v = v * 85 + d;
    if (v > std.math.maxInt(u32)) return error.Malformed;
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @intCast(v), .big);
    return b;
}

// ---- tests ----

const testing = std.testing;

fn loadFixture(name: []const u8) ![]u8 {
    const options = @import("build_options");
    var buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ options.read_fixtures, name });
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 24));
}

test "bytes before the %PDF header: within 1024 bytes the file is read from its header" {
    const gpa = testing.allocator;
    const base = try loadFixture("base.pdf");
    defer gpa.free(base);
    // A tag a web server wrote before the file, and two UTF-8 byte order marks: both seen in files
    // from the web, whose offsets count from %PDF.
    for ([_][]const u8{ "<meta name=\"robots\" content=\"noindex\" />", "\xEF\xBB\xBF\xEF\xBB\xBF" }) |junk| {
        const file = try std.mem.concat(gpa, u8, &.{ junk, base });
        defer gpa.free(file);
        var r = try Reader.open(gpa, file, .{});
        defer r.deinit();
        try testing.expectEqual(@as(usize, 3), r.pageCount());
        var pt = try r.pageText(gpa, 2);
        defer pt.deinit();
        try testing.expect(pt.runs.len > 0);
    }
    // Past 1024 bytes the header is not looked for: the offsets then count from byte 0, and fail.
    const far = try gpa.alloc(u8, 1025 + base.len);
    defer gpa.free(far);
    @memset(far[0..1025], ' ');
    @memcpy(far[1025..], base);
    try testing.expectError(error.Malformed, Reader.open(gpa, far, .{}));
}

test "zpdf's file and qpdf's object-stream and linearized rewrites read as the same 3 pages" {
    const gpa = testing.allocator;
    const base_bytes = try loadFixture("base.pdf");
    defer gpa.free(base_bytes);
    var base = try Reader.open(gpa, base_bytes, .{});
    defer base.deinit();
    try testing.expectEqual(@as(usize, 3), base.pageCount());
    for (0..3) |i| {
        try testing.expectEqual([4]f64{ 0, 0, 612, 792 }, base.page(i).media_box);
        try testing.expectEqual(@as(u16, 0), base.page(i).rotate);
    }
    const first = (try base.pageContents(gpa, base.page(0))).?;
    defer gpa.free(first);
    try testing.expect(std.mem.indexOf(u8, first, " re f\n") != null);

    for ([_][]const u8{ "objstm.pdf", "linear.pdf" }) |name| {
        const bytes = try loadFixture(name);
        defer gpa.free(bytes);
        var r = try Reader.open(gpa, bytes, .{});
        defer r.deinit();
        try testing.expectEqual(@as(usize, 3), r.pageCount());
        for (0..3) |i| {
            try testing.expectEqual([4]f64{ 0, 0, 612, 792 }, r.page(i).media_box);
            const want = (try base.pageContents(gpa, base.page(i))).?;
            defer gpa.free(want);
            const got = (try r.pageContents(gpa, r.page(i))).?;
            defer gpa.free(got);
            try testing.expectEqualStrings(want, got);
        }
        // Each file really is the shape it is named for.
        var compressed: usize = 0;
        var it = r.xref.valueIterator();
        while (it.next()) |e| compressed += @intFromBool(e.* == .compressed);
        if (std.mem.eql(u8, name, "objstm.pdf")) {
            try testing.expect(compressed > 0);
            try testing.expect(nameIs(r.trailerDict().get("Type"), "XRef"));
        } else {
            try testing.expectEqual(@as(usize, 0), compressed);
            try testing.expect(std.mem.count(u8, bytes, "startxref") == 2);
        }
    }
}

/// The /Registry string of the first font's CID font on page 1: a string in an indirect object
/// (an object-stream object in some fixtures), which decryption must get right.
fn cidRegistry(r: *Reader) ![]const u8 {
    const fonts = switch ((try r.getResolved(r.page(0).resources, "Font")).?) {
        .dict => |d| d,
        else => return error.TestUnexpectedResult,
    };
    var registry: ?[]const u8 = null;
    for (fonts.entries) |e| {
        const font = switch (try r.resolve(e.value)) {
            .dict => |d| d,
            else => continue,
        };
        const descendants = (try r.getResolved(font, "DescendantFonts")) orelse continue;
        const cid = switch (try r.resolve(descendants.array[0])) {
            .dict => |d| d,
            else => return error.TestUnexpectedResult,
        };
        const info = switch ((try r.getResolved(cid, "CIDSystemInfo")).?) {
            .dict => |d| d,
            else => return error.TestUnexpectedResult,
        };
        registry = switch ((try r.getResolved(info, "Registry")).?) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
    }
    return registry orelse error.TestUnexpectedResult;
}

test "every revision of the standard security handler, written by qpdf, reads as the file it encrypts" {
    const gpa = testing.allocator;
    const base_bytes = try loadFixture("base.pdf");
    defer gpa.free(base_bytes);
    var base = try Reader.open(gpa, base_bytes, .{});
    defer base.deinit();
    try testing.expectEqualStrings("Adobe", try cidRegistry(&base));
    // name, the password to open it with, its revision.
    const files = [_]struct { []const u8, []const u8, u8 }{
        .{ "encrypted/rc4-40.pdf", "", 2 },
        .{ "encrypted/rc4-128.pdf", "", 3 },
        .{ "encrypted/rc4-128-v4.pdf", "", 4 },
        .{ "encrypted/aes-128.pdf", "", 4 },
        .{ "encrypted/aes-128-cleartext-metadata.pdf", "", 4 },
        .{ "encrypted/aes-256-r5.pdf", "", 5 },
        .{ "encrypted/aes-256.pdf", "", 6 },
        // The owner password opens a file whose user password is empty, too (R2, R4 and R6).
        .{ "encrypted/rc4-40.pdf", "owner", 2 },
        .{ "encrypted/aes-128.pdf", "owner", 4 },
        .{ "encrypted/aes-256.pdf", "owner", 6 },
        .{ "encrypted/aes-128-empty-owner.pdf", "user", 4 },
        .{ "encrypted/rc4-128-password.pdf", "user", 3 },
        .{ "encrypted/rc4-128-password.pdf", "owner", 3 },
        .{ "encrypted/aes-256-r5-password.pdf", "user", 5 },
        .{ "encrypted/aes-256-r5-password.pdf", "owner", 5 },
        .{ "encrypted.pdf", "user", 6 },
        .{ "encrypted.pdf", "owner", 6 },
    };
    for (files) |f| {
        const bytes = try loadFixture(f[0]);
        defer gpa.free(bytes);
        var r = Reader.open(gpa, bytes, .{ .password = f[1] }) catch |err| {
            std.debug.print("{s} with \"{s}\": {t}\n", .{ f[0], f[1], err });
            return err;
        };
        defer r.deinit();
        try testing.expectEqual(f[2], r.crypt.?.revision);
        try testing.expectEqual(@as(usize, 3), r.pageCount());
        for (0..3) |i| {
            const want = (try base.pageContents(gpa, base.page(i))).?;
            defer gpa.free(want);
            const got = (try r.pageContents(gpa, r.page(i))).?;
            defer gpa.free(got);
            try testing.expectEqualStrings(want, got);
        }
        try testing.expectEqualStrings("Adobe", try cidRegistry(&r));
        var want_text = try base.pageText(gpa, 1);
        defer want_text.deinit();
        var got_text = try r.pageText(gpa, 1);
        defer got_text.deinit();
        try testing.expectEqual(want_text.runs.len, got_text.runs.len);
        for (want_text.runs, got_text.runs) |w, g| try testing.expectEqualStrings(w.text, g.text);
    }
}

test "not decrypted: clear metadata, a signature's /Contents, the encryption dictionary, an xref stream" {
    const gpa = testing.allocator;
    {
        const bytes = try loadFixture("encrypted/aes-128-sig-metadata.pdf");
        defer gpa.free(bytes);
        var r = try Reader.open(gpa, bytes, .{});
        defer r.deinit();
        const catalog = (try r.resolve(r.trailerDict().get("Root").?)).dict;
        const metadata = (try r.getResolved(catalog, "Metadata")).?.stream;
        try testing.expectEqualStrings("<?xpacket begin=\"\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\">zpdf metadata</x:xmpmeta>", try r.streamData(metadata));
        const sig = (try r.getResolved(catalog, "ZpdfTestSig")).?.dict;
        var contents: [48]u8 = undefined;
        for (&contents, 1..) |*b, i| b.* = @intCast(i);
        try testing.expectEqualSlices(u8, &contents, sig.get("Contents").?.string);
        // The same dictionary's other strings are encrypted.
        try testing.expectEqualStrings("zpdf signer", sig.get("Name").?.string);
        // The encryption dictionary, loaded again: /O is the 32 bytes the file has.
        const enc = (try r.object(r.encrypt_num.?)).dict;
        try testing.expectEqual(@as(usize, 32), enc.get("O").?.string.len);
    }
    {
        // A cross-reference stream, loaded as an object after decryption is set up, still decodes:
        // its rows are whole.
        const bytes = try loadFixture("encrypted/aes-256.pdf");
        defer gpa.free(bytes);
        var r = try Reader.open(gpa, bytes, .{});
        defer r.deinit();
        var lx: Lexer = .{ .src = bytes, .pos = try findStartXref(bytes) };
        const head = try parseIndirectHead(&lx, r.arena_state);
        const xref = (try r.object(head.num)).stream;
        try testing.expect(nameIs(xref.dict.get("Type"), "XRef"));
        var row: usize = 0;
        for (xref.dict.get("W").?.array) |w| row += @intCast(w.integer);
        const data = try r.streamData(xref);
        try testing.expect(data.len > 0 and data.len % row == 0);
    }
}

test "a /Crypt filter: /Identity, named or by default, leaves the data as written" {
    const gpa = testing.allocator;
    const base = try loadFixture("encrypted/aes-128-cleartext-metadata.pdf");
    defer gpa.free(base);
    // The update's trailer repeats /Encrypt and /ID, as a writer's would.
    var extra_buf: [256]u8 = undefined;
    const extra = blk: {
        var r = try Reader.open(gpa, base, .{});
        defer r.deinit();
        const enc = r.trailerDict().get("Encrypt").?.ref;
        const id = try r.firstId();
        break :blk try std.fmt.bufPrint(&extra_buf, "/Encrypt {d} {d} R /ID [<{x}> <{x}>] ", .{ enc.num, enc.gen, id, id });
    };
    const pdf = try appendUpdate(gpa, base, &.{
        .{ .num = 20, .body = "<< /Length 14 /Filter /Crypt /DecodeParms << /Name /Identity >> >>\nstream\nplain identity\nendstream" },
        .{ .num = 21, .body = "<< /Length 11 /Filter [/Crypt /ASCIIHexDecode] /DecodeParms [<< /Name /Identity >> null] >>\nstream\n706c61696e>\nendstream" },
        .{ .num = 22, .body = "<< /Length 7 /Filter /Crypt >>\nstream\ndefault\nendstream" },
        .{ .num = 23, .body = "<< /Length 4 /Filter /Crypt /DecodeParms << /Name /Mine >> >>\nstream\nmine\nendstream" },
        .{ .num = 24, .body = "<< /Length 5 /Filter [/ASCIIHexDecode /Crypt] >>\nstream\n6869>\nendstream" },
    }, 25, extra);
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    try testing.expect(r.crypt != null);
    try testing.expectEqualStrings("plain identity", try r.streamData((try r.object(20)).stream));
    try testing.expectEqualStrings("plain", try r.streamData((try r.object(21)).stream));
    try testing.expectEqualStrings("default", try r.streamData((try r.object(22)).stream));
    // A crypt filter that is not /Identity or /StdCF, and /Crypt after another filter (7.4.10).
    try testing.expectError(error.UnsupportedEncryption, r.streamData((try r.object(23)).stream));
    try testing.expectError(error.Malformed, r.streamData((try r.object(24)).stream));
    // The page content, through /StdCF (the file's stream method), still reads.
    const content = (try r.pageContents(gpa, r.page(0))).?;
    gpa.free(content);

    // In a file that is not encrypted, /Crypt /Identity is accepted, and only as the first filter:
    // above, the stream after another filter would fail as AES data anyway.
    const plain = try buildPdf(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [] /Count 0 >>",
        "<< /Length 5 /Filter [/Crypt /ASCIIHexDecode] >>\nstream\n6869>\nendstream",
        "<< /Length 5 /Filter [/ASCIIHexDecode /Crypt] >>\nstream\n6869>\nendstream",
    }, "");
    defer gpa.free(plain);
    var p = try Reader.open(gpa, plain, .{});
    defer p.deinit();
    try testing.expectEqualStrings("hi", try p.streamData((try p.object(3)).stream));
    try testing.expectError(error.Malformed, p.streamData((try p.object(4)).stream));
}

test "a file with a user password needs it, or its owner password; a wrong one is PasswordRequired" {
    const gpa = testing.allocator;
    // aes-128-empty-owner.pdf: its owner password is empty, which must not open it (as in Acrobat
    // and MuPDF), so "" is refused like any other wrong password.
    for ([_][]const u8{ "encrypted.pdf", "encrypted/rc4-128-password.pdf", "encrypted/aes-256-r5-password.pdf", "encrypted/aes-128-empty-owner.pdf" }) |name| {
        const bytes = try loadFixture(name);
        defer gpa.free(bytes);
        for ([_][]const u8{ "", "wrong", "use", "users", "owne" }) |pw| {
            try testing.expectError(error.PasswordRequired, Reader.open(gpa, bytes, .{ .password = pw }));
        }
    }
}

test "an encryption handler or crypt filter it does not read is UnsupportedEncryption" {
    const gpa = testing.allocator;
    const pages = "<< /Type /Pages /Kids [] /Count 0 >>";
    const o = "<" ++ "0000000000000000000000000000000000000000000000000000000000000000" ++ ">";
    const cases = [_][]const u8{
        // Public-key security.
        "/Encrypt << /Filter /Adobe.PubSec /V 4 /R 4 >> /ID [<00> <00>] ",
        // A revision past 6.
        "/Encrypt << /Filter /Standard /V 5 /R 7 /O " ++ o ++ " /U " ++ o ++ " /P -4 >> /ID [<00> <00>] ",
        // V 3, which was never published.
        "/Encrypt << /Filter /Standard /V 3 /R 3 /O " ++ o ++ " /U " ++ o ++ " /P -4 >> /ID [<00> <00>] ",
        // A crypt filter that is neither /Identity nor /StdCF.
        "/Encrypt << /Filter /Standard /V 4 /R 4 /O " ++ o ++ " /U " ++ o ++ " /P -4 /CF << /Mine << /CFM /AESV2 >> >> /StmF /Mine /StrF /Mine >> /ID [<00> <00>] ",
        // A crypt filter method it does not know.
        "/Encrypt << /Filter /Standard /V 4 /R 4 /O " ++ o ++ " /U " ++ o ++ " /P -4 /CF << /StdCF << /CFM /Other >> >> /StmF /StdCF /StrF /StdCF >> /ID [<00> <00>] ",
    };
    for (cases) |extra| {
        const pdf = try buildPdf(gpa, &.{ "<< /Type /Catalog /Pages 2 0 R >>", pages }, extra);
        defer gpa.free(pdf);
        try testing.expectError(error.UnsupportedEncryption, Reader.open(gpa, pdf, .{}));
    }
}

test "the stream size limit and the depth limit are errors" {
    const bytes = try loadFixture("objstm.pdf");
    defer testing.allocator.free(bytes);
    try testing.expectError(error.TooLarge, Reader.open(testing.allocator, bytes, .{ .max_stream_bytes = 16 }));
    var buf: [400]u8 = undefined;
    const deep = &(@as([100]u8, @splat('[')) ++ @as([100]u8, @splat(']')));
    const pdf = try buildPdf(testing.allocator, &.{ "<< /Type /Catalog /Pages 2 0 R /X " ++ deep ++ " >>", "<< /Type /Pages /Kids [] /Count 0 >>" }, "");
    defer testing.allocator.free(pdf);
    _ = &buf;
    try testing.expectError(error.TooDeep, Reader.open(testing.allocator, pdf, .{}));
}

/// Test helpers for read_text.zig's tests.
pub const test_util = if (@import("builtin").is_test) struct {
    pub const build = buildPdf;
} else struct {};

/// A PDF with a classic xref: object i + 1 is bodies[i]; the trailer is /Size, /Root 1 0 R and
/// `extra`.
fn buildPdf(gpa: Allocator, bodies: []const []const u8, extra: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("%PDF-1.7\n");
    var offsets: [32]usize = undefined;
    for (bodies, 0..) |body, i| {
        offsets[i] = aw.written().len;
        try w.print("{d} 0 obj\n{s}\nendobj\n", .{ i + 1, body });
    }
    const xref_at = aw.written().len;
    try w.print("xref\n0 {d}\n0000000000 65535 f \n", .{bodies.len + 1});
    for (bodies, 0..) |_, i| try w.print("{d:0>10} 00000 n \n", .{offsets[i]});
    try w.print("trailer\n<< /Size {d} /Root 1 0 R {s}>>\nstartxref\n{d}\n%%EOF\n", .{ bodies.len + 1, extra, xref_at });
    return aw.toOwnedSlice();
}

/// `base` with an incremental update appended: each change sets object `num` to `body`, or
/// frees it when body is null. The new trailer has /Prev, the old /Root, `size` and `extra`.
fn appendUpdate(gpa: Allocator, base: []const u8, changes: []const struct { num: u32, body: ?[]const u8 }, size: u32, extra: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(base);
    var offsets: [16]usize = undefined;
    for (changes, 0..) |c, i| {
        offsets[i] = aw.written().len;
        if (c.body) |body| try w.print("{d} 0 obj\n{s}\nendobj\n", .{ c.num, body });
    }
    const xref_at = aw.written().len;
    try w.writeAll("xref\n");
    for (changes, 0..) |c, i| {
        if (c.body != null) {
            try w.print("{d} 1\n{d:0>10} 00000 n \n", .{ c.num, offsets[i] });
        } else try w.print("{d} 1\n0000000000 00001 f \n", .{c.num});
    }
    const prev = try findStartXref(base);
    try w.print("trailer\n<< /Size {d} /Root 1 0 R /Prev {d} {s}>>\nstartxref\n{d}\n%%EOF\n", .{ size, prev, extra, xref_at });
    return aw.toOwnedSlice();
}

test "an incremental update replaces and frees objects, and pages inherit from the tree" {
    const gpa = testing.allocator;
    const base = try buildPdf(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 612 792] /Rotate 90 /Resources << /Font << /F1 6 0 R >> >> >>",
        "<< /Type /Page /Parent 2 0 R >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [10 20 -5 400] /Rotate -90 /Contents 5 0 R >>",
        "<< /Length 2 >>\nstream\nq\n\nendstream",
        "<< /Type /Font >>",
    }, "");
    defer gpa.free(base);
    var r = try Reader.open(gpa, base, .{});
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.pageCount());
    try testing.expectEqual([4]f64{ 0, 0, 612, 792 }, r.page(0).media_box);
    try testing.expectEqual(@as(u16, 90), r.page(0).rotate);
    try testing.expect(r.page(0).resources.get("Font") != null);
    // A box given backwards is normalized; -90 is 270.
    try testing.expectEqual([4]f64{ -5, 20, 10, 400 }, r.page(1).media_box);
    try testing.expectEqual(@as(u16, 270), r.page(1).rotate);
    // An unfiltered stream is still a new allocation the caller frees (testing.allocator
    // would fail a free of a slice into the file); a page without /Contents is null.
    const unfiltered = (try r.pageContents(gpa, r.page(1))).?;
    defer gpa.free(unfiltered);
    try testing.expectEqualStrings("q\n", unfiltered);
    try testing.expectEqual(@as(?[]u8, null), try r.pageContents(gpa, r.page(0)));

    // The update drops page 3 from the tree, and frees the font.
    const updated = try appendUpdate(gpa, base, &.{
        .{ .num = 2, .body = "<< /Type /Pages /Kids [4 0 R] /Count 1 /MediaBox [0 0 100 100] >>" },
        .{ .num = 6, .body = null },
    }, 7, "");
    defer gpa.free(updated);
    var u = try Reader.open(gpa, updated, .{});
    defer u.deinit();
    try testing.expectEqual(@as(usize, 1), u.pageCount());
    try testing.expectEqual([4]f64{ -5, 20, 10, 400 }, u.page(0).media_box);
    try testing.expectEqual(Object.null, try u.object(6));
    // Object 3 is only in the older section, and still there.
    try testing.expect((try u.object(3)) == .dict);
}

test "broken structure is Malformed: cycles, bad lengths, bad offsets, no startxref" {
    const gpa = testing.allocator;
    const cases = [_]struct { bodies: []const []const u8, extra: []const u8 = "" }{
        // The page tree refers back to itself.
        .{ .bodies = &.{ "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [2 0 R] /Count 1 >>" } },
        // A stream's /Length refers to the stream itself.
        .{ .bodies = &.{ "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 1 1] >>", "<< /Type /Page /Contents 4 0 R >>", "<< /Length 4 0 R >>\nstream\nab\nendstream" } },
        // A /Length that stops short of endstream.
        .{ .bodies = &.{ "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 1 1] >>", "<< /Type /Page /Contents 4 0 R >>", "<< /Length 1 >>\nstream\nabc\nendstream" } },
        // A page with no media box anywhere.
        .{ .bodies = &.{ "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page >>" } },
        // /Prev pointing at its own section.
        .{ .bodies = &.{ "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>" }, .extra = "/Prev SELF " },
        // A rotation that is not a multiple of 90.
        .{ .bodies = &.{ "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 1 1] /Rotate 45 >>", "<< /Type /Page >>" } },
    };
    for (cases, 0..) |c, i| {
        var pdf = try buildPdf(gpa, c.bodies, c.extra);
        defer gpa.free(pdf);
        if (std.mem.indexOf(u8, pdf, "/Prev SELF ")) |at| {
            // Point /Prev at this file's own xref, padded to the placeholder's length.
            var num: [9]u8 = undefined;
            const s = try std.fmt.bufPrint(&num, "{d}", .{try findStartXref(pdf)});
            @memset(pdf[at + 6 ..][0..4], ' ');
            @memcpy(pdf[at + 6 ..][0..s.len], s);
        }
        const opened = Reader.open(gpa, pdf, .{});
        if (opened) |r| {
            var rr = r;
            defer rr.deinit();
            // Some defects only show when the object is read.
            const got = rr.pageContents(gpa, rr.page(0));
            if (got) |contents| {
                if (contents) |bytes| gpa.free(bytes);
                std.debug.print("case {d} was not refused\n", .{i});
                return error.TestUnexpectedResult;
            } else |err| try testing.expectEqual(error.Malformed, err);
        } else |err| try testing.expectEqual(error.Malformed, err);
    }
    try testing.expectError(error.Malformed, Reader.open(gpa, "%PDF-1.7\n1 0 obj\n<< >>\nendobj\n", .{}));
    // A truncated file: its startxref is cut off.
    const whole = try buildPdf(gpa, &.{ "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>" }, "");
    defer gpa.free(whole);
    try testing.expectError(error.Malformed, Reader.open(gpa, whole[0 .. whole.len - 20], .{}));
}

test "the lexer decodes strings, names and numbers as ISO 32000-1 7.3 says" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var lx: Lexer = .{ .src = "(a\\(b\\)c\\\\ \\101\\7x \\q (nest) line\\\ncont\r\nend) <48 65 6c6C 6f 7> /A#20B /Plain 12 -3 +.5 4. -0.25 %c\n" ++
        "true R", .pos = 0 };
    try testing.expectEqualStrings("a(b)c\\ A\x07x q (nest) linecont\nend", (try lx.next(&arena_state)).string);
    try testing.expectEqualStrings("Hello\x70", (try lx.next(&arena_state)).string);
    try testing.expectEqualStrings("A B", (try lx.next(&arena_state)).name);
    try testing.expectEqualStrings("Plain", (try lx.next(&arena_state)).name);
    try testing.expectEqual(@as(i64, 12), (try lx.next(&arena_state)).integer);
    try testing.expectEqual(@as(i64, -3), (try lx.next(&arena_state)).integer);
    try testing.expectEqual(@as(f64, 0.5), (try lx.next(&arena_state)).real);
    try testing.expectEqual(@as(f64, 4), (try lx.next(&arena_state)).real);
    try testing.expectEqual(@as(f64, -0.25), (try lx.next(&arena_state)).real);
    try testing.expectEqualStrings("true", (try lx.next(&arena_state)).keyword);
    try testing.expectEqualStrings("R", (try lx.next(&arena_state)).keyword);
    try testing.expectEqual(Token.eof, try lx.next(&arena_state));
    // A string whose only special characters are balanced parentheses, which the plain-string
    // path must not end at the first ')'; and a comment straight after a word, which ends it.
    var more: Lexer = .{ .src = "(a(b)c) (plain) 12%c\n13", .pos = 0 };
    try testing.expectEqualStrings("a(b)c", (try more.next(&arena_state)).string);
    try testing.expectEqualStrings("plain", (try more.next(&arena_state)).string);
    try testing.expectEqual(@as(i64, 12), (try more.next(&arena_state)).integer);
    try testing.expectEqual(@as(i64, 13), (try more.next(&arena_state)).integer);
    try testing.expectEqual(Token.eof, try more.next(&arena_state));
    // A refusal moves past what it refused, so a caller that skips bad tokens moves on: past a
    // hex string's bad digit, and to the end when its '>' never comes.
    var bad_hex: Lexer = .{ .src = "<4g>5", .pos = 0 };
    try testing.expectError(error.Malformed, bad_hex.next(&arena_state));
    try testing.expectEqual(@as(usize, 3), bad_hex.pos);
    var open_hex: Lexer = .{ .src = "<48 65", .pos = 0 };
    try testing.expectError(error.Malformed, open_hex.next(&arena_state));
    try testing.expectEqual(@as(usize, 6), open_hex.pos);
    for ([_][]const u8{ "1-2", "--1", "(open", "<4g>", "/A#2", ">", "1e5" }) |bad| {
        var l: Lexer = .{ .src = bad, .pos = 0 };
        try testing.expectError(error.Malformed, l.next(&arena_state));
    }
    var p_lx: Lexer = .{ .src = "<< /K [1 2 R 3 /N (s)] /D << >> /R 7 0 R >>", .pos = 0 };
    var p: Parser = .{ .lx = &p_lx, .arena = &arena_state, .max_depth = 8 };
    const d = (try p.parseValue(0)).dict;
    const k = d.get("K").?.array;
    try testing.expectEqual(@as(usize, 4), k.len);
    try testing.expectEqual(Ref{ .num = 1, .gen = 2 }, k[0].ref);
    try testing.expectEqual(@as(i64, 3), k[1].integer);
    try testing.expectEqual(Ref{ .num = 7, .gen = 0 }, d.get("R").?.ref);
}

test "ASCIIHex, ASCII85 and the TIFF predictor decode known vectors" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("abc\x70", try asciiHex(a, "61 62\n63 7>", 100));
    // From Python's base64.a85encode.
    try testing.expectEqualStrings("Hello, PDF reader!", try ascii85(a, "87cURD_*#-6q/;>ART+\\EZk~>", 100));
    try testing.expectEqualStrings("\x00\x00\x00\x00abc", try ascii85(a, "z@:E^~>", 100));
    try testing.expectError(error.Malformed, ascii85(a, "87cUR\x7f~>", 100));
    try testing.expectError(error.TooLarge, asciiHex(a, "616263", 2));

    var r: Reader = undefined;
    r.options = .{};
    r.arena_state = &arena_state;
    r.cache = .empty;
    r.xref = .empty;
    r.loading = .empty;
    const params: Object = .{ .dict = .{ .entries = &.{
        .{ .key = "Predictor", .value = .{ .integer = 2 } },
        .{ .key = "Columns", .value = .{ .integer = 3 } },
    } } };
    // Each byte after the first in a row adds the byte before it.
    try testing.expectEqualSlices(u8, &.{ 1, 3, 6, 10, 10, 11 }, try r.documentScope().unpredict(params, &.{ 1, 2, 3, 10, 0, 1 }));
}

/// LZW codes since a clear, packed as an encoder would: 9 bits wide at first, wider when the
/// decoder's next table entry needs it (7.4.4.2). For data no encoder in tests/read/lzw writes.
fn packLzw(a: Allocator, codes: []const u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var acc: u64 = 0;
    var held: u6 = 0;
    var bits: u6 = 9;
    var since_clear: u32 = 0;
    for (codes) |code| {
        acc = acc << bits | code;
        held += bits;
        while (held >= 8) {
            held -= 8;
            try out.append(a, @truncate(acc >> held));
        }
        if (code == 256) {
            bits = 9;
            since_clear = 0;
            continue;
        }
        since_clear += 1;
        // After its first code, the decoder adds an entry per code; /EarlyChange 1.
        const decoder_next = 257 + since_clear;
        if (bits < 12 and decoder_next + 1 >= @as(u32, 1) << @intCast(bits)) bits += 1;
    }
    if (held > 0) try out.append(a, @truncate(acc << @intCast(8 - held)));
    return out.items;
}

test "LZWDecode: libtiff's data and the standard's example, at both /EarlyChange values" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: Reader = undefined;
    r.options = .{};
    r.arena_state = &arena_state;
    r.cache = .empty;
    r.xref = .empty;
    r.loading = .empty;

    // ISO 32000-1 7.4.4.2, Example: codes 256 45 258 258 65 259 66 257.
    const example = "\x80\x0b\x60\x50\x22\x0c\x0c\x85\x01";
    try testing.expectEqualStrings("-----A---B", try r.documentScope().applyFilter("LZWDecode", .null, example));
    // With /Predictor 2 (TIFF), in rows of 5: each byte adds the one before it.
    const tiff: Object = .{ .dict = .{ .entries = &.{
        .{ .key = "Predictor", .value = .{ .integer = 2 } },
        .{ .key = "Columns", .value = .{ .integer = 5 } },
    } } };
    try testing.expectEqualSlices(u8, &.{ 45, 90, 135, 180, 225, 65, 110, 155, 200, 10 }, try r.documentScope().applyFilter("LZW", tiff, example));

    // base.pdf, encoded by libtiff (EarlyChange 1) and by tools/lzw-fixtures.py (EarlyChange 0);
    // both fill the code table and clear it.
    const plain = try loadFixture("base.pdf");
    defer testing.allocator.free(plain);
    const ec1 = try loadFixture("lzw/early-change-1.lzw");
    defer testing.allocator.free(ec1);
    const ec0 = try loadFixture("lzw/early-change-0.lzw");
    defer testing.allocator.free(ec0);
    const early: [2]Object = .{
        .{ .dict = .{ .entries = &.{.{ .key = "EarlyChange", .value = .{ .integer = 0 } }} } },
        .{ .dict = .{ .entries = &.{.{ .key = "EarlyChange", .value = .{ .integer = 1 } }} } },
    };
    try testing.expectEqualSlices(u8, plain, try r.documentScope().applyFilter("LZW", .null, ec1));
    try testing.expectEqualSlices(u8, plain, try r.documentScope().applyFilter("LZWDecode", early[1], ec1));
    try testing.expectEqualSlices(u8, plain, try r.documentScope().applyFilter("LZWDecode", early[0], ec0));
    // Read with the other /EarlyChange, the widths go wrong and the data with them.
    try testing.expectError(error.Malformed, r.documentScope().applyFilter("LZWDecode", early[0], ec1));
    try testing.expectError(error.Malformed, r.documentScope().applyFilter("LZWDecode", early[1], ec0));
    const two: Object = .{ .dict = .{ .entries = &.{.{ .key = "EarlyChange", .value = .{ .integer = 2 } }} } };
    try testing.expectError(error.Malformed, r.documentScope().applyFilter("LZWDecode", two, example));
    try testing.expectError(error.TooLarge, lzw(a, ec1, true, plain.len - 1));
}

test "LZWDecode refuses what no encoder writes, and reads one code at a full table as MuPDF does" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const max = 1 << 20;
    try testing.expectEqualStrings("AB", try lzw(a, try packLzw(a, &.{ 256, 65, 66, 257 }), true, max));
    // No end code: the data stops after B.
    try testing.expectError(error.Malformed, lzw(a, try packLzw(a, &.{ 256, 65, 66 }), true, max));
    // 259 is not in the table yet: only 258 (A + the next code's first byte) is being added.
    try testing.expectError(error.Malformed, lzw(a, try packLzw(a, &.{ 256, 65, 259, 257 }), true, max));
    // The first code after a clear has no previous string to extend, so it is a byte.
    try testing.expectError(error.Malformed, lzw(a, try packLzw(a, &.{ 256, 258, 257 }), true, max));

    // 3839 codes fill the table to 4096 entries; then one more code is read and adds none, and a
    // second is refused. A clear starts the table and the code width again (258 is "zz"), and the
    // next full table may have its one code too.
    var codes: std.ArrayList(u16) = .empty;
    try codes.append(a, 256);
    try codes.appendNTimes(a, 'x', 3839);
    const full = codes.items.len;
    try codes.appendSlice(a, &.{ 'y', 256, 'z', 'z', 258 });
    try codes.appendNTimes(a, 'x', 3836);
    try codes.appendSlice(a, &.{ 'y', 256, 257 });
    const out = try lzw(a, try packLzw(a, codes.items), true, max);
    try testing.expectEqual(@as(usize, 3839 + 5 + 3836 + 1), out.len);
    try testing.expectEqualStrings("xyzzzzx", out[3838..][0..7]);
    try testing.expectEqualStrings("xy", out[out.len - 2 ..]);
    codes.items.len = full;
    try codes.appendSlice(a, &.{ 'y', 'y', 256, 257 });
    try testing.expectError(error.Malformed, lzw(a, try packLzw(a, codes.items), true, max));
}

/// Builds a PDF from numbered objects, then an xref the test writes with `xref`, which gets the
/// objects' offsets and where the xref starts. For hybrid and xref-stream files.
const TestFile = struct {
    aw: std.Io.Writer.Allocating,
    offsets: [16]usize = @splat(0),

    fn init(gpa: Allocator) !TestFile {
        var f: TestFile = .{ .aw = .init(gpa) };
        try f.aw.writer.writeAll("%PDF-1.7\n");
        return f;
    }

    fn obj(self: *TestFile, num: usize, body: []const u8) !void {
        self.offsets[num] = self.aw.written().len;
        try self.aw.writer.print("{d} 0 obj\n{s}\nendobj\n", .{ num, body });
    }

    fn at(self: *TestFile) usize {
        return self.aw.written().len;
    }

    /// An xref stream object `num` with /W [1 4 1], no filter: one entry per `entries` item
    /// as (type, field 2, field 3) for consecutive numbers from `first`.
    fn xrefStream(self: *TestFile, num: usize, first: usize, entries: []const [3]u32, extra: []const u8) !void {
        var data: [16 * 6]u8 = undefined;
        for (entries, 0..) |e, i| {
            data[i * 6] = @intCast(e[0]);
            std.mem.writeInt(u32, data[i * 6 + 1 ..][0..4], e[1], .big);
            data[i * 6 + 5] = @intCast(e[2]);
        }
        const d = data[0 .. entries.len * 6];
        self.offsets[num] = self.at();
        try self.aw.writer.print("{d} 0 obj\n<< /Type /XRef /W [1 4 1] /Index [{d} {d}] /Size {d} /Length {d} {s}>>\nstream\n", .{ num, first, entries.len, first + entries.len, d.len, extra });
        try self.aw.writer.writeAll(d);
        try self.aw.writer.writeAll("\nendstream\nendobj\n");
    }
};

test "the numbers' fast path reads what the general one does, and leaves it the rest" {
    // Shapes and edges by hand, then generated words: each must read as numberSlow reads it, to
    // the bit, or be left to it.
    const words = [_][]const u8{
        "0",                         "-0",                "+0",                    "7",     "-7",  "+7",                 "5.",                  ".5",              "-.5",              "+.5",
        "-0.0",                      "0.000",             "1.5",                   "-1.25", "007", "00.10",              ".",                   "-",               "+",                "-.",
        "1.2.3",                     "1-2",               "--1",                   "+-1",   "1e5", "999999999999999999", "9999999999999999999", "123456789012345", "1234567890123456", "0.1234567890123456789012",
        "0.12345678901234567890123", "3.141592653589793", "-922337203685477580.8",
    };
    var buf: [40]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0x7a706466);
    const rand = prng.random();
    var generated: usize = 0;
    var fast_taken: usize = 0;
    var k: usize = 0;
    while (k < words.len + 20000) : (k += 1) {
        const w: []const u8 = if (k < words.len) words[k] else blk: {
            // Three in four in the fast path's shape (a sign, digits, a point, digits, near its
            // limits), one in four any mix of digits, points and signs.
            var len: usize = 0;
            if (rand.uintLessThan(u8, 4) == 0) {
                len = rand.intRangeAtMost(usize, 1, 24);
                for (buf[0..len]) |*c| c.* = "0123456789.-+"[rand.uintLessThan(u8, 13)];
            } else {
                if (rand.boolean()) {
                    buf[0] = "-+"[rand.uintLessThan(u8, 2)];
                    len = 1;
                }
                for (0..rand.uintAtMost(usize, 16)) |_| {
                    buf[len] = '0' + rand.uintLessThan(u8, 10);
                    len += 1;
                }
                if (rand.boolean()) {
                    buf[len] = '.';
                    len += 1;
                    for (0..rand.uintAtMost(usize, 23 - @min(len, 23))) |_| {
                        buf[len] = '0' + rand.uintLessThan(u8, 10);
                        len += 1;
                    }
                }
                if (len == 0) {
                    buf[0] = '0';
                    len = 1;
                }
            }
            generated += 1;
            break :blk buf[0..len];
        };
        const slow = numberSlow(w);
        if (numberFast(w)) |fast| {
            fast_taken += 1;
            const want = try slow;
            switch (fast) {
                .integer => |v| try testing.expectEqual(want.integer, v),
                .real => |v| try testing.expectEqual(@as(u64, @bitCast(want.real)), @as(u64, @bitCast(v))),
                else => unreachable,
            }
        }
    }
    // The run did the work: most generated words are in the fast path's shapes.
    try testing.expect(generated == 20000 and fast_taken > 10000);
}

test "file numbers that overflow are Malformed, not a crash" {
    const gpa = testing.allocator;
    const base = try buildPdf(gpa, &.{ "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>" }, "");
    defer gpa.free(base);
    // An xref subsection that starts at the largest i64: start + count overflows.
    const at = std.mem.indexOf(u8, base, "xref\n0 3\n").?;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.print("{s}xref\n9223372036854775807 1\n0000000009 00000 n \n{s}", .{ base[0..at], base[at + "xref\n0 3\n".len + 60 ..] });
    try testing.expectError(error.Malformed, Reader.open(gpa, aw.written(), .{}));
}

test "a chain of /Length references is bounded, and every decoded stream keeps to the size limit" {
    const gpa = testing.allocator;
    // Object 4's /Length is object 5, a stream whose /Length is object 6, and so on: each load
    // needs the next one.
    var f = try TestFile.init(gpa);
    defer f.aw.deinit();
    try f.obj(1, "<< /Type /Catalog /Pages 2 0 R >>");
    try f.obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 1 1] >>");
    try f.obj(3, "<< /Type /Page /Contents 4 0 R >>");
    for (4..14) |n| {
        var buf: [64]u8 = undefined;
        try f.obj(n, try std.fmt.bufPrint(&buf, "<< /Length {d} 0 R >>\nstream\nab\nendstream", .{n + 1}));
    }
    try f.obj(14, "2");
    const xref_at = f.at();
    try f.aw.writer.writeAll("xref\n0 15\n0000000000 65535 f \n");
    for (1..15) |n| try f.aw.writer.print("{d:0>10} 00000 n \n", .{f.offsets[n]});
    try f.aw.writer.print("trailer\n<< /Size 15 /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{xref_at});
    var r = try Reader.open(gpa, f.aw.written(), .{ .max_depth = 8 });
    defer r.deinit();
    try testing.expectError(error.TooDeep, r.pageContents(gpa, r.page(0)));
    // With room for the whole chain, it ends at a /Length that is a stream, not an integer.
    var deep = try Reader.open(gpa, f.aw.written(), .{});
    defer deep.deinit();
    try testing.expectError(error.Malformed, deep.pageContents(gpa, deep.page(0)));

    // An unfiltered stream is held to max_stream_bytes too.
    const plain = try buildPdf(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 1 1] >>",
        "<< /Type /Page /Contents 4 0 R >>",
        "<< /Length 2 >>\nstream\nab\nendstream",
    }, "");
    defer gpa.free(plain);
    var small = try Reader.open(gpa, plain, .{ .max_stream_bytes = 1 });
    defer small.deinit();
    try testing.expectError(error.TooLarge, small.pageContents(gpa, small.page(0)));
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    try testing.expectError(error.TooLarge, asciiHex(arena_state.allocator(), "F>", 0));
}

test "a hybrid file's /XRefStm gives objects its table marks free; the table's in-use entries win" {
    const gpa = testing.allocator;
    var f = try TestFile.init(gpa);
    defer f.aw.deinit();
    try f.obj(1, "<< /Type /Catalog /Pages 2 0 R >>");
    try f.obj(2, "<< /Type /Pages /Kids [] /Count 0 >>");
    try f.obj(3, "<< /From /table >>");
    try f.obj(4, "<< /From /stream >>");
    try f.obj(5, "<< /Hidden true >>");
    // The stream gives 3 at 4's offset (the table must win) and 5 (the table says free).
    try f.xrefStream(6, 3, &.{ .{ 1, @intCast(f.offsets[4]), 0 }, .{ 0, 0, 0 }, .{ 1, @intCast(f.offsets[5]), 0 } }, "");
    const stm = f.offsets[6];
    const xref_at = f.at();
    try f.aw.writer.writeAll("xref\n0 6\n0000000000 65535 f \n");
    for (1..4) |n| try f.aw.writer.print("{d:0>10} 00000 n \n", .{f.offsets[n]});
    try f.aw.writer.writeAll("0000000000 00001 f \n0000000000 65535 f \n");
    try f.aw.writer.print("trailer\n<< /Size 7 /Root 1 0 R /XRefStm {d} >>\nstartxref\n{d}\n%%EOF\n", .{ stm, xref_at });
    var r = try Reader.open(gpa, f.aw.written(), .{});
    defer r.deinit();
    try testing.expect(nameIs((try r.object(3)).dict.get("From"), "table"));
    try testing.expect((try r.object(5)).dict.get("Hidden") != null);
    // 4 is free in the stream and in the table.
    try testing.expectEqual(Object.null, try r.object(4));
}

test "generations, endobj, object-stream extents and stream delimiters are checked" {
    const gpa = testing.allocator;
    // Object 3 is "3 0 obj"; a "3 1 R" reference names an object that does not exist.
    const pdf = try buildPdf(gpa, &.{ "<< /Type /Catalog /Pages 2 0 R /A 3 1 R /B 3 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>", "<< /X 1 >>" }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    const root = (try r.resolve(r.trailerDict().get("Root").?)).dict;
    try testing.expectEqual(Object.null, try r.resolve(root.get("A").?));
    try testing.expect((try r.resolve(root.get("B").?)) == .dict);

    // An object stream whose first object is an unterminated array: it must not take the next
    // object's bytes. Object 6 is the object stream, 7 the xref stream.
    var f = try TestFile.init(gpa);
    defer f.aw.deinit();
    try f.obj(1, "<< /Type /Catalog /Pages 2 0 R >>");
    try f.obj(2, "<< /Type /Pages /Kids [] /Count 0 >>");
    const header = "4 0 5 5 ";
    const objects = "[1 2 [3]]";
    var body: [128]u8 = undefined;
    try f.obj(6, try std.fmt.bufPrint(&body, "<< /Type /ObjStm /N 2 /First {d} /Length {d} >>\nstream\n{s}{s}\nendstream", .{ header.len, header.len + objects.len, header, objects }));
    const xref_at = f.at();
    try f.xrefStream(7, 1, &.{ .{ 1, @intCast(f.offsets[1]), 0 }, .{ 1, @intCast(f.offsets[2]), 0 }, .{ 0, 0, 0 }, .{ 2, 6, 0 }, .{ 2, 6, 1 }, .{ 1, @intCast(f.offsets[6]), 0 }, .{ 1, @intCast(xref_at), 0 } }, "/Root 1 0 R ");
    try f.aw.writer.print("startxref\n{d}\n%%EOF\n", .{xref_at});
    var o = try Reader.open(gpa, f.aw.written(), .{});
    defer o.deinit();
    // Object 4 is "[1 2" (its extent ends at object 5): unterminated. Object 5 is "[3]]":
    // a value, then a stray "]".
    try testing.expectError(error.Malformed, o.object(4));
    try testing.expectError(error.Malformed, o.object(5));

    const bad = [_][]const u8{
        // No endobj.
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\n2 0 obj",
        // No end-of-line after "stream": read from the space, /Length 3 would fit " ab".
        "<< /Length 3 >>\nstream ab\nendstream",
        // The data, then a comment before endstream: a lexer would skip it, the format does not.
        "<< /Length 2 >>\nstream\nab%junk\nendstream",
    };
    for (bad, 0..) |b, i| {
        const bodies: []const []const u8 = if (i == 0)
            &.{ "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>" }
        else
            &.{ "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>", b };
        var file = try buildPdf(gpa, bodies, "");
        defer gpa.free(file);
        if (i == 0) {
            // Drop object 1's endobj.
            const at = std.mem.indexOf(u8, file, ">>\nendobj\n2 0 obj").? + 2;
            @memcpy(file[at..][0..7], "\n      ");
        }
        var rr = Reader.open(gpa, file, .{}) catch |err| {
            try testing.expectEqual(error.Malformed, err);
            continue;
        };
        defer rr.deinit();
        try testing.expectError(error.Malformed, rr.object(3));
    }
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectError(error.Malformed, asciiHex(a, "616263", 100));
    try testing.expectError(error.Malformed, ascii85(a, "87cURD]i,\"Ebo80", 100));
    try testing.expectError(error.Malformed, ascii85(a, "87cURD]i,\"Ebo80~", 100));
}

test "the PNG predictor's left byte is a whole pixel back, rounded up, and short rows are refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var r: Reader = undefined;
    r.options = .{};
    r.arena_state = &arena_state;
    r.cache = .empty;
    r.xref = .empty;
    r.loading = .empty;
    // 3 colours of 4 bits, 2 columns: rows of 3 bytes, pixels of 1.5 bytes, so "left" is 2
    // bytes back. Sub filter: [1, 2, 2] decodes to [1, 2, 1 + 2].
    const params: Object = .{ .dict = .{ .entries = &.{
        .{ .key = "Predictor", .value = .{ .integer = 15 } },
        .{ .key = "Colors", .value = .{ .integer = 3 } },
        .{ .key = "BitsPerComponent", .value = .{ .integer = 4 } },
        .{ .key = "Columns", .value = .{ .integer = 2 } },
    } } };
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, try r.documentScope().unpredict(params, &.{ 1, 1, 2, 2 }));
    try testing.expectError(error.Malformed, r.documentScope().unpredict(params, &.{ 1, 1, 2 }));
}

/// std.compress.flate, as inflate called it before libdeflate: the reference the test below checks
/// inflate against.
fn inflateStdReference(allocator: Allocator, data: []const u8, max: usize) Error![]u8 {
    var in: std.Io.Reader = .fixed(data);
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var d: std.compress.flate.Decompress = .init(&in, .zlib, window);
    return d.reader.allocRemaining(allocator, .limited(max)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.TooLarge,
        error.ReadFailed => error.Malformed,
    };
}

test "inflate reads what std.compress.flate reads, and refuses what it refuses" {
    // Streams from std's compressor at three levels, of random bytes (stored blocks), text, and
    // long runs that inflate more than 8 times (so inflate decodes again into a larger buffer);
    // each whole, with its trailer cut short, with a bad method, with a reserved window size, and
    // with a limit one byte short. Each must give std's bytes, or std's refusal.
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x666c6174);
    const rand = prng.random();
    const levels = [_]std.compress.flate.Compress.Options{ .level_1, .level_6, .level_9 };
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(gpa);
    var compared: usize = 0;
    var retried: usize = 0;
    for (0..48) |i| {
        plain.clearRetainingCapacity();
        const len = rand.uintAtMost(usize, 40_000);
        switch (i % 4) {
            0 => for (0..len) |_| try plain.append(gpa, rand.int(u8)),
            1 => for (0..len) |_| try plain.append(gpa, "etaoin shrdlu\n()[]0123"[rand.uintLessThan(usize, 22)]),
            2 => while (plain.items.len < len) try plain.appendNTimes(gpa, rand.int(u8), rand.uintAtMost(usize, 3000)),
            else => for (0..len % 64) |_| try plain.append(gpa, rand.int(u8)),
        }
        var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
        defer out.deinit();
        const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
        defer gpa.free(window);
        var c = try std.compress.flate.Compress.init(&out.writer, window, .zlib, levels[i % levels.len]);
        try c.writer.writeAll(plain.items);
        try c.finish();
        const z = out.written();
        if (plain.items.len > z.len * 8 + 4096) retried += 1;

        var bad_method = try gpa.dupe(u8, z);
        defer gpa.free(bad_method);
        bad_method[0] = (bad_method[0] & 0xf0) | 9;
        var big_window = try gpa.dupe(u8, z);
        defer gpa.free(big_window);
        big_window[0] = (big_window[0] & 0x0f) | 0x80;
        const variants = [_]struct { data: []const u8, max: usize }{
            .{ .data = z, .max = 1 << 24 },
            .{ .data = z[0 .. z.len - 1], .max = 1 << 24 },
            .{ .data = z[0 .. z.len - 4], .max = 1 << 24 },
            .{ .data = bad_method, .max = 1 << 24 },
            .{ .data = big_window, .max = 1 << 24 },
            .{ .data = z, .max = plain.items.len -| 1 },
        };
        for (variants) |v| {
            const want = inflateStdReference(gpa, v.data, v.max);
            defer if (want) |w| gpa.free(w) else |_| {};
            const got = inflate(gpa, v.data, v.max);
            defer if (got) |g| gpa.free(g) else |_| {};
            if (want) |w| {
                try testing.expectEqualSlices(u8, w, try got);
                try testing.expectEqualSlices(u8, plain.items, w);
            } else |err| try testing.expectError(err, got);
            compared += 1;
        }
    }
    // The run did the work: every variant compared, and some streams took the larger buffer. And
    // libdeflate gave back every block it took.
    try testing.expect(compared == 48 * 6 and retried >= 4);
    try testing.expectEqual(@as(usize, 0), libdeflate_blocks.load(.monotonic));
}

test "inflate refuses a stream that ends inside a code" {
    // The first 17 bytes of a 267-byte zlib stream from std's compressor (a dynamic-Huffman
    // block). Cut at 16 or 17, Zig 0.16.0's decompressor discarded bits it did not have
    // (tossBitsShort added consumed_bits where it must subtract them) and panicked; 0.17.0 has
    // the fix. Every cut must be refused.
    const prefix = [_]u8{ 0x78, 0x9c, 0x75, 0x94, 0x3d, 0x4a, 0x85, 0x41, 0x10, 0x04, 0x73, 0x4f, 0x31, 0xa1, 0x46, 0x6e, 0xf7 };
    for (0..prefix.len + 1) |cut| {
        try std.testing.expectError(error.Malformed, inflate(std.testing.allocator, prefix[0..cut], 1 << 20));
    }
}

test "an object loaded in the document scope is parsed once and cached; in another arena it is not cached" {
    const gpa = testing.allocator;
    const pdf = try buildPdf(gpa, &.{ "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>", "<< /A 1 >>" }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    // Object 3 is not in the page tree, so open has not loaded it.
    try testing.expect(!r.cache.contains(3));
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const once = try r.scopeIn(&arena_state).load(3);
    try testing.expectEqual(@as(i64, 1), once.dict.get("A").?.integer);
    try testing.expect(!r.cache.contains(3));
    const first = try r.object(3);
    try testing.expect(r.cache.contains(3));
    try testing.expectEqual(first.dict.entries.ptr, (try r.object(3)).dict.entries.ptr);
    // Once cached, any scope gets the cached object.
    try testing.expectEqual(first.dict.entries.ptr, (try r.scopeIn(&arena_state).load(3)).dict.entries.ptr);
}
