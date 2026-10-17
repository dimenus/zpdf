#include <stdint.h>
#include <stddef.h>

#include "kb_text_shape.h"

// Every kb allocation in zpdf lives exactly as long as the font or the shape
// context that made it: kb never frees while a context is alive (its five
// context arenas are freed only by kbts_DestroyShapeContext, and ShapeBegin
// only moves scratch blocks to kb's own free list). So Zig backs each bridge
// with an ArenaAllocator and kb's FREE is a no-op; the arena frees in bulk.
typedef void *kbshim_alloc_fn(void *user_data, uint32_t size);

typedef struct kbshim_allocator_bridge {
  kbshim_alloc_fn *alloc;
  void *user_data;
} kbshim_allocator_bridge;

// Lives in the font arena. `context` is created on the first shape and reused,
// because kb caches shape configs per (font, script, language) inside the
// context (kbts__FindOrCreateShapeConfig). It is NULL before the first shape
// and after any failed shape: kb errors are sticky ("Once a context is tagged
// with an error, most operations on it will do nothing"), so a failed context
// is dropped and Zig frees the context arena before the next one is made.
//
// `variation_vector` and `variation_normalized` are the font's instance (see
// kbshim_font_set_instance). They are NULL for a font with no axes.
typedef struct kbshim_font_handle {
  kbts_font font;
  kbshim_allocator_bridge *context_bridge;
  kbts_shape_context *context;
  int axis_count;
  float *variation_vector;
  kbts_s16 *variation_normalized;
} kbshim_font_handle;

typedef struct kbshim_flat_glyph {
  uint16_t id;
  uint16_t _reserved0;
  uint32_t cluster;
  int32_t advance_x;
  int32_t advance_y;
  int32_t offset_x;
  int32_t offset_y;
} kbshim_flat_glyph;

typedef struct kbshim_flat_run {
  uint32_t direction;
  uint32_t script;
  uint32_t glyph_start;
  uint32_t glyph_count;
  // The paragraph direction kb resolved (from the text when the caller gave
  // KBTS_DIRECTION_DONT_KNOW); zpdf orders the runs of the line with it.
  uint32_t paragraph_direction;
} kbshim_flat_run;

typedef int kbshim_emit_glyph_fn(void *user_data, const kbshim_flat_glyph *glyph);
typedef int kbshim_emit_run_fn(void *user_data, const kbshim_flat_run *run);

_Static_assert(sizeof(kbshim_flat_glyph) == 24, "kbshim_flat_glyph size drift");
_Static_assert(sizeof(kbshim_flat_run) == 20, "kbshim_flat_run size drift");

static void kbshim_allocator_trampoline(void *data, kbts_allocator_op *op) {
  kbshim_allocator_bridge *bridge = (kbshim_allocator_bridge *)data;
  if (op->Kind == KBTS_ALLOCATOR_OP_KIND_ALLOCATE) {
    op->Allocate.Pointer = bridge->alloc(bridge->user_data, op->Allocate.Size);
  }
}

// kb's direct font API (kbts_LoadFont + kbts_PlaceBlob), not kbts_FontFromMemory,
// so the two buffers can have different owners: the blob is used by the font
// until kbts_FreeFont, and the scratch can be freed once PlaceBlob returns.
// A font placed this way has no kb allocator, so kbts_FreeFont frees nothing.
kbts_load_font_error kbshim_font_create(kbshim_allocator_bridge *font_bridge,
                                        kbshim_allocator_bridge *scratch_bridge,
                                        kbshim_allocator_bridge *context_bridge,
                                        void *font_bytes,
                                        int font_bytes_len,
                                        int font_index,
                                        kbshim_font_handle **out_font) {
  *out_font = NULL;
  kbshim_font_handle *handle =
      (kbshim_font_handle *)font_bridge->alloc(font_bridge->user_data, (uint32_t)sizeof(kbshim_font_handle));
  if (handle == NULL) {
    return KBTS_LOAD_FONT_ERROR_OUT_OF_MEMORY;
  }
  kbshim_font_handle zero_handle = {0};
  *handle = zero_handle;
  handle->context_bridge = context_bridge;

  // LoadFont requires a zeroed state.
  kbts_load_font_state state = {0};
  int scratch_size = 0;
  int output_size = 0;
  kbts_load_font_error err =
      kbts_LoadFont(&handle->font, &state, font_bytes, font_bytes_len, font_index, &scratch_size, &output_size);
  if (err == KBTS_LOAD_FONT_ERROR_NEED_TO_CREATE_BLOB) {
    void *scratch = scratch_bridge->alloc(scratch_bridge->user_data, (uint32_t)scratch_size);
    void *output = font_bridge->alloc(font_bridge->user_data, (uint32_t)output_size);
    // PlaceBlob reports OUT_OF_MEMORY itself when either buffer is NULL.
    err = kbts_PlaceBlob(&handle->font, &state, scratch, output);
  }
  if (err != KBTS_LOAD_FONT_ERROR_NONE) {
    return err;
  }
  if ((handle->font.Blob == NULL) || !kbts_FontIsValid(&handle->font)) {
    return KBTS_LOAD_FONT_ERROR_INVALID_FONT;
  }

  *out_font = handle;
  return KBTS_LOAD_FONT_ERROR_NONE;
}

