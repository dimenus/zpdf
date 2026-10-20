//! zpdf's images: a JPEG or PNG file, checked and turned into the samples of a PDF image
//! XObject (ISO 32000-1 8.9). pdf.zig writes the objects; this file knows no PDF syntax.
//!
//! How to use it:
//!   var img = try image.decode(gpa, bytes, max_bytes);
//!   defer img.deinit(gpa);
//!   // img.width x img.height samples of img.color at img.bits, img.data rows from the top,
//!   // each row padded to a whole byte; img.alpha, when set, is a DeviceGray soft mask.
//!
//! JPEG (baseline, extended or progressive Huffman, 8 bits, 1, 3 or 4 components) is not
//! decoded: its bytes go into the PDF as they are, for /DCTDecode. The file's structure is checked
//! up to its end-of-image marker; the entropy-coded data is not. A 4-component JPEG is CMYK with
//! its samples inverted (0 is full ink), because that is how JPEG viewers read every CMYK JPEG,
//! with an Adobe APP14 marker or without, while PDF readers draw /DCTDecode samples as they are:
//! pdf.zig writes the inverting /Decode, so the PDF shows what a viewer of the file shows.
//!
//! PNG is decoded in full, every colour type and bit depth, interlaced or not, so a broken file is
//! refused here, not drawn wrong by a viewer. Its alpha becomes a soft mask (an alpha channel, or
//! a palette's tRNS); a grey or RGB tRNS becomes a colour-key mask. gAMA, cHRM, sRGB and iCCP are
//! not applied: the samples are written as DeviceGray or DeviceRGB, as Pillow and the browsers
//! that ignore those chunks draw them.
//!
//! Orientation: the Exif orientation tag (a JPEG's APP1, a PNG's eXIf) is read, not applied to
//! the samples; the caller draws through `Orientation.matrix`, which turns the stored picture the
//! way the tag says.
//!
//! Refused, and never drawn with a guess:
//! - error.InvalidImage: anything that breaks the format, including a bad PNG CRC or zlib
//!   checksum, image data shorter or longer than the image, a palette index past the palette, and
//!   an Exif block that cannot be read or has an orientation outside 1 to 8.
//! - error.UnsupportedImage: a file that is neither PNG nor JPEG; a JPEG that is lossless,
//!   hierarchical, arithmetic-coded, 12-bit, with 2 components or more than 4, or sized by a DNL
//!   marker; a PNG with a critical chunk the PNG standard does not define.
//! - error.TooLarge: a PNG whose decoding would hold more than `max_bytes` (decodePng says what
//!   it counts).
//!
//! Images are untrusted input: every length and offset is checked against the file, and the
//! decoded size is checked before anything that size is allocated.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ InvalidImage, UnsupportedImage, TooLarge, OutOfMemory };

pub const ColorSpace = union(enum) {
    gray,
    rgb,
    /// A JPEG's 4 components, stored inverted (see the module doc).
    cmyk_inverted,
    /// A PNG palette: 3 bytes (r, g, b) per entry, 1 to 256 entries.
    indexed: []const u8,

    pub fn components(self: ColorSpace) u8 {
        return switch (self) {
            .gray, .indexed => 1,
            .rgb => 3,
            .cmyk_inverted => 4,
        };
    }
};

/// The Exif orientation (TIFF tag 0x0112): how the stored picture is turned to be shown.
pub const Orientation = enum(u3) {
    normal,
    mirror_horizontal,
    rotate_180,
    mirror_vertical,
    /// Mirrored across the top-left to bottom-right diagonal.
    transpose,
    rotate_90_cw,
    /// Mirrored across the top-right to bottom-left diagonal.
    transverse,
    rotate_90_ccw,

    fn fromExif(value: u16) Error!Orientation {
        if (value < 1 or value > 8) return error.InvalidImage;
        return @fromBackingInt(@intCast(value - 1));
    }

    /// True when the shown picture is the stored one turned a quarter: its width is the stored
    /// height.
    pub fn swapsAxes(self: Orientation) bool {
        return @backingInt(self) >= @backingInt(Orientation.transpose);
    }

    /// The `cm` matrix [a b c d e f] that draws the image (the unit square, its first row at the
    /// top) turned this way, into the rectangle with bottom-left (x, y) and size w x h as shown.
    /// Each case maps the stored picture's top row and left column to the side of the shown
    /// picture that the Exif tag names for them (TIFF 6.0, Orientation).
    pub fn matrix(self: Orientation, x: f64, y: f64, w: f64, h: f64) [6]f64 {
        return switch (self) {
            .normal => .{ w, 0, 0, h, x, y },
            .mirror_horizontal => .{ -w, 0, 0, h, x + w, y },
            .rotate_180 => .{ -w, 0, 0, -h, x + w, y + h },
            .mirror_vertical => .{ w, 0, 0, -h, x, y + h },
            .transpose => .{ 0, -h, -w, 0, x + w, y + h },
            .rotate_90_cw => .{ 0, -h, w, 0, x, y + h },
            .transverse => .{ 0, h, w, 0, x, y },
            .rotate_90_ccw => .{ 0, h, -w, 0, x + w, y },
        };
    }
};

/// A colour-key mask (ISO 32000-1 8.9.6.4): a pixel whose samples equal these is not painted.
pub const ColorKey = struct {
    values: [3]u16,
    len: u2,
};

pub const Image = struct {
    /// The stored picture's size in pixels; Orientation.swapsAxes says whether it is shown
    /// turned.
    width: u32,
    height: u32,
    orientation: Orientation,
    color: ColorSpace,
    /// Bits per sample: 1, 2, 4, 8 or 16.
    bits: u8,
    /// Rows from the top, each padded to a whole byte. For a JPEG, its file, for /DCTDecode.
    data: []const u8,
    encoding: enum { samples, dct },
    color_key: ?ColorKey = null,
    /// A soft mask, DeviceGray, `alpha_bits` per sample, the same size and layout as `data`.
    /// null when every pixel is opaque.
    alpha: ?[]const u8 = null,
    alpha_bits: u8 = 8,
    /// The buffer `data` lies in, when decode allocated it (a PNG); a JPEG's data is its file.
    allocation: []u8 = &.{},

    /// Frees what decode allocated.
    pub fn deinit(self: *Image, gpa: Allocator) void {
        gpa.free(self.allocation);
        if (self.alpha) |a| gpa.free(a);
        self.* = undefined;
    }

    /// The size as shown, after the orientation.
    pub fn shownSize(self: Image) [2]u32 {
        return if (self.orientation.swapsAxes()) .{ self.height, self.width } else .{ self.width, self.height };
    }
};

