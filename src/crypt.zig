//! The PDF standard security handler (ISO 32000-2 7.6.4), for reading: it checks a password
//! against an encrypted file and decrypts its strings and streams.
//!
//! How to use it (src/read.zig does this when a file has /Encrypt):
//!   const h = try Handler.authenticate(params, password);    // params: the /Encrypt values
//!   const plain = try h.decrypt(arena, h.stream_method, num, gen, encrypted_bytes);
//!
//! Which files: /Filter /Standard, revisions 2 to 6: RC4 with a 40- to 128-bit key (R2, R3, and R4
//! with /CFM /V2), AES-128 (R4, /AESV2) and AES-256 (R5, Adobe's deprecated Extension Level 3
//! form, and R6, PDF 2.0). Other handlers (public-key /Adobe.PubSec) and other revisions are
//! error.UnsupportedEncryption, as MuPDF refuses them.
//!
//! The password, UTF-8, is tried as the user password, then as the owner password, which also
//! opens the file. An empty password is the user password of most encrypted files (they restrict
//! printing or copying and open without asking), so readers try it first; an empty owner password
//! does not open a file whose user password is not empty, as in Acrobat and MuPDF. For R2 to R4
//! the password is converted to PDFDocEncoding, a character it lacks becoming '?'; for R5 and R6
//! it is used as UTF-8, cut to 127 bytes, without the SASLprep the standard asks for (MuPDF does
//! the same). A wrong password is error.PasswordRequired.
//!
//! Permissions (/P) are not enforced: the reader extracts text whatever /P says, as MuPDF does.
//!
//! Encrypted data that is not well formed is error.Malformed: an AES stream whose length is not the
//! IV plus whole blocks, and AES data whose padding is out of range. One exception, as in MuPDF:
//! a string whose length AES cannot produce (under the 32 bytes of an IV and one padded block, or
//! not whole blocks) is taken as written. It cannot be ciphertext, and writers that leave a string
//! unencrypted make exactly these (a catalog's /OCProperties /D /Name, in a file from the web).

const std = @import("std");
const Md5 = std.crypto.hash.Md5;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha384 = std.crypto.hash.sha2.Sha384;
const Sha512 = std.crypto.hash.sha2.Sha512;
const aes = std.crypto.core.aes;

pub const Error = error{ PasswordRequired, UnsupportedEncryption, Malformed, OutOfMemory };

/// How a string or stream is encrypted (a crypt filter's /CFM, 7.6.6).
pub const Method = enum { none, rc4, aesv2, aesv3 };

/// The /Encrypt dictionary's values, read by src/read.zig, and the first element of the trailer's
/// /ID. The crypt filters (/CF, /StmF, /StrF) are already resolved to methods.
pub const Params = struct {
    /// /V: 1 and 2 are RC4 throughout; 4 and 5 name crypt filters.
    v: i64,
    /// /R: 2 to 6.
    r: i64,
    /// The key length in bits: /Length for V 2, the crypt filter's /Length for V 4; 40 for V 1.
    length: i64,
    o: []const u8,
    u: []const u8,
    /// /OE and /UE, R5 and R6 only; empty otherwise.
    oe: []const u8,
    ue: []const u8,
    p: i64,
    /// The first string of the trailer's /ID; empty when it has none.
    id: []const u8,
    /// /EncryptMetadata, true when absent.
    encrypt_metadata: bool,
    string_method: Method,
    stream_method: Method,
    /// The method of the crypt filter named /StdCF, for a stream whose /Crypt filter names it.
    std_cf_method: Method,
};

