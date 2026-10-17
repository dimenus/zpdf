// libzpdf as a C caller has it: the generated zpdf.h and the shared library.
//
//     abi-test <font.ttf> <a PDF with two or more pages>
//
// Several threads, each with its own context, write a PDF with an embedded font and a standard
// font, read it back, and read the given PDF. Each checks what it reads and that its context
// ends with no live bytes. Prints "abi-test: ok" when every check passed.

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "zpdf.h"

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

#define THREADS 4
#define ROUNDS 8

static unsigned char *font_bytes;
static size_t font_len;
static unsigned char *pdf_bytes;
static size_t pdf_len;

static void fail(const char *what, int32_t rc) {
    const char *name = zpdf_error_name(rc);
    fprintf(stderr, "abi-test: %s: %d %s\n", what, rc, name ? name : "(no name)");
    exit(1);
}

#define CHECK(call)                     \
    do {                                \
        int32_t rc_ = (call);           \
        if (rc_ != ZPDF_OK) fail(#call, rc_); \
    } while (0)

#define EXPECT(cond)                                         \
    do {                                                     \
        if (!(cond)) {                                       \
            fprintf(stderr, "abi-test: failed: %s\n", #cond); \
            exit(1);                                         \
        }                                                    \
    } while (0)

static unsigned char *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "abi-test: cannot open %s\n", path);
        exit(2);
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *bytes = malloc((size_t)n);
    if (!bytes || fread(bytes, 1, (size_t)n, f) != (size_t)n) exit(2);
    fclose(f);
    *len = (size_t)n;
    return bytes;
}

// The page's text, all runs joined, into `out` (NUL-terminated).
static void page_text(zpdf_context *ctx, uint32_t reader, uint32_t index, char *out, size_t cap) {
    uint8_t *buf = NULL;
    size_t len = 0;
    CHECK(zpdf_reader_page_text(ctx, reader, index, &buf, &len));
    zpdf_text_header h;
    memcpy(&h, buf, sizeof h);
    size_t runs_at = sizeof h;
    size_t strings_at = runs_at + h.run_count * sizeof(zpdf_run_record) + h.glyph_count * sizeof(zpdf_glyph_record);
    EXPECT(strings_at + h.strings_len == len);
    size_t n = 0;
    for (uint32_t i = 0; i < h.run_count; i++) {
        zpdf_run_record r;
        memcpy(&r, buf + runs_at + i * sizeof r, sizeof r);
        EXPECT(r.text_offset + r.text_len <= h.strings_len);
        EXPECT(n + r.text_len < cap);
        memcpy(out + n, buf + strings_at + r.text_offset, r.text_len);
        n += r.text_len;
    }
    out[n] = 0;
    CHECK(zpdf_free(ctx, buf, len));
}

// A memory sink, as a C caller writes one: it keeps every byte zpdf hands it.
struct mem_sink {
    uint8_t *data;
    size_t len, cap;
    int calls;
};

static int32_t mem_write(void *user, const uint8_t *bytes, size_t n) {
    struct mem_sink *m = user;
    if (m->len + n > m->cap) {
        size_t cap = m->cap ? m->cap : 4096;
        while (cap < m->len + n) cap *= 2;
        uint8_t *grown = realloc(m->data, cap);
        if (!grown) return -1;
        m->data = grown;
        m->cap = cap;
    }
    memcpy(m->data + m->len, bytes, n);
    m->len += n;
    m->calls++;
    return 0;
}

// A caller-buffer sink, as a C caller writes one: zpdf writes into memory this lends (a
// scratch area of at least min_len bytes), and commit keeps what was written. The test checks
// that a buffer is never lent twice before it comes back.
struct lend_sink {
    struct mem_sink out;
    uint8_t *scratch;
    size_t scratch_len;
    int lent;
};

static int32_t lend_get(void *user, size_t min_len, uint8_t **buffer, size_t *len) {
    struct lend_sink *l = user;
    if (l->lent) return -1;
    if (l->scratch_len < min_len) {
        uint8_t *grown = realloc(l->scratch, min_len);
        if (!grown) return -1;
        l->scratch = grown;
        l->scratch_len = min_len;
    }
    l->lent = 1;
    *buffer = l->scratch;
    *len = l->scratch_len;
    return 0;
}

static int32_t lend_commit(void *user, size_t len) {
    struct lend_sink *l = user;
    if (!l->lent) return -1;
    l->lent = 0;
    return mem_write(&l->out, l->scratch, len);
}

