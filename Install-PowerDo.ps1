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
    [string]$InstallDir
)

$ErrorActionPreference = 'Stop'
$script:Auto = [bool]$Auto
$script:Source = Join-Path $PSScriptRoot 'PowerDo_fixed.ps1'

# ----------------------------------------------------------------- output
$e = [char]27
function Banner {
    Write-Host ''
    Write-Host "  ╔═══════════════════════════════════════╗" -ForegroundColor DarkCyan
    Write-Host "  ║   PowerDo Installer  · Glastfin        ║" -ForegroundColor Cyan
    Write-Host "  ╚═══════════════════════════════════════╝" -ForegroundColor DarkCyan
    Write-Host ''
}
function Step([string]$m) { Write-Host ":: $m" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "   [ok] $m" -ForegroundColor Green }
function Note([string]$m) { Write-Host "   $m" -ForegroundColor DarkGray }
function Warn2([string]$m){ Write-Host "   [!!] $m" -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host "   [xx] $m" -ForegroundColor Red }

# ---------------------------------------------------------------- prompts
function Ask([string]$Msg, [bool]$Default = $true) {
    if ($script:Auto) { return $Default }
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $r = Read-Host "$Msg [$hint]"
        if ([string]::IsNullOrWhiteSpace($r)) { return $Default }
        if ($r -match '^(y|yes)$') { return $true }
        if ($r -match '^(n|no)$')  { return $false }
        Note 'please answer y or n'
    }
}
function Ask-Text([string]$Msg, [string]$Default) {
    if ($script:Auto) { return $Default }
    $r = Read-Host "$Msg [$Default]"
    if ([string]::IsNullOrWhiteSpace($r)) { return $Default }
    return $r.Trim().Trim('"')
}

# ------------------------------------------------------------- preflight
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
Banner
if (-not $IsWindows) { Fail 'Windows required.'; exit 1 }
if (-not (Test-Path -LiteralPath $script:Source)) {
    Fail "source missing: $($script:Source)"; exit 1
}
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Fail 'PowerShell 7 (pwsh) is required'
    Note 'install:  winget install Microsoft.PowerShell'
    exit 1
}

# ------------------------------------------------------- 1. permission
Step 'install PowerDo?'
if (-not (Ask 'Install PowerDo on this computer?' $true)) {
    Write-Host ''
    Note 'cancelled - nothing was changed.'
    Write-Host ''
    exit 0
}

