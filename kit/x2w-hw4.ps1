#requires -Version 5.1
<#
.SYNOPSIS
  Xbox2Windows: прогон hw4 на ноутбуке (#448, #874, #809, #768, #839, #966).
.DESCRIPTION
  Работает рядом со сборкой из x2w-dev.ps1 (%USERPROFILE%\x2w-dev\src), но саму папку src не трогает:
  для прогона заводит отдельную копию исходников %USERPROFILE%\x2w-dev\hw (git worktree).
  Части (ключ -Parts, через запятую):
    update - ставит копию hw на коммит main 45b3c5d, собирает закреплённые SPIR-V инструменты
             (tools\setup-spirv-tools.ps1) и весь проект.
    timing - #448: время pixel_aot до и после разделения draw-core (PR #1049) на одном драйвере.
             Отдельная копия исходников (git worktree): коммит до слияния и коммит слияния.
             NVIDIA 3 раза + Intel 1 раз для каждого, плюс прогоны без лимита CTest и контрольный
             повтор «до» в конце. Копия потом удаляется.
    copyq  - #874: независимая проверка COPY -> DIRECT (vm_copy_queue_check, сборка release),
             Intel и NVIDIA по 3 раза, WARP 1 раз.
    bridge - #809 и #768: мостовые SPIR-V тесты spirv_minlod* и spirv_compaction на Intel, NVIDIA и WARP.
    f16    - #839: перевод half -> int16/uint16 из PR #1077 (pixel_aot_f16_to_int16) на Intel и NVIDIA
             по 3 раза, WARP 1 раз.
    suite  - #966: все тесты _hardware на NVIDIA и на Intel, все тесты _warp; каждый красный тест
             повторяется ещё 2 раза.
  Всего около полутора часов, ноутбук на зарядке. Если одна часть сломается, остальные всё равно
  пройдут. Итоги - в x2w-hw4-results.zip на рабочем столе. Путь профиля, имя пользователя и
  компьютера в логах заменяются.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\x2w-hw4.ps1
#>
[CmdletBinding()]
param(
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'x2w-dev'),
    [string]$Intel = 'Intel',
    [string]$Nvidia = 'NVIDIA',
    [string]$Commit = '45b3c5d247e33c740beff7b2e207c745741091e7',
    [string]$SplitMerge = '4ad7b0a212825c8369e866b8d16228437970acf2',
    [string]$Parts = 'update,timing,copyq,bridge,f16,suite'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$KitVersion = '2'
$Src = Join-Path $WorkRoot 'src'
$Hw = Join-Path $WorkRoot 'hw'
$Res = Join-Path $WorkRoot 'hw4-results'
$Wt = Join-Path $WorkRoot 'wt448'
$Build = Join-Path $Hw 'out\build\dev'
$Renderer = Join-Path $Build 'offscreen_check.exe'
$VenvPy = Join-Path $Src 'out\pe-env\Scripts\python.exe'
$SdkDxc = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe'
$SpirvBin = Join-Path $Hw 'out\tools\spirv\bin'
$Upstream = 'https://github.com/R0Y00/Xbox2Windows.git'
$PartList = @($Parts -split '[,; ]+' | Where-Object { $_ } | ForEach-Object { $_.ToLower() })
# Test-only narrowing of the suite part (the kit check on a hosted runner sets it); empty on the laptop.
$SuiteFilter = [string]$env:X2W_KIT_SUITE_FILTER

function F([string]$Format) {
    # Invariant-culture formatting, so decimals use a dot in the logs.
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, $Format, [object[]]$args)
}

function Write-Step([string]$Text) { Write-Host ''; Write-Host ('==> ' + $Text) -ForegroundColor Cyan }
function Write-Note([string]$Text) { Write-Host ('    ' + $Text) }
function Write-Warn([string]$Text) { Write-Host ('!!  ' + $Text) -ForegroundColor Yellow }

