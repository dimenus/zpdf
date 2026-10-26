// Runs zpdf.wasm in headless Chromium through web/index.html, and checks with pdf.js
// that the PDF it makes draws ink.
//
//   zig build web-test          builds the wasm, then runs this with the env set
//   ZPDF_WASM=<zpdf.wasm> ZPDF_TEST_WASM=<zpdf-test.wasm> ZPDF_FONTS=<harfbuzz>/test/subset/data/fonts bun test   (from web/)
import { afterAll, beforeAll, expect, test } from "bun:test";
import { chromium } from "playwright-core";
import { startServer } from "../serve.js";

const wasm_path = process.env.ZPDF_WASM;
const test_wasm_path = process.env.ZPDF_TEST_WASM;
const font_dir = process.env.ZPDF_FONTS;
if (!wasm_path || !test_wasm_path || !font_dir) {
  throw new Error("set ZPDF_WASM (zpdf.wasm), ZPDF_TEST_WASM (zpdf-test.wasm) and ZPDF_FONTS (harfbuzz test/subset/data/fonts)");
}

// One line of 24 pt text at scale 1 gives a few hundred dark pixels (the console line of
// each test prints the count); a blank page gives none. The floor sits well below the
// thinnest script here (Arabic) and well above zero.
const MIN_INK = 100;
const MAX_BLANK_INK = 10;

const CASES = [
  { font: "Roboto-Regular.ttf", text: "office AVA" },
  { font: "NotoSansDevanagari-Regular.ttf", text: "हिन्दी क्षि" },
  { font: "Amiri-Regular.ttf", text: "بسم الله" },
  { font: "NotoIKEAHebrewLatin-Regular.ttf", text: "שָׁלוֹם" },
];

let server;
let browser;
let page;
// An uncaught error on the page is a crash, and fails whatever test is running.
const page_errors = [];

beforeAll(async () => {
  server = startServer(wasm_path, font_dir, 0, test_wasm_path);
  browser = await chromium.launch();
  page = await browser.newPage();
  page.on("pageerror", (error) => page_errors.push(error));
  await page.goto(server.url.href);
  await page.waitForSelector("body[data-ready=true]", { timeout: 15000 });
});

afterAll(async () => {
  await browser?.close();
  server?.stop(true);
});

// Makes the PDF and renders it in the page. Returns what the checks need, not the bytes.
async function makeInBrowser(fontName, text, variations) {
  return page.evaluate(
    async ({ fontName, text, variations }) => {
      const response = await fetch(`/fonts/${encodeURIComponent(fontName)}`);
      if (!response.ok) {
        throw new Error(`font fetch ${fontName}: ${response.status}`);
      }
      const font = new Uint8Array(await response.arrayBuffer());
      const z = window.zpdfPage;
      const pdf = await z.textToPdf(z.wasmModule, font, text, variations);
      const canvas = document.createElement("canvas");
      await z.renderPdf(pdf, canvas, 1);
      const decode = (bytes) => String.fromCharCode(...bytes);
      // The CIDFont dictionary is not a stream, so its /W is plain text even when
      // the streams are compressed.
      const latin1 = new TextDecoder("latin1").decode(pdf);
      const widths = latin1.match(/\/W \[ 0 \[([-0-9 ]*)\] \]/);
      return {
        fontBytes: font.length,
        pdfBytes: pdf.length,
        head: decode(pdf.subarray(0, 8)),
        tail: decode(pdf.subarray(pdf.length - 16)),
        width: canvas.width,
        height: canvas.height,
        ink: z.darkPixels(canvas),
        widths: widths === null ? null : widths[1],
      };
    },
    { fontName, text, variations },
  );
}

function expectPdf(result) {
  expect(result.head).toBe("%PDF-1.7");
  expect(result.tail.trimEnd().endsWith("%%EOF")).toBe(true);
  // US Letter at scale 1.
  expect([result.width, result.height]).toEqual([612, 792]);
}

for (const { font, text } of CASES) {
  test(`${font}: "${text}" renders ink`, async () => {
    const result = await makeInBrowser(font, text, {});
    console.log(`${font}: font ${result.fontBytes} B, pdf ${result.pdfBytes} B, ${result.ink} dark px`);
    expectPdf(result);
    expect(result.ink).toBeGreaterThan(MIN_INK);
    expect(page_errors).toEqual([]);
  });
}

test("empty text renders a blank page, so the ink check can fail", async () => {
  const result = await makeInBrowser("Roboto-Regular.ttf", "", {});
  console.log(`empty text: pdf ${result.pdfBytes} B, ${result.ink} dark px`);
  expectPdf(result);
  expect(result.ink).toBeLessThanOrEqual(MAX_BLANK_INK);
});

// zpdf.wasm reads back what it writes, through its own reader exports: the PDF's streams are
// FlateDecode, so this runs libdeflate as built for wasm32-freestanding (src/libdeflate_impl.c),
// which nothing else here does. The text comes from zpdf_reader_page_text's strings, the last
// strings_len bytes of each page's buffer (zpdf.h, zpdf_text_header).
test("zpdf.wasm's reader reads back the compressed PDF zpdf.wasm writes", async () => {
  const got = await page.evaluate(async () => {
    const response = await fetch(`/fonts/${encodeURIComponent("Roboto-Regular.ttf")}`);
    const font = new Uint8Array(await response.arrayBuffer());
    const z = window.zpdfPage;
    const pdf = await z.textToPdf(z.wasmModule, font, "zpdf reads this back. ".repeat(40), {});
    const { exports: e } = await WebAssembly.instantiate(z.wasmModule, {});
    const check = (code, what) => {
      if (code !== 0) throw new Error(`${what} returned ${code}`);
    };
    const view = () => new DataView(e.memory.buffer);
    const ctx = e.zpdf_context_new();
    const bytes = e.zpdf_alloc(ctx, pdf.length);
    new Uint8Array(e.memory.buffer, bytes, pdf.length).set(pdf);
    const out = e.zpdf_alloc(ctx, 16);
    check(e.zpdf_reader_open(ctx, bytes, pdf.length, out), "zpdf_reader_open");
    const reader = view().getUint32(out, true);
    check(e.zpdf_reader_page_count(ctx, reader, out + 4), "zpdf_reader_page_count");
    const pages = view().getUint32(out + 4, true);
    let strings = "";
    for (let i = 0; i < pages; i++) {
      check(e.zpdf_reader_page_text(ctx, reader, i, out + 8, out + 12), "zpdf_reader_page_text");
      const ptr = view().getUint32(out + 8, true);
      const len = view().getUint32(out + 12, true);
      const strings_len = view().getUint32(ptr + 12, true);
      strings += new TextDecoder().decode(new Uint8Array(e.memory.buffer, ptr + len - strings_len, strings_len));
      check(e.zpdf_free(ctx, ptr, len), "zpdf_free");
    }
    check(e.zpdf_reader_close(ctx, reader), "zpdf_reader_close");
    check(e.zpdf_free(ctx, out, 16), "zpdf_free");
    check(e.zpdf_free(ctx, bytes, pdf.length), "zpdf_free");
    return {
      flate: new TextDecoder("latin1").decode(pdf).includes("/FlateDecode"),
      pages,
      text: strings.replace(/\s+/g, ""),
      freed: e.zpdf_context_free(ctx),
    };
  });
  expect(got.flate).toBe(true);
  expect(got.pages).toBeGreaterThan(0);
  expect(got.text).toContain("zpdfreadsthisback.".repeat(10));
  expect(got.freed).toBe(0);
  expect(page_errors).toEqual([]);
});

