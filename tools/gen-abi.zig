//! Writes zpdf.h and the C# declarations (Zpdf.Abi.g.cs) for zpdf's C ABI.
//!
//!     gen-abi <src/abi.zig> <out zpdf.h> <out Zpdf.Abi.g.cs>
//!
//! The types come from the compiled module (zpdf.abi): each export's signature, each wire
//! record's fields, the error codes, the RunFlag bits. The compiled types do not carry parameter names or doc
//! comments, so those come from parsing src/abi.zig; a parameter count that differs between the
//! two stops the tool. A Zig type with no C or C# mapping below is a compile error here, so a new
//! export cannot reach the header with a guessed type.

const std = @import("std");
const zpdf = @import("zpdf");
const abi = zpdf.abi;
const Ast = std.zig.Ast;

const Allocator = std.mem.Allocator;

/// The doc comment of a declaration in src/abi.zig, one string per line, without the slashes.
const Doc = []const []const u8;

const Source = struct {
    module_doc: Doc,
    /// Function name to its parameter names and doc comment.
    fns: std.StringHashMapUnmanaged(struct { params: []const []const u8, doc: Doc }) = .empty,
    /// "Record.field" or "Record" to a doc comment.
    docs: std.StringHashMapUnmanaged(Doc) = .empty,
};

fn docBefore(arena: Allocator, tree: *const Ast, first: Ast.TokenIndex, tag: std.zig.Token.Tag) !Doc {
    var start = first;
    while (start > 0 and tree.tokenTag(start - 1) == tag) start -= 1;
    var lines: std.ArrayList([]const u8) = .empty;
    for (start..first) |t| {
        const text = tree.tokenSlice(@intCast(t));
        const body = std.mem.trimEnd(u8, text[3..], " \r");
        try lines.append(arena, if (body.len > 0 and body[0] == ' ') body[1..] else body);
    }
    return lines.items;
}

fn readSource(arena: Allocator, source: [:0]const u8) !Source {
    var tree = try Ast.parse(arena, source, .{ .mode = .zig });
    if (tree.errors.len != 0) return error.ParseError;
    var module_doc: std.ArrayList([]const u8) = .empty;
    var t: Ast.TokenIndex = 0;
    while (tree.tokenTag(t) == .container_doc_comment) : (t += 1) {
        const body = std.mem.trimEnd(u8, tree.tokenSlice(t)[3..], " \r");
        try module_doc.append(arena, if (body.len > 0 and body[0] == ' ') body[1..] else body);
    }
    var out: Source = .{ .module_doc = module_doc.items };
    for (tree.rootDecls()) |decl| {
        const var_decl = tree.fullVarDecl(decl) orelse continue;
        const name = tree.tokenSlice(var_decl.ast.mut_token + 1);
        const init = var_decl.ast.init_node.unwrap() orelse continue;
        var buf: [2]Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&buf, init) orelse continue;
        try out.docs.put(arena, name, try docBefore(arena, &tree, var_decl.firstToken(), .doc_comment));
        for (container.ast.members) |member| {
            if (tree.fullContainerField(member)) |field| {
                const key = try std.fmt.allocPrint(arena, "{s}.{s}", .{ name, tree.tokenSlice(field.ast.main_token) });
                try out.docs.put(arena, key, try docBefore(arena, &tree, field.firstToken(), .doc_comment));
                continue;
            }
            if (!std.mem.eql(u8, name, "exports") or tree.nodeTag(member) != .fn_decl) continue;
            var proto_buf: [1]Ast.Node.Index = undefined;
            const proto = tree.fullFnProto(&proto_buf, member).?;
            var params: std.ArrayList([]const u8) = .empty;
            var it = proto.iterate(&tree);
            while (it.next()) |param| try params.append(arena, tree.tokenSlice(param.name_token.?));
            try out.fns.put(arena, tree.tokenSlice(proto.name_token.?), .{
                .params = params.items,
                .doc = try docBefore(arena, &tree, tree.firstToken(member), .doc_comment),
            });
        }
    }
    return out;
}

/// The wire records: abi's extern structs, in declaration order.
const records = blk: {
    var list: []const []const u8 = &.{};
    for (@typeInfo(abi).@"struct".decl_names) |decl_name| {
        const value = @field(abi, decl_name);
        if (@TypeOf(value) != type) continue;
        switch (@typeInfo(value)) {
            .@"struct" => |s| if (s.layout == .@"extern") {
                list = list ++ .{decl_name};
            },
            else => {},
        }
    }
    break :blk list;
};

