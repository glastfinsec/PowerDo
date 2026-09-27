#requires -Version 7.0
<#
    PowerDo :: Glastfin Edition
    ---------------------------
    A keyboard-driven, panes-and-sidebars terminal task manager.
    Built by GlaStFiN. Look & feel modeled after webstonehq/tuxedo
    (a Rust/ratatui todo.txt TUI) -- vim-style chords, four themes,
    three densities, filter/detail sidebars, an archive view, undo.

    Run: pwsh -NoProfile -ExecutionPolicy Bypass -File .\PowerDo.ps1

    Glory to Mankind, GlaStFiN~
#>

$ErrorActionPreference = 'Stop'

# ============================================================================
#  PATHS & GLOBAL STATE                                              GlaStFiN
# ============================================================================
$script:OriginalTitle = $null
try { $script:OriginalTitle = $Host.UI.RawUI.WindowTitle } catch {}

$script:DataDir    = Join-Path $env:LOCALAPPDATA 'PowerDo'
$script:TodoFile   = Join-Path $script:DataDir 'todo.txt'
$script:DoneFile   = Join-Path $script:DataDir 'done.txt'
$script:ConfigFile = Join-Path $script:DataDir 'config.json'
$script:LegacyFile = Join-Path $script:DataDir 'tasks.json'

New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null

$script:Tasks          = [System.Collections.Generic.List[object]]::new()
$script:DoneTasks      = [System.Collections.Generic.List[object]]::new()
$script:UndoStack      = [System.Collections.Generic.List[object]]::new()
$script:MultiSelected  = [System.Collections.Generic.List[object]]::new()

$script:SelectedTask = $null
$script:SelectedDone = $null
$script:Mode         = 'normal'   # normal|visual|archive|add|edit|search|addproject|addcontext|setdue|filterpick|help|settings|confirmuninstall
$script:PreviousMode = 'normal'
$script:Running      = $true
$script:PendingChord = $null

$script:ScrollOffset        = 0
$script:ArchiveScrollOffset = 0
$script:LastVisibleCount    = 5

$script:FilterProject    = $null
$script:FilterContext    = $null
$script:SearchQuery      = ''
$script:InputBuffer      = ''
$script:FilterPickerBy    = $null
$script:FilterPickerItems = @()
$script:FilterPickerIndex = 0

$script:StatusMessage = $null
$script:StatusExpire  = Get-Date
$script:ActiveBg      = $null

# ============================================================================
#  ANSI / THEME ENGINE                                                GlaStFiN
# ============================================================================
$Esc            = [char]27
$AnsiReset      = "$Esc[0m"
$AnsiFgReset    = "$Esc[39m"
$AnsiBgReset    = "$Esc[49m"
$AnsiBold       = "$Esc[1m"
$AnsiBoldReset  = "$Esc[22m"
$AnsiStrike     = "$Esc[9m"
$AnsiStrikeReset= "$Esc[29m"

function Ansi-Fg { param($T) "$Esc[38;2;$($T[0]);$($T[1]);$($T[2])m" }
function Ansi-Bg { param($T) "$Esc[48;2;$($T[0]);$($T[1]);$($T[2])m" }

# Four themes, tuxedo-style: Muted Slate (default), Dawn, Nord, Matrix
$script:Themes = @{
    'MutedSlate' = @{
        Accent=@(120,150,180); Text=@(214,218,224); Muted=@(128,134,144)
        Success=@(120,180,130); Warning=@(224,184,96); Danger=@(224,114,114)
        Border=@(76,84,96); Selection=@(64,78,96); Background=@(42,42,58)
    }
    'Dawn' = @{
        Accent=@(232,158,100); Text=@(238,224,210); Muted=@(176,146,126)
        Success=@(156,184,116); Warning=@(232,194,98); Danger=@(224,106,96)
        Border=@(122,92,72); Selection=@(94,64,48); Background=@(34,26,22)
    }
    'Nord' = @{
        Accent=@(136,192,208); Text=@(216,222,233); Muted=@(120,130,150)
        Success=@(163,190,140); Warning=@(235,203,139); Danger=@(191,97,106)
        Border=@(72,80,98); Selection=@(67,76,94); Background=@(46,52,70)
    }
    'Matrix' = @{
        Accent=@(40,255,90); Text=@(30,210,70); Muted=@(20,120,45)
        Success=@(110,255,140); Warning=@(190,255,80); Danger=@(255,90,90)
        Border=@(20,140,55); Selection=@(10,60,25); Background=@(4,14,8)
    }
}
$script:ThemeOrder = @('MutedSlate','Dawn','Nord','Matrix')

# Renders one styled segment: @{ Text; Fg; Bold; Strike }
function Render-Segment {
    param($Seg)
    $out = ''
    if ($Seg.Bold)   { $out += $AnsiBold }
    if ($Seg.Strike) { $out += $AnsiStrike }
    if ($Seg.Fg)     { $out += (Ansi-Fg $Seg.Fg) }
    $out += $Seg.Text
    if ($Seg.Fg)     { $out += $AnsiFgReset }
    if ($Seg.Strike) { $out += $AnsiStrikeReset }
    if ($Seg.Bold)   { $out += $AnsiBoldReset }
    return $out
}

# Builds one fixed-*visible*-width colored cell from a list of segments.
function Complete-Row {
    param([array]$Segments, [int]$Width, $BgTuple = $null)
    if (-not $Segments) { $Segments = @() }
    if (-not $BgTuple -and $script:ActiveBg) { $BgTuple = $script:ActiveBg }
    $plainLen = 0
    foreach ($s in $Segments) { $plainLen += [string]$s.Text | ForEach-Object { $_.Length } }
    if ($plainLen -gt $Width) {
        $over = $plainLen - $Width
        for ($i = $Segments.Count - 1; $i -ge 0 -and $over -gt 0; $i--) {
            $len = ([string]$Segments[$i].Text).Length
            if ($len -le $over) { $Segments[$i].Text = ''; $over -= $len }
            else { $Segments[$i].Text = ([string]$Segments[$i].Text).Substring(0, $len - $over); $over = 0 }
        }
        $plainLen = $Width
    }
    $pad = $Width - $plainLen
    if ($pad -lt 0) { $pad = 0 }
    $out = ''
    if ($BgTuple) { $out += (Ansi-Bg $BgTuple) }
    foreach ($s in $Segments) { $out += (Render-Segment $s) }
    if ($pad -gt 0) { $out += (' ' * $pad) }
    if ($BgTuple) { $out += $AnsiBgReset }
    $out += $AnsiReset
    return $out
}

function Center-Text {
    param([string]$Text, [int]$Width)
    if ($Text.Length -ge $Width) { return $Text.Substring(0, [Math]::Max(0,$Width)) }
    $left = [int](($Width - $Text.Length) / 2)
    $right = $Width - $Text.Length - $left
    return ((' ' * $left) + $Text + (' ' * $right))
}

# ============================================================================
#  TODO.TXT PARSING                                                   GlaStFiN
# ============================================================================
function ConvertFrom-TodoLine {
    param([string]$Line)
    $t = [pscustomobject]@{
        Completed = $false; CompletionDate = $null; Priority = $null
        CreationDate = $null; Description = ''
    }
    $s = $Line
    if ($s -match '^x\s+(.*)$') {
        $t.Completed = $true
        $s = $Matches[1]
        if ($s -match '^(\d{4}-\d{2}-\d{2})\s+(\d{4}-\d{2}-\d{2})\s+(.*)$') {
            $t.CompletionDate = $Matches[1]; $t.CreationDate = $Matches[2]; $s = $Matches[3]
        } elseif ($s -match '^(\d{4}-\d{2}-\d{2})\s+(.*)$') {
            $t.CompletionDate = $Matches[1]; $s = $Matches[2]
        }
    } else {
        if ($s -match '^\(([A-Za-z])\)\s+(.*)$') {
            $t.Priority = $Matches[1].ToUpperInvariant(); $s = $Matches[2]
        }
        if ($s -match '^(\d{4}-\d{2}-\d{2})\s+(.*)$') {
            $t.CreationDate = $Matches[1]; $s = $Matches[2]
        }
    }
    $t.Description = $s
    return $t
}

function ConvertTo-TodoLine {
    param($Task)
    if ($Task.Completed) {
        $parts = @('x')
        if ($Task.CompletionDate) { $parts += $Task.CompletionDate }
        if ($Task.CreationDate)   { $parts += $Task.CreationDate }
        $parts += $Task.Description
    } else {
        $parts = @()
        if ($Task.Priority)     { $parts += "($($Task.Priority))" }
        if ($Task.CreationDate) { $parts += $Task.CreationDate }
        $parts += $Task.Description
    }
    return ($parts -join ' ')
}

function Get-TaskProjects { param($Task) @([regex]::Matches($Task.Description, '(?<=^|\s)\+(\S+)') | ForEach-Object { $_.Groups[1].Value }) }
function Get-TaskContexts { param($Task) @([regex]::Matches($Task.Description, '(?<=^|\s)@(\S+)') | ForEach-Object { $_.Groups[1].Value }) }
function Get-TaskDue      { param($Task) if ($Task.Description -match '(?<=^|\s)due:(\S+)') { $Matches[1] } else { $null } }

# --------------------------------------------------------------------------
#  FUZZY DATES - natural phrases -> DateTime                       GlaStFiN
# --------------------------------------------------------------------------
function ConvertTo-TimeOfDay {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim().ToLowerInvariant()
    if ($t -eq 'noon')     { return [timespan]::FromHours(12) }
    if ($t -eq 'midnight') { return [timespan]::Zero }
    $ampm = $null
    if ($t -match '^(.+?)\s*(a\.?m\.?|p\.?m\.?)$') { $t = $Matches[1].Trim(); $ampm = $Matches[2][0] }
    $h = 0; $min = 0
    if     ($t -match '^(\d{1,2}):(\d{2})$') { $h = [int]$Matches[1]; $min = [int]$Matches[2] }
    elseif ($t -match '^(\d{1,2})$')         { $h = [int]$Matches[1] }
    else { return $null }
    if ($min -gt 59) { return $null }
    if ($ampm) {
        if ($h -lt 1 -or $h -gt 12) { return $null }
        if ($ampm -eq 'p' -and $h -ne 12) { $h += 12 }
        if ($ampm -eq 'a' -and $h -eq 12) { $h = 0 }
    } elseif ($h -gt 23) { return $null }
    return [timespan]::FromHours($h).Add([timespan]::FromMinutes($min))
}

