// libzpdf through its C ABI, as .NET and C callers use it, for comparing two builds of the library
// (tools/bench-abi.py runs it against this tree and a base).
//
//   bench-abi write <threads> <rows> <font.ttf> <out.pdf|->
//   bench-abi read  <threads> <times> <in.pdf>
//
// write: each thread makes a document of `rows` rows of 7 cells at 9 pt, 45 rows a page, Letter
//   landscape (the cells of tools/bench.zig's grid): the text columns in the embedded font, shaped,
//   the numbers in Helvetica. The PDF goes to a sink; with "-" the sink discards it, else thread 0's
//   is written to out.pdf.
// read: each thread opens the PDF and reads every page's text, `times` times over.
// Each thread has its own context. Prints one line: wall_ms=<n> maxrss_kb=<n> bytes=<n>, where bytes
// is the PDF bytes written (write) or the text bytes read (read), summed over threads.
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#include "zpdf.h"

static unsigned char *font_bytes;
static size_t font_len;
static unsigned char *pdf_bytes;
static size_t pdf_len;
static int rows_or_times;
static FILE *out_file;

static void check(int32_t rc, const char *what) {
    if (rc != ZPDF_OK) {
        const char *name = zpdf_error_name(rc);
        fprintf(stderr, "bench-abi: %s: %s\n", what, name ? name : "?");
        exit(1);
    }
}

// This process's peak resident memory, in KiB. Linux: VmHWM, because ru_maxrss survives execve
// and would report the peak of whatever started the harness (a Python runner's).
// macOS: ru_maxrss, which it gives in bytes.
static long peak_rss_kb(void) {
#ifdef __APPLE__
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return ru.ru_maxrss / 1024;
#else
    FILE *f = fopen("/proc/self/status", "r");
    if (!f) {
        perror("bench-abi: /proc/self/status");
        exit(1);
    }
    char line[256];
    long kb = -1;
    while (fgets(line, sizeof line, f)) {
        if (sscanf(line, "VmHWM: %ld kB", &kb) == 1) break;
    }
    fclose(f);
    if (kb < 0) {
        fprintf(stderr, "bench-abi: no VmHWM in /proc/self/status\n");
        exit(1);
    }
    return kb;
#endif
}

static unsigned char *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "bench-abi: cannot open %s\n", path);
        exit(2);
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *b = malloc((size_t)n);
    if (!b || fread(b, 1, (size_t)n, f) != (size_t)n) exit(2);
    fclose(f);
    *len = (size_t)n;
    return b;
}

struct sink_state {
    uint64_t bytes;
    FILE *file;
};

static int32_t sink_write(void *user, const uint8_t *bytes, size_t n) {
    struct sink_state *s = user;
    s->bytes += n;
    if (s->file && fwrite(bytes, 1, n, s->file) != n) return -1;
    return 0;
}

