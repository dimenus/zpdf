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
# again, and twice in blocks a libzpdf context allocates. The run fails unless valgrind reports all
# five.
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

# Runs a canary under valgrind and fails unless valgrind reports all five planted reads.
check_canary() {
  run_valgrind --suppressions=tools/valgrind.supp "./$1" > "$log" 2>&1 || true
  for fn in canaryHeapRead canaryStackRead canaryReusedBlockRead canaryContextRead canaryContextAllocRead; do
    if ! grep -A1 'depends on uninitialised' "$log" | grep -q "$fn"; then
      cat "$log" >&2
      echo "FATAL: valgrind did not report the uninitialised read in $fn of $1, so a clean run after it would prove nothing." >&2
      exit 1
    fi
  done
  echo "canary: all five reads reported"
}

echo "== canary: valgrind must report the planted heap, stack, reused-block and context reads"
check_canary "$canary"

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

# libzpdf, called by tests/abi/abi-test.c from several threads. The test binary above cannot stand
# in for it: it is a Debug build of other code (the tests), compiled differently, on one thread. A
# report that only this run made is in the git log (2026-10-16, read_text's run start). Both forms
# below build libzpdf as it ships (ReleaseSafe, no libc) with Zig's valgrind support on (build.zig
# nativeModule says why), and each runs its canary first.
#
# On Linux: abi-test and libzpdf linked into one static musl executable (zig build abi-test-static),
# run by this machine's valgrind. A static executable needs no ld.so, so this runs with no Docker.
# Where Docker works (always on macOS): the shared library, loaded by glibc's and musl's ld.so, in
# containers (tools/valgrind-abi-bundle.sh), because valgrind needs debug symbols for the ld.so of a
# dynamic program.
abi_runs=()
if [ "$mode" = host ]; then
  static="$out/abi-static"
  echo "== libzpdf under abi-test, linked statically, on this machine's valgrind"
  "$zig" build abi-test-static abi-canary -Dtarget="$arch-linux-musl" -Dcpu=baseline --prefix "$here/$static"
  check_canary "$static/canary/valgrind-canary"
  fonts=("$here"/zig-pkg/*/test/subset/data/fonts/Roboto-Regular.ttf)
  if [ "${#fonts[@]}" -ne 1 ] || [ ! -f "${fonts[0]}" ]; then
    echo "FATAL: expected one Roboto-Regular.ttf in the harfbuzz package, found: ${fonts[*]}" >&2
    exit 1
  fi
  abi_status=0
  run_valgrind --quiet --error-exitcode=97 --leak-check=full --errors-for-leak-kinds=definite \
    --suppressions=tools/valgrind.supp "./$static/bin/abi-test-static" \
    "${fonts[0]}" tests/read/objstm.pdf tests/images/exif/orient-6.jpg 2>&1 | tee "$log" || abi_status=$?
  if ! grep -qx 'abi-test: ok' "$log"; then
    echo "FATAL: abi-test-static did not finish (exit $abi_status); read above." >&2
    exit 1
  fi
  reports="$(grep -cE '==[0-9]+== [A-Z]' "$log" || true)"
  if [ "$reports" -gt 0 ] || [ "$abi_status" -ne 0 ]; then
    echo "FATAL: valgrind reported $reports finding(s) in static libzpdf (exit $abi_status); the full report is above." >&2
    exit 1
  fi
  abi_runs+=("static on musl")
fi
if [ "$mode" = docker ] || docker info >/dev/null 2>&1; then
  "$here/tools/valgrind-abi-bundle.sh" "$arch" "$here/$out/abi"
  "$here/$out/abi/run.sh"
  abi_runs+=("shared on glibc and musl")
fi
printf -v joined '%s, ' "${abi_runs[@]}"
echo "valgrind clean ($ran tests, and libzpdf under abi-test: ${joined%, })"