function Format-DueDisplay { param([string]$Due) if (-not $Due) { return $Due }; return $Due.Replace('T', ' ') }

function ConvertFrom-FuzzyDate {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $s = $Text.Trim().ToLowerInvariant().Replace('_', ' ')
    $s = $s -replace '^(?:by|before|due|till|until|on)\s+', ''
    $s = ($s -replace '\s+', ' ').Trim()
    $today = (Get-Date).Date
    $wd = @{ sun=0;sunday=0;mon=1;monday=1;tue=2;tues=2;tuesday=2;wed=3;weds=3;wednesday=3;thu=4;thur=4;thurs=4;thursday=4;fri=5;friday=5;sat=6;saturday=6 }
    $mo = @{ jan=1;january=1;feb=2;february=2;mar=3;march=3;apr=4;april=4;may=5;jun=6;june=6;jul=7;july=7;aug=8;august=8;sep=9;sept=9;september=9;oct=10;october=10;nov=11;november=11;dec=12;december=12 }
    $wdPat = '(?:sun(?:day)?|mon(?:day)?|tue(?:s(?:day)?)?|wed(?:s(?:nesday)?)?|thu(?:rs?(?:day)?)?|fri(?:day)?|sat(?:urday)?)'

    # -- extract a time-of-day spec, resolve the date, re-apply the time -----
    $tod = $null
    if     ($s -match '^(?:at\s+)?(\d{1,2}:\d{2}\s*(?:am|pm)?|\d{1,2}\s*(?:am|pm)|noon|midnight)$') { $tod = $Matches[1]; $s = 'today' }
    elseif ($s -match '^at\s+(\d{1,2})$') {
        $n = [int]$Matches[1]
        if ($n -ge 1 -and $n -le 11) { $n += 12 }   # bare hour via 'at' => pm
        $tod = "${n}:00"; $s = 'today'
    }
    elseif ($s -match '^(.*\S)\s+(?:at\s+)?(\d{1,2}:\d{2}\s*(?:am|pm)?)$')  { $tod = $Matches[2]; $s = $Matches[1] }
    elseif ($s -match '^(.*\S)\s+(?:at\s+)?(\d{1,2}\s*(?:am|pm))$')         { $tod = $Matches[2]; $s = $Matches[1] }
    elseif ($s -match '^(.*\S)\s+(?:at\s+)?(noon|midnight)$')               { $tod = $Matches[2]; $s = $Matches[1] }
    elseif ($s -match '^(.*\S)\s+at\s+(\d{1,2})$') {
        $n = [int]$Matches[2]
        if ($n -ge 1 -and $n -le 11) { $n += 12 }   # bare hour via 'at' => pm
        $tod = "${n}:00"; $s = $Matches[1]
    }

    $r = $null
    switch -Regex ($s) {
        '^(?:today|tod|tonight|eod)$'              { $r = $today; break }
        '^(?:tomorrow|tom|tmr|tmw)$'               { $r = $today.AddDays(1); break }
        '^yesterday$'                              { $r = $today.AddDays(-1); break }
        '^weekend$'                                { $r = $today.AddDays((6 - [int]$today.DayOfWeek + 7) % 7); break }
        '^(?:eow|end of (?:the )?week|this week)$' { $r = $today.AddDays((0 - [int]$today.DayOfWeek + 7) % 7); break }
        '^next week$'                              { $r = $today.AddDays(7); break }
        '^(?:eom|end of (?:the )?month)$'          { $r = [datetime]::new($today.Year, $today.Month, [datetime]::DaysInMonth($today.Year, $today.Month)); break }
        '^next month$' {
            $y = $today.Year; $m = $today.Month + 1
            if ($m -gt 12) { $m = 1; $y++ }
            $r = [datetime]::new($y, $m, [Math]::Min($today.Day, [datetime]::DaysInMonth($y, $m))); break
        }
        '^(?:eoy|end of (?:the )?year)$'           { $r = [datetime]::new($today.Year, 12, 31); break }
        '^next year$' {
            $y = $today.Year + 1
            $r = [datetime]::new($y, $today.Month, [Math]::Min($today.Day, [datetime]::DaysInMonth($y, $today.Month))); break
        }
        '^(?:(?:in|next)\s+)?(\d+)\s*(h|hr|hrs|hour|hours|min|mins|minute|minutes)$' {
            $n = [int]$Matches[1]; $u = $Matches[2]; $now = Get-Date
            if ($u -match '^(?:h|hr|hrs|hour|hours)$') { $r = $now.AddHours($n) } else { $r = $now.AddMinutes($n) }
            break
        }
        '^(?:(?:in|next)\s+)?(\d+)\s*(day|days|d|week|weeks|w|month|months|mo|year|years|y)$' {
            $n = [int]$Matches[1]; $u = $Matches[2]
            if ($u -match '^(?:d|day|days)$') { $r = $today.AddDays($n); break }
            if ($u -match '^(?:w|week|weeks)$') { $r = $today.AddDays($n * 7); break }
            if ($u -match '^(?:mo|month|months)$') {
                $m = $today.Month + $n
                $y = $today.Year + [int][Math]::Floor(($m - 1) / 12)
                $m = (($m - 1) % 12) + 1
                $r = [datetime]::new($y, $m, [Math]::Min($today.Day, [datetime]::DaysInMonth($y, $m))); break
            }
            $y = $today.Year + $n
            $r = [datetime]::new($y, $today.Month, [Math]::Min($today.Day, [datetime]::DaysInMonth($y, $today.Month))); break
        }
        "^(next|this)\s+($wdPat)$" {
            $target = [int]$wd[$Matches[2]]
            $next = $today.AddDays(($target - [int]$today.DayOfWeek + 7) % 7)
            if ($Matches[1] -eq 'next' -and $next -eq $today) { $next = $next.AddDays(7) }
            $r = $next; break
        }
        "^($wdPat)$" { $r = $today.AddDays(([int]$wd[$Matches[1]] - [int]$today.DayOfWeek + 7) % 7); break }
        '^(\d{4})-(\d{1,2})-(\d{1,2})$' {
            $y = [int]$Matches[1]; $m = [int]$Matches[2]; $d = [int]$Matches[3]
            if ($m -ge 1 -and $m -le 12 -and $d -ge 1 -and $d -le [datetime]::DaysInMonth($y, $m)) { $r = [datetime]::new($y, $m, $d) }
            break
        }
        '^(\d{1,2})[\/\.](\d{1,2})(?:[\/\.](\d{2,4}))?$' {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            $m = 0; $d = 0
            if     ($a -gt 12 -and $b -le 12) { $d = $a; $m = $b }
            elseif ($b -gt 12 -and $a -le 12) { $m = $a; $d = $b }
            elseif ($a -le 12 -and $b -le 12) { $m = $a; $d = $b }
            else { break }
            $y = $today.Year; $hasYear = [bool]$Matches[3]
            if ($hasYear) { $y = [int]$Matches[3]; if ($y -lt 100) { $y += 2000 } }
            if ($m -lt 1 -or $m -gt 12 -or $d -lt 1 -or $d -gt [datetime]::DaysInMonth($y, $m)) { break }
            $rr = [datetime]::new($y, $m, $d)
            if (-not $hasYear -and $rr -lt $today) { $rr = $rr.AddYears(1) }
            $r = $rr; break
        }
        '^(\d{1,2})\s+([a-z]+)(?:\s+(\d{4}))?$' {
            if (-not $mo.ContainsKey($Matches[2])) { break }
            $m = [int]$mo[$Matches[2]]; $d = [int]$Matches[1]
            $y = $today.Year; $hasYear = [bool]$Matches[3]
            if ($hasYear) { $y = [int]$Matches[3] }
            if ($d -lt 1 -or $d -gt [datetime]::DaysInMonth($y, $m)) { break }
            $rr = [datetime]::new($y, $m, $d)
            if (-not $hasYear -and $rr -lt $today) { $rr = $rr.AddYears(1) }
            $r = $rr; break
        }
        '^([a-z]+)\s+(\d{1,2})(?:\s+(\d{4}))?$' {
            if (-not $mo.ContainsKey($Matches[1])) { break }
            $m = [int]$mo[$Matches[1]]; $d = [int]$Matches[2]
            $y = $today.Year; $hasYear = [bool]$Matches[3]
            if ($hasYear) { $y = [int]$Matches[3] }
            if ($d -lt 1 -or $d -gt [datetime]::DaysInMonth($y, $m)) { break }
            $rr = [datetime]::new($y, $m, $d)
            if (-not $hasYear -and $rr -lt $today) { $rr = $rr.AddYears(1) }
            $r = $rr; break
        }
        '^(\d{1,2})$' {
            $d = [int]$Matches[1]
            if ($d -lt 1) { break }
            if ($d -le [datetime]::DaysInMonth($today.Year, $today.Month)) {
                $rr = [datetime]::new($today.Year, $today.Month, $d)
                if ($rr -ge $today) { $r = $rr; break }
            }
            $y = $today.Year; $m = $today.Month + 1
            if ($m -gt 12) { $m = 1; $y++ }
            if ($d -le [datetime]::DaysInMonth($y, $m)) { $r = [datetime]::new($y, $m, $d) }
            break
        }
    }
    if ($r -and $tod) {
        $ts = ConvertTo-TimeOfDay $tod
        if ($ts) { $r = $r.Date.Add($ts) }
    }
    return $r
}

