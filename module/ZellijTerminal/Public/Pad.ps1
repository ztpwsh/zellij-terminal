<#
    The macro pad - checking it, and wiring it up.

    THE PAD HAS NEVER ACTUALLY BEEN WIRED

    Test-Setup has reported "PowerToys has NO shortcut remaps - the pad keys do
    nothing" since it was written, and Keyboard Manager's config really is empty.
    Device present, transport working, hook working - the one missing link was a
    listener turning Ctrl+Shift+F13..F16 into commands. This closes it.

    POWERTOYS BY DEFAULT, AUTOHOTKEY BY REQUEST

    Both do the same job. PowerToys is already running on this machine, so its
    Keyboard Manager costs no additional process; AutoHotkey would add one that
    sits there forever. That is the whole of the reason - not a judgement about
    the tools.

    Running BOTH double-fires every key, which reads as the pad stuttering
    rather than as a configuration mistake, so these commands refuse to set up
    one while the other is live.

    WHERE THE SCHEMA CAME FROM

    Keyboard Manager's on-disk format is not documented, and a guessed schema is
    the worst possible outcome here: unknown fields are ignored silently, so the
    symptom is identical to a dead pad. It was not guessed. The JSON key names
    were read out of the shipped binaries:

        PowerToys.KeyboardManagerEditor.exe
        PowerToys.KeyboardManagerEngine.exe
        PowerToys.KeyboardManagerEditorUI.dll

    which yielded originalKeys, newRemapKeys, operationType, runProgramFilePath,
    runProgramArgs, runProgramStartInDir, runProgramElevationLevel,
    runProgramStartWindowType, runProgramAlreadyRunningAction, and the
    remapShortcuts/global container. The enum VALUES came from the PowerToys
    source (Shortcut.h): operationType RunProgram = 1, ElevationLevel
    NonElevated = 0, StartWindowType Hidden = 1, ProgramAlreadyRunningAction
    StartAnother = 1.

    KEYS 1 AND 2 DO NOT GO THROUGH POWERSHELL

    They call zellij.exe directly, ~60 ms measured, instead of paying a
    PowerShell start of ~500 ms to do nothing but forward two bytes.
    Only keys 3 and 4 need a script, because choosing which tab to jump to is
    real logic. The AutoHotkey script already makes this split; PowerToys now
    matches it.
#>

# VK codes. F13..F16 are 0x7C..0x7F. Generic VK_CONTROL (17) and VK_SHIFT (16)
# rather than the left-specific 162/160, so it matches whichever physical
# modifier the pad's firmware actually emits.
$script:ZtVkCtrl  = 17
$script:ZtVkShift = 16

