// The MuPDF side of tools/bench-ab.py: the same pages as tools/bench.zig, drawn with MuPDF's
// C API (a document writer and a device, as an app drawing a report would use it).
//
//   bench-mupdf <grid|text> <font.ttf> <count> <out.pdf>
//
// Keep the scenarios' text, sizes and positions identical to bench.zig. One difference is
// MuPDF's, not this file's: fz_show_string maps characters to glyphs one by one with no
// shaping, where zpdf shapes every line with kb. For the Latin text here the glyphs differ
// only in ligatures. The output is compressed ("compress").
//
// Built by bench-ab.py: zig cc -O2 against Homebrew's mupdf-tools (libmupdf.a,
// libmupdf-third.a).
#include <mupdf/fitz.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void draw(fz_context *ctx, fz_device *dev, fz_font *font, float size, float page_h, float x, float y, const char *s)
{
	fz_text *text = fz_new_text(ctx);
	fz_try(ctx)
	{
		// The writer's device space has y down from the top; the line's baseline is y up from
		// the bottom, as in zpdf.
		fz_matrix trm = fz_make_matrix(size, 0, 0, -size, x, page_h - y);
		fz_show_string(ctx, text, font, trm, s, 0, 0, FZ_BIDI_LTR, FZ_LANG_UNSET);
		float black[3] = {0, 0, 0};
		fz_fill_text(ctx, dev, text, fz_identity, fz_device_rgb(ctx), black, 1, fz_default_color_params);
	}
	fz_always(ctx)
		fz_drop_text(ctx, text);
	fz_catch(ctx)
		fz_rethrow(ctx);
}

// Same cells as bench.zig's grid().
static void grid(fz_context *ctx, fz_document_writer *wri, fz_font *font, int rows)
{
	fz_device *dev = NULL;
	char cell[7][24];
	for (int row = 0; row < rows; row++)
	{
		if (row % 45 == 0)
		{
			if (dev)
				fz_end_page(ctx, wri);
			dev = fz_begin_page(ctx, wri, fz_make_rect(0, 0, 792, 612));
		}
		float y = 576 - 12 * (float)(row % 45);
		snprintf(cell[0], 24, "Item %06d", row);
		snprintf(cell[1], 24, "Vendor %d", row % 97);
		snprintf(cell[2], 24, "Category %d", row % 13);
		snprintf(cell[3], 24, "%d", row * 7 % 1000);
		snprintf(cell[4], 24, "%d.%02d", row % 500, row % 100);
		snprintf(cell[5], 24, "%d", row % 9973);
		snprintf(cell[6], 24, "Room %d", row % 41);
		for (int i = 0; i < 7; i++)
			draw(ctx, dev, font, 9, 612, 36 + 104 * (float)i, y, cell[i]);
	}
	if (dev)
		fz_end_page(ctx, wri);
}

// Same lines as bench.zig's running().
static void running(fz_context *ctx, fz_document_writer *wri, fz_font *font, char *text, int times)
{
	fz_device *dev = NULL;
	int n = 0;
	for (int t = 0; t < times; t++)
	{
		char *p = text;
		while (*p)
		{
			char *end = strchr(p, '\n');
			size_t len = end ? (size_t)(end - p) : strlen(p);
			if (len > 0)
			{
				char line[1024];
				int at = snprintf(line, sizeof line, "%d ", n);
				if (len >= sizeof line - (size_t)at)
					len = sizeof line - (size_t)at - 1;
				memcpy(line + at, p, len);
				line[at + len] = 0;
				if (n % 50 == 0)
				{
					if (dev)
						fz_end_page(ctx, wri);
					dev = fz_begin_page(ctx, wri, fz_make_rect(0, 0, 612, 792));
				}
				draw(ctx, dev, font, 12, 792, 72, 756 - 14 * (float)(n % 50), line);
				n++;
			}
			p = end ? end + 1 : p + len;
		}
	}
	if (dev)
		fz_end_page(ctx, wri);
}

static char *read_file(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	char *buf = malloc((size_t)n + 1);
	if (fread(buf, 1, (size_t)n, f) != (size_t)n)
	{
		fclose(f);
		free(buf);
		return NULL;
	}
	buf[n] = 0;
	fclose(f);
	return buf;
}

int main(int argc, char **argv)
{
	if (argc != 5)
	{
		fprintf(stderr, "usage: bench-mupdf grid|text <font.ttf> <count> <out.pdf>\n");
		return 2;
	}
	int count = atoi(argv[3]);
	fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
	if (!ctx)
		return 1;
	int rc = 0;
	fz_document_writer *wri = NULL;
	fz_font *font = NULL;
	char *text = NULL;
	fz_var(wri);
	fz_var(font);
	fz_var(text);
	fz_try(ctx)
	{
		font = fz_new_font_from_file(ctx, NULL, argv[2], 0, 0);
		wri = fz_new_document_writer(ctx, argv[4], "pdf", "compress");
		if (strcmp(argv[1], "grid") == 0)
			grid(ctx, wri, font, count);
		else if (strcmp(argv[1], "text") == 0)
		{
			text = read_file("tests/golden/latin-small.txt");
			if (!text)
				fz_throw(ctx, FZ_ERROR_GENERIC, "cannot read tests/golden/latin-small.txt");
			running(ctx, wri, font, text, count);
		}
		else
			fz_throw(ctx, FZ_ERROR_GENERIC, "unknown scenario %s", argv[1]);
		fz_close_document_writer(ctx, wri);
	}
	fz_always(ctx)
	{
		fz_drop_document_writer(ctx, wri);
		fz_drop_font(ctx, font);
		free(text);
	}
	fz_catch(ctx)
	{
		fprintf(stderr, "bench-mupdf: %s\n", fz_caught_message(ctx));
		rc = 1;
	}
	fz_drop_context(ctx);
	return rc;
}
