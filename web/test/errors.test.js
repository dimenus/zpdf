// The JS error table and standard font list in zpdf.js are copies of error_codes in
// src/abi.zig and StandardFont in src/pdf.zig. These fail when a copy differs.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { ERROR_NAMES, STANDARD_FONTS } from "../zpdf.js";

test("zpdf.js error names match src/abi.zig", () => {
  const src = readFileSync(new URL("../../src/abi.zig", import.meta.url), "utf8");
  const body = src.slice(src.indexOf("pub const error_codes"), src.indexOf("pub fn mapError"));
  const fromZig = new Map([...body.matchAll(/\.\{ error\.(\w+), (-\d+) \}/g)].map((m) => [Number(m[2]), m[1]]));
  expect(fromZig.size).toBeGreaterThan(30);
  const unknown = body.match(/unknown_code: i32 = (-\d+)/);
  expect(unknown).not.toBeNull();
  fromZig.set(Number(unknown[1]), "Unknown");
  expect(new Map([...ERROR_NAMES].sort((a, b) => a[0] - b[0]))).toEqual(new Map([...fromZig].sort((a, b) => a[0] - b[0])));
});

test("zpdf.js standard fonts match StandardFont in src/pdf.zig, in enum order", () => {
  const src = readFileSync(new URL("../../src/pdf.zig", import.meta.url), "utf8");
  const start = src.indexOf("pub const StandardFont = enum {");
  const decl = src.slice(start, src.indexOf("\n};", start));
  const fields = [...decl.slice(0, decl.indexOf("pub fn")).matchAll(/^    (\w+),$/gm)].map((m) => m[1]);
  const names = new Map([...decl.matchAll(/\.(\w+) => "([\w-]+)"/g)].map((m) => [m[1], m[2]]));
  expect(fields.length).toBe(12);
  expect(fields.map((f) => names.get(f))).toEqual(STANDARD_FONTS);
});