function Get-ZtPadKeyMap {
    <#
        The four keys, and what each one runs. One definition, used to write the
        config, to check it, and to print the table.
    #>
    param(
        [string]$Session = 'claude',

        # Which tabs keys 3 and 4 move between. 'claude*' skips your shell,
        # editor and log tabs; '*' cycles everything in the session.
        [string]$Pattern = 'claude*'
    )

    $repo   = Get-ZtRoot
    $tabPs1 = Join-Path $repo (Join-Path 'scripts' 'zj-claude-tab.ps1')

    $zellij = 'zellij.exe'
    $found  = Get-Command zellij -ErrorAction SilentlyContinue
    if ($found) { $zellij = $found.Source }

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    # NO QUOTES around the script path.
    #
    # Keyboard Manager takes runProgramArgs as a single string and does not
    # appear to honour embedded double quotes: keys 1 and 2 (zellij.exe, no
    # quotes) fired, while 3 and 4 (powershell.exe -File "...") did nothing at
    # all, though the identical command line pasted into a shell worked. No
    # error anywhere - the same silent-failure shape as everything else in this
    # rig.
    #
    # The repo path has no spaces, so quotes were never needed. Where it does,
    # fall back to the 8.3 short path rather than quoting - same reason.
    # CHECK THE RESULT, not that the call did not throw. GetFile().ShortPath
    # returns the LONG path unchanged on a volume with 8.3 name creation
    # disabled - no exception, no warning, and the remap that gets written is
    # the unusable one this whole passage exists to avoid. So re-test for
    # whitespace afterwards and refuse, rather than writing a key that fails
    # silently and sends the user hunting through PowerToys.
    foreach ($p in 'tabPs1', 'zellij') {
        $val = (Get-Variable $p -ValueOnly)
        if ($val -notmatch '\s') { continue }

        try {
            $fso = New-Object -ComObject Scripting.FileSystemObject
            Set-Variable $p -Value ($fso.GetFile($val).ShortPath)
        } catch {
            # Swallowed on purpose, and only here: the re-test below is what
            # decides, so a failure to get a short name and a short name that
            # still has spaces reach the same refusal by the same route.
            Write-Verbose "8.3 lookup failed for '$val': $($_.Exception.Message)"
        }

        if ((Get-Variable $p -ValueOnly) -match '\s') {
            throw ("The path '$val' contains spaces and this volume has no 8.3 short name for it. " +
                   "Keyboard Manager takes runProgramArgs as one string and does not honour embedded " +
                   "quotes, so the remap would be written and then do nothing at all, with no error. " +
                   "Move the clone (or zellij.exe) somewhere without spaces, or enable 8.3 names on " +
                   "that volume, and run zt pad install again.")
        }
    }

    return @(
        [pscustomobject]@{
            Key = 1; Vk = 124; Chord = 'Ctrl+Shift+F13'
            Does = 'Enter - accept the highlighted option'
            File = $zellij; Args = "--session $Session action write 13"
        },
        [pscustomobject]@{
            Key = 2; Vk = 125; Chord = 'Ctrl+Shift+F14'
            Does = 'Esc - reject'
            File = $zellij; Args = "--session $Session action write 27"
        },
        [pscustomobject]@{
            Key = 3; Vk = 126; Chord = 'Ctrl+Shift+F15'
            Does = 'jump to whoever is waiting'
            File = $psExe; Args = "-NoProfile -ExecutionPolicy Bypass -File $tabPs1 -Waiting -Session $Session -Pattern $Pattern -ZellijExe $zellij"
        },
        [pscustomobject]@{
            Key = 4; Vk = 127; Chord = 'Ctrl+Shift+F16'
            Does = 'cycle claude-* tabs'
            File = $psExe; Args = "-NoProfile -ExecutionPolicy Bypass -File $tabPs1 -Direction next -Session $Session -Pattern $Pattern -ZellijExe $zellij"
        }
    )
}

function Get-ZtPadDeviceId {
    <#
        The pad's USB instance id, if one has been recorded. Stored per device,
        because which pad is plugged into which machine is a fact about that
        machine and nothing else.
    #>
    $device = Get-ZtDeviceConfig
    $pad    = Get-ZtProp $device 'pad'
    if (-not $pad) { return $null }
    return (Get-ZtProp $pad 'deviceId')
}

function Set-ZellijTerminalPadDevice {
    <#
    .SYNOPSIS
        Record which USB device is your pad, so `zt pad` can check it is plugged
        in.

    .DESCRIPTION
        Entirely optional - the pad works without this, because Keyboard Manager
        matches on the CHORD, not on which device sent it. This only enables the
        "device present" line in `zt pad`.

        To find yours, unplug it, run the command below, plug it back in, run it
        again, and diff:

            Get-PnpDevice -Class HIDClass,Keyboard -Status OK |
                Select-Object FriendlyName, InstanceId

    .EXAMPLE
        zt pad device 'USB\VID_8089&PID_000C*'
        zt pad device -Clear
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Position = 0)]
        [string]$InstanceId,

        # Forget it again.
        [switch]$Clear
    )

    if (-not $InstanceId -and -not $Clear) {
        $current = Get-ZtPadDeviceId
        if ($current) { Write-Host "  pad device: $current" -ForegroundColor Green }
        else { Write-Host '  No pad device recorded. Pass an instance id to set one.' -ForegroundColor Yellow }
        return
    }

    if (-not $PSCmdlet.ShouldProcess("device '$(Get-ZtDeviceName)'", $(if ($Clear) { 'Clear the pad device id' } else { "Record pad device '$InstanceId'" }))) {
        return
    }

    $device = Get-ZtDeviceConfig
    $pad    = Get-ZtProp $device 'pad'
    if (-not $pad) { $pad = [pscustomobject]@{} }

    if ($Clear) {
        $pad | Add-Member -NotePropertyName 'deviceId' -NotePropertyValue $null -Force
        Write-Host 'Pad device cleared.' -ForegroundColor Green
    } else {
        $pad | Add-Member -NotePropertyName 'deviceId' -NotePropertyValue $InstanceId -Force
        Write-Host "Pad device recorded: $InstanceId" -ForegroundColor Green
    }

    $device | Add-Member -NotePropertyName 'pad' -NotePropertyValue $pad -Force
    Set-ZtDeviceConfig $device
}

