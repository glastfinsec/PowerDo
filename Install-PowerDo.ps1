#requires -Version 7.0
<#
.SYNOPSIS
    PowerDo installer - quiet, pretty, single-click friendly.
.DESCRIPTION
    Asks a few questions, copies PowerDo into a folder of your choice,
    unblocks files, sets CurrentUser execution policy, registers a
    'powerdo' alias (profile) plus an optional PATH shim, and offers
    a Defender exclusion / desktop shortcut. Clean code - no tricks.
.PARAMETER Auto
    Answer every question with its default (unattended).
.EXAMPLE
    .\"Install PowerDo.cmd"          <- double-click
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install-PowerDo.ps1 -Auto
#>
[CmdletBinding()]
param(
    [switch]$Auto,
    [string]$InstallDir,
    [switch]$ForceBootstrap
)

$ErrorActionPreference = 'Stop'
$script:Auto = [bool]$Auto
$script:ForceBootstrap = [bool]$ForceBootstrap
$script:Source = Join-Path $PSScriptRoot 'PowerDo_fixed.ps1'
$script:T0 = Get-Date
$script:Changes = New-Object System.Collections.Generic.List[string]
$script:PwshExe = $null

# ----------------------------------------------------------------- output
function Banner {
    Write-Host ''
    Write-Host "  ╔═══════════════════════════════════════╗" -ForegroundColor DarkCyan
    Write-Host "  ║   PowerDo Installer  · Glastfin        ║" -ForegroundColor Cyan
    Write-Host "  ╚═══════════════════════════════════════╝" -ForegroundColor DarkCyan
    Write-Host ''
}
function Elapsed {
    $ts = (Get-Date) - $script:T0
    return ('{0:00}:{1:00}' -f [int]$ts.TotalMinutes, $ts.Seconds)
}
function Step([string]$m)  { Write-Host ":: [$(Elapsed)] $m" -ForegroundColor Cyan }
function Ok([string]$m)    { Write-Host "   [ok] $m" -ForegroundColor Green }
function Note([string]$m)  { Write-Host "   $m" -ForegroundColor DarkGray }
function Detail([string]$m){ Write-Host "     . $m" -ForegroundColor DarkGray }
function Say-Command([string]$m) { Write-Host "     > $m" -ForegroundColor DarkYellow }
function Warn2([string]$m) { Write-Host "   [!!] $m" -ForegroundColor Yellow }
function Fail([string]$m)  { Write-Host "   [xx] $m" -ForegroundColor Red }
function Track([string]$m) { $script:Changes.Add($m) | Out-Null }

# ---------------------------------------------------------------- prompts
function Ask([string]$Msg, [bool]$Default = $true) {
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    if ($script:Auto) {
        $ans = if ($Default) { 'yes' } else { 'no' }
        Write-Host "   ? $Msg [$hint] -> $ans (auto)" -ForegroundColor DarkGray
        return $Default
    }
    while ($true) {
        $r = Read-Host "   ? $Msg [$hint]"
        if ([string]::IsNullOrWhiteSpace($r)) { return $Default }
        if ($r -match '^(y|yes)$') { return $true }
        if ($r -match '^(n|no)$')  { return $false }
        Note 'please answer y or n'
    }
}
function Ask-Text([string]$Msg, [string]$Default) {
    if ($script:Auto) {
        Write-Host "   ? $Msg [$Default] -> '$Default' (auto)" -ForegroundColor DarkGray
        return $Default
    }
    $r = Read-Host "   ? $Msg [$Default]"
    if ([string]::IsNullOrWhiteSpace($r)) { return $Default }
    return $r.Trim().Trim('"')
}

