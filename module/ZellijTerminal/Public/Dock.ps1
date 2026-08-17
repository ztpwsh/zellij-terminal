<#
    Pinning the workspace band to Command Palette's dock.

    The dock is Command Palette's persistent strip - always on top, present
    whether or not the palette is summoned. It is configured in the palette's
    own settings.json as a list of bands, each naming a ProviderId and a
    CommandId, so pinning ours means editing that file. There is no API for it.

    This is what replaces the tray icon: an always-visible "2 running, 1
    WAITING" with no resident process of ours, no icon to maintain, and the same
    registry underneath everything else.
#>

function Get-ZtCmdPalSettingsPath {
    return (Join-Path $env:LOCALAPPDATA (Join-Path 'Packages' (Join-Path 'Microsoft.CommandPalette_8wekyb3d8bbwe' (Join-Path 'LocalState' 'settings.json'))))
}

function Add-ZellijTerminalDock {
    <#
    .SYNOPSIS
        Pin the Zellij workspace band to the Command Palette dock.

    .DESCRIPTION
        Adds a band naming this extension's provider and its workspaces command.
        Idempotent - a band that is already there is left alone.

        Command Palette rewrites its settings on exit, so it is closed first.
        Editing the file underneath a running palette means the change is
        silently discarded, which looks exactly like the band not working.

    .EXAMPLE
        zt dock
        zt dock -Remove
        zt dock -Side Start
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        # Which end of the dock. Start is the left/top group, End the right.
        [ValidateSet('Start', 'Center', 'End')]
        [string]$Side = 'End',

        # Take the band off again.
        [switch]$Remove,

        # Leave Command Palette running - the change will probably be lost.
        [switch]$NoRestart
    )

    $path = Get-ZtCmdPalSettingsPath
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Error ("Command Palette settings not found at $path. Open Command Palette once, " +
                     "then retry.")
        return
    }

    $cfg = Read-ZtJson $path $null
    if (-not $cfg) { Write-Error "Could not read $path"; return }

    $dock = Get-ZtProp $cfg 'DockSettings'
    if (-not $dock) { Write-Error 'Command Palette has no DockSettings - is the dock feature present?'; return }

    $listName = "$($Side)Bands"
    $bands    = @(Get-ZtProp $dock $listName @())

    # The provider id is the one the extension sets on its CommandProvider; the
    # command id is the one on the workspaces page. Both are fixed in the C#
    # precisely so this can name them.
    $providerId = 'ZellijTerminal'
    $commandId  = 'zt.workspaces'

    $already = @($bands | Where-Object {
        (Get-ZtProp $_ 'ProviderId') -eq $providerId -and (Get-ZtProp $_ 'CommandId') -eq $commandId
    })

    if ($Remove) {
        if ($already.Count -eq 0) { Write-Host 'The band is not pinned.' -ForegroundColor Yellow; return }
        if (-not $PSCmdlet.ShouldProcess('Command Palette dock', 'Remove the Zellij band')) { return }
        $bands = @($bands | Where-Object {
            -not ((Get-ZtProp $_ 'ProviderId') -eq $providerId -and (Get-ZtProp $_ 'CommandId') -eq $commandId)
        })
    } else {
        if ($already.Count -gt 0) {
            Write-Host "Already pinned to the $Side of the dock." -ForegroundColor Green
            return
        }
        if (-not $PSCmdlet.ShouldProcess('Command Palette dock', "Pin the Zellij band to $Side")) { return }
        $bands = @($bands) + [pscustomobject]@{
            ProviderId    = $providerId
            CommandId     = $commandId
            ShowTitles    = $null
            ShowSubtitles = $null
        }
    }

    # Closing first, because the palette writes this file on exit and would
    # overwrite the edit - a silent loss that reads as "the band does not work".
    if (-not $NoRestart) {
        $ui = @(Get-Process 'Microsoft.CmdPal.UI' -ErrorAction SilentlyContinue)
        if ($ui.Count -gt 0) {
            Write-Host '  closing Command Palette so it does not overwrite this' -ForegroundColor DarkGray
            $ui | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 700
        }
    }

    $bak = "$path.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
    Copy-Item -LiteralPath $path -Destination $bak -Force

    $dock | Add-Member -NotePropertyName $listName -NotePropertyValue $bands -Force
    $cfg  | Add-Member -NotePropertyName 'DockSettings' -NotePropertyValue $dock -Force

    # Depth matters: DockSettings nests monitor configs several levels down, and
    # the default depth of 2 would quietly flatten them to type names.
    $json = $cfg | ConvertTo-Json -Depth 12
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8

    Write-Host ''
    if ($Remove) {
        Write-Host '  Band removed.' -ForegroundColor Green
    } else {
        Write-Host "  Pinned to the $Side of the dock." -ForegroundColor Green
        Write-Host '  It shows the workspace count, and updates itself.' -ForegroundColor DarkGray
    }
    Write-Host "  backup: $(Split-Path $bak -Leaf)" -ForegroundColor DarkGray
    Write-Host '  Reopen Command Palette to see it.' -ForegroundColor DarkGray
    Write-Host ''
}

function Get-ZellijTerminalDock {
    <#
    .SYNOPSIS
        Show the Command Palette dock's current bands.

    .EXAMPLE
        zt dock -List
    #>
    [CmdletBinding()]
    param()

    $cfg = Read-ZtJson (Get-ZtCmdPalSettingsPath) $null
    $dock = Get-ZtProp $cfg 'DockSettings'
    if (-not $dock) { Write-Warning 'No dock settings found.'; return }

    Write-Host ''
    Write-Host ("  dock: {0}, always on top: {1}, enabled: {2}" -f
        (Get-ZtProp $dock 'Side' '?'), (Get-ZtProp $dock 'AlwaysOnTop' '?'), (Get-ZtProp $cfg 'EnableDock' '?')) -ForegroundColor Cyan
    Write-Host ''

    foreach ($side in 'Start', 'Center', 'End') {
        $bands = @(Get-ZtProp $dock "$($side)Bands" @())
        Write-Host ("  {0,-8} {1} band(s)" -f $side, $bands.Count) -ForegroundColor DarkGray
        foreach ($b in $bands) {
            $mine = ''
            if ((Get-ZtProp $b 'ProviderId') -eq 'ZellijTerminal') { $mine = '   <- this rig' }
            Write-Host ("    {0,-40} {1}{2}" -f (Get-ZtProp $b 'ProviderId'), (Get-ZtProp $b 'CommandId'), $mine)
        }
    }
    Write-Host ''
}