test("junk font throws InvalidFont and the page keeps working", async () => {
  const thrown = await page.evaluate(async () => {
    // Fixed seed, so a failure reproduces.
    let seed = 12345;
    const junk = new Uint8Array(4096).map(() => {
      seed = (seed * 1103515245 + 12345) >>> 0;
      return seed >>> 24;
    });
    const z = window.zpdfPage;
    try {
      await z.textToPdf(z.wasmModule, junk, "office", {});
      return null;
    } catch (error) {
      return { message: error.message, code: error.code, zpdfCode: error.zpdfCode };
    }
  });
  console.log(`junk font: ${JSON.stringify(thrown)}`);
  expect(thrown).toEqual({ message: "zpdf_font_open failed: InvalidFont (-3)", code: "InvalidFont", zpdfCode: -3 });

  // The same page, same compiled module, still makes a good PDF afterwards.
  const after = await makeInBrowser("Roboto-Regular.ttf", "office AVA", {});
  expect(after.ink).toBeGreaterThan(MIN_INK);
  expect(page_errors).toEqual([]);
});

test("a variable font at an instance: /W holds the instance's widths, and it renders thin", async () => {
  // Fraunces has 2000 units per em. CID 0 is .notdef, then o, ffi, c, e.
  // hb-shape --no-glyph-names --features=-kern --variations=opsz=144,wght=100 Fraunces.ttf
  //   --unicodes=U+006F,U+0066,U+0066,U+0069,U+0063,U+0065  gives  [47=0+914|478=1+1237|31=4+737|33=5+751]
  // and with no variations [47=0+1247|478=1+2532|31=4+1115|33=5+1120].
  const varied = await makeInBrowser("Fraunces.ttf", "office", { opsz: 144, wght: 100 });
  const plain = await makeInBrowser("Fraunces.ttf", "office", {});
  console.log(`Fraunces opsz=144,wght=100: /W [${varied.widths}], ${varied.ink} dark px; default /W [${plain.widths}], ${plain.ink} dark px`);
  expectPdf(varied);
  expect(varied.widths).toBe("500 457 619 369 376");
  expect(plain.widths).toBe("500 624 1266 558 560");
  expect(varied.ink).toBeGreaterThan(MIN_INK);
  // The embedded outlines are the instance's: wght=100 strokes are a fraction
  // of the default wght=900 ones, so pdf.js (with its own font checks) draws
  // far less ink. With the default outlines at the instance's widths, the two
  // would be close.
  expect(varied.ink).toBeLessThan(plain.ink / 2);
  expect(page_errors).toEqual([]);
});

test("bad variations throw: NaN from zpdf, a bad tag or a missing argument from zpdf.js", async () => {
  const thrown = await page.evaluate(async () => {
    const font = new Uint8Array(await (await fetch("/fonts/Fraunces.ttf")).arrayBuffer());
    const z = window.zpdfPage;
    const attempt = async (variations) => {
      try {
        await z.textToPdf(z.wasmModule, font, "office", variations);
        return null;
      } catch (error) {
        return { name: error.name, message: error.message, code: error.code ?? null };
      }
    };
    return [await attempt({ wght: Number.NaN }), await attempt({ wghtx: 1 }), await attempt(undefined), await attempt({ wght: "700" })];
  });
  console.log(`bad variations: ${JSON.stringify(thrown)}`);
  expect(thrown[0]).toEqual({ name: "Error", message: "zpdf_font_open failed: InvalidNumber (-9)", code: "InvalidNumber" });
  expect(thrown[1].name).toBe("TypeError");
  expect(thrown[2].name).toBe("TypeError");
  expect(thrown[3].name).toBe("TypeError");
  expect(page_errors).toEqual([]);
});

test("fontAxes: Roboto Flex's axes as fontTools reads them, [] for a static font, InvalidFont for junk", async () => {
  const got = await page.evaluate(async () => {
    const z = window.zpdfPage;
    const { fontAxes } = await import("/zpdf.js");
    const bytes = async (name) => new Uint8Array(await (await fetch(`/fonts/${name}`)).arrayBuffer());
    let junk;
    try {
      await fontAxes(z.wasmModule, new Uint8Array(64));
      junk = null;
    } catch (error) {
      junk = error.message;
    }
    return {
      flex: await fontAxes(z.wasmModule, await bytes("RobotoFlex-Variable.ttf")),
      roboto: await fontAxes(z.wasmModule, await bytes("Roboto-Regular.ttf")),
      junk,
    };
  });
  // uv run --with fonttools: [(a.axisTag, a.minValue, a.defaultValue, a.maxValue, a.flags & 1)
  //   for a in TTFont("RobotoFlex-Variable.ttf")["fvar"].axes]
  const want = [
    ["wght", 100, 400, 1000, 0], ["wdth", 25, 100, 151, 0], ["opsz", 8, 14, 144, 0], ["GRAD", -200, 0, 150, 0],
    ["slnt", -10, 0, 0, 0], ["XTRA", 323, 468, 603, 1], ["XOPQ", 27, 96, 175, 1], ["YOPQ", 25, 79, 135, 1],
    ["YTLC", 416, 514, 570, 1], ["YTUC", 528, 712, 760, 1], ["YTAS", 649, 750, 854, 1], ["YTDE", -305, -203, -98, 1],
    ["YTFI", 560, 738, 788, 1],
  ].map(([tag, min, def, max, hidden]) => ({ tag, min, default: def, max, hidden: hidden === 1 }));
  expect(got.flex).toEqual(want);
  expect(got.roboto).toEqual([]);
  expect(got.junk).toBe("zpdf_font_open failed: InvalidFont (-3)");
  expect(page_errors).toEqual([]);
});