function Get-ZtKbmPath {
    return (Join-Path $env:LOCALAPPDATA (Join-Path 'Microsoft' (Join-Path 'PowerToys' (Join-Path 'Keyboard Manager' 'default.json'))))
}

function Get-ZtKbmConfig {
    $cfg = Read-ZtJson (Get-ZtKbmPath) $null
    if (-not $cfg) {
        $cfg = [pscustomobject]@{
            remapKeys      = [pscustomobject]@{ inProcess = @() }
            remapShortcuts = [pscustomobject]@{ global = @(); appSpecific = @() }
        }
    }
    return $cfg
}

function Get-ZtKbmGlobal {
    param($Config)
    $s = Get-ZtProp $Config 'remapShortcuts'
    if (-not $s) { return @() }
    return @(Get-ZtProp $s 'global' @())
}

function Test-ZtKbmOurs {
    <#
        Is this remap one of ours? Matched on what it runs, not on the keys, so
        a remap you made yourself on the same chord is never silently replaced.
    #>
    param($Remap)

    # Not $args: that is an automatic variable, and assigning to it inside a
    # function that also has a param block is the kind of shadowing that works
    # until somebody adds a second parameter.
    $file     = Get-ZtProp $Remap 'runProgramFilePath' ''
    $progArgs = Get-ZtProp $Remap 'runProgramArgs' ''
    if ($progArgs -like '*zj-claude-tab.ps1*') { return $true }
    if ($file -like '*zellij.exe' -and $progArgs -like '*action write*') { return $true }
    return $false
}