fn recordName(comptime T: type) ?[]const u8 {
    inline for (records) |name| {
        if (@field(abi, name) == T) return name;
    }
    return null;
}

/// "PageInfo" -> "page_info", "InvalidUtf8" -> "invalid_utf8".
fn snake(arena: Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name, 0..) |c, i| {
        if (std.ascii.isUpper(c) and i != 0) try out.append(arena, '_');
        try out.append(arena, std.ascii.toLower(c));
    }
    return out.items;
}

/// "actual_text" -> "ActualText".
fn pascal(arena: Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var upper = true;
    for (name) |c| {
        if (c == '_') {
            upper = true;
            continue;
        }
        try out.append(arena, if (upper) std.ascii.toUpper(c) else c);
        upper = false;
    }
    return out.items;
}

fn cType(arena_state: *std.heap.ArenaAllocator, comptime T: type) ![]const u8 {
    const arena = arena_state.allocator();
    if (T == abi.Context) return "zpdf_context";
    if (comptime recordName(T)) |name| return std.fmt.allocPrint(arena, "zpdf_{s}", .{try snake(arena, name)});
    if (T == anyopaque) return "void";
    return switch (@typeInfo(T)) {
        .void => "void",
        .int => |i| switch (T) {
            usize => "size_t",
            else => std.fmt.allocPrint(arena, "{s}int{d}_t", .{ if (i.signedness == .unsigned) "u" else "", i.bits }),
        },
        .float => switch (T) {
            f32 => "float",
            f64 => "double",
            else => @compileError("no C type for " ++ @typeName(T)),
        },
        .optional => |o| cType(arena_state, o.child),
        .pointer => |p| blk: {
            if (p.size == .slice or p.size == .c) @compileError("no C type for " ++ @typeName(T));
            if (p.child == u8 and p.sentinel() != null) break :blk "const char *";
            const child = try cType(arena_state, p.child);
            break :blk std.fmt.allocPrint(arena, "{s}{s}{s}*", .{ if (p.attrs.@"const") "const " else "", child, if (child[child.len - 1] == '*') "" else " " });
        },
        else => @compileError("no C type for " ++ @typeName(T)),
    };
}

/// A function pointer field as a C declarator: `int32_t (*write)(void *, const uint8_t *, size_t)`.
/// The compiled type carries no parameter names, so none are written.
fn cFnPointerField(arena_state: *std.heap.ArenaAllocator, comptime F: type, name: []const u8) ![]const u8 {
    const arena = arena_state.allocator();
    const f = @typeInfo(F).@"fn";
    var params: std.ArrayList(u8) = .empty;
    inline for (f.param_types, 0..) |param_type, i| {
        if (i != 0) try params.appendSlice(arena, ", ");
        try params.appendSlice(arena, try cType(arena_state, param_type.?));
    }
    const ret = try cType(arena_state, f.return_type.?);
    return std.fmt.allocPrint(arena, "{s} (*{s})({s})", .{ ret, name, if (params.items.len == 0) "void" else params.items });
}

/// Whether a record has a pointer field, so its size depends on the target.
fn hasPointer(comptime T: type) bool {
    for (@typeInfo(T).@"struct".field_types) |F| {
        const P = switch (@typeInfo(F)) {
            .optional => |o| o.child,
            else => F,
        };
        if (@typeInfo(P) == .pointer) return true;
    }
    return false;
}

/// The function type a field points at, when it is a (possibly optional) function pointer.
fn fnPointee(comptime T: type) ?type {
    const P = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    return switch (@typeInfo(P)) {
        .pointer => |p| if (@typeInfo(p.child) == .@"fn") p.child else null,
        else => null,
    };
}

fn csType(arena_state: *std.heap.ArenaAllocator, comptime T: type) ![]const u8 {
    const arena = arena_state.allocator();
    if (T == abi.Context) return "ZpdfContext";
    if (T == anyopaque) return "void";
    if (comptime fnPointee(T)) |F| {
        // An unmanaged function pointer: C# calls it, and passes [UnmanagedCallersOnly] methods.
        const f = @typeInfo(F).@"fn";
        var args: std.ArrayList(u8) = .empty;
        inline for (f.param_types) |param_type| {
            try args.appendSlice(arena, try csType(arena_state, param_type.?));
            try args.appendSlice(arena, ", ");
        }
        try args.appendSlice(arena, try csType(arena_state, f.return_type.?));
        return std.fmt.allocPrint(arena, "delegate* unmanaged[Cdecl]<{s}>", .{args.items});
    }
    if (comptime recordName(T)) |name| return name;
    return switch (T) {
        void => "void",
        u8 => "byte",
        u32 => "uint",
        i32 => "int",
        usize => "nuint",
        f32 => "float",
        f64 => "double",
        else => switch (@typeInfo(T)) {
            .optional => |o| csType(arena_state, o.child),
            .pointer => |p| blk: {
                if (p.size == .slice or p.size == .c) @compileError("no C# type for " ++ @typeName(T));
                break :blk std.fmt.allocPrint(arena, "{s}*", .{try csType(arena_state, p.child)});
            },
            else => @compileError("no C# type for " ++ @typeName(T)),
        },
    };
}

