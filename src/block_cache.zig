//! A bounded free list of large blocks, over another allocator.
//!
//! Why: std.heap.smp_allocator maps every block of 64 KiB or more directly and unmaps it when it
//! is freed (SmpAllocator.zig, through PageAllocator.map and unmap). A caller that frees and
//! allocates large blocks again and again pays two system calls and fresh page faults each time,
//! where glibc's malloc keeps freed memory for reuse. libzpdf's contexts allocate through this
//! cache, so libzpdf can run on smp_allocator, with no libc, without paying that. std has no
//! general one: BrkAllocator keeps the same size-class free lists but owns the brk system call
//! (wasm, single-threaded), and MemoryPool holds objects of one type and one size.
//!
//! How to use it:
//!   var cache: BlockCache = .init(child, max_cached_bytes);
//!   defer cache.deinit();          // gives every cached block back to child
//!   const a = cache.allocator();   // one thread at a time, as a zpdf context is used
//!
//! What it does. A request of 64 KiB to 32 MiB, aligned to at most a page, is rounded up to a power
//! of two (its class) and served from that class's free list, else from child. Freed, the block
//! goes on its class's list while the cached total stays within max_cached_bytes, else back to
//! child. Smaller, larger and more aligned requests pass straight through. A block resizes in place
//! within its class; across classes resize fails and remap returns null, so the caller allocates
//! and copies, as with any allocator that cannot grow in place.
//!
//! A reused block is marked undefined for valgrind (src/valgrind_marks.zig), so reading it before
//! writing it is reported as for a new block. tools/valgrind-canary.zig checks that this still fires.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const valgrind_marks = @import("valgrind_marks");

pub const BlockCache = struct {
    child: Allocator,
    max_cached_bytes: usize,
    cached_bytes: usize = 0,
    /// Freed blocks by class, each holding the next one's address in its first word.
    lists: [class_count]?*FreeBlock = @splat(null),

    const min_class = 16;
    const max_class = 25;
    const class_count = max_class - min_class + 1;
    /// Every cached block is allocated with this alignment, so any request it serves is aligned.
    const block_alignment: Alignment = .fromByteUnits(std.heap.page_size_min);

    const FreeBlock = struct { next: ?*FreeBlock };

    pub fn init(child: Allocator, max_cached_bytes: usize) BlockCache {
        return .{ .child = child, .max_cached_bytes = max_cached_bytes };
    }

    pub fn deinit(self: *BlockCache) void {
        for (&self.lists, 0..) |*list, class| {
            while (list.*) |block| {
                list.* = block.next;
                self.child.rawFree(@as([*]u8, @ptrCast(block))[0..classSize(class)], block_alignment, @returnAddress());
            }
        }
        self.cached_bytes = 0;
    }

    pub fn allocator(self: *BlockCache) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// The class of a block of `len`, or null when it passes through to child.
    fn classOf(len: usize, alignment: Alignment) ?usize {
        if (len < 1 << min_class or len > 1 << max_class) return null;
        if (alignment.compare(.gt, block_alignment)) return null;
        return std.math.log2_int_ceil(usize, len) - min_class;
    }

    fn classSize(class: usize) usize {
        return @as(usize, 1) << @intCast(class + min_class);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *BlockCache = @ptrCast(@alignCast(ctx));
        const class = classOf(len, alignment) orelse return self.child.rawAlloc(len, alignment, ra);
        if (self.lists[class]) |block| {
            self.lists[class] = block.next;
            self.cached_bytes -= classSize(class);
            const bytes: [*]u8 = @ptrCast(block);
            valgrind_marks.makeUndefined(bytes[0..classSize(class)]);
            return bytes;
        }
        return self.child.rawAlloc(classSize(class), block_alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
        const self: *BlockCache = @ptrCast(@alignCast(ctx));
        const old = classOf(memory.len, alignment);
        const new = classOf(new_len, alignment);
        if (old == null and new == null) return self.child.rawResize(memory, alignment, new_len, ra);
        return old != null and old == new;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *BlockCache = @ptrCast(@alignCast(ctx));
        const old = classOf(memory.len, alignment);
        const new = classOf(new_len, alignment);
        if (old == null and new == null) return self.child.rawRemap(memory, alignment, new_len, ra);
        if (old != null and old == new) return memory.ptr;
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const self: *BlockCache = @ptrCast(@alignCast(ctx));
        const class = classOf(memory.len, alignment) orelse return self.child.rawFree(memory, alignment, ra);
        const size = classSize(class);
        if (self.cached_bytes + size > self.max_cached_bytes) {
            return self.child.rawFree(memory.ptr[0..size], block_alignment, ra);
        }
        const block: *FreeBlock = @ptrCast(@alignCast(memory.ptr));
        block.* = .{ .next = self.lists[class] };
        self.lists[class] = block;
        self.cached_bytes += size;
    }
};

// ---- tests ----

const testing = std.testing;

/// Counts what reaches the child, to see what the cache keeps from it.
const ChildCount = struct {
    child: Allocator,
    allocs: usize = 0,
    frees: usize = 0,

    fn allocator(self: *ChildCount) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = cAlloc, .resize = cResize, .remap = cRemap, .free = cFree } };
    }
    fn cAlloc(ctx: *anyopaque, len: usize, a: Alignment, ra: usize) ?[*]u8 {
        const self: *ChildCount = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        return self.child.rawAlloc(len, a, ra);
    }
    fn cResize(ctx: *anyopaque, m: []u8, a: Alignment, n: usize, ra: usize) bool {
        const self: *ChildCount = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(m, a, n, ra);
    }
    fn cRemap(ctx: *anyopaque, m: []u8, a: Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *ChildCount = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(m, a, n, ra);
    }
    fn cFree(ctx: *anyopaque, m: []u8, a: Alignment, ra: usize) void {
        const self: *ChildCount = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.child.rawFree(m, a, ra);
    }
};