pub const Handler = struct {
    revision: u8,
    /// The file key: key_len bytes, 5 to 16 for R2 to R4, 32 for R5 and R6.
    key: [32]u8,
    key_len: u8,
    string_method: Method,
    stream_method: Method,
    std_cf_method: Method,
    encrypt_metadata: bool,

    /// The handler for `params` opened with `password` (UTF-8), or error.PasswordRequired.
    pub fn authenticate(params: Params, password: []const u8) Error!Handler {
        if (params.r < 2 or params.r > 6) return error.UnsupportedEncryption;
        switch (params.v) {
            1, 2, 4, 5 => {},
            else => return error.UnsupportedEncryption,
        }
        const r: u8 = @intCast(params.r);
        var h: Handler = .{
            .revision = r,
            .key = @splat(0),
            .key_len = 0,
            .string_method = params.string_method,
            .stream_method = params.stream_method,
            .std_cf_method = params.std_cf_method,
            .encrypt_metadata = params.encrypt_metadata,
        };
        if (r >= 5) {
            if (params.o.len < 48 or params.u.len < 48 or params.oe.len < 32 or params.ue.len < 32) return error.Malformed;
            var pw: [127]u8 = undefined;
            const n = @min(password.len, pw.len);
            @memcpy(pw[0..n], password[0..n]);
            h.key = (try aes256Key(r, pw[0..n], params)) orelse return error.PasswordRequired;
            h.key_len = 32;
            return h;
        }
        if (params.o.len < 32 or params.u.len < 32) return error.Malformed;
        // The key length in bytes: 5 for R2, /Length / 8 for R3 and R4 (7.6.4.3.2).
        const bits = if (r == 2) 40 else params.length;
        if (bits < 40 or bits > 128 or @mod(bits, 8) != 0) return error.Malformed;
        h.key_len = @intCast(@divExact(bits, 8));
        var pw: [32]u8 = undefined;
        const pw_len = toPdfDoc(password, &pw);
        if (userKey(r, h.key_len, pw[0..pw_len], params)) |key| {
            @memcpy(h.key[0..16], &key);
            return h;
        }
        if (password.len > 0) {
            // As the owner password: it decrypts /O into the user password (Algorithm 7).
            const user = userPasswordFromOwner(r, h.key_len, pw[0..pw_len], params.o[0..32]);
            if (userKey(r, h.key_len, &user, params)) |key| {
                @memcpy(h.key[0..16], &key);
                return h;
            }
        }
        return error.PasswordRequired;
    }

    /// A string of object `num` `gen` decrypted with string_method, in `arena`; as written when
    /// it is AES with a length AES cannot produce (the file's header says why). So it may be
    /// `data` itself: valid while both live, never freed by the caller.
    pub fn decryptString(self: *const Handler, arena: *std.heap.ArenaAllocator, num: u32, gen: u16, data: []const u8) Error![]const u8 {
        switch (self.string_method) {
            .aesv2, .aesv3 => if (data.len != 0 and (data.len < 32 or data.len % 16 != 0)) return data,
            .none, .rc4 => {},
        }
        return self.decrypt(arena, self.string_method, num, gen, data);
    }

    /// `data` of object `num` `gen` decrypted with `method`, in `arena` (or `data` itself for
    /// .none): valid while both live, never freed by the caller. AES data is the 16-byte IV,
    /// then whole blocks with PKCS #5 padding (7.6.3.1).
    pub fn decrypt(self: *const Handler, arena: *std.heap.ArenaAllocator, method: Method, num: u32, gen: u16, data: []const u8) Error![]const u8 {
        const a = arena.allocator();
        switch (method) {
            .none => return data,
            .rc4 => {
                const key = self.objectKey(num, gen, false);
                const out = try a.alloc(u8, data.len);
                var rc4: Rc4 = .init(key.bytes[0..key.len]);
                rc4.xor(out, data);
                return out;
            },
            .aesv2, .aesv3 => {
                if (data.len == 0) return data;
                if (data.len < 16 or (data.len - 16) % 16 != 0) return error.Malformed;
                if (data.len == 16) return data[0..0];
                const out = try a.alloc(u8, data.len - 16);
                const iv = data[0..16].*;
                if (method == .aesv2) {
                    const key = self.objectKey(num, gen, true);
                    if (key.len != 16) return error.Malformed;
                    cbcDecrypt(aes.Aes128, key.bytes[0..16].*, iv, out, data[16..]);
                } else {
                    if (self.key_len != 32) return error.Malformed;
                    cbcDecrypt(aes.Aes256, self.key, iv, out, data[16..]);
                }
                const pad = out[out.len - 1];
                if (pad < 1 or pad > 16) return error.Malformed;
                return out[0 .. out.len - pad];
            },
        }
    }

    /// The key for one object (Algorithm 1): the file key, the object number's low 3 bytes and the
    /// generation's 2, and "sAlT" for AES, through MD5, cut to the file key's length plus 5 (at
    /// most 16). AES-256 uses the file key itself.
    fn objectKey(self: *const Handler, num: u32, gen: u16, salt: bool) struct { bytes: [32]u8, len: usize } {
        var out: [32]u8 = @splat(0);
        if (self.key_len == 32) {
            out = self.key;
            return .{ .bytes = out, .len = 32 };
        }
        var md5 = Md5.init(.{});
        md5.update(self.key[0..self.key_len]);
        md5.update(&.{ @truncate(num), @truncate(num >> 8), @truncate(num >> 16), @truncate(gen), @truncate(gen >> 8) });
        if (salt) md5.update("sAlT");
        md5.final(out[0..16]);
        return .{ .bytes = out, .len = @min(self.key_len + 5, 16) };
    }
};

