#!/usr/bin/env bash
# A package that depends on zpdf builds and runs: HEAD as `zig fetch` gets it (only build.zig.zon's
# .paths), then tests/consumer built against it and run. A file the build needs but .paths leaves
# out fails here, and nowhere else: zig build test runs from the checkout, which has every file.
#
#   tools/consumer-test.sh [zig]      (zig: the Zig to use; default tools/zig)
#
# CI runs it on Linux and macOS, and tools/platform-test.sh on each Linux machine. Exit 0 when the
# consumer built, ran and wrote a PDF.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# tools/zig picks the Zig of the checkout it runs in, so it is asked here, in this one, for the
# binary that then runs in the consumer's folder.
zig=${1:-$(cd "$root" && tools/zig env | sed -n 's/^ *\.zig_exe = "\(.*\)",$/\1/p')}
if [ -z "$zig" ]; then
  echo "consumer-test: tools/zig env gave no zig_exe" >&2
  exit 2
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git -C "$root" archive --format=tar.gz -o "$work/zpdf.tar.gz" HEAD
cp -R "$root/tests/consumer" "$work/consumer"
cd "$work/consumer"
"$zig" fetch --save=zpdf "file://$work/zpdf.tar.gz"
"$zig" build run
head -c 5 hello.pdf | grep -q '%PDF-'
echo "consumer: a package that depends on zpdf built, ran and wrote a PDF"