// Runs `action` and waits until the page has finished `steps` more steps (a PDF made,
// or an error shown), so a check never reads the result of an earlier action.
async function afterSteps(steps, action) {
  const before = Number((await page.getAttribute("#status", "data-seq")) ?? 0);
  await action();
  await page.waitForFunction((want) => Number(document.getElementById("status").dataset.seq ?? 0) >= want, before + steps, {
    timeout: 15000,
  });
  return page.evaluate(() => ({
    status: document.getElementById("status").textContent,
    isError: document.getElementById("status").className === "error",
    ink: window.zpdfPage.darkPixels(document.getElementById("page")),
    directInk: window.zpdfPage.darkPixels(document.getElementById("direct")),
  }));
}

async function pickFont(name, buffer) {
  await page.setInputFiles("#font", { name, mimeType: "font/ttf", buffer: Buffer.from(buffer) });
}

test("the page UI: picking a font makes the PDF; the button and download link work", async () => {
  await page.fill("#text", "office AVA");
  const roboto = await Bun.file(`${font_dir}/Roboto-Regular.ttf`).bytes();
  const picked = await afterSteps(1, () => pickFont("Roboto-Regular.ttf", roboto));
  console.log(`page UI: ${picked.ink} dark px on the page canvas`);
  expect(picked.status.startsWith("PDF:")).toBe(true);
  expect(picked.ink).toBeGreaterThan(MIN_INK);
  expect(picked.directInk).toBeGreaterThan(MIN_INK);
  // A static font has no sliders.
  expect(await page.locator("#axes input").count()).toBe(0);
  expect(await page.isHidden("#show-hidden-label")).toBe(true);

  const clicked = await afterSteps(1, () => page.click("#make"));
  expect(clicked.status.startsWith("PDF:")).toBe(true);
  const link = await page.evaluate(async () => {
    const a = document.getElementById("download");
    const bytes = new Uint8Array(await (await fetch(a.href)).arrayBuffer());
    return { hidden: a.hidden, head: String.fromCharCode(...bytes.subarray(0, 8)) };
  });
  expect(link).toEqual({ hidden: false, head: "%PDF-1.7" });

  // A junk font shows the error and leaves the page alive; the button then says why.
  const junk = await afterSteps(1, () => pickFont("junk.ttf", "not a font at all"));
  expect(junk).toMatchObject({ status: "zpdf_font_open failed: InvalidFont (-3)", isError: true });
  const after_junk = await afterSteps(1, () => page.click("#make"));
  expect(after_junk).toMatchObject({ status: "Pick a font file first.", isError: true });
  expect(page_errors).toEqual([]);
});

test("the page UI: a variable font gets one slider per shown axis, and moving one redraws the instance", async () => {
  await page.fill("#text", "office");
  const fraunces = await Bun.file(`${font_dir}/Fraunces.ttf`).bytes();
  const at_default = await afterSteps(1, () => pickFont("Fraunces.ttf", fraunces));
  expect(at_default.status.startsWith("PDF:")).toBe(true);
  // Fraunces: opsz 9..144 (default 9), wght 100..900 (900), SOFT 0..100 (0), WONK 0..1 (1); none hidden.
  const sliders = await page.$$eval("#axes input", (inputs) => inputs.map((i) => [i.dataset.tag, i.min, i.max, i.value]));
  expect(sliders).toEqual([
    ["opsz", "9", "144", "9"],
    ["wght", "100", "900", "900"],
    ["SOFT", "0", "100", "0"],
    ["WONK", "0", "1", "1"],
  ]);
  expect(await page.isHidden("#show-hidden-label")).toBe(true);

  // The slider's value goes to zpdf: wght=100 strokes are a fraction of wght=900's.
  const thin = await afterSteps(1, () =>
    page.$eval('#axes input[data-tag="wght"]', (input) => {
      input.value = "100";
      input.dispatchEvent(new Event("input"));
    }),
  );
  console.log(`page UI sliders: Fraunces wght=900 ${at_default.ink} dark px, wght=100 ${thin.ink} dark px`);
  expect(thin.status.startsWith("PDF:")).toBe(true);
  expect(thin.ink).toBeGreaterThan(MIN_INK);
  expect(thin.ink).toBeLessThan(at_default.ink / 2);
  // The canvas view follows the slider too.
  expect(thin.directInk).toBeLessThan(at_default.directInk / 2);

  // A burst of moves during a make ends on the last value: the canvas equals a fresh
  // make at wght=100 after the slider went to 500, 300 and back to 100.
  await page.$eval('#axes input[data-tag="wght"]', (input) => {
    for (const v of ["500", "300", "100"]) {
      input.value = v;
      input.dispatchEvent(new Event("input"));
    }
  });
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("PDF:"), null, { timeout: 15000 });
  await page.waitForFunction(() => window.zpdfPage.isIdle(), null, { timeout: 15000 });
  const burst = await page.evaluate(() => window.zpdfPage.darkPixels(document.getElementById("page")));
  expect(burst).toBe(thin.ink);

  // Roboto Flex: 5 shown axes and 8 hidden ones, shown only on request.
  const flex = await Bun.file(`${font_dir}/RobotoFlex-Variable.ttf`).bytes();
  await afterSteps(1, () => pickFont("RobotoFlex-Variable.ttf", flex));
  const visibleRows = () => page.$$eval("#axes .axis", (rows) => rows.filter((r) => !r.hidden).length);
  expect(await page.locator("#axes input").count()).toBe(13);
  expect(await visibleRows()).toBe(5);
  await page.check("#show-hidden");
  expect(await visibleRows()).toBe(13);
  await page.uncheck("#show-hidden");
  expect(await visibleRows()).toBe(5);
  expect(page_errors).toEqual([]);
});