/// C and C++ keywords: a name that is one cannot be in the header.
const c_keywords = std.StaticStringMap(void).initComptime(.{
    .{"auto"},     .{"bool"},      .{"break"},    .{"case"},     .{"char"},     .{"class"},
    .{"const"},    .{"continue"},  .{"default"},  .{"delete"},   .{"do"},       .{"double"},
    .{"else"},     .{"enum"},      .{"explicit"}, .{"extern"},   .{"false"},    .{"float"},
    .{"for"},      .{"friend"},    .{"goto"},     .{"if"},       .{"inline"},   .{"int"},
    .{"long"},     .{"namespace"}, .{"new"},      .{"operator"}, .{"private"},  .{"protected"},
    .{"public"},   .{"register"},  .{"restrict"}, .{"return"},   .{"short"},    .{"signed"},
    .{"sizeof"},   .{"static"},    .{"struct"},   .{"switch"},   .{"template"}, .{"this"},
    .{"throw"},    .{"true"},      .{"try"},      .{"typedef"},  .{"typename"}, .{"union"},
    .{"unsigned"}, .{"using"},     .{"virtual"},  .{"void"},     .{"volatile"}, .{"while"},
});

fn cName(name: []const u8) ![]const u8 {
    if (c_keywords.has(name)) {
        std.debug.print("gen-abi: \"{s}\" is a C or C++ keyword; rename it in src/abi.zig\n", .{name});
        return error.Keyword;
    }
    return name;
}

/// C# keywords. A name that is one is written as @name, which C# reads as a plain name.
const cs_keywords = std.StaticStringMap(void).initComptime(.{
    .{"abstract"},  .{"as"},       .{"base"},     .{"bool"},       .{"break"},     .{"byte"},
    .{"case"},      .{"catch"},    .{"char"},     .{"checked"},    .{"class"},     .{"const"},
    .{"continue"},  .{"decimal"},  .{"default"},  .{"delegate"},   .{"do"},        .{"double"},
    .{"else"},      .{"enum"},     .{"event"},    .{"explicit"},   .{"extern"},    .{"false"},
    .{"finally"},   .{"fixed"},    .{"float"},    .{"for"},        .{"foreach"},   .{"goto"},
    .{"if"},        .{"implicit"}, .{"in"},       .{"int"},        .{"interface"}, .{"internal"},
    .{"is"},        .{"lock"},     .{"long"},     .{"namespace"},  .{"new"},       .{"null"},
    .{"object"},    .{"operator"}, .{"out"},      .{"override"},   .{"params"},    .{"private"},
    .{"protected"}, .{"public"},   .{"readonly"}, .{"ref"},        .{"return"},    .{"sbyte"},
    .{"sealed"},    .{"short"},    .{"sizeof"},   .{"stackalloc"}, .{"static"},    .{"string"},
    .{"struct"},    .{"switch"},   .{"this"},     .{"throw"},      .{"true"},      .{"try"},
    .{"typeof"},    .{"uint"},     .{"ulong"},    .{"unchecked"},  .{"unsafe"},    .{"ushort"},
    .{"using"},     .{"virtual"},  .{"void"},     .{"volatile"},   .{"while"},
});

fn csName(arena_state: *std.heap.ArenaAllocator, name: []const u8) ![]const u8 {
    const arena = arena_state.allocator();
    return if (cs_keywords.has(name)) std.fmt.allocPrint(arena, "@{s}", .{name}) else name;
}

fn writeDoc(w: *std.Io.Writer, indent: []const u8, doc: Doc) !void {
    for (doc) |line| {
        if (line.len == 0) try w.print("{s}//\n", .{indent}) else try w.print("{s}// {s}\n", .{ indent, line });
    }
}