function Get-ZtAhkExe {
    # v2 only. v1 is also installed on this machine and fails a v2 script with a
    # syntax error that explains nothing.
    foreach ($c in @(
        'C:\Program Files\AutoHotkey\v2\AutoHotkey.exe',
        'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe',
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey.exe")) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Get-ZtPadScript { return (Join-Path (Get-ZtRoot) (Join-Path 'pad' 'macropad-zellij.ahk')) }

function Get-ZtAhkRunning {
    # Match the command line, not the process name: someone else's AHK script is
    # not this one, and saying so would take a while to unpick.
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name like 'AutoHotkey%'" -ErrorAction Stop |
                 Where-Object { $_.CommandLine -and $_.CommandLine -like '*macropad-zellij.ahk*' })
    } catch { return @() }
}

function Get-ZtPadProbeLog   { return (Join-Path $env:TEMP 'zt-pad-probe.log') }
function Get-ZtPadProbeState { return (Join-Path (Split-Path (Get-ZtLiveDir) -Parent) 'pad-probe-backup.json') }

function Debug-ZellijTerminalPad {
    <#
    .SYNOPSIS
        Find out which pad keys actually arrive, and whether PowerToys can
        launch anything for them.

    .DESCRIPTION
        "The pad does nothing" has at least three causes that look identical:
        the chord never reaches Windows, Keyboard Manager never matches it, or
        it matches and the launch fails. Nothing in the normal path
        distinguishes them, because every one of them is silent.

        So: temporarily point all four keys at the same trivial command - append
        a line to a log - and read which lines appear.

            all four logged      chords arrive, launching works; the fault is
                                 downstream in what the real remaps run
            some logged          the missing chords are not reaching Keyboard
                                 Manager. Check the pad's own key programming
            none logged          Keyboard Manager cannot launch powershell.exe
                                 at all, or is not reloading its config

        Always run `zt pad probe -Stop` afterwards; the real remaps are backed
        up and restored exactly.

    .EXAMPLE
        zt pad probe          # arm it, then press all four keys
        zt pad probe -Show    # what arrived
        zt pad probe -Stop    # put the real remaps back
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        # Report what has been logged so far.
        [switch]$Show,

        # Restore the real remaps.
        [switch]$Stop
    )

    $log   = Get-ZtPadProbeLog
    $state = Get-ZtPadProbeState
    $path  = Get-ZtKbmPath

    if ($Show) {
        if (-not (Test-Path -LiteralPath $log)) {
            Write-Host ''
            Write-Host '  Nothing logged - no pad key has fired since the probe was armed.' -ForegroundColor Yellow
            Write-Host '  That points at the chords not arriving, or Keyboard Manager not' -ForegroundColor DarkGray
            Write-Host '  reloading. Toggle Keyboard Manager off and on, then try again.' -ForegroundColor DarkGray
            Write-Host ''
            return
        }
        $lines = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)
        Write-Host ''
        Write-Host "  $($lines.Count) press(es) logged:" -ForegroundColor Cyan
        foreach ($k in 1..4) {
            $n = @($lines | Where-Object { $_ -eq "KEY$k" }).Count
            if ($n -gt 0) {
                Write-Host ('    key {0}  {1,3} press(es)  - chord arrives, launch works' -f $k, $n) -ForegroundColor Green
            } else {
                Write-Host ('    key {0}    none            - chord never arrived' -f $k) -ForegroundColor Red
            }
        }
        Write-Host ''
        Write-Host '  Put the real remaps back with: zt pad probe -Stop' -ForegroundColor DarkGray
        Write-Host ''
        return
    }

    if ($Stop) {
        $saved = Read-ZtJson $state $null
        if (-not $saved) {
            Write-Warning 'No probe backup found. Rewriting the real remaps instead.'
            Install-ZellijTerminalPad -Confirm:$false
            return
        }
        if (-not $PSCmdlet.ShouldProcess($path, 'Restore the real pad remaps')) { return }

        $cfg = Get-ZtKbmConfig
        $sc  = Get-ZtProp $cfg 'remapShortcuts'
        if (-not $sc) { $sc = [pscustomobject]@{} }
        $sc  | Add-Member -NotePropertyName 'global' -NotePropertyValue @(Get-ZtProp $saved 'global' @()) -Force
        $cfg | Add-Member -NotePropertyName 'remapShortcuts' -NotePropertyValue $sc -Force
        Write-ZtJson $path $cfg
        Remove-Item -LiteralPath $state -Force -ErrorAction SilentlyContinue
        Write-Host 'Real pad remaps restored.' -ForegroundColor Green
        return
    }

    # ---- arm it -----------------------------------------------------------

    if ($log -match '\s') {
        Write-Error "The temp path contains a space ($log), which Keyboard Manager cannot pass. Probe unavailable."
        return
    }

    $cfg    = Get-ZtKbmConfig
    $global = @(Get-ZtKbmGlobal $cfg)

    if (-not $PSCmdlet.ShouldProcess($path, 'Replace the pad remaps with a logging probe')) { return }

    Write-ZtJson $state ([pscustomobject]@{ savedAt = (Get-Date).ToString('o'); global = $global })

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $keep  = @($global | Where-Object { -not (Test-ZtKbmOurs $_) })
    $probe = @()
    foreach ($k in 1..4) {
        $vk = 123 + $k        # F13 = 124
        $probe += [pscustomobject]@{
            originalKeys                   = "$($script:ZtVkCtrl);$($script:ZtVkShift);$vk"
            newRemapKeys                   = ''
            operationType                  = 1
            runProgramFilePath             = $psExe
            runProgramArgs                 = "-NoProfile -Command Add-Content -LiteralPath $log -Value KEY$k"
            runProgramStartInDir           = ''
            runProgramElevationLevel       = 0
            runProgramAlreadyRunningAction = 1
            runProgramStartWindowType      = 1
        }
    }

    $sc = Get-ZtProp $cfg 'remapShortcuts'
    if (-not $sc) { $sc = [pscustomobject]@{} }
    $sc  | Add-Member -NotePropertyName 'global' -NotePropertyValue @($keep + $probe) -Force
    $cfg | Add-Member -NotePropertyName 'remapShortcuts' -NotePropertyValue $sc -Force
    Write-ZtJson $path $cfg

    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host '  Probe armed. All four keys now just write to a log.' -ForegroundColor Green
    Write-Host ''
    Write-Host '    1. Toggle Keyboard Manager OFF and ON in PowerToys, so it reloads.' -ForegroundColor DarkGray
    Write-Host '    2. Press pad keys 1, 2, 3, 4 - a few times each.' -ForegroundColor DarkGray
    Write-Host '    3. zt pad probe -Show' -ForegroundColor DarkGray
    Write-Host '    4. zt pad probe -Stop' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host "  log: $log" -ForegroundColor DarkGray
    Write-Host ''
}

