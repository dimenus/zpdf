//! Checks that each built libzpdf exports exactly the functions the generated C# declares.
//!
//!     check-exports <Zpdf.Abi.g.cs> <library>...
//!
//! The declarations come from src/abi.zig's types (tools/gen-abi.zig); a library's export table
//! comes from the linker, so it shares nothing with them. A function declared but not exported fails
//! only when C# first calls it (EntryPointNotFoundException); one exported but not declared is ABI
//! that no binding covers. Each library is read by its own format, whatever the host: ELF (.dynsym),
//! Mach-O (LC_SYMTAB, defined external symbols, without the leading underscore) or PE (the export
//! directory). Only names starting with "zpdf_" count; the rest are the linker's own.

const std = @import("std");
const elf = std.elf;
const macho = std.macho;
const coff = std.coff;

const Names = std.StringArrayHashMapUnmanaged(void);

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage: check-exports <Zpdf.Abi.g.cs> <library>...\n", .{});
        std.process.exit(2);
    }
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var declared: Names = .empty;
    const csharp = try cwd.readFileAlloc(io, args[1], arena, .limited(1 << 22));
    var rest: []const u8 = csharp;
    const marker = "EntryPoint = \"";
    while (std.mem.indexOf(u8, rest, marker)) |at| {
        rest = rest[at + marker.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return error.UnclosedEntryPoint;
        try declared.put(arena, rest[0..end], {});
    }
    // A file the parse found nothing in would make every library "export too much"; say so instead.
    if (declared.count() == 0) fail("{s}: no EntryPoint declarations found", .{args[1]});

    var bad = false;
    for (args[2..]) |path| {
        const bytes = try cwd.readFileAlloc(io, path, arena, .limited(1 << 28));
        var exported: Names = .empty;
        if (std.mem.startsWith(u8, bytes, elf.MAGIC)) {
            try elfExports(arena, bytes, &exported);
        } else if (bytes.len >= 4 and std.mem.readInt(u32, bytes[0..4], .little) == macho.MH_MAGIC_64) {
            try machoExports(arena, bytes, &exported);
        } else if (std.mem.startsWith(u8, bytes, "MZ")) {
            try peExports(arena, bytes, &exported);
        } else {
            fail("{s}: not an ELF, 64-bit Mach-O or PE file", .{path});
        }
        for (declared.keys()) |name| if (!exported.contains(name)) {
            std.debug.print("{s}: declared in C# but not exported: {s}\n", .{ path, name });
            bad = true;
        };
        for (exported.keys()) |name| if (!declared.contains(name)) {
            std.debug.print("{s}: exported but not declared in C#: {s}\n", .{ path, name });
            bad = true;
        };
    }
    if (bad) std.process.exit(1);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

fn read(comptime T: type, bytes: []const u8, at: usize) !T {
    if (at > bytes.len or bytes.len - at < @sizeOf(T)) return error.Truncated;
    return std.mem.bytesToValue(T, bytes[at..][0..@sizeOf(T)]);
}

fn cString(bytes: []const u8, at: usize) ![]const u8 {
    if (at >= bytes.len) return error.Truncated;
    const end = std.mem.indexOfScalarPos(u8, bytes, at, 0) orelse return error.Truncated;
    return bytes[at..end];
}

fn keep(arena: std.mem.Allocator, names: *Names, name: []const u8) !void {
    if (std.mem.startsWith(u8, name, "zpdf_")) try names.put(arena, name, {});
}

/// Defined global or weak functions in .dynsym (what the dynamic linker resolves).
fn elfExports(arena: std.mem.Allocator, bytes: []const u8, names: *Names) !void {
    if (bytes[elf.EI.CLASS] != elf.ELFCLASS64) return error.NotElf64;
    const header = try read(elf.Elf64_Ehdr, bytes, 0);
    var i: usize = 0;
    while (i < header.e_shnum) : (i += 1) {
        const section = try read(elf.Elf64_Shdr, bytes, header.e_shoff + i * header.e_shentsize);
        if (section.sh_type != @backingInt(elf.SHT.DYNSYM)) continue;
        const strings = try read(elf.Elf64_Shdr, bytes, header.e_shoff + section.sh_link * header.e_shentsize);
        var at = section.sh_offset;
        while (at < section.sh_offset + section.sh_size) : (at += section.sh_entsize) {
            const sym = try read(elf.Elf64_Sym, bytes, at);
            const bind = sym.st_bind();
            if (sym.st_shndx == elf.SHN_UNDEF or sym.st_type() != elf.STT_FUNC) continue;
            if (bind != elf.STB_GLOBAL and bind != elf.STB_WEAK) continue;
            try keep(arena, names, try cString(bytes, strings.sh_offset + sym.st_name));
        }
        return;
    }
    return error.NoDynsym;
}

/// External symbols defined in a section, from LC_SYMTAB; C names carry a leading underscore.
fn machoExports(arena: std.mem.Allocator, bytes: []const u8, names: *Names) !void {
    const header = try read(macho.mach_header_64, bytes, 0);
    var at: usize = @sizeOf(macho.mach_header_64);
    var i: usize = 0;
    while (i < header.ncmds) : (i += 1) {
        const command = try read(macho.load_command, bytes, at);
        if (command.cmd == .SYMTAB) {
            const symtab = try read(macho.symtab_command, bytes, at);
            var s: usize = 0;
            while (s < symtab.nsyms) : (s += 1) {
                const sym = try read(macho.nlist_64, bytes, symtab.symoff + s * @sizeOf(macho.nlist_64));
                const bits = sym.n_type.bits;
                if (bits.is_stab != 0 or !bits.ext or bits.type != .sect) continue;
                const name = try cString(bytes, symtab.stroff + sym.n_strx);
                if (name.len > 0 and name[0] == '_') try keep(arena, names, name[1..]);
            }
            return;
        }
        at += command.cmdsize;
    }
    return error.NoSymtab;
}

/// The names in the export directory of a PE32+ image.
fn peExports(arena: std.mem.Allocator, bytes: []const u8, names: *Names) !void {
    const pe_at = std.mem.readInt(u32, (try read([4]u8, bytes, 0x3c))[0..], .little);
    if (!std.mem.eql(u8, &(try read([4]u8, bytes, pe_at)), "PE\x00\x00")) return error.NotPe;
    const header = try read(coff.Header, bytes, pe_at + 4);
    const optional_at = pe_at + 4 + @sizeOf(coff.Header);
    const optional = try read(coff.OptionalHeader.@"PE32+", bytes, optional_at);
    if (optional.standard.magic != .@"PE32+") return error.NotPe32Plus;
    if (optional.number_of_rva_and_sizes == 0) return error.NoExportDirectory;
    // The data directories follow the optional header's fixed part; the export table is the first.
    const directory = try read(coff.ImageDataDirectory, bytes, optional_at + @sizeOf(coff.OptionalHeader.@"PE32+"));
    const sections_at = optional_at + header.size_of_optional_header;
    const table = try read(coff.ExportDirectoryTable, bytes, try fileOffset(bytes, sections_at, header.number_of_sections, directory.virtual_address));
    const name_rvas = try fileOffset(bytes, sections_at, header.number_of_sections, table.name_pointer_table_rva);
    var i: usize = 0;
    while (i < table.number_of_names) : (i += 1) {
        const name_rva = (try read(coff.ExportNamePointerTableEntry, bytes, name_rvas + i * 4)).name_rva;
        try keep(arena, names, try cString(bytes, try fileOffset(bytes, sections_at, header.number_of_sections, name_rva)));
    }
}

/// Where the byte at relative virtual address `rva` is in the file, from the section table.
fn fileOffset(bytes: []const u8, sections_at: usize, count: u16, rva: u32) !usize {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const section = try read(coff.SectionHeader, bytes, sections_at + i * @sizeOf(coff.SectionHeader));
        if (rva >= section.virtual_address and rva - section.virtual_address < @max(section.virtual_size, section.size_of_raw_data)) {
            return section.pointer_to_raw_data + (rva - section.virtual_address);
        }
    }
    return error.RvaOutsideSections;
}