/// The 32 bytes a password shorter than 32 is padded with (7.6.4.3.2).
const padding = [32]u8{
    0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
    0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
};

/// The password padded or cut to 32 bytes.
fn padded(password: []const u8) [32]u8 {
    var out = padding;
    const n = @min(password.len, 32);
    @memcpy(out[0..n], password[0..n]);
    if (n < 32) @memcpy(out[n..], padding[0 .. 32 - n]);
    return out;
}

/// The file key for a user password, R2 to R4 (Algorithm 2), when the password matches /U
/// (Algorithms 4 and 5); null when it does not.
fn userKey(r: u8, key_len: u8, password: []const u8, params: Params) ?[16]u8 {
    var md5 = Md5.init(.{});
    md5.update(&padded(password));
    md5.update(params.o[0..32]);
    const p: u32 = @truncate(@as(u64, @bitCast(params.p)));
    md5.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, p)));
    md5.update(params.id);
    if (r >= 4 and !params.encrypt_metadata) md5.update(&.{ 0xFF, 0xFF, 0xFF, 0xFF });
    var key: [16]u8 = undefined;
    md5.final(&key);
    if (r >= 3) for (0..50) |_| Md5.hash(key[0..key_len], &key, .{});
    @memset(key[key_len..], 0);

    if (r == 2) {
        var check: [32]u8 = undefined;
        var rc4: Rc4 = .init(key[0..key_len]);
        rc4.xor(&check, &padding);
        return if (std.mem.eql(u8, &check, params.u[0..32])) key else null;
    }
    var check: [16]u8 = undefined;
    md5 = Md5.init(.{});
    md5.update(&padding);
    md5.update(params.id);
    md5.final(&check);
    for (0..20) |i| {
        var round_key: [16]u8 = undefined;
        for (round_key[0..key_len], key[0..key_len]) |*k, b| k.* = b ^ @as(u8, @intCast(i));
        var rc4: Rc4 = .init(round_key[0..key_len]);
        rc4.xor(&check, &check);
    }
    return if (std.mem.eql(u8, &check, params.u[0..16])) key else null;
}

/// The padded user password /O holds, decrypted with an owner password (Algorithms 3 and 7). The
/// 50 extra rounds of R3 and R4 hash the key's first key_len bytes, as in Algorithm 2 and MuPDF
/// (Algorithm 3 does not say; the two agree for 128-bit keys).
fn userPasswordFromOwner(r: u8, key_len: u8, owner: []const u8, o: *const [32]u8) [32]u8 {
    var key: [16]u8 = undefined;
    Md5.hash(&padded(owner), &key, .{});
    if (r >= 3) for (0..50) |_| Md5.hash(key[0..key_len], &key, .{});
    var out = o.*;
    if (r == 2) {
        var rc4: Rc4 = .init(key[0..key_len]);
        rc4.xor(&out, &out);
        return out;
    }
    var i: usize = 20;
    while (i > 0) {
        i -= 1;
        var round_key: [16]u8 = undefined;
        for (round_key[0..key_len], key[0..key_len]) |*k, b| k.* = b ^ @as(u8, @intCast(i));
        var rc4: Rc4 = .init(round_key[0..key_len]);
        rc4.xor(&out, &out);
    }
    return out;
}