function Get-DueLabel {
    param([string]$Due)
    if ([string]::IsNullOrWhiteSpace($Due)) { return $null }
    $d = $null; $hasTime = $false
    if ($Due -match '^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})$') {
        try {
            $base = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            $d = $base.AddHours([int]$Matches[2].Split(':')[0]).AddMinutes([int]$Matches[2].Split(':')[1])
            $hasTime = $true
        } catch { return $null }
    } else {
        try { $d = [datetime]::ParseExact($Due, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture).Date } catch { return $null }
    }
    $now = Get-Date
    $diff = ($d.Date - $now.Date).Days
    $at = if ($hasTime) { ' at ' + $d.ToString('HH:mm') } else { '' }
    $overdue = if ($hasTime) { $d -lt $now } else { $diff -lt 0 }
    if ($overdue) {
        if ($hasTime -and $diff -eq 0) {
            $span = $now - $d
            if ($span.TotalHours -ge 1) { return "overdue by $([int][Math]::Floor($span.TotalHours))h $($span.Minutes)m" }
            return "overdue by $($span.Minutes)m"
        }
        $n = -$diff; return $(if ($n -eq 1) { 'overdue by 1 day' } else { "overdue by $n days" })
    }
    if ($diff -eq 0) { return "today$at" }
    if ($diff -eq 1) { return "tomorrow$at" }
    if ($diff -le 6) { return "in $diff days, $($d.ToString('ddd'))$at" }
    return $null
}

function Get-DueColorInfo {
    param($Palette, [string]$Due, [bool]$Completed)
    if ([string]::IsNullOrWhiteSpace($Due) -or $Completed) { return @{ Fg = $Palette.Warning; Bold = $false } }
    $d = $null; $hasTime = $false
    if ($Due -match '^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})$') {
        try {
            $base = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null)
            $d = $base.AddHours([int]$Matches[2].Split(':')[0]).AddMinutes([int]$Matches[2].Split(':')[1])
            $hasTime = $true
        } catch { return @{ Fg = $Palette.Warning; Bold = $false } }
    } else {
        try { $d = [datetime]::ParseExact($Due, 'yyyy-MM-dd', $null).Date } catch { return @{ Fg = $Palette.Warning; Bold = $false } }
    }
    $now = Get-Date
    if ($hasTime) {
        if ($d -lt $now)                          { return @{ Fg = $Palette.Danger;  Bold = $true } }
        if ($d -lt $now.AddHours(1))              { return @{ Fg = $Palette.Warning; Bold = $true } }
        if ($d.Date -eq $now.Date)                { return @{ Fg = $Palette.Warning; Bold = $true } }
        if (($d.Date - $now.Date).Days -eq 1)     { return @{ Fg = $Palette.Warning; Bold = $true } }
        if (($d.Date - $now.Date).Days -le 6)     { return @{ Fg = $Palette.Warning; Bold = $false } }
        return @{ Fg = $Palette.Warning; Bold = $false }
    }
    $diff = ($d - $now.Date).Days
    if ($diff -lt 0)     { return @{ Fg = $Palette.Danger;  Bold = $true } }
    if ($diff -le 1)     { return @{ Fg = $Palette.Warning; Bold = $true } }
    return @{ Fg = $Palette.Warning; Bold = $false }
}

function Apply-TaskDue {
    param([datetime]$Date)
    $t = $script:SelectedTask
    if (-not $t) { Set-Status 'No task selected.'; return $false }
    Push-Undo
    $fmt = if ($Date.TimeOfDay -eq [timespan]::Zero) { 'yyyy-MM-dd' } else { 'yyyy-MM-ddTHH:mm' }
    $iso = $Date.ToString($fmt)
    if ($t.Description -match '(?<=^|\s)due:\S+') {
        $t.Description = [regex]::Replace($t.Description, '(?<=^|\s)due:\S+', "due:$iso")
    } else {
        $t.Description = $t.Description.TrimEnd() + " due:$iso"
    }
    Save-Tasks
    $label = Get-DueLabel $iso
    $disp = Format-DueDisplay $iso
    Set-Status $(if ($label) { "Due set: $disp ($label)." } else { "Due set: $disp." })
    return $true
}

function Clear-TaskDue {
    $t = $script:SelectedTask
    if (-not $t) { Set-Status 'No task selected.'; return }
    Push-Undo
    $t.Description = ([regex]::Replace($t.Description, '(?<=^|\s)due:\S+\s?', '') -replace '\s+', ' ').Trim()
    Save-Tasks
    Set-Status 'Due date removed.'
}

function Normalize-DueTokens {
    param([string]$Text)
    if (-not $Text) { return $Text }
    $timeTok = '\d{1,2}:\d{2}\s*(?:am|pm)?|\d{1,2}\s*(?:am|pm)|noon|midnight'
    return [regex]::Replace($Text, "(?<=^|\s)due:(\S+(?:\s+(?:$timeTok|\d{1,2}))*)", {
        param($m)
        $d = ConvertFrom-FuzzyDate -Text $m.Groups[1].Value.Replace('_', ' ')
        if ($d) {
            $fmt = if ($d.TimeOfDay -eq [timespan]::Zero) { 'yyyy-MM-dd' } else { 'yyyy-MM-ddTHH:mm' }
            'due:' + $d.ToString($fmt)
        } else { $m.Value }
    })
}

function Get-AllProjects { @(($script:Tasks | ForEach-Object { Get-TaskProjects $_ }) | Where-Object { $_ } | Select-Object -Unique | Sort-Object) }
function Get-AllContexts { @(($script:Tasks | ForEach-Object { Get-TaskContexts $_ }) | Where-Object { $_ } | Select-Object -Unique | Sort-Object) }

# ============================================================================
#  PERSISTENCE (atomic write: temp then rename)                       GlaStFiN
# ============================================================================
function Load-Config {
    $default = [pscustomobject]@{
        Theme = 'MutedSlate'; Density = 'comfortable'; Sort = 'priority'
        ShowFilterSidebar = $false; ShowDetailSidebar = $true
        ShowDone = $true; LineNumbers = $false
    }
    if (Test-Path -LiteralPath $script:ConfigFile) {
        try {
            $loaded = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            foreach ($p in $default.PSObject.Properties.Name) {
                if ($null -ne $loaded.$p) { $default.$p = $loaded.$p }
            }
        } catch {}
    }
    $script:Config = $default
}

function Save-Config {
    $json = $script:Config | ConvertTo-Json -Depth 3
    $tmp = "$($script:ConfigFile).tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $script:ConfigFile -Force
}

function Import-LegacyTasksIfNeeded {
    if ((Test-Path -LiteralPath $script:LegacyFile) -and (-not (Test-Path -LiteralPath $script:TodoFile))) {
        try {
            $items = @(Get-Content -LiteralPath $script:LegacyFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
            foreach ($item in $items) {
                if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item.Title)) {
                    $done = [bool]$item.Completed
                    $script:Tasks.Add([pscustomobject]@{
                        Completed = $done
                        CompletionDate = $(if ($done) { Get-Date -Format 'yyyy-MM-dd' } else { $null })
                        Priority = $null
                        CreationDate = (Get-Date -Format 'yyyy-MM-dd')
                        Description = [string]$item.Title
                    })
                }
            }
            Save-Tasks
        } catch {}
    }
}

function Load-Tasks {
    $script:Tasks.Clear()
    if (Test-Path -LiteralPath $script:TodoFile) {
        foreach ($line in (Get-Content -LiteralPath $script:TodoFile -Encoding UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $script:Tasks.Add((ConvertFrom-TodoLine -Line $line))
        }
    }
}

function Save-Tasks {
    $lines = @($script:Tasks | ForEach-Object { ConvertTo-TodoLine -Task $_ })
    $tmp = "$($script:TodoFile).tmp"
    Set-Content -LiteralPath $tmp -Value $lines -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $script:TodoFile -Force
}

function Load-Done {
    $script:DoneTasks.Clear()
    if (Test-Path -LiteralPath $script:DoneFile) {
        foreach ($line in (Get-Content -LiteralPath $script:DoneFile -Encoding UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $script:DoneTasks.Add((ConvertFrom-TodoLine -Line $line))
        }
    }
}

function Save-Done {
    $lines = @($script:DoneTasks | ForEach-Object { ConvertTo-TodoLine -Task $_ })
    $tmp = "$($script:DoneFile).tmp"
    Set-Content -LiteralPath $tmp -Value $lines -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $script:DoneFile -Force
}

# ============================================================================
#  UNDO STACK (50 levels)                                             GlaStFiN
# ============================================================================
function Push-Undo {
    $snapshot = @($script:Tasks | ForEach-Object { $_.PSObject.Copy() })
    $script:UndoStack.Add($snapshot)
    if ($script:UndoStack.Count -gt 50) { $script:UndoStack.RemoveAt(0) }
}

function Invoke-Undo {
    if ($script:UndoStack.Count -eq 0) { Set-Status 'Nothing to undo.'; return }
    $last = $script:UndoStack[$script:UndoStack.Count - 1]
    $script:UndoStack.RemoveAt($script:UndoStack.Count - 1)
    $script:Tasks.Clear()
    foreach ($t in $last) { $script:Tasks.Add($t) }
    Save-Tasks
    Sync-Selection
    Set-Status 'Undo.'
}

# ============================================================================
#  VIEW / SELECTION MANAGEMENT                                        GlaStFiN
# ============================================================================
function Get-ViewList {
    $items = @($script:Tasks)
    if (-not $script:Config.ShowDone) { $items = @($items | Where-Object { -not $_.Completed }) }
    if ($script:FilterProject) { $items = @($items | Where-Object { @(Get-TaskProjects $_) -contains $script:FilterProject }) }
    if ($script:FilterContext) { $items = @($items | Where-Object { @(Get-TaskContexts $_) -contains $script:FilterContext }) }
    if ($script:SearchQuery) {
        $q = [System.Management.Automation.WildcardPattern]::Escape($script:SearchQuery)
        $items = @($items | Where-Object { $_.Description -like "*$q*" })
    }
    switch ($script:Config.Sort) {
        'priority' { $items = @($items | Sort-Object -Property @{Expression={ if ($_.Priority) { $_.Priority } else { 'ZZZ' } }}) }
        'due'      { $items = @($items | Sort-Object -Property @{Expression={ $d = Get-TaskDue $_; if ($d) { $d } else { '9999-99-99' } }}) }
        default    { }
    }
    return @($items)
}

function Get-DoneView { @($script:DoneTasks | Sort-Object -Property CompletionDate -Descending) }

function Sync-Selection {
    $view = @(Get-ViewList)
    if ($view.Count -eq 0) { $script:SelectedTask = $null; return }
    if ($script:SelectedTask) {
        $idx = [array]::IndexOf($view, $script:SelectedTask)
        if ($idx -ge 0) { return }
    }
    $script:SelectedTask = $view[0]
}

function Sync-DoneSelection {
    $view = @(Get-DoneView)
    $script:SelectedDone = if ($view.Count -gt 0) { $view[0] } else { $null }
}

function Move-Selection {
    param([int]$Delta)
    $view = @(Get-ViewList)
    if ($view.Count -eq 0) { $script:SelectedTask = $null; return }
    $idx = [array]::IndexOf($view, $script:SelectedTask)
    if ($idx -lt 0) { $idx = 0 } else { $idx += $Delta }
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -gt $view.Count - 1) { $idx = $view.Count - 1 }
    $script:SelectedTask = $view[$idx]
}

function Jump-Top    { $view = @(Get-ViewList); if ($view.Count -gt 0) { $script:SelectedTask = $view[0] } }
function Jump-Bottom { $view = @(Get-ViewList); if ($view.Count -gt 0) { $script:SelectedTask = $view[$view.Count - 1] } }

function Move-DoneSelection {
    param([int]$Delta)
    $view = @(Get-DoneView)
    if ($view.Count -eq 0) { $script:SelectedDone = $null; return }
    $idx = [array]::IndexOf($view, $script:SelectedDone)
    if ($idx -lt 0) { $idx = 0 } else { $idx += $Delta }
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -gt $view.Count - 1) { $idx = $view.Count - 1 }
    $script:SelectedDone = $view[$idx]
}