// How far the direct canvas is from pdf.js's render of the same PDF, both at 4 px per
// point: the summed ink difference over the summed larger ink, over the line's rows.
async function compareDirectWithPdf(fontName, text, variations, shiftX, directVariations, shiftY = 0) {
  return page.evaluate(
    async ({ fontName, text, variations, shiftX, directVariations, shiftY }) => {
      const { Zpdf, drawText, textToPdf } = await import("/zpdf.js");
      const z = window.zpdfPage;
      const bytes = new Uint8Array(await (await fetch(`/fonts/${encodeURIComponent(fontName)}`)).arrayBuffer());
      const pdfCanvas = document.createElement("canvas");
      const SCALE = 4;
      await z.renderPdf(await textToPdf(z.wasmModule, bytes, text, variations), pdfCanvas, SCALE);
      const zpdf = await Zpdf.create(z.wasmModule);
      const font = zpdf.openFont(bytes, { variations: directVariations ?? variations });
      const direct = document.createElement("canvas");
      const W = 612 * SCALE;
      const H = 120 * SCALE;
      direct.width = W;
      direct.height = H;
      const ctx = direct.getContext("2d");
      ctx.fillStyle = "#fff";
      ctx.fillRect(0, 0, W, H);
      ctx.fillStyle = "#000";
      drawText(ctx, font, text, (72 + shiftX) * SCALE, (72 + shiftY) * SCALE, 24 * SCALE);
      font.close();
      const a = pdfCanvas.getContext("2d").getImageData(0, 0, W, H).data;
      const b = ctx.getImageData(0, 0, W, H).data;
      const dark = (d, i) => (0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2]) * (d[i + 3] / 255) + 255 * (1 - d[i + 3] / 255) < 128;
      const ink = (d, i) => 1 - ((0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2]) * (d[i + 3] / 255) + 255 * (1 - d[i + 3] / 255)) / 255;
      let union = 0;
      let only = 0;
      let diff = 0;
      let most = 0;
      for (let i = 0; i < a.length; i += 4) {
        const da = dark(a, i);
        const db = dark(b, i);
        if (da || db) {
          union++;
        }
        if (da !== db) {
          only++;
        }
        diff += Math.abs(ink(a, i) - ink(b, i));
        most += Math.max(ink(a, i), ink(b, i));
      }
      return { union, only, ratio: only / union, grey: diff / most, live: zpdf.liveBytes() };
    },
    { fontName, text, variations, shiftX, directVariations, shiftY },
  );
}

const DIRECT_CASES = [
  { font: "Roboto-Regular.ttf", text: "office AVA", variations: {} },
  // Harakat: marks with vertical offsets (181, -164, -215 font units), placed by the pen.
  { font: "Amiri-Regular.ttf", text: "بِسْمِ اللَّهِ", variations: {} },
  { font: "NotoSansDevanagari-Regular.ttf", text: "हिन्दी क्षि", variations: {} },
  { font: "Amiri-Regular.ttf", text: "بسم الله", variations: {} },
  { font: "NotoIKEAHebrewLatin-Regular.ttf", text: "שָׁלוֹם", variations: {} },
  { font: "Fraunces.ttf", text: "office", variations: { opsz: 144, wght: 100 } },
  { font: "Fraunces.ttf", text: "office", variations: {} },
  { font: "Fraunces.ttf", text: "office", variations: { wght: 500 } },
  { font: "RobotoFlex-Variable.ttf", text: "Variable AVA", variations: { wght: 1000, wdth: 25 } },
];

// drawText puts the same glyphs where the PDF puts them. pdf.js and the canvas
// antialias differently, and thin strokes (Fraunces at wght=100) differ most, so the
// bar is relative to a control measured in the same run: the correct drawing must be
// less than half as far from the PDF as the same drawing moved half a point. Measured
// at this commit: correct 0.04-0.11 (0.30 for Fraunces wght=100), half a point 0.17-0.78,
// so correct/half-point is 0.25-0.38. For a variable font, drawing the default instance
// must also be farther than the half-point shift.
for (const c of DIRECT_CASES) {
  test(`canvas drawText matches the PDF: ${c.font} ${JSON.stringify(c.variations)}`, async () => {
    const same = await compareDirectWithPdf(c.font, c.text, c.variations, 0);
    const half = await compareDirectWithPdf(c.font, c.text, c.variations, 0.5);
    console.log(`${c.font} ${JSON.stringify(c.variations)}: correct ${same.grey.toFixed(4)}, half a point off ${half.grey.toFixed(4)}`);
    expect(same.union).toBeGreaterThan(1000);
    expect(same.grey).toBeLessThan(half.grey / 2);
    const down = await compareDirectWithPdf(c.font, c.text, c.variations, 0, undefined, 0.5);
    // The same rule one way down. Measured: correct/down 0.26-0.37, and 0.50 for
    // Fraunces wght=100 (hairlines), so the vertical bar is 0.6.
    expect(same.grey).toBeLessThan(down.grey * 0.6);
    if (Object.keys(c.variations).length > 0) {
      const wrong = await compareDirectWithPdf(c.font, c.text, c.variations, 0, {});
      expect(wrong.grey).toBeGreaterThan(half.grey);
    }
    expect(page_errors).toEqual([]);
  });
}