/// `bytes` must stay valid while the result is used: a JPEG's data and a PNG's palette are slices
/// of it. The result's buffers are allocated with `gpa`; Image.deinit frees them.
pub fn decode(gpa: Allocator, bytes: []const u8, max_bytes: usize) Error!Image {
    if (std.mem.startsWith(u8, bytes, png_signature)) return decodePng(gpa, bytes, max_bytes);
    if (std.mem.startsWith(u8, bytes, "\xFF\xD8\xFF")) return parseJpeg(bytes);
    return error.UnsupportedImage;
}

// ---- JPEG ----

/// ITU-T T.81 B.1.1: markers, segments, and the scan that SOS starts.
fn parseJpeg(bytes: []const u8) Error!Image {
    var pos: usize = 2;
    var frame: ?struct { width: u16, height: u16, components: u8 } = null;
    var orientation: ?Orientation = null;
    while (true) {
        if (pos >= bytes.len or bytes[pos] != 0xFF) return error.InvalidImage;
        // Any number of 0xFF may come before a marker (B.1.1.2).
        while (pos < bytes.len and bytes[pos] == 0xFF) pos += 1;
        if (pos >= bytes.len) return error.InvalidImage;
        const marker = bytes[pos];
        pos += 1;
        switch (marker) {
            // EOI before any scan, or a marker that may only come inside entropy-coded data.
            0x00, 0xD0...0xD9 => return error.InvalidImage,
            0x01 => continue,
            else => {},
        }
        if (bytes.len - pos < 2) return error.InvalidImage;
        const len = std.mem.readInt(u16, bytes[pos..][0..2], .big);
        if (len < 2 or bytes.len - pos < len) return error.InvalidImage;
        const segment = bytes[pos + 2 .. pos + len];
        pos += len;
        switch (marker) {
            // SOF0 baseline, SOF1 extended, SOF2 progressive: Huffman coding, what /DCTDecode
            // reads (ISO 32000-1 7.4.8).
            0xC0, 0xC1, 0xC2 => {
                if (frame != null) return error.InvalidImage;
                if (segment.len < 6) return error.InvalidImage;
                const precision = segment[0];
                const height = std.mem.readInt(u16, segment[1..3], .big);
                const width = std.mem.readInt(u16, segment[3..5], .big);
                const n = segment[5];
                if (segment.len != 6 + 3 * @as(usize, n)) return error.InvalidImage;
                if (width == 0 or n == 0) return error.InvalidImage;
                if (precision != 8) return error.UnsupportedImage;
                // A height of 0 is given later by a DNL marker.
                if (height == 0) return error.UnsupportedImage;
                if (n != 1 and n != 3 and n != 4) return error.UnsupportedImage;
                frame = .{ .width = width, .height = height, .components = n };
            },
            // Lossless, hierarchical, and arithmetic-coded frames.
            0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => return error.UnsupportedImage,
            0xE1 => if (orientation == null and std.mem.startsWith(u8, segment, "Exif\x00\x00")) {
                orientation = try exifOrientation(segment[6..]);
            },
            0xDA => {
                const f = frame orelse return error.InvalidImage;
                // Entropy-coded data holds 0xFF only as 0xFF00 or a restart marker, so the
                // first FFD9 after the scan starts is the end of the image. A progressive
                // file has more segments and scans before it; they are not checked.
                const eoi = std.mem.indexOfPos(u8, bytes, pos, "\xFF\xD9") orelse return error.InvalidImage;
                return .{
                    .width = f.width,
                    .height = f.height,
                    .orientation = orientation orelse .normal,
                    .color = switch (f.components) {
                        1 => .gray,
                        3 => .rgb,
                        4 => .cmyk_inverted,
                        else => unreachable,
                    },
                    .bits = 8,
                    .data = bytes[0 .. eoi + 2],
                    .encoding = .dct,
                };
            },
            else => {},
        }
    }
}

/// The orientation in an Exif block (a TIFF file, TIFF 6.0 section 2): IFD0's tag 0x0112, a
/// SHORT. No tag is .normal.
fn exifOrientation(tiff: []const u8) Error!Orientation {
    if (tiff.len < 8) return error.InvalidImage;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, tiff[0..2], "II"))
        .little
    else if (std.mem.eql(u8, tiff[0..2], "MM"))
        .big
    else
        return error.InvalidImage;
    if (std.mem.readInt(u16, tiff[2..4], endian) != 42) return error.InvalidImage;
    const ifd = std.mem.readInt(u32, tiff[4..8], endian);
    if (ifd > tiff.len or tiff.len - ifd < 2) return error.InvalidImage;
    const count = std.mem.readInt(u16, tiff[ifd..][0..2], endian);
    if ((tiff.len - ifd - 2) / 12 < count) return error.InvalidImage;
    for (0..count) |i| {
        const entry = tiff[ifd + 2 + 12 * i ..][0..12];
        if (std.mem.readInt(u16, entry[0..2], endian) != 0x0112) continue;
        // Type 3 is SHORT; one value, held in the entry itself.
        if (std.mem.readInt(u16, entry[2..4], endian) != 3) return error.InvalidImage;
        if (std.mem.readInt(u32, entry[4..8], endian) != 1) return error.InvalidImage;
        return Orientation.fromExif(std.mem.readInt(u16, entry[8..10], endian));
    }
    return .normal;
}

// ---- PNG ----

const png_signature = "\x89PNG\r\n\x1a\n";

pub const Header = struct {
    width: u32,
    height: u32,
    depth: u8,
    color_type: u8,
    interlaced: bool,

    fn channels(h: Header) u8 {
        return switch (h.color_type) {
            0, 3 => 1,
            2 => 3,
            4 => 2,
            6 => 4,
            else => unreachable,
        };
    }

    fn bitsPerPixel(h: Header) u64 {
        return @as(u64, h.channels()) * h.depth;
    }

    /// The bytes of one row of `w` pixels, without its filter byte.
    fn rowBytes(h: Header, w: u64) u64 {
        return (w * h.bitsPerPixel() + 7) / 8;
    }
};

