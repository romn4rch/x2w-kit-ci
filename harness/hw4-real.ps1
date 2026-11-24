# Real run of the hw4 kit on a GitHub-hosted Windows runner under Windows PowerShell 5.1: a checkout
# like a volunteer laptop (local main at c639a01 with a local edit that the kit must not touch), the real MSVC
# build, the real SPIR-V tool build, real CTest and the real offscreen_check. The runner has no Intel
# or NVIDIA GPU, so those runs fail by design; WARP runs are real. Only Read-Host is replaced.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here
$kit = Join-Path $repo 'kit\x2w-hw4.ps1'
$out = 'C:\x2w-check\hw4'
$work = 'C:\x2w-dev'
$src = Join-Path $work 'src'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$report = New-Object System.Collections.Generic.List[string]
function Note([string]$Text) { $report.Add($Text); Write-Host $Text }
function Run([string]$Exe, [string[]]$Arguments) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $lines = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    return [pscustomobject]@{ Code = $code; Text = ($lines -join "`n") }
}
Note ('PowerShell ' + $PSVersionTable.PSVersion + ' (' + $PSVersionTable.PSEdition + '), ' + [Environment]::OSVersion.VersionString)
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($kit, [ref]$tokens, [ref]$errors)
Note ('parse errors: ' + @($errors).Count)
foreach ($e in @($errors)) { Note ('  line ' + $e.Extent.StartLineNumber + ': ' + $e.Message) }
$bytes = [IO.File]::ReadAllBytes($kit)
Note ('kit bytes ' + $bytes.Length + ', BOM ' + ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF))

try {
    $r = Run 'git' @('clone', '--quiet', 'https://github.com/R0Y00/Xbox2Windows', $src)
    Note ('clone exit ' + $r.Code)
    $r = Run 'git' @('-C', $src, 'checkout', '-q', '-B', 'main', 'c639a01549f2833b3e5e046030acb92b977b5a26')
    Note ('local main at c639a01: exit ' + $r.Code)
    $r = Run 'python' @('-m', 'venv', (Join-Path $src 'out\pe-env'))
    $py = Join-Path $src 'out\pe-env\Scripts\python.exe'
    $r = Run $py @('-m', 'pip', 'install', '-q', '-r', (Join-Path $src 'requirements-dev.txt'))
    Note ('venv and requirements at c639a01: exit ' + $r.Code)
    Add-Content -LiteralPath (Join-Path $src 'README.md') -Value 'local edit that the kit must not touch'
} catch {
    Note ('setup stopped: ' + $_.Exception.Message)
}

function global:Read-Host { param([string]$Prompt) '' }
$env:X2W_TEST_POWER = 'Online'
$env:X2W_KIT_SUITE_FILTER = '^(vm_copy_queue|spirv_minlod|pixel_aot_f16_round)'
$clock = [Diagnostics.Stopwatch]::StartNew()
& $kit -WorkRoot $work *>&1 | Out-File -Encoding utf8 -FilePath (Join-Path $out 'console.txt')
$code = $LASTEXITCODE
Note ('kit exit ' + $code + ', ' + [int]$clock.Elapsed.TotalMinutes + ' min')
if (Test-Path (Join-Path $work 'hw4-results')) { Copy-Item (Join-Path $work 'hw4-results') (Join-Path $out 'results') -Recurse -Force }
Note ('archive: ' + (Test-Path (Join-Path $work 'x2w-hw4-results.zip')))
Note ('src HEAD: ' + (Run 'git' @('-C', $src, 'rev-parse', 'HEAD')).Text + ', branch ' + (Run 'git' @('-C', $src, 'rev-parse', '--abbrev-ref', 'HEAD')).Text)
Note ('src status: [' + (Run 'git' @('-C', $src, 'status', '--porcelain', '--untracked-files=no')).Text + ']')
Note ('worktrees: [' + ((Run 'git' @('-C', $src, 'worktree', 'list')).Text -replace "`n", ' | ') + ']')
Note ('wt448 left behind: ' + (Test-Path (Join-Path $work 'wt448')))
if (Test-Path (Join-Path $work 'hw4-results\system.txt')) {
    foreach ($l in [IO.File]::ReadAllLines((Join-Path $work 'hw4-results\system.txt'))) { Note ('  | ' + $l) }
}
[IO.File]::WriteAllLines((Join-Path $out 'report.txt'), $report)
exit 0