function Test-ZellijTerminalPad {
    <#
    .SYNOPSIS
        Report what the pad is wired to, and what is missing.

    .DESCRIPTION
        Narrower than `zt check`, which walks all four layers. This answers only
        "will pressing a key do anything, and which listener would handle it".

    .EXAMPLE
        zt pad check
    #>
    [CmdletBinding()]
    param([string]$Session = 'claude')

    Write-Host ''
    Write-Host '  Macro pad' -ForegroundColor Cyan
    Write-Host '  ---------' -ForegroundColor Cyan

    # WHICH pad is a setting, not a constant.
    #
    # Nothing here needs a particular device. Anything that can emit
    # Ctrl+Shift+F13..F16 works: a macro pad, a programmable keyboard layer, a
    # spare numpad with remapped keys. This was built against a SayoDevice 1_3P,
    # and baking that USB id into the code would report "device NOT FOUND" to
    # everyone else holding a perfectly good pad.
    $padId = Get-ZtPadDeviceId
    if (-not $padId) {
        Write-Host ('  {0,-18} {1}' -f 'device', 'not configured - set one with: zt pad device <instance-id>') -ForegroundColor DarkGray
    } else {
        $pad = @(Get-PnpDevice -InstanceId $padId -ErrorAction SilentlyContinue)
        if ($pad.Count -gt 0) {
            Write-Host ('  {0,-18} {1}' -f 'device', "present ($($pad.Count) interfaces)") -ForegroundColor Green
        } else {
            Write-Host ('  {0,-18} {1}' -f 'device', "NOT FOUND ($padId) - unplugged?") -ForegroundColor Red
        }
    }

    $ptRun  = @(Get-Process PowerToys -ErrorAction SilentlyContinue)
    $global = @(Get-ZtKbmGlobal (Get-ZtKbmConfig))
    $ours   = @($global | Where-Object { Test-ZtKbmOurs $_ })

    if ($ptRun.Count -eq 0) {
        Write-Host ('  {0,-18} {1}' -f 'PowerToys', 'not running - remaps do nothing') -ForegroundColor Red
    } else {
        Write-Host ('  {0,-18} {1}' -f 'PowerToys', 'running') -ForegroundColor Green
    }

    # The engine reads the config at START, not on change. An engine older than
    # the file is running something other than what the file says - which has
    # now caused two separate hours of confusion: keys that kept working after
    # the remaps were deleted, and console windows that kept flashing after
    # they were set back to hidden.
    $eng = @(Get-Process PowerToys.KeyboardManagerEngine -ErrorAction SilentlyContinue)
    if ($eng.Count -eq 0) {
        Write-Host ('  {0,-18} {1}' -f 'KBM engine', 'NOT RUNNING - toggle Keyboard Manager off and on') -ForegroundColor Red
    } else {
        $cfgFile = Get-Item -LiteralPath (Get-ZtKbmPath) -ErrorAction SilentlyContinue
        $stale = $false
        try { $stale = ($eng[0].StartTime -lt $cfgFile.LastWriteTime) } catch { }
        if ($stale) {
            Write-Host ('  {0,-18} {1}' -f 'KBM engine', 'STALE - started before the config was last written') -ForegroundColor Yellow
            Write-Host ('  {0,-18} {1}' -f '', 'it is running the OLD remaps. Toggle Keyboard Manager off and on.') -ForegroundColor Yellow
        } else {
            Write-Host ('  {0,-18} {1}' -f 'KBM engine', 'running, config is current') -ForegroundColor Green
        }
    }

    if ($ours.Count -eq 4) {
        Write-Host ('  {0,-18} {1}' -f 'pad remaps', 'all 4 present') -ForegroundColor Green
    } elseif ($ours.Count -gt 0) {
        Write-Host ('  {0,-18} {1}' -f 'pad remaps', "only $($ours.Count) of 4 - run zt pad install") -ForegroundColor Yellow
    } else {
        Write-Host ('  {0,-18} {1}' -f 'pad remaps', 'NONE - the keys do nothing. Run zt pad install') -ForegroundColor Yellow
    }

    # Remaps carry an ABSOLUTE path to zj-claude-tab.ps1, frozen when they were
    # written. Move the clone, or install from a second one, and keys 3 and 4 go
    # on pointing at the old location - which Keyboard Manager reports by doing
    # nothing whatsoever. The count check above still says "all 4 present",
    # because they are: present, ours, and aimed at a file that may not exist.
    #
    # The AutoHotkey path has warned about exactly this since it was written
    # (see Install-ZellijTerminalPad -Listener ahk). PowerToys is the default
    # listener and never got the equivalent, so the more common setup was the
    # unguarded one. Found by installing from a second clone and watching
    # `zt pad` report a healthy pad that could not have worked.
    $expected = (Get-ZtRoot).TrimEnd('\')
    $stalePaths = @()
    foreach ($r in $ours) {
        $a = Get-ZtProp $r 'runProgramArgs' ''
        $m = [regex]::Match($a, '-File\s+(\S+)')
        if (-not $m.Success) { continue }          # keys 1 and 2 call zellij.exe directly
        $scriptPath = $m.Groups[1].Value
        $missing = -not (Test-Path -LiteralPath $scriptPath)
        $foreign = $scriptPath -notlike "$expected*"
        if ($missing -or $foreign) { $stalePaths += $scriptPath }
    }
    if ($stalePaths.Count -gt 0) {
        Write-Host ('  {0,-18} {1}' -f 'remap paths', (
            "$($stalePaths.Count) point outside this repo or at a missing file - " +
            'those keys do nothing. Run zt pad install')) -ForegroundColor Yellow
        foreach ($p in ($stalePaths | Sort-Object -Unique)) {
            Write-Host ('  {0,-18} {1}' -f '', "  $p") -ForegroundColor DarkGray
        }
        Write-Host ('  {0,-18} {1}' -f '', "  this repo: $expected") -ForegroundColor DarkGray
    }

    $downgraded = @($ours | Where-Object {
        (Get-ZtProp $_ 'runProgramStartWindowType' 1) -ne 1 -or
        (Get-ZtProp $_ 'runProgramAlreadyRunningAction' 1) -ne 1
    })
    if ($downgraded.Count -gt 0) {
        Write-Host ("  {0,-18} {1}" -f 'remap settings', "$($downgraded.Count) rewritten by the Keyboard Manager UI - console windows will flash. Run zt pad install") -ForegroundColor Yellow
    }

    $other = @($global | Where-Object { -not (Test-ZtKbmOurs $_) })
    if ($other.Count -gt 0) {
        Write-Host ('  {0,-18} {1}' -f 'other remaps', "$($other.Count) of yours, untouched") -ForegroundColor DarkGray
    }

    # @() around the call: a function RETURNING an empty array unrolls to $null,
    # and $null.Count throws under Set-StrictMode. Caught exactly here.
    $ahk = @(Get-ZtAhkRunning)
    if ($ahk.Count -gt 0) {
        Write-Host ('  {0,-18} {1}' -f 'AutoHotkey', "running - pid $($ahk[0].ProcessId)") -ForegroundColor Yellow
        if ($ours.Count -gt 0) {
            Write-Host ''
            Write-Host '  ! BOTH listeners are live. Every key press fires twice.' -ForegroundColor Red
            Write-Host '    Pick one: zt pad uninstall -Listener ahk' -ForegroundColor Red
        }
    }

    if (Test-ZtClientAttached -Session $Session) {
        Write-Host ('  {0,-18} {1}' -f 'client attached', 'yes - injection can land') -ForegroundColor Green
    } else {
        Write-Host ('  {0,-18} {1}' -f 'client attached', 'NO - every key is a silent no-op. Run zac') -ForegroundColor Red
    }

    Write-Host ''
    foreach ($k in (Get-ZtPadKeyMap -Session $Session)) {
        Write-Host ('    {0}  {1,-16} {2}' -f $k.Key, $k.Chord, $k.Does) -ForegroundColor DarkGray
    }
    Write-Host ''
}

function Install-ZellijTerminalPad {
    <#
    .SYNOPSIS
        Wire the pad up by writing PowerToys Keyboard Manager remaps.

    .DESCRIPTION
        Writes the four Ctrl+Shift+F13..F16 remaps into Keyboard Manager's
        config, backing it up first and leaving any remaps of your own alone -
        ours are identified by what they run, not by which keys they use.

        Keys 1 and 2 call zellij.exe directly rather than PowerShell, saving
        ~500 ms per press on the two keys where latency is most obvious.

        -Listener ahk uses the AutoHotkey script instead. It works, but it adds
        a resident process; PowerToys is already running.

    .EXAMPLE
        zt pad install
        zt pad install -Listener ahk -Startup
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [ValidateSet('powertoys', 'ahk')]
        [string]$Listener = 'powertoys',

        # AutoHotkey only: also run it at logon.
        [switch]$Startup,

        [string]$Session = 'claude',

        # Which tabs keys 3 and 4 move between. Pass '*' to cycle every tab in
        # the session, including your scratch and editor tabs.
        [string]$Pattern = 'claude*'
    )

    $keys = Get-ZtPadKeyMap -Session $Session -Pattern $Pattern

    if ($Listener -eq 'ahk') {
        $global = @(Get-ZtKbmGlobal (Get-ZtKbmConfig))
        if (@($global | Where-Object { Test-ZtKbmOurs $_ }).Count -gt 0) {
            Write-Error 'PowerToys already has the pad remaps. Running both listeners double-fires every key. Run: zt pad uninstall'
            return
        }

        $ahk = Get-ZtAhkExe
        if (-not $ahk) {
            Write-Error 'AutoHotkey v2 not found. Install it with: winget install AutoHotkey.AutoHotkey'
            return
        }
        $script = Get-ZtPadScript
        if (-not (Test-Path -LiteralPath $script)) { Write-Error "Pad script not found at $script"; return }

        # A stale RepoDir means keys 3 and 4 call a script that is not there,
        # and AutoHotkey reports that by doing nothing at all.
        $m = [regex]::Match((Get-Content -LiteralPath $script -Raw), 'RepoDir\s*:=\s*"([^"]+)"')
        if ($m.Success -and $m.Groups[1].Value.TrimEnd('\') -ne (Get-ZtRoot).TrimEnd('\')) {
            Write-Warning ("The script's RepoDir is '$($m.Groups[1].Value)' but this repo is at " +
                           "'$(Get-ZtRoot)'. Keys 3 and 4 will silently do nothing until that matches.")
        }

        if (-not $PSCmdlet.ShouldProcess('macro pad', 'Start the AutoHotkey listener')) { return }

        Start-Process -FilePath $ahk -ArgumentList "`"$script`"" | Out-Null
        Start-Sleep -Milliseconds 700
        $running = @(Get-ZtAhkRunning)
        if ($running.Count -eq 0) {
            Write-Error "The listener did not stay running. Run it by hand to see why: & '$ahk' '$script'"
            return
        }
        Write-Host "Pad listener running - pid $($running[0].ProcessId)" -ForegroundColor Green

        if ($Startup) {
            $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'zellij-macropad.lnk'
            if ($PSCmdlet.ShouldProcess($lnk, 'Create startup shortcut')) {
                $shell = New-Object -ComObject WScript.Shell
                $sc = $shell.CreateShortcut($lnk)
                $sc.TargetPath       = $ahk
                $sc.Arguments        = "`"$script`""
                $sc.WorkingDirectory = (Split-Path $script -Parent)
                $sc.Description      = 'Zellij macro pad listener'
                $sc.Save()
                Write-Host "  runs at logon: $lnk" -ForegroundColor DarkGray
            }
        }
        return
    }

    # ---- PowerToys ---------------------------------------------------------

    if (@(Get-ZtAhkRunning).Count -gt 0) {
        Write-Error 'The AutoHotkey listener is running. Running both double-fires every key. Run: zt pad uninstall -Listener ahk'
        return
    }

    $path = Get-ZtKbmPath
    $dir  = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        Write-Error ("Keyboard Manager has never run - $dir does not exist. Open PowerToys, enable " +
                     "Keyboard Manager once, then retry.")
        return
    }

    $cfg    = Get-ZtKbmConfig
    $global = @(Get-ZtKbmGlobal $cfg)
    $keep   = @($global | Where-Object { -not (Test-ZtKbmOurs $_) })

    $new = @()
    foreach ($k in $keys) {
        # Field set matched to what the WinUI3 editor itself writes, learned by
        # toggling one entry in the UI and diffing the file.
        #
        # THE EDITOR DOWNGRADES TWO OF THESE ON ANY SAVE. It rewrote all four
        # entries with runProgramStartWindowType 0 (Normal) and
        # runProgramAlreadyRunningAction 0 (ShowWindow), which means a console
        # window flashes on every key press and a running zellij.exe may be
        # focused instead of the command being run. Neither is what you want
        # from a macro pad, so re-run `zt pad install` after editing anything in
        # the Keyboard Manager UI.
        #
        # Note there is NO per-remap enabled field in either version - the UI's
        # toggle is not persisted at all, which is why it needs a fake edit and
        # a save to appear to stick. The engine honours every entry regardless;
        # verified by the keys working while the UI showed them off.
        $new += [pscustomobject]@{
            originalKeys                   = "$($script:ZtVkCtrl);$($script:ZtVkShift);$($k.Vk)"
            newRemapKeys                   = ''
            exactMatch                     = $false
            operationType                  = 1          # RunProgram
            runProgramFilePath             = $k.File
            runProgramArgs                 = $k.Args
            runProgramStartInDir           = ''
            runProgramElevationLevel       = 0          # NonElevated
            runProgramAlreadyRunningAction = 1          # StartAnother, NOT ShowWindow
            runProgramStartWindowType      = 1          # Hidden - no console flash
        }
    }

    if (-not $PSCmdlet.ShouldProcess($path, "Write $($new.Count) pad remap(s), keeping $($keep.Count) of yours")) {
        return
    }

    # Back up before touching it. This file is not ours and PowerToys does not
    # keep its own history.
    if (Test-Path -LiteralPath $path) {
        $bak = "$path.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
        Copy-Item -LiteralPath $path -Destination $bak -Force
        Write-Host "  backed up to $(Split-Path $bak -Leaf)" -ForegroundColor DarkGray
    }

    $shortcuts = Get-ZtProp $cfg 'remapShortcuts'
    if (-not $shortcuts) { $shortcuts = [pscustomobject]@{} }
    $shortcuts | Add-Member -NotePropertyName 'global' -NotePropertyValue @($keep + $new) -Force
    if (-not (Get-ZtProp $shortcuts 'appSpecific')) {
        $shortcuts | Add-Member -NotePropertyName 'appSpecific' -NotePropertyValue @() -Force
    }
    $cfg | Add-Member -NotePropertyName 'remapShortcuts' -NotePropertyValue $shortcuts -Force
    if (-not (Get-ZtProp $cfg 'remapKeys')) {
        $cfg | Add-Member -NotePropertyName 'remapKeys' -NotePropertyValue ([pscustomobject]@{ inProcess = @() }) -Force
    }

    Write-ZtJson $path $cfg

    Write-Host ''
    Write-Host "  Wrote $($new.Count) remaps to Keyboard Manager." -ForegroundColor Green
    foreach ($k in $keys) {
        Write-Host ('    {0}  {1,-16} {2}' -f $k.Key, $k.Chord, $k.Does) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  VERIFY BEFORE TRUSTING IT:' -ForegroundColor Cyan
    Write-Host '    1. PowerToys -> Keyboard Manager -> Remap a shortcut' -ForegroundColor DarkGray
    Write-Host '       Four rows should be listed. If the list is empty, the schema is wrong' -ForegroundColor DarkGray
    Write-Host '       and the backup above is the way back.' -ForegroundColor DarkGray
    Write-Host '    2. zac, then press key 1 at a Claude prompt.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  NOW TOGGLE KEYBOARD MANAGER OFF AND ON in PowerToys Settings.' -ForegroundColor Yellow
    Write-Host '  Its engine reads this file at START, not when it changes - so until you do,' -ForegroundColor DarkGray
    Write-Host '  it keeps running whatever it loaded last. That is why the keys can go on' -ForegroundColor DarkGray
    Write-Host '  working after the remaps are deleted, and why console windows can keep' -ForegroundColor DarkGray
    Write-Host '  flashing after they are set back to hidden.' -ForegroundColor DarkGray
    Write-Host ''
}