/// The PNG standard (third edition), section 5 (chunks), 7 and 9 (filters), 8 (Adam7), 10
/// (zlib), 11 (the chunks it defines).
///
/// Memory: the IDAT data is used where it lies when it is one chunk, and copied once, at its exact
/// size, when it is several. It is inflated into a buffer of the exact size, then unfiltered and
/// packed into image rows in that same buffer; an interlaced image needs a second buffer for its
/// passes. An alpha channel is split out into its own plane, and the colour samples are packed in
/// place. So an RGBA image holds about 1.25 times its samples, not three copies.
fn decodePng(gpa: Allocator, bytes: []const u8, max_bytes: usize) Error!Image {
    var pos: usize = png_signature.len;
    var header: ?Header = null;
    var palette: ?[]const u8 = null;
    var trns: ?[]const u8 = null;
    var orientation: ?Orientation = null;
    var idat_state: enum { before, in, after } = .before;
    // The IDAT chunks: where the first starts, how many, their data's total length, the last's data.
    var idat_start: usize = 0;
    var idat_chunks: usize = 0;
    var idat_len: u64 = 0;
    var idat_last: []const u8 = &.{};
    while (true) {
        if (bytes.len - pos < 12) return error.InvalidImage;
        const start = pos;
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        if (len > std.math.maxInt(i32) or bytes.len - pos - 12 < len) return error.InvalidImage;
        const kind = bytes[pos + 4 ..][0..4];
        const data = bytes[pos + 8 ..][0..len];
        const crc = std.mem.readInt(u32, bytes[pos + 8 + len ..][0..4], .big);
        if (std.hash.Crc32.hash(bytes[pos + 4 .. pos + 8 + len]) != crc) return error.InvalidImage;
        pos += 12 + len;
        for (kind) |c| if (!std.ascii.isAlphabetic(c)) return error.InvalidImage;
        if (header == null and !std.mem.eql(u8, kind, "IHDR")) return error.InvalidImage;
        if (idat_state == .in and !std.mem.eql(u8, kind, "IDAT")) idat_state = .after;

        if (std.mem.eql(u8, kind, "IHDR")) {
            if (header != null) return error.InvalidImage;
            header = try parseHeader(data);
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            const h = header.?;
            if (palette != null or idat_state != .before or trns != null) return error.InvalidImage;
            if (h.color_type == 0 or h.color_type == 4) return error.InvalidImage;
            if (len == 0 or len % 3 != 0 or len / 3 > 256) return error.InvalidImage;
            if (h.color_type == 3 and len / 3 > @as(u32, 1) << @intCast(h.depth)) return error.InvalidImage;
            palette = data;
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            const h = header.?;
            if (trns != null or idat_state != .before) return error.InvalidImage;
            switch (h.color_type) {
                0 => if (len != 2) return error.InvalidImage,
                2 => if (len != 6) return error.InvalidImage,
                3 => {
                    const p = palette orelse return error.InvalidImage;
                    if (len > p.len / 3) return error.InvalidImage;
                },
                else => return error.InvalidImage,
            }
            trns = data;
        } else if (std.mem.eql(u8, kind, "eXIf")) {
            if (orientation != null) return error.InvalidImage;
            orientation = try exifOrientation(data);
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            if (idat_state == .after) return error.InvalidImage;
            if (idat_state == .before) idat_start = start;
            idat_state = .in;
            idat_chunks += 1;
            idat_len += len;
            idat_last = data;
        } else if (std.mem.eql(u8, kind, "IEND")) {
            if (len != 0) return error.InvalidImage;
            break;
        } else if (kind[0] & 0x20 == 0) {
            // A critical chunk (an upper-case first letter) must be understood to draw the image.
            return error.UnsupportedImage;
        }
    }
    const h = header orelse return error.InvalidImage;
    if (idat_state == .before) return error.InvalidImage;
    if (h.color_type == 3 and palette == null) return error.InvalidImage;

    // The most decoding holds at once, in u64 so no product can wrap (usize is 32 bits on
    // wasm32): the IDAT copy (none for one chunk), the inflated rows with their filter bytes, an
    // interlaced image's own buffer, and an alpha plane. It counts the IDAT copy as held to the
    // end, though it is freed once inflated, so it is an upper bound.
    const size = std.math.mul(u64, h.rowBytes(h.width), h.height) catch return error.TooLarge;
    const pixel_count = @as(u64, h.width) * h.height;
    const alpha_len: u64 = switch (h.color_type) {
        3 => if (trns != null) pixel_count else 0,
        4, 6 => std.math.mul(u64, pixel_count, h.depth / 8) catch return error.TooLarge,
        else => 0,
    };
    const filtered_len = try filteredLength(h);
    var held: u64 = if (idat_chunks > 1) idat_len else 0;
    for ([_]u64{ filtered_len, if (h.interlaced) size else 0, alpha_len }) |part| {
        held = std.math.add(u64, held, part) catch return error.TooLarge;
    }
    if (held > max_bytes) return error.TooLarge;
    const stride: usize = @intCast(h.rowBytes(h.width));

    // Inflate, then let go of the IDAT copy before anything else is allocated.
    const filtered = try gpa.alloc(u8, @intCast(filtered_len));
    var filtered_owned = true;
    defer if (filtered_owned) gpa.free(filtered);
    {
        const copy: []u8 = if (idat_chunks > 1) try gpa.alloc(u8, @intCast(idat_len)) else &.{};
        defer gpa.free(copy);
        if (idat_chunks > 1) {
            // The IDAT chunks are consecutive, from idat_start; their CRCs are already checked.
            var at = idat_start;
            var n: usize = 0;
            while (n < copy.len) {
                const len = std.mem.readInt(u32, bytes[at..][0..4], .big);
                @memcpy(copy[n..][0..len], bytes[at + 8 ..][0..len]);
                n += len;
                at += 12 + len;
            }
        }
        try inflateExactly(gpa, if (idat_chunks > 1) copy else idat_last, filtered);
    }

    // `allocation` is what the Image owns: the inflated buffer, or an interlaced image's own.
    var allocation: []u8 = undefined;
    if (h.interlaced) {
        allocation = try gpa.alloc(u8, @intCast(size));
        @memset(allocation, 0);
        var at: usize = 0;
        for (adam7) |pass| {
            const pw = passSize(h.width, pass.x0, pass.dx);
            const ph = passSize(h.height, pass.y0, pass.dy);
            if (pw == 0 or ph == 0) continue;
            const prb: usize = @intCast(h.rowBytes(pw));
            const len = (prb + 1) * ph;
            unfilter(filtered[at..][0..len], prb, h) catch |err| {
                gpa.free(allocation);
                return err;
            };
            scatterPass(allocation, stride, filtered[at..][0..len], prb, h, pass, pw, ph);
            at += len;
        }
    } else {
        try unfilter(filtered, stride, h);
        // Row r moves from r * (stride + 1) + 1 to r * stride: always down, so in place.
        for (0..h.height) |row| std.mem.copyForwards(u8, filtered[row * stride ..][0..stride], filtered[row * (stride + 1) + 1 ..][0..stride]);
        allocation = filtered;
        filtered_owned = false;
    }
    errdefer gpa.free(allocation);
    const pixels = allocation[0..@intCast(size)];

    var result: Image = .{
        .width = h.width,
        .height = h.height,
        .orientation = orientation orelse .normal,
        .color = switch (h.color_type) {
            0, 4 => .gray,
            2, 6 => .rgb,
            3 => .{ .indexed = palette.? },
            else => unreachable,
        },
        .bits = h.depth,
        .data = pixels,
        .encoding = .samples,
        .allocation = allocation,
    };
    switch (h.color_type) {
        0, 2 => if (trns) |t| {
            var key: ColorKey = .{ .values = .{ 0, 0, 0 }, .len = @intCast(t.len / 2) };
            const max_sample = (@as(u32, 1) << @intCast(h.depth)) - 1;
            for (0..key.len) |i| {
                const v = std.mem.readInt(u16, t[i * 2 ..][0..2], .big);
                // Below 16 bits, only the low bits may be set (PNG 11.3.2.1).
                if (v > max_sample) return error.InvalidImage;
                key.values[i] = v;
            }
            result.color_key = key;
        },
        3 => {
            const entries = palette.?.len / 3;
            const t = trns orelse &.{};
            // Only a tRNS can make a pixel other than opaque, so without one there is no plane.
            const alpha: []u8 = if (trns != null) try gpa.alloc(u8, @intCast(pixel_count)) else &.{};
            var opaque_all = true;
            for (0..h.height) |row| {
                for (0..h.width) |col| {
                    const index = sampleAt(pixels[row * stride ..][0..stride], col, h.depth);
                    if (index >= entries) {
                        gpa.free(alpha);
                        return error.InvalidImage;
                    }
                    if (trns == null) continue;
                    const a: u8 = if (index < t.len) t[index] else 255;
                    alpha[row * h.width + col] = a;
                    opaque_all = opaque_all and a == 255;
                }
            }
            if (opaque_all) gpa.free(alpha) else result.alpha = alpha;
        },
        4, 6 => {
            const color_n: usize = h.channels() - 1;
            const sample_bytes: usize = h.depth / 8;
            const n_pixels: usize = @intCast(pixel_count);
            const alpha = try gpa.alloc(u8, n_pixels * sample_bytes);
            var opaque_all = true;
            const pixel_bytes = (color_n + 1) * sample_bytes;
            const color_bytes = color_n * sample_bytes;
            for (0..n_pixels) |i| {
                const a = pixels[i * pixel_bytes + color_bytes ..][0..sample_bytes];
                @memcpy(alpha[i * sample_bytes ..][0..sample_bytes], a);
                for (a) |byte| opaque_all = opaque_all and byte == 0xFF;
                // Pixel i's colour moves from i * pixel_bytes to i * color_bytes: down, and no
                // further than its own alpha, which was read first.
                std.mem.copyForwards(u8, pixels[i * color_bytes ..][0..color_bytes], pixels[i * pixel_bytes ..][0..color_bytes]);
            }
            result.data = pixels[0 .. n_pixels * color_bytes];
            if (opaque_all) gpa.free(alpha) else {
                result.alpha = alpha;
                result.alpha_bits = h.depth;
            }
        },
        else => unreachable,
    }
    return result;
}