# ============================================================================
#  TASK COMMANDS                                                      GlaStFiN
# ============================================================================
function Set-Status {
    param([string]$Message)
    $script:StatusMessage = $Message
    $script:StatusExpire = (Get-Date).AddSeconds(3)
}

function Toggle-Complete {
    if (-not $script:SelectedTask) { return }
    Push-Undo
    $script:SelectedTask.Completed = -not $script:SelectedTask.Completed
    $script:SelectedTask.CompletionDate = if ($script:SelectedTask.Completed) { Get-Date -Format 'yyyy-MM-dd' } else { $null }
    Save-Tasks
}

function Cycle-Priority {
    if (-not $script:SelectedTask) { return }
    Push-Undo
    $next = switch ($script:SelectedTask.Priority) {
        $null   { 'A' }
        'A'     { 'B' }
        'B'     { 'C' }
        'C'     { $null }
        default { $null }
    }
    $script:SelectedTask.Priority = $next
    Save-Tasks
}

function Delete-Current {
    $view = @(Get-ViewList)
    if ($view.Count -eq 0) { return }
    $idx = [array]::IndexOf($view, $script:SelectedTask)
    if ($idx -lt 0) { $idx = 0 }
    Push-Undo
    $target = $view[$idx]
    $script:Tasks.Remove($target) | Out-Null
    Save-Tasks
    $newView = @(Get-ViewList)
    if ($newView.Count -eq 0) { $script:SelectedTask = $null }
    else {
        $newIdx = [Math]::Min($idx, $newView.Count - 1)
        $script:SelectedTask = $newView[$newIdx]
    }
    Set-Status 'Task deleted.'
}

function Complete-MultiSelected {
    if ($script:MultiSelected.Count -eq 0) { $script:Mode = 'normal'; return }
    Push-Undo
    foreach ($t in $script:MultiSelected) { $t.Completed = $true; $t.CompletionDate = (Get-Date -Format 'yyyy-MM-dd') }
    Save-Tasks
    $script:MultiSelected.Clear()
    $script:Mode = 'normal'
    Sync-Selection
    Set-Status 'Bulk complete.'
}

function Delete-MultiSelected {
    if ($script:MultiSelected.Count -eq 0) { $script:Mode = 'normal'; return }
    Push-Undo
    foreach ($t in $script:MultiSelected) { $script:Tasks.Remove($t) | Out-Null }
    Save-Tasks
    $script:MultiSelected.Clear()
    $script:Mode = 'normal'
    Sync-Selection
    Set-Status 'Bulk delete.'
}

function Invoke-Archive {
    $completed = @($script:Tasks | Where-Object { $_.Completed })
    if ($completed.Count -eq 0) { Set-Status 'Nothing to archive.'; return }
    Push-Undo
    foreach ($t in $completed) { $script:DoneTasks.Add($t); $script:Tasks.Remove($t) | Out-Null }
    Save-Done
    Save-Tasks
    Sync-Selection
    Set-Status "Archived $($completed.Count) task(s)."
}

function Invoke-Unarchive {
    if (-not $script:SelectedDone) { return }
    $t = $script:SelectedDone
    $script:DoneTasks.Remove($t) | Out-Null
    $script:Tasks.Add($t)
    Save-Done
    Save-Tasks
    Sync-DoneSelection
    Sync-Selection
    Set-Status 'Un-archived.'
}

function Remove-DoneForever {
    if (-not $script:SelectedDone) { return }
    $script:DoneTasks.Remove($script:SelectedDone) | Out-Null
    Save-Done
    Sync-DoneSelection
    Set-Status 'Deleted from archive.'
}

function Apply-Tag {
    param([string]$Symbol)
    if (-not $script:SelectedTask) { return }
    $tag = $script:InputBuffer.Trim()
    if (-not $tag) { return }
    Push-Undo
    $pattern = "(?<=^|\s)$([regex]::Escape($Symbol))$([regex]::Escape($tag))(?=\s|$)"
    if ($script:SelectedTask.Description -match $pattern) {
        $script:SelectedTask.Description = (($script:SelectedTask.Description -replace $pattern, '').Trim() -replace '\s{2,}', ' ')
        Set-Status "Removed $Symbol$tag"
    } else {
        $script:SelectedTask.Description = ("$($script:SelectedTask.Description) $Symbol$tag").Trim()
        Set-Status "Added $Symbol$tag"
    }
    Save-Tasks
}

function Apply-FilterPick {
    if ($script:FilterPickerItems.Count -eq 0) { return }
    $val = $script:FilterPickerItems[$script:FilterPickerIndex]
    if ($script:FilterPickerBy -eq 'project') { $script:FilterProject = $val } else { $script:FilterContext = $val }
    Sync-Selection
}

function Enter-FilterMode {
    param([string]$By)
    $items = @(if ($By -eq 'project') { Get-AllProjects } else { Get-AllContexts })
    if ($items.Count -eq 0) { Set-Status "No $By tags found."; return }
    $script:FilterPickerBy = $By
    $script:FilterPickerItems = $items
    $current = if ($By -eq 'project') { $script:FilterProject } else { $script:FilterContext }
    $idx = [array]::IndexOf($items, $current)
    if ($idx -lt 0) { $idx = 0 }
    $script:FilterPickerIndex = $idx
    $script:Mode = 'filterpick'
    Apply-FilterPick
}

function Cycle-Theme {
    $idx = [array]::IndexOf($script:ThemeOrder, $script:Config.Theme)
    $idx = ($idx + 1) % $script:ThemeOrder.Count
    $script:Config.Theme = $script:ThemeOrder[$idx]
    Save-Config
}

function Cycle-Density {
    $order = @('compact','comfortable','cozy')
    $idx = [array]::IndexOf($order, $script:Config.Density)
    $idx = ($idx + 1) % $order.Count
    $script:Config.Density = $order[$idx]
    Save-Config
}

function Cycle-Sort {
    $order = @('priority','due','file')
    $idx = [array]::IndexOf($order, $script:Config.Sort)
    $idx = ($idx + 1) % $order.Count
    $script:Config.Sort = $order[$idx]
    Save-Config
}

# ============================================================================
#  TEXT INPUT MODES (add / edit / search / tag prompts)               GlaStFiN
# ============================================================================
function Confirm-TextInput {
    switch ($script:Mode) {
        'add' {
            $text = Normalize-DueTokens -Text $script:InputBuffer.Trim()
            if ($text) {
                Push-Undo
                $task = ConvertFrom-TodoLine -Line $text
                if (-not $task.CreationDate) { $task.CreationDate = (Get-Date -Format 'yyyy-MM-dd') }
                $script:Tasks.Add($task)
                Save-Tasks
                $script:SelectedTask = $task
                $dueNow = Get-TaskDue $task
                $lbl = Get-DueLabel $dueNow
                Set-Status $(if ($lbl) { "Task added. due $(Format-DueDisplay $dueNow) ($lbl)." } else { 'Task added.' })
            }
        }
        'edit' {
            $text = Normalize-DueTokens -Text $script:InputBuffer.Trim()
            if ($text -and $script:SelectedTask) {
                Push-Undo
                $script:SelectedTask.Description = $text
                Save-Tasks
                Set-Status 'Task updated.'
            }
        }
        'setdue' {
            $in = $script:InputBuffer.Trim()
            if (-not $script:SelectedTask) { Set-Status 'No task selected.' }
            elseif ($in -match '^(?:clear|none|remove|-)$') { Clear-TaskDue }
            else {
                $d = ConvertFrom-FuzzyDate -Text $in
                if ($d) { Apply-TaskDue -Date $d | Out-Null }
                else { Set-Status "?? can't parse date: $in" }
            }
        }
        'search' {
            $script:SearchQuery = $script:InputBuffer.Trim()
            Sync-Selection
        }
        'addproject' { Apply-Tag -Symbol '+' }
        'addcontext' { Apply-Tag -Symbol '@' }
    }
    $script:Mode = 'normal'
    $script:InputBuffer = ''
}