/// The file key for R5 and R6 (Algorithm 2.A): the password checked as the user password, then as
/// the owner password, and /UE or /OE decrypted with the matching hash; null when neither matches.
fn aes256Key(r: u8, password: []const u8, params: Params) Error!?[32]u8 {
    const u = params.u[0..48];
    const o = params.o[0..48];
    const empty: []const u8 = &.{};
    // /U: hash (32), validation salt (8), key salt (8). /O the same, hashed with /U's 48 bytes.
    if (std.mem.eql(u8, &hash(r, password, u[32..40], empty), u[0..32])) {
        return unwrapKey(hash(r, password, u[40..48], empty), params.ue[0..32]);
    }
    if (password.len > 0 and std.mem.eql(u8, &hash(r, password, o[32..40], u), o[0..32])) {
        return unwrapKey(hash(r, password, o[40..48], u), params.oe[0..32]);
    }
    return null;
}

/// /UE or /OE decrypted with `key`: AES-256, CBC with a zero IV, no padding.
fn unwrapKey(key: [32]u8, wrapped: *const [32]u8) [32]u8 {
    var out: [32]u8 = undefined;
    cbcDecrypt(aes.Aes256, key, @splat(0), &out, wrapped);
    return out;
}

/// The password hash: SHA-256 for R5; Algorithm 2.B for R6.
fn hash(r: u8, password: []const u8, salt: []const u8, udata: []const u8) [32]u8 {
    var k: [64]u8 = undefined;
    var sha = Sha256.init(.{});
    sha.update(password);
    sha.update(salt);
    sha.update(udata);
    sha.final(k[0..32]);
    if (r == 5) return k[0..32].*;
    var k_len: usize = 32;
    // K1 is the password, K and the user data, 64 times; E is K1 encrypted with AES-128-CBC
    // (key K[0..16], IV K[16..32]). The sum of E's first 16 bytes modulo 3 picks the next hash.
    // At least 64 rounds; then until E's last byte is at most the round number less 32.
    var buf: [64 * (127 + 64 + 48)]u8 = undefined;
    var round: usize = 0;
    while (true) : (round += 1) {
        const unit = password.len + k_len + udata.len;
        const k1_len = unit * 64;
        var at: usize = 0;
        for (0..64) |_| {
            @memcpy(buf[at..][0..password.len], password);
            @memcpy(buf[at + password.len ..][0..k_len], k[0..k_len]);
            @memcpy(buf[at + password.len + k_len ..][0..udata.len], udata);
            at += unit;
        }
        const e = buf[0..k1_len];
        cbcEncrypt(k[0..16].*, k[16..32].*, e);
        var sum: u32 = 0;
        for (e[0..16]) |b| sum += b;
        switch (sum % 3) {
            0 => {
                Sha256.hash(e, k[0..32], .{});
                k_len = 32;
            },
            1 => {
                Sha384.hash(e, k[0..48], .{});
                k_len = 48;
            },
            else => {
                Sha512.hash(e, k[0..64], .{});
                k_len = 64;
            },
        }
        if (round >= 63 and e[e.len - 1] <= round + 1 - 32) break;
    }
    return k[0..32].*;
}

/// Blocks per call into std's software AES: what it works on at once on 64-bit CPUs (8 or 16
/// blocks, bitsliced), so a batch costs what one block would.
const soft_batch = 16;

/// AES-CBC decryption of whole blocks into `out` (not `in`): each plain block is its block
/// decrypted, XORed with the block before it, the IV first. Without AES instructions, std's AES is
/// software that works on soft_batch blocks at once whatever it is given, and leaves the lanes it
/// was not given uninitialised, which valgrind then reports in the result. So there the blocks go
/// soft_batch at a time, the last batch padded with zero blocks; with AES instructions, one by one.
fn cbcDecrypt(comptime Aes: type, key: [Aes.key_bits / 8]u8, iv: [16]u8, out: []u8, in: []const u8) void {
    std.debug.assert(in.len % 16 == 0 and out.len == in.len);
    const ctx = Aes.initDec(key);
    const step: usize = if (aes.has_hardware_support) 16 else soft_batch * 16;
    var at: usize = 0;
    while (at < in.len) {
        const n = @min(step, in.len - at);
        var plain: [soft_batch * 16]u8 = undefined;
        if (aes.has_hardware_support) {
            ctx.decrypt(plain[0..16], in[at..][0..16]);
        } else {
            var cipher: [soft_batch * 16]u8 = @splat(0);
            @memcpy(cipher[0..n], in[at..][0..n]);
            ctx.decryptWide(soft_batch, &plain, &cipher);
        }
        for (out[at..][0..n], plain[0..n], at..) |*o, p, k| o.* = p ^ (if (k < 16) iv[k] else in[k - 16]);
        at += n;
    }
}

