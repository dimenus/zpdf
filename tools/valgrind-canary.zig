//! The canary tools/test-valgrind.sh runs under valgrind before the test binary, built the same way
//! (target, optimize mode, LLVM). It reads uninitialised memory twice on purpose: on the heap, through
//! the allocator std.testing.allocator is (a DebugAllocator over page_allocator), and on the stack.
//! The script fails unless valgrind reports both reads, in canaryHeapRead and canaryStackRead, so a
//! build in which valgrind cannot see uninitialised memory fails instead of reporting a clean run.
//! That build existed: Zig's self-hosted x86_64 backend emits no valgrind marking for undefined
//! memory, and valgrind saw no uninitialised heap read in its binary (build.zig, test-artifacts).
//!
//! It prints which branch each read took and exits 0; the branch taken means nothing.
const std = @import("std");

pub fn main() !void {
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    try canaryHeapRead(dbg.allocator());
    canaryStackRead();
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
