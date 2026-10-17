#!/bin/sh
# Rebuilds tests/read/*.pdf, the files src/read.zig's tests read: a 3-page PDF from zpdf's
# wasm build (tools/read-fixtures.mjs), and qpdf's rewrites of it into the other file shapes
# the reader must handle. qpdf writes them, not zpdf, so the reader is tested on another
# writer's xref streams, object streams, predictors and linearization.
#
#   tools/read-fixtures.sh        (from the repo root; needs zig, bun, qpdf)
#
# The tests compare these files against each other, not against stored hashes, so a newer
# qpdf that writes different bytes still passes.
set -eu
cd "$(dirname "$0")/.."
zig build
out=tests/read
bun tools/read-fixtures.mjs zig-out/bin/zpdf.wasm "$out/base.pdf"
# Object streams and a cross-reference stream (qpdf predicts it with PNG Up, /Predictor 12).
qpdf --object-streams=generate "$out/base.pdf" "$out/objstm.pdf"
# Linearized: a first-page xref section, then the main one, joined by /Prev.
qpdf --linearize "$out/base.pdf" "$out/linear.pdf"
# AES-256; the reader must refuse it as Encrypted.
qpdf --encrypt user owner 256 -- "$out/base.pdf" "$out/encrypted.pdf"
qpdf --check "$out/objstm.pdf" > /dev/null
qpdf --check "$out/linear.pdf" > /dev/null
ls -l "$out"
