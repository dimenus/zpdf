// Local server for the zpdf page.
//
//   bun web/serve.js <path/to/zpdf.wasm> [font-dir] [port]
//
// `zig build --prefix <dir>` puts zpdf.wasm in <dir>/bin. Run `bun install` in web/ first:
// pdf.js comes from node_modules. A font dir, when given, is served under /fonts/<name>
// (the browser test uses it); the page itself takes a font from a file picker.
// Port 0 or no port picks a free one; the URL is printed. startServer's testWasmPath,
// when not null, is served as /zpdf-test.wasm: the build with zpdf_wasm_test_panic, for
// the browser test of the trap policy.
import { basename, join } from "node:path";

const WEB_DIR = import.meta.dir;
const PDFJS_DIR = join(WEB_DIR, "node_modules", "pdfjs-dist", "build");

export function startServer(wasmPath, fontDir, port, testWasmPath) {
  const routes = new Map([
    ["/", join(WEB_DIR, "index.html")],
    ["/index.html", join(WEB_DIR, "index.html")],
    ["/zpdf.js", join(WEB_DIR, "zpdf.js")],
    ["/zpdf.wasm", wasmPath],
    ["/pdfjs/pdf.mjs", join(PDFJS_DIR, "pdf.mjs")],
    ["/pdfjs/pdf.worker.mjs", join(PDFJS_DIR, "pdf.worker.mjs")],
  ]);
  if (testWasmPath !== null) {
    routes.set("/zpdf-test.wasm", testWasmPath);
  }
  return Bun.serve({
    port,
    hostname: "127.0.0.1",
    async fetch(request) {
      const path = new URL(request.url).pathname;
      let file_path = routes.get(path);
      // basename() keeps a request inside the font dir.
      if (file_path === undefined && fontDir !== null && path.startsWith("/fonts/")) {
        file_path = join(fontDir, basename(decodeURIComponent(path)));
      }
      if (file_path === undefined) {
        return new Response("not found", { status: 404 });
      }
      const file = Bun.file(file_path);
      if (!(await file.exists())) {
        return new Response(`missing on disk: ${file_path}`, { status: 404 });
      }
      // Bun.file guesses the type from the extension; .wasm must be application/wasm
      // for WebAssembly.compileStreaming.
      return new Response(file);
    },
  });
}

if (import.meta.main) {
  const [wasmPath, fontDir, port] = process.argv.slice(2);
  if (wasmPath === undefined) {
    throw new Error("usage: bun web/serve.js <path/to/zpdf.wasm> [font-dir] [port]");
  }
  if (!(await Bun.file(wasmPath).exists())) {
    throw new Error(`zpdf.wasm not found: ${wasmPath}`);
  }
  const server = startServer(wasmPath, fontDir ?? null, Number(port ?? 0), null);
  console.log(`zpdf page: ${server.url}`);
}