$Personal = New-Object System.Collections.Generic.List[object]
function Add-Personal([string]$Value, [string]$Label) {
    if (-not $Value -or $Value.Length -lt 4) { return }
    # Plain, forward-slash and doubled-backslash spellings (the last one appears in Python reprs).
    foreach ($v in @($Value.Replace('\', '\\'), $Value, $Value.Replace('\', '/'))) {
        $Personal.Add([pscustomobject]@{ Value = $v; Label = $Label })
    }
}
Add-Personal $env:USERPROFILE '%USERPROFILE%'
try {
    $short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($env:USERPROFILE).ShortPath
    if ($short -and $short -ne $env:USERPROFILE) {
        Add-Personal $short '%USERPROFILE%'
        Add-Personal (Split-Path -Leaf $short) '%USERNAME%'
    }
} catch { }
Add-Personal $env:COMPUTERNAME '%COMPUTERNAME%'
Add-Personal $env:USERNAME '%USERNAME%'
Add-Personal (Split-Path -Leaf $env:USERPROFILE) '%USERNAME%'

function Hide-Personal([string]$Text) {
    if (-not $Text) { return $Text }
    foreach ($p in $Personal) {
        $Text = [regex]::Replace($Text, [regex]::Escape($p.Value), $p.Label.Replace('$', '$$'), 'IgnoreCase')
    }
    return $Text
}

function Save-Text([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, (Hide-Personal $Text), (New-Object System.Text.UTF8Encoding($false)))
}

function Add-Line([string]$Text) {
    $script:sys.Add($Text)
    Write-Note $Text
}

function Invoke-Logged([string]$Exe, [string[]]$Arguments, [string]$LogPath, [switch]$Show) {
    # Runs a program, keeps its output (stdout and stderr) and measures the wall time.
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $lines = @(& $Exe @Arguments 2>&1 | ForEach-Object { $s = "$_"; if ($Show) { Write-Host $s }; $s })
        $code = $LASTEXITCODE
    } catch {
        $lines = @($_.Exception.Message)
        $code = -1
    } finally {
        $ErrorActionPreference = $old
    }
    $clock.Stop()
    $text = ($lines -join "`r`n")
    if ($LogPath) {
        $head = ('> ' + $Exe + ' ' + ($Arguments -join ' ') + "`r`n" + (F 'exit {0}, {1:0.00} s' $code ($clock.Elapsed.TotalSeconds)) + "`r`n")
        Save-Text $LogPath ($head + $text + "`r`n")
    }
    return [pscustomobject]@{ Code = $code; Seconds = $clock.Elapsed.TotalSeconds; Text = $text }
}

function Get-Text([string]$Exe, [string[]]$Arguments) {
    $r = Invoke-Logged $Exe $Arguments ''
    return [pscustomobject]@{ Code = $r.Code; Text = $r.Text.Trim() }
}

function Set-Adapter([string]$Name) {
    if ($Name) { $env:XBOX2WINDOWS_ADAPTER = $Name }
    elseif (Test-Path Env:XBOX2WINDOWS_ADAPTER) { Remove-Item Env:XBOX2WINDOWS_ADAPTER }
}

function Get-Header([string]$Text) {
    $parts = @()
    foreach ($key in @('debug_layer', 'adapter', 'driver')) {
        $m = [regex]::Match($Text, '(?m)' + $key + '=([^\r\n]*)')
        if ($m.Success) { $parts += ($key + '=' + $m.Groups[1].Value.Trim()) }
    }
    return ($parts -join '; ')
}

function Get-TestTimes([string]$Text) {
    $times = @([regex]::Matches($Text, 'Test\s+#\d+:\s+(\S+)\s+\.+\s*(\*\*\*)?(\w+)\s+([\d.]+) sec') | ForEach-Object {
        $_.Groups[1].Value + ' ' + $_.Groups[3].Value + ' ' + $_.Groups[4].Value + ' s' })
    return ($times -join ', ')
}

function Get-Summary([string]$Text) {
    # The CTest summary line and the total time, if present.
    $parts = @()
    $m = [regex]::Match($Text, '(?m)^\s*(\d+% tests passed, \d+ tests failed out of \d+)')
    if ($m.Success) { $parts += $m.Groups[1].Value }
    $m = [regex]::Match($Text, '(?m)^\s*Total Test time \(real\) =\s*([\d.]+) sec')
    if ($m.Success) { $parts += ('total ' + $m.Groups[1].Value + ' s') }
    return ($parts -join '; ')
}

function Get-Failed([string]$Text) {
    # Names and reasons from the CTest "The following tests FAILED" list.
    $list = @()
    $i = $Text.IndexOf('The following tests FAILED')
    if ($i -lt 0) { return $list }
    foreach ($m in [regex]::Matches($Text.Substring($i), '(?m)^\s*\d+\s+-\s+(\S+)\s+\(([^)]+)\)')) {
        $list += [pscustomobject]@{ Name = $m.Groups[1].Value; Reason = $m.Groups[2].Value }
    }
    return $list
}

function Get-Power {
    # The power line state as Windows reports it (Online, Offline or Unknown), plus the battery charge.
    $line = 'Unknown'
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $line = [string][System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
    } catch { }
    if ($env:X2W_TEST_POWER) { $line = $env:X2W_TEST_POWER }
    $extra = ''
    try {
        $b = @(Get-CimInstance Win32_Battery)
        if ($b.Count -gt 0) { $extra = ', charge ' + $b[0].EstimatedChargeRemaining + '%, battery status ' + $b[0].BatteryStatus }
    } catch { }
    return [pscustomobject]@{ Line = $line; Text = ('power line ' + $line + $extra) }
}

function Wait-Charger([int]$Seconds) {
    # Gives the charger a chance without blocking the run: polls for up to $Seconds.
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $p = Get-Power
    if ($p.Line -eq 'Offline') {
        Write-Warn 'Ноутбук работает от батареи. Подключи зарядку: без неё замеры времени неточные.'
    }
    while ($p.Line -eq 'Offline' -and $clock.Elapsed.TotalSeconds -lt $Seconds) {
        Start-Sleep -Seconds 5
        $p = Get-Power
    }
    return $p.Text
}

function Remove-Worktree {
    # Drops the timing copy of the sources (and its build tree) if a previous run left it behind.
    $null = Get-Text 'git' @('-C', $Src, 'worktree', 'prune')
    if (Test-Path -LiteralPath $Wt) {
        $null = Get-Text 'git' @('-C', $Src, 'worktree', 'remove', '--force', $Wt)
    }
    if (Test-Path -LiteralPath $Wt) {
        Remove-Item -LiteralPath $Wt -Recurse -Force -ErrorAction SilentlyContinue
        $null = Get-Text 'git' @('-C', $Src, 'worktree', 'prune')
    }
    return (-not (Test-Path -LiteralPath $Wt))
}

function Invoke-WtBuild([string]$Tag) {
    # Builds offscreen_check in the timing copy; CMake regenerates itself when CMakeLists.txt changed.
    Set-Location -LiteralPath $Wt
    $r = Invoke-Logged 'cmake' @('--build', '--preset', 'dev', '--target', 'offscreen_check') (Join-Path $Res ('timing-build-' + $Tag + '.txt'))
    return $r
}

function Invoke-Timing([string]$Tag, [string]$Adapter, [string]$Regex, [int]$Index) {
    Set-Location -LiteralPath $Wt
    Set-Adapter $Adapter
    $p = (Get-Power).Text
    $log = Join-Path $Res ('timing-' + $Tag + '-' + $Index + '.txt')
    $r = Invoke-Logged 'ctest' @('--preset', 'dev', '--no-tests=error', '-R', $Regex, '-j', '1', '-V') $log
    Add-Line (F 'timing {0} #{1}: exit {2}, wall {3:0.00} s; {4}; {5}' $Tag $Index ($r.Code) ($r.Seconds) (Get-TestTimes $r.Text) $p)
    return $r
}

function Invoke-Direct([string]$Tag, [string]$Mode) {
    # The command CTest runs for one entry, without its 60 s limit.
    $wtBuild = Join-Path $Wt 'out\build\dev'
    Set-Location -LiteralPath $wtBuild
    Set-Adapter $Nvidia
    $p = (Get-Power).Text
    $r = Invoke-Logged $VenvPy @('-B', (Join-Path $Wt 'tests\pixel_aot_check.py'), $Mode, $SdkDxc, (Join-Path $wtBuild 'offscreen_check.exe'), 'hardware') (Join-Path $Res ('timing-' + $Tag + '-direct-' + $Mode + '.txt'))
    Add-Line (F 'timing {0} NVIDIA direct {1} (no CTest limit): exit {2}, {3:0.00} s; {4}' $Tag $Mode ($r.Code) ($r.Seconds) $p)
    Set-Location -LiteralPath $Wt
}

New-Item -ItemType Directory -Force -Path $Res | Out-Null
Get-ChildItem -LiteralPath $Res -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
$sys = New-Object System.Collections.Generic.List[string]
$sys.Add('Xbox2Windows hardware run 4 (kit hw4 v' + $KitVersion + ')')
$sys.Add('Date (UTC): ' + [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm'))
$sys.Add('Parts: ' + ($PartList -join ','))
if ($SuiteFilter) { $sys.Add('Suite filter (kit check only): ' + $SuiteFilter) }
$done = New-Object System.Collections.Generic.List[string]
$exitCode = 0
$startDir = (Get-Location).Path
$runClock = [Diagnostics.Stopwatch]::StartNew()
try {
    Write-Host 'Xbox2Windows: прогон hw4 (около полутора часов, ноутбук на зарядке, окно не закрывать)' -ForegroundColor Green

    # 0. What we work with
    Write-Step 'Проверяю сборку и питание'
    if (-not (Test-Path -LiteralPath (Join-Path $Src '.git')) -or -not (Test-Path -LiteralPath $VenvPy)) {
        throw 'Не нашёл сборку в %USERPROFILE%\x2w-dev\src. Сначала нужен x2w-dev.ps1.'
    }
    if (-not (Test-Path -LiteralPath $SdkDxc)) { throw 'Нет dxc.exe из Windows SDK 10.0.26100.' }
    $power = Get-Power
    if ($power.Line -eq 'Offline') {
        Write-Warn 'Ноутбук работает от батареи, а для замеров времени нужна зарядка.'
        [void](Read-Host 'Подключи зарядку и нажми Enter')
        $power = Get-Power
    }
    Add-Line ('Power at start: ' + $power.Text)
    try { Add-Line ('Power plan: ' + ((Get-Text 'powercfg' @('/getactivescheme')).Text -replace '^.*:\s*', '')) } catch { }
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    Add-Line ('Windows build ' + $cv.CurrentBuild + '.' + $cv.UBR + ' (' + $cv.DisplayVersion + ')')
    foreach ($g in @(Get-CimInstance Win32_VideoController)) {
        $m = [regex]::Match([string]$g.PNPDeviceID, 'VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})')
        $ids = ''
        if ($m.Success) { $ids = (' (vendor={0} device={1})' -f $m.Groups[1].Value, $m.Groups[2].Value) }
        Add-Line ('GPU: ' + $g.Name + $ids + ', driver ' + $g.DriverVersion)
    }
    try {
        $cpu = @(Get-CimInstance Win32_Processor)[0]
        Add-Line ('CPU: ' + ([string]$cpu.Name).Trim() + ', ' + $cpu.NumberOfCores + ' cores, ' + $cpu.NumberOfLogicalProcessors + ' threads')
    } catch { }
    # The user's checkout is only read: its branch, its last commit and whether it has local changes.
    Add-Line ('Checkout src: branch ' + (Get-Text 'git' @('-C', $Src, 'rev-parse', '--abbrev-ref', 'HEAD')).Text +
              ', ' + (Get-Text 'git' @('-C', $Src, 'log', '-1', '--format=%h %cI')).Text +
              ', local changes: ' + [bool](Get-Text 'git' @('-C', $Src, 'status', '--porcelain', '--untracked-files=no')).Text)
    try {
        $drive = Get-PSDrive -Name ($WorkRoot.Substring(0, 1)) -ErrorAction Stop
        Add-Line (F 'Free disk space on {0}: {1:0.0} GB' ($drive.Name + ':') ($drive.Free / 1GB))
        if ($drive.Free -lt 20GB) { Write-Warn 'Места на диске меньше 20 ГБ; сборке может не хватить.' }
    } catch { }

    # 1. The run's own copy of the sources at the pinned main commit, the pinned SPIR-V tools, a full build
    if ($PartList -contains 'update') {
        Write-Step ('Готовлю копию исходников на ' + $Commit.Substring(0, 7) + ', SPIR-V инструменты и полную сборку (20-40 минут)')
        $f = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            # a short network hiccup should not cost the run
            $f = Invoke-Logged 'git' @('-C', $Src, 'fetch', $Upstream, 'main') (Join-Path $Res 'git-fetch.txt')
            if ($f.Code -eq 0) { break }
            Start-Sleep -Seconds 10
        }
        Add-Line ('update: fetch of upstream main exit ' + $f.Code)
        $known = (Get-Text 'git' @('-C', $Src, 'cat-file', '-e', ($Commit + '^{commit}'))).Code -eq 0
        if (-not $known) { throw ('Коммит ' + $Commit.Substring(0, 7) + ' не скачался; проверь интернет и запусти ещё раз.') }
        $isTree = (Test-Path -LiteralPath (Join-Path $Hw '.git')) -and
                  ((Get-Text 'git' @('-C', $Hw, 'rev-parse', '--is-inside-work-tree')).Text -eq 'true')
        if ($isTree) {
            $co = Invoke-Logged 'git' @('-C', $Hw, 'checkout', '--detach', '--force', $Commit) (Join-Path $Res 'git-checkout.txt')
            Add-Line ('update: copy hw moved to ' + $Commit.Substring(0, 7) + ', exit ' + $co.Code)
        } else {
            if (Test-Path -LiteralPath $Hw) { Remove-Item -LiteralPath $Hw -Recurse -Force -ErrorAction SilentlyContinue }
            $null = Get-Text 'git' @('-C', $Src, 'worktree', 'prune')
            $co = Invoke-Logged 'git' @('-C', $Src, 'worktree', 'add', '--detach', $Hw, $Commit) (Join-Path $Res 'git-worktree.txt')
            Add-Line ('update: copy hw created at ' + $Commit.Substring(0, 7) + ', exit ' + $co.Code)
        }
        if ($co.Code -ne 0) { throw 'Не получилось подготовить копию исходников hw.' }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Hw '.git'))) { throw 'Нет копии исходников hw; нужен запуск с частью update.' }
    Add-Line ('Source (hw): ' + (Get-Text 'git' @('-C', $Hw, 'log', '-1', '--format=%H %cI %s')).Text)
    $hasCommit = (Get-Text 'git' @('-C', $Hw, 'merge-base', '--is-ancestor', $Commit, 'HEAD')).Code -eq 0
    Add-Line ('Source contains ' + $Commit.Substring(0, 7) + ': ' + $hasCommit)

    Write-Step 'Включаю среду сборки Visual Studio (tools\dev.ps1)'
    $env:VSLANG = '1033'
    & (Join-Path $Hw 'tools\dev.ps1')
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    Set-Location -LiteralPath $Hw
    $env:PYTHONUTF8 = '1'
    if (Test-Path Env:X2W_REQUIRE_SPIRV_TOOLS) { Remove-Item Env:X2W_REQUIRE_SPIRV_TOOLS }
    Add-Line ('MSVC: ' + $env:VCToolsVersion)
    Add-Line ('CMake: ' + ((Get-Text 'cmake' @('--version')).Text -split "`r?`n")[0])
    Add-Line ('DXC: ' + ((Get-Text $SdkDxc @('--version')).Text -split "`r?`n")[0])
    Add-Line ('Python: ' + (Get-Text $VenvPy @('--version')).Text)
    Add-Line ('Git: ' + (Get-Text 'git' @('--version')).Text)

    if ($PartList -contains 'update') {
        $pip = Invoke-Logged $VenvPy @('-m', 'pip', 'install', '-q', '-r', (Join-Path $Hw 'requirements-dev.txt')) (Join-Path $Res 'pip.txt')
        Add-Line (F 'Python packages (requirements-dev.txt): exit {0}, {1:0} s' ($pip.Code) ($pip.Seconds))
        $sp = Invoke-Logged 'powershell' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Hw 'tools\setup-spirv-tools.ps1'), '-Python', $VenvPy) (Join-Path $Res 'spirv-tools.txt')
        Add-Line (F 'SPIR-V tools (tools\setup-spirv-tools.ps1): exit {0}, {1:0} s' ($sp.Code) ($sp.Seconds))
        Set-Location -LiteralPath $Hw
        $cf = Invoke-Logged 'cmake' @('--preset', 'dev', ('-DINTAKE_PYTHON=' + $VenvPy)) (Join-Path $Res 'configure-dev.txt')
        Add-Line (F 'Configure (cmake --preset dev): exit {0}, {1:0} s' ($cf.Code) ($cf.Seconds))
        $cache = Join-Path $Build 'CMakeCache.txt'
        if (Test-Path -LiteralPath $cache) {
            $m = [regex]::Match([IO.File]::ReadAllText($cache), '(?m)^DXC_EXECUTABLE:FILEPATH=(.*)$')
            if ($m.Success) { Add-Line ('  DXC used by CTest: ' + $m.Groups[1].Value.Trim()) }
        }
        foreach ($tool in @('spirv-as.exe', 'spirv-val.exe', 'spirv-cross.exe')) {
            Add-Line ('  ' + $tool + ' present: ' + (Test-Path -LiteralPath (Join-Path $SpirvBin $tool)))
        }
        $c = Invoke-Logged 'cmake' @('--build', '--preset', 'dev') (Join-Path $Res 'build-main.txt')
        Add-Line (F 'Build (cmake --build --preset dev): exit {0}, {1:0} s' ($c.Code) ($c.Seconds))
        if ($c.Code -ne 0) { Write-Warn 'Полная сборка не прошла; остальные части попробую всё равно.' }
        $done.Add('update')
    }
    if (Test-Path -LiteralPath $Renderer) {
        Set-Adapter $Intel
        $probe = Invoke-Logged $Renderer @('hardware', '--texture-mips') (Join-Path $Res 'debug-layer-check.txt')
        Add-Line ('Renderer on Intel: ' + (Get-Header $probe.Text))
        Set-Adapter $Nvidia
        $probe = Invoke-Logged $Renderer @('hardware', '--texture-mips') ''
        Add-Line ('Renderer on NVIDIA: ' + (Get-Header $probe.Text))
        Set-Adapter ''
        $probe = Invoke-Logged $Renderer @('warp', '--texture-mips') ''
        Add-Line ('Renderer on WARP: ' + (Get-Header $probe.Text))
    } else {
        Add-Line 'Renderer: offscreen_check.exe not found'
    }

    # 2. #448: pixel_aot before and after the draw-core split, same driver, serial
    if ($PartList -contains 'timing') {
        Write-Step 'Время pixel_aot до и после разделения draw-core (#448): отдельная копия, около 20 минут'
        try {
            Add-Line ('timing: ' + (Wait-Charger 120))
            $old = (Get-Text 'git' @('-C', $Src, 'rev-parse', ($SplitMerge + '^1'))).Text
            $new = (Get-Text 'git' @('-C', $Src, 'rev-parse', $SplitMerge)).Text
            Add-Line ('timing: before the split ' + $old + ', after the split (merge of #1049) ' + $new)
            if ($old -notmatch '^[0-9a-f]{40}$' -or $new -notmatch '^[0-9a-f]{40}$') { throw 'commits not found' }
            if (-not (Remove-Worktree)) { throw 'an old copy at wt448 could not be removed' }
            $w = Invoke-Logged 'git' @('-C', $Src, 'worktree', 'add', '--detach', $Wt, $old) (Join-Path $Res 'timing-worktree.txt')
            if ($w.Code -ne 0) { throw ('git worktree add failed, exit ' + $w.Code) }
            Set-Location -LiteralPath $Wt
            $cf = Invoke-Logged 'cmake' @('--preset', 'dev', ('-DINTAKE_PYTHON=' + $VenvPy)) (Join-Path $Res 'timing-configure.txt')
            Add-Line (F 'timing: configure exit {0}, {1:0} s' ($cf.Code) ($cf.Seconds))
            $b = Invoke-WtBuild 'before'
            Add-Line (F 'timing: build offscreen_check before the split exit {0}, {1:0} s' ($b.Code) ($b.Seconds))
            if ($b.Code -ne 0) { throw 'build before the split failed' }
            $lst = Invoke-Logged 'ctest' @('--preset', 'dev', '-N', '-R', '^pixel_aot_(core_vector_)?hardware$') (Join-Path $Res 'timing-list-before.txt')
            Add-Line ('timing: registered before: ' + (([regex]::Matches($lst.Text, 'Test\s+#\d+:\s+(\S+)') | ForEach-Object { $_.Groups[1].Value }) -join ', '))
            $before = '^pixel_aot_hardware$'
            $after = '^pixel_aot_(core_vector_)?hardware$'
            for ($i = 1; $i -le 3; $i++) { $null = Invoke-Timing 'before-nvidia' $Nvidia $before $i }
            $null = Invoke-Timing 'before-intel' $Intel $before 1
            Invoke-Direct 'before' 'draw-core'
            $co = Invoke-Logged 'git' @('-C', $Wt, 'checkout', '--detach', '--quiet', $new) (Join-Path $Res 'timing-checkout-after.txt')
            $b = Invoke-WtBuild 'after'
            Add-Line (F 'timing: checkout after the split exit {0}; build exit {1}, {2:0} s' ($co.Code) ($b.Code) ($b.Seconds))
            if ($co.Code -ne 0 -or $b.Code -ne 0) { throw 'switching to the split commit failed' }
            $lst = Invoke-Logged 'ctest' @('--preset', 'dev', '-N', '-R', '^pixel_aot_(core_vector_)?hardware$') (Join-Path $Res 'timing-list-after.txt')
            Add-Line ('timing: registered after: ' + (([regex]::Matches($lst.Text, 'Test\s+#\d+:\s+(\S+)') | ForEach-Object { $_.Groups[1].Value }) -join ', '))
            for ($i = 1; $i -le 3; $i++) { $null = Invoke-Timing 'after-nvidia' $Nvidia $after $i }
            $null = Invoke-Timing 'after-intel' $Intel $after 1
            Invoke-Direct 'after' 'draw-core'
            Invoke-Direct 'after' 'draw-core-vector'
            # One more run before the split at the end, to see any drift from heat over the part.
            $co = Invoke-Logged 'git' @('-C', $Wt, 'checkout', '--detach', '--quiet', $old) (Join-Path $Res 'timing-checkout-before-again.txt')
            $b = Invoke-WtBuild 'before-again'
            Add-Line (F 'timing: checkout before the split again exit {0}; build exit {1}, {2:0} s' ($co.Code) ($b.Code) ($b.Seconds))
            if ($co.Code -eq 0 -and $b.Code -eq 0) { $null = Invoke-Timing 'before-nvidia' $Nvidia $before 4 }
            Add-Line ('timing: power at the end: ' + (Get-Power).Text)
            $done.Add('timing')
        } catch {
            Add-Line ('timing: stopped: ' + $_.Exception.Message)
        } finally {
            Set-Adapter ''
            Set-Location -LiteralPath $Hw
            Add-Line ('timing: copy removed: ' + (Remove-Worktree))
        }
    }

    # 3. #874: COPY -> DIRECT cross-page ordering, release preset, as in the task table
    if ($PartList -contains 'copyq') {
        Write-Step 'Проверка COPY -> DIRECT (#874): сборка release и прогоны на Intel, NVIDIA и WARP (около 5 минут)'
        try {
            Set-Location -LiteralPath $Hw
            $cf = Invoke-Logged 'cmake' @('--preset', 'release', ('-DINTAKE_PYTHON=' + $VenvPy)) (Join-Path $Res 'copyq-configure.txt')
            $b = Invoke-Logged 'cmake' @('--build', '--preset', 'release', '--target', 'vm_copy_queue_check') (Join-Path $Res 'copyq-build.txt')
            Add-Line (F 'copyq: configure release exit {0}, {1:0} s; build vm_copy_queue_check exit {2}, {3:0} s' ($cf.Code) ($cf.Seconds) ($b.Code) ($b.Seconds))
            if ($b.Code -ne 0) { throw 'build failed' }
            foreach ($a in @(@($Intel, 'intel'), @($Nvidia, 'nvidia'))) {
                for ($i = 1; $i -le 3; $i++) {
                    Set-Adapter $a[0]
                    $r = Invoke-Logged 'ctest' @('--preset', 'release', '--no-tests=error', '-R', '^vm_(copy_queue|page_provenance)_hardware$', '-V') (Join-Path $Res ('copyq-' + $a[1] + '-' + $i + '.txt'))
                    Add-Line (('copyq {0} #{1}: exit {2}; {3}; {4}' -f $a[1], $i, $r.Code, (Get-Summary $r.Text), (Get-Header $r.Text)))
                }
            }
            Set-Adapter ''
            $r = Invoke-Logged 'ctest' @('--preset', 'release', '--no-tests=error', '-R', '^vm_(copy_queue|page_provenance)_warp$', '-V') (Join-Path $Res 'copyq-warp-1.txt')
            Add-Line (('copyq warp #1: exit {0}; {1}' -f $r.Code, (Get-Summary $r.Text)))
            $done.Add('copyq')
        } catch {
            Add-Line ('copyq: stopped: ' + $_.Exception.Message)
        } finally {
            Set-Adapter ''
            Set-Location -LiteralPath $Hw
        }
    }

    # 4. #809 and #768: the source-built MinLod and subgroup compaction bridge tests on every adapter
    if ($PartList -contains 'bridge') {
        Write-Step 'MinLod (#809) и compaction (#768): мостовые SPIR-V тесты на Intel, NVIDIA и WARP (около 5 минут)'
        try {
            Set-Location -LiteralPath $Hw
            # A missing SPIR-V tool must fail here instead of skipping quietly.
            $env:X2W_REQUIRE_SPIRV_TOOLS = '1'
            $bridge = '^spirv_(compaction|minlod|minlod_exact|minlod_levels|minlod_fractional)'
            foreach ($a in @(@($Intel, 'intel', '_hardware'), @($Nvidia, 'nvidia', '_hardware'), @('', 'warp', '_warp'))) {
                Set-Adapter $a[0]
                $r = Invoke-Logged 'ctest' @('--preset', 'dev', '--no-tests=error', '-R', ($bridge + $a[2] + '$'), '-j', '1', '-V') (Join-Path $Res ('bridge-' + $a[1] + '.txt'))
                Add-Line (('bridge {0}: exit {1}; {2}; {3}' -f $a[1], $r.Code, (Get-Summary $r.Text), (Get-TestTimes $r.Text)))
            }
            $done.Add('bridge')
        } catch {
            Add-Line ('bridge: stopped: ' + $_.Exception.Message)
        } finally {
            Set-Adapter ''
            if (Test-Path Env:X2W_REQUIRE_SPIRV_TOOLS) { Remove-Item Env:X2W_REQUIRE_SPIRV_TOOLS }
        }
    }

    # 5. #839: the binary16 -> int16/uint16 draw of PR #1077 on real GPUs (CI runs it on WARP only)
    if ($PartList -contains 'f16') {
        Write-Step 'Перевод half -> int16 (#839, PR #1077): Intel и NVIDIA по 3 раза, WARP 1 раз (около 5 минут)'
        try {
            Set-Location -LiteralPath $Hw
            foreach ($a in @(@($Intel, 'intel', 'hardware', 3), @($Nvidia, 'nvidia', 'hardware', 3), @('', 'warp', 'warp', 1))) {
                for ($i = 1; $i -le $a[3]; $i++) {
                    Set-Adapter $a[0]
                    $r = Invoke-Logged 'ctest' @('--preset', 'dev', '--no-tests=error', '-R', ('^pixel_aot_f16_to_int16_' + $a[2] + '$'), '-j', '1', '-V') (Join-Path $Res ('f16-' + $a[1] + '-' + $i + '.txt'))
                    Add-Line (('f16 {0} #{1}: exit {2}; {3}; {4}; {5}' -f $a[1], $i, $r.Code, (Get-Summary $r.Text), (Get-TestTimes $r.Text), (Get-Header $r.Text)))
                }
            }
            $done.Add('f16')
        } catch {
            Add-Line ('f16: stopped: ' + $_.Exception.Message)
        } finally {
            Set-Adapter ''
        }
    }

    # 6. #966: every hardware test on both adapters and every WARP test, reds rerun twice
    if ($PartList -contains 'suite') {
        Write-Step 'Полный прогон (#966): все тесты _hardware на NVIDIA и Intel и все _warp (около часа)'
        try {
            Set-Location -LiteralPath $Hw
            $hwRegex = '_hardware$'
            $warpRegex = '_warp$'
            if ($SuiteFilter) {
                $hwRegex = $SuiteFilter + '.*_hardware$'
                $warpRegex = $SuiteFilter + '.*_warp$'
            }
            foreach ($a in @(@($Nvidia, 'nvidia', $hwRegex), @($Intel, 'intel', $hwRegex), @('', 'warp', $warpRegex))) {
                Set-Adapter $a[0]
                $p = (Get-Power).Text
                $junit = Join-Path $Res ('suite-' + $a[1] + '.xml')
                $r = Invoke-Logged 'ctest' @('--preset', 'dev', '--no-tests=error', '-R', $a[2], '-j', '1', '--timeout', '600', '--output-junit', $junit) (Join-Path $Res ('suite-' + $a[1] + '.txt'))
                $failed = @(Get-Failed $r.Text)
                $skipped = @([regex]::Matches($r.Text, '(?m)^\s*\d+/\d+ Test\s+#\d+:\s+(\S+)\s+\.+\s*\*+Skipped') | ForEach-Object { $_.Groups[1].Value })
                Add-Line (F 'suite {0}: exit {1}, wall {2:0} s; {3}; skipped {4}; failed {5}; {6}' $a[1] ($r.Code) ($r.Seconds) (Get-Summary $r.Text) $skipped.Count $failed.Count $p)
                foreach ($s in $skipped) { Add-Line ('  skipped: ' + $s) }
                foreach ($t in $failed) {
                    $line = ('  failed: ' + $t.Name + ' (' + $t.Reason + ')')
                    for ($k = 2; $k -le 3; $k++) {
                        $rr = Invoke-Logged 'ctest' @('--preset', 'dev', '--no-tests=error', '-R', ('^' + [regex]::Escape($t.Name) + '$'), '-j', '1', '--timeout', '600', '-V') (Join-Path $Res ('suite-' + $a[1] + '-' + $t.Name + '-run' + $k + '.txt'))
                        $state = 'passed'
                        if ($rr.Code -ne 0) {
                            $state = 'failed'
                            $again = @(Get-Failed $rr.Text)
                            if ($again.Count -gt 0) { $state = $again[0].Reason }
                        }
                        $line += (F '; run {0}: {1} ({2:0.0} s)' $k $state ($rr.Seconds))
                    }
                    Add-Line $line
                }
            }
            $done.Add('suite')
        } catch {
            Add-Line ('suite: stopped: ' + $_.Exception.Message)
        } finally {
            Set-Adapter ''
        }
    }
} catch {
    $exitCode = 1
    $sys.Add('Stopped: ' + $_.Exception.Message)
    Write-Host ''
    Write-Host ('Остановлено: ' + $_.Exception.Message) -ForegroundColor Red
} finally {
    try {
        Set-Location -LiteralPath $WorkRoot
        if (Test-Path -LiteralPath $Wt) { $null = Remove-Worktree }
    } catch { }
    $sys.Add('Parts finished: ' + ($done -join ','))
    $sys.Add((F 'Total time: {0:0} min' ($runClock.Elapsed.TotalMinutes)))
    Set-Location -LiteralPath $startDir
    try {
        Save-Text (Join-Path $Res 'system.txt') (($sys -join "`r`n") + "`r`n")
        foreach ($f in @(Get-ChildItem -LiteralPath $Res -Recurse -File -Include '*.txt', '*.json', '*.log', '*.xml')) {
            $t = [IO.File]::ReadAllText($f.FullName)
            $h = Hide-Personal $t
            if ($h -ne $t) { [IO.File]::WriteAllText($f.FullName, $h, (New-Object System.Text.UTF8Encoding($false))) }
        }
        $zipOut = Join-Path $WorkRoot 'x2w-hw4-results.zip'
        if (Test-Path -LiteralPath $zipOut) { Remove-Item -LiteralPath $zipOut -Force }
        Compress-Archive -Path (Join-Path $Res '*') -DestinationPath $zipOut -Force
        $copy = $zipOut
        $desktop = [Environment]::GetFolderPath('Desktop')
        if ($desktop -and (Test-Path -LiteralPath $desktop)) {
            Copy-Item -LiteralPath $zipOut -Destination $desktop -Force
            $copy = Join-Path $desktop 'x2w-hw4-results.zip'
        }
        Write-Host ''
        if ($exitCode -eq 0) { Write-Host ('Готово. Пришли мне архив: ' + $copy) -ForegroundColor Green }
        else { Write-Host ('Пришли мне архив, даже неполный, разберёмся: ' + $copy) -ForegroundColor Yellow }
    } catch {
        Write-Host ('Не получилось собрать архив: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host ('Пришли тогда папку целиком: ' + $Res)
    }
    [void](Read-Host 'Нажми Enter, чтобы закрыть окно')
}
exit $exitCode
