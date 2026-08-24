<#
.SYNOPSIS
    Check every layer of the macro-pad rig independently and report which ones
    are working.

.DESCRIPTION
    "The pad doesn't work" has at least six distinct causes across four layers.
    This isolates them so you fix the right thing.

    Compatible with Windows PowerShell 5.1 - no ternary, no ??, no && / ||.

.EXAMPLE
    .\Test-Setup.ps1
    .\Test-Setup.ps1 -Session claude -Prefix claude-
#>

[CmdletBinding()]
param(
    [string]$Session = 'claude',
    [string]$Prefix  = 'claude-'
)

$results = New-Object System.Collections.ArrayList

function Add-Result {
    param(
        [string]$Layer,
        [string]$Check,
        [ValidateSet('PASS', 'FAIL', 'WARN', 'INFO')]
        [string]$State,
        [string]$Detail
    )
    [void]$results.Add([pscustomobject]@{
        Layer = $Layer; Check = $Check; State = $State; Detail = $Detail
    })
}

function Get-DeviceConfigPath {
    <#
        Where this device's registry lives. Mirrors Get-ZtConfigHome and
        Get-ZtDevicePath in module\ZellijTerminal\Private\Core.ps1 - this script
        runs without importing the module on purpose, because the hook and the
        pad call it and neither can pay for a module load.

        It is a third implementation of one rule, so it is written once here
        rather than three times inline. The three copies it replaces all still
        pointed at <clone>\config\devices\ after the registry moved out of the
        working tree, which made `zt check` report "no device registry" on a
        machine that had one.
    #>
    $home_ = $env:ZT_CONFIG_HOME
    if (-not $home_) {
        $base = $env:LOCALAPPDATA
        if (-not $base) { $base = $env:TEMP }
        $home_ = Join-Path $base 'ZellijTerminal'
    }

    $device = $env:ZT_DEVICE
    if (-not $device) { $device = $env:COMPUTERNAME }

    return (Join-Path $home_ (Join-Path 'devices' ($device + '.json')))
}

# Tabs the layout opens that are not workspaces. Same list as $ZtLayoutTabs in
# module\ZellijTerminal\Private\Core.ps1 and the same reason: since 0.7.20 there
# is no prefix to recognise a project tab by, so the honest test is to exclude
# the one tab we know is not one and ask the registry about the rest.
$ZtLayoutTabs = @('home')

function Get-TabIdentity {
    <#
        Strip the activity glyph the hook appends, then a legacy `claude-`
        prefix, leaving the string the registry can be compared against. Both
        halves come off - this is the same reduction as Get-ZtTabBase followed
        by Get-ZtSessionName, and `zt check` needs its own copy for the same
        reason Get-DeviceConfigPath has one.
    #>
    param([string]$Name)
    if (-not $Name) { return $Name }
    $b = ($Name -replace ' [v!?*>~#@&+.]$', '')
    if ($Prefix -and $b.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
        $s = $b.Substring($Prefix.Length)
        if ($s) { return $s }
    }
    return $b
}

function Get-RegisteredTabBases {
    <#
        Which tabs are projects, according to this device's registry. Mirrors
        Get-ZtRegisteredTabBases in scripts\zj-claude-tab.ps1, including its
        precedence: an explicit name wins, then the leaf of rel, then of abs,
        then the id. An explicit name is reduced too, because a registry written
        before 0.7.22 can hold `claude-<leaf>` there.

        An unreadable registry returns nothing, and the caller falls back rather
        than reporting an empty session. Failing open is the right failure here:
        this is a diagnostic, and a diagnostic that lies about a healthy machine
        is the thing this whole file exists to avoid.
    #>
    $out  = @()
    $file = Get-DeviceConfigPath
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    try { $d = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json } catch { return @() }
    if (-not $d) { return @() }
    if ($d.PSObject.Properties.Name -notcontains 'workspaces') { return @() }

    foreach ($w in @($d.workspaces)) {
        if (-not $w) { continue }
        $n = $null
        if ($w.PSObject.Properties.Name -contains 'name' -and $w.name) { $n = Get-TabIdentity "$($w.name)" }
        if (-not $n -and $w.PSObject.Properties.Name -contains 'rel' -and $w.rel) { $n = Split-Path "$($w.rel)" -Leaf }
        if (-not $n -and $w.PSObject.Properties.Name -contains 'abs' -and $w.abs) { $n = Split-Path "$($w.abs)" -Leaf }
        if (-not $n -and $w.PSObject.Properties.Name -contains 'id'  -and $w.id ) { $n = "$($w.id)" }
        if ($n) { $out += $n }
    }
    return @($out | Sort-Object -Unique)
}

Write-Host ''
Write-Host '  Macro pad rig - layer check' -ForegroundColor Cyan
Write-Host '  ---------------------------' -ForegroundColor Cyan
Write-Host ''

# ===========================================================================
#  LAYER 1 - device
# ===========================================================================
# Presence and health are separate questions, and conflating them gives a false
# FAIL: Get-PnpDevice reports Status 'Unknown' for every device when the shell
# is not elevated, so filtering on Status -eq 'OK' finds nothing on a perfectly
# healthy pad. Test presence first, then report status as its own line.
# Which pad is a SETTING, not a constant - anything emitting Ctrl+Shift+F13..F16
# works, so a hard-coded USB id would report a missing device to everyone whose
# pad is not the one this was built against. Read it from the device config.
$padId = $null
try {
    $devCfgPath = Get-DeviceConfigPath
    if (Test-Path -LiteralPath $devCfgPath) {
        $devCfg = Get-Content -LiteralPath $devCfgPath -Raw | ConvertFrom-Json
        if ($devCfg.PSObject.Properties.Name -contains 'pad' -and $devCfg.pad) {
            if ($devCfg.pad.PSObject.Properties.Name -contains 'deviceId') { $padId = $devCfg.pad.deviceId }
        }
    }
} catch { }

