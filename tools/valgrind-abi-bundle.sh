#!/usr/bin/env bash
# Build a bundle that runs libzpdf under valgrind on Linux, for a machine that has Docker but not
# this repo or Zig.
#
#   tools/valgrind-abi-bundle.sh <aarch64|x86_64> <out dir>
#   <out dir>/run.sh                      # on the Linux machine (or a Mac with Docker)
#   ZPDF_DOCKER="sudo docker" ./run.sh    # where the user cannot use the Docker socket
#
# The bundle holds libzpdf as it ships (ReleaseSafe, a shared library on glibc),
# tests/abi/abi-test.c built against it, the inputs abi-test reads, and run.sh. run.sh runs
# abi-test under memcheck in Debian, because Debian's valgrind brings the glibc debug symbols that
# memcheck needs; a host whose ld.so is stripped (Arch) cannot run it outside a container.
# run.sh prints "valgrind clean (libzpdf under abi-test, <arch>)" and exits 0 only when abi-test
# finished and valgrind reported nothing. tools/test-valgrind.sh runs the aarch64 bundle.
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
"$zig" build abi -Dtarget="$arch-linux-gnu" -Dcpu=baseline --prefix "$out"
"$zig" cc -target "$arch-linux-gnu" -std=c11 -Wall -Wextra -Werror tests/abi/abi-test.c \
  -I "$out/include" -L "$out/lib" -lzpdf -lpthread -o "$out/abi-test"
cp "${fonts[0]}" "$out/font.ttf"
cp tests/read/objstm.pdf "$out/read.pdf"
rm -rf "$out/include" "$out/csharp"

cat > "$out/run.sh" <<EOF
#!/usr/bin/env bash
# libzpdf under valgrind, $arch, built from zpdf $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- || echo " plus uncommitted changes").
set -uo pipefail
cd "\$(dirname "\${BASH_SOURCE[0]}")"
docker_cmd=(\${ZPDF_DOCKER:-docker})
log="\$(mktemp)"
trap 'rm -f "\$log"' EXIT
status=0
"\${docker_cmd[@]}" run --rm --platform $platform -v "\$PWD":/b -w /b debian:bookworm-slim sh -c '
  set -e
  apt-get update -qq >/dev/null && apt-get install -y -qq valgrind >/dev/null 2>&1
  test -x ./abi-test || { echo "FATAL: the container cannot see the bundle through the mount"; exit 3; }
  LD_LIBRARY_PATH=lib valgrind --quiet --error-exitcode=97 --leak-check=full \\
    --errors-for-leak-kinds=definite ./abi-test font.ttf read.pdf
' 2>&1 | tee "\$log" || status=\$?
if ! grep -qx 'abi-test: ok' "\$log"; then
  echo "FATAL: abi-test did not finish (exit \$status); read above." >&2
  exit 1
fi
reports="\$(grep -cE '^==[0-9]+== [A-Z]' "\$log" || true)"
if [ "\$reports" -gt 0 ] || [ "\$status" -ne 0 ]; then
  echo "FATAL: valgrind reported \$reports finding(s) in libzpdf (exit \$status); the full report is above." >&2
  exit 1
fi
echo "valgrind clean (libzpdf under abi-test, $arch)"
EOF
chmod +x "$out/run.sh" "$out/abi-test"
echo "bundle: $out (run.sh)"
