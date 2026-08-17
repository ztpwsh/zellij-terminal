<#
    Command Palette's per-command global hotkeys.

    The palette has a `CommandHotkeys` map in its settings, separate from the
    single summon hotkey. If it does what its name suggests - bind a system-wide
    chord straight to one command - then the pad could talk to the palette
    instead of to Keyboard Manager, and one of the two listeners goes away.

    The commands it would need already exist in the extension:

        zt.answer.yes     Enter into the focused pane   (pad key 1)
        zt.answer.no      Esc into the focused pane     (pad key 2)
        zt.global.Jumptowhoeveriswaiting                (pad key 3)
        zt.workspaces     the list                      (pad key 4-ish)

    What is NOT known is the on-disk shape of a CommandHotkeys entry, and the
    palette's own binaries are under WindowsApps ACLs that will not give it up.
    Guessing a config format whose failure mode is silence is exactly the
    mistake this repo keeps writing down - so this learns it from one you set by
    hand, the same way Keyboard Manager's schema was learned.
#>

function Get-ZellijTerminalHotkey {
    <#
    .SYNOPSIS
        Show Command Palette's command hotkeys, and learn their format.

    .DESCRIPTION
        With none set, prints what to do to create one. With one set, prints its
        exact shape and saves a copy - which is what a future `-Install` needs
        to write the rest.

    .EXAMPLE
        zt hotkeys
    #>
    [CmdletBinding()]
    param(
        # Where to save the captured sample.
        [string]$SamplePath
    )

    $path = Get-ZtCmdPalSettingsPath
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Error "Command Palette settings not found at $path"
        return
    }

    $cfg = Read-ZtJson $path $null
    $summon = Get-ZtProp $cfg 'Hotkey'
    $hk     = Get-ZtProp $cfg 'CommandHotkeys'

    Write-Host ''
    if ($summon) {
        Write-Host ('  summon: {0}' -f (Format-ZtHotkey $summon)) -ForegroundColor DarkGray
    }

    $entries = @()
    if ($hk) {
        if ($hk -is [System.Array]) { $entries = @($hk) }
        else { $entries = @($hk.PSObject.Properties) }
    }

    if ($entries.Count -eq 0) {
        Write-Host '  No command hotkeys set.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  To learn the format, set ONE by hand and run this again:' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '    1. Open Command Palette' -ForegroundColor DarkGray
        Write-Host '    2. Find  "Zellij: accept the prompt"' -ForegroundColor DarkGray
        Write-Host '    3. Assign it a hotkey - Ctrl+Shift+F13, the pad''s key 1' -ForegroundColor DarkGray
        Write-Host '    4. zt hotkeys' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  If that chord binds and fires with the palette CLOSED, Keyboard' -ForegroundColor DarkGray
        Write-Host '  Manager is no longer needed and zt pad uninstall can retire it.' -ForegroundColor DarkGray
        Write-Host ''
        return
    }

    Write-Host "  $($entries.Count) command hotkey(s):" -ForegroundColor Green
    Write-Host ''
    Write-Host ($hk | ConvertTo-Json -Depth 8)

    if (-not $SamplePath) {
        # NOT into the clone, and not into spikes/ least of all. This wrote
        # <clone>\spikes\cmdpal-hotkey-sample.json, so running `zt hotkeys` in a
        # published checkout CREATED a spikes directory - the one directory this
        # project promises is never published - and put the device name in it.
        # Nothing could catch that either: the anonymisation gate reads tracked
        # files, and this is a runtime write.
        #
        # It is a capture of this machine's Command Palette bindings, so it is
        # device state and belongs with the rest of it. Same reasoning as
        # Get-ZtConfigHome: a clone is one checkout of the code, not the machine.
        $SamplePath = Join-Path (Get-ZtConfigHome) 'cmdpal-hotkey-sample.json'
    }
    Write-ZtJson $SamplePath ([pscustomobject]@{
        capturedAt     = (Get-Date).ToString('o')
        device         = (Get-ZtDeviceName)
        summon         = $summon
        commandHotkeys = $hk
    })
    Write-Host ''
    Write-Host "  Saved a copy to $SamplePath" -ForegroundColor DarkGray
    Write-Host '  With this, the other three can be written the same way.' -ForegroundColor Cyan
    Write-Host ''
}

