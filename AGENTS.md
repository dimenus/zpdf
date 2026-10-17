# Working on zpdf

- This repo builds with the Zig in `build.zig.zon` (`minimum_zig_version`); `zig` on PATH can be
  another version. Run `tools/zig` (it picks this checkout's), e.g. `tools/zig build test`; the tools
  here already do. Check a std declaration in that version's std source; never fix a compile error
  by guessing.
- `zig build test` runs the unit tests, checks formatting (`zig build fmt` fixes it), and builds the
  wasm32-freestanding library; all must pass.
  One test: `zig build test -Dtest-filter='<name substring>'` (`-- --test-filter` does not filter).
- `zig build test` includes `zig build golden`: zpdf-text's PDFs for `tests/golden/cases.tsv` must match
  `tests/golden/sha256.txt`. A failure prints each changed PDF's path. Never regenerate that file; a change
  you mean to make is a hand edit of its lines, explained in the commit.
- On any change that touches memory, also run `tools/test-valgrind.sh` (Docker; uninitialised reads in
  Zig and in kb's C). It must print `valgrind clean (N tests, and libzpdf under abi-test)`; do not read its status
  through a pipe.
- libzpdf under valgrind on another Linux machine (x86_64, say): `tools/valgrind-abi-bundle.sh
  x86_64 <dir>`, copy `<dir>` there (`COPYFILE_DISABLE=1 tar`), and run `<dir>/run.sh`.
- kb_text_shape comes from the fork `dimenus/kb`, branch `fixes`, pinned by commit in `build.zig.zon`.
  A kb change is made and tested in the fork first; then the pin moves here.
- Before writing or changing code that calls a dependency (kb from `src/kb_shim.c` and `src/root.zig`),
  read that library's own docs AND implementation, and use it the way the library intends, not the
  first way that compiles. The compiled source is `zig-pkg/<hash>/`, with the hash from `build.zig.zon`
  (kb: `kb_text_shape.h`, docs at the top, examples under EXAMPLES). Example of the miss: kb caches shape
  configs inside a long-lived shape context (`kbts__FindOrCreateShapeConfig`), and zpdf made one context
  per `drawText`, which rebuilt the config for every line (t-3197). A commit that touches such
  a call names the library section it relied on. Zig's std counts: before writing a helper (formatting,
  UTF-8/UTF-16, writers, allocators), look for it in std and use std's when it exists.
- Fonts are untrusted input. `uv run tools/font-sweep.py <font dirs>` runs a Debug zpdf-text over every
  file and lists each crash and hang by its first source frame; use `--exe` with a ReleaseFast build too,
  because some kb defects crash only there. Corpus: the harfbuzz package's `test/` folder.
- Mutation testing a new test: `uv run tools/mutate.py <mutants.json>` (its docstring has the
  format). Every kill must name the failing test; it exits 1 when a mutant survives.
- Speed of a change: `uv run tools/bench-ab.py` (hyperfine; needs hyperfine, mutool, Homebrew mupdf-tools)
  times this tree against main and against MuPDF on the same pages, and exits 1 when this tree is slower
  than main. Run it on any change to the PDF path.
- Reader speed and memory: `uv run tools/bench-read.py` times zpdf-read (ReleaseFast and ReleaseSafe)
  against main, mutool and pdftotext on the same PDFs from three writers (`--pdf` adds files), and
  exits 1 when this tree is slower than main twice. Run it on any change to `src/read*.zig`.
- Speed and output size against HarfBuzz + Cairo (`hb-view`) and PyMuPDF: `uv run bench/compare.py`
  (needs `hb-view`, `mutool`, `qpdf`). Compare tools on its `per 1k cp` column.
- Memory follows one page, not the document ("stream and free"): the `stream and free` tests in
  `src/abi.zig` and "a PageText holds its result" in `src/read_text.zig` fail when a page's data
  outlives its page. A cache that outlives a page must be bounded, and its test says by what.
- The C ABI (`src/abi.zig`, shared by zpdf.wasm and libzpdf): `zig build abi` installs libzpdf,
  `include/zpdf.h` and `csharp/Zpdf.Abi.g.cs` (generated; never edit them); `zig build native-all`
  builds libzpdf for the four .NET RIDs into `zig-out/runtimes/`. `zig build test` runs
  `tests/abi/abi-test.c` against the library; `zig build abi-dotnet-test` runs the generated C#
  (needs the .NET SDK). A change to an export, a wire record or an error code bumps `abi_version`;
  the test "the ABI surface is the one abi_version names" fails until it does, and prints the new hash.
- Wasm in a real browser (Playwright Chromium + pdf.js): `zig build web-test`; if Chromium is missing, `bun web/node_modules/playwright-core/cli.js install --only-shell chromium`.
