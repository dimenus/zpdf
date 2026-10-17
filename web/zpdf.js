// zpdf in the browser, in two layers.
//
// High level, one call each, every call on a fresh wasm instance (a bad font in one call
// cannot touch another):
//   const module = await WebAssembly.compileStreaming(fetch("zpdf.wasm")); // or the raw bytes
//   const pdf = await textToPdf(module, fontBytes, "office AVA", { wght: 700 });
//   const axes = await fontAxes(module, variableFontBytes);
//
// Low level, one long-lived instance and handles, for drawing many times:
//   const zpdf = await Zpdf.create(module);
//   const font = zpdf.openFont(fontBytes, { variations: { wght: 700 } });
//   drawText(canvas.getContext("2d"), font, "office AVA", 72, 100, 24);  // also high level
//   const doc = zpdf.newDocument();                  // { compress: false } for plain streams
//   const page = doc.beginPage(612, 792);              // one page open at a time
//   doc.drawText(page, doc.addFont(font), 24, 72, 720, BLACK, "office AVA");
//   doc.fillRect(page, 72, 600, 100, 50, { r: 0.9, g: 0.9, b: 0.9 }); // also drawLine, strokeRect
//   doc.endPage(page);                                 // writes the page, frees its drawing
//   const pdfBytes = doc.finish();                     // fonts, page tree, catalog, xref
//   doc.close(); font.close();
//
// Rules for the low level:
//   - Every object must be closed; zpdf.liveBytes() shows what is still allocated.
//     A font added to a document stays usable by the document after font.close().
//   - A font's instance (its variations) is fixed when it opens. Another instance is
//     another openFont; opening is cheap.
//   - A handle belongs to its Zpdf; passing it to another throws TypeError.
//   - A document is written page by page: endPage writes the page and frees its drawing,
//     so memory follows one page, not the document. A page cannot be drawn on after
//     endPage. finish returns the PDF once; later calls on the document throw
//     DocumentFinished, and after a failed endPage or finish they throw DocumentFailed.
//   - If any call traps (a Zig safety check or kb's undefined behaviour), the instance is
//     retired: that call throws an Error with code "Trapped" and the panic message, and
//     every later call on the Zpdf or its objects throws code "Retired". Make a new Zpdf.
//     A trapped wasm instance is never reused: its state is unknown, and it keeps the
//     stack the trap left behind.
//   - Results are copies; none is a view into wasm memory.
//   - Errors from zpdf throw an Error whose message names the zpdf error, for example
//     "zpdf_font_open failed: InvalidFont (-3)"; `error.code` is the name and
//     `error.zpdfCode` the number.
//
// Arguments:
//   - fontBytes: a whole TrueType/OpenType file (ArrayBuffer / Uint8Array). openFont
//     takes { index } for a face of a collection (default 0).
//   - variations: an object from axis tag to value in the axis's own units, as
//     hb-shape --variations takes them ({ wght: 700 }); {} for a static font or the
//     default instance. A tag is 1 to 4 printable ASCII characters, padded with spaces.
//     A tag the font has no axis for is ignored, a value outside the axis range is
//     clamped, a value that is not finite throws InvalidNumber, and a font with an avar
//     version 2 table throws UnsupportedAvarVersion when variations are given.
//   - text: a JS string, sent as UTF-8. direction: "ltr", "rtl", or omitted (from the text).
//   - textToPdf draws one line at 24 pt at x=72, y=720 on a US Letter page (612 x 792 pt).
//
// The protocol under all this is written in src/abi.zig. Each Zpdf holds one context.

