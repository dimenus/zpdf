// libdeflate's DEFLATE decompressor, for src/read.zig's inflate: lib/deflate_decompress.c, and on
// x86 the CPU feature detection that picks its BMI2 variant (lib/x86/cpu_features.c, which only
// executes cpuid).
//
// libdeflate's lib_common.h marks its API __attribute__((visibility("default"))) under clang, which
// -fvisibility=hidden does not override, so libzpdf would export libdeflate_* and could bind to
// another libdeflate in the same process, or it to ours. The system headers it uses are included
// first; then `visibility` becomes a macro that makes libdeflate's own attributes hidden. System
// headers spell it __visibility__, so nothing else is changed. Without it the Linux and macOS
// libraries exported six libdeflate_ functions; tools/check-exports.zig fails on any.
//
// lib/utils.c is left out. Built FREESTANDING (no C runtime), it defines weak memset, memcpy,
// memmove and memcmp of its own, as plain byte loops; in libzpdf for Linux, which links no libc,
// they replaced Zig's own for all of the library (its memcpy was 117 bytes there, Zig's 351). Of
// the rest, the decompressor needs only the default allocator, which read.zig never uses: it always
// passes its own in libdeflate_options. FREESTANDING still makes lib_common.h call the compiler's
// built-in memset and memcpy, which reach Zig's.

#ifndef FREESTANDING
#  include <stdlib.h>
#  include <string.h>
#endif
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define visibility(v) visibility("hidden")

#include "lib/deflate_decompress.c"

malloc_func_t libdeflate_default_malloc_func = NULL;
free_func_t libdeflate_default_free_func = NULL;
#if defined(__x86_64__) || defined(__i386__) || defined(_M_X64) || defined(_M_IX86)
#  include "lib/x86/cpu_features.c"
#endif
