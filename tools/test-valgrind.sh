#!/usr/bin/env bash
# Run the zpdf test binary under valgrind, in a native arm64 Linux container.
#
#   tools/test-valgrind.sh                       # the whole suite
#   tools/test-valgrind.sh 'fresh font would'    # tests whose name contains this (repeatable)
#
# Valgrind does not run on Darwin; it runs on Linux/arm64, which Docker provides
# natively here. The test binary is cross-compiled to aarch64-linux-musl into
# zig-out-linux/ (never zig-out/, which holds the native binaries).
#
# What it catches that `zig build test` does not: reads of uninitialised memory,
# in Zig and in kb's C, and access to unmapped memory with a stack trace. What
# it does not catch: a use-after-free inside an arena block that is still
# mapped. The native suite covers part of that, because a failed shape frees
# the context arena with .free_all and the test allocator unmaps large blocks.
#
# Rules carried from an earlier test runner, each from a run that lied:
# - A filter that matches nothing still runs the unnamed `test {}` block and
#   exits 0, so every requested filter must match a test name that RAN.
# - Zero tests run is a failure, not a pass.
# - Do not read this script's exit status through a pipe (`| tail` reports
#   tail's status).
# - Docker Desktop mounts an unshared path as an empty directory, silently.
#   The binary is checked through the mount before the run.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
zig="${ZIG:-$here/tools/zig}"
image="${VALGRIND_IMAGE:-alpine:3.21}"
out="zig-out-linux"
bin="$out/test/test"

if ! docker info >/dev/null 2>&1; then
  echo "FATAL: docker is not running, so valgrind did NOT run." >&2
  exit 1
fi

filter_args=()
for f in "$@"; do
  filter_args+=("-Dtest-filter=$f")
done

echo "== cross-compile the test binary for aarch64-linux-musl into $out"
"$zig" build test-artifacts -Dtarget=aarch64-linux-musl -Dcpu=baseline \
  "${filter_args[@]+"${filter_args[@]}"}" --prefix "$here/$out"

# The test binary opens fonts by absolute host path (build_options), so the
# repo is mounted at its own path, not at /w.
if ! docker run --rm --platform linux/arm64 -v "$here":"$here" -w "$here" "$image" test -x "$here/$bin"; then
  echo "FATAL: the container cannot see $bin through the bind mount ($here)." >&2
  exit 1
fi

log="$(mktemp -t zpdf-valgrind.XXXXXX)"
trap 'rm -f "$log"' EXIT

echo "== valgrind (memcheck, error-exitcode=97)"
vg_status=0
# --leak-check=no: std.testing.allocator already fails a test that leaks.
# tools/valgrind.supp holds the reports that are not defects, each with its reason.
docker run --rm --platform linux/arm64 -v "$here":"$here" -w "$here" "$image" sh -c "
  set -e
  apk add --no-cache valgrind >/dev/null 2>&1
  valgrind --quiet --error-exitcode=97 --leak-check=no --suppressions=tools/valgrind.supp ./$bin
" 2>&1 | tee "$log" || vg_status=$?  # pipefail: this is docker's status, not tee's

ran="$(grep -cE '^[0-9]+/[0-9]+ ' "$log" || true)"
echo "== tests executed under valgrind: $ran"
if [ "$ran" -eq 0 ]; then
  echo "FATAL: zero tests ran, so valgrind proved nothing." >&2
  exit 1
fi
missed=0
for f in "$@"; do
  if ! grep -E '^[0-9]+/[0-9]+ ' "$log" | grep -qF -- "$f"; then
    echo "FATAL: no executed test name contained '$f'." >&2
    missed=1
  fi
done
if [ "$missed" -ne 0 ]; then
  exit 1
fi

reports="$(grep -cE '^==[0-9]+== [A-Z]' "$log" || true)"
if [ "$reports" -gt 0 ]; then
  echo "FATAL: valgrind reported $reports finding(s); the full report is above." >&2
  exit 1
fi
if [ "$vg_status" -ne 0 ]; then
  echo "FATAL: the run exited $vg_status with no valgrind report to explain it (a crash or a failed test; read above)." >&2
  exit 1
fi
# libzpdf as it ships (ReleaseSafe, a shared library on glibc), called by tests/abi/abi-test.c
# from several threads, through the same bundle another machine runs
# (tools/valgrind-abi-bundle.sh). The Debug test binary above cannot stand in for it: Debug
# fills `undefined` memory with 0xaa, which valgrind counts as initialised, and the optimised
# library is compiled differently. A report that only this run made is in the git log
# (2026-10-16, read_text's run start).
"$here/tools/valgrind-abi-bundle.sh" aarch64 "$here/$out/abi"
"$here/$out/abi/run.sh"
echo "valgrind clean ($ran tests, and libzpdf under abi-test)"
