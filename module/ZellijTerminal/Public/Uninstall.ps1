<#
    Uninstall - undo what install.ps1 did, and nothing else.

    This exists because it was written by hand twice while testing releases, and
    the by-hand version has a trap in it that would cost you the repo: the module
    is on your module path as a JUNCTION, so `Remove-Item -Recurse` follows the
    link and deletes module\ZellijTerminal out of the clone. The link has to be
    removed as a link, and it carries the ReadOnly attribute, so the obvious
    .Delete() fails with "Access to the path is denied" until that is cleared.

    Nobody should have to know that to remove a tool. It is also the reason this
    is a command rather than a page in the README: an uninstall people have to
    perform from instructions is an uninstall people perform wrongly.

    WHAT IT WILL NOT TOUCH, unless you ask
      Your workspace registrations (%LOCALAPPDATA%\ZellijTerminal\devices\
      <HOST>.json) survive by default. They are yours, they took effort to build, and reinstalling is a
      normal thing to do - losing the project list to a reinstall is the kind of
      thing that stops people reinstalling. -Purge removes them.

    WHAT IT WILL NEVER TOUCH
      Zellij, PowerShell, PowerToys, the .NET SDK, and the clone itself. This
      installed none of them, so removing them is not its business. It says so
      at the end rather than leaving you to wonder.
#>