/// AES-128-CBC encryption in place, no padding: `data` is whole blocks. CBC encryption is a chain,
/// one block at a time; without AES instructions each goes to std's software AES as the first of a
/// batch of zero blocks, for the reason cbcDecrypt gives, which costs what one block does.
fn cbcEncrypt(key: [16]u8, iv: [16]u8, data: []u8) void {
    const ctx = aes.Aes128.initEnc(key);
    var prev = iv;
    var plain: [soft_batch * 16]u8 = @splat(0);
    var sealed: [soft_batch * 16]u8 = undefined;
    var i: usize = 0;
    while (i < data.len) : (i += 16) {
        const block = data[i..][0..16];
        for (plain[0..16], block, prev) |*o, b, p| o.* = b ^ p;
        if (aes.has_hardware_support) {
            ctx.encrypt(block, plain[0..16]);
        } else {
            ctx.encryptWide(soft_batch, &sealed, &plain);
            block.* = sealed[0..16].*;
        }
        prev = block.*;
    }
}

/// RC4 (7.6.3.2), which std does not have.
const Rc4 = struct {
    s: [256]u8,
    i: u8 = 0,
    j: u8 = 0,

    fn init(key: []const u8) Rc4 {
        var self: Rc4 = .{ .s = undefined };
        for (&self.s, 0..) |*b, n| b.* = @intCast(n);
        var j: u8 = 0;
        for (0..256) |n| {
            j +%= self.s[n] +% key[n % key.len];
            std.mem.swap(u8, &self.s[n], &self.s[j]);
        }
        return self;
    }

    /// `out` is `in` XORed with the key stream; they may be the same slice.
    fn xor(self: *Rc4, out: []u8, in: []const u8) void {
        for (out, in) |*o, b| {
            self.i +%= 1;
            self.j +%= self.s[self.i];
            std.mem.swap(u8, &self.s[self.i], &self.s[self.j]);
            o.* = b ^ self.s[self.s[self.i] +% self.s[self.j]];
        }
    }
};

/// `utf8` in PDFDocEncoding, cut to 32 bytes, into `out`; returns the length. A character
/// PDFDocEncoding lacks becomes '?', as in MuPDF; invalid UTF-8 is taken byte by byte.
fn toPdfDoc(utf8: []const u8, out: *[32]u8) usize {
    const pdf_doc = @import("read_text.zig").pdfDocEncoding;
    const view = std.unicode.Utf8View.init(utf8) catch {
        const n = @min(utf8.len, 32);
        @memcpy(out[0..n], utf8[0..n]);
        return n;
    };
    var it = view.iterator();
    var n: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (n == 32) break;
        out[n] = for (0..256) |b| {
            if (pdf_doc(@intCast(b)) == cp) break @intCast(b);
        } else '?';
        n += 1;
    }
    return n;
}

// ---- tests ----

const testing = std.testing;

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "RC4 gives the published test vectors" {
    // The three common vectors, checked with Node's crypto (createCipheriv("rc4")), which shares no
    // code with this.
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "Key", "Plaintext", &hex("bbf316e8d940af0ad3") },
        .{ "Wiki", "pedia", &hex("1021bf0420") },
        .{ "Secret", "Attack at dawn", &hex("45a01f645fc35b383552544b9bf5") },
    };
    for (cases) |c| {
        var out: [32]u8 = undefined;
        var rc4: Rc4 = .init(c[0]);
        rc4.xor(out[0..c[1].len], c[1]);
        try testing.expectEqualSlices(u8, c[2], out[0..c[1].len]);
    }
}