int kbshim_font_axis_count(kbshim_font_handle *font) {
  int axis_count = 0;
  kbts_GetVariationInfo(&font->font, &axis_count, 0);
  return axis_count;
}

// Returns 0 when [axis_index] is out of range.
int kbshim_font_axis_info(kbshim_font_handle *font,
                          int axis_index,
                          uint32_t *tag,
                          float *minimum,
                          float *default_value,
                          float *maximum,
                          int *hidden) {
  kbts_variation_axis_info info;
  if (!kbts_GetVariationAxisInfo(&font->font, axis_index, &info)) {
    return 0;
  }
  *tag = info.Tag;
  *minimum = info.MinimumValue;
  *default_value = info.DefaultValue;
  *maximum = info.MaximumValue;
  *hidden = (info.Flags & KBTS_VARIATION_AXIS_FLAG_HIDDEN) != 0;
  return 1;
}

// Fixes the font's instance before its first shape. [vector] holds one user
// coordinate per axis, in fvar order; kb normalizes it once, here, into
// [normalized]. Both buffers are the caller's, at least axis_count long, and
// must outlive the font. The same [vector] is what the shape context gets
// (kbts_ShapeSetFontVariationVector), so the context normalizes the same
// floats with the same function, and its advances and GPOS deltas are those of
// [normalized]: the vector kbshim_glyph_advance_x passes to kb.
void kbshim_font_set_instance(kbshim_font_handle *font, float *vector, kbts_s16 *normalized) {
  font->axis_count = kbshim_font_axis_count(font);
  font->variation_vector = vector;
  font->variation_normalized = normalized;
  kbts_NormalizeVariationVector(&font->font, vector, normalized);
}

// The advance shaping gives [glyph_id] before GPOS, in font units, at the
// font's instance.
int32_t kbshim_glyph_advance_x(kbshim_font_handle *font, uint32_t glyph_id) {
  return kbts_GetGlyphAdvanceX(&font->font, glyph_id, font->variation_normalized);
}

// kbts_FontMetric for [tag] (four bytes in file order, read little-endian as
// KBTS_FOURCC makes them) at [vector], one user coordinate per axis.
float kbshim_font_metric(kbshim_font_handle *font, uint32_t tag, float *vector) {
  return kbts_FontMetric(&font->font, tag, vector);
}

static void kbshim_drop_context(kbshim_font_handle *font) {
  if (font->context != NULL) {
    kbts_DestroyShapeContext(font->context);
    font->context = NULL;
  }
}

void kbshim_font_destroy(kbshim_font_handle *font) {
  kbshim_drop_context(font);
  kbts_FreeFont(&font->font);
}

int kbshim_font_has_context(const kbshim_font_handle *font) {
  return font->context != NULL;
}