# ------------------------------------------------- 1b. existing install?
Step 'check for an existing install'
$oldDir = $null
if ($PROFILE -and (Test-Path -LiteralPath $PROFILE)) {
    $profContent = Get-Content -LiteralPath $PROFILE -Raw -ErrorAction SilentlyContinue
    if ($profContent -and $profContent -match "(?s)# >>> PowerDo >>>.*?function powerdo \{[^']*'([^']+)'") {
        $oldDir = Split-Path -Parent $Matches[1]
    }
}
if (-not $oldDir) {
    $guess = Join-Path $env:LOCALAPPDATA 'Programs\PowerDo'
    if (Test-Path -LiteralPath (Join-Path $guess 'PowerDo.ps1')) { $oldDir = $guess }
}
if ($oldDir -and (Test-Path -LiteralPath (Join-Path $oldDir 'PowerDo.ps1'))) {
    Ok "already installed: $oldDir"
    if (-not (Ask 'reinstall (overwrite and repair)?' $true)) {
        Note 'nothing changed.'
        Note "uninstall instead:  pwsh -File `"$oldDir\Uninstall-PowerDo.ps1`""
        Write-Host ''
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
}
Ok "folder ready: $dir"
if ($oldDir -and ($oldDir.TrimEnd('\') -ine $dir.TrimEnd('\'))) {
    if (Ask "remove previous install at $oldDir?" $true) {
        Get-ChildItem -LiteralPath $oldDir -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $oldDir) { Warn2 "could not fully remove $oldDir" }
        else { Ok "old install removed: $oldDir" }
    }
}

# ------------------------------------------------------- 3. copy app
Step 'copy app'
$dest = Join-Path $dir 'PowerDo.ps1'
Copy-Item -LiteralPath $script:Source -Destination $dest -Force
$kb = [math]::Round((Get-Item -LiteralPath $dest).Length / 1kb, 1)
Ok "PowerDo.ps1  ($kb KB) -> $dir"

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
        } else {
            Warn2 "policy is now '$newPolicy'"
        }
    } catch {
        Warn2 "blocked: $($_.Exception.Message)"
        Note 'group policy may enforce it - using a bypass launcher instead'
    }
} else {
    Warn2 "policy stays '$policy' - using a bypass launcher"
}

# ------------------------------------------------------- 5. alias
Step "register alias 'powerdo'"
if (-not (Ask "add a 'powerdo' command to your PowerShell profile?" $true)) {
    Warn2 "skipped - you would run:  pwsh -File `"$dest`""
} else {
    $profilePath = $PROFILE
    try {
        if (-not (Test-Path -LiteralPath $profilePath)) {
            New-Item -ItemType File -Path $profilePath -Force | Out-Null
        }
        $destEsc = $dest.Replace("'", "''")
        $body = if ($policyOk) {
            "function powerdo { & '$destEsc' @args }"
        } else {
            "function powerdo { pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File '$destEsc' @args }"
        }
        $block = "# >>> PowerDo >>>`n$body`n# <<< PowerDo <<<"
        $content = Get-Content -LiteralPath $profilePath -Raw -ErrorAction SilentlyContinue
        if ($null -eq $content) { $content = '' }
        if ($content -match '# >>> PowerDo >>>') {
            $content = [regex]::Replace($content, '(?s)# >>> PowerDo >>>.*?# <<< PowerDo <<<', $block)
            Set-Content -LiteralPath $profilePath -Value $content -Encoding utf8 -NoNewline
            Ok "profile updated (alias now points to $dest)"
        } else {
            $sep = if ($content -and -not $content.EndsWith("`n")) { "`n`n" } else { "" }
            Add-Content -LiteralPath $profilePath -Value "$sep$block" -Encoding utf8
            Ok "profile updated (alias now points to $dest)"
        }
        Note ($body -replace "^", "   ")
    } catch {
        Warn2 "could not edit profile: $($_.Exception.Message)"
        Note "run manually instead:  pwsh -ExecutionPolicy Bypass -File `"$dest`""
    }
}

# ------------------------------------------------- 5b. PATH shim (any shell)
Step "add 'powerdo' to PATH (cmd / PowerShell 5.1 / 7)"
$shimAdded = $false
if (Ask 'create powerdo.cmd shim and add its folder to your user PATH?' $true) {
    $shimPath = Join-Path $dir 'powerdo.cmd'
    $shim = @'
@echo off
rem PowerDo launcher - created by Install-PowerDo.ps1
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "__APP__" %*
exit /b %ERRORLEVEL%
'@ -replace '__APP__', ($dest -replace '"', '""')
    Set-Content -LiteralPath $shimPath -Value $shim -Encoding Ascii -Force
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
        }
        $env:Path = "$env:Path;$normDir"
        $shimAdded = $true
    } catch {
        Warn2 "PATH update failed: $($_.Exception.Message)"
    }
} else {
    Note 'skipped - profile alias alone still works in PowerShell 7'
}

# ------------------------------------------------- 5c. Defender exclusion
Step 'Microsoft Defender (optional, honest alternative to hacks)'
$defenderExcluded = $false
if (Ask "whitelist the install folder in Defender? (needs the prompt it shows; skip if unsure)" $false) {
    try {
        Add-MpPreference -ExclusionPath $dir -ErrorAction Stop
        $dataDir = Join-Path $env:LOCALAPPDATA 'PowerDo'
        if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
        Add-MpPreference -ExclusionPath $dataDir -ErrorAction Stop
        Ok "Defender exclusion added: $dir"
        $defenderExcluded = $true
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
        $lnk.TargetPath = if ($shimAdded) { Join-Path $dir 'powerdo.cmd' } else { 'pwsh.exe' }
        if (-not $shimAdded) { $lnk.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$dest`"" }
        $lnk.WorkingDirectory = $dir
        $lnk.Description = 'PowerDo - Glastfin Edition'
        $lnk.Save()
        Ok "shortcut -> $shortcutPath"
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
#requires -Version 7.0
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
Write-Host ":: removing PowerDo" -ForegroundColor Cyan
if ($PROFILE -and (Test-Path -LiteralPath $PROFILE)) {
    $c = Get-Content -LiteralPath $PROFILE -Raw
    if ($c -and $c -match '# >>> PowerDo >>>') {
        $c = [regex]::Replace($c, '(?s)\r?\n?# >>> PowerDo >>>.*?# <<< PowerDo <<<', '')
        Set-Content -LiteralPath $PROFILE -Value $c -Encoding utf8 -NoNewline
        Write-Host "   [ok] profile cleaned" -ForegroundColor Green
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
if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'PowerDo')) {
    Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'PowerDo') -Recurse -Force
    Write-Host "   [ok] task data removed" -ForegroundColor Green
}
Write-Host ":: done - close this terminal and open a new one" -ForegroundColor Cyan
try { if ($PSCommandPath) { Start-Sleep -Milliseconds 300; Remove-Item -LiteralPath $PSCommandPath -Force -EA SilentlyContinue } } catch {}
'@
Set-Content -LiteralPath $uninstPath -Value $uninst -Encoding utf8

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
Write-Host "pwsh -File `"$uninstPath`"" -ForegroundColor Yellow
if (-not $defenderExcluded) {
    Write-Host ''
    Write-Host "     if Windows blocks a file later, run:  " -NoNewline -ForegroundColor DarkGray
    Write-Host "Unblock-File `"$dest`"" -ForegroundColor Yellow
}
Write-Host "     optional hardening (if you distribute it): sign it with" -ForegroundColor DarkGray
Write-Host "     Set-AuthenticodeSignature - that beats any flag, no code changes." -ForegroundColor DarkGray
Write-Host ''
exit 0
