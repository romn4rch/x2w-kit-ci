# Independent review of one pull request head on a GitHub-hosted Windows runner (WARP only):
# build offscreen_check, run the new draw and its binary16 neighbours, then a truncation -> round negative control.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg = @{}
foreach ($line in [IO.File]::ReadAllLines((Join-Path $here 'target.env'))) {
    if ($line -match '^(\w+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim() }
}
$PR = $cfg['PR']
$SHA = $cfg['SHA']
$out = 'C:\review-out'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$summary = Join-Path $out 'summary.txt'
function Note([string]$Text) { Add-Content -LiteralPath $summary -Value $Text -Encoding UTF8; Write-Host $Text }
function Run([string]$Name, [string]$Exe, [string[]]$Arguments) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $lines = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    [IO.File]::WriteAllLines((Join-Path $out ($Name + '.txt')), [string[]]$lines)
    Note ('{0}: exit {1}, {2} s' -f $Name, $code, [int]$clock.Elapsed.TotalSeconds)
    return $code
}
$src = 'C:\rv\src'
New-Item -ItemType Directory -Force -Path 'C:\rv' | Out-Null
$null = Run 'clone' 'git' @('clone', '--quiet', 'https://github.com/R0Y00/Xbox2Windows', $src)
Set-Location -LiteralPath $src
$null = Run 'fetch' 'git' @('fetch', '--quiet', 'origin', ('pull/' + $PR + '/head:pr' + $PR))
$null = Run 'checkout' 'git' @('checkout', '--quiet', $SHA)
Note ('head under test: ' + (& git rev-parse HEAD))
Note ('windows: ' + [Environment]::OSVersion.VersionString)
$null = Run 'venv' 'python' @('-m', 'venv', 'out\pe-env')
$null = Run 'pip' (Join-Path $src 'out\pe-env\Scripts\python.exe') @('-m', 'pip', 'install', '-q', '-r', 'requirements-dev.txt')
. (Join-Path $src 'tools\dev.ps1')
Set-Location -LiteralPath $src
Note ('VCToolsVersion: ' + $env:VCToolsVersion)
$dxc = Get-Command dxc -ErrorAction SilentlyContinue
if ($dxc) {
    Note ('dxc: ' + $dxc.Source)
    Note ('dxc version: ' + ((& $dxc.Source --version 2>&1 | ForEach-Object { "$_" }) -join ' '))
} else {
    Note 'dxc: not found on PATH'
}
$null = Run 'configure' 'cmake' @('--preset', 'dev')
$null = Run 'build' 'cmake' @('--build', '--preset', 'dev', '--target', 'offscreen_check')
$null = Run 'ctest-list' 'ctest' @('--preset', 'dev', '-N', '-R', '^pixel_aot_f16_')
$null = Run 'warp-f16-to-int16' 'ctest' @('--preset', 'dev', '--no-tests=error', '-R', '^pixel_aot_f16_to_int16_warp$', '-V')
$null = Run 'warp-f16-to-int16-repeat2' 'ctest' @('--preset', 'dev', '--no-tests=error', '-R', '^pixel_aot_f16_to_int16_warp$', '-V')
$null = Run 'warp-f16-to-int16-repeat3' 'ctest' @('--preset', 'dev', '--no-tests=error', '-R', '^pixel_aot_f16_to_int16_warp$', '-V')
$null = Run 'warp-f16-family' 'ctest' @('--preset', 'dev', '--no-tests=error', '-R', '^pixel_aot_f16_.*_warp$')
# Negative control: truncation replaced by round to nearest in the emitted lowering.
$file = Join-Path $src 'tools\pixel_aot.py'
$text = [IO.File]::ReadAllText($file)
$mutated = $text.Replace('int(trunc(hs{i}))', 'int(round(hs{i}))')
if ($mutated -ne $text) {
    [IO.File]::WriteAllText($file, $mutated)
    Note 'mutation applied: int(trunc(hs{i})) -> int(round(hs{i})) in tools\pixel_aot.py'
    $null = Run 'warp-f16-to-int16-mutated' 'ctest' @('--preset', 'dev', '--no-tests=error', '-R', '^pixel_aot_f16_to_int16_warp$', '-V')
    $null = Run 'restore' 'git' @('checkout', '--', 'tools/pixel_aot.py')
    Note ('mutation restored, git status: [' + ((& git status --porcelain --untracked-files=no) -join ' ') + ']')
} else {
    Note 'mutation pattern not found'
}
exit 0
