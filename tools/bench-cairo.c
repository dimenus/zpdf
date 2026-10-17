// The HarfBuzz + Cairo side of tools/bench-ab.py: the same pages as tools/bench.zig, shaped by
// HarfBuzz and written by Cairo's PDF surface (the stack hb-view uses). Like zpdf, it shapes every
// line and embeds a subset of the TrueType font; cairo_show_text_glyphs passes HarfBuzz's clusters
// so a ligature maps back to its text.
//
//   bench-cairo <grid|text> <font.ttf> <count> <out.pdf>
//
// Keep the scenarios' text, sizes and positions identical to bench.zig. Cairo compresses its
// streams by default. Built by bench-ab.py against Homebrew's cairo, harfbuzz and freetype.
#include <cairo/cairo-ft.h>
#include <cairo/cairo-pdf.h>
#include <cairo/cairo.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <harfbuzz/hb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct
{
	cairo_t *cr;
	hb_font_t *hb;
	hb_buffer_t *buf;
	double page_h;
	unsigned upem;
} Ctx;

// Shapes `s` and draws it at (x, y), y up from the page's bottom as in zpdf, at `size` points.
static void draw(Ctx *c, double size, double x, double y, const char *s)
{
	int len = (int)strlen(s);
	hb_buffer_clear_contents(c->buf);
	hb_buffer_add_utf8(c->buf, s, len, 0, len);
	hb_buffer_guess_segment_properties(c->buf);
	hb_shape(c->hb, c->buf, NULL, 0);
	unsigned n;
	hb_glyph_info_t *info = hb_buffer_get_glyph_infos(c->buf, &n);
	hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(c->buf, &n);

	cairo_glyph_t *glyphs = cairo_glyph_allocate((int)n);
	cairo_text_cluster_t *clusters = cairo_text_cluster_allocate((int)n);
	double scale = size / c->upem;
	double pen = 0;
	int nc = 0;
	for (unsigned i = 0; i < n; i++)
	{
		glyphs[i].index = info[i].codepoint;
		glyphs[i].x = x + (pen + pos[i].x_offset) * scale;
		glyphs[i].y = (c->page_h - y) - pos[i].y_offset * scale;
		pen += pos[i].x_advance;
		// One Cairo cluster per HarfBuzz cluster: its bytes run to the next cluster's start.
		if (i == 0 || info[i].cluster != info[i - 1].cluster)
		{
			unsigned next = (unsigned)len;
			for (unsigned j = i + 1; j < n; j++)
				if (info[j].cluster != info[i].cluster)
				{
					next = info[j].cluster;
					break;
				}
			clusters[nc].num_bytes = (int)(next - info[i].cluster);
			clusters[nc].num_glyphs = 1;
			nc++;
		}
		else
			clusters[nc - 1].num_glyphs++;
	}
	cairo_show_text_glyphs(c->cr, s, len, glyphs, (int)n, clusters, nc, 0);
	cairo_glyph_free(glyphs);
	cairo_text_cluster_free(clusters);
}

static void grid(Ctx *c, int rows)
{
	char cell[7][24];
	for (int row = 0; row < rows; row++)
	{
		if (row % 45 == 0 && row != 0)
			cairo_show_page(c->cr);
		double y = 576 - 12 * (double)(row % 45);
		snprintf(cell[0], 24, "Item %06d", row);
		snprintf(cell[1], 24, "Vendor %d", row % 97);
		snprintf(cell[2], 24, "Category %d", row % 13);
		snprintf(cell[3], 24, "%d", row * 7 % 1000);
		snprintf(cell[4], 24, "%d.%02d", row % 500, row % 100);
		snprintf(cell[5], 24, "%d", row % 9973);
		snprintf(cell[6], 24, "Room %d", row % 41);
		for (int i = 0; i < 7; i++)
			draw(c, 9, 36 + 104 * (double)i, y, cell[i]);
	}
	cairo_show_page(c->cr);
}

static void running(Ctx *c, char *text, int times)
{
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
				if (n % 50 == 0 && n != 0)
					cairo_show_page(c->cr);
				draw(c, 12, 72, 756 - 14 * (double)(n % 50), line);
				n++;
			}
			p = end ? end + 1 : p + len;
		}
	}
	cairo_show_page(c->cr);
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
	size_t got = fread(buf, 1, (size_t)n, f);
	fclose(f);
	buf[got] = 0;
	return buf;
}

int main(int argc, char **argv)
{
	if (argc != 5)
	{
		fprintf(stderr, "usage: bench-cairo grid|text <font.ttf> <count> <out.pdf>\n");
		return 2;
	}
	int count = atoi(argv[3]);
	int is_grid = strcmp(argv[1], "grid") == 0;
	if (!is_grid && strcmp(argv[1], "text") != 0)
	{
		fprintf(stderr, "unknown scenario %s\n", argv[1]);
		return 2;
	}
	FT_Library ft;
	FT_Face face;
	if (FT_Init_FreeType(&ft) || FT_New_Face(ft, argv[2], 0, &face))
	{
		fprintf(stderr, "bench-cairo: cannot load %s\n", argv[2]);
		return 1;
	}
	Ctx c = {0};
	// HarfBuzz's own OpenType functions, in font units; FreeType only backs Cairo's font face.
	hb_blob_t *blob = hb_blob_create_from_file(argv[2]);
	hb_face_t *hb_face = hb_face_create(blob, 0);
	c.upem = hb_face_get_upem(hb_face);
	c.hb = hb_font_create(hb_face);
	c.buf = hb_buffer_create();
	c.page_h = is_grid ? 612 : 792;
	cairo_surface_t *surface = cairo_pdf_surface_create(argv[4], is_grid ? 792 : 612, c.page_h);
	c.cr = cairo_create(surface);
	cairo_font_face_t *cf = cairo_ft_font_face_create_for_ft_face(face, 0);
	cairo_set_font_face(c.cr, cf);
	cairo_set_font_size(c.cr, is_grid ? 9 : 12);
	cairo_set_source_rgb(c.cr, 0, 0, 0);

	int rc = 0;
	if (is_grid)
		grid(&c, count);
	else
	{
		char *text = read_file("tests/golden/latin-small.txt");
		if (!text)
		{
			fprintf(stderr, "bench-cairo: cannot read tests/golden/latin-small.txt\n");
			rc = 1;
		}
		else
		{
			running(&c, text, count);
			free(text);
		}
	}
	cairo_destroy(c.cr);
	cairo_surface_finish(surface);
	if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS)
	{
		fprintf(stderr, "bench-cairo: %s\n", cairo_status_to_string(cairo_surface_status(surface)));
		rc = 1;
	}
	cairo_surface_destroy(surface);
	cairo_font_face_destroy(cf);
	hb_buffer_destroy(c.buf);
	hb_font_destroy(c.hb);
	hb_face_destroy(hb_face);
	hb_blob_destroy(blob);
	FT_Done_Face(face);
	FT_Done_FreeType(ft);
	return rc;
}