test("handles: one PDF through the handle API equals textToPdf's; misuse is an error, not a crash", async () => {
  const got = await page.evaluate(async () => {
    const { BLACK, Zpdf, textToPdf } = await import("/zpdf.js");
    const z = window.zpdfPage;
    const bytes = new Uint8Array(await (await fetch("/fonts/Fraunces.ttf")).arrayBuffer());
    const variations = { opsz: 144, wght: 100 };
    const attempt = (f) => {
      try {
        f();
        return null;
      } catch (error) {
        return error.code ?? error.name;
      }
    };
    const zpdf = await Zpdf.create(z.wasmModule);
    const start = zpdf.liveBytes();
    const font = zpdf.openFont(bytes, { variations });
    const doc = zpdf.newDocument();
    const p = doc.beginPage(612, 792);
    doc.drawText(p, doc.addFont(font), 24, 72, 720, BLACK, "office");
    // The font handle closes before the document writes; the document keeps the font.
    font.close();
    const pageOpen = attempt(() => doc.beginPage(612, 792));
    const finishOpen = attempt(() => doc.finish());
    const badPage = attempt(() => doc.drawText(99, 0, 24, 72, 720, BLACK, "x"));
    doc.endPage(p);
    const endedPage = attempt(() => doc.drawText(p, 0, 24, 72, 720, BLACK, "x"));
    const pdf = doc.finish();
    const finished = attempt(() => doc.finish());
    const want = await textToPdf(z.wasmModule, bytes, "office", variations);
    const same = pdf.length === want.length && pdf.every((b, i) => b === want[i]);
    const afterClose = attempt(() => font.shape("x"));
    const other = await Zpdf.create(z.wasmModule);
    const otherFont = other.openFont(bytes);
    const crossInstance = attempt(() => doc.addFont(otherFont));
    doc.close();
    const docAfterClose = attempt(() => doc.finish());

    // A standard font: named, not embedded, WinAnsi only.
    const std = zpdf.newDocument({ compress: false });
    const helv = std.addStandardFont("Helvetica-Bold");
    const badName = attempt(() => std.addStandardFont("Arial"));
    const sp = std.beginPage(612, 792);
    std.drawText(sp, helv, 12, 72, 720, BLACK, "Caf\u00e9 \u20ac5");
    const notWinAnsi = attempt(() => std.drawText(sp, helv, 12, 72, 700, BLACK, "\u0142"));
    std.endPage(sp);
    const stdText = new TextDecoder("latin1").decode(std.finish());
    std.close();
    const named = stdText.includes("/BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding") && !stdText.includes("FontFile");
    otherFont.close();
    return {
      same, afterClose, crossInstance, pageOpen, finishOpen, badPage, endedPage, finished, docAfterClose,
      badName, notWinAnsi, named, leftOver: zpdf.liveBytes() - start, otherLeft: other.liveBytes(),
    };
  });
  expect(got).toEqual({
    same: true, afterClose: "InvalidHandle", crossInstance: "TypeError", pageOpen: "PageOpen", finishOpen: "PageOpen",
    badPage: "InvalidPage", endedPage: "InvalidPage", finished: "DocumentFinished", docAfterClose: "InvalidHandle",
    badName: "TypeError", notWinAnsi: "NotWinAnsi", named: true, leftOver: 0, otherLeft: 0,
  });
  expect(page_errors).toEqual([]);
});

// pdf.js, not zpdf, decides the colour of each pixel here, so this checks what a reader draws.
test("lines, rectangles and coloured text render in their colours where they were drawn", async () => {
  const got = await page.evaluate(async () => {
    const { Zpdf } = await import("/zpdf.js");
    const z = window.zpdfPage;
    const zpdf = await Zpdf.create(z.wasmModule);
    const doc = zpdf.newDocument();
    const helv = doc.addStandardFont("Helvetica-Bold");
    const p = doc.beginPage(612, 792);
    const red = { r: 1, g: 0, b: 0 };
    const blue = { r: 0, g: 0, b: 1 };
    const green = { r: 0, g: 0.5, b: 0 };
    doc.fillRect(p, 100, 600, 100, 100, red);
    doc.strokeRect(p, 300, 600, 100, 100, 4, blue);
    doc.drawLine(p, 100, 400, 500, 400, 6, green);
    doc.drawText(p, helv, 96, 100, 150, blue, "H");
    const attempt = (f) => {
      try {
        f();
        return null;
      } catch (error) {
        return error.code ?? error.name;
      }
    };
    const badColor = attempt(() => doc.fillRect(p, 0, 0, 1, 1, { r: 0, g: 1.5, b: 0 }));
    const notColor = attempt(() => doc.drawLine(p, 0, 0, 1, 1, 1, "red"));
    const negative = attempt(() => doc.fillRect(p, 0, 0, -1, 1, red));
    doc.endPage(p);
    const pdf = doc.finish();
    doc.close();
    const canvas = document.createElement("canvas");
    await z.renderPdf(pdf, canvas, 1);
    const data = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data;
    // PDF (x, y) is canvas (x, 792 - y) at scale 1.
    const at = (x, y) => Array.from(data.subarray(((792 - y) * canvas.width + x) * 4, ((792 - y) * canvas.width + x) * 4 + 3));
    let blueText = 0;
    let otherText = 0;
    for (let y = 150; y < 230; y++) {
      for (let x = 100; x < 180; x++) {
        const [r, g, b] = at(x, y);
        if (b > 200 && r < 60 && g < 60) blueText++;
        else if (!(r > 200 && g > 200 && b > 200) && !(b > r && b > g)) otherText++;
      }
    }
    return {
      fillInside: at(150, 650), fillOutside: at(95, 650),
      strokeEdge: at(300, 650), strokeInside: at(350, 650),
      line: at(300, 400), lineAbove: at(300, 405),
      blueText: blueText > 500, otherText, badColor, notColor, negative,
    };
  });
  const white = [255, 255, 255];
  expect(got).toEqual({
    fillInside: [255, 0, 0], fillOutside: white,
    strokeEdge: [0, 0, 255], strokeInside: white,
    line: [0, 128, 0], lineAbove: white,
    blueText: true, otherText: 0, badColor: "InvalidColor", notColor: "TypeError", negative: "InvalidNumber",
  });
  expect(page_errors).toEqual([]);
});