fn parseHeader(data: []const u8) Error!Header {
    if (data.len != 13) return error.InvalidImage;
    const width = std.mem.readInt(u32, data[0..4], .big);
    const height = std.mem.readInt(u32, data[4..8], .big);
    if (width == 0 or height == 0 or width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) return error.InvalidImage;
    const depth = data[8];
    const color_type = data[9];
    const depth_ok = switch (color_type) {
        0 => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
        3 => depth == 1 or depth == 2 or depth == 4 or depth == 8,
        2, 4, 6 => depth == 8 or depth == 16,
        else => return error.InvalidImage,
    };
    if (!depth_ok) return error.InvalidImage;
    // Compression method 0 (zlib) and filter method 0 are the only ones defined.
    if (data[10] != 0 or data[11] != 0) return error.InvalidImage;
    if (data[12] > 1) return error.InvalidImage;
    return .{ .width = width, .height = height, .depth = depth, .color_type = color_type, .interlaced = data[12] == 1 };
}

/// The length of the zlib data once inflated: each row of each pass with its filter byte.
fn filteredLength(h: Header) Error!u64 {
    if (!h.interlaced) return std.math.mul(u64, h.rowBytes(h.width) + 1, h.height) catch error.TooLarge;
    var total: u64 = 0;
    for (adam7) |pass| {
        const pw = passSize(h.width, pass.x0, pass.dx);
        const ph = passSize(h.height, pass.y0, pass.dy);
        if (pw == 0 or ph == 0) continue;
        total += (h.rowBytes(pw) + 1) * ph;
    }
    return total;
}

/// Fills `out` exactly, and the zlib stream must end there with a good checksum.
fn inflateExactly(gpa: Allocator, data: []const u8, out: []u8) Error!void {
    var in: std.Io.Reader = .fixed(data);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var d: std.compress.flate.Decompress = .init(&in, .zlib, window);
    d.reader.readSliceAll(out) catch return error.InvalidImage;
    // Any byte left is data the image has no room for. Reading to the end also reads the
    // footer, but std's Decompress only stores its Adler-32 (container_metadata) and never
    // compares it, so that is done here.
    const rest = d.reader.discardRemaining() catch return error.InvalidImage;
    if (rest != 0) return error.InvalidImage;
    if (std.hash.Adler32.hash(out) != d.container_metadata.zlib.adler) return error.InvalidImage;
}