static void *writer(void *arg) {
    int id = (int)(intptr_t)arg;
    zpdf_context *ctx = zpdf_context_new();
    if (!ctx) exit(1);
    uint32_t font = 0, standard = 0, doc = 0, embedded = 0, helvetica = 0, page = 0;
    check(zpdf_font_open(ctx, font_bytes, font_len, 0, NULL, 0, &font), "font_open");
    check(zpdf_font_open_standard(ctx, 0, &standard), "font_open_standard");
    struct sink_state *s = calloc(1, sizeof *s);
    s->file = id == 0 ? out_file : NULL;
    zpdf_sink sink = {.user = s, .write = sink_write};
    check(zpdf_doc_new_sink(ctx, 1, &sink, &doc), "doc_new_sink");
    check(zpdf_doc_add_font(ctx, doc, font, &embedded), "add_font");
    check(zpdf_doc_add_font(ctx, doc, standard, &helvetica), "add_font standard");
    char cell[7][24];
    for (int row = 0; row < rows_or_times; row++) {
        if (row % 45 == 0) {
            if (row) check(zpdf_doc_end_page(ctx, doc, page), "end_page");
            check(zpdf_doc_begin_page(ctx, doc, 792, 612, &page), "begin_page");
        }
        double y = 576 - 12 * (double)(row % 45);
        snprintf(cell[0], 24, "Item %06d", row);
        snprintf(cell[1], 24, "Vendor %d", row % 97);
        snprintf(cell[2], 24, "Category %d", row % 13);
        snprintf(cell[3], 24, "%d", row * 7 % 1000);
        snprintf(cell[4], 24, "%d.%02d", row % 500, row % 100);
        snprintf(cell[5], 24, "%d", row % 9973);
        snprintf(cell[6], 24, "Room %d", row % 41);
        for (int i = 0; i < 7; i++) {
            uint32_t f = (i == 0 || i == 1 || i == 2 || i == 6) ? embedded : helvetica;
            check(zpdf_doc_draw_text(ctx, doc, page, f, 9, 36 + 104 * (double)i, y, 0, 0, 0,
                                     (const uint8_t *)cell[i], strlen(cell[i]), 0), "draw_text");
        }
    }
    check(zpdf_doc_end_page(ctx, doc, page), "end_page");
    uint8_t *rest = NULL;
    size_t rest_len = 0;
    check(zpdf_doc_finish(ctx, doc, &rest, &rest_len), "finish");
    check(zpdf_doc_close(ctx, doc), "doc_close");
    check(zpdf_font_close(ctx, font), "font_close");
    check(zpdf_font_close(ctx, standard), "font_close standard");
    check(zpdf_context_free(ctx), "context_free");
    return s;
}

static void *reader(void *arg) {
    (void)arg;
    zpdf_context *ctx = zpdf_context_new();
    if (!ctx) exit(1);
    uint64_t *bytes = calloc(1, sizeof *bytes);
    for (int t = 0; t < rows_or_times; t++) {
        uint32_t r = 0, pages = 0;
        check(zpdf_reader_open(ctx, pdf_bytes, pdf_len, &r), "reader_open");
        check(zpdf_reader_page_count(ctx, r, &pages), "page_count");
        for (uint32_t i = 0; i < pages; i++) {
            uint8_t *buf = NULL;
            size_t len = 0;
            check(zpdf_reader_page_text(ctx, r, i, &buf, &len), "page_text");
            *bytes += len;
            check(zpdf_free(ctx, buf, len), "free");
        }
        check(zpdf_reader_close(ctx, r), "reader_close");
    }
    check(zpdf_context_free(ctx), "context_free");
    return bytes;
}

int main(int argc, char **argv) {
    int write = argc == 6 && strcmp(argv[1], "write") == 0;
    int read = argc == 5 && strcmp(argv[1], "read") == 0;
    if (!write && !read) {
        fprintf(stderr, "usage: bench-abi write <threads> <rows> <font.ttf> <out.pdf|->\n"
                        "       bench-abi read  <threads> <times> <in.pdf>\n");
        return 2;
    }
    if (zpdf_abi_version() != ZPDF_ABI_VERSION) {
        fprintf(stderr, "bench-abi: libzpdf ABI %u, built for %u\n", zpdf_abi_version(), ZPDF_ABI_VERSION);
        return 2;
    }
    int threads = atoi(argv[2]);
    rows_or_times = atoi(argv[3]);
    if (threads < 1 || threads > 64 || rows_or_times < 1) return 2;
    if (write) {
        font_bytes = read_file(argv[4], &font_len);
        out_file = strcmp(argv[5], "-") == 0 ? NULL : fopen(argv[5], "wb");
    } else {
        pdf_bytes = read_file(argv[4], &pdf_len);
    }
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    pthread_t th[64];
    for (int i = 0; i < threads; i++) pthread_create(&th[i], NULL, write ? writer : reader, (void *)(intptr_t)i);
    uint64_t bytes = 0;
    for (int i = 0; i < threads; i++) {
        void *r;
        pthread_join(th[i], &r);
        bytes += *(uint64_t *)r;
        free(r);
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    if (out_file) fclose(out_file);
    long ms = (long)((t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000);
    printf("wall_ms=%ld maxrss_kb=%ld bytes=%llu\n", ms, peak_rss_kb(), (unsigned long long)bytes);
    return 0;
}