fn header(arena_state: *std.heap.ArenaAllocator, w: *std.Io.Writer, src: *const Source) !void {
    const arena = arena_state.allocator();
    try w.writeAll(
        \\// zpdf.h: generated from src/abi.zig by tools/gen-abi.zig; do not edit.
        \\
        \\#ifndef ZPDF_H
        \\#define ZPDF_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#define ZPDF_STATIC_ASSERT static_assert
        \\#else
        \\#define ZPDF_STATIC_ASSERT _Static_assert
        \\#endif
        \\
        \\
    );
    try writeDoc(w, "", src.module_doc);
    try w.print("\n#define ZPDF_ABI_VERSION {d}u\n\ntypedef struct zpdf_context zpdf_context;\n\n", .{abi.abi_version});
    try w.writeAll("enum zpdf_error {\n    ZPDF_OK = 0,\n");
    inline for (abi.error_codes) |e| {
        const upper = try std.ascii.allocUpperString(arena, try snake(arena, @errorName(e[0])));
        try w.print("    ZPDF_ERROR_{s} = {d},\n", .{ upper, e[1] });
    }
    try w.print("    ZPDF_ERROR_UNKNOWN = {d},\n}};\n\n", .{abi.unknown_code});
    try writeDoc(w, "", src.docs.get("RunFlag").?);
    try w.writeAll("enum zpdf_run_flag {\n");
    const flags = @typeInfo(abi.RunFlag).@"enum";
    inline for (flags.field_names, flags.field_values) |name, value| {
        try writeDoc(w, "    ", src.docs.get("RunFlag." ++ name).?);
        try w.print("    ZPDF_RUN_FLAG_{s} = 1u << {d},\n", .{ try std.ascii.allocUpperString(arena, name), value });
    }
    try w.writeAll("};\n\n");
    inline for (records) |name| {
        const T = @field(abi, name);
        const c_name = try cType(arena_state, T);
        try writeDoc(w, "", src.docs.get(name) orelse &.{});
        try w.print("typedef struct {s} {{\n", .{c_name});
        const fields = @typeInfo(T).@"struct";
        inline for (fields.field_names, fields.field_types) |field_name, field_type| {
            try writeDoc(w, "    ", src.docs.get(name ++ "." ++ field_name) orelse &.{});
            if (comptime fnPointee(field_type)) |F| {
                try w.print("    {s};\n", .{try cFnPointerField(arena_state, F, try cName(field_name))});
            } else switch (@typeInfo(field_type)) {
                .array => |a| try w.print("    {s} {s}[{d}];\n", .{ try cType(arena_state, a.child), try cName(field_name), a.len }),
                else => {
                    const t = try cType(arena_state, field_type);
                    try w.print("    {s}{s}{s};\n", .{ t, if (t[t.len - 1] == '*') "" else " ", try cName(field_name) });
                },
            }
        }
        if (comptime hasPointer(T)) {
            // Pointer-sized fields: the platform's C layout, not one size for every target.
            try w.print("}} {s};\n\n", .{c_name});
        } else {
            try w.print("}} {s};\nZPDF_STATIC_ASSERT(sizeof({s}) == {d}, \"{s}\");\n\n", .{ c_name, c_name, @sizeOf(T), c_name });
        }
    }
    inline for (@typeInfo(abi.exports).@"struct".decl_names) |decl_name| {
        const info = @typeInfo(@TypeOf(@field(abi.exports, decl_name))).@"fn";
        const names = try paramNames(src, decl_name, info.param_types.len);
        try writeDoc(w, "", src.fns.get(decl_name).?.doc);
        const ret = try cType(arena_state, info.return_type.?);
        try w.print("{s}{s}{s}(", .{ ret, if (ret[ret.len - 1] == '*') "" else " ", decl_name });
        if (info.param_types.len == 0) try w.writeAll("void");
        inline for (info.param_types, 0..) |param_type, i| {
            const t = try cType(arena_state, param_type.?);
            try w.print("{s}{s}{s}{s}", .{ if (i == 0) "" else ", ", t, if (t[t.len - 1] == '*') "" else " ", try cName(names[i]) });
        }
        try w.writeAll(");\n\n");
    }
    try w.writeAll(
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif
        \\
    );
}

fn paramNames(src: *const Source, name: []const u8, count: usize) ![]const []const u8 {
    const f = src.fns.get(name) orelse {
        std.debug.print("gen-abi: {s} is not in the source's exports\n", .{name});
        return error.SourceMismatch;
    };
    if (f.params.len != count) {
        std.debug.print("gen-abi: {s} has {d} parameters in the source and {d} compiled\n", .{ name, f.params.len, count });
        return error.SourceMismatch;
    }
    return f.params;
}