test "a freed large block is reused for its class, small ones pass through" {
    var count: ChildCount = .{ .child = testing.allocator };
    var cache: BlockCache = .init(count.allocator(), 1 << 20);
    defer cache.deinit();
    const a = cache.allocator();
    const first = try a.alloc(u8, 70_000);
    a.free(first);
    try testing.expectEqual(@as(usize, 1), count.allocs);
    try testing.expectEqual(@as(usize, 0), count.frees);
    try testing.expectEqual(@as(usize, 128 * 1024), cache.cached_bytes);
    // 100 000 rounds up to the same 128 KiB class as 70 000, so it gets the same block.
    const second = try a.alloc(u8, 100_000);
    try testing.expectEqual(first.ptr, second.ptr);
    try testing.expectEqual(@as(usize, 1), count.allocs);
    // The total follows what is on the lists, or it drifts up and the cache stops caching.
    try testing.expectEqual(@as(usize, 0), cache.cached_bytes);
    a.free(second);
    try testing.expectEqual(@as(usize, 128 * 1024), cache.cached_bytes);
    // 64 KiB is its own class: a new block.
    const other = try a.alloc(u8, 64 * 1024);
    try testing.expectEqual(@as(usize, 2), count.allocs);
    a.free(other);
    // Below 64 KiB nothing is kept: each goes to the child and back.
    const small = try a.alloc(u8, 1000);
    a.free(small);
    try testing.expectEqual(@as(usize, 3), count.allocs);
    try testing.expectEqual(@as(usize, 1), count.frees);
}

test "the cache keeps at most max_cached_bytes and gives the rest back" {
    var count: ChildCount = .{ .child = testing.allocator };
    // Room for two 128 KiB blocks.
    var cache: BlockCache = .init(count.allocator(), 256 * 1024);
    defer cache.deinit();
    const a = cache.allocator();
    var blocks: [4][]u8 = undefined;
    for (&blocks) |*b| b.* = try a.alloc(u8, 70_000);
    for (blocks) |b| a.free(b);
    try testing.expectEqual(@as(usize, 256 * 1024), cache.cached_bytes);
    try testing.expectEqual(@as(usize, 2), count.frees);
    // deinit gives the cached two back (the test allocator fails the test on a leak).
}

test "a block resizes in place within its class, and only there" {
    var cache: BlockCache = .init(testing.allocator, 1 << 20);
    defer cache.deinit();
    const a = cache.allocator();
    var b = try a.alloc(u8, 70_000);
    // 70 000 and 120 000 are both 128 KiB blocks.
    try testing.expect(a.resize(b, 120_000));
    b.len = 120_000;
    b = a.remap(b, 66_000) orelse return error.TestUnexpectedResult;
    // 200 000 is the 256 KiB class, 1000 passes through: neither can be this block.
    try testing.expect(!a.resize(b, 200_000));
    try testing.expect(!a.resize(b, 1000));
    try testing.expectEqual(@as(?[]u8, null), a.remap(b, 200_000));
    a.free(b);
    // A small block grows into a large one by moving, never in place.
    const s = try a.alloc(u8, 1000);
    try testing.expect(!a.resize(s, 70_000));
    a.free(s);
}

test "an over-aligned request passes through and is never cached" {
    var count: ChildCount = .{ .child = testing.allocator };
    var cache: BlockCache = .init(count.allocator(), 1 << 20);
    defer cache.deinit();
    const a = cache.allocator();
    const align_big: Alignment = .fromByteUnits(std.heap.page_size_min * 2);
    const p = a.rawAlloc(70_000, align_big, @returnAddress()).?;
    a.rawFree(p[0..70_000], align_big, @returnAddress());
    try testing.expectEqual(@as(usize, 1), count.frees);
    try testing.expectEqual(@as(usize, 0), cache.cached_bytes);
}