/// Undoes the filters of `len / (row_bytes + 1)` rows, in place (PNG 7.3 and 9).
fn unfilter(rows: []u8, row_bytes: usize, h: Header) Error!void {
    const bpp: usize = @intCast(@max(1, h.bitsPerPixel() / 8));
    const n = rows.len / (row_bytes + 1);
    for (0..n) |r| {
        const filter = rows[r * (row_bytes + 1)];
        const cur = rows[r * (row_bytes + 1) + 1 ..][0..row_bytes];
        const prev: ?[]const u8 = if (r == 0) null else rows[(r - 1) * (row_bytes + 1) + 1 ..][0..row_bytes];
        switch (filter) {
            0 => {},
            1 => for (bpp..row_bytes) |i| {
                cur[i] +%= cur[i - bpp];
            },
            2 => if (prev) |p| for (cur, p) |*c, b| {
                c.* +%= b;
            },
            3 => for (cur, 0..) |*c, i| {
                const a: u16 = if (i >= bpp) cur[i - bpp] else 0;
                const b: u16 = if (prev) |p| p[i] else 0;
                c.* +%= @intCast((a + b) / 2);
            },
            4 => for (cur, 0..) |*c, i| {
                const a: u8 = if (i >= bpp) cur[i - bpp] else 0;
                const b: u8 = if (prev) |p| p[i] else 0;
                const cc: u8 = if (i >= bpp) (if (prev) |p| p[i - bpp] else 0) else 0;
                c.* +%= paeth(a, b, cc);
            },
            else => return error.InvalidImage,
        }
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

const Pass = struct { x0: u32, y0: u32, dx: u32, dy: u32 };

/// PNG 8.2.
const adam7 = [7]Pass{
    .{ .x0 = 0, .y0 = 0, .dx = 8, .dy = 8 },
    .{ .x0 = 4, .y0 = 0, .dx = 8, .dy = 8 },
    .{ .x0 = 0, .y0 = 4, .dx = 4, .dy = 8 },
    .{ .x0 = 2, .y0 = 0, .dx = 4, .dy = 4 },
    .{ .x0 = 0, .y0 = 2, .dx = 2, .dy = 4 },
    .{ .x0 = 1, .y0 = 0, .dx = 2, .dy = 2 },
    .{ .x0 = 0, .y0 = 1, .dx = 1, .dy = 2 },
};

fn passSize(full: u32, start: u32, step: u32) u32 {
    if (full <= start) return 0;
    return (full - start + step - 1) / step;
}

/// Copies one unfiltered Adam7 pass's pixels to their places in the image.
fn scatterPass(pixels: []u8, stride: usize, rows: []const u8, row_bytes: usize, h: Header, pass: Pass, pw: u32, ph: u32) void {
    const bpp_bits: usize = @intCast(h.bitsPerPixel());
    for (0..ph) |j| {
        const src = rows[j * (row_bytes + 1) + 1 ..][0..row_bytes];
        const dst = pixels[(pass.y0 + j * pass.dy) * stride ..][0..stride];
        for (0..pw) |i| {
            const x = pass.x0 + i * pass.dx;
            if (bpp_bits >= 8) {
                const n = bpp_bits / 8;
                @memcpy(dst[x * n ..][0..n], src[i * n ..][0..n]);
            } else {
                const v = sampleAt(src, i, h.depth);
                setSample(dst, x, h.depth, v);
            }
        }
    }
}

/// Sample `i` of a row of `depth`-bit samples, the first in the high bits of a byte.
fn sampleAt(row: []const u8, i: usize, depth: u8) usize {
    return switch (depth) {
        8 => row[i],
        16 => std.mem.readInt(u16, row[i * 2 ..][0..2], .big),
        1, 2, 4 => {
            const per_byte = 8 / depth;
            const shift: u3 = @intCast(8 - depth * (1 + i % per_byte));
            const mask = (@as(u8, 1) << @intCast(depth)) - 1;
            return (row[i / per_byte] >> shift) & mask;
        },
        else => unreachable,
    };
}

fn setSample(row: []u8, i: usize, depth: u8, v: usize) void {
    const per_byte = 8 / depth;
    const shift: u3 = @intCast(8 - depth * (1 + i % per_byte));
    row[i / per_byte] |= @as(u8, @intCast(v)) << shift;
}

// ---- tests ----

const testing = std.testing;

/// Tests (here and in pdf.zig): a PNG of the given chunks, after IHDR; each chunk gets its
/// length and CRC.
pub fn testPng(gpa: Allocator, header: Header, chunks: []const struct { []const u8, []const u8 }) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll(png_signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], header.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], header.height, .big);
    ihdr[8] = header.depth;
    ihdr[9] = header.color_type;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = @intFromBool(header.interlaced);
    try writeChunk(&out.writer, "IHDR", &ihdr);
    for (chunks) |c| try writeChunk(&out.writer, c[0], c[1]);
    try writeChunk(&out.writer, "IEND", "");
    return out.toOwnedSlice();
}

fn writeChunk(w: *std.Io.Writer, kind: []const u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

/// Tests: `data` as a zlib stream.
pub fn testZlib(gpa: Allocator, data: []const u8) ![]u8 {
    // Compress.init asserts its sink has room for at least 9 bytes.
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
    errdefer out.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var c = try std.compress.flate.Compress.init(&out.writer, window, .zlib, .default);
    try c.writer.writeAll(data);
    try c.finish();
    return out.toOwnedSlice();
}

test "a 2x2 RGBA PNG splits into RGB samples and an alpha mask; an opaque one writes no mask" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Two rows, filter 0 (None) and 2 (Up): the second row adds the first to its bytes.
    const rows = [_]u8{ 0, 255, 0, 0, 128, 0, 255, 0, 255 } ++ [_]u8{ 2, 0, 0, 255, 127, 0, 0, 0, 0 };
    const png = try testPng(arena, .{ .width = 2, .height = 2, .depth = 8, .color_type = 6, .interlaced = false }, &.{.{ "IDAT", try testZlib(arena, &rows) }});
    const img = try decode(arena, png, 1 << 20);
    try testing.expectEqual(2, img.width);
    try testing.expectEqual(.rgb, std.meta.activeTag(img.color));
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 255, 0, 255, 0, 255, 0, 255, 0 }, img.data);
    try testing.expectEqualSlices(u8, &.{ 128, 255, 255, 255 }, img.alpha.?);

    const solid = [_]u8{ 0, 1, 2, 3, 255 } ++ [_]u8{ 0, 4, 5, 6, 255 };
    const png2 = try testPng(arena, .{ .width = 1, .height = 2, .depth = 8, .color_type = 6, .interlaced = false }, &.{.{ "IDAT", try testZlib(arena, &solid) }});
    const img2 = try decode(arena, png2, 1 << 20);
    try testing.expectEqual(null, img2.alpha);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, img2.data);
}