// tests/images/exif/orient-6.png is stored a quarter turn off, with the Exif tag that turns it
// upright: a 32 x 16 picture with a red block at its top left and a blue bar along its bottom
// (tools/image-fixtures.py). pdf.js must show it upright where it was drawn.
test("a PNG with an Exif orientation renders upright where it was drawn; junk is refused", async () => {
  const png = Array.from(new Uint8Array(await Bun.file(new URL("../../tests/images/exif/orient-6.png", import.meta.url)).arrayBuffer()));
  const got = await page.evaluate(async (png) => {
    const { Zpdf } = await import("/zpdf.js");
    const z = window.zpdfPage;
    const zpdf = await Zpdf.create(z.wasmModule);
    const doc = zpdf.newDocument();
    const image = doc.addImage(new Uint8Array(png));
    let junk = null;
    try {
      doc.addImage(new Uint8Array([1, 2, 3]));
    } catch (error) {
      junk = error.code;
    }
    const p = doc.beginPage(612, 792);
    // Shown 32 x 16, drawn 4 times larger with its bottom-left at (100, 600).
    doc.drawImage(p, image, 100, 600, 128, 64);
    doc.endPage(p);
    const pdf = doc.finish();
    doc.close();
    const canvas = document.createElement("canvas");
    await z.renderPdf(pdf, canvas, 1);
    const data = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data;
    const at = (x, y) => Array.from(data.subarray(((792 - y) * canvas.width + x) * 4, ((792 - y) * canvas.width + x) * 4 + 3));
    return { size: [image.width, image.height], junk, topLeft: at(116, 648), topRight: at(212, 648), bottom: at(164, 608), outside: at(95, 630) };
  }, png);
  const red = ([r, g, b]) => r > 200 && g < 60 && b < 60;
  const blue = ([r, g, b]) => b > 150 && r < 60 && g < 60;
  expect(got.size).toEqual([32, 16]);
  expect(got.junk).toBe("UnsupportedImage");
  expect([red(got.topLeft), red(got.topRight), blue(got.bottom), got.outside]).toEqual([true, false, true, [255, 255, 255]]);
  expect(page_errors).toEqual([]);
});

// JPEG viewers read every CMYK JPEG's samples as inverted, and PDF readers draw /DCTDecode samples
// as they are, so zpdf writes an inverting /Decode (src/image.zig). pdf.js's render of each CMYK
// file must be the picture Chrome's own JPEG decoder shows, not its negative. The colours differ
// with each CMYK to RGB conversion, so the check is that their brightness correlates by 0.5 or
// more; a negative correlates strongly negatively (tools/image-oracle.py has the same check).
test("a CMYK JPEG renders as Chrome's own decoder shows it, not as its negative", async () => {
  const names = ["cmyk.jpg", "cmyk-noadobe.jpg", "cmyk-plain.jpg"];
  const files = await Promise.all(names.map(async (name) =>
    Array.from(new Uint8Array(await Bun.file(new URL(`../../tests/images/jpeg/${name}`, import.meta.url)).arrayBuffer()))));
  const got = await page.evaluate(async (files) => {
    const { Zpdf } = await import("/zpdf.js");
    const z = window.zpdfPage;
    const zpdf = await Zpdf.create(z.wasmModule);
    const brightness = (canvas) => {
      const d = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data;
      const out = [];
      for (let i = 0; i < d.length; i += 4) out.push((d[i] + d[i + 1] + d[i + 2]) / 3);
      return out;
    };
    const correlation = (a, b) => {
      const mean = (v) => v.reduce((s, x) => s + x, 0) / v.length;
      const ma = mean(a);
      const mb = mean(b);
      let ab = 0;
      let aa = 0;
      let bb = 0;
      for (let i = 0; i < a.length; i++) {
        ab += (a[i] - ma) * (b[i] - mb);
        aa += (a[i] - ma) ** 2;
        bb += (b[i] - mb) ** 2;
      }
      return ab / Math.sqrt(aa * bb);
    };
    const results = [];
    for (const bytes of files) {
      const jpeg = new Uint8Array(bytes);
      const doc = zpdf.newDocument();
      const image = doc.addImage(jpeg);
      const p = doc.beginPage(64, 32);
      doc.drawImage(p, image, 0, 0, 64, 32);
      doc.endPage(p);
      const pdf = doc.finish();
      doc.close();
      const rendered = document.createElement("canvas");
      await z.renderPdf(pdf, rendered, 1);
      const img = new Image();
      img.src = URL.createObjectURL(new Blob([jpeg], { type: "image/jpeg" }));
      await img.decode();
      const decoded = document.createElement("canvas");
      decoded.width = 64;
      decoded.height = 32;
      decoded.getContext("2d").drawImage(img, 0, 0, 64, 32);
      results.push([image.width, image.height, Math.round(correlation(brightness(rendered), brightness(decoded)) * 1000) / 1000]);
    }
    return results;
  }, files);
  console.log("CMYK correlations:", JSON.stringify(got));
  for (const [width, height, r] of got) {
    expect([width, height]).toEqual([32, 16]);
    expect(r).toBeGreaterThanOrEqual(0.5);
  }
  expect(page_errors).toEqual([]);
});

