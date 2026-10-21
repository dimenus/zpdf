const std = @import("std");
const valgrind_marks = @import("valgrind_marks");

/// Counts the bytes an allocator has handed out and not taken back, so a test can
/// see that closing everything returns to where it started. Counts the requested
/// length; a resize or remap that succeeds moves the count by the difference.
///
/// Also marks what it hands out (a new block, the grown end of a resized one) undefined for
/// valgrind. On Linux libzpdf links no libc, so valgrind cannot replace its malloc and sees
/// smp_allocator's memory as mapped, defined pages: without these marks an uninitialised read in
/// libzpdf or kb goes unreported. Every libzpdf context allocation passes through here
/// (src/abi.zig), and tools/valgrind-canary.zig checks that valgrind still sees a read of one.
/// A mark is a client request (src/valgrind_marks.zig): a few instructions that do nothing outside
/// valgrind, and nothing at all where valgrind does not run (wasm, macOS, Windows).
pub const Counting = struct {
    child: std.mem.Allocator,
    live: usize = 0,
    /// The most `live` has been since it was last set; a test sets it to `live` to measure one
    /// step's own peak.
    peak: usize = 0,

    fn grew(self: *Counting) void {
        self.peak = @max(self.peak, self.live);
    }

    pub fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        valgrind_marks.makeUndefined(p[0..len]);
        self.live += len;
        self.grew();
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len > memory.len) valgrind_marks.makeUndefined(memory.ptr[memory.len..new_len]);
        self.live = self.live - memory.len + new_len;
        self.grew();
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len > memory.len) valgrind_marks.makeUndefined(p[memory.len..new_len]);
        self.live = self.live - memory.len + new_len;
        self.grew();
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.live -= memory.len;
    }
};