fn csharp(arena_state: *std.heap.ArenaAllocator, w: *std.Io.Writer, src: *const Source) !void {
    const arena = arena_state.allocator();
    try w.writeAll(
        \\// <auto-generated>
        \\// Generated from src/abi.zig by tools/gen-abi.zig; do not edit. The protocol (contexts,
        \\// buffers, handles, error codes) is in zpdf.h and src/abi.zig.
        \\// </auto-generated>
        \\#nullable enable
        \\
        \\using System.Runtime.InteropServices;
        \\
        \\namespace Zpdf.Native;
        \\
        \\// Never instantiated: a ZpdfContext* is an opaque pointer.
        \\internal struct ZpdfContext
        \\{
        \\}
        \\
        \\internal enum ZpdfError
        \\{
        \\    Ok = 0,
        \\
    );
    inline for (abi.error_codes) |e| try w.print("    {s} = {d},\n", .{ @errorName(e[0]), e[1] });
    try w.print("    Unknown = {d},\n}}\n\n", .{abi.unknown_code});
    try writeDoc(w, "", src.docs.get("RunFlag").?);
    try w.writeAll("[System.Flags]\ninternal enum RunFlag : uint\n{\n");
    const flags = @typeInfo(abi.RunFlag).@"enum";
    inline for (flags.field_names, flags.field_values) |name, value| {
        try writeDoc(w, "    ", src.docs.get("RunFlag." ++ name).?);
        try w.print("    {s} = 1u << {d},\n", .{ try pascal(arena, name), value });
    }
    try w.writeAll("}\n\n");
    inline for (records) |name| {
        const T = @field(abi, name);
        try writeDoc(w, "", src.docs.get(name) orelse &.{});
        if (comptime hasPointer(T)) {
            try w.print("[StructLayout(LayoutKind.Sequential)]\ninternal unsafe struct {s}\n{{\n", .{name});
        } else {
            try w.print("[StructLayout(LayoutKind.Sequential, Size = {d})]\ninternal unsafe struct {s}\n{{\n", .{ @sizeOf(T), name });
        }
        const fields = @typeInfo(T).@"struct";
        inline for (fields.field_names, fields.field_types) |field_name, field_type| {
            try writeDoc(w, "    ", src.docs.get(name ++ "." ++ field_name) orelse &.{});
            switch (@typeInfo(field_type)) {
                .array => |a| try w.print("    public fixed {s} {s}[{d}];\n", .{ try csType(arena_state, a.child), try csName(arena_state, field_name), a.len }),
                else => try w.print("    public {s} {s};\n", .{ try csType(arena_state, field_type), try csName(arena_state, field_name) }),
            }
        }
        try w.writeAll("}\n\n");
    }
    try w.print(
        \\internal static unsafe partial class ZpdfAbi
        \\{{
        \\    public const uint AbiVersion = {d};
        \\    public const string LibraryName = "zpdf";
        \\
    , .{abi.abi_version});
    inline for (@typeInfo(abi.exports).@"struct".decl_names) |decl_name| {
        const info = @typeInfo(@TypeOf(@field(abi.exports, decl_name))).@"fn";
        const names = try paramNames(src, decl_name, info.param_types.len);
        try w.writeAll("\n");
        try writeDoc(w, "    ", src.fns.get(decl_name).?.doc);
        try w.print("    [LibraryImport(LibraryName, EntryPoint = \"{s}\")]\n    public static partial {s} {s}(", .{ decl_name, try csType(arena_state, info.return_type.?), decl_name });
        inline for (info.param_types, 0..) |param_type, i| {
            try w.print("{s}{s} {s}", .{ if (i == 0) "" else ", ", try csType(arena_state, param_type.?), try csName(arena_state, names[i]) });
        }
        try w.writeAll(");\n");
    }
    try w.writeAll("}\n");
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.debug.print("usage: gen-abi <src/abi.zig> <out zpdf.h> <out Zpdf.Abi.g.cs>\n", .{});
        std.process.exit(2);
    }
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const source = try cwd.readFileAllocOptions(io, args[1], arena, .limited(1 << 22), .of(u8), 0);
    const src = try readSource(arena, source);
    for ([_]struct { []const u8, *const fn (*std.heap.ArenaAllocator, *std.Io.Writer, *const Source) anyerror!void }{
        .{ args[2], header },
        .{ args[3], csharp },
    }) |out| {
        var aw: std.Io.Writer.Allocating = .init(arena);
        try out[1](init.arena, &aw.writer, &src);
        try cwd.writeFile(io, .{ .sub_path = out[0], .data = aw.written() });
    }
}