function Process-TextInput {
    param($Key)
    if ($Key.Key -eq [ConsoleKey]::Enter) { Confirm-TextInput; return }
    if ($Key.Key -eq [ConsoleKey]::Escape) {
        if ($script:Mode -eq 'search') { $script:SearchQuery = '' }
        $script:Mode = 'normal'
        $script:InputBuffer = ''
        Sync-Selection
        return
    }
    if ($Key.Key -eq [ConsoleKey]::Backspace) {
        if ($script:InputBuffer.Length -gt 0) { $script:InputBuffer = $script:InputBuffer.Substring(0, $script:InputBuffer.Length - 1) }
        if ($script:Mode -eq 'search') { $script:SearchQuery = $script:InputBuffer; Sync-Selection }
        return
    }
    if ($Key.KeyChar -and -not [char]::IsControl($Key.KeyChar)) {
        $script:InputBuffer += $Key.KeyChar
        if ($script:Mode -eq 'search') { $script:SearchQuery = $script:InputBuffer; Sync-Selection }
    }
}

# ============================================================================
#  KEY DISPATCH                                                       GlaStFiN
# ============================================================================
function Wait-Key {
    if (-not [Console]::IsInputRedirected) {
        # live-resize poll: repaint as soon as the window size changes,
        # without requiring a keypress (returns $null => main loop re-renders)
        try {
            $w = [Console]::WindowWidth
            $h = [Console]::WindowHeight
            while ($script:Running) {
                if ([Console]::KeyAvailable) { return [Console]::ReadKey($true) }
                Start-Sleep -Milliseconds 40
                if ([Console]::WindowWidth -ne $w -or [Console]::WindowHeight -ne $h) { return $null }
            }
            return $null
        } catch {
            return [Console]::ReadKey($true)
        }
    }
    $ch = [Console]::In.Read()
    if ($ch -lt 0) { $script:Running = $false; return $null }
    $c = [char]$ch
    if ($c -eq "`r" -or $c -eq "`n") { return [pscustomobject]@{ Key = [ConsoleKey]::Enter;    KeyChar = "`r"; Modifiers = [ConsoleModifiers]::None } }
    if ([int]$ch -eq 8)               { return [pscustomobject]@{ Key = [ConsoleKey]::Backspace; KeyChar = [char]8; Modifiers = [ConsoleModifiers]::None } }
    if ([int]$ch -eq 27)              { return [pscustomobject]@{ Key = [ConsoleKey]::Escape;   KeyChar = [char]27; Modifiers = [ConsoleModifiers]::None } }
    return [pscustomobject]@{ Key = [ConsoleKey]::NoName; KeyChar = $c; Modifiers = [ConsoleModifiers]::None }
}

function Process-NormalKey {
    param($Key)
    switch ($Key.KeyChar.ToString()) {
        'j' { Move-Selection 1 }
        'k' { Move-Selection -1 }
        'g' { $script:PendingChord = 'g' }
        'G' { Jump-Bottom }
        'n' { $script:Mode = 'add'; $script:InputBuffer = '' }
        'e' { if ($script:SelectedTask) { $script:Mode = 'edit'; $script:InputBuffer = $script:SelectedTask.Description } }
        'i' { if ($script:SelectedTask) { $script:Mode = 'edit'; $script:InputBuffer = $script:SelectedTask.Description } }
        'x' { Toggle-Complete }
        'd' { $script:PendingChord = 'd' }
        'p' { Cycle-Priority }
        'c' { if ($script:SelectedTask) { $script:Mode = 'addcontext'; $script:InputBuffer = '' } }
        '+' { if ($script:SelectedTask) { $script:Mode = 'addproject'; $script:InputBuffer = '' } }
        'u' { Invoke-Undo }
        '/' { $script:Mode = 'search'; $script:InputBuffer = $script:SearchQuery }
        'f' { $script:PendingChord = 'f' }
        'S' { Cycle-Sort }
        'v' { if ($script:SelectedTask) { $script:Mode = 'visual'; $script:MultiSelected.Clear() } }
        'l' { }
        'a' { $script:Mode = 'archive'; Load-Done; Sync-DoneSelection }
        'A' { Invoke-Archive }
        'H' { $script:Config.ShowDone = -not $script:Config.ShowDone; Save-Config; Sync-Selection }
        '[' { $script:Config.ShowFilterSidebar = -not $script:Config.ShowFilterSidebar; Save-Config }
        ']' { $script:Config.ShowDetailSidebar = -not $script:Config.ShowDetailSidebar; Save-Config }
        'T' { Cycle-Theme }
        'D' { Cycle-Density }
        'L' { $script:Config.LineNumbers = -not $script:Config.LineNumbers; Save-Config }
        '?' { $script:PreviousMode = $script:Mode; $script:Mode = 'help' }
        ',' { $script:Mode = 'settings' }
        'q' { $script:Running = $false }
        default {
            if ($Key.Key -eq [ConsoleKey]::DownArrow) { Move-Selection 1 }
            elseif ($Key.Key -eq [ConsoleKey]::UpArrow) { Move-Selection -1 }
            elseif ($Key.Key -eq [ConsoleKey]::Escape) {
                $script:FilterProject = $null; $script:FilterContext = $null; $script:SearchQuery = ''
                Sync-Selection
            }
            elseif ($Key.Key -eq [ConsoleKey]::D -and ($Key.Modifiers -band [ConsoleModifiers]::Control)) {
                Move-Selection ([Math]::Max(1, [int]($script:LastVisibleCount / 2)))
            }
            elseif ($Key.Key -eq [ConsoleKey]::U -and ($Key.Modifiers -band [ConsoleModifiers]::Control)) {
                Move-Selection (-1 * [Math]::Max(1, [int]($script:LastVisibleCount / 2)))
            }
        }
    }
}

function Process-VisualKey {
    param($Key)
    switch ($Key.KeyChar.ToString()) {
        'j' { Move-Selection 1 }
        'k' { Move-Selection -1 }
        ' ' {
            if ($script:SelectedTask) {
                if ($script:MultiSelected.Contains($script:SelectedTask)) { $script:MultiSelected.Remove($script:SelectedTask) | Out-Null }
                else { $script:MultiSelected.Add($script:SelectedTask) }
            }
        }
        'x' { Complete-MultiSelected }
        'd' { $script:PendingChord = 'd' }
        default {
            if ($Key.Key -eq [ConsoleKey]::Escape) { $script:MultiSelected.Clear(); $script:Mode = 'normal' }
            elseif ($Key.Key -eq [ConsoleKey]::DownArrow) { Move-Selection 1 }
            elseif ($Key.Key -eq [ConsoleKey]::UpArrow) { Move-Selection -1 }
        }
    }
}

function Process-ArchiveKey {
    param($Key)
    switch ($Key.KeyChar.ToString()) {
        'j' { Move-DoneSelection 1 }
        'k' { Move-DoneSelection -1 }
        'u' { Invoke-Unarchive }
        'd' { $script:PendingChord = 'd' }
        'a' { $script:Mode = 'normal' }
        'l' { $script:Mode = 'normal' }
        default {
            if ($Key.Key -eq [ConsoleKey]::Escape) { $script:Mode = 'normal' }
            elseif ($Key.Key -eq [ConsoleKey]::DownArrow) { Move-DoneSelection 1 }
            elseif ($Key.Key -eq [ConsoleKey]::UpArrow) { Move-DoneSelection -1 }
        }
    }
}

function Process-FilterPickKey {
    param($Key)
    if ($Key.Key -eq [ConsoleKey]::Escape) {
        if ($script:FilterPickerBy -eq 'project') { $script:FilterProject = $null } else { $script:FilterContext = $null }
        $script:Mode = 'normal'
        Sync-Selection
        return
    }
    if ($Key.KeyChar.ToString() -eq 'j' -or $Key.Key -eq [ConsoleKey]::DownArrow) {
        $script:FilterPickerIndex = [Math]::Min($script:FilterPickerIndex + 1, $script:FilterPickerItems.Count - 1)
        Apply-FilterPick
        return
    }
    if ($Key.KeyChar.ToString() -eq 'k' -or $Key.Key -eq [ConsoleKey]::UpArrow) {
        $script:FilterPickerIndex = [Math]::Max($script:FilterPickerIndex - 1, 0)
        Apply-FilterPick
        return
    }
    $script:Mode = 'normal'
}

function Process-Key {
    param($Key)

    if ($script:Mode -in @('add','edit','search','addproject','addcontext','setdue')) { Process-TextInput -Key $Key; return }
    if ($script:Mode -eq 'help')     { $script:Mode = $script:PreviousMode; return }
    if ($script:Mode -eq 'confirmuninstall') {
        switch ($Key.KeyChar.ToString()) {
            'y' { Invoke-Uninstall -RemoveData $false; $script:Running = $false }
            'd' { Invoke-Uninstall -RemoveData $true;  $script:Running = $false }
            default { $script:Mode = 'settings' }
        }
        return
    }
    if ($script:Mode -eq 'settings') {
        switch ($Key.KeyChar.ToString()) {
            'T' { Cycle-Theme }
            'D' { Cycle-Density }
            'S' { Cycle-Sort }
            'L' { $script:Config.LineNumbers = -not $script:Config.LineNumbers; Save-Config }
            'H' { $script:Config.ShowDone = -not $script:Config.ShowDone; Save-Config; Sync-Selection }
            'U' { $script:Mode = 'confirmuninstall' }
            default { $script:Mode = 'normal' }
        }
        return
    }
    if ($script:Mode -eq 'filterpick') { Process-FilterPickKey -Key $Key; return }

    if ($script:PendingChord) {
        $combo = "$($script:PendingChord)$($Key.KeyChar)"
        $script:PendingChord = $null
        switch ($combo) {
            'gg' { Jump-Top }
            'dd' {
                if ($script:Mode -eq 'visual') { Delete-MultiSelected }
                elseif ($script:Mode -eq 'archive') { Remove-DoneForever }
                else { Delete-Current }
            }
            'du' {
                if ($script:Mode -eq 'archive') { }
                elseif ($script:SelectedTask) { $script:Mode = 'setdue'; $script:InputBuffer = '' }
                else { Set-Status 'No task selected.' }
            }
            'dt' {
                if ($script:Mode -ne 'archive') { Apply-TaskDue -Date (Get-Date).Date | Out-Null }
            }
            'dw' {
                if ($script:Mode -ne 'archive') { Apply-TaskDue -Date (Get-Date).Date.AddDays(7) | Out-Null }
            }
            'fp' { if ($script:Mode -ne 'archive') { Enter-FilterMode -By 'project' } }
            'fc' { if ($script:Mode -ne 'archive') { Enter-FilterMode -By 'context' } }
            default { }
        }
        return
    }

    if ($script:Mode -eq 'archive') { Process-ArchiveKey -Key $Key; return }
    if ($script:Mode -eq 'visual')  { Process-VisualKey -Key $Key; return }
    Process-NormalKey -Key $Key
}