// One page: the line in the embedded font, "Helvetica", a rectangle, and a place for later text.
// Returns the later place and Helvetica's id.
static void draw_page(zpdf_context *ctx, uint32_t doc, uint32_t font, const char *line, uint32_t *later, uint32_t *helvetica) {
    uint32_t embedded = 0, page = 0;
    CHECK(zpdf_doc_add_font(ctx, doc, font, &embedded));
    CHECK(zpdf_doc_add_standard_font(ctx, doc, 0, helvetica));
    CHECK(zpdf_doc_begin_page(ctx, doc, 612, 792, &page));
    CHECK(zpdf_doc_draw_text(ctx, doc, page, embedded, 24, 72, 720, 0, 0, 0, (const uint8_t *)line, strlen(line), 0));
    CHECK(zpdf_doc_draw_text(ctx, doc, page, *helvetica, 12, 72, 690, 0, 0.5, 0.5, (const uint8_t *)"Helvetica", 9, 0));
    CHECK(zpdf_doc_fill_rect(ctx, doc, page, 72, 600, 100, 50, 0.9, 0.9, 0.9));
    CHECK(zpdf_doc_reserve_later(ctx, doc, page, later));
    CHECK(zpdf_doc_end_page(ctx, doc, page));
}

static void *work(void *arg) {
    int id = (int)(size_t)arg;
    for (int round = 0; round < ROUNDS; round++) {
        zpdf_context *ctx = zpdf_context_new();
        EXPECT(ctx != NULL);

        uint32_t font = 0;
        CHECK(zpdf_font_open(ctx, font_bytes, font_len, 0, NULL, 0, &font));
        uint8_t *buf = NULL;
        size_t len = 0;
        CHECK(zpdf_font_shape(ctx, font, (const uint8_t *)"office", 6, 0, &buf, &len));
        EXPECT(len > sizeof(zpdf_shape_header) && (len - sizeof(zpdf_shape_header)) % sizeof(zpdf_shaped_glyph) == 0);
        CHECK(zpdf_free(ctx, buf, len));

        char line[64];
        snprintf(line, sizeof line, "Thread %d round %d", id, round);

        // The same document into the caller's sink: when end_page returns, the page is there.
        struct mem_sink sink_out = {0};
        zpdf_sink sink = {.user = &sink_out, .write = mem_write};
        uint32_t sink_doc = 0, sink_later = 0, sink_helvetica = 0;
        CHECK(zpdf_doc_new_sink(ctx, 1, &sink, &sink_doc));
        draw_page(ctx, sink_doc, font, line, &sink_later, &sink_helvetica);
        EXPECT(sink_out.len > 5 && memcmp(sink_out.data, "%PDF-", 5) == 0);
        size_t sink_after_page = sink_out.len;
        CHECK(zpdf_doc_draw_text_later(ctx, sink_doc, sink_later, sink_helvetica, 9, 300, 40, 0, 0, 0, (const uint8_t *)"Page 1 of 1", 11, 0));
        uint8_t *none = NULL;
        size_t none_len = 1;
        CHECK(zpdf_doc_finish(ctx, sink_doc, &none, &none_len));
        EXPECT(none == NULL && none_len == 0);
        CHECK(zpdf_doc_close(ctx, sink_doc));

        // And into memory the caller lends: nothing is held between calls.
        struct lend_sink lend = {0};
        zpdf_sink lend_sink = {.user = &lend, .get_buffer = lend_get, .commit = lend_commit};
        uint32_t lend_doc = 0, lend_later = 0, lend_helvetica = 0;
        CHECK(zpdf_doc_new_sink(ctx, 1, &lend_sink, &lend_doc));
        EXPECT(!lend.lent);
        draw_page(ctx, lend_doc, font, line, &lend_later, &lend_helvetica);
        EXPECT(!lend.lent);
        EXPECT(lend.out.len == sink_after_page);
        CHECK(zpdf_doc_draw_text_later(ctx, lend_doc, lend_later, lend_helvetica, 9, 300, 40, 0, 0, 0, (const uint8_t *)"Page 1 of 1", 11, 0));
        CHECK(zpdf_doc_finish(ctx, lend_doc, &none, &none_len));
        EXPECT(!lend.lent && none == NULL && none_len == 0);
        CHECK(zpdf_doc_close(ctx, lend_doc));
        EXPECT(lend.out.len == sink_out.len && memcmp(lend.out.data, sink_out.data, sink_out.len) == 0);
        free(lend.out.data);
        free(lend.scratch);

        uint32_t doc = 0, helvetica = 0, later = 0;
        CHECK(zpdf_doc_new(ctx, 1, &doc));
        draw_page(ctx, doc, font, line, &later, &helvetica);
        CHECK(zpdf_font_close(ctx, font));  // the document keeps it
        // Streamed: the page's bytes are taken as soon as it ends, then the rest at finish.
        uint8_t *first = NULL;
        size_t first_len = 0;
        CHECK(zpdf_doc_take(ctx, doc, &first, &first_len));
        EXPECT(first_len > 5 && memcmp(first, "%PDF-", 5) == 0);
        CHECK(zpdf_doc_draw_text_later(ctx, doc, later, helvetica, 9, 300, 40, 0, 0, 0, (const uint8_t *)"Page 1 of 1", 11, 0));
        uint8_t *rest = NULL;
        size_t rest_len = 0;
        CHECK(zpdf_doc_finish(ctx, doc, &rest, &rest_len));
        EXPECT(zpdf_context_free(ctx) == ZPDF_ERROR_BUFFERS_OUTSTANDING);
        // The sink got the bytes take and finish give, in the same pieces' order.
        EXPECT(sink_after_page == first_len);
        EXPECT(sink_out.len == first_len + rest_len);
        EXPECT(memcmp(sink_out.data, first, first_len) == 0);
        EXPECT(memcmp(sink_out.data + first_len, rest, rest_len) == 0);
        free(sink_out.data);
        len = first_len + rest_len;
        buf = malloc(len);
        EXPECT(buf != NULL);
        memcpy(buf, first, first_len);
        memcpy(buf + first_len, rest, rest_len);
        CHECK(zpdf_free(ctx, first, first_len));
        CHECK(zpdf_free(ctx, rest, rest_len));

        uint32_t reader = 0, pages = 0;
        CHECK(zpdf_reader_open(ctx, buf, len, &reader));
        free(buf);  // the reader has its own copy
        CHECK(zpdf_reader_page_count(ctx, reader, &pages));
        EXPECT(pages == 1);
        zpdf_page_info info;
        CHECK(zpdf_reader_page(ctx, reader, 0, &info));
        EXPECT(info.media_box[2] == 612 && info.media_box[3] == 792 && info.rotate == 0);
        char text[256];
        page_text(ctx, reader, 0, text, sizeof text);
        char want[256];
        snprintf(want, sizeof want, "%sHelveticaPage 1 of 1", line);
        if (strcmp(text, want) != 0) {
            fprintf(stderr, "abi-test: read back \"%s\", wrote \"%s\"\n", text, want);
            exit(1);
        }
        EXPECT(zpdf_reader_page(ctx, reader, 1, &info) == ZPDF_ERROR_INVALID_PAGE);
        CHECK(zpdf_reader_close(ctx, reader));
        CHECK(zpdf_doc_close(ctx, doc));

        CHECK(zpdf_reader_open(ctx, pdf_bytes, pdf_len, &reader));
        CHECK(zpdf_reader_page_count(ctx, reader, &pages));
        EXPECT(pages >= 2);
        for (uint32_t i = 0; i < pages; i++) {
            page_text(ctx, reader, i, text, sizeof text);
            EXPECT(strlen(text) > 0);
        }
        CHECK(zpdf_reader_close(ctx, reader));

        size_t live = 1;
        CHECK(zpdf_live_bytes(ctx, &live));
        EXPECT(live == 0);
        CHECK(zpdf_context_free(ctx));
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: abi-test <font.ttf> <a PDF with two or more pages>\n");
        return 2;
    }
    EXPECT(zpdf_abi_version() == ZPDF_ABI_VERSION);
    EXPECT(strcmp(zpdf_error_name(ZPDF_ERROR_INVALID_FONT), "InvalidFont") == 0);
    font_bytes = read_file(argv[1], &font_len);
    pdf_bytes = read_file(argv[2], &pdf_len);

    pthread_t threads[THREADS];
    for (size_t i = 0; i < THREADS; i++) EXPECT(pthread_create(&threads[i], NULL, work, (void *)i) == 0);
    for (size_t i = 0; i < THREADS; i++) EXPECT(pthread_join(threads[i], NULL) == 0);
    free(font_bytes);
    free(pdf_bytes);
#ifdef _WIN32
    // Text-mode stdout writes "\r\n" for "\n", and the build compares the bytes.
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    printf("abi-test: ok\n");
    return 0;
}
