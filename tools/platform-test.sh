#!/usr/bin/env bash
# One Linux machine's part of tools/test-platforms.sh, run there by herd-run:
#
#   platform-test.sh <commit>
#
# A fresh clone of $HOME/zpdf-platform-test.bundle into $HOME/zpdf-platform-test, which must be at
# <commit>; then zig build test, dotnet-test, tools/test-valgrind.sh with this machine's own
# valgrind, and tools/consumer-test.sh. Each must print its own result: a test count ("test
# success" with no count is a cached step, and once passed for a run that never happened),
# valgrind's "valgrind clean (N tests", with libzpdf's static run in it, and the consumer's line.
# Exit 0 when all four ran and passed, 1 when any failed or did not run, 2 when the clone is wrong.
set -uo pipefail
want=$1
dir="$HOME/zpdf-platform-test"
rm -rf "$dir"
git -c advice.detachedHead=false clone -q "$HOME/zpdf-platform-test.bundle" "$dir" || exit 2
cd "$dir" || exit 2
got=$(git rev-parse --short=12 HEAD)
if [ "$got" != "$want" ]; then
  echo "cloned $got, expected $want"
  exit 2
fi
echo "$(uname -sm), zpdf $got"

tools/zig build test --summary all > /tmp/zpdf-platform-test.log 2>&1
t=$?
grep -E "Build Summary|run test [0-9]+ pass" /tmp/zpdf-platform-test.log
if ! grep -qE "run test [0-9]+ pass" /tmp/zpdf-platform-test.log; then
  echo "no 'run test N pass' line: the unit tests did not run (log: /tmp/zpdf-platform-test.log)"
  t=3
fi
tools/zig build dotnet-test > /tmp/zpdf-platform-dotnet.log 2>&1
d=$?
grep -E "Passed!|Failed!" /tmp/zpdf-platform-dotnet.log
if ! grep -qE "Passed!.*Total: +[1-9]" /tmp/zpdf-platform-dotnet.log; then
  echo "no 'Passed! ... Total: N' line: the .NET tests did not run (log: /tmp/zpdf-platform-dotnet.log)"
  d=3
fi
tools/test-valgrind.sh > /tmp/zpdf-platform-valgrind.log 2>&1
v=$?
grep -E "^canary:|tests executed under valgrind|^valgrind clean|^FATAL" /tmp/zpdf-platform-valgrind.log
if ! grep -qE "^valgrind clean \([1-9][0-9]* tests, and libzpdf under abi-test: .*static on musl" /tmp/zpdf-platform-valgrind.log; then
  echo "no 'valgrind clean (N tests, and libzpdf under abi-test: ... static on musl' line (log: /tmp/zpdf-platform-valgrind.log)"
  v=3
fi
tools/consumer-test.sh > /tmp/zpdf-platform-consumer.log 2>&1
c=$?
grep -E "^consumer:" /tmp/zpdf-platform-consumer.log
if ! grep -qE "^consumer: a package that depends on zpdf built" /tmp/zpdf-platform-consumer.log; then
  echo "no 'consumer: ...' line: the consumer package did not build or run (log: /tmp/zpdf-platform-consumer.log)"
  c=3
fi
echo "zig build test exit=$t, dotnet-test exit=$d, test-valgrind exit=$v, consumer-test exit=$c"
if [ "$t" -ne 0 ] || [ "$d" -ne 0 ] || [ "$v" -ne 0 ] || [ "$c" -ne 0 ]; then
  exit 1
fi
