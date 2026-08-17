<#
    Parking, restoring, and repairing the config by hand.

    THE SHUTDOWN POSITION

    There is no shutdown hook here, on purpose. Catching Windows on its way
    down is the weakest link available: SessionEnding gives you a few seconds,
    the OS can kill you anyway, and you would be racing to Ctrl+C several Claude
    sessions inside that window. Every part of that is unreliable at exactly the
    moment reliability matters.

    So make the loss cheap instead of fighting the clock. Two things already in
    place do the work:

      * session_serialization is on in config.kdl, so an exited Zellij session
        resurrects with its tabs, names and directories.
      * the live records carry each Claude session_id, which is what lets a
        restart resume the same conversation rather than opening a blank one.

    Shutdown therefore stops being an event that must be caught and becomes one
    that is recovered from. Restore is the safety net; park is just the tidy
    version of the same thing when you happen to be at the keyboard.
#>

function Get-ZtParkedPath {
    return (Join-Path (Split-Path (Get-ZtLiveDir) -Parent) 'parked.json')
}

function Suspend-ZellijTerminal {
    <#
    .SYNOPSIS
        Stop everything that is running, remembering what it was so Resume can
        bring it back.

    .DESCRIPTION
        Ctrl+C into each running workspace, leaving its tab as a shell, and
        writes a parked list beside the live records.

        Use it when you are about to shut down, or when you want the machine
        quiet without losing your place. It is not required before a shutdown -
        Resume works without it - it just makes the return exact.

    .EXAMPLE
        zt park
        zt park -Close        # close the tabs as well
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        # Close each tab after stopping it.
        [switch]$Close,

        [string]$Session = 'claude',
        [string]$Prefix  = 'claude-'
    )

    $running = @(Get-ZellijTerminal -Session $Session -Prefix $Prefix |
                 Where-Object { $_.State -eq 'running' })

    if ($running.Count -eq 0) {
        Write-Host 'Nothing running to park.' -ForegroundColor Green
        return
    }

    if (-not (Test-ZtClientAttached -Session $Session)) {
        Write-Error ("Nothing is attached to session '$Session', so the Ctrl+C would be swallowed " +
                     "and this would report a stop that never happened. Run zac first.")
        return
    }

    if (-not $PSCmdlet.ShouldProcess("$($running.Count) workspace(s)", 'Park')) { return }

    # Record BEFORE stopping: Stop deletes the live record, which is where the
    # session id lives, and the session id is the whole point of restoring.
    $record = [pscustomobject]@{
        parkedAt   = (Get-Date).ToString('o')
        device     = (Get-ZtDeviceName)
        workspaces = @($running | ForEach-Object {
            [pscustomobject]@{
                id        = $_.Id
                key       = $_.Key
                kind      = $_.Kind
                tab       = $_.Tab
                cwd       = $_.Path
                sessionId = $_.Session
            }
        })
    }
    Write-ZtJson (Get-ZtParkedPath) $record

    foreach ($ws in $running) {
        Stop-ZellijTerminal -Name $ws.Id -Session $Session -Prefix $Prefix -Confirm:$false
        if ($Close) {
            Remove-ZellijTerminalTab -Name $ws.Id -Session $Session -Prefix $Prefix -Confirm:$false
        }
    }

    Write-Host ''
    Write-Host "  Parked $($running.Count) workspace(s). Bring them back with: zt restore" -ForegroundColor Cyan
    Write-Host ''
}

