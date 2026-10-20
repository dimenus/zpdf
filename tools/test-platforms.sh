#!/usr/bin/env bash
# zig build test and dotnet-test on other machines, from this checkout's HEAD, each machine in a shell
# pane that herd-run can reach. With this machine's own `tools/zig build test`, that covers the
# platforms CI covers, before anything is pushed.
#
#   tools/test-platforms.sh <linux|windows> <machine> <pane> [<linux|windows> <machine> <pane>]...
#
# Needs `herd-run` on PATH, or HERD_RUN set to it (its docstring has the protocol: it checks each
# script before it runs, and reports a run that never started at once). HEAD is what is tested, so a
# tree with uncommitted changes is refused.
#
# Each machine gets HEAD as a git bundle (zpdf-platform-test.bundle in its home directory) and runs
# tools/platform-test.sh (linux) or tools/platform-test.ps1 (windows) from this checkout: a fresh
# clone, so no earlier build's cache can stand in for this run, and both suites must print their own
# test counts. The machines run at the same time; each one's output is printed when all are done.
# Exit 1 when any machine failed, 2 on bad usage.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  echo "usage: tools/test-platforms.sh <linux|windows> <machine> <pane> [<linux|windows> <machine> <pane>]..." >&2
  exit 2
}
herd_run=${HERD_RUN:-herd-run}
if ! command -v "$herd_run" > /dev/null; then
  echo "test-platforms: herd-run not found; put it on PATH or set HERD_RUN" >&2
  exit 2
fi
if [ $# -lt 3 ] || [ $(($# % 3)) -ne 0 ]; then
  usage
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "test-platforms: the tree has uncommitted changes, and the machines would test HEAD without them" >&2
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git bundle create -q "$work/zpdf-platform-test.bundle" HEAD
head=$(git rev-parse --short=12 HEAD)
echo "testing $head"

names=()
pids=()
while [ $# -gt 0 ]; do
  os=$1 machine=$2 pane=$3
  shift 3
  case $os in
    linux) script=tools/platform-test.sh ;;
    windows) script=tools/platform-test.ps1 ;;
    *) usage ;;
  esac
  "$herd_run" --machine "$machine" "$pane" "$script" --file "$work/zpdf-platform-test.bundle" \
    --timeout 3600 -- "$head" > "$work/$machine.out" 2>&1 &
  names+=("$os $machine")
  pids+=($!)
done

failed=0
for i in "${!pids[@]}"; do
  if wait "${pids[$i]}"; then
    status=passed
  else
    status="FAILED (herd-run exit $?)"
    failed=1
  fi
  machine=${names[$i]#* }
  echo "== ${names[$i]}: $status"
  cat "$work/$machine.out"
done
exit "$failed"