function Install-ZellijTerminalHotkey {
    <#
    .SYNOPSIS
        Bind the pad's four chords straight to Command Palette commands, so
        Keyboard Manager is not needed at all.

    .DESCRIPTION
        Command Palette's CommandHotkeys really are system-wide: verified on
        2026-08-15 with Ctrl+Shift+Alt+F7, a chord Keyboard Manager knew nothing
        about, which fired the command anyway. That makes the palette able to do
        the whole job the pad needs.

        The four bindings mirror the Keyboard Manager ones exactly:

            Ctrl+Shift+F13  zt.answer.yes   Enter into the focused pane
            Ctrl+Shift+F14  zt.answer.no    Esc into the focused pane
            Ctrl+Shift+F15  zt.waiting      jump to whoever is waiting
            Ctrl+Shift+F16  zt.nexttab      cycle the claude-* tabs

        No Alt anywhere: Ctrl+Alt is AltGr on a UK layout, which D21 in
        docs/02-decisions.md rules out outright. The Ctrl+Shift+Alt+F7 used to
        prove the mechanism is fine as a one-off test but would be a poor
        permanent binding.

        Running this while Keyboard Manager still has the same chords mapped
        would double-fire every key, so it refuses unless they are gone.

    .EXAMPLE
        zt hotkeys -Install
        zt hotkeys -Install -Remove
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        # Take the bindings out again.
        [switch]$Remove,

        # Bind even though Keyboard Manager has the same chords.
        [switch]$Force
    )

    $path = Get-ZtCmdPalSettingsPath
    if (-not (Test-Path -LiteralPath $path)) { Write-Error "Command Palette settings not found."; return }

    # F13..F16 are 124..127, same codes the pad emits and Keyboard Manager used.
    $wanted = @(
        [pscustomobject]@{ CommandId = 'zt.answer.yes'; Code = 124; Label = 'Ctrl+Shift+F13  accept' },
        [pscustomobject]@{ CommandId = 'zt.answer.no';  Code = 125; Label = 'Ctrl+Shift+F14  reject' },
        [pscustomobject]@{ CommandId = 'zt.waiting';    Code = 126; Label = 'Ctrl+Shift+F15  go to whoever is waiting' },
        [pscustomobject]@{ CommandId = 'zt.nexttab';    Code = 127; Label = 'Ctrl+Shift+F16  next tab' }
    )

    if (-not $Remove -and -not $Force) {
        $kbm = @(Get-ZtKbmGlobal (Get-ZtKbmConfig)) | Where-Object { Test-ZtKbmOurs $_ }
        if (@($kbm).Count -gt 0) {
            Write-Error ("Keyboard Manager still has $(@($kbm).Count) of the same chords mapped. Binding " +
                         "both would fire every key twice. Run: zt pad uninstall")
            return
        }
    }

    $cfg = Read-ZtJson $path $null
    if (-not $cfg) { Write-Error "Could not read $path"; return }

    $existing = @(Get-ZtProp $cfg 'CommandHotkeys' @())
    $ours     = @($wanted | ForEach-Object { $_.CommandId })
    $keep     = @($existing | Where-Object { $ours -notcontains (Get-ZtProp $_ 'CommandId') })

    if ($Remove) {
        if (-not $PSCmdlet.ShouldProcess('Command Palette', "Remove $($ours.Count) hotkey binding(s)")) { return }
        $new = $keep
    } else {
        if (-not $PSCmdlet.ShouldProcess('Command Palette', "Bind $($wanted.Count) pad chords")) { return }
        $new = @($keep) + @($wanted | ForEach-Object {
            [pscustomobject]@{
                CommandId = $_.CommandId
                Hotkey    = [pscustomobject]@{
                    win = $false; ctrl = $true; alt = $false; shift = $true
                    code = $_.Code; key = ''
                }
            }
        })
    }

    # The palette rewrites this file on exit and would discard the edit.
    $ui = @(Get-Process 'Microsoft.CmdPal.UI' -ErrorAction SilentlyContinue)
    if ($ui.Count -gt 0) {
        Write-Host '  closing Command Palette so it does not overwrite this' -ForegroundColor DarkGray
        $ui | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 900
    }

    Copy-Item -LiteralPath $path -Destination "$path.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak" -Force
    $cfg | Add-Member -NotePropertyName 'CommandHotkeys' -NotePropertyValue @($new) -Force
    Set-Content -LiteralPath $path -Value ($cfg | ConvertTo-Json -Depth 20) -Encoding UTF8

    Write-Host ''
    if ($Remove) {
        Write-Host '  Bindings removed.' -ForegroundColor Green
    } else {
        Write-Host '  Bound to Command Palette:' -ForegroundColor Green
        foreach ($w in $wanted) { Write-Host "    $($w.Label)" -ForegroundColor DarkGray }
        Write-Host ''
        Write-Host '  Keyboard Manager is no longer needed for the pad.' -ForegroundColor Cyan
    }
    Write-Host '  Reopen Command Palette for these to take effect.' -ForegroundColor DarkGray
    Write-Host ''
}

function Format-ZtHotkey {
    <#
        The palette stores a chord as flags plus a virtual-key code, the same
        shape as its summon hotkey.
    #>
    param($Hotkey)

    $parts = @()
    if (Get-ZtProp $Hotkey 'win')   { $parts += 'Win' }
    if (Get-ZtProp $Hotkey 'ctrl')  { $parts += 'Ctrl' }
    if (Get-ZtProp $Hotkey 'alt')   { $parts += 'Alt' }
    if (Get-ZtProp $Hotkey 'shift') { $parts += 'Shift' }

    $code = Get-ZtProp $Hotkey 'code'
    $key  = Get-ZtProp $Hotkey 'key'

    $name = $key
    if (-not $name -and $code) {
        # F13..F24 are 124..135, which is the range the pad uses.
        if ($code -ge 124 -and $code -le 135) { $name = 'F' + ($code - 111) }
        elseif ($code -eq 32) { $name = 'Space' }
        else { $name = "vk$code" }
    }

    $parts += $name
    return ($parts -join '+')
}