# ============================================================================
#  RENDERING                                                          GlaStFiN
# ============================================================================
function Get-ConsoleSize {
    try {
        $w = [Console]::WindowWidth
        $h = [Console]::WindowHeight
        if ($w -lt 24) { $w = 24 }
        if ($h -lt 8)  { $h = 8 }
        return @($w, $h)
    } catch { return @(100, 32) }
}

function Get-Layout {
    param([int]$TotalWidth)
    $filterW = if ($script:Config.ShowFilterSidebar) { 18 } else { 0 }
    $detailW = if ($script:Config.ShowDetailSidebar) { 26 } else { 0 }
    $extra = ($(if ($filterW -gt 0) { $filterW + 1 } else { 0 })) + ($(if ($detailW -gt 0) { $detailW + 1 } else { 0 }))
    $mainW = $TotalWidth - 2 - $extra
    if ($mainW -lt 24 -and $detailW -gt 0) {
        $detailW = 0
        $extra = ($(if ($filterW -gt 0) { $filterW + 1 } else { 0 }))
        $mainW = $TotalWidth - 2 - $extra
    }
    if ($mainW -lt 24 -and $filterW -gt 0) {
        $filterW = 0
        $mainW = $TotalWidth - 2
    }
    if ($mainW -lt 10) { $mainW = 10 }
    return [pscustomobject]@{ FilterWidth = $filterW; DetailWidth = $detailW; MainWidth = $mainW }
}

function Get-BorderLine {
    param($Layout, $Palette, [string]$Position, [int]$Width)
    $l = if ($Position -eq 'top') { '┌' } else { '└' }
    $r = if ($Position -eq 'top') { '┐' } else { '┘' }
    $t = if ($Position -eq 'top') { '┬' } else { '┴' }
    $text = $l + ('─' * $Layout.FilterWidth)
    if ($Layout.FilterWidth -gt 0) { $text += $t }
    $text += ('─' * $Layout.MainWidth)
    if ($Layout.DetailWidth -gt 0) { $text += $t + ('─' * $Layout.DetailWidth) }
    $text += $r
    return (Complete-Row -Segments @(@{ Text = $text; Fg = $Palette.Border }) -Width $Width)
}

function Build-TaskRowSegments {
    param($Task, [int]$Width, [bool]$Selected, [bool]$Multi, $Palette, [int]$Number)
    $segs = New-Object System.Collections.Generic.List[object]
    if ($script:Config.LineNumbers) { $segs.Add(@{ Text = ('{0,3} ' -f $Number); Fg = $Palette.Muted }) }
    if ($Multi) { $segs.Add(@{ Text = '* '; Fg = $Palette.Accent; Bold = $true }) }
    if ($Task.Completed) {
        $segs.Add(@{ Text = '[x] '; Fg = $Palette.Success })
    } elseif ($Task.Priority) {
        $pcolor = switch ($Task.Priority) { 'A' { $Palette.Danger } 'B' { $Palette.Warning } default { $Palette.Success } }
        $segs.Add(@{ Text = "[$($Task.Priority)] "; Fg = $pcolor; Bold = $true })
    } else {
        $segs.Add(@{ Text = '[ ] '; Fg = $Palette.Muted })
    }
    $desc = $Task.Description
    foreach ($tok in ($desc -split '(\s+)')) {
        if ($tok -match '^\+\S+$')      { $segs.Add(@{ Text = $tok; Fg = $Palette.Accent;  Strike = $Task.Completed }) }
        elseif ($tok -match '^@\S+$')   { $segs.Add(@{ Text = $tok; Fg = $Palette.Success; Strike = $Task.Completed }) }
        elseif ($tok -match '^due:\S+$'){
            $dc = Get-DueColorInfo -Palette $Palette -Due ($tok -replace '^due:', '') -Completed ([bool]$Task.Completed)
            $segs.Add(@{ Text = $tok; Fg = $dc.Fg; Bold = $dc.Bold; Strike = $Task.Completed })
        }
        else                            { $segs.Add(@{ Text = $tok; Fg = $(if ($Task.Completed) { $Palette.Muted } else { $Palette.Text }); Strike = $Task.Completed }) }
    }
    $bg = if ($Selected) { $Palette.Selection } else { $null }
    return @{ Segments = @($segs.ToArray()); Bg = $bg }
}

function Build-FilterSidebarRows {
    param([int]$Height, $Palette)
    $rows = New-Object System.Collections.Generic.List[object]
    $rows.Add(@{ Segments = @(@{ Text = 'PROJECTS'; Fg = $Palette.Muted; Bold = $true }) })
    $projects = @(Get-AllProjects)
    if ($projects.Count -eq 0) { $rows.Add(@{ Segments = @(@{ Text = '  (none)'; Fg = $Palette.Muted }) }) }
    foreach ($p in $projects) {
        $active = ($p -eq $script:FilterProject)
        $rows.Add(@{ Segments = @(@{ Text = "  +$p"; Fg = $(if ($active) { $Palette.Accent } else { $Palette.Text }); Bold = $active }) })
    }
    $rows.Add(@{ Segments = @() })
    $rows.Add(@{ Segments = @(@{ Text = 'CONTEXTS'; Fg = $Palette.Muted; Bold = $true }) })
    $contexts = @(Get-AllContexts)
    if ($contexts.Count -eq 0) { $rows.Add(@{ Segments = @(@{ Text = '  (none)'; Fg = $Palette.Muted }) }) }
    foreach ($c in $contexts) {
        $active = ($c -eq $script:FilterContext)
        $rows.Add(@{ Segments = @(@{ Text = "  @$c"; Fg = $(if ($active) { $Palette.Accent } else { $Palette.Text }); Bold = $active }) })
    }
    while ($rows.Count -lt $Height) { $rows.Add(@{ Segments = @() }) }
    if ($rows.Count -gt $Height) { $rows = [System.Collections.Generic.List[object]]($rows.GetRange(0, $Height)) }
    return $rows
}

function Build-DetailSidebarRows {
    param([int]$Height, $Palette)
    $rows = New-Object System.Collections.Generic.List[object]
    $rows.Add(@{ Segments = @(@{ Text = 'DETAIL'; Fg = $Palette.Muted; Bold = $true }) })
    $rows.Add(@{ Segments = @() })
    $t = $script:SelectedTask
    if (-not $t) {
        $rows.Add(@{ Segments = @(@{ Text = 'No task selected'; Fg = $Palette.Muted }) })
    } else {
        $rows.Add(@{ Segments = @(@{ Text = "Status:   $(if ($t.Completed) {'Done'} else {'Open'})"; Fg = $Palette.Text }) })
        $rows.Add(@{ Segments = @(@{ Text = "Priority: $(if ($t.Priority) { $t.Priority } else { '-' })"; Fg = $Palette.Text }) })
        $rows.Add(@{ Segments = @(@{ Text = "Created:  $(if ($t.CreationDate) { $t.CreationDate } else { '-' })"; Fg = $Palette.Text }) })
    $due = Get-TaskDue $t
    $rows.Add(@{ Segments = @(@{ Text = "Due:      $(if ($due) { Format-DueDisplay $due } else { '-' })"; Fg = $Palette.Text }) })
    $dueLbl = Get-DueLabel $due
    if ($dueLbl) {
        $lblFg = if ($dueLbl.StartsWith('overdue')) { $Palette.Danger }
                 elseif ($dueLbl.StartsWith('today') -or $dueLbl.StartsWith('tomorrow')) { $Palette.Warning }
                 else { $Palette.Muted }
        $rows.Add(@{ Segments = @(@{ Text = "  $dueLbl"; Fg = $lblFg }) })
    }
        $projs = (Get-TaskProjects $t) -join ', '
        $rows.Add(@{ Segments = @(@{ Text = "Projects: $(if ($projs) { $projs } else { '-' })"; Fg = $Palette.Text }) })
        $ctxs = (Get-TaskContexts $t) -join ', '
        $rows.Add(@{ Segments = @(@{ Text = "Contexts: $(if ($ctxs) { $ctxs } else { '-' })"; Fg = $Palette.Text }) })
    }
    while ($rows.Count -lt $Height) { $rows.Add(@{ Segments = @() }) }
    if ($rows.Count -gt $Height) { $rows = [System.Collections.Generic.List[object]]($rows.GetRange(0, $Height)) }
    return $rows
}