test "PNG refusals: bad CRC, short and long data, a palette index past the palette, a bad tRNS, budget" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gray: Header = .{ .width = 2, .height = 1, .depth = 8, .color_type = 0, .interlaced = false };
    const good = try testPng(arena, gray, &.{.{ "IDAT", try testZlib(arena, &.{ 0, 10, 20 }) }});
    _ = try decode(arena, good, 1 << 20);

    const bad_crc = try arena.dupe(u8, good);
    bad_crc[png_signature.len + 8] ^= 1;
    try testing.expectError(error.InvalidImage, decode(arena, bad_crc, 1 << 20));
    try testing.expectError(error.InvalidImage, decode(arena, try testPng(arena, gray, &.{.{ "IDAT", try testZlib(arena, &.{ 0, 10 }) }}), 1 << 20));
    try testing.expectError(error.InvalidImage, decode(arena, try testPng(arena, gray, &.{.{ "IDAT", try testZlib(arena, &.{ 0, 10, 20, 30 }) }}), 1 << 20));
    try testing.expectError(error.InvalidImage, decode(arena, try testPng(arena, gray, &.{.{ "IDAT", try testZlib(arena, &.{ 5, 10, 20 }) }}), 1 << 20));
    // The inflated rows (3 bytes) hold the image too: it is packed into them.
    try testing.expectError(error.TooLarge, decode(arena, good, 2));
    _ = try decode(arena, good, 3);
    // A 1-bit palette with tRNS: 2 bytes of rows, and an alpha byte per pixel (8).
    const bits: Header = .{ .width = 8, .height = 1, .depth = 1, .color_type = 3, .interlaced = false };
    const two = try testPng(arena, bits, &.{ .{ "PLTE", "\xff\x00\x00\x00\xff\x00" }, .{ "tRNS", "\x80" }, .{ "IDAT", try testZlib(arena, &.{ 0, 0x55 }) } });
    try testing.expectError(error.TooLarge, decode(arena, two, 9));
    const masked = try decode(arena, two, 10);
    try testing.expectEqualSlices(u8, &.{ 128, 255, 128, 255, 128, 255, 128, 255 }, masked.alpha.?);

    const indexed: Header = .{ .width = 2, .height = 1, .depth = 8, .color_type = 3, .interlaced = false };
    const plte = "\xff\x00\x00\x00\xff\x00";
    _ = try decode(arena, try testPng(arena, indexed, &.{ .{ "PLTE", plte }, .{ "IDAT", try testZlib(arena, &.{ 0, 0, 1 }) } }), 1 << 20);
    try testing.expectError(error.InvalidImage, decode(arena, try testPng(arena, indexed, &.{ .{ "PLTE", plte }, .{ "IDAT", try testZlib(arena, &.{ 0, 0, 2 }) } }), 1 << 20));
    // tRNS longer than the palette, and a grey key with bits past the depth.
    try testing.expectError(error.InvalidImage, decode(arena, try testPng(arena, indexed, &.{ .{ "PLTE", plte }, .{ "tRNS", "\x00\x00\x00" }, .{ "IDAT", try testZlib(arena, &.{ 0, 0, 1 }) } }), 1 << 20));
    const gray4: Header = .{ .width = 2, .height = 1, .depth = 4, .color_type = 0, .interlaced = false };
    try testing.expectError(error.InvalidImage, decode(arena, try testPng(arena, gray4, &.{ .{ "tRNS", "\x00\x10" }, .{ "IDAT", try testZlib(arena, &.{ 0, 0x12 }) } }), 1 << 20));
    const keyed = try decode(arena, try testPng(arena, gray4, &.{ .{ "tRNS", "\x00\x0f" }, .{ "IDAT", try testZlib(arena, &.{ 0, 0x12 }) } }), 1 << 20);
    try testing.expectEqual(15, keyed.color_key.?.values[0]);
    // An unknown critical chunk, and one that is ancillary.
    try testing.expectError(error.UnsupportedImage, decode(arena, try testPng(arena, gray, &.{ .{ "ABCD", "" }, .{ "IDAT", try testZlib(arena, &.{ 0, 10, 20 }) } }), 1 << 20));
    _ = try decode(arena, try testPng(arena, gray, &.{ .{ "abCD", "" }, .{ "IDAT", try testZlib(arena, &.{ 0, 10, 20 }) } }), 1 << 20);
    try testing.expectError(error.UnsupportedImage, decode(arena, "GIF89a", 1 << 20));
}

test "JPEG frames: 1, 3 and 4 components are taken, 2 and 5 refused, and lossless refused" {
    // SOI, an SOF segment, SOS, EOI: enough for parseJpeg, which does not decode the scan.
    const Frame = struct {
        fn jpeg(buf: *[64]u8, marker: u8, n: u8) []const u8 {
            var w: std.Io.Writer = .fixed(buf);
            w.writeAll("\xFF\xD8\xFF") catch unreachable;
            w.writeByte(marker) catch unreachable;
            w.writeInt(u16, 8 + 3 * @as(u16, n), .big) catch unreachable;
            w.writeAll("\x08\x00\x10\x00\x20") catch unreachable;
            w.writeByte(n) catch unreachable;
            for (0..n) |i| w.writeAll(&.{ @intCast(i + 1), 0x11, 0 }) catch unreachable;
            w.writeAll("\xFF\xDA\x00\x02\x00\xFF\xD9") catch unreachable;
            return w.buffered();
        }
    };
    var buf: [64]u8 = undefined;
    try testing.expectEqual(.gray, std.meta.activeTag((try decode(testing.allocator, Frame.jpeg(&buf, 0xC0, 1), 0)).color));
    try testing.expectEqual(.rgb, std.meta.activeTag((try decode(testing.allocator, Frame.jpeg(&buf, 0xC2, 3), 0)).color));
    const cmyk = try decode(testing.allocator, Frame.jpeg(&buf, 0xC0, 4), 0);
    try testing.expectEqual(.cmyk_inverted, std.meta.activeTag(cmyk.color));
    try testing.expectEqual([2]u32{ 32, 16 }, cmyk.shownSize());
    try testing.expectError(error.UnsupportedImage, decode(testing.allocator, Frame.jpeg(&buf, 0xC0, 2), 0));
    try testing.expectError(error.UnsupportedImage, decode(testing.allocator, Frame.jpeg(&buf, 0xC0, 5), 0));
    try testing.expectError(error.UnsupportedImage, decode(testing.allocator, Frame.jpeg(&buf, 0xC3, 3), 0));
}