// One shaping pass (ShapeBegin .. ShapeEnd, then every run) on the font's
// long-lived context. ShapeBegin resets the scratch arena and the implicit user
// id counter, so cluster ids restart at 0 for every call. On any failure, kb's
// or an emit callback's, the context is dropped; the caller must then free the
// context arena before shaping again.
kbts_shape_error kbshim_shape_utf8(kbshim_font_handle *font,
                                   const char *utf8,
                                   int utf8_len,
                                   uint32_t paragraph_direction,
                                   uint32_t language,
                                   kbshim_emit_glyph_fn *emit_glyph,
                                   kbshim_emit_run_fn *emit_run,
                                   void *emit_user_data) {
  kbts_shape_error err = KBTS_SHAPE_ERROR_NONE;
  if (font->context == NULL) {
    font->context = kbts_CreateShapeContext(kbshim_allocator_trampoline, font->context_bridge);
    if (font->context == NULL) {
      return KBTS_SHAPE_ERROR_OUT_OF_MEMORY;
    }
    // kb's docs: "A [return value] of 0 means that the stack has run out of
    // space", i.e. an allocation failed. At pin 853dc2b kb returns 0 there
    // without setting the context error (t-3183), so check both.
    kbts_u32 context_font = 0;
    kbts_font *pushed = kbts_ShapePushFont2(font->context, &font->font, NULL, 0, &context_font);
    err = kbts_ShapeError(font->context);
    if ((pushed == NULL) && (err == KBTS_SHAPE_ERROR_NONE)) {
      err = KBTS_SHAPE_ERROR_OUT_OF_MEMORY;
    }
    // The push set every axis to its default; the instance replaces them all.
    // It returns 0 only when the handle names no font, which a push that
    // succeeded cannot give.
    if ((err == KBTS_SHAPE_ERROR_NONE) && (font->axis_count > 0) &&
        !kbts_ShapeSetFontVariationVector(font->context, context_font, font->variation_vector)) {
      err = KBTS_SHAPE_ERROR_INVALID_FONT;
    }
    if (err != KBTS_SHAPE_ERROR_NONE) {
      kbshim_drop_context(font);
      return err;
    }
  }
  kbts_shape_context *context = font->context;

  kbts_ShapeBegin(context, paragraph_direction, language);
  kbts_ShapeUtf8(context, utf8, utf8_len, KBTS_USER_ID_GENERATION_MODE_CODEPOINT_INDEX);
  kbts_ShapeEnd(context);

  if (err == KBTS_SHAPE_ERROR_NONE) {
    kbts_run run;
    uint32_t glyph_index = 0;

    while (kbts_ShapeRun(context, &run)) {
      // kbts__ShapeRun can copy a scratchpad error (e.g. TOO_MANY_OPERATIONS)
      // onto Context->Error and still return 1 with the run filled in. Do not
      // emit that run: a later emit OOM would hide the real shape error.
      err = kbts_ShapeError(context);
      if (err != KBTS_SHAPE_ERROR_NONE) {
        break;
      }

      uint32_t run_start = glyph_index;
      kbts_glyph *glyph = NULL;
      while (kbts_GlyphIteratorNext(&run.Glyphs, &glyph)) {
        kbshim_flat_glyph flat;
        flat.id = glyph->Id;
        flat._reserved0 = 0;
        flat.cluster = (uint32_t)glyph->UserIdOrCodepointIndex;
        flat.advance_x = glyph->AdvanceX;
        flat.advance_y = glyph->AdvanceY;
        flat.offset_x = glyph->OffsetX;
        flat.offset_y = glyph->OffsetY;
        if (!emit_glyph(emit_user_data, &flat)) {
          err = KBTS_SHAPE_ERROR_OUT_OF_MEMORY;
          break;
        }
        glyph_index += 1;
      }
      if (err != KBTS_SHAPE_ERROR_NONE) {
        break;
      }

      kbshim_flat_run flat_run;
      flat_run.direction = run.Direction;
      flat_run.script = run.Script;
      flat_run.glyph_start = run_start;
      flat_run.glyph_count = glyph_index - run_start;
      flat_run.paragraph_direction = run.ParagraphDirection;
      if (!emit_run(emit_user_data, &flat_run)) {
        err = KBTS_SHAPE_ERROR_OUT_OF_MEMORY;
        break;
      }
    }

    if (err == KBTS_SHAPE_ERROR_NONE) {
      err = kbts_ShapeError(context);
    }
  }

  if (err != KBTS_SHAPE_ERROR_NONE) {
    kbshim_drop_context(font);
  }
  return err;
}