// pdf.js reads the text back: a reserved place shows on its page, with the page count that was
// only known after the last page.
test("reserveLater places drawn after the last page read as Page N of M on each page", async () => {
  const got = await page.evaluate(async () => {
    const { BLACK, Zpdf } = await import("/zpdf.js");
    const pdfjs = await import("/pdfjs/pdf.mjs");
    const z = window.zpdfPage;
    const zpdf = await Zpdf.create(z.wasmModule);
    const start = zpdf.liveBytes();
    const bytes = new Uint8Array(await (await fetch("/fonts/Roboto-Regular.ttf")).arrayBuffer());
    const font = zpdf.openFont(bytes);
    const doc = zpdf.newDocument();
    const roboto = doc.addFont(font);
    const attempt = (f) => {
      try {
        f();
        return null;
      } catch (error) {
        return error.code ?? error.name;
      }
    };
    const laters = [];
    for (let n = 0; n < 3; n++) {
      const p = doc.beginPage(612, 792);
      doc.drawText(p, roboto, 12, 72, 720, BLACK, `Body ${n + 1}`);
      laters.push(doc.reserveLater(p));
      doc.endPage(p);
    }
    const notDrawn = attempt(() => doc.finish());
    laters.forEach((later, i) => doc.drawTextLater(later, roboto, 9, 280, 30, BLACK, `Page ${i + 1} of ${laters.length}`));
    const drawnTwice = attempt(() => doc.drawTextLater(laters[0], roboto, 9, 280, 30, BLACK, "x"));
    const badLater = attempt(() => doc.drawTextLater(99, roboto, 9, 280, 30, BLACK, "x"));
    const pdf = doc.finish();
    doc.close();
    font.close();
    const loading = pdfjs.getDocument({ data: pdf.slice() });
    const pages = [];
    try {
      const reader = await loading.promise;
      for (let n = 1; n <= reader.numPages; n++) {
        const content = await (await reader.getPage(n)).getTextContent();
        pages.push(content.items.map((item) => item.str).filter((s) => s.trim() !== "").join("|"));
      }
    } finally {
      await loading.destroy();
    }
    return { pages, notDrawn, drawnTwice, badLater, leftOver: zpdf.liveBytes() - start };
  });
  expect(got).toEqual({
    pages: ["Body 1|Page 1 of 3", "Body 2|Page 2 of 3", "Body 3|Page 3 of 3"],
    notDrawn: "LaterNotDrawn", drawnTwice: "LaterDrawn", badLater: "InvalidLater", leftOver: 0,
  });
  expect(page_errors).toEqual([]);
});

test("links and bookmarks read back in pdf.js: URLs, forward page links, and the outline tree", async () => {
  const got = await page.evaluate(async () => {
    const { Zpdf } = await import("/zpdf.js");
    const pdfjs = await import("/pdfjs/pdf.mjs");
    const zpdf = await Zpdf.create(window.zpdfPage.wasmModule);
    const start = zpdf.liveBytes();
    const doc = zpdf.newDocument();
    const attempt = (f) => {
      try {
        f();
        return null;
      } catch (error) {
        return error.code ?? error.name;
      }
    };
    const p0 = doc.beginPage(612, 792);
    doc.addLink(p0, 72, 700, 100, 12, { uri: "https://example.com/a" });
    // To page 2, which is not begun yet.
    doc.addLink(p0, 72, 680, 100, 12, { page: 2, x: 0, y: 792 });
    const badUri = attempt(() => doc.addLink(p0, 0, 0, 10, 10, { uri: "https://example.com/a b" }));
    const top = doc.addBookmark(null, "Top", { page: 0, x: 0, y: 792 }, true);
    const kid = doc.addBookmark(top, "Kid", { page: 2, x: 0, y: 500 }, false);
    doc.addBookmark(kid, "Leaf \u00e9", { page: 1, x: 0, y: 400 }, true);
    doc.addBookmark(null, "Second", { page: 1, x: 0, y: 792 }, true);
    const badParent = attempt(() => doc.addBookmark(99, "x", { page: 0, x: 0, y: 0 }, true));
    doc.endPage(p0);
    doc.endPage(doc.beginPage(612, 792));
    const missing = attempt(() => doc.finish());
    doc.endPage(doc.beginPage(612, 792));
    const pdf = doc.finish();
    doc.close();
    const loading = pdfjs.getDocument({ data: pdf.slice() });
    try {
      const reader = await loading.promise;
      const where = async (dest) => [await reader.getPageIndex(dest[0]), dest[1].name, dest[2], dest[3]];
      const links = [];
      for (const a of await (await reader.getPage(1)).getAnnotations()) {
        links.push({ subtype: a.subtype, url: a.url ?? null, dest: a.dest ? await where(a.dest) : null, rect: a.rect });
      }
      const tree = async (items) => Promise.all(items.map(async (i) => ({ title: i.title, count: i.count ?? null, dest: await where(i.dest), items: await tree(i.items) })));
      const outline = await tree(await reader.getOutline());
      return { links, outline, badUri, badParent, missing, leftOver: zpdf.liveBytes() - start };
    } finally {
      await loading.destroy();
    }
  });
  expect(got).toEqual({
    links: [
      { subtype: "Link", url: "https://example.com/a", dest: null, rect: [72, 700, 172, 712] },
      { subtype: "Link", url: null, dest: [2, "XYZ", 0, 792], rect: [72, 680, 172, 692] },
    ],
    outline: [
      {
        title: "Top", count: 1, dest: [0, "XYZ", 0, 792],
        items: [{ title: "Kid", count: -1, dest: [2, "XYZ", 0, 500], items: [{ title: "Leaf \u00e9", count: null, dest: [1, "XYZ", 0, 400], items: [] }] }],
      },
      { title: "Second", count: null, dest: [1, "XYZ", 0, 792], items: [] },
    ],
    badUri: "InvalidUri", badParent: "InvalidBookmark", missing: "MissingPage", leftOver: 0,
  });
  expect(page_errors).toEqual([]);
});

test("live bytes return to their start after 200 open, shape, path, finish and close cycles", async () => {
  const got = await page.evaluate(async () => {
    const { BLACK, Zpdf } = await import("/zpdf.js");
    const z = window.zpdfPage;
    const bytes = new Uint8Array(await (await fetch("/fonts/RobotoFlex-Variable.ttf")).arrayBuffer());
    const zpdf = await Zpdf.create(z.wasmModule);
    const start = zpdf.liveBytes();
    let peak = 0;
    let glyphs = 0;
    for (let i = 0; i < 200; i++) {
      const font = zpdf.openFont(bytes, { variations: { wght: 100 + 4 * i } });
      const line = font.shape("Variable AVA");
      glyphs += line.glyphs.length;
      for (const g of line.glyphs) {
        font.glyphPath(g.id);
      }
      const doc = zpdf.newDocument();
      const p = doc.beginPage(612, 792);
      doc.drawText(p, doc.addFont(font), 24, 72, 720, BLACK, "Variable AVA");
      doc.endPage(p);
      doc.finish();
      peak = Math.max(peak, zpdf.liveBytes());
      font.close();
      doc.close();
    }
    return { left: zpdf.liveBytes() - start, peak, glyphs };
  });
  console.log(`200 cycles: ${got.glyphs} glyphs shaped, peak ${got.peak} live bytes, ${got.left} left`);
  expect(got.glyphs).toBe(200 * 12);
  expect(got.peak).toBeGreaterThan(100000);
  expect(got.left).toBe(0);
});