test "IDAT split over chunks decodes as one; a bad zlib checksum or data after the image is refused" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rgb: Header = .{ .width = 3, .height = 2, .depth = 8, .color_type = 2, .interlaced = false };
    const rows = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 } ++ [_]u8{ 1, 10, 20, 30, 1, 1, 1, 2, 2, 2 };
    const z = try testZlib(arena, &rows);
    // Decoded with the real allocator, so a buffer decode forgets to free fails the test.
    var one = try decode(gpa, try testPng(arena, rgb, &.{.{ "IDAT", z }}), 1 << 20);
    defer one.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 20, 30, 11, 21, 31, 13, 23, 33 }, one.data);
    const split_png = try testPng(arena, rgb, &.{ .{ "IDAT", z[0..3] }, .{ "IDAT", z[3..7] }, .{ "IDAT", z[7..] } });
    var split = try decode(gpa, split_png, 1 << 20);
    defer split.deinit(gpa);
    try testing.expectEqualSlices(u8, one.data, split.data);
    // The budget: one chunk is inflated where it lies (20 bytes of rows); several are copied
    // first, so their compressed length counts too.
    try testing.expectError(error.TooLarge, decode(gpa, try testPng(arena, rgb, &.{.{ "IDAT", z }}), 19));
    var at_budget = try decode(gpa, try testPng(arena, rgb, &.{.{ "IDAT", z }}), 20);
    at_budget.deinit(gpa);
    try testing.expectError(error.TooLarge, decode(gpa, split_png, 20 + z.len - 1));
    var split_at_budget = try decode(gpa, split_png, 20 + z.len);
    split_at_budget.deinit(gpa);

    const bad_adler = try arena.dupe(u8, z);
    bad_adler[bad_adler.len - 1] ^= 1;
    try testing.expectError(error.InvalidImage, decode(gpa, try testPng(arena, rgb, &.{.{ "IDAT", bad_adler }}), 1 << 20));
    // One byte past the image, with the footer's checksum made right for the image alone, so
    // only the length check can refuse it.
    const longer = try testZlib(arena, &(rows ++ [_]u8{7}));
    std.mem.writeInt(u32, longer[longer.len - 4 ..][0..4], std.hash.Adler32.hash(&rows), .big);
    try testing.expectError(error.InvalidImage, decode(gpa, try testPng(arena, rgb, &.{.{ "IDAT", longer }}), 1 << 20));
    // A refusal after the rows are decoded (a palette index past the palette) frees them too.
    const indexed: Header = .{ .width = 2, .height = 1, .depth = 8, .color_type = 3, .interlaced = false };
    try testing.expectError(error.InvalidImage, decode(gpa, try testPng(arena, indexed, &.{ .{ "PLTE", "\xff\x00\x00" }, .{ "tRNS", "\x80" }, .{ "IDAT", try testZlib(arena, &.{ 0, 0, 1 }) } }), 1 << 20));
    // An RGBA image's colour is packed where the pixels were, its alpha split out.
    const rgba: Header = .{ .width = 2, .height = 1, .depth = 16, .color_type = 6, .interlaced = false };
    const px = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    var split_alpha = try decode(gpa, try testPng(arena, rgba, &.{.{ "IDAT", try testZlib(arena, &px) }}), 1 << 20);
    defer split_alpha.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14 }, split_alpha.data);
    try testing.expectEqualSlices(u8, &.{ 7, 8, 15, 16 }, split_alpha.alpha.?);
    // Fully opaque: no mask, and the alpha plane it was split into is freed.
    const opaque_px = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 0xFF, 0xFF, 9, 10, 11, 12, 13, 14, 0xFF, 0xFF };
    var no_mask = try decode(gpa, try testPng(arena, rgba, &.{.{ "IDAT", try testZlib(arena, &opaque_px) }}), 1 << 20);
    defer no_mask.deinit(gpa);
    try testing.expectEqual(null, no_mask.alpha);
}

test "Exif orientation: both byte orders, no tag, and a value outside 1 to 8" {
    const le = "II\x2a\x00\x08\x00\x00\x00\x01\x00\x12\x01\x03\x00\x01\x00\x00\x00\x06\x00\x00\x00";
    try testing.expectEqual(.rotate_90_cw, try exifOrientation(le));
    const be = "MM\x00\x2a\x00\x00\x00\x08\x00\x01\x01\x12\x00\x03\x00\x00\x00\x01\x00\x08\x00\x00";
    try testing.expectEqual(.rotate_90_ccw, try exifOrientation(be));
    const none = "II\x2a\x00\x08\x00\x00\x00\x01\x00\x10\x01\x03\x00\x01\x00\x00\x00\x06\x00\x00\x00";
    try testing.expectEqual(.normal, try exifOrientation(none));
    const zero = "II\x2a\x00\x08\x00\x00\x00\x01\x00\x12\x01\x03\x00\x01\x00\x00\x00\x00\x00\x00\x00";
    try testing.expectError(error.InvalidImage, exifOrientation(zero));
    try testing.expectError(error.InvalidImage, exifOrientation(le[0..20]));
}

