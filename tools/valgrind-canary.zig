//! The canary run under valgrind before what it vouches for, and built the same way: before the test
//! binary by tools/test-valgrind.sh (target, optimize mode, LLVM), and before libzpdf by
//! tools/valgrind-abi-bundle.sh (libzpdf's module options, build.zig nativeModule). It reads
//! uninitialised memory four times on purpose: on the heap, through the allocator
//! std.testing.allocator is (a DebugAllocator over page_allocator); on the stack; in a large block
//! that libzpdf's block cache (src/block_cache.zig) hands out a second time, still holding what was
//! written into it before; and in a block a libzpdf context allocates (src/counting.zig over
//! smp_allocator, never written by an allocator that marks it). tools/test-valgrind.sh fails unless
//! valgrind reports all four, in canaryHeapRead, canaryStackRead, canaryReusedBlockRead and
//! canaryContextRead; the bundle requires the last two, the ones that go through zpdf's own marks
//! (libzpdf's build leaves Zig's marking of `undefined` values off). So a build in which valgrind
//! cannot see uninitialised memory fails instead of reporting a clean run. Two such builds existed:
//! Zig's self-hosted x86_64 backend emits no valgrind marking for undefined memory, and valgrind saw
//! no uninitialised heap read in its binary (build.zig, test-artifacts); and libzpdf with no libc,
//! before src/counting.zig marked its blocks.
//!
//! It prints which branch each read took and exits 0; the branch taken means nothing.
const std = @import("std");
const BlockCache = @import("block_cache").BlockCache;
const Counting = @import("counting").Counting;

pub fn main() !void {
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    try canaryHeapRead(dbg.allocator());
    canaryStackRead();
    try canaryReusedBlockRead();
    try canaryContextRead();
}

noinline fn canaryContextRead() !void {
    var counting: Counting = .{ .child = std.heap.smp_allocator };
    const a = counting.allocator();
    // rawAlloc, for the reason canaryReusedBlockRead gives: the mark must be Counting's own.
    const len = 4096;
    const p = a.rawAlloc(len, .@"16", @returnAddress()) orelse return error.OutOfMemory;
    defer a.rawFree(p[0..len], .@"16", @returnAddress());
    const v: *volatile u8 = &p[5];
    if (v.* > 3) std.debug.print("context: big\n", .{}) else std.debug.print("context: small\n", .{});
}

noinline fn canaryHeapRead(gpa: std.mem.Allocator) !void {
    const xs = try gpa.alloc(u32, 64);
    defer gpa.free(xs);
    // Never written. volatile, so the read is not optimised away.
    const v: *volatile u32 = &xs[5];
    // A branch statement, as the probes that showed the reports had: a select can become a
    // conditional move, which valgrind reports differently.
    if (v.* > 3) std.debug.print("heap: big\n", .{}) else std.debug.print("heap: small\n", .{});
}

noinline fn canaryStackRead() void {
    var x: u32 = undefined;
    const v: *volatile u32 = &x;
    if (v.* > 3) std.debug.print("stack: big\n", .{}) else std.debug.print("stack: small\n", .{});
}

noinline fn canaryReusedBlockRead() !void {
    var cache: BlockCache = .init(std.heap.page_allocator, 1 << 20);
    defer cache.deinit();
    const a = cache.allocator();
    // rawAlloc and rawFree, not alloc and free: Allocator.alloc marks new memory undefined itself,
    // and this must be the cache's own marking of a reused block.
    const len = 70_000;
    const first = a.rawAlloc(len, .@"16", @returnAddress()) orelse return error.OutOfMemory;
    @memset(first[0..len], 7);
    a.rawFree(first[0..len], .@"16", @returnAddress());
    const again = a.rawAlloc(len, .@"16", @returnAddress()) orelse return error.OutOfMemory;
    defer a.rawFree(again[0..len], .@"16", @returnAddress());
    if (again != first) return error.NotReused;
    const v: *volatile u8 = &again[5];
    if (v.* > 3) std.debug.print("reused: big\n", .{}) else std.debug.print("reused: small\n", .{});
}