test("a trap retires the instance with the panic message; a new instance works", async () => {
  const got = await page.evaluate(async () => {
    const { Zpdf } = await import("/zpdf.js");
    const module = await WebAssembly.compileStreaming(fetch("/zpdf-test.wasm"));
    const bytes = new Uint8Array(await (await fetch("/fonts/Roboto-Regular.ttf")).arrayBuffer());
    const zpdf = await Zpdf.create(module);
    const font = zpdf.openFont(bytes);
    const line = font.shape("office");
    const before = line.glyphs.length;
    font.path2D(line.glyphs[0].id);
    const catchIt = (f) => {
      try {
        f();
        return null;
      } catch (error) {
        return { code: error.code, panic: error.panic ?? null };
      }
    };
    const trap = catchIt(() => zpdf._call("zpdf_wasm_test_panic"));
    const later = catchIt(() => font.shape("office"));
    const cachedPath = catchIt(() => font.path2D(line.glyphs[0].id));
    const fresh = await Zpdf.create(module);
    const after = fresh.openFont(bytes).shape("office").glyphs.length;
    // The shipped build has no test panic.
    const shipped = WebAssembly.Module.exports(window.zpdfPage.wasmModule).some((e) => e.name === "zpdf_wasm_test_panic");
    return { before, trap, retired: zpdf.retired, later, cachedPath, after, shipped };
  });
  // "office" in Roboto is 4 glyphs: o, the ffi ligature, c, e.
  expect(got).toEqual({
    before: 4,
    trap: { code: "Trapped", panic: "zpdf_wasm_test_panic" },
    retired: true,
    later: { code: "Retired", panic: null },
    cachedPath: { code: "Retired", panic: null },
    after: 4,
    shipped: false,
  });
  expect(page_errors).toEqual([]);
});

test("an engine stack overflow (a RangeError, not a RuntimeError) also retires the instance", async () => {
  const got = await page.evaluate(async () => {
    const { Zpdf } = await import("/zpdf.js");
    const module = await WebAssembly.compileStreaming(fetch("/zpdf-test.wasm"));
    const zpdf = await Zpdf.create(module);
    const shallow = zpdf._call("zpdf_wasm_test_recurse", 100);
    let deep;
    try {
      zpdf._call("zpdf_wasm_test_recurse", 50000000);
      deep = null;
    } catch (error) {
      deep = { code: error.code, cause: error.cause?.constructor?.name ?? null };
    }
    let later;
    try {
      zpdf.liveBytes();
      later = null;
    } catch (error) {
      later = error.code;
    }
    return { shallow, deep, retired: zpdf.retired, later };
  });
  expect(got).toEqual({ shallow: 100, deep: { code: "Trapped", cause: "RangeError" }, retired: true, later: "Retired" });
  expect(page_errors).toEqual([]);
});

// A canvas context that records the calls drawText makes.
const RECORDER = `
  window.recordingContext = () => {
    const calls = [];
    const ctx = {};
    for (const name of ["save", "restore", "translate", "scale", "fill"]) {
      ctx[name] = (...args) => calls.push([name, ...args.filter((a) => typeof a !== "object")]);
    }
    return { ctx, calls };
  };
`;

test("drawText places every glyph at its shaped origin, follows direction, and fails without touching the context", async () => {
  await page.evaluate(RECORDER);
  const got = await page.evaluate(async () => {
    const { Zpdf, drawText } = await import("/zpdf.js");
    const z = window.zpdfPage;
    const load = async (name) => new Uint8Array(await (await fetch(`/fonts/${name}`)).arrayBuffer());
    const zpdf = await Zpdf.create(z.wasmModule);
    const placement = (font, text, options) => {
      const line = font.shape(text, options);
      const scale = 30 / font.unitsPerEm();
      const { ctx, calls } = window.recordingContext();
      const width = drawText(ctx, font, text, 10, 50, 30, options);
      const want = line.glyphs.flatMap((g) => [["save"], ["translate", 10 + g.x * scale, 50 - g.y * scale], ["scale", scale, -scale], ["fill", "nonzero"], ["restore"]]);
      const marksMoved = line.glyphs.filter((g) => g.y !== 0).length;
      return { same: JSON.stringify(calls) === JSON.stringify(want), glyphs: line.glyphs.length, marksMoved, width: width === line.advance.x * scale, ids: line.glyphs.map((g) => g.id) };
    };
    const amiri = zpdf.openFont(await load("Amiri-Regular.ttf"));
    const harakat = placement(amiri, "بِسْمِ اللَّهِ", {});
    // Hebrew then Latin: the Hebrew run is drawn left of "abc" in an LTR paragraph
    // and right of it in an RTL one, so the order differs when the option reaches kb.
    const hebrew = zpdf.openFont(await load("NotoIKEAHebrewLatin-Regular.ttf"));
    const ltr = placement(hebrew, "שלום abc", { direction: "ltr" });
    const rtl = placement(hebrew, "שלום abc", { direction: "rtl" });
    // CFF: shaping works, glyph paths do not; the context must stay untouched.
    const cff = zpdf.openFont(await load("SourceSansPro-Regular.otf"));
    const { ctx, calls } = window.recordingContext();
    let cffError;
    try {
      drawText(ctx, cff, "office", 10, 50, 30);
    } catch (error) {
      cffError = error.code;
    }
    return { harakat, ltr: { same: ltr.same, width: ltr.width }, rtl: { same: rtl.same, width: rtl.width }, reversed: JSON.stringify(rtl.ids) !== JSON.stringify(ltr.ids), cffError, cffCalls: calls.length };
  });
  expect(got.harakat.same).toBe(true);
  expect(got.harakat.width).toBe(true);
  expect(got.harakat.marksMoved).toBeGreaterThan(2);
  expect(got.ltr).toEqual({ same: true, width: true });
  expect(got.rtl).toEqual({ same: true, width: true });
  expect(got.reversed).toBe(true);
  expect(got.cffError).toBe("UnsupportedFontFormat");
  expect(got.cffCalls).toBe(0);
  expect(page_errors).toEqual([]);
});
