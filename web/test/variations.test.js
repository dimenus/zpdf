// The bytes zpdf.js sends to zpdf_font_open for `variations`: 8 per variation, the
// 4 tag bytes (a short tag padded with spaces, as parseVariations in src/root.zig does)
// and the value as a little-endian f32.
import { expect, test } from "bun:test";
import { parseAxisRecords, variationRecords } from "../zpdf.js";

test("variations become 8-byte records: padded tag, little-endian f32", () => {
  const got = variationRecords({ wght: 700, ab: -1.5 });
  const want = new Uint8Array(16);
  want.set([0x77, 0x67, 0x68, 0x74], 0); // "wght"
  new DataView(want.buffer).setFloat32(4, 700, true);
  want.set([0x61, 0x62, 0x20, 0x20], 8); // "ab  "
  new DataView(want.buffer).setFloat32(12, -1.5, true);
  expect([...got]).toEqual([...want]);
  expect([...variationRecords({})]).toEqual([]);
});

test("variationRecords refuses what zpdf cannot read", () => {
  for (const bad of [undefined, null, [], [["wght", 700]], { "": 1 }, { wghtx: 1 }, { "wg t": 1 }, { wght: "700" }]) {
    expect(() => variationRecords(bad)).toThrow(TypeError);
  }
});

// The bytes zpdf_font_axes returns: 20 per axis, the 4 tag bytes, minimum, default
// and maximum as little-endian f32, then a little-endian u32 of flags (bit 0: hidden).
test("axis records become objects; a tag's padding is trimmed; flag bit 0 is hidden", () => {
  const bytes = new Uint8Array(40);
  const view = new DataView(bytes.buffer);
  bytes.set([0x77, 0x67, 0x68, 0x74], 0); // "wght"
  view.setFloat32(4, 100, true);
  view.setFloat32(8, 400, true);
  view.setFloat32(12, 900, true);
  view.setUint32(16, 0, true);
  bytes.set([0x61, 0x62, 0x20, 0x20], 20); // "ab  "
  view.setFloat32(24, -1.5, true);
  view.setFloat32(28, 0, true);
  view.setFloat32(32, 2.5, true);
  view.setUint32(36, 3, true); // bit 1 is not a flag zpdf.js reads
  expect(parseAxisRecords(bytes)).toEqual([
    { tag: "wght", min: 100, default: 400, max: 900, hidden: false },
    { tag: "ab", min: -1.5, default: 0, max: 2.5, hidden: true },
  ]);
  expect(parseAxisRecords(new Uint8Array(0))).toEqual([]);
  // A view into a larger buffer reads from its own offset.
  const padded = new Uint8Array(44);
  padded.set(bytes, 4);
  expect(parseAxisRecords(padded.subarray(4))).toEqual(parseAxisRecords(bytes));
  expect(() => parseAxisRecords(new Uint8Array(19))).toThrow("not a multiple of 20");
});