$pad = @()
if ($padId) { $pad = @(Get-PnpDevice -InstanceId $padId -ErrorAction SilentlyContinue) }
$padOk  = @($pad | Where-Object { $_.Status -eq 'OK' })
$padBad = @($pad | Where-Object { $_.Status -eq 'Error' })

if ($pad.Count -eq 0) {
    if (-not $padId) { Add-Result '1 device' 'Pad device' 'INFO' 'None configured - optional. Set one with: zt pad device <instance-id>' }
    else { Add-Result '1 device' 'Pad device' 'FAIL' "$padId not found - unplugged?" }
} else {
    Add-Result '1 device' 'Pad device' 'PASS' "$($pad.Count) interface(s)"

    if ($padBad.Count -gt 0) {
        Add-Result '1 device' 'Pad device healthy' 'FAIL' "$($padBad.Count) interface(s) in an error state - check Device Manager"
    } elseif ($padOk.Count -gt 0) {
        Add-Result '1 device' 'Pad device healthy' 'PASS' "$($padOk.Count) interface(s) reporting OK"
    } else {
        Add-Result '1 device' 'Pad device healthy' 'INFO' 'Status unavailable - run elevated to read it (not a fault)'
    }
}

Add-Result '1 device' 'Chords emitted' 'INFO' 'Verify manually at keyboardtester.com: expect Ctrl+Shift+F13..F16'

# ===========================================================================
#  LAYER 2 - listener
# ===========================================================================
$ahk = Get-Process -Name 'AutoHotkey*' -ErrorAction SilentlyContinue
if ($ahk) {
    Add-Result '2 listener' 'AutoHotkey running' 'PASS' "PID $($ahk[0].Id)"
} else {
    Add-Result '2 listener' 'AutoHotkey running' 'INFO' 'Not running (fine if using PowerToys)'
}

$pt = Get-Process -Name 'PowerToys*' -ErrorAction SilentlyContinue
if ($pt) {
    Add-Result '2 listener' 'PowerToys running' 'PASS' 'Process is up'
} else {
    Add-Result '2 listener' 'PowerToys running' 'INFO' 'Not running (fine if using AutoHotkey)'
}

# PowerToys being *running* says nothing about whether the pad is bound to
# anything. Read the mappings: an empty remapShortcuts list means the chords go
# nowhere, which looks identical to a broken rig from the user's side.
$ptCfg = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\Keyboard Manager\default.json'
if (Test-Path -LiteralPath $ptCfg) {
    try {
        $km = Get-Content -LiteralPath $ptCfg -Raw | ConvertFrom-Json
        $shortcuts = @()
        if ($km.PSObject.Properties.Name -contains 'remapShortcuts') {
            if ($km.remapShortcuts.PSObject.Properties.Name -contains 'global') {
                $shortcuts = @($km.remapShortcuts.global)
            }
        }
        if ($shortcuts.Count -gt 0) {
            Add-Result '2 listener' 'Pad chords mapped' 'PASS' "$($shortcuts.Count) shortcut remap(s) configured"
        } else {
            Add-Result '2 listener' 'Pad chords mapped' 'WARN' 'PowerToys has NO shortcut remaps - the pad keys do nothing. See pad/powertoys-setup.md'
        }
    } catch {
        Add-Result '2 listener' 'Pad chords mapped' 'WARN' "Could not read $ptCfg"
    }
} elseif ($pt) {
    Add-Result '2 listener' 'Pad chords mapped' 'WARN' 'Keyboard Manager config absent - enable it in PowerToys settings'
}

if (-not $ahk -and -not $pt) {
    Add-Result '2 listener' 'A listener is active' 'FAIL' 'Neither AutoHotkey nor PowerToys is running - nothing will hear the pad'
}

if ($ahk -and $pt) {
    Add-Result '2 listener' 'Only one listener' 'WARN' 'Both running - chords may double-fire'
}

# ===========================================================================
#  LAYER 3 - transport
# ===========================================================================
$zellij = Get-Command zellij -ErrorAction SilentlyContinue
if ($zellij) {
    Add-Result '3 transport' 'zellij on PATH' 'PASS' $zellij.Source
} else {
    Add-Result '3 transport' 'zellij on PATH' 'FAIL' 'Not resolvable. If you just installed it, restart this terminal'
}