function Get-ListLines {
    param([int]$Width, [int]$InnerHeight, $Palette, $Layout, [int]$RowGap, [int]$BottomPad)
    $view = @(Get-ViewList)
    $rowsPerTask = 1 + $RowGap
    $visibleTaskCount = [Math]::Max(1, [int]([Math]::Floor(($InnerHeight - $BottomPad) / $rowsPerTask)))
    $script:LastVisibleCount = $visibleTaskCount

    $selIdx = [array]::IndexOf($view, $script:SelectedTask)
    if ($selIdx -lt 0) { $selIdx = 0 }
    if ($selIdx -lt $script:ScrollOffset) { $script:ScrollOffset = $selIdx }
    elseif ($selIdx -ge $script:ScrollOffset + $visibleTaskCount) { $script:ScrollOffset = $selIdx - $visibleTaskCount + 1 }
    if ($script:ScrollOffset -lt 0) { $script:ScrollOffset = 0 }
    $maxOffset = [Math]::Max(0, $view.Count - $visibleTaskCount)
    if ($script:ScrollOffset -gt $maxOffset) { $script:ScrollOffset = $maxOffset }

    $mainRows = New-Object System.Collections.Generic.List[object]
    if ($view.Count -eq 0) {
        $mainRows.Add(@{ Segments = @(@{ Text = (Center-Text '*  No tasks yet  *' $Layout.MainWidth); Fg = $Palette.Muted; Bold = $true }) })
        $mainRows.Add(@{ Segments = @() })
        $mainRows.Add(@{ Segments = @(@{ Text = (Center-Text "press 'n' to add your first task" $Layout.MainWidth); Fg = $Palette.Muted }) })
    } else {
        for ($i = 0; $i -lt $visibleTaskCount; $i++) {
            $viewIdx = $script:ScrollOffset + $i
            if ($viewIdx -ge $view.Count) { $mainRows.Add(@{ Segments = @() }) }
            else {
                $task = $view[$viewIdx]
                $isSel = ($task -eq $script:SelectedTask)
                $isMulti = $script:MultiSelected.Contains($task)
                $mainRows.Add((Build-TaskRowSegments -Task $task -Width $Layout.MainWidth -Selected $isSel -Multi $isMulti -Palette $Palette -Number ($viewIdx + 1)))
            }
            for ($g = 0; $g -lt $RowGap; $g++) { $mainRows.Add(@{ Segments = @() }) }
        }
    }
    while ($mainRows.Count -lt $InnerHeight) { $mainRows.Add(@{ Segments = @() }) }
    if ($mainRows.Count -gt $InnerHeight) { $mainRows = [System.Collections.Generic.List[object]]($mainRows.GetRange(0, $InnerHeight)) }

    $filterRows = if ($Layout.FilterWidth -gt 0) { Build-FilterSidebarRows -Height $InnerHeight -Palette $Palette } else { $null }
    $detailRows = if ($Layout.DetailWidth -gt 0) { Build-DetailSidebarRows -Height $InnerHeight -Palette $Palette } else { $null }

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add((Get-BorderLine -Layout $Layout -Palette $Palette -Position 'top' -Width $Width))
    for ($i = 0; $i -lt $InnerHeight; $i++) {
        $line = (Complete-Row -Segments @(@{ Text = '|'; Fg = $Palette.Border }) -Width 1)
        if ($filterRows) {
            $line += (Complete-Row -Segments $filterRows[$i].Segments -Width $Layout.FilterWidth -BgTuple $filterRows[$i].Bg)
            $line += (Complete-Row -Segments @(@{ Text = '|'; Fg = $Palette.Border }) -Width 1)
        }
        $mr = $mainRows[$i]
        $line += (Complete-Row -Segments $mr.Segments -Width $Layout.MainWidth -BgTuple $mr.Bg)
        if ($detailRows) {
            $line += (Complete-Row -Segments @(@{ Text = '|'; Fg = $Palette.Border }) -Width 1)
            $line += (Complete-Row -Segments $detailRows[$i].Segments -Width $Layout.DetailWidth -BgTuple $detailRows[$i].Bg)
        }
        $line += (Complete-Row -Segments @(@{ Text = '|'; Fg = $Palette.Border }) -Width 1)
        $out.Add($line)
    }
    $out.Add((Get-BorderLine -Layout $Layout -Palette $Palette -Position 'bottom' -Width $Width))
    return $out
}

function Get-ArchiveLines {
    param([int]$Width, [int]$InnerHeight, $Palette)
    $view = @(Get-DoneView)
    $script:LastVisibleCount = $InnerHeight
    $selIdx = [array]::IndexOf($view, $script:SelectedDone)
    if ($selIdx -lt 0) { $selIdx = 0 }
    if ($selIdx -lt $script:ArchiveScrollOffset) { $script:ArchiveScrollOffset = $selIdx }
    elseif ($selIdx -ge $script:ArchiveScrollOffset + $InnerHeight) { $script:ArchiveScrollOffset = $selIdx - $InnerHeight + 1 }
    if ($script:ArchiveScrollOffset -lt 0) { $script:ArchiveScrollOffset = 0 }
    $maxOffset = [Math]::Max(0, $view.Count - $InnerHeight)
    if ($script:ArchiveScrollOffset -gt $maxOffset) { $script:ArchiveScrollOffset = $maxOffset }

    $fullWidth = $Width - 2
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add((Complete-Row -Segments @(@{ Text = ('┌' + ('─' * $fullWidth) + '┐'); Fg = $Palette.Border }) -Width $Width))
    for ($i = 0; $i -lt $InnerHeight; $i++) {
        $vIdx = $script:ArchiveScrollOffset + $i
        $segs = @()
        $bg = $null
        if ($view.Count -eq 0 -and $i -eq [int]($InnerHeight / 2)) {
            $segs = @(@{ Text = (Center-Text 'Archive is empty' $fullWidth); Fg = $Palette.Muted })
        } elseif ($vIdx -lt $view.Count) {
            $t = $view[$vIdx]
            $isSel = ($t -eq $script:SelectedDone)
            $line = "  [x] $($t.Description)  (done $($t.CompletionDate))"
            $segs = @(@{ Text = $line; Fg = $(if ($isSel) { $Palette.Text } else { $Palette.Muted }); Bold = $isSel })
            if ($isSel) { $bg = $Palette.Selection }
        }
        $inner = (Complete-Row -Segments $segs -Width $fullWidth -BgTuple $bg)
        $out.Add((Complete-Row -Segments @(@{ Text = '|'; Fg = $Palette.Border }) -Width 1) + $inner + (Complete-Row -Segments @(@{ Text = '|'; Fg = $Palette.Border }) -Width 1))
    }
    $out.Add((Complete-Row -Segments @(@{ Text = ('└' + ('─' * $fullWidth) + '┘'); Fg = $Palette.Border }) -Width $Width))
    return $out
}

function Get-OverlayLines {
    param([int]$Width, [int]$InnerHeight, $Palette, [string[]]$Content)
    $fullWidth = $Width - 2
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add((Complete-Row -Segments @(@{ Text = ('┌' + ('─' * $fullWidth) + '┐'); Fg = $Palette.Border }) -Width $Width))
    for ($i = 0; $i -lt $InnerHeight; $i++) {
        $text = if ($i -lt $Content.Count) { '  ' + $Content[$i] } else { '' }
        $inner = (Complete-Row -Segments @(@{ Text = $text; Fg = $Palette.Text }) -Width $fullWidth)
        $out.Add((Complete-Row -Segments @(@{ Text = '|'; Fg = $Palette.Border }) -Width 1) + $inner + (Complete-Row -Segments @(@{ Text = '|'; Fg = $Palette.Border }) -Width 1))
    }
    $out.Add((Complete-Row -Segments @(@{ Text = ('└' + ('─' * $fullWidth) + '┘'); Fg = $Palette.Border }) -Width $Width))
    return $out
}

function Get-StatusText {
    if ($script:StatusMessage -and (Get-Date) -lt $script:StatusExpire) { return " $($script:StatusMessage)" }
    $modeLabel = switch ($script:Mode) {
        'visual'  { 'VISUAL' }
        'archive' { 'ARCHIVE' }
        default   { 'NORMAL' }
    }
    $filters = @()
    if ($script:FilterProject) { $filters += "+$($script:FilterProject)" }
    if ($script:FilterContext) { $filters += "@$($script:FilterContext)" }
    if ($script:SearchQuery)   { $filters += "/$($script:SearchQuery)" }
    $filterText = if ($filters.Count -gt 0) { " . filter: $($filters -join ' ')" } else { '' }
    $chord = if ($script:PendingChord) { " . $($script:PendingChord)..." } else { '' }
    return " $modeLabel$filterText$chord  .  theme:$($script:Config.Theme)  .  density:$($script:Config.Density)  .  sort:$($script:Config.Sort)"
}

function Get-InputLine {
    param([int]$Width, $Palette)
    $prompt = switch ($script:Mode) {
        'add'        { "  add: $($script:InputBuffer)_" }
        'edit'       { "  edit: $($script:InputBuffer)_" }
        'search'     { "  search: $($script:InputBuffer)_" }
        'addproject' { "  project (+): $($script:InputBuffer)_" }
        'addcontext' { "  context (@): $($script:InputBuffer)_" }
        'setdue'     { "  due (fuzzy): $($script:InputBuffer)_   today / tmr / eow / sep 15 / 5pm / 17:00 / in 2 hours / clear" }
        'filterpick' { "  $($script:FilterPickerBy) filter -- j/k cycle, Esc clear, any key confirms" }
        default      { " >  ?: help   ,: settings   T: theme   D: density   q: quit" }
    }
    return (Complete-Row -Segments @(@{ Text = $prompt; Fg = $Palette.Muted }) -Width $Width)
}