# ------------------------------------------------- PowerShell 7 detection
function Refresh-Path {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$m;$u"
    Detail 'refreshed PATH from registry (Machine+User)'
}
function Find-Pwsh {
    $c = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $candidates = @()
    if ($env:ProgramFiles)  { $candidates += (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7\pwsh.exe') }
    if ($env:LOCALAPPDATA)  { $candidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe') }
    foreach ($p in $candidates) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    Refresh-Path
    $c = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}
function Test-PwshFound { return [bool](Find-Pwsh) }

function Install-PS7 {
    Write-Host ''
    Note 'install chain: winget -> choco -> Microsoft Store'
    Note 'each command is printed before it runs; output streams live.'

    # ---- 1. winget ------------------------------------------------------
    $wg = Get-Command winget -ErrorAction SilentlyContinue
    if ($wg) {
        Step 'trying winget (Microsoft.PowerShell)'
        $wgArgs = @('install', '--id', 'Microsoft.PowerShell', '--exact', '--source', 'winget',
                    '--accept-package-agreements', '--accept-source-agreements',
                    '--disable-interactivity', '--silent')
        Say-Command "winget $($wgArgs -join ' ')"
        Detail 'a User Account Control (UAC) prompt may appear - approve it to continue'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $p = Start-Process -FilePath $wg.Source -ArgumentList $wgArgs -NoNewWindow -Wait -PassThru
            Detail "winget exit code: $($p.ExitCode)  (took $([int]$sw.Elapsed.TotalSeconds)s)"
        } catch {
            Warn2 "winget could not run: $($_.Exception.Message)"
        }
        if (Test-PwshFound) { Ok 'PowerShell 7 is ready (winget)'; return $true }
        Warn2 'winget did not result in a usable pwsh'
    } else {
        Warn2 'winget not found on this system'
    }

    # ---- 2. choco -------------------------------------------------------
    $ch = Get-Command choco -ErrorAction SilentlyContinue
    if ($ch) {
        Step 'trying choco (powershell-core)'
        Say-Command 'choco install powershell-core -y'
        try {
            $p = Start-Process -FilePath $ch.Source -ArgumentList @('install', 'powershell-core', '-y') -NoNewWindow -Wait -PassThru
            Detail "choco exit code: $($p.ExitCode)"
        } catch {
            Warn2 "choco could not run: $($_.Exception.Message)"
        }
        if (Test-PwshFound) { Ok 'PowerShell 7 is ready (choco)'; return $true }
        Warn2 'choco did not result in a usable pwsh'
    } else {
        Warn2 'choco not found on this system'
    }

    # ---- 3. Microsoft Store / manual ------------------------------------
    Step 'Microsoft Store fallback'
    $storeUri = 'ms-windows-store://pdp/?ProductId=9MZ1SNWT0N5D'
    Note 'PowerShell 7 on the Microsoft Store (no admin needed):'
    Detail $storeUri
    Detail 'https://aka.ms/powershell'
    if (-not $script:Auto) {
        if (Ask 'open the Microsoft Store page for PowerShell 7?' $true) {
            try { Start-Process $storeUri | Out-Null; Detail 'Store page opened' }
            catch { Warn2 'could not open the Store - open https://aka.ms/powershell in a browser instead' }
        }
        for ($i = 1; $i -le 2; $i++) {
            Read-Host '  press Enter once PowerShell 7 is installed (Ctrl+C to give up)' | Out-Null
            if (Test-PwshFound) { Ok 'PowerShell 7 detected'; return $true }
            Warn2 'pwsh still not found - is the install finished?'
        }
    } else {
        Note '(auto mode: not waiting for a manual install)'
    }
    return (Test-PwshFound)
}

# ------------------------------------------------------------- preflight
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# transcript: everything below lands in a log file (best effort)
$script:LogPath = Join-Path $env:TEMP ("PowerDo-install-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$transcriptOn = $false
try { Start-Transcript -Path $script:LogPath -Force | Out-Null; $transcriptOn = $true } catch { $script:LogPath = $null }

Banner
if ($env:OS -ne 'Windows_NT') { Fail 'Windows required.'; exit 1 }
Note "installer host: PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
if (-not (Test-Path -LiteralPath $script:Source)) {
    Fail "source missing: $($script:Source)"; exit 1
}

# ------------------------------------------------- 0. runtime (PowerShell 7)
Step 'runtime: PowerShell 7 (pwsh) - required by PowerDo'
if ($script:ForceBootstrap) {
    Note 'ForceBootstrap: pretending pwsh is missing (test mode)'
    $script:PwshExe = $null
} else {
    $script:PwshExe = Find-Pwsh
}
if ($script:PwshExe) {
    Ok "found: $script:PwshExe"
    try {
        $v = (& $script:PwshExe -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null | Select-Object -First 1)
        Detail "version: $v"
    } catch { Detail 'version: (could not query)' }
} else {
    Warn2 'PowerShell 7 (pwsh) not found'
    if (-not (Ask 'install PowerShell 7 now? (winget -> choco -> Microsoft Store)' $true)) {
        Fail 'PowerShell 7 is required - aborted, nothing was changed.'
        Note 'manual install:  winget install Microsoft.PowerShell'
        Note '              or  https://aka.ms/powershell   then run this installer again.'
        if ($transcriptOn) { try { Stop-Transcript | Out-Null } catch {} }
        exit 1
    }
    if (-not (Install-PS7)) {
        Fail 'could not install PowerShell 7 automatically - aborted, nothing was changed.'
        Note 'install manually from the Microsoft Store or https://aka.ms/powershell'
        Note 'then run this installer again.'
        if ($transcriptOn) { try { Stop-Transcript | Out-Null } catch {} }
        exit 1
    }
    $script:PwshExe = Find-Pwsh
    if (-not $script:PwshExe) {
        Fail 'pwsh still not visible after install - aborted.'
        Note 'open a NEW terminal and run this installer again.'
        if ($transcriptOn) { try { Stop-Transcript | Out-Null } catch {} }
        exit 1
    }
    Ok "ready: $script:PwshExe"
}
Track "runtime: PowerShell 7 at $script:PwshExe"

# ------------------------------------------------------- 1. permission
Write-Host ''
Step 'install PowerDo?'
if (-not (Ask 'Install PowerDo on this computer?' $true)) {
    Write-Host ''
    Note 'cancelled - nothing was changed.'
    Write-Host ''
    if ($transcriptOn) { try { Stop-Transcript | Out-Null } catch {} }
    exit 0
}

# ------------------------------------------------- 1b. existing install?
Step 'check for an existing install'
$oldDir = $null
foreach ($pp in @($PROFILE, (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Microsoft.PowerShell_profile.ps1'))) {
    if (-not $pp) { continue }
    if (-not (Test-Path -LiteralPath $pp)) { continue }
    $profContent = Get-Content -LiteralPath $pp -Raw -ErrorAction SilentlyContinue
    if (-not $profContent) { continue }
    if ($profContent -match "(?s)# >>> PowerDo >>>.*?-File '([^']+)'") { $oldDir = Split-Path -Parent $Matches[1]; break }
    if ($profContent -match "(?s)# >>> PowerDo >>>.*?function powerdo \{[^']*'([^']+)'") { $oldDir = Split-Path -Parent $Matches[1]; break }
}
if (-not $oldDir) {
    $guess = Join-Path $env:LOCALAPPDATA 'Programs\PowerDo'
    if (Test-Path -LiteralPath (Join-Path $guess 'PowerDo.ps1')) { $oldDir = $guess }
}
$dataDir = Join-Path $env:LOCALAPPDATA 'PowerDo'
$openN = 0; $doneN = 0
if (Test-Path -LiteralPath (Join-Path $dataDir 'todo.txt')) { $openN = @(Get-Content -LiteralPath (Join-Path $dataDir 'todo.txt') -ErrorAction SilentlyContinue).Count }
if (Test-Path -LiteralPath (Join-Path $dataDir 'done.txt')) { $doneN = @(Get-Content -LiteralPath (Join-Path $dataDir 'done.txt') -ErrorAction SilentlyContinue).Count }
$hasData = (Test-Path -LiteralPath $dataDir)
if ($hasData) {
    Note "task data: $dataDir  ($openN open, $doneN done)"
    Note 'reinstalling REPLACES the app files only - your tasks stay intact'
}
if ($oldDir -and (Test-Path -LiteralPath (Join-Path $oldDir 'PowerDo.ps1'))) {
    Ok "already installed: $oldDir"
    if (-not (Ask 'reinstall (overwrite and repair, keep tasks)?' $true)) {
        Note 'nothing changed.'
        Note "uninstall instead:  & `"$($script:PwshExe)`" -NoProfile -File `"$oldDir\Uninstall-PowerDo.ps1`""
        Write-Host ''
        if ($transcriptOn) { try { Stop-Transcript | Out-Null } catch {} }
        exit 0
    }
} else {
    Note 'no previous install found'
    $oldDir = $null
}

# ------------------------------------------------------- 2. folder
Step 'choose install folder'
$defaultDir = if ($InstallDir) { $InstallDir }
              elseif ($oldDir) { $oldDir }
              else { Join-Path $env:LOCALAPPDATA 'Programs\PowerDo' }
$dir = Ask-Text 'install folder' $defaultDir
$dir = [Environment]::ExpandEnvironmentVariables($dir.Trim().Trim('"'))
if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Detail "created: $dir"
}
Ok "folder ready: $dir"
if ($oldDir -and ($oldDir.TrimEnd('\') -ine $dir.TrimEnd('\'))) {
    if (Ask "remove previous install at $oldDir?" (-not $script:Auto)) {
        Get-ChildItem -LiteralPath $oldDir -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $oldDir) { Warn2 "could not fully remove $oldDir" }
        else { Ok "old install removed: $oldDir"; Track "removed old install folder $oldDir" }
    }
}

# ------------------------------------------------------- 3. copy app
Step 'copy app (replace files, keep tasks)'
$dest = Join-Path $dir 'PowerDo.ps1'
Copy-Item -LiteralPath $script:Source -Destination $dest -Force
$kb = [math]::Round((Get-Item -LiteralPath $dest).Length / 1kb, 1)
$shaS = [System.Security.Cryptography.SHA256]::Create()
$shaF = [IO.File]::OpenRead($dest)
try { $sha = ([BitConverter]::ToString($shaS.ComputeHash($shaF)).Replace('-', '')).Substring(0, 16).ToLower() }
finally { $shaF.Close(); $shaS.Dispose() }
Ok "PowerDo.ps1  ($kb KB, sha256:$sha) -> $dir"
Detail "source: $($script:Source)"
if ($hasData) { Ok "task data preserved: $dataDir  ($openN open, $doneN done)" }
Track "app files in $dir"

# ------------------------------------------------- 3b. unblock (MotW)
Step 'unblock downloaded files'
$toUnblock = @($script:Source, $dest,
    (Join-Path $PSScriptRoot 'Install-PowerDo.ps1'),
    (Join-Path $PSScriptRoot 'Install PowerDo.cmd')) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
$unblocked = 0
foreach ($f in $toUnblock) {
    if (Get-Item -LiteralPath $f -Stream * -ErrorAction SilentlyContinue |
            Where-Object Stream -eq 'Zone.Identifier') {
        Unblock-File -LiteralPath $f -ErrorAction SilentlyContinue
        $unblocked++
        Detail "unblocked: $f"
    }
}
if ($unblocked) { Ok "removed download mark from $unblocked file(s)" }
else { Ok 'no download marks found - nothing to unblock' }

# ------------------------------------------------------- 4. policy
Step 'execution policy (so .ps1 files may run)'
$policy = try { (Get-ExecutionPolicy).ToString() } catch { 'Unknown' }
Note "current: $policy"
$policyOk = $false
if ($policy -in @('RemoteSigned', 'Unrestricted', 'Bypass')) {
    $policyOk = $true
    Ok 'already permissive - no change needed'
} elseif (Ask 'set CurrentUser policy to RemoteSigned? (recommended)' $true) {
    try {
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
        $newPolicy = try { (Get-ExecutionPolicy).ToString() } catch { '?' }
        if ($newPolicy -in @('RemoteSigned', 'Unrestricted', 'Bypass')) {
            $policyOk = $true
            Ok "CurrentUser policy -> $newPolicy"
            Track "execution policy: CurrentUser=$newPolicy"
        } else {
            Warn2 "policy is now '$newPolicy'"
        }
    } catch {
        Warn2 "blocked: $($_.Exception.Message)"
        Note 'group policy may enforce it - the powerdo launchers use -ExecutionPolicy Bypass anyway'
    }
} else {
    Warn2 "policy stays '$policy' - the powerdo launchers use -ExecutionPolicy Bypass anyway"
}

# ------------------------------------------------------- 5. alias (both profiles)
Step "register alias 'powerdo' (PowerShell 7 + Windows PowerShell profiles)"
$docs = [Environment]::GetFolderPath('MyDocuments')
$profileTargets = @($PROFILE,
    (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1')) |
    Where-Object { $_ } | Select-Object -Unique
if (-not (Ask "add a 'powerdo' command to your PowerShell profile(s)?" $true)) {
    Warn2 "skipped - you would run:  & `"$($script:PwshExe)`" -NoProfile -File `"$dest`""
} else {
    $destEsc = $dest.Replace("'", "''")
    $exeEsc = $script:PwshExe.Replace("'", "''")
    $body = "function powerdo { & '$exeEsc' -NoLogo -NoProfile -ExecutionPolicy Bypass -File '$destEsc' @args }"
    $block = "# >>> PowerDo >>>`n$body`n# <<< PowerDo <<<"
    foreach ($profilePath in $profileTargets) {
        try {
            if (-not (Test-Path -LiteralPath $profilePath)) {
                New-Item -ItemType File -Path $profilePath -Force | Out-Null
            }
            $content = Get-Content -LiteralPath $profilePath -Raw -ErrorAction SilentlyContinue
            if ($null -eq $content) { $content = '' }
            if ($content -match '# >>> PowerDo >>>') {
                $content = [regex]::Replace($content, '(?s)# >>> PowerDo >>>.*?# <<< PowerDo <<<', $block)
                Set-Content -LiteralPath $profilePath -Value $content -Encoding utf8 -NoNewline
                Ok "profile updated: $profilePath"
            } else {
                $sep = if ($content -and -not $content.EndsWith("`n")) { "`n`n" } else { "" }
                Add-Content -LiteralPath $profilePath -Value "$sep$block" -Encoding utf8
                Ok "profile added: $profilePath"
            }
            Track "profile block in $profilePath"
        } catch {
            Warn2 "could not edit profile ${profilePath}: $($_.Exception.Message)"
        }
    }
    Detail $body
}

# ------------------------------------------------- 5b. PATH shim (any shell)
Step "add 'powerdo' to PATH (cmd / Windows PowerShell / PowerShell 7)"
$shimAdded = $false
if (Ask 'create powerdo.cmd shim and add its folder to your user PATH?' $true) {
    $shimPath = Join-Path $dir 'powerdo.cmd'
    $shim = @'
@echo off
rem PowerDo launcher - created by Install-PowerDo.ps1
"__PWSH__" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "__APP__" %*
exit /b %ERRORLEVEL%
'@ -replace '__PWSH__', ($script:PwshExe -replace '"', '""') -replace '__APP__', ($dest -replace '"', '""')
    Set-Content -LiteralPath $shimPath -Value $shim -Encoding Ascii -Force
    Say-Command "`"$($script:PwshExe)`" -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$dest`""
    try {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($null -eq $userPath) { $userPath = '' }
        $entries = @($userPath -split ';' | Where-Object { $_ })
        $normDir = $dir.TrimEnd('\')
        if ($entries | Where-Object { $_.TrimEnd('\') -ieq $normDir }) {
            Ok 'folder already in user PATH'
        } else {
            [Environment]::SetEnvironmentVariable('Path', (($entries + $normDir) -join ';'), 'User')
            Ok "PATH += $normDir"
            Track "user PATH += $normDir"
        }
        $env:Path = "$env:Path;$normDir"
        $shimAdded = $true
        Track "launcher shim $shimPath"
    } catch {
        Warn2 "PATH update failed: $($_.Exception.Message)"
    }
} else {
    Note 'skipped - the profile alias still works'
}

# ------------------------------------------------- 5c. Defender exclusion
Step 'Microsoft Defender (optional, honest alternative to hacks)'
$defenderExcluded = $false
if (Ask "whitelist the install folder in Defender? (the prompt it shows is normal; skip if unsure)" $false) {
    try {
        Add-MpPreference -ExclusionPath $dir -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
        Add-MpPreference -ExclusionPath $dataDir -ErrorAction Stop
        Ok "Defender exclusion added: $dir"
        $defenderExcluded = $true
        Track "Defender exclusion: $dir"
    } catch {
        Warn2 "could not add exclusion: $($_.Exception.Message)"
        Note 'running installer as admin usually fixes this - or ignore, app runs fine without it'
    }
} else {
    Note 'skipped - default Defender left untouched'
}

# ------------------------------------------------- 5d. desktop shortcut
$shortcutPath = $null
Step 'desktop shortcut (optional)'
if (Ask 'create a desktop shortcut to start PowerDo?' $false) {
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $shortcutPath = Join-Path $desktop 'PowerDo.lnk'
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($shortcutPath)
        $lnk.TargetPath = if ($shimAdded) { Join-Path $dir 'powerdo.cmd' } else { $script:PwshExe }
        if (-not $shimAdded) { $lnk.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$dest`"" }
        $lnk.WorkingDirectory = $dir
        $lnk.Description = 'PowerDo - Glastfin Edition'
        $lnk.Save()
        Ok "shortcut -> $shortcutPath"
        Track "desktop shortcut $shortcutPath"
    } catch {
        Warn2 "shortcut failed: $($_.Exception.Message)"
        $shortcutPath = $null
    }
} else {
    Note 'skipped'
}

# ------------------------------------------------------- 6. uninstaller
$uninstPath = Join-Path $dir 'Uninstall-PowerDo.ps1'
$uninst = @'
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
Write-Host ":: removing PowerDo" -ForegroundColor Cyan
$docs = [Environment]::GetFolderPath('MyDocuments')
$profiles = @($PROFILE,
    (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1')) |
    Where-Object { $_ } | Select-Object -Unique
foreach ($p in $profiles) {
    if ($p -and (Test-Path -LiteralPath $p)) {
        $c = Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
        if ($c -and $c -match '# >>> PowerDo >>>') {
            $c = [regex]::Replace($c, '(?s)\r?\n?# >>> PowerDo >>>.*?# <<< PowerDo <<<', '')
            Set-Content -LiteralPath $p -Value $c -Encoding utf8 -NoNewline
            Write-Host "   [ok] profile cleaned: $p" -ForegroundColor Green
        }
    }
}
Get-ChildItem -LiteralPath $here -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -ne $PSCommandPath } |
    Remove-Item -Force -ErrorAction SilentlyContinue
Write-Host "   [ok] files removed from $here" -ForegroundColor Green
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -and (($userPath -split ';') | Where-Object { $_.TrimEnd('\') -ieq $here.TrimEnd('\') })) {
    $newPath = (@($userPath -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ine $here.TrimEnd('\') }) -join ';')
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host "   [ok] user PATH cleaned" -ForegroundColor Green
}
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'PowerDo.lnk'
if (Test-Path -LiteralPath $lnk) {
    Remove-Item -LiteralPath $lnk -Force
    Write-Host "   [ok] desktop shortcut removed" -ForegroundColor Green
}
try {
    $excl = (Get-MpPreference -ErrorAction Stop).ExclusionPath
    foreach ($p in @($here, (Join-Path $env:LOCALAPPDATA 'PowerDo'))) {
        if ($excl -contains $p) {
            Remove-MpPreference -ExclusionPath $p -ErrorAction Stop
            Write-Host "   [ok] Defender exclusion removed: $p" -ForegroundColor Green
        }
    }
} catch { }
$data = Join-Path $env:LOCALAPPDATA 'PowerDo'
if (Test-Path -LiteralPath $data) {
    $keep = $true
    try {
        $r = Read-Host '   keep task data? (Y/n)'
        if (-not [string]::IsNullOrWhiteSpace($r) -and $r -match '^(n|no)$') { $keep = $false }
    } catch { $keep = $true }
    if ($keep) {
        Write-Host "   [ok] task data kept: $data" -ForegroundColor Green
    } else {
        Remove-Item -LiteralPath $data -Recurse -Force
        Write-Host "   [ok] task data removed" -ForegroundColor Green
    }
}
Write-Host ":: done - close this terminal and open a new one" -ForegroundColor Cyan
try { if ($PSCommandPath) { Start-Sleep -Milliseconds 300; Remove-Item -LiteralPath $PSCommandPath -Force -EA SilentlyContinue } } catch {}
'@
Set-Content -LiteralPath $uninstPath -Value $uninst -Encoding utf8
Ok "uninstaller -> $uninstPath (asks before touching task data)"
Track "uninstaller $uninstPath"

# ------------------------------------------------------- done
Write-Host ''
Write-Host "  ✅  installed - nothing else to do" -ForegroundColor Green
Write-Host ''
Write-Host "     open a NEW terminal, then type:   " -NoNewline -ForegroundColor Gray
Write-Host "powerdo" -ForegroundColor Yellow
if ($shimAdded) {
    Write-Host "     (works in PowerShell 7, Windows PowerShell and cmd)" -ForegroundColor Gray
}
Write-Host "     help inside the app:  ?          quit:  q" -ForegroundColor Gray
Write-Host "     uninstall:  " -NoNewline -ForegroundColor Gray
Write-Host "& `"$($script:PwshExe)`" -NoProfile -File `"$uninstPath`"" -ForegroundColor Yellow
if ($hasData) {
    Write-Host "     task data kept: $dataDir  ($openN open, $doneN done)" -ForegroundColor Gray
}
Write-Host ''
Write-Host "  system changes made:" -ForegroundColor Cyan
foreach ($c in $script:Changes) { Write-Host "     - $c" -ForegroundColor Gray }
if ($script:LogPath) {
    Write-Host ''
    Write-Host "  install transcript: $($script:LogPath)" -ForegroundColor DarkGray
}
if (-not $defenderExcluded) {
    Write-Host ''
    Write-Host "     if Windows blocks a file later, run:  " -NoNewline -ForegroundColor DarkGray
    Write-Host "Unblock-File `"$dest`"" -ForegroundColor Yellow
}
Write-Host "     optional hardening (if you distribute it): sign it with" -ForegroundColor DarkGray
Write-Host "     Set-AuthenticodeSignature - that beats any flag, no code changes." -ForegroundColor DarkGray
Write-Host ''
if ($transcriptOn) { try { Stop-Transcript | Out-Null } catch {} }
exit 0

Write-Host "     optional hardening (if you distribute it): sign it with" -ForegroundColor DarkGray
Write-Host "     Set-AuthenticodeSignature - that beats any flag, no code changes." -ForegroundColor DarkGray
Write-Host ''
exit 0
