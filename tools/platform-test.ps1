# One Windows machine's part of tools/test-platforms.sh, run there by herd-run:
#
#   platform-test.ps1 <commit>
#
# A fresh clone of $HOME\zpdf-platform-test.bundle into $HOME\zpdf-platform-test, which must be at
# <commit>; then zig build test and dotnet-test with the Zig that build.zig.zon names. That Zig is
# installed into C:\tools on first use, from ziglang.org's download index, and its SHA-256 is checked
# against the one the index publishes. Each suite must print its own test count: a cached test step
# prints "test success" with no count. Exit 0 when both ran and passed, 1 when either failed or did not
# run, 2 when the clone or the Zig download is wrong.
$ErrorActionPreference = 'Stop'
$want = $args[0]
$dir = Join-Path $HOME 'zpdf-platform-test'
if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
git -c advice.detachedHead=false clone -q (Join-Path $HOME 'zpdf-platform-test.bundle') $dir
if ($LASTEXITCODE -ne 0) { exit 2 }
Set-Location $dir
$got = git rev-parse --short=12 HEAD
if ($got -ne $want) {
    Write-Output "cloned $got, expected $want"
    exit 2
}

$version = (Select-String -Path 'build.zig.zon' -Pattern '\.minimum_zig_version = "([^"]+)"').Matches[0].Groups[1].Value
$zigDir = "C:\tools\zig-x86_64-windows-$version"
$zig = Join-Path $zigDir 'zig.exe'
if (-not (Test-Path $zig)) {
    $entry = (Invoke-RestMethod 'https://ziglang.org/download/index.json').$version.'x86_64-windows'
    $zip = Join-Path $env:TEMP "zig-x86_64-windows-$version.zip"
    Invoke-WebRequest $entry.tarball -OutFile $zip
    $sha = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
    if ($sha -ne $entry.shasum) {
        Write-Output "zig $version download: SHA-256 $sha, the index says $($entry.shasum)"
        exit 2
    }
    Expand-Archive $zip -DestinationPath 'C:\tools' -Force
    Remove-Item $zip
}
Write-Output "Windows x64, zig $(& $zig version), zpdf $got"

$testLog = Join-Path $env:TEMP 'zpdf-platform-test.log'
$dotnetLog = Join-Path $env:TEMP 'zpdf-platform-dotnet.log'
& $zig build test --summary all *> $testLog
$t = $LASTEXITCODE
Select-String -Path $testLog -Pattern 'Build Summary|run test \d+ pass' | ForEach-Object { $_.Line }
if (-not (Select-String -Path $testLog -Pattern 'run test \d+ pass' -Quiet)) {
    Write-Output "no 'run test N pass' line: the unit tests did not run (log: $testLog)"
    $t = 3
}
& $zig build dotnet-test *> $dotnetLog
$d = $LASTEXITCODE
Select-String -Path $dotnetLog -Pattern 'Passed!|Failed!' | ForEach-Object { $_.Line }
if (-not (Select-String -Path $dotnetLog -Pattern 'Passed!.*Total: +[1-9]' -Quiet)) {
    Write-Output "no 'Passed! ... Total: N' line: the .NET tests did not run (log: $dotnetLog)"
    $d = 3
}
Write-Output "zig build test exit=$t, dotnet-test exit=$d"
if ($t -ne 0 -or $d -ne 0) { exit 1 }
exit 0