if ($zellij) {
    $sessions = & zellij list-sessions 2>&1 | Out-String
    if ($sessions -match [regex]::Escape($Session)) {
        Add-Result '3 transport' "Session '$Session'" 'PASS' 'Present'
    } else {
        Add-Result '3 transport' "Session '$Session'" 'FAIL' "Start it: zellij attach --create $Session"
    }

    # RESURRECTABLE SESSIONS ARE WHY A REPAIR APPEARS NOT TO WORK.
    # `session_serialization true` is set deliberately in config.kdl, so a
    # session that exits stays in the list and `attach --create` RESURRECTS it
    # from its serialized state rather than building a new one from the layout.
    # A layout rewritten since, or a plugin permission granted since, is
    # therefore never read - and reinstalling changes nothing, however many
    # times you do it.
    #
    # That cost most of a night on a second machine: the grant was correct on
    # disk and every session started was a corpse that could not see it. The
    # fix is delete-session, not kill-session, and nothing in this rig said so.
    $exited = @($sessions -split "`r?`n" | Where-Object { $_ -match 'EXITED' })
    if ($exited.Count -gt 0) {
        Add-Result '3 transport' 'Resurrectable sessions' 'WARN' (
            "$($exited.Count) exited session(s) still listed. ``attach --create`` resurrects one " +
            'rather than reading the layout, so config and plugin-permission changes are ignored. ' +
            'Clear with: zellij delete-session <name> --force')
    } else {
        Add-Result '3 transport' 'Resurrectable sessions' 'PASS' 'None - a new session will be built from the layout'
    }

    $tabs = @(
        & zellij --session $Session action query-tab-names 2>$null |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    )
    if ($tabs.Count -gt 0) {
        Add-Result '3 transport' 'query-tab-names' 'PASS' ($tabs -join ', ')

        # Having no project tab used to be a FAIL, from when the layout opened
        # one on startup and its absence meant something had gone wrong. The
        # layout now starts with only `home`, so an empty session is the normal
        # cold start - and a check that cries wolf on a healthy rig is worse
        # than no check, because it trains you to read past the failure line.
        #
        # Still worth reporting, because "I typed zt start and nothing appeared"
        # needs to be distinguishable from "I have not started anything yet",
        # so the two empty cases say different things. A tab that is genuinely
        # missing behind a record that claims to be running shows up as `stale`
        # in `zt` and is cleared with `zt sync`; that is the check for it.
        #
        # COUNTED FROM THE REGISTRY SINCE 0.7.22, the way zj-claude-tab.ps1 does
        # it. This asked `-like "$Prefix*"` of names that stopped carrying the
        # prefix in 0.7.20, so the two rows contradicted each other in the same
        # output - query-tab-names PASS listing four project tabs, immediately
        # below "None open - 33 registered". The check that exists to tell "I
        # typed zt start and nothing appeared" from "I have not started anything
        # yet" always reported the second, and the whole run still said no
        # failures.
        $registered = @(Get-RegisteredTabBases)
        $bases      = @{}
        foreach ($t in $tabs) { $bases[$t] = (Get-TabIdentity $t) }

        $matching = @($tabs | Where-Object {
            $b = $bases[$_]
            $b -and ($ZtLayoutTabs -notcontains $_) -and
            (($registered.Count -eq 0) -or ($registered -contains $b))
        })

        # An unreadable or empty registry falls back to counting every tab that
        # is not the layout's own, for the reason zj-claude-tab.ps1 falls back:
        # reporting "nothing open" over a session full of tabs is worse than
        # over-counting by one.
        $how = if ($registered.Count -gt 0) { 'registered' } else { 'non-layout, registry unreadable' }

        if ($matching.Count -gt 0) {
            Add-Result '3 transport' 'Project tabs' 'PASS' "$($matching.Count) ${how}: $($matching -join ', ')"
        } elseif ($registered.Count -gt 0) {
            Add-Result '3 transport' 'Project tabs' 'INFO' "None open - $($registered.Count) registered. Open one: zt start <id>"
        } else {
            Add-Result '3 transport' 'Project tabs' 'INFO' 'None open, none registered yet. Register a folder: zt add <path>'
        }
    } else {
        Add-Result '3 transport' 'query-tab-names' 'FAIL' 'No output - session not reachable'
    }

    # Check the EXIT CODE, not just whether anything came back. Called from
    # outside the session this prints "No active tab found for current client"
    # on stderr and exits 2 - non-empty output that means the opposite of
    # success. Testing output alone reports a false PASS.
    $info = (& zellij --session $Session action current-tab-info 2>&1) -join ' '
    if ($LASTEXITCODE -eq 0 -and $info) {
        Add-Result '3 transport' 'current-tab-info' 'PASS' $info.Substring(0, [Math]::Min(60, $info.Length))
    } elseif ($info -match 'No active tab') {
        Add-Result '3 transport' 'current-tab-info' 'INFO' 'Only works from inside the session - scripts fall back to a state file'
    } else {
        Add-Result '3 transport' 'current-tab-info' 'WARN' 'Unavailable - scripts fall back to a state file'
    }

    # A CLIENT MUST BE ATTACHED. With the session detached, write / write-chars
    # / go-to-tab-name / close-tab all no-op silently AND STILL EXIT 0, so exit
    # codes prove nothing here. Check for a client first - an empty
    # list-clients table is the whole diagnosis when "the pad does nothing".
    $clients = (& zellij --session $Session action list-clients 2>&1) -join "`n"
    $clientRows = @([regex]::Matches($clients, '(?m)^\d+\s'))
    if ($clientRows.Count -eq 1) {
        Add-Result '3 transport' 'Client attached' 'PASS' 'A terminal is attached - injection can land'
    } elseif ($clientRows.Count -gt 1) {
        # Zellij MIRRORS: every client shows the same session and every
        # keystroke lands in all of them. Two windows that look identical are
        # not two sessions, and each client carries its own focus, so `write`
        # can land somewhere you are not looking. Detach the spare with Ctrl+O d
        # or just close its window.
        #
        # Say the resize symptom out loud, because it does not look like this
        # at all: the grid is sized to the SMALLEST attached client, so widening
        # one window changes nothing and the text never reflows. That reads as
        # "zellij cannot reflow", which is a dead end - it reflows fine as soon
        # as one client is left.
        Add-Result '3 transport' 'Client attached' 'WARN' "$($clientRows.Count) clients attached - mirrored: input lands in all of them, and the grid is pinned to the smallest, so resize and reflow do nothing"
    } else {
        Add-Result '3 transport' 'Client attached' 'FAIL' "No client attached. Open a terminal on it: zellij attach $Session"
    }

    # A cold `zt attach` - no Terminal window open at all - opens TWO windows on
    # one session when Terminal is set to restore its layout: the saved layout
    # is a window already running `zellij attach`, and the command line is
    # honoured on top of it. Nothing in this rig can tell the two apart
    # afterwards, so the only place to catch it is the setting. Read the file as
    # text: Terminal's settings.json is JSONC and ConvertFrom-Json refuses it
    # under Windows PowerShell.
    # @() OUTSIDE the pipeline, not around the list: a one-element pipeline
    # result is a bare string, and [0] on a string is its first CHARACTER - the
    # check then reads a path called "C", finds nothing, and reports PASS.
    # Mirrors Get-ZtWtWindowPreference in the module, which this cannot import
    # because it has to run under 5.1. tests/Attach.Tests.ps1 pins the two.
    # The unpackaged path matters: a Scoop or portable Terminal keeps its
    # settings there and nowhere else, and without it this check reported
    # "not found - skipped" on exactly the installs it was written for.
    $wtSettings = @(
        @(
            (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
            (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
        ) | Where-Object { Test-Path -LiteralPath $_ }
    )
    if ($wtSettings.Count -gt 0) {
        $wtText = Get-Content -LiteralPath $wtSettings[0] -Raw -ErrorAction SilentlyContinue
        if (-not $wtText) { $wtText = '' }
        # Drop full-line comments first. Terminal writes its own defaults out
        # commented, so a commented-out persistedWindowLayout would otherwise
        # raise a warning about a setting the user does not have.
        $wtLive = ($wtText -split "`r?`n" | Where-Object { $_.TrimStart() -notlike '//*' }) -join "`n"
        $pref   = [regex]::Match($wtLive, '"firstWindowPreference"\s*:\s*"([^"]+)"')
        if ($pref.Success -and $pref.Groups[1].Value -eq 'persistedWindowLayout') {
            Add-Result '3 transport' 'Terminal window restore' 'WARN' 'firstWindowPreference is persistedWindowLayout - a cold attach opens a duplicate mirrored window. Set it to defaultProfile'
        } else {
            Add-Result '3 transport' 'Terminal window restore' 'PASS' 'Terminal will not restore a second window over the attach'
        }
    } else {
        Add-Result '3 transport' 'Terminal window restore' 'INFO' 'Terminal settings.json not found - skipped'
    }

    # Focus-free injection is the load-bearing assumption. Writing 0
    # bytes is a no-op, so nothing is typed into whatever is focused.
    & zellij --session $Session action write-chars '' 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Add-Result '3 transport' 'Injection reachable' 'PASS' 'action write-chars accepted (see Client attached)'
    } else {
        Add-Result '3 transport' 'Injection reachable' 'FAIL' 'Cannot write to session - the pad cannot answer prompts'
    }
}

# ===========================================================================
#  LAYER 4 - hooks and feedback
# ===========================================================================
$flagDir = Join-Path $env:TEMP 'claude-zellij-flags'
if (Test-Path -LiteralPath $flagDir) {
    $flags = @(Get-ChildItem -LiteralPath $flagDir -Filter '*.json' -ErrorAction SilentlyContinue)
    if ($flags.Count -gt 0) {
        Add-Result '4 hooks' 'Waiting flags' 'PASS' (($flags | ForEach-Object { $_.BaseName }) -join ', ')
    } else {
        Add-Result '4 hooks' 'Waiting flags' 'INFO' 'Directory exists, nothing waiting right now'
    }
} else {
    Add-Result '4 hooks' 'Waiting flags' 'WARN' 'Directory absent - hook has never fired'
}

$statusDir = Join-Path $env:TEMP 'claude-zellij-status'
if (Test-Path -LiteralPath $statusDir) {
    Add-Result '4 hooks' 'Status state' 'PASS' $statusDir
} else {
    Add-Result '4 hooks' 'Status state' 'WARN' 'Directory absent - hook has never fired'
}

# Registration can be global OR project-scoped; either is valid. Check both,
# and report which one is actually in play.
$settingsPaths = @(
    (Join-Path $env:USERPROFILE '.claude\settings.json'),
    (Join-Path $PSScriptRoot '..\.claude\settings.json')
)
$registeredIn = @()
foreach ($s in $settingsPaths) {
    if (Test-Path -LiteralPath $s) {
        $raw = Get-Content -LiteralPath $s -Raw
        if ($raw -match 'claude-zj-hook') { $registeredIn += (Resolve-Path $s).Path }
    }
}
if ($registeredIn.Count -gt 0) {
    Add-Result '4 hooks' 'Hook registered' 'PASS' ($registeredIn -join ' ; ')
} else {
    Add-Result '4 hooks' 'Hook registered' 'FAIL' 'No claude-zj-hook entry in user or project settings.json'
}

# A registration is not the same as a WORKING registration. The path is stamped
# in at install time, so moving the clone, re-cloning somewhere else, or
# deleting an old one leaves an entry pointing at a script that is not there -
# and a hook whose file is missing fails per event, in the background, where
# nobody is looking. The visible symptom is a tab glyph that never changes,
# which reads as a zellij problem rather than a stale path.
$stalePaths = @()
foreach ($s in $registeredIn) {
    $raw = Get-Content -LiteralPath $s -Raw
    foreach ($m in ([regex]::Matches($raw, '"([^"]*claude-zj-hook[^"]*)"'))) {
        $p = $m.Groups[1].Value
        if (-not (Test-Path -LiteralPath $p)) { $stalePaths += $p }
    }
}
$stalePaths = @($stalePaths | Sort-Object -Unique)
if ($stalePaths.Count -gt 0) {
    Add-Result '4 hooks' 'Hook path exists' 'FAIL' (
        'registered hook script is not there: ' + ($stalePaths -join ' ; ') +
        ' - re-run install.ps1 -Global from the clone you are actually using')
} elseif ($registeredIn.Count -gt 0) {
    Add-Result '4 hooks' 'Hook path exists' 'PASS' 'every registered hook path resolves to a file'
}

# PreToolUse/PostToolUse cost ~956 ms per tool call, measured. Warn loudly.
foreach ($s in $registeredIn) {
    $raw = Get-Content -LiteralPath $s -Raw
    if ($raw -match '"(Pre|Post)ToolUse"') {
        Add-Result '4 hooks' 'Per-tool hooks off' 'WARN' "Pre/PostToolUse registered in $s - adds ~956 ms per tool call"
    }
}

# The hook must actually run under Windows PowerShell 5.1, not just exist.
$hookScript = Join-Path $PSScriptRoot '..\hooks\claude-zj-hook.ps1'
if (Test-Path -LiteralPath $hookScript) {
    $probe = Join-Path $env:TEMP ('zjhookprobe-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $probe -Force | Out-Null
    $inFile = Join-Path $probe 'in.json'
    '{"hook_event_name":"Stop","cwd":"C:/code/probe"}' |
        Set-Content -LiteralPath $inFile -Encoding UTF8 -NoNewline
    # Redirect the child's TEMP by setting it HERE and letting the child inherit
    # it, rather than with Start-Process -Environment.
    #
    # -Environment reads better and does not exist where it matters: it arrived
    # in PowerShell 7.4, and the header of this file promises 5.1 - which is the
    # shell this very probe exists to test the hook under. Run under 5.1 the
    # parameter is not found, the whole probe throws, and the catch below
    # reports "Hook script runs FAIL" with a binding error. So the check that
    # exists to prove the hook works on 5.1 was the one thing guaranteed to fail
    # there. Verified: (Get-Command Start-Process).Parameters.ContainsKey(
    # 'Environment') is False on 5.1.26100 and True on 7.6.4.
    $savedTemp = $env:TEMP
    $savedTmp  = $env:TMP
    try {
        $env:TEMP = $probe
        $env:TMP  = $probe
        $p = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$hookScript `
            -RedirectStandardInput $inFile `
            -RedirectStandardOutput (Join-Path $probe 'out.txt') `
            -RedirectStandardError  (Join-Path $probe 'err.txt') `
            -NoNewWindow -PassThru
        $p.WaitForExit()
        # A FLAG FILE IS NAMED FOR THE TAB, and the tab lost its `claude-`
        # prefix in 0.7.20 - so this looked for `claude-probe.json` and the hook
        # correctly wrote `probe.json`. It read as the hook being broken, which
        # is exactly the wrong conclusion and exactly what this row exists to
        # avoid. Both spellings are accepted: a machine still running an older
        # hook has to pass this too.
        $flagDir = Join-Path $probe 'claude-zellij-flags'
        $wrote = (Test-Path (Join-Path $flagDir 'probe.json')) -or
                 (Test-Path (Join-Path $flagDir 'claude-probe.json'))
        if ($p.ExitCode -eq 0 -and $wrote) {
            Add-Result '4 hooks' 'Hook script runs' 'PASS' 'Stop payload wrote a flag under powershell.exe'
        } elseif ($p.ExitCode -eq 0) {
            Add-Result '4 hooks' 'Hook script runs' 'FAIL' 'Exits 0 but wrote no flag - check the Prefix and cwd handling'
        } else {
            $e = (Get-Content (Join-Path $probe 'err.txt') -Raw -ErrorAction SilentlyContinue)
            Add-Result '4 hooks' 'Hook script runs' 'FAIL' ("Exit $($p.ExitCode). " + ($e -replace '\s+',' '))
        }
    } catch {
        Add-Result '4 hooks' 'Hook script runs' 'FAIL' $_.Exception.Message
    } finally {
        $env:TEMP = $savedTemp
        $env:TMP  = $savedTmp
        Remove-Item $probe -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Add-Result '4 hooks' 'Hook script runs' 'FAIL' "Not found at $hookScript"
}

# The hook now records its own failures, because it is the one component whose
# failures are invisible by construction: it runs detached under powershell.exe
# with output going nowhere, so a malformed payload used to mean it quietly did
# nothing and every symptom pointed elsewhere. Surfacing the log HERE is the
# other half of that fix - a log nobody reads is only marginally better than no
# log, and this is the place people already look when the rig misbehaves.
$hookLog = Join-Path $env:TEMP 'claude-zellij-hook.log'
if (Test-Path -LiteralPath $hookLog) {
    $lines = @(Get-Content -LiteralPath $hookLog -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) {
        Add-Result '4 hooks' 'Hook errors' 'PASS' 'Log present, empty - the hook has not failed'
    } else {
        $last = $lines[-1]
        Add-Result '4 hooks' 'Hook errors' 'WARN' (
            "$($lines.Count) logged. Most recent: $($last -replace '\s+', ' '). Full log: $hookLog")
    }
} else {
    Add-Result '4 hooks' 'Hook errors' 'PASS' 'No log written - the hook has never failed'
}

# ===========================================================================
#  ENVIRONMENT
# ===========================================================================
Add-Result 'env' 'PowerShell' 'INFO' $PSVersionTable.PSVersion.ToString()

# The ZellijTerminal module (zt) is the front door for typing commands. It is a
# convenience, never a dependency: the macro pad and the hook call the scripts
# directly and do not care whether it is installed. So a missing module is INFO,
# not a failure.
#
# What IS worth catching is a junction pointing at a different clone, because
# then `zt` drives one repo while you are looking at another.
$czModule = @(Get-Module -ListAvailable ZellijTerminal)
if ($czModule.Count -eq 0) {
    Add-Result 'env' 'ZellijTerminal (zt)' 'INFO' 'Not installed - run .\install.ps1 to type commands instead of script paths'
} else {
    # The install is a junction, and Windows resolves paths by string, so the
    # module reports the junction's own path. Follow the reparse point or this
    # check warns about a correct install. PowerShell 7 exposes LinkTarget,
    # 5.1 exposes Target as an array; this script has to run under both.
    $czBase = Split-Path $czModule[0].Path -Parent
    $czReal = $czBase
    $czItem = Get-Item -LiteralPath $czBase -Force -ErrorAction SilentlyContinue
    if ($czItem -and ($czItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        $czProps = $czItem.PSObject.Properties.Name
        if (($czProps -contains 'LinkTarget') -and $czItem.LinkTarget) {
            $czReal = $czItem.LinkTarget
        } elseif (($czProps -contains 'Target') -and $czItem.Target) {
            $czReal = @($czItem.Target)[0]
        }
    }

    $expect = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\module\ZellijTerminal')).Path
    if ($czReal.TrimEnd('\') -eq $expect.TrimEnd('\')) {
        Add-Result 'env' 'ZellijTerminal (zt)' 'PASS' "$($czModule[0].Version) -> this repo"
    } else {
        Add-Result 'env' 'ZellijTerminal (zt)' 'WARN' "$($czModule[0].Version) resolves to $czReal, not $expect"
    }

    # The device config is what makes the registry work on several PCs. Its
    # absence is not a fault - the first `zt add` creates it - but knowing which
    # device file is in play saves a confusing hour when two machines disagree.
    $devPath = Get-DeviceConfigPath
    if (Test-Path -LiteralPath $devPath) {
        $devCount = 0
        try {
            $dev = Get-Content -LiteralPath $devPath -Raw | ConvertFrom-Json
            if ($dev.PSObject.Properties.Name -contains 'workspaces') { $devCount = @($dev.workspaces).Count }
        } catch { }
        # Say WHERE, not just how many. The registry can be relocated with
        # ZT_CONFIG_HOME, and "which file am I actually reading" is the first
        # question when two machines, or a clone and an install, disagree.
        Add-Result 'env' 'Device registry' 'PASS' "$devCount workspace(s) - $devPath"
    } else {
        Add-Result 'env' 'Device registry' 'INFO' "No config for $env:COMPUTERNAME yet - created by the first 'zt add'"
    }
}

# Note the `config` level - verified against 0.44.3. The old path here was
# missing it, so this check passed while reading nothing.
$zjCfg = Join-Path $env:APPDATA 'Zellij\config\config.kdl'
if (Test-Path -LiteralPath $zjCfg) {
    Add-Result 'env' 'Zellij config' 'PASS' $zjCfg

    # Deployed config drifting from the repo copy is a silent, confusing
    # failure - it looks like Zellij ignoring settings that were never applied.
    $repoCfg = Join-Path $PSScriptRoot '..\zellij\config.kdl'
    if (Test-Path -LiteralPath $repoCfg) {
        $a = (Get-Content -LiteralPath $zjCfg   -Raw) -replace '\s',''
        $b = (Get-Content -LiteralPath $repoCfg -Raw) -replace '\s',''
        if ($a -eq $b) {
            Add-Result 'env' 'Config matches repo' 'PASS' 'Deployed copy is current'
        } else {
            Add-Result 'env' 'Config matches repo' 'WARN' "Differs from zellij\config.kdl - copy it to $zjCfg"
        }
    }
} else {
    Add-Result 'env' 'Zellij config' 'WARN' "Not at $zjCfg - run: zellij setup --check"
}

$zjLayout = Join-Path $env:APPDATA 'Zellij\config\layouts\claude.kdl'
if (Test-Path -LiteralPath $zjLayout) {
    Add-Result 'env' 'Claude layout' 'PASS' $zjLayout

    # If the layout references zjstatus, the plugin must actually be there or
    # the session starts with no status bar and no explanation.
    $layoutRaw = Get-Content -LiteralPath $zjLayout -Raw
    if ($layoutRaw -match 'zjstatus') {
        # THE DEPLOYED LAYOUT IS A COPY, and a copy can be older than the
        # template it came from. This particular line going missing does not
        # look like a stale deployment - it looks like the tab bar breaking.
        #
        # A bar over its width budget is not wrapped and not truncated: the
        # chunk that does not fit is dropped WHOLE. So an over-long tab list
        # does not shorten, it vanishes - every name at once, while the mode
        # indicator and the activity codes carry on painting. A window bounds
        # what the tab list can ask for. See docs/03-troubleshooting.md B8.
        $window = [regex]::Match($layoutRaw, '(?m)^\s*tab_display_count\s+"(\d+)"')
        if ($window.Success) {
            Add-Result '4 hooks' 'Tab names protected' 'PASS' (
                "Tab list is windowed to $($window.Groups[1].Value), so it cannot be dropped for being too wide")
        } else {
            Add-Result '4 hooks' 'Tab names protected' 'WARN' (
                'Deployed layout has no tab_display_count - once the tab list is wider than ' +
                'the bar, EVERY tab name disappears at once and only the activity codes are ' +
                'left. Fix: re-run install.ps1, then close every session with delete-session ' +
                '(a resurrected one keeps the old bar)')
        }

        # 0.7.17 shipped this believing it kept the tab names; rendered with and
        # without it the painted output was identical, and on a long tab list it
        # was worse - it dropped the activity codes too and gave back no names.
        if ($layoutRaw -match '(?m)^\s*format_hide_on_overlength\s+"true"') {
            Add-Result '4 hooks' 'Overlength guard' 'WARN' (
                'Deployed layout still sets format_hide_on_overlength. It does not protect ' +
                'the tab names - measured identical with and without - and it costs you the ' +
                'activity codes when the tab list is long. Fix: re-run install.ps1')
        }

        $wasm = Join-Path $env:APPDATA 'Zellij\data\plugins\zjstatus.wasm'
        if (Test-Path -LiteralPath $wasm) {
            $kb = [int]((Get-Item -LiteralPath $wasm).Length / 1KB)
            Add-Result '4 hooks' 'zjstatus plugin' 'PASS' "$wasm ($kb KB)"
        } else {
            Add-Result '4 hooks' 'zjstatus plugin' 'FAIL' "Layout references zjstatus but $wasm is missing"
        }

        # A PLUGIN THAT IS PRESENT IS NOT A PLUGIN THAT MAY RUN. Zellij holds
        # an ungranted plugin pending approval. The prompt renders - a single
        # line across the top row, "Allow? (y/n)" - but the session starts in
        # locked mode with focus in the terminal pane, so the keypress never
        # reaches the plugin and it sits unanswered. It reads as a banner
        # rather than a question. The bar is absent, and nothing is logged.
        #
        # This check exists because every other line in this table passed on a
        # machine with no status bar. The grant is acquired interactively and
        # cached outside both the clone and %APPDATA%, so every development
        # machine had one and nothing that ships did - the exact shape of
        # failure a layer check is supposed to catch and could not.
        #
        # Mirrors install.ps1, which writes it. tests/Permissions.Tests.ps1
        # pins the two together, because a check reading a different path from
        # the writer reports a missing grant on a machine that has one.
        $permPath = Join-Path $env:LOCALAPPDATA 'Zellij\cache\permissions.kdl'
        $permKey  = $wasm -replace '\\', '/'
        if (Test-Path -LiteralPath $permPath) {
            $permText = Get-Content -LiteralPath $permPath -Raw -ErrorAction SilentlyContinue
            if (-not $permText) { $permText = '' }
            if ($permText -match [regex]::Escape($permKey)) {
                Add-Result '4 hooks' 'zjstatus permitted' 'PASS' 'Zellij has a plugin permission grant for it'
            } else {
                Add-Result '4 hooks' 'zjstatus permitted' 'FAIL' (
                    "No grant for $permKey in $permPath - the plugin waits on a prompt that " +
                    'cannot be answered from a locked session. Fix: close every session with ' +
                    'delete-session, then re-run install.ps1')
            }
        } else {
            Add-Result '4 hooks' 'zjstatus permitted' 'FAIL' (
                "$permPath does not exist, so no plugin is permitted to run - the bar " +
                'will be absent with no prompt and no error. Fix: close every session with ' +
                'delete-session, then re-run install.ps1')
        }
    }
} else {
    Add-Result 'env' 'Claude layout' 'WARN' "Not at $zjLayout - default_layout `"claude`" will fail to start"
}

# The hook must never WAIT on `zellij pipe`: with zjstatus listening that call
# never returns, and Claude Code waits for its hooks.
$hookRaw = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\hooks\claude-zj-hook.ps1') -Raw -ErrorAction SilentlyContinue
if ($hookRaw) {
    if ($hookRaw -match '(?m)^\s*&\s*zellij[^\r\n]*\spipe\s') {
        Add-Result '4 hooks' 'Pipe is non-blocking' 'FAIL' 'Hook calls `& zellij ... pipe` and waits - this hangs Claude when zjstatus is loaded'
    } else {
        Add-Result '4 hooks' 'Pipe is non-blocking' 'PASS' 'Hook starts the pipe without waiting on it'
    }
}

# ---------------------------------------------------------------------------
#  Ctrl+V inside a pane
# ---------------------------------------------------------------------------
#  Zellij 0.44.3 on Windows never negotiates bracketed paste, so Windows
#  Terminal types the clipboard in as ordinary keystrokes and every newline is
#  Enter. In Claude Code that submits, so a ten-line paste becomes ten prompts.
#
#  NO ctrl+v ENTRY MEANS TERMINAL OWNS IT: ctrl+v -> paste is one of Terminal's
#  built-in defaults, so silence here is the broken case, not the healthy one.
#
#  Mirrors Get-ZtWtCtrlVState and Get-ZtClaudeCtrlVState in
#  module\ZellijTerminal\Public\Paste.ps1 - this script cannot import the module.
#  tests\Paste.Tests.ps1 pins them together. Full write-up: docs B6.
$pasteWt = @(
    @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    ) | Where-Object { Test-Path -LiteralPath $_ }
)

if ($pasteWt.Count -eq 0) {
    Add-Result 'env' 'Paste (Ctrl+V)' 'INFO' 'Terminal settings.json not found - skipped'
} else {
    $termOwnsCtrlV = $true
    $pasteRaw = Get-Content -LiteralPath $pasteWt[0] -Raw -ErrorAction SilentlyContinue
    if ($pasteRaw) {
        $pasteLive = ($pasteRaw -split "`r?`n" | Where-Object { $_.TrimStart() -notlike '//*' }) -join "`n"
        $pasteHit  = [regex]::Match($pasteLive, '\{[^{}]*"keys"\s*:\s*"ctrl\+v"[^{}]*\}', 'IgnoreCase')
        if ($pasteHit.Success) {
            if (($pasteHit.Value -match '"id"\s*:\s*null') -or ($pasteHit.Value -match '"command"\s*:\s*"unbound"')) {
                $termOwnsCtrlV = $false
            }
        }
    }

    $ccDir = $env:CLAUDE_CONFIG_DIR
    if (-not $ccDir) { $ccDir = Join-Path $env:USERPROFILE '.claude' }
    $ccKeys  = Join-Path $ccDir 'keybindings.json'
    $ccBound = $false
    if (Test-Path -LiteralPath $ccKeys) {
        try {
            $ccCfg = Get-Content -LiteralPath $ccKeys -Raw | ConvertFrom-Json
            foreach ($grp in @($ccCfg.bindings)) {
                if (-not $grp) { continue }
                if ("$($grp.context)" -ne 'Chat') { continue }
                if (-not $grp.bindings) { continue }
                $names = $grp.bindings.PSObject.Properties.Name
                if ($names -contains 'ctrl+v') {
                    if ("$($grp.bindings.'ctrl+v')" -eq 'chat:imagePaste') { $ccBound = $true }
                }
            }
        } catch { }
    }

    if ((-not $termOwnsCtrlV) -and $ccBound) {
        Add-Result 'env' 'Paste (Ctrl+V)' 'PASS' 'Terminal leaves ctrl+v alone and Claude Code binds it'
    } elseif ($termOwnsCtrlV -and (-not $ccBound)) {
        Add-Result 'env' 'Paste (Ctrl+V)' 'WARN' 'Terminal owns ctrl+v - multi-line pastes shred inside Zellij. Fix: zt paste fix (alt+v works meanwhile)'
    } elseif ($termOwnsCtrlV) {
        Add-Result 'env' 'Paste (Ctrl+V)' 'WARN' 'Claude Code binds ctrl+v but Terminal still intercepts it first. Fix: zt paste fix'
    } else {
        Add-Result 'env' 'Paste (Ctrl+V)' 'WARN' 'Terminal ctrl+v is unbound but Claude Code has no ctrl+v, so nothing pastes there. Fix: zt paste fix'
    }
}

# ---------------------------------------------------------------------------
#  Nothing registered inside a git worktree
# ---------------------------------------------------------------------------
#  The release worktree is GENERATED: Publish-Release.ps1 empties it on every
#  run and rebuilds it from the manifest. A session living there loses its files
#  to the next publish and holds the directory open so the publish fails. Both
#  have happened, which is why this is FAIL and not WARN.
#
#  Read `git worktree list` rather than hard-coding a path - the worktree's
#  location is not a constant and has moved at least once.
$repoRoot = $null
try { $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path } catch { }

$wtPaths = @()
if ($repoRoot) {
    $wtRaw = & git -C $repoRoot worktree list --porcelain 2>$null
    if ($LASTEXITCODE -eq 0 -and $wtRaw) {
        foreach ($line in @($wtRaw)) {
            if ("$line" -match '^worktree\s+(.+)$') { $wtPaths += $Matches[1] }
        }
    }
}

function Get-ZtNormPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    return (($Path -replace '/', '\').TrimEnd('\')).ToLowerInvariant()
}

if ($wtPaths.Count -le 1) {
    # One entry is the repo itself; none means git was unavailable. Either way
    # there is no generated worktree on this machine to fall into.
    Add-Result 'env' 'Release worktree' 'PASS' 'No extra git worktree registered on this device'
} else {
    $mainWt  = Get-ZtNormPath $wtPaths[0]
    $genWts  = @($wtPaths | ForEach-Object { Get-ZtNormPath $_ } | Where-Object { $_ -and $_ -ne $mainWt })

    # Everything this device points at: registered workspaces, and any live
    # session record. A live record is the urgent one - it means a session is
    # open in there right now.
    $suspect = @()

    $devPath2 = Get-DeviceConfigPath
    if (Test-Path -LiteralPath $devPath2) {
        try {
            $dev2 = Get-Content -LiteralPath $devPath2 -Raw | ConvertFrom-Json
            foreach ($w in @($dev2.workspaces)) {
                if ($w -and $w.path) { $suspect += [pscustomobject]@{ What = "workspace '$($w.id)'"; Path = $w.path } }
            }
        } catch { }
    }

    $liveBase2 = $env:LOCALAPPDATA
    if (-not $liveBase2) { $liveBase2 = $env:TEMP }
    $liveDir2 = Join-Path $liveBase2 'ZellijTerminal\live'
    if (Test-Path -LiteralPath $liveDir2) {
        foreach ($f in @(Get-ChildItem -LiteralPath $liveDir2 -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            try {
                $rec = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
                if ($rec -and $rec.cwd) { $suspect += [pscustomobject]@{ What = "LIVE SESSION in tab '$($rec.tab)'"; Path = $rec.cwd } }
            } catch { }
        }
    }

    $hits = @()
    foreach ($s in $suspect) {
        $p = Get-ZtNormPath $s.Path
        foreach ($g in $genWts) {
            if ($p -eq $g -or $p.StartsWith($g + '\')) {
                $hits += "$($s.What) -> $($s.Path)"
                break
            }
        }
    }

    if ($hits.Count -eq 0) {
        Add-Result 'env' 'Release worktree' 'PASS' "$($genWts.Count) worktree(s), none registered or running"
    } else {
        Add-Result 'env' 'Release worktree' 'FAIL' (
            "Inside a generated worktree, which the next publish empties: $($hits -join ' ; '). Close the session and unregister it")
    }
}

# ===========================================================================
#  REPORT
# ===========================================================================
foreach ($r in $results) {
    switch ($r.State) {
        'PASS' { $colour = 'Green'  }
        'FAIL' { $colour = 'Red'    }
        'WARN' { $colour = 'Yellow' }
        default { $colour = 'DarkGray' }
    }
    $line = '  {0,-12} {1,-22} {2,-5} {3}' -f $r.Layer, $r.Check, $r.State, $r.Detail
    Write-Host $line -ForegroundColor $colour
}

$failed = @($results | Where-Object { $_.State -eq 'FAIL' })

Write-Host ''
if ($failed.Count -eq 0) {
    Write-Host '  No failures. Press a pad key to confirm end to end.' -ForegroundColor Green
} else {
    Write-Host "  $($failed.Count) failure(s). Fix the LOWEST layer first -" -ForegroundColor Red
    Write-Host '  a broken layer makes everything above it look broken too.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  See docs/03-troubleshooting.md' -ForegroundColor DarkGray
}
Write-Host ''