function Render-Frame {
    $size = Get-ConsoleSize
    $width = $size[0]; $height = $size[1]
    $palette = $script:Themes[$script:Config.Theme]
    if (-not $palette) { $palette = $script:Themes['MutedSlate']; $script:Config.Theme = 'MutedSlate' }
    $script:ActiveBg = $palette.Background
    $lines = New-Object System.Collections.Generic.List[string]

    $showSubtitle = $script:Config.Density -ne 'compact'
    $bottomPad = switch ($script:Config.Density) { 'compact' { 0 } 'comfortable' { 1 } 'cozy' { 2 } default { 1 } }
    $rowGap = if ($script:Config.Density -eq 'cozy') { 1 } else { 0 }

    $layout = Get-Layout -TotalWidth $width

    $titleText = ' * POWERDO'
    $rightText = 'GLASTFIN EDITION '
    $padMiddle = $width - $titleText.Length - $rightText.Length
    if ($padMiddle -lt 0) { $padMiddle = 0 }
    $lines.Add((Complete-Row -Segments @(
        @{ Text = $titleText; Fg = $palette.Text; Bold = $true }
        @{ Text = (' ' * $padMiddle); Fg = $palette.Text }
        @{ Text = $rightText; Fg = $palette.Text; Bold = $true }
    ) -Width $width -BgTuple $palette.Accent))

    if ($showSubtitle) {
        $viewName = switch ($script:Mode) {
            'archive'  { 'Archive' }
            'help'     { 'Help' }
            'settings' { 'Settings' }
            default    { 'Task List' }
        }
        $total = $script:Tasks.Count
        $done = @($script:Tasks | Where-Object { $_.Completed }).Count
        $sub = "  crafted by GlaStFiN  .  $viewName  .  $done/$total done"
        $lines.Add((Complete-Row -Segments @(@{ Text = $sub; Fg = $palette.Muted }) -Width $width))
    }

    $bodyHeight = [Math]::Max(3, $height - $lines.Count - 2)
    $innerHeight = [Math]::Max(1, $bodyHeight - 2)

    if ($script:Mode -eq 'help') {
        $content = @(
            'NAVIGATION   j/k move . gg top . G bottom . Ctrl-d/u half page'
            'EDITING      n add . e/i edit . x complete . dd delete . p priority'
            'TAGS         c context . + project . u undo (50 levels)'
            'DUE          du fuzzy date prompt . dt today . dw +7 days . time: 5pm / 17:00 / in 2 hours . inline due:today 5pm'
            'FILTER/SORT  / search . fp filter project . fc filter context . S sort'
            'SELECTION    v visual mode . space select . x/dd bulk complete/delete'
            'VIEWS        l list . a archive (u un-archive, dd delete forever) . A archive done'
            'LAYOUT       [ filter sidebar . ] detail sidebar . L line numbers'
            'STYLE        T theme . D density'
            'SYSTEM       ? help . , settings . U uninstall . q quit'
            ''
            '-- PowerDo :: Glastfin Edition, crafted by GlaStFiN --'
            ''
            'press any key to return'
        )
        $lines.AddRange([string[]](Get-OverlayLines -Width $width -InnerHeight $innerHeight -Palette $palette -Content $content))
    } elseif ($script:Mode -eq 'settings') {
        $content = @(
            "Theme:            $($script:Config.Theme)   (press T to cycle)"
            "Density:          $($script:Config.Density)   (press D to cycle)"
            "Sort:             $($script:Config.Sort)   (press S to cycle)"
            "Line numbers:     $($script:Config.LineNumbers)   (press L to toggle)"
            "Show done tasks:  $($script:Config.ShowDone)   (press H to toggle)"
            "Uninstall:        press U to remove PowerDo from this computer"
            ''
            'Settings persist automatically to config.json.'
            ''
            '-- GlaStFiN --'
            ''
            'press any other key to return'
        )
        $lines.AddRange([string[]](Get-OverlayLines -Width $width -InnerHeight $innerHeight -Palette $palette -Content $content))
    } elseif ($script:Mode -eq 'confirmuninstall') {
        $content = @(
            'UNINSTALL PowerDo?'
            ''
            '  y   yes - remove PowerDo, keep your task data'
            '  d   yes - remove PowerDo AND delete task data'
            '  n   any other key - back to settings'
            ''
            'Removes the powerdo alias, PATH entry, desktop'
            'shortcut, Defender whitelist and program files.'
            ''
            '-- GlaStFiN --'
            ''
            'choose y, d or any other key'
        )
        $lines.AddRange([string[]](Get-OverlayLines -Width $width -InnerHeight $innerHeight -Palette $palette -Content $content))
    } elseif ($script:Mode -eq 'archive') {
        $lines.AddRange([string[]](Get-ArchiveLines -Width $width -InnerHeight $innerHeight -Palette $palette))
    } else {
        $lines.AddRange([string[]](Get-ListLines -Width $width -InnerHeight $innerHeight -Palette $palette -Layout $layout -RowGap $rowGap -BottomPad $bottomPad))
    }

    $lines.Add((Complete-Row -Segments @(@{ Text = (Get-StatusText); Fg = $palette.Text; Bold = $true }) -Width $width -BgTuple $palette.Selection))
    $lines.Add((Get-InputLine -Width $width -Palette $palette))

    while ($lines.Count -lt $height) { $lines.Add((' ' * $width)) }
    if ($lines.Count -gt $height) { $lines = [System.Collections.Generic.List[string]]($lines.GetRange(0, $height)) }

    $frame = ($lines -join "`r`n")
    if ($script:FrameSink) { $script:FrameSink = $lines; return }
    try {
        [Console]::SetCursorPosition(0, 0)
        [Console]::Out.Write($frame)
    } catch {
        try { Clear-Host } catch {}
        try { [Console]::Out.Write($frame) } catch { Write-Host $frame -NoNewline }
    }
}

# ============================================================================
#  UNINSTALL                                                        GlaStFiN
# ============================================================================
function Invoke-Uninstall {
    param([bool]$RemoveData)

    $dir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $installed = [System.IO.Path]::GetFileName($PSCommandPath) -ieq 'PowerDo.ps1'

    # remove profile alias block
    try {
        if ($PROFILE -and (Test-Path -LiteralPath $PROFILE)) {
            $c = Get-Content -LiteralPath $PROFILE -Raw
            if ($c -and $c -match '# >>> PowerDo >>>') {
                $c = [regex]::Replace($c, '(?s)\r?\n?# >>> PowerDo >>>.*?# <<< PowerDo <<<', '')
                Set-Content -LiteralPath $PROFILE -Value $c -Encoding utf8 -NoNewline
            }
        }
    } catch {}

    # remove install dir from user PATH
    try {
        $up = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($up -and (($up -split ';') | Where-Object { $_.TrimEnd('\') -ieq $dir.TrimEnd('\') })) {
            $np = (@($up -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ine $dir.TrimEnd('\') }) -join ';')
            [Environment]::SetEnvironmentVariable('Path', $np, 'User')
        }
    } catch {}

    # remove desktop shortcut
    try {
        $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'PowerDo.lnk'
        if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
    } catch {}

    # remove Defender whitelist
    try {
        $ex = (Get-MpPreference).ExclusionPath
        foreach ($p in @($dir, (Join-Path $env:LOCALAPPDATA 'PowerDo'))) {
            if ($ex -contains $p) { Remove-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue }
        }
    } catch {}

    # optional task data
    if ($RemoveData) {
        try {
            $dataDir = Join-Path $env:LOCALAPPDATA 'PowerDo'
            if (Test-Path -LiteralPath $dataDir) { Remove-Item -LiteralPath $dataDir -Recurse -Force }
        } catch {}
    }

    # program files we own (never touch other files; self deleted after exit)
    foreach ($f in 'PowerDo.ps1', 'powerdo.cmd', 'Uninstall-PowerDo.ps1') {
        $fp = Join-Path $dir $f
        if (($f -ieq 'PowerDo.ps1') -and $installed) { continue }
        if (Test-Path -LiteralPath $fp) {
            try { Remove-Item -LiteralPath $fp -Force -ErrorAction Stop } catch {}
        }
    }

    $script:UninstallPending = [pscustomobject]@{
        Dir     = $dir
        Self    = if ($installed) { $PSCommandPath } else { $null }
        HadData = $RemoveData
    }
}

# ============================================================================
#  MAIN                                                                GlaStFiN
# ============================================================================
try {
    try { $Host.UI.RawUI.WindowTitle = 'POWERDO :: Glastfin Edition -- GlaStFiN' } catch {}
    try { [Console]::CursorVisible = $false } catch {}

    Load-Config
    Import-LegacyTasksIfNeeded
    Load-Tasks
    Sync-Selection

    $failures = 0
    while ($script:Running) {
        try {
            Render-Frame
            $failures = 0
            $key = Wait-Key
            if ($null -ne $key) { Process-Key -Key $key }
        } catch {
            $failures++
            $msg = $_.Exception.Message
            if ($failures -ge 3) { throw "PowerDo cannot render: $msg" }
            try { Set-Status "Error: $msg" } catch {}
            Start-Sleep -Milliseconds 300
        }
    }
} finally {
    try { [Console]::CursorVisible = $true } catch {}
    try { $Host.UI.RawUI.WindowTitle = $script:OriginalTitle } catch {}
    try { Clear-Host } catch {}
    if ($script:UninstallPending) {
        $uDir = $script:UninstallPending.Dir
        $uSelf = $script:UninstallPending.Self
        Write-Host ''
        Write-Host '  +--------------------------------------------------------------+' -ForegroundColor DarkCyan
        Write-Host '  |  PowerDo uninstalled. Alias, PATH and files removed.         |' -ForegroundColor Green
        if ($script:UninstallPending.HadData) {
            Write-Host '  |  Task data was deleted.                                      |' -ForegroundColor Yellow
        } else {
            Write-Host '  |  Task data kept in %LOCALAPPDATA%\PowerDo                     |' -ForegroundColor Gray
        }
        Write-Host '  |    Glory to Mankind, GlaStFiN~                                |' -ForegroundColor DarkGray
        Write-Host '  +--------------------------------------------------------------+' -ForegroundColor DarkCyan
        Write-Host ''
        $leftover = $false
        if ($uSelf) {
            try { if (Test-Path -LiteralPath $uSelf) { Remove-Item -LiteralPath $uSelf -Force -ErrorAction Stop } } catch { $leftover = $true }
        }
        try { if (Test-Path -LiteralPath $uDir) { Remove-Item -LiteralPath $uDir -Force -ErrorAction Stop } } catch { $leftover = $true }
        if ($leftover) {
            # files are still locked - finish the job a moment after exit
            try {
                $lines = @(
                    '@echo off'
                    'ping -n 4 127.0.0.1 >nul'
                    $(if ($uSelf) { "del /f /q `"$uSelf`"" } else { 'rem no self file' })
                    "rd `"$uDir`""
                    'del /f /q "%~f0"'
                )
                $batch = Join-Path ([IO.Path]::GetTempPath()) "powerdo_cleanup_$PID.cmd"
                Set-Content -LiteralPath $batch -Value $lines -Encoding Ascii
                Start-Process -FilePath $batch -WindowStyle Hidden
            } catch {}
        }
    } else {
        Write-Host ''
        Write-Host '  +--------------------------------------------------------------+' -ForegroundColor DarkCyan
        Write-Host '  |  PowerDo session ended. Your tasks are saved.                 |' -ForegroundColor Green
        Write-Host '  |    Glory to Mankind, GlaStFiN~                                |' -ForegroundColor DarkGray
        Write-Host '  +--------------------------------------------------------------+' -ForegroundColor DarkCyan
        Write-Host ''
    }
}