test "AES-CBC decrypts and encrypts NIST SP 800-38A F.2" {
    // F.2.1 to F.2.6, the first two blocks, checked with LibreSSL's openssl enc.
    const iv = hex("000102030405060708090a0b0c0d0e0f");
    const plain = hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51");
    const k128 = hex("2b7e151628aed2a6abf7158809cf4f3c");
    const c128 = hex("7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b2");
    const k256 = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4");
    const c256 = hex("f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d");
    var out: [32]u8 = undefined;
    cbcDecrypt(aes.Aes128, k128, iv, &out, &c128);
    try testing.expectEqualSlices(u8, &plain, &out);
    cbcDecrypt(aes.Aes256, k256, iv, &out, &c256);
    try testing.expectEqualSlices(u8, &plain, &out);
    out = plain;
    cbcEncrypt(k128, iv, &out);
    try testing.expectEqualSlices(u8, &c128, &out);
    // 40 blocks, past cbcDecrypt's batches: encrypted, then decrypted back.
    var long: [40 * 16]u8 = undefined;
    for (&long, 0..) |*b, i| b.* = @truncate(i * 7);
    var sealed = long;
    cbcEncrypt(k128, iv, &sealed);
    var opened: [40 * 16]u8 = undefined;
    cbcDecrypt(aes.Aes128, k128, iv, &opened, &sealed);
    try testing.expectEqualSlices(u8, &long, &opened);
}

test "AES data is the IV and whole blocks, with padding of 1 to 16 bytes, or Malformed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = &arena;
    const h: Handler = .{ .revision = 4, .key = @splat(7), .key_len = 16, .string_method = .aesv2, .stream_method = .aesv2, .std_cf_method = .aesv2, .encrypt_metadata = true };
    const key = h.objectKey(12, 0, true).bytes[0..16].*;
    const iv: [16]u8 = @splat(3);
    var buf: [48]u8 = @splat(0);
    @memcpy(buf[0..16], &iv);
    // "hello" and 11 bytes of padding, encrypted as a writer would for object 12.
    var block = "hello".* ++ @as([11]u8, @splat(11));
    cbcEncrypt(key, iv, &block);
    @memcpy(buf[16..32], &block);
    try testing.expectEqualStrings("hello", try h.decrypt(a, .aesv2, 12, 0, buf[0..32]));
    // Object 13's key does not give it back: padding out of range, or other bytes.
    if (h.decrypt(a, .aesv2, 13, 0, buf[0..32])) |other| {
        try testing.expect(!std.mem.eql(u8, other, "hello"));
    } else |err| try testing.expectEqual(error.Malformed, err);
    // Empty, and the IV alone, are empty; a part block or a short IV is Malformed.
    try testing.expectEqual(@as(usize, 0), (try h.decrypt(a, .aesv2, 12, 0, "")).len);
    try testing.expectEqual(@as(usize, 0), (try h.decrypt(a, .aesv2, 12, 0, buf[0..16])).len);
    try testing.expectError(error.Malformed, h.decrypt(a, .aesv2, 12, 0, buf[0..15]));
    try testing.expectError(error.Malformed, h.decrypt(a, .aesv2, 12, 0, buf[0..33]));
    // Padding of 0 or over 16 is Malformed, for a string too: it is ciphertext under the wrong key,
    // or damaged.
    for ([_]u8{ 0, 17 }) |pad| {
        var bad = "0123456789abcde".* ++ [1]u8{pad};
        cbcEncrypt(key, iv, &bad);
        @memcpy(buf[16..32], &bad);
        try testing.expectError(error.Malformed, h.decrypt(a, .aesv2, 12, 0, buf[0..32]));
        try testing.expectError(error.Malformed, h.decryptString(a, 12, 0, buf[0..32]));
    }
    // A string AES cannot have made is taken as written; a stream is not.
    try testing.expectEqualStrings("DefaultOC", try h.decryptString(a, 12, 0, "DefaultOC"));
    try testing.expectEqualSlices(u8, buf[0..16], try h.decryptString(a, 12, 0, buf[0..16]));
    try testing.expectEqualSlices(u8, buf[0..33], try h.decryptString(a, 12, 0, buf[0..33]));
    try testing.expectError(error.Malformed, h.decrypt(a, .aesv2, 12, 0, "DefaultOC"));
}

test "a password is PDFDocEncoding for R2 to R4: a character it lacks is '?'" {
    var out: [32]u8 = undefined;
    // é is 0xE9 (Latin-1), € 0xA0, • 0x80; 日 is not in it.
    const n = toPdfDoc("caf\u{E9}\u{20AC}\u{2022}\u{65E5}", &out);
    try testing.expectEqualSlices(u8, "caf\xE9\xA0\x80?", out[0..n]);
    // Cut to 32 bytes, as the padding step would.
    const long: [40]u8 = @splat('a');
    try testing.expectEqual(@as(usize, 32), toPdfDoc(&long, &out));
}