function Uninstall-ZellijTerminal {
    <#
    .SYNOPSIS
        Remove everything install.ps1 put on this machine.

    .DESCRIPTION
        Reverses each step of install.ps1, plus the optional pieces if they were
        set up. Reports what it removed, what it left, and why.

        Your workspace registrations are kept unless -Purge is given.

    .EXAMPLE
        zt uninstall -WhatIf     # see it first, always available
        zt uninstall
        zt uninstall -Purge      # registrations and live state as well

    .EXAMPLE
        # Keep the pad wired up, because you are about to reinstall
        zt uninstall -KeepPad
    #>
    # ConfirmImpact stays Medium on purpose. High makes every one of the nine
    # ShouldProcess calls below prompt separately at the default
    # $ConfirmPreference, which is both a prompt storm and - worse - a hard
    # failure with no TTY: each call throws "PowerShell is in NonInteractive
    # mode", so running this from a script aborted eight times and reported a
    # tidy summary saying it had kept everything. Safe, but only by accident.
    #
    # One gate instead, below: a single ShouldContinue that names what is going,
    # skipped by -Force, and refused outright when there is nobody to ask.
    # -WhatIf still enumerates every step, which is the part worth keeping.
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        # Also remove workspace registrations and live state. Off by default.
        [switch]$Purge,

        # Skip the confirmation. Required non-interactively: removing things is
        # not something to do because a script forgot to say it meant it.
        [switch]$Force,

        # Leave the Keyboard Manager remaps alone. Only sensible if you are
        # reinstalling to the same path - the remaps store absolute paths, and
        # `zt pad` reports it when they point somewhere else.
        [switch]$KeepPad,

        # Leave the Command Palette extension installed.
        [switch]$KeepPalette,

        # Leave the Zellij session running.
        [switch]$KeepSession,

        [string]$Session = 'claude'
    )

    $repo    = Get-ZtRoot
    $removed = @()
    $kept    = @()
    $failed  = @()

    Write-Host ''
    Write-Host '  Uninstalling zt' -ForegroundColor Cyan
    Write-Host "  $repo" -ForegroundColor DarkGray
    Write-Host ''

    # The single gate. -WhatIf skips it, because a dry run has nothing to
    # confirm and asking would make -WhatIf useless in a script.
    if (-not $WhatIfPreference -and -not $Force) {
        $what = 'the module junction, the Zellij layout, the Claude Code hook and the pad remaps'
        if ($Purge) { $what += ', AND your workspace registrations' }

        if (Get-ZtInteractive) {
            if (-not $PSCmdlet.ShouldContinue("This removes $what. Continue?", 'Uninstall zt')) {
                Write-Host '  Nothing removed.' -ForegroundColor DarkGray
                Write-Host ''
                return
            }
        } else {
            Write-Error ('Refusing to uninstall without confirmation and with nobody to ask. ' +
                         'Re-run with -Force if you meant it, or -WhatIf to see what it would do.')
            return
        }
    }

    # --- 1. the session -----------------------------------------------------
    # First, because killing it later would strand the tabs the rest of this
    # reports on.
    if (-not $KeepSession) {
        if (Test-ZtSession -Session $Session) {
            if ($PSCmdlet.ShouldProcess("Zellij session '$Session'", 'Kill')) {
                & zellij kill-session $Session 2>&1 | Out-Null
                & zellij delete-session $Session --force 2>&1 | Out-Null
                $removed += "session '$Session'"
            }
        }
    } else { $kept += "session '$Session'" }

    # --- 2. the pad ---------------------------------------------------------
    if (-not $KeepPad) {
        $ours = @(Get-ZtKbmGlobal (Get-ZtKbmConfig) | Where-Object { Test-ZtKbmOurs $_ })
        if ($ours.Count -gt 0) {
            if ($PSCmdlet.ShouldProcess('Keyboard Manager', "Remove $($ours.Count) pad remap(s)")) {
                Uninstall-ZellijTerminalPad -Confirm:$false | Out-Null
                $removed += "$($ours.Count) pad remap(s)"
            }
        }
    } else { $kept += 'pad remaps' }

    # --- 3. the Command Palette extension -----------------------------------
    if (-not $KeepPalette) {
        $pkg = $null
        try { $pkg = Get-AppxPackage ZellijTerminal.Palette -ErrorAction SilentlyContinue } catch { }
        if ($pkg) {
            if ($PSCmdlet.ShouldProcess("ZellijTerminal.Palette $($pkg.Version)", 'Remove-AppxPackage')) {
                try {
                    Get-Process 'ZellijTerminal.Palette' -ErrorAction SilentlyContinue |
                        Stop-Process -Force -ErrorAction SilentlyContinue
                    Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                    $removed += "Command Palette extension $($pkg.Version)"
                } catch {
                    $failed += "Command Palette extension: $($_.Exception.Message)"
                }
            }
        }
    } else { $kept += 'Command Palette extension' }

    # --- 4. the Claude Code hook --------------------------------------------
    # Two possible homes, and they are removed differently. The repo file is
    # ours outright. The global one is somebody's whole Claude Code
    # configuration - permissions, plugins, autoMode - with our hooks block
    # merged into it, so only that key comes out.
    $repoHook = Join-Path $repo (Join-Path '.claude' 'settings.json')
    if (Test-Path -LiteralPath $repoHook) {
        if ($PSCmdlet.ShouldProcess($repoHook, 'Remove the repo hook config')) {
            Remove-Item -LiteralPath $repoHook -Force -ErrorAction SilentlyContinue
            $removed += 'repo hook registration'
        }
    }

    $globalHook = Join-Path $HOME (Join-Path '.claude' 'settings.json')
    if (Test-Path -LiteralPath $globalHook) {
        $g = $null
        try { $g = Get-Content -LiteralPath $globalHook -Raw | ConvertFrom-Json } catch {
            $failed += "global settings is not valid JSON, left alone: $globalHook"
        }
        if ($g -and $g.PSObject.Properties.Name -contains 'hooks') {
            # Only OUR entries come out. `hooks` is a shared key: deleting it
            # wholesale also deleted anybody else's hooks, while the line
            # printed afterwards said the rest of the file was kept. It was -
            # the FILE was. Their hooks were not.
            $surgery   = Remove-ZtOwnHookEntries -Hooks $g.hooks
            $ours      = $surgery.OursRemoved
            $foreign   = $surgery.ForeignKept
            $survivors = $surgery.Survivors

            if ($ours -eq 0) {
                if ($foreign -gt 0) { $kept += "global hooks ($foreign entries, none of them ours)" }
            } elseif ($PSCmdlet.ShouldProcess($globalHook, 'Remove the zt hook entries, keeping any others')) {
                Copy-Item -LiteralPath $globalHook `
                          -Destination "$globalHook.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak" -Force

                if ($survivors) {
                    $g | Add-Member -NotePropertyName 'hooks' -NotePropertyValue $survivors -Force
                } else {
                    # Nothing left in it, so take the key out entirely rather
                    # than leaving an empty object behind.
                    $g.PSObject.Properties.Remove('hooks')
                }

                $g | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $globalHook -Encoding UTF8

                $msg = "global hook registration ($ours entries"
                if ($foreign -gt 0) { $msg += "; $foreign other hook entries left in place" }
                $msg += '; rest of the file backed up and kept)'
                $removed += $msg
            }
        }
    }

    # --- 4b. the Windows Terminal profile fragment ---------------------------
    # install.ps1 contributes a profile as a FRAGMENT rather than editing
    # settings.json, so removing it is deleting one file and the user's own
    # Terminal configuration is never touched. The icon beside it was extracted
    # from their zellij.exe at install time, so it is ours to remove too - and
    # leaving it would leave a dead profile pointing at an image nothing owns.
    $fragFile = Get-ZtWtFragmentPath
    $fragDir  = Split-Path $fragFile -Parent
    if (Test-Path -LiteralPath $fragFile) {
        if ($PSCmdlet.ShouldProcess($fragFile, 'Remove the Windows Terminal profile fragment')) {
            Remove-Item -LiteralPath $fragFile -Force -ErrorAction SilentlyContinue
            # Only if it is now empty: a fragment directory named after this rig
            # should not survive, but nor should anything else in it be assumed.
            if ((Test-Path -LiteralPath $fragDir) -and
                -not (Get-ChildItem -LiteralPath $fragDir -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $fragDir -Force -ErrorAction SilentlyContinue
            }
            $removed += 'Windows Terminal profile (restart Terminal to see it go)'
        }
    }

    $iconFile = Join-Path $env:LOCALAPPDATA (Join-Path 'ZellijTerminal' 'zellij-logo.png')
    if (Test-Path -LiteralPath $iconFile) {
        if ($PSCmdlet.ShouldProcess($iconFile, 'Remove the extracted Zellij icon')) {
            Remove-Item -LiteralPath $iconFile -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 5. Zellij config and layout ----------------------------------------
    # install.ps1 backs the config up before overwriting, so put the original
    # back rather than leaving a hole. Without this, uninstalling costs you
    # whatever Zellij configuration you had before you ever found this project.
    $zjDir  = Join-Path $env:APPDATA (Join-Path 'Zellij' 'config')
    $cfgDst = Join-Path $zjDir 'config.kdl'
    $layDst = Join-Path $zjDir (Join-Path 'layouts' 'claude.kdl')

    if (Test-Path -LiteralPath $layDst) {
        if ($PSCmdlet.ShouldProcess($layDst, 'Remove the claude layout')) {
            Remove-Item -LiteralPath $layDst -Force -ErrorAction SilentlyContinue
            $removed += 'claude layout'
        }
    }

    if (Test-Path -LiteralPath $cfgDst) {
        # Oldest backup = the config that was there before this was ever
        # installed. Later ones are backups of our own deployed copy, and
        # restoring one of those would hand back our config as if it were yours.
        #
        # Sorted by the timestamp in the NAME, not LastWriteTime: Copy-Item
        # preserves the source's mtime, so a backup's LastWriteTime is the age of
        # its contents, not when it was taken. Sorting by that picked whichever
        # config happened to be edited longest ago - which is not the same file
        # and, on this machine, was not even close.
        $backup = Get-ChildItem -LiteralPath $zjDir -Filter 'config.kdl.*.bak' -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match 'config\.kdl\.(\d{8}-\d{6})\.bak$' } |
                  Sort-Object { [regex]::Match($_.Name, '(\d{8}-\d{6})').Value } |
                  Select-Object -First 1
        if ($backup) {
            if ($PSCmdlet.ShouldProcess($cfgDst, "Restore your pre-install config from $($backup.Name)")) {
                Copy-Item -LiteralPath $backup.FullName -Destination $cfgDst -Force
                $removed += "Zellij config (yours restored from $($backup.Name))"
            }
        } else {
            if ($PSCmdlet.ShouldProcess($cfgDst, 'Remove the deployed Zellij config (no backup found)')) {
                Remove-Item -LiteralPath $cfgDst -Force -ErrorAction SilentlyContinue
                $removed += 'Zellij config (no pre-install backup existed)'
            }
        }
    }

    # --- 6. live state and flags --------------------------------------------
    $tempBits = @(
        (Join-Path $env:TEMP 'claude-zellij-flags'),
        (Join-Path $env:TEMP 'claude-zellij-status'),
        (Join-Path $env:TEMP 'claude-zellij-hook.log')
    )
    $tempGone = 0
    foreach ($t in $tempBits) {
        if (Test-Path -LiteralPath $t) {
            if ($PSCmdlet.ShouldProcess($t, 'Remove')) {
                Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
                $tempGone++
            }
        }
    }
    # Counted, not assumed. Appending this unconditionally made -WhatIf report
    # "Removed: transient flags and status" for a run that removed nothing,
    # which is the same shape of lie the whole project exists to refuse.
    if ($tempGone -gt 0) { $removed += "transient flags and status ($tempGone)" }

    # --- 7. registrations, only if asked ------------------------------------
    if ($Purge) {
        # Take a backup before destroying the one thing here that cannot be
        # regenerated. Registrations are the user's work - paths, kinds,
        # commands, tab-name overrides - and -Purge is a single word away from
        # -WhatIf. The export is cheap, and a backup nobody needed costs a file.
        if ($PSCmdlet.ShouldProcess('workspace registrations', 'Export a backup before purging')) {
            $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backup = Join-Path $env:TEMP "zt-purge-backup-$stamp.json"
            try {
                Export-ZellijTerminal -Path $backup -Confirm:$false -WarningAction SilentlyContinue |
                    Out-Null
                $kept += "a backup of everything purged: $backup  (restore with: zt import)"
            } catch {
                $failed += "could not back up before purging: $($_.Exception.Message)"
            }
        }

        $devFile = Get-ZtDevicePath
        if (Test-Path -LiteralPath $devFile) {
            if ($PSCmdlet.ShouldProcess($devFile, 'Remove this device''s workspace registrations')) {
                Remove-Item -LiteralPath $devFile -Force -ErrorAction SilentlyContinue
                $removed += 'workspace registrations'
            }
        }
        $liveDir = Get-ZtLiveDir
        if (Test-Path -LiteralPath $liveDir) {
            if ($PSCmdlet.ShouldProcess($liveDir, 'Remove live records')) {
                Remove-Item -LiteralPath $liveDir -Recurse -Force -ErrorAction SilentlyContinue
                $removed += 'live records'
            }
        }
    } else {
        $n = 0
        try { $n = @(Get-ZtProp (Get-ZtDeviceConfig) 'workspaces' @()).Count } catch { }
        $kept += "$n workspace registration(s) - remove with -Purge"
    }

    # --- 8. the module junction, LAST ---------------------------------------
    # Last because everything above needs the module's own functions, and
    # unjunctioning does not unload what is already in memory but there is no
    # reason to find out the hard way.
    $modulePath = Join-Path (Resolve-ZtUserModulePath) 'ZellijTerminal'
    if (Test-Path -LiteralPath $modulePath) {
        if ($PSCmdlet.ShouldProcess($modulePath, 'Remove the module junction')) {
            $item = Get-Item -LiteralPath $modulePath -Force

            # The guard that makes this safe. A junction deleted as a directory
            # takes the clone's module folder with it; this refuses rather than
            # risking it, and says what it found instead.
            if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $failed += ("$modulePath is a real directory, not a junction to this repo. " +
                            'Refusing to delete it - remove it by hand if you are sure.')
            } else {
                try {
                    # ReadOnly is set on junctions created by New-Item, and
                    # .Delete() fails with "Access denied" until it is cleared.
                    $item.Attributes = $item.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
                    $item.Delete()
                    $removed += 'module junction'
                } catch {
                    $failed += "module junction: $($_.Exception.Message)"
                }
            }
        }
    }

    # --- report -------------------------------------------------------------
    Write-Host ''
    if ($removed.Count -gt 0) {
        Write-Host '  Removed' -ForegroundColor Green
        foreach ($x in $removed) { Write-Host "    $x" -ForegroundColor DarkGray }
    }
    if ($kept.Count -gt 0) {
        Write-Host ''
        Write-Host '  Kept' -ForegroundColor Cyan
        foreach ($x in $kept) { Write-Host "    $x" -ForegroundColor DarkGray }
    }
    if ($failed.Count -gt 0) {
        Write-Host ''
        Write-Host '  Could not remove' -ForegroundColor Yellow
        foreach ($x in $failed) { Write-Host "    $x" -ForegroundColor Yellow }
    }

    Write-Host ''
    Write-Host '  Not touched, because this did not install them:' -ForegroundColor DarkGray
    Write-Host '    Zellij, PowerShell, PowerToys, the .NET SDK, and this clone.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  The commands stay in THIS shell until you close it - a loaded' -ForegroundColor DarkGray
    Write-Host '  module does not unload when its files go. Open a new one to' -ForegroundColor DarkGray
    Write-Host '  confirm zt is really gone.' -ForegroundColor DarkGray
    Write-Host ''
}
