#!/bin/sh
# Rebuilds tests/read/*.pdf, the files src/read.zig's tests read: a 3-page PDF from zpdf's
# wasm build (tools/read-fixtures.mjs), and qpdf's rewrites of it into the other file shapes
# the reader must handle. qpdf writes them, not zpdf, so the reader is tested on another
# writer's xref streams, object streams, predictors and linearization.
#
#   tools/read-fixtures.sh        (from the repo root; needs zig, bun, qpdf, uv, and tiffcp from libtiff)
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
# AES-256 (R6) with a user password: PasswordRequired without it, readable with it.
qpdf --encrypt user owner 256 -- "$out/base.pdf" "$out/encrypted.pdf"
# Every revision of the standard security handler, from qpdf, so the reader's decryption is
# checked against another implementation: the empty user password unless named -password.
# --extract=n on two: permissions are not enforced. Two have object streams, whose objects are
# decrypted with their stream, not again. rc4 needs --allow-weak-crypto.
enc="$out/encrypted"
mkdir -p "$enc"
weak=--allow-weak-crypto
qpdf $weak --encrypt "" owner 40 --extract=n -- "$out/base.pdf" "$enc/rc4-40.pdf"
qpdf $weak --encrypt "" owner 128 --use-aes=n -- "$out/base.pdf" "$enc/rc4-128.pdf"
qpdf $weak --encrypt "" owner 128 --use-aes=n --force-V4 -- "$out/base.pdf" "$enc/rc4-128-v4.pdf"
qpdf --encrypt "" owner 128 --use-aes=y --extract=n -- --object-streams=generate "$out/base.pdf" "$enc/aes-128.pdf"
qpdf --encrypt "" owner 128 --use-aes=y --cleartext-metadata -- "$out/base.pdf" "$enc/aes-128-cleartext-metadata.pdf"
qpdf --encrypt "" owner 256 --force-R5 -- "$out/base.pdf" "$enc/aes-256-r5.pdf"
qpdf --encrypt "" owner 256 -- --object-streams=generate "$out/base.pdf" "$enc/aes-256.pdf"
qpdf $weak --encrypt user owner 128 --use-aes=n -- "$out/base.pdf" "$enc/rc4-128-password.pdf"
qpdf --encrypt user owner 256 --force-R5 -- "$out/base.pdf" "$enc/aes-256-r5-password.pdf"
# An empty owner password with a user password: the empty password must not open it.
qpdf --encrypt user "" 128 --use-aes=y -- "$out/base.pdf" "$enc/aes-128-empty-owner.pdf"
# What is not encrypted: base.pdf with a /Metadata stream and a signature dictionary added
# (sig-metadata.json, written for base.pdf's 18 objects: its maxobjectid), encrypted with clear
# metadata. qpdf leaves the metadata and the signature's /Contents unencrypted, as the standard
# says, and encrypts its /Name. /Contents is 48 bytes, a length AES data can have, so a reader
# that decrypted it would not get it back by accident.
qpdf "$out/base.pdf" --update-from-json="$enc/sig-metadata.json" "$enc/sig-metadata.tmp.pdf"
qpdf --encrypt "" owner 128 --use-aes=y --cleartext-metadata -- "$enc/sig-metadata.tmp.pdf" "$enc/aes-128-sig-metadata.pdf"
rm "$enc/sig-metadata.tmp.pdf"
# LZWDecode data that decodes to base.pdf: from libtiff, and with /EarlyChange 0.
uv run tools/lzw-fixtures.py
qpdf --check "$out/objstm.pdf" > /dev/null
qpdf --check "$out/linear.pdf" > /dev/null
ls -lR "$out"
