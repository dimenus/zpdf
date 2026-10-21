//! The valgrind marks zpdf makes itself: tell memcheck that memory holds no defined value, so a read
//! of it before a write is reported. src/counting.zig marks each block a libzpdf context allocates,
//! and src/block_cache.zig each block it hands out again. On Linux libzpdf links no libc, so
//! valgrind cannot replace its malloc and would see its heap as defined, mapped pages.
//!
//! Why not std.valgrind: it does nothing unless valgrind support is on in the root module (std reads
//! its own `builtin`, which follows the root), and on for all of libzpdf it also marks every
//! `undefined` value, which made writing measurably slower. So this file makes the client request
//! itself, with the instruction sequence std.valgrind.doClientRequest uses, on Linux x86_64 and
//! aarch64. Outside valgrind those instructions change nothing; elsewhere it compiles to nothing.
//!
//! A module of its own ("valgrind_marks", build.zig addValgrindMarks) because the valgrind canary
//! imports counting.zig and block_cache.zig as two modules, and a file belongs to one module.
const std = @import("std");
const builtin = @import("builtin");

const make_mem_undefined: usize = @backingInt(std.valgrind.memcheck.ClientRequest.MakeMemUndefined);

/// Tells valgrind `mem` holds no defined value.
pub fn makeUndefined(mem: []const u8) void {
    if (builtin.os.tag != .linux) return;
    const args = [_]usize{ make_mem_undefined, @intFromPtr(mem.ptr), mem.len, 0, 0, 0 };
    switch (builtin.cpu.arch) {
        .x86_64 => _ = asm volatile (
            \\ rolq  $3,    %%rdi ; rolq $13, %%rdi
            \\ rolq  $61,   %%rdi ; rolq $51, %%rdi
            \\ xchgq %%rbx, %%rbx
            : [_] "={rdx}" (-> usize),
            : [_] "{rax}" (&args),
              [_] "{rdx}" (@as(usize, 0)),
            : .{ .memory = true }),
        .aarch64 => _ = asm volatile (
            \\ ror x12, x12, #3  ; ror x12, x12, #13
            \\ ror x12, x12, #51 ; ror x12, x12, #61
            \\ orr x10, x10, x10
            : [_] "={x3}" (-> usize),
            : [_] "{x4}" (&args),
              [_] "{x3}" (@as(usize, 0)),
            : .{ .memory = true }),
        else => {},
    }
}
