#!/usr/bin/env bash
# Run the zpdf test binary under valgrind.
#
#   tools/test-valgrind.sh                       # the whole suite
#   tools/test-valgrind.sh 'fresh font would'    # tests whose name contains this (repeatable)
#
# Where it runs. On macOS, valgrind does not run, so it runs in a native arm64 Linux container
# (Docker). On Linux it is this machine's own valgrind, for its own architecture, with no container,
# no root and no docker group: the test binary is static musl, so valgrind needs no debug symbols for
# the system's glibc. Either way the binary is cross-compiled to <arch>-linux-musl into
# zig-out-linux/ (never zig-out/, which holds the native binaries), through LLVM (build.zig says why).
#
# What it catches that `zig build test` does not: reads of uninitialised memory, in Zig and in kb's
# C, on the stack and on the heap, and access to unmapped memory with a stack trace. What it does not
# catch: a use-after-free inside an arena block that is still mapped. The native suite covers part of
# that, because a failed shape frees the context arena with .free_all and the test allocator unmaps
# large blocks.
#
# The canary. Before the suite, tools/valgrind-canary.zig, built the same way, reads uninitialised
# memory on purpose: on the heap, on the stack, in a large block libzpdf's block cache hands out
# again, and in a block a libzpdf context allocates. The run fails unless valgrind reports all four.
# Without it a build in which valgrind cannot see uninitialised memory passes clean: Zig's
# self-hosted x86_64 backend was one, and the heap read went unreported (2026-10-21).
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
canary="$out/test/valgrind-canary"

case "$(uname -s)" in
  Darwin)
    mode=docker
    arch=aarch64
    if ! docker info >/dev/null 2>&1; then
      echo "FATAL: docker is not running, so valgrind did NOT run." >&2
      exit 1
    fi
    ;;
  Linux)
    mode=host
    arch="$(uname -m)"
    if ! command -v valgrind >/dev/null; then
      echo "FATAL: valgrind is not installed, so it did NOT run." >&2
      exit 1
    fi
    ;;
  *)
    echo "FATAL: valgrind runs here on macOS (Docker) or Linux, not $(uname -s)." >&2
    exit 1
    ;;
esac

# Runs valgrind with these arguments, from the repo root, in the container or on this machine.
run_valgrind() {
  if [ "$mode" = docker ]; then
    # The test binary opens fonts by absolute host path (build_options), so the repo is mounted at
    # its own path, not at /w.
    docker run --rm --platform linux/arm64 -v "$here":"$here" -w "$here" "$image" \
      sh -c 'apk add --no-cache valgrind >/dev/null 2>&1 && exec valgrind "$@"' valgrind "$@"
  else
    (cd "$here" && valgrind "$@")
  fi
}

filter_args=()
for f in "$@"; do
  filter_args+=("-Dtest-filter=$f")
done

echo "== cross-compile the test binary and the canary for $arch-linux-musl into $out"
"$zig" build test-artifacts -Dtarget="$arch-linux-musl" -Dcpu=baseline \
  "${filter_args[@]+"${filter_args[@]}"}" --prefix "$here/$out"

if [ "$mode" = docker ] &&
  ! docker run --rm --platform linux/arm64 -v "$here":"$here" -w "$here" "$image" test -x "$here/$bin"; then
  echo "FATAL: the container cannot see $bin through the bind mount ($here)." >&2
  exit 1
fi

log="$(mktemp -t zpdf-valgrind.XXXXXX)"
trap 'rm -f "$log"' EXIT

echo "== canary: valgrind must report the planted heap, stack, reused-block and context reads"
run_valgrind --suppressions=tools/valgrind.supp "./$canary" > "$log" 2>&1 || true
for fn in canaryHeapRead canaryStackRead canaryReusedBlockRead canaryContextRead; do
  if ! grep -A1 'depends on uninitialised' "$log" | grep -q "$fn"; then
    cat "$log" >&2
    echo "FATAL: valgrind did not report the uninitialised read in $fn, so a clean run below would prove nothing." >&2
    exit 1
  fi
done
echo "canary: all four reads reported"

echo "== valgrind (memcheck, error-exitcode=97)"
vg_status=0
# --leak-check=no: std.testing.allocator already fails a test that leaks.
# tools/valgrind.supp holds the reports that are not defects, each with its reason.
run_valgrind --quiet --error-exitcode=97 --leak-check=no --suppressions=tools/valgrind.supp "./$bin" \
  2>&1 | tee "$log" || vg_status=$?  # pipefail: this is valgrind's status, not tee's

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

# Not anchored: a report can start on the line the test runner left open ("4/4 name...==1== ...").
reports="$(grep -cE '==[0-9]+== [A-Z]' "$log" || true)"
if [ "$reports" -gt 0 ]; then
  echo "FATAL: valgrind reported $reports finding(s); the full report is above." >&2
  exit 1
fi
if [ "$vg_status" -ne 0 ]; then
  echo "FATAL: the run exited $vg_status with no valgrind report to explain it (a crash or a failed test; read above)." >&2
  exit 1
fi

# libzpdf as it ships (ReleaseSafe, a shared library with no libc), called by tests/abi/abi-test.c
# from several threads, on glibc and on musl, through the same bundle another machine runs
# (tools/valgrind-abi-bundle.sh, which has its own canary). The test binary above cannot stand in
# for it: it is a static Debug build, compiled differently, on one thread. A report that only this
# run made is in the git log (2026-10-16, read_text's run start). The bundle runs in containers,
# because valgrind needs debug symbols for the container's ld.so; on a Linux machine with no usable
# Docker it is not run, and the last line says so.
if [ "$mode" = docker ] || docker info >/dev/null 2>&1; then
  "$here/tools/valgrind-abi-bundle.sh" "$arch" "$here/$out/abi"
  "$here/$out/abi/run.sh"
  echo "valgrind clean ($ran tests, and libzpdf under abi-test)"
else
  echo "valgrind clean ($ran tests; libzpdf under abi-test NOT run: no usable Docker on this machine)"
fi