function Resume-ZellijTerminal {
    <#
    .SYNOPSIS
        Reopen what was running, resuming each Claude session where it left off.

    .DESCRIPTION
        Two sources, in order:

          1. the parked list, if you ran `zt park`
          2. otherwise, live records with nothing running behind them

        The second is what makes this a shutdown recovery and not just an undo.
        A live record is written on SessionStart and deleted on SessionEnd, so a
        record still sitting there with no session behind it means that session
        did not exit - the machine went down under it. Those are exactly the
        workspaces worth bringing back.

    .EXAMPLE
        zt restore
        zt restore -Fresh     # reopen them, but start new conversations
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        # Start new Claude sessions instead of resuming the previous ones.
        [switch]$Fresh,

        [string]$Session = 'claude',
        [string]$Prefix  = 'claude-'
    )

    $parkedPath = Get-ZtParkedPath
    $parked     = Read-ZtJson $parkedPath $null

    $targets = @()
    $source  = ''

    if ($parked -and (Get-ZtProp $parked 'workspaces')) {
        $targets = @(Get-ZtProp $parked 'workspaces' @())
        $source  = "parked $(Get-ZtProp $parked 'parkedAt')"
    } else {
        # Nothing parked: find sessions that never got to say goodbye.
        $orphans = @(Get-ZellijTerminal -Session $Session -Prefix $Prefix |
                     Where-Object { $_.Session -and $_.State -ne 'running' })
        $targets = @($orphans | ForEach-Object {
            [pscustomobject]@{
                id = $_.Id; key = $_.Key; kind = $_.Kind
                tab = $_.Tab; cwd = $_.Path; sessionId = $_.Session
            }
        })
        $source = 'sessions that did not exit cleanly'
    }

    if ($targets.Count -eq 0) {
        Write-Host 'Nothing to restore.' -ForegroundColor Green
        return
    }

    Write-Host ''
    Write-Host "  Restoring $($targets.Count) workspace(s) - $source" -ForegroundColor Cyan
    foreach ($t in $targets) {
        Write-Host ("    {0,-20} {1}" -f (Get-ZtProp $t 'id'), (Get-ZtProp $t 'cwd')) -ForegroundColor DarkGray
    }
    Write-Host ''

    if (-not $PSCmdlet.ShouldProcess("$($targets.Count) workspace(s)", 'Restore')) { return }

    # Creating a tab is a server operation and works detached; typing into an
    # existing one is not. Most restores land on tabs that already exist -
    # Zellij resurrected them - so check once here rather than failing per item.
    if (-not (Test-ZtClientAttached -Session $Session)) {
        Write-Warning 'Nothing is attached - anything that needs typing into an existing tab will be skipped. Run zac first.'
    }

    foreach ($t in $targets) {
        $id = Get-ZtProp $t 'id'
        if (-not $id) { continue }

        $resume = $false
        if (-not $Fresh -and (Get-ZtProp $t 'kind' 'claude') -eq 'claude' -and (Get-ZtProp $t 'sessionId')) {
            $resume = $true
        }

        # The stale record would otherwise make Start think it is still running
        # - and clearing it discards the session id, so pass that in explicitly.
        $sid = Get-ZtProp $t 'sessionId'
        Remove-ZtLive (Get-ZtProp $t 'key')

        Start-ZellijTerminal -Name $id -Session $Session -Prefix $Prefix `
                             -Resume:$resume -SessionId $sid -Confirm:$false
    }

    if (Test-Path -LiteralPath $parkedPath) {
        Remove-Item -LiteralPath $parkedPath -Force -ErrorAction SilentlyContinue
    }
}

function Set-ZellijTerminalWaiting {
    <#
    .SYNOPSIS
        Raise a workspace's hand, or lower it - the thing key 3 jumps to.

    .DESCRIPTION
        The waiting queue is just flag files in %TEMP%\claude-zellij-flags. The
        Claude Code hook writes them automatically; nothing says only it can.

        Two uses. First, testing: with nothing waiting, key 3 falls through to
        plain cycling and is indistinguishable from key 4, so there is no way to
        tell "the jump works" from "nothing was waiting" without one of these.

        Second, and more usefully: it makes non-Claude workspaces first-class.
        A build or a deploy can end with `zt flag web` and the pad will take you
        to it, exactly as it would for a Claude session asking a question.

    .EXAMPLE
        npm run build; zt flag web
        zt unflag web
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Position = 0)]
        [string]$Name,

        # Lower the hand instead of raising it.
        [switch]$Clear,

        # What it is waiting for - shown by `zt` and the status bar.
        #
        # Named EventName, not Event: that is an automatic variable owned by
        # PowerShell's eventing subsystem. Aliased so -Event keeps working for
        # anyone who already types it.
        [Alias('Event')]
        [string]$EventName = 'Manual',

        [string]$Session = 'claude',
        [string]$Prefix  = 'claude-'
    )

    $ws = Resolve-ZtTarget -Name $Name -Title 'Flag which workspace?' -Session $Session -Prefix $Prefix
    if (-not $ws) { return }

    $flagDir = Join-Path $env:TEMP 'claude-zellij-flags'
    $flag    = Join-Path $flagDir ($ws.Tab + '.json')

    if ($Clear) {
        if (-not $PSCmdlet.ShouldProcess($ws.Id, 'Clear the waiting flag')) { return }
        if (Test-Path -LiteralPath $flag) {
            Remove-Item -LiteralPath $flag -Force
            Write-Host "Lowered '$($ws.Id)'" -ForegroundColor Green
        } else {
            Write-Host "'$($ws.Id)' was not flagged." -ForegroundColor Yellow
        }
        return
    }

    if (-not $PSCmdlet.ShouldProcess($ws.Id, "Flag as waiting ($EventName)")) { return }

    if (-not (Test-Path -LiteralPath $flagDir)) {
        New-Item -ItemType Directory -Path $flagDir -Force | Out-Null
    }

    # Exactly the shape the hook writes - zj-claude-tab.ps1 reads `waiting`,
    # `tab` and `since`, and nothing else.
    Write-ZtJson $flag ([pscustomobject]@{
        tab     = $ws.Tab
        cwd     = $ws.Path
        event   = $EventName
        waiting = $true
        since   = (Get-Date).ToString('o')
    })

    Write-Host "Flagged '$($ws.Id)' as waiting - key 3 will now jump to it." -ForegroundColor Green
}

function Edit-ZellijTerminalConfig {
    <#
    .SYNOPSIS
        Open the config JSON in your editor - the last-resort escape hatch.

    .DESCRIPTION
        Everything the commands do is a read-modify-write of these two files,
        and there is no state anywhere else, so editing them by hand is a
        supported repair rather than a hack. Run `zt validate` afterwards.

        Defaults to this device's file, which is the one that changes.

    .EXAMPLE
        zt config
        zt config -Shared
    #>
    [CmdletBinding()]
    param(
        # Open the shared config instead of this device's.
        [switch]$Shared,

        # Print the path instead of opening anything.
        [switch]$PathOnly
    )

    $path = Get-ZtDevicePath
    if ($Shared) { $path = Get-ZtSharedPath }

    if (-not (Test-Path -LiteralPath $path)) {
        if ($Shared) { Set-ZtSharedConfig (New-ZtSharedConfig) } else { Set-ZtDeviceConfig (New-ZtDeviceConfig) }
        Write-Host "Created $path" -ForegroundColor DarkGray
    }

    if ($PathOnly) { return $path }

    # $env:EDITOR first, then VS Code, then whatever .json is associated with.
    # Invoke-Item last because it is the one that can silently open nothing if
    # the association is broken.
    if ($env:EDITOR) {
        & $env:EDITOR $path
    } elseif (Get-Command code -ErrorAction SilentlyContinue) {
        & code $path
    } else {
        Invoke-Item -LiteralPath $path
    }

    Write-Host $path -ForegroundColor DarkGray
    Write-Host 'Run  zt validate  when you are done.' -ForegroundColor DarkGray
}

function Test-ZellijTerminalConfig {
    <#
    .SYNOPSIS
        Check both config files and say exactly what is wrong.

    .DESCRIPTION
        Hand-editing JSON goes wrong in a handful of predictable ways, and the
        failure otherwise surfaces much later inside some unrelated command.
        This finds them at the point you can still remember what you changed.

    .EXAMPLE
        zt validate
    #>
    [CmdletBinding()]
    param([string]$Prefix = 'claude-')

    $problems = @()
    $checked  = 0

    foreach ($spec in @(
        @{ Name = 'shared'; Path = (Get-ZtSharedPath) },
        @{ Name = "device ($(Get-ZtDeviceName))"; Path = (Get-ZtDevicePath) }
    )) {
        if (-not (Test-Path -LiteralPath $spec.Path)) {
            Write-Host ("  {0,-22} {1}" -f $spec.Name, 'absent (fine - created on first use)') -ForegroundColor DarkGray
            continue
        }

        $raw = Get-Content -LiteralPath $spec.Path -Raw -ErrorAction SilentlyContinue
        $cfg = $null
        try { $cfg = $raw | ConvertFrom-Json } catch {
            $problems += "$($spec.Name): not valid JSON - $($_.Exception.Message)"
            Write-Host ("  {0,-22} {1}" -f $spec.Name, 'INVALID JSON') -ForegroundColor Red
            continue
        }

        $ws = @(Get-ZtProp $cfg 'workspaces' @())
        $checked += $ws.Count
        Write-Host ("  {0,-22} {1} workspace(s)" -f $spec.Name, $ws.Count) -ForegroundColor Green

        $seenIds  = @{}
        $seenKeys = @{}
        foreach ($w in $ws) {
            $id  = Get-ZtProp $w 'id'
            $key = Get-ZtProp $w 'key'

            if (-not $id)  { $problems += "$($spec.Name): an entry has no id";  continue }
            if (-not $key) { $problems += "$($spec.Name): '$id' has no key - it cannot be matched to a session"; continue }

            # Duplicates make every command that takes a name ambiguous.
            if ($seenIds.ContainsKey($id))   { $problems += "$($spec.Name): duplicate id '$id'" }
            if ($seenKeys.ContainsKey($key)) { $problems += "$($spec.Name): duplicate key '$key' - two entries for the same directory" }
            $seenIds[$id]   = $true
            $seenKeys[$key] = $true

            if (-not (Get-ZtProp $w 'root') -and -not (Get-ZtProp $w 'abs')) {
                $problems += "$($spec.Name): '$id' has neither a root nor an absolute path"
            }
            # `-Kind pwsh` with no command is NOT a problem. It used to be an
            # error and was deliberately made valid - Registry.ps1 says so, and
            # `zt help` advertises it: "a shell in this folder, running nothing".
            # Reporting a documented, supported configuration as a fault teaches
            # people to skim past this command's output, which costs more than
            # the check could ever save.
        }
    }

    # Roots that point nowhere are the commonest cause of a workspace showing
    # 'unavailable' on a machine where the project is plainly present.
    foreach ($r in @(Get-ZellijTerminalRoot)) {
        if (-not $r.Exists) { $problems += "root '$($r.Name)' points at $($r.Path), which does not exist on this device" }
    }

    # Tab-name collisions: two workspaces claiming one tab means go-to-tab-name
    # picks arbitrarily, and the pad answers the wrong session.
    $tabs = @{}
    foreach ($w in @(Get-ZellijTerminal -All -NoDiscover -Prefix $Prefix)) {
        if (-not $w.Tab) { continue }
        if ($tabs.ContainsKey($w.Tab)) {
            $problems += "'$($w.Id)' and '$($tabs[$w.Tab])' both want tab '$($w.Tab)' - give one a name"
        }
        $tabs[$w.Tab] = $w.Id
    }

    Write-Host ''
    if ($problems.Count -eq 0) {
        Write-Host "  No problems. $checked workspace(s) checked." -ForegroundColor Green
    } else {
        foreach ($p in $problems) { Write-Host "  ! $p" -ForegroundColor Red }
        Write-Host ''
        Write-Host "  $($problems.Count) problem(s). Fix with: zt config" -ForegroundColor Yellow
    }
    Write-Host ''
}