function Uninstall-ZellijTerminalPad {
    <#
    .SYNOPSIS
        Remove the pad remaps, or stop the AutoHotkey listener.

    .DESCRIPTION
        Removes only remaps this rig created - anything you added yourself stays.

    .EXAMPLE
        zt pad uninstall
        zt pad uninstall -Listener ahk
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [ValidateSet('powertoys', 'ahk')]
        [string]$Listener = 'powertoys'
    )

    if ($Listener -eq 'ahk') {
        $running = @(Get-ZtAhkRunning)
        foreach ($p in $running) {
            if ($PSCmdlet.ShouldProcess("pid $($p.ProcessId)", 'Stop pad listener')) {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
                Write-Host "Stopped listener pid $($p.ProcessId)" -ForegroundColor Green
            }
        }
        if ($running.Count -eq 0) { Write-Host 'No AutoHotkey listener was running.' -ForegroundColor Yellow }

        $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'zellij-macropad.lnk'
        if ((Test-Path -LiteralPath $lnk) -and $PSCmdlet.ShouldProcess($lnk, 'Remove startup shortcut')) {
            Remove-Item -LiteralPath $lnk -Force
            Write-Host '  removed from startup' -ForegroundColor DarkGray
        }
        return
    }

    $path   = Get-ZtKbmPath
    $cfg    = Get-ZtKbmConfig
    $global = @(Get-ZtKbmGlobal $cfg)
    $ours   = @($global | Where-Object { Test-ZtKbmOurs $_ })
    $keep   = @($global | Where-Object { -not (Test-ZtKbmOurs $_) })

    if ($ours.Count -eq 0) {
        Write-Host 'No pad remaps to remove.' -ForegroundColor Yellow
        return
    }
    if (-not $PSCmdlet.ShouldProcess($path, "Remove $($ours.Count) pad remap(s), keeping $($keep.Count)")) { return }

    $shortcuts = Get-ZtProp $cfg 'remapShortcuts'
    $shortcuts | Add-Member -NotePropertyName 'global' -NotePropertyValue @($keep) -Force
    Write-ZtJson $path $cfg
    Write-Host "Removed $($ours.Count) pad remap(s)." -ForegroundColor Green
}