test "every orientation's matrix puts the stored top-left corner where the Exif tag says" {
    // The stored picture's top-left is (0, 1) in image space. Where it lands on a 10 x 20
    // rectangle at (100, 200): tag 1 top-left, 2 top-right, 3 bottom-right, 4 bottom-left,
    // 5 top-left, 6 top-right, 7 bottom-right, 8 bottom-left.
    const want = [8][2]f64{ .{ 100, 220 }, .{ 110, 220 }, .{ 110, 200 }, .{ 100, 200 }, .{ 100, 220 }, .{ 110, 220 }, .{ 110, 200 }, .{ 100, 200 } };
    for (want, 0..) |w, i| {
        const m = Orientation.matrix(@fromBackingInt(@intCast(i)), 100, 200, 10, 20);
        try testing.expectEqual(w[0], m[2] + m[4]);
        try testing.expectEqual(w[1], m[3] + m[5]);
        // Every matrix fills the rectangle: the four corners of the unit square land on its
        // corners.
        for ([_][2]f64{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |uv| {
            const px = m[0] * uv[0] + m[2] * uv[1] + m[4];
            const py = m[1] * uv[0] + m[3] * uv[1] + m[5];
            try testing.expect(px == 100 or px == 110);
            try testing.expect(py == 200 or py == 220);
        }
    }
}

test "PngSuite: every valid file decodes, every x* file is refused" {
    const options = @import("build_options");
    var dir = try std.Io.Dir.cwd().openDir(testing.io, options.pngsuite_dir, .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    var decoded: usize = 0;
    var refused: usize = 0;
    while (try it.next(testing.io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".png")) continue;
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const bytes = try dir.readFileAlloc(testing.io, entry.name, arena, .limited(1 << 20));
        // The test allocator, not the arena: a buffer decode forgets to free fails the test.
        var result = decode(testing.allocator, bytes, 1 << 24);
        if (entry.name[0] == 'x') {
            if (result) |*img| {
                img.deinit(testing.allocator);
                std.debug.print("{s}: decoded, but PngSuite says it is broken\n", .{entry.name});
                return error.TestUnexpectedResult;
            } else |_| refused += 1;
        } else {
            var img = result catch |err| {
                std.debug.print("{s}: {t}\n", .{ entry.name, err });
                return err;
            };
            img.deinit(testing.allocator);
            decoded += 1;
        }
    }
    // The run did the work: PngSuite 2017jul19 has 162 valid images and 14 broken ones.
    try testing.expectEqual(162, decoded);
    try testing.expectEqual(14, refused);
}

/// Damages `bytes` in place: `n` random bytes get random values.
fn damage(random: std.Random, bytes: []u8, n: usize) void {
    for (0..n) |_| bytes[random.uintLessThan(usize, bytes.len)] = random.int(u8);
}

/// Rewrites every chunk's CRC that lies inside `png`, so damage reaches past the CRC check.
fn fixCrcs(png: []u8) void {
    var pos: usize = png_signature.len;
    while (png.len - pos >= 12) {
        const len = std.mem.readInt(u32, png[pos..][0..4], .big);
        if (png.len - pos - 12 < len) return;
        std.mem.writeInt(u32, png[pos + 8 + len ..][0..4], std.hash.Crc32.hash(png[pos + 4 .. pos + 8 + len]), .big);
        pos += 12 + len;
    }
}

/// `png` with its IDAT chunks replaced by one holding `idat`, the other chunks as they were.
fn withIdat(gpa: Allocator, png: []const u8, idat: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll(png_signature);
    var pos: usize = png_signature.len;
    var written = false;
    while (png.len - pos >= 12) {
        const len = std.mem.readInt(u32, png[pos..][0..4], .big);
        const kind = png[pos + 4 ..][0..4];
        if (std.mem.eql(u8, kind, "IDAT")) {
            if (!written) try writeChunk(&out.writer, "IDAT", idat);
            written = true;
        } else try out.writer.writeAll(png[pos..][0 .. 12 + len]);
        pos += 12 + len;
    }
    return out.toOwnedSlice();
}

/// The concatenated IDAT data of a well-formed PNG, inflated.
fn inflatedIdat(gpa: Allocator, png: []const u8) ![]u8 {
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    var pos: usize = png_signature.len;
    while (png.len - pos >= 12) {
        const len = std.mem.readInt(u32, png[pos..][0..4], .big);
        if (std.mem.eql(u8, png[pos + 4 ..][0..4], "IDAT")) try idat.appendSlice(gpa, png[pos + 8 ..][0..len]);
        pos += 12 + len;
    }
    var in: std.Io.Reader = .fixed(idat.items);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var d: std.compress.flate.Decompress = .init(&in, .zlib, window);
    return d.reader.allocRemaining(gpa, .unlimited);
}

test "damaged images give an image or an error, never a crash or a hang" {
    const options = @import("build_options");
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7a706466);
    const random = prng.random();
    var decoded: usize = 0;
    var refused: usize = 0;
    var files: usize = 0;
    for ([_][]const u8{ "pngsuite", "exif", "jpeg", "png" }) |sub| {
        var root = try std.Io.Dir.cwd().openDir(testing.io, options.image_fixtures, .{});
        defer root.close(testing.io);
        var dir = try root.openDir(testing.io, sub, .{ .iterate = true });
        defer dir.close(testing.io);
        var it = dir.iterate();
        while (try it.next(testing.io)) |entry| {
            const is_png = std.mem.endsWith(u8, entry.name, ".png");
            if (!is_png and !std.mem.endsWith(u8, entry.name, ".jpg")) continue;
            if (entry.name[0] == 'x') continue;
            const bytes = try dir.readFileAlloc(testing.io, entry.name, gpa, .limited(1 << 20));
            defer gpa.free(bytes);
            files += 1;
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            // Outside the arena, which each round resets.
            const inner = if (is_png) try inflatedIdat(gpa, bytes) else try gpa.alloc(u8, 0);
            defer gpa.free(inner);
            for (0..48) |round| {
                _ = arena_state.reset(.retain_capacity);
                const copy = switch (round % 3) {
                    // Cut short anywhere.
                    0 => try arena.dupe(u8, bytes[0..random.uintLessThan(usize, bytes.len)]),
                    // A few bytes anywhere; a PNG's CRCs fixed, so the damage reaches its parser.
                    1 => blk: {
                        const c = try arena.dupe(u8, bytes);
                        damage(random, c, 1 + round % 4);
                        if (is_png) fixCrcs(c);
                        break :blk c;
                    },
                    // A PNG's inflated rows damaged and compressed again: filter types, palette
                    // indices and sample values the decoder must check after zlib does.
                    else => blk: {
                        if (!is_png) {
                            const c = try arena.dupe(u8, bytes);
                            damage(random, c, 1);
                            break :blk c;
                        }
                        const rows = try arena.dupe(u8, inner);
                        if (rows.len != 0) damage(random, rows, 1 + round % 3);
                        break :blk try withIdat(arena, bytes, try testZlib(arena, rows));
                    },
                };
                // The test allocator, so every error path is also checked for leaks.
                if (decode(gpa, copy, 1 << 24)) |img| {
                    var kept = img;
                    kept.deinit(gpa);
                    decoded += 1;
                } else |_| refused += 1;
            }
        }
    }
    // The run did the work: every fixture was damaged, and the damage reached both outcomes.
    try testing.expectEqual(162 + 16 + 5 + 2, files);
    try testing.expect(decoded > 1000 and refused > 1000);
}
