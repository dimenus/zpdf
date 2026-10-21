#!/usr/bin/env bash
# Build a bundle that runs libzpdf under valgrind on Linux, for a machine that has Docker but not
# this repo or Zig.
#
#   tools/valgrind-abi-bundle.sh <aarch64|x86_64> <out dir>
#   <out dir>/run.sh                      # on the Linux machine (or a Mac with Docker)
#   ZPDF_DOCKER="sudo docker" ./run.sh    # where the user cannot use the Docker socket
#
# The bundle holds libzpdf as it ships (ReleaseSafe, a shared library that links no libc),
# tests/abi/abi-test.c built against it twice, for glibc and for musl, the inputs abi-test reads,
# and run.sh. run.sh runs both under memcheck, in Debian (glibc) and in Alpine (musl): the one .so
# must load and pass in each. Containers, because valgrind needs debug symbols for a dynamic
# program's ld.so, which a host like Arch strips. run.sh prints "valgrind clean (libzpdf under
# abi-test, <arch>, glibc and musl)" and exits 0 only when both finished and valgrind reported
# nothing. tools/test-valgrind.sh runs the aarch64 bundle.
#
# The canary. With no libc there is no malloc for valgrind to replace, so it sees libzpdf's heap
# only through the marks libzpdf makes itself (src/counting.zig, src/block_cache.zig, through
# src/valgrind_marks.zig). Before abi-test, run.sh runs tools/valgrind-canary.zig, built with
# libzpdf's module options, and fails unless valgrind reports its two planted reads that go through
# those marks. Without the marks, a planted read in libzpdf went unreported and the run said clean.
# The canary's heap and stack reads are not required here: they rely on Zig marking `undefined`
# values, which libzpdf's build leaves off.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
zig="${ZIG:-$here/tools/zig}"
arch="${1:?usage: tools/valgrind-abi-bundle.sh <aarch64|x86_64> <out dir>}"
out="${2:?usage: tools/valgrind-abi-bundle.sh <aarch64|x86_64> <out dir>}"
case "$arch" in
  aarch64) platform=linux/arm64 ;;
  x86_64) platform=linux/amd64 ;;
  *) echo "FATAL: arch must be aarch64 or x86_64, not $arch" >&2; exit 2 ;;
esac
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac

cd "$here"
fonts=(zig-pkg/*/test/subset/data/fonts/Roboto-Regular.ttf)
if [ "${#fonts[@]}" -ne 1 ] || [ ! -f "${fonts[0]}" ]; then
  echo "FATAL: expected one Roboto-Regular.ttf in the harfbuzz package, found: ${fonts[*]}" >&2
  exit 1
fi

rm -rf "$out"
"$zig" build abi abi-canary -Dtarget="$arch-linux-gnu" -Dcpu=baseline --prefix "$out"
mv "$out/canary/valgrind-canary" "$out/valgrind-canary"
rmdir "$out/canary"
for libc in gnu musl; do
  "$zig" cc -target "$arch-linux-$libc" -std=c11 -Wall -Wextra -Werror tests/abi/abi-test.c \
    -I "$out/include" -L "$out/lib" -lzpdf -lpthread -o "$out/abi-test-$libc"
done
cp "${fonts[0]}" "$out/font.ttf"
cp tests/read/objstm.pdf "$out/read.pdf"
cp tests/images/exif/orient-6.jpg "$out/image.jpg"
cp tools/valgrind.supp "$out/valgrind.supp"
rm -rf "$out/include" "$out/csharp"

cat > "$out/run.sh" <<EOF
#!/usr/bin/env bash
# libzpdf under valgrind, $arch, built from zpdf $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- || echo " plus uncommitted changes").
set -uo pipefail
cd "\$(dirname "\${BASH_SOURCE[0]}")"
docker_cmd=(\${ZPDF_DOCKER:-docker})
log="\$(mktemp)"
trap 'rm -f "\$log"' EXIT
rm -f canary.log
# One container per libc, each with its own valgrind; the same libzpdf.so in both. \$4, when set,
# runs the canary first, into canary.log.
run_in() {
  local image=\$1 install=\$2 program=\$3 canary=\${4:-} status=0
  "\${docker_cmd[@]}" run --rm --platform $platform -v "\$PWD":/b -w /b "\$image" sh -c "
    set -e
    \$install
    test -x ./\$program || { echo 'FATAL: the container cannot see the bundle through the mount'; exit 3; }
    \${canary:+valgrind --log-file=canary.log --suppressions=valgrind.supp ./valgrind-canary >/dev/null || true}
    LD_LIBRARY_PATH=lib valgrind --quiet --error-exitcode=97 --leak-check=full \\
      --errors-for-leak-kinds=definite --suppressions=valgrind.supp ./\$program font.ttf read.pdf image.jpg
  " 2>&1 | tee "\$log" || status=\$?
  if ! grep -qx 'abi-test: ok' "\$log"; then
    echo "FATAL: \$program did not finish in \$image (exit \$status); read above." >&2
    exit 1
  fi
  reports="\$(grep -cE '^==[0-9]+== [A-Z]' "\$log" || true)"
  if [ "\$reports" -gt 0 ] || [ "\$status" -ne 0 ]; then
    echo "FATAL: valgrind reported \$reports finding(s) in libzpdf in \$image (exit \$status); the full report is above." >&2
    exit 1
  fi
}
run_in debian:bookworm-slim "apt-get update -qq >/dev/null && apt-get install -y -qq valgrind >/dev/null 2>&1" abi-test-gnu canary
for fn in canaryReusedBlockRead canaryContextRead; do
  if ! grep -A1 'depends on uninitialised' canary.log | grep -q "\$fn"; then
    cat canary.log >&2
    echo "FATAL: valgrind did not report the uninitialised read in \$fn, so the clean run above proves nothing." >&2
    exit 1
  fi
done
echo "canary: the block cache and context reads reported"
run_in alpine:3.21 "apk add --no-cache valgrind >/dev/null 2>&1" abi-test-musl
echo "valgrind clean (libzpdf under abi-test, $arch, glibc and musl)"
EOF
chmod +x "$out/run.sh" "$out/abi-test-gnu" "$out/abi-test-musl" "$out/valgrind-canary"
echo "bundle: $out (run.sh)"
