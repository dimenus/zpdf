// The base file for tools/read-fixtures.sh: 3 US Letter pages, each with Roboto text (Type 0,
// Identity-H, ToUnicode), Helvetica text (WinAnsi), a line, a fill, and a "Page n of 3" footer in
// a reserveLater form. Compressed.
//
//   bun tools/read-fixtures.mjs <zpdf.wasm> <out.pdf>
import { readFileSync, writeFileSync } from "node:fs";
import { BLACK, Zpdf } from "../web/zpdf.js";

const [wasmPath, outPath] = process.argv.slice(2);
const zpdf = await Zpdf.create(await WebAssembly.compile(readFileSync(wasmPath)));
const harfbuzz = readFileSync(new URL("../build.zig.zon", import.meta.url), "utf8").match(/\.harfbuzz = \.\{[\s\S]*?\.hash = "([^"]+)"/)[1];
const font = zpdf.openFont(readFileSync(new URL(`../zig-pkg/${harfbuzz}/test/subset/data/fonts/Roboto-Regular.ttf`, import.meta.url)));
const doc = zpdf.newDocument({ compress: true });
const roboto = doc.addFont(font);
const helv = doc.addStandardFont("Helvetica");
const laters = [];
for (let n = 1; n <= 3; n++) {
  const page = doc.beginPage(612, 792);
  doc.fillRect(page, 72, 700, 468, 24, { r: 0.9, g: 0.9, b: 0.9 });
  doc.drawText(page, roboto, 14, 76, 706, BLACK, `Report page ${n}: office café`);
  doc.drawLine(page, 72, 690, 540, 690, 0.5, BLACK);
  doc.drawText(page, helv, 10, 76, 670, { r: 0.2, g: 0.2, b: 0.6 }, `Helvetica (parens) \\ café €${n}`);
  laters.push(doc.reserveLater(page));
  doc.endPage(page);
}
laters.forEach((later, i) => doc.drawTextLater(later, helv, 9, 270, 30, BLACK, `Page ${i + 1} of ${laters.length}`));
writeFileSync(outPath, doc.finish());
doc.close();
font.close();