// Same table as error_codes in src/abi.zig; web/test/errors.test.js fails if they differ.
export const ERROR_NAMES = new Map([
  [-1, "OutOfMemory"],
  [-2, "InvalidUtf8"],
  [-3, "InvalidFont"],
  [-4, "TooManyOperations"],
  [-5, "TooManyCids"],
  [-6, "UnsupportedShaping"],
  [-7, "UnsupportedFontFormat"],
  [-8, "InvalidPage"],
  [-9, "InvalidNumber"],
  [-10, "WriteFailed"],
  [-11, "UnsupportedAvarVersion"],
  [-12, "DuplicateVariationTag"],
  [-13, "InvalidVariation"],
  [-14, "InvalidHandle"],
  [-15, "TooManyHandles"],
  [-16, "InvalidDirection"],
  [-17, "FontMismatch"],
  [-18, "PageOpen"],
  [-19, "DocumentFinished"],
  [-20, "DocumentFailed"],
  [-21, "NotWinAnsi"],
  [-22, "InvalidColor"],
  [-23, "InvalidLater"],
  [-24, "LaterDrawn"],
  [-25, "LaterNotDrawn"],
  [-26, "Malformed"],
  [-27, "Encrypted"],
  [-28, "UnsupportedFilter"],
  [-29, "UnsupportedFont"],
  [-30, "TooDeep"],
  [-31, "TooLarge"],
  [-32, "InvalidPointer"],
  [-33, "ContextBusy"],
  [-34, "BuffersOutstanding"],
  [-35, "SinkFailed"],
  [-36, "NotEmbedded"],
  [-127, "Unknown"],
]);

// The 12 standard fonts by their PDF names, in the order of StandardFont in src/pdf.zig
// (web/test/errors.test.js checks it).
export const STANDARD_FONTS = [
  "Helvetica",
  "Helvetica-Bold",
  "Helvetica-Oblique",
  "Helvetica-BoldOblique",
  "Times-Roman",
  "Times-Bold",
  "Times-Italic",
  "Times-BoldItalic",
  "Courier",
  "Courier-Bold",
  "Courier-Oblique",
  "Courier-BoldOblique",
];

const DIRECTIONS = new Map([[undefined, 0], ["ltr", 1], ["rtl", 2]]);
const PATH_KINDS = ["move", "line", "quad", "close"];

function toBytes(value, what) {
  if (value instanceof Uint8Array) {
    return value;
  }
  if (value instanceof ArrayBuffer) {
    return new Uint8Array(value);
  }
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  throw new TypeError(`${what} must be an ArrayBuffer or a typed array`);
}

export const BLACK = Object.freeze({ r: 0, g: 0, b: 0 });

// A colour's components for the wasm call. Their range is checked by zpdf (InvalidColor).
function rgb(color) {
  if (color === null || typeof color !== "object" || ![color.r, color.g, color.b].every((v) => typeof v === "number")) {
    throw new TypeError("color must be { r, g, b } with numbers from 0 to 1");
  }
  return [color.r, color.g, color.b];
}

function direction(options) {
  const d = DIRECTIONS.get(options?.direction);
  if (d === undefined) {
    throw new TypeError(`direction must be "ltr", "rtl" or omitted, not ${JSON.stringify(options.direction)}`);
  }
  return d;
}

// The wire form of `variations`: 8 bytes each, the 4 tag bytes and a little-endian f32.
// Exported for web/test/.
export function variationRecords(variations) {
  if (variations === null || typeof variations !== "object" || Array.isArray(variations)) {
    throw new TypeError("variations must be an object such as { wght: 700 }, or {}");
  }
  const entries = Object.entries(variations);
  const records = new Uint8Array(entries.length * 8);
  const view = new DataView(records.buffer);
  entries.forEach(([tag, value], i) => {
    if (!/^[\x21-\x7e]{1,4}$/.test(tag)) {
      throw new TypeError(`variation tag ${JSON.stringify(tag)} must be 1 to 4 printable ASCII characters`);
    }
    if (typeof value !== "number") {
      throw new TypeError(`variation ${tag} must be a number`);
    }
    const padded = tag.padEnd(4, " ");
    for (let j = 0; j < 4; j += 1) {
      records[i * 8 + j] = padded.charCodeAt(j);
    }
    view.setFloat32(i * 8 + 4, value, true);
  });
  return records;
}

// zpdf_font_axes' wire form, 20 bytes per axis. Exported for web/test/.
export function parseAxisRecords(bytes) {
  if (bytes.length % 20 !== 0) {
    throw new Error(`axis records: ${bytes.length} bytes is not a multiple of 20`);
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const axes = [];
  for (let at = 0; at < bytes.length; at += 20) {
    axes.push({
      tag: String.fromCharCode(...bytes.subarray(at, at + 4)).trimEnd(),
      min: view.getFloat32(at + 4, true),
      default: view.getFloat32(at + 8, true),
      max: view.getFloat32(at + 12, true),
      hidden: (view.getUint32(at + 16, true) & 1) !== 0,
    });
  }
  return axes;
}

function zpdfError(fn, rc) {
  const name = ERROR_NAMES.get(rc) ?? "Unknown";
  const error = new Error(`${fn} failed: ${name} (${rc})`);
  error.code = name;
  error.zpdfCode = rc;
  return error;
}

// One wasm instance and the objects open in it.
export class Zpdf {
  #e;
  #ctx;
  #retired = false;

  constructor(instance) {
    this.#e = instance.exports;
    this.#ctx = this.#invoke("zpdf_context_new", []) >>> 0;
    if (this.#ctx === 0) {
      throw zpdfError("zpdf_context_new", -1);
    }
  }

  // `wasm` is a WebAssembly.Module, or the bytes of zpdf.wasm.
  static async create(wasm) {
    const module = wasm instanceof WebAssembly.Module ? wasm : await WebAssembly.compile(toBytes(wasm, "wasm"));
    return new Zpdf(await WebAssembly.instantiate(module, {}));
  }

  get retired() {
    return this.#retired;
  }

  // Throws code "Retired" when an earlier trap retired this Zpdf.
  _live(what) {
    if (this.#retired) {
      const error = new Error(`${what}: this Zpdf was retired by an earlier trap; make a new one`);
      error.code = "Retired";
      throw error;
    }
  }

  // Calls export `fn` with this Zpdf's context first.
  #call(fn, ...args) {
    return this.#invoke(fn, [this.#ctx, ...args]);
  }

  // Calls export `fn`. Any exception out of it retires the instance: the module has no
  // imports, so an exception means wasm frames were unwound without returning, which
  // leaves its state unknown and loses their stack. That includes a RangeError from the
  // engine's own stack limit, not only a RuntimeError. The exports are dropped too, so
  // nothing here keeps the dead instance's memory alive.
  #invoke(fn, args) {
    this._live(fn);
    try {
      return this.#e[fn](...args);
    } catch (cause) {
      let panic = "";
      try {
        const len = this.#e.zpdf_wasm_panic_len() >>> 0;
        if (len !== 0) {
          panic = new TextDecoder().decode(new Uint8Array(this.#e.memory.buffer, this.#e.zpdf_wasm_panic_ptr() >>> 0, len));
        }
      } catch {
        // The message is a bonus; the trap is what is reported.
      }
      this.#retired = true;
      this.#e = null;
      const error = new Error(`${fn} trapped: ${panic || "no Zig panic message"} (${cause?.message ?? cause})`, { cause });
      error.code = "Trapped";
      error.panic = panic;
      throw error;
    }
  }

  // A pointer or size from wasm: an i32 to JS, read back as the u32 it is.
  #callU(fn, ...args) {
    return this.#call(fn, ...args) >>> 0;
  }

  #memory() {
    return this.#e.memory.buffer;
  }

  // Gives back a buffer zpdf_alloc or an output made.
  #free(ptr, len) {
    const rc = this.#call("zpdf_free", ptr, len);
    if (rc !== 0) {
      throw zpdfError("zpdf_free", rc);
    }
  }

  // Copies `inputs` (Uint8Arrays) into wasm memory, runs `body(ptrs, scratch)` where
  // scratch is 8 bytes for outputs, then frees everything it allocated (not on a
  // retired instance, which is dropped whole). An empty input is a null pointer.
  _with(inputs, body) {
    const allocated = [];
    const alloc = (len) => {
      if (len === 0) {
        return 0;
      }
      const ptr = this.#callU("zpdf_alloc", len);
      if (ptr === 0) {
        throw zpdfError("zpdf_alloc", -1);
      }
      allocated.push([ptr, len]);
      return ptr;
    };
    try {
      const ptrs = inputs.map((bytes) => {
        const ptr = alloc(bytes.length);
        if (bytes.length !== 0) {
          new Uint8Array(this.#memory(), ptr, bytes.length).set(bytes);
        }
        return ptr;
      });
      return body(ptrs, alloc(8));
    } finally {
      for (const [ptr, len] of allocated) {
        if (this.#retired) {
          break;
        }
        this.#free(ptr, len);
      }
    }
  }

  // Calls `fn` with `args` plus a u32 out pointer; returns the u32.
  _u32(fn, inputs, args) {
    return this._with(inputs, (ptrs, out) => {
      const rc = this.#call(fn, ...args(ptrs), out);
      if (rc !== 0) {
        throw zpdfError(fn, rc);
      }
      return new DataView(this.#memory()).getUint32(out, true);
    });
  }

  // Calls `fn` with `args` plus (out_ptr, out_len); returns a copy of the buffer it gave.
  _bytes(fn, inputs, args) {
    return this._with(inputs, (ptrs, out) => {
      const rc = this.#call(fn, ...args(ptrs), out, out + 4);
      if (rc !== 0) {
        throw zpdfError(fn, rc);
      }
      const view = new DataView(this.#memory());
      const ptr = view.getUint32(out, true);
      const len = view.getUint32(out + 4, true);
      if (len === 0) {
        return new Uint8Array(0);
      }
      // The output is freed even when the copy fails (a JS allocation can).
      try {
        return new Uint8Array(this.#memory(), ptr, len).slice();
      } finally {
        if (!this.#retired) {
          this.#free(ptr, len);
        }
      }
    });
  }

  _status(fn, inputs, args) {
    this._with(inputs, (ptrs) => {
      const rc = this.#call(fn, ...args(ptrs));
      if (rc !== 0) {
        throw zpdfError(fn, rc);
      }
    });
  }

  // Internal: calls any export, with no context, through the trap handling above. The
  // browser test uses it for zpdf_wasm_test_panic, which only the test build has.
  _call(fn, ...args) {
    return this.#invoke(fn, args);
  }

  // The context's live bytes, less the 8-byte output scratch (_with) this call itself holds
  // while zpdf counts.
  liveBytes() {
    return this._u32("zpdf_live_bytes", [], () => []) - 8;
  }

  openFont(fontBytes, options = {}) {
    const font = toBytes(fontBytes, "fontBytes");
    const records = variationRecords(options.variations ?? {});
    const index = options.index ?? 0;
    if (!Number.isInteger(index)) {
      throw new TypeError("index must be an integer");
    }
    const handle = this._u32("zpdf_font_open", [font, records], ([f, v]) => [f, font.length, index, v, records.length]);
    return new ZpdfFont(this, handle);
  }

  // options: { compress } (default true: Flate streams).
  newDocument(options = {}) {
    return new ZpdfDocument(this, this._u32("zpdf_doc_new", [], () => [options.compress === false ? 0 : 1]));
  }
}

function checkOwner(zpdf, object, what) {
  if (!(object instanceof ZpdfFont) || object.zpdf !== zpdf) {
    throw new TypeError(`${what} must be a font opened by the same Zpdf`);
  }
}

export class ZpdfFont {
  #paths = new Map();

  constructor(zpdf, handle) {
    this.zpdf = zpdf;
    this.handle = handle;
  }

  unitsPerEm() {
    return this.zpdf._u32("zpdf_font_units_per_em", [], () => [this.handle]);
  }

  axes() {
    return parseAxisRecords(this.zpdf._bytes("zpdf_font_axes", [], () => [this.handle]));
  }

  // { advance: { x, y }, glyphs: [{ id, cluster, x, y }] }: font units, y up; each glyph's
  // origin from the line's start, the positions the PDF uses. cluster is a codepoint index.
  shape(text, options = {}) {
    if (typeof text !== "string") {
      throw new TypeError("text must be a string");
    }
    const utf8 = new TextEncoder().encode(text);
    const bytes = this.zpdf._bytes("zpdf_font_shape", [utf8], ([t]) => [this.handle, t, utf8.length, direction(options)]);
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const glyphs = [];
    for (let at = 8; at < bytes.length; at += 16) {
      glyphs.push({
        id: view.getUint32(at, true),
        cluster: view.getUint32(at + 4, true),
        x: view.getInt32(at + 8, true),
        y: view.getInt32(at + 12, true),
      });
    }
    return { advance: { x: view.getInt32(0, true), y: view.getInt32(4, true) }, glyphs };
  }

  // Glyph `id`'s outline: [{ kind: "move"|"line"|"quad"|"close", ... }], font units, y up,
  // nonzero fill. move and line have x, y; quad has cx, cy, x, y.
  glyphPath(id) {
    const bytes = this.zpdf._bytes("zpdf_font_glyph_path", [], () => [this.handle, id]);
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const commands = [];
    for (let at = 0; at < bytes.length; at += 40) {
      const kind = PATH_KINDS[view.getUint32(at, true)];
      const v = [0, 1, 2, 3].map((j) => view.getFloat64(at + 8 + j * 8, true));
      if (kind === "quad") {
        commands.push({ kind, cx: v[0], cy: v[1], x: v[2], y: v[3] });
      } else if (kind === "close") {
        commands.push({ kind });
      } else {
        commands.push({ kind, x: v[0], y: v[1] });
      }
    }
    return commands;
  }

  // The glyph as a Path2D in font units, y up; kept per glyph for the font's life.
  path2D(id) {
    this.zpdf._live("path2D");
    let path = this.#paths.get(id);
    if (path === undefined) {
      path = new Path2D();
      for (const c of this.glyphPath(id)) {
        if (c.kind === "move") {
          path.moveTo(c.x, c.y);
        } else if (c.kind === "line") {
          path.lineTo(c.x, c.y);
        } else if (c.kind === "quad") {
          path.quadraticCurveTo(c.cx, c.cy, c.x, c.y);
        } else {
          path.closePath();
        }
      }
      this.#paths.set(id, path);
    }
    return path;
  }

  close() {
    this.#paths.clear();
    this.zpdf._status("zpdf_font_close", [], () => [this.handle]);
  }
}

export class ZpdfDocument {
  constructor(zpdf, handle) {
    this.zpdf = zpdf;
    this.handle = handle;
  }

  // Returns the font's id in this document.
  addFont(font) {
    checkOwner(this.zpdf, font, "font");
    return this.zpdf._u32("zpdf_doc_add_font", [], () => [this.handle, font.handle]);
  }

  // One of STANDARD_FONTS, named and not embedded: no shaping, and only WinAnsi text
  // (Latin-1 and a few more); any other character throws NotWinAnsi. Returns its id.
  addStandardFont(name) {
    const index = STANDARD_FONTS.indexOf(name);
    if (index < 0) {
      throw new TypeError(`standard font must be one of ${STANDARD_FONTS.join(", ")}`);
    }
    const font = this.zpdf._u32("zpdf_font_open_standard", [], () => [index]);
    try {
      return this.zpdf._u32("zpdf_doc_add_font", [], () => [this.handle, font]);
    } finally {
      this.zpdf._status("zpdf_font_close", [], () => [font]);
    }
  }

  // Opens the next page, in points; throws PageOpen while another page is open.
  beginPage(width, height) {
    return this.zpdf._u32("zpdf_doc_begin_page", [], () => [this.handle, width, height]);
  }

  endPage(page) {
    this.zpdf._status("zpdf_doc_end_page", [], () => [this.handle, page]);
  }

  // One line at (x, y) in points, PDF space (y up from the page's bottom), in `color`
  // ({ r, g, b }, each 0 to 1; BLACK is one).
  drawText(page, fontId, size, x, y, color, text, options = {}) {
    if (typeof text !== "string") {
      throw new TypeError("text must be a string");
    }
    const [r, g, b] = rgb(color);
    const utf8 = new TextEncoder().encode(text);
    this.zpdf._status("zpdf_doc_draw_text", [utf8], ([t]) => [this.handle, page, fontId, size, x, y, r, g, b, t, utf8.length, direction(options)]);
  }

  // Reserves a place on the open page, at this point of its drawing, for text drawn later
  // with drawTextLater, such as "Page 3 of 12" once the page count is known. Returns its id.
  // Every place must be drawn before finish (else LaterNotDrawn).
  reserveLater(page) {
    return this.zpdf._u32("zpdf_doc_reserve_later", [], () => [this.handle, page]);
  }

  // drawText for a reserveLater place, on that place's page; once per place (LaterDrawn).
  drawTextLater(later, fontId, size, x, y, color, text, options = {}) {
    if (typeof text !== "string") {
      throw new TypeError("text must be a string");
    }
    const [r, g, b] = rgb(color);
    const utf8 = new TextEncoder().encode(text);
    this.zpdf._status("zpdf_doc_draw_text_later", [utf8], ([t]) => [this.handle, later, fontId, size, x, y, r, g, b, t, utf8.length, direction(options)]);
  }

  // A straight line, `width` points wide with square-cut ends, centred on the line.
  drawLine(page, x1, y1, x2, y2, width, color) {
    this.zpdf._status("zpdf_doc_draw_line", [], () => [this.handle, page, x1, y1, x2, y2, width, ...rgb(color)]);
  }

  // (x, y) is the rectangle's bottom-left corner.
  fillRect(page, x, y, width, height, color) {
    this.zpdf._status("zpdf_doc_fill_rect", [], () => [this.handle, page, x, y, width, height, ...rgb(color)]);
  }

  strokeRect(page, x, y, width, height, lineWidth, color) {
    this.zpdf._status("zpdf_doc_stroke_rect", [], () => [this.handle, page, x, y, width, height, lineWidth, ...rgb(color)]);
  }

  // The PDF. Every page must be ended first.
  finish() {
    return this.zpdf._bytes("zpdf_doc_finish", [], () => [this.handle]);
  }

  close() {
    this.zpdf._status("zpdf_doc_close", [], () => [this.handle]);
  }
}

// Fills `text` shaped with `font` on a canvas: the baseline starts at (x, y) in canvas
// pixels (y down), at `size` pixels per em, with the context's current fillStyle. The
// glyphs are the font's outlines at its instance, placed as the PDF places them.
export function drawText(ctx, font, text, x, y, size, options = {}) {
  const scale = size / font.unitsPerEm();
  const line = font.shape(text, options);
  // Every path first: one that fails (a CFF font, a trap) then leaves the canvas as it was.
  const paths = line.glyphs.map((glyph) => font.path2D(glyph.id));
  line.glyphs.forEach((glyph, i) => {
    ctx.save();
    try {
      ctx.translate(x + glyph.x * scale, y - glyph.y * scale);
      ctx.scale(scale, -scale);
      ctx.fill(paths[i], "nonzero");
    } finally {
      ctx.restore();
    }
  });
  return line.advance.x * scale;
}

export async function textToPdf(wasm, fontBytes, text, variations) {
  if (typeof text !== "string") {
    throw new TypeError("text must be a string");
  }
  // Required here (pass {} for none), as before openFont made it optional.
  variationRecords(variations);
  const zpdf = await Zpdf.create(wasm);
  const font = zpdf.openFont(fontBytes, { variations });
  const doc = zpdf.newDocument();
  const page = doc.beginPage(612, 792);
  doc.drawText(page, doc.addFont(font), 24, 72, 720, BLACK, text);
  doc.endPage(page);
  return doc.finish();
}

export async function fontAxes(wasm, fontBytes) {
  const zpdf = await Zpdf.create(wasm);
  return zpdf.openFont(fontBytes).axes();
}
