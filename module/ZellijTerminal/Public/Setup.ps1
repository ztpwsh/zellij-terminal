<#
    Setup - getting the module onto the module path, and checking the rig.
#>

function Resolve-ZtUserModulePath {
    # Take the user-scope entry already on PSModulePath rather than guessing:
    # Documents may be redirected (OneDrive, a work profile), and a guess would
    # install somewhere PowerShell never looks.
    $candidates = @(
        $env:PSModulePath -split [System.IO.Path]::PathSeparator |
            Where-Object { $_ -and $_ -match 'Documents.PowerShell.Modules$' } |
            Sort-Object -Unique
    )
    if ($candidates.Count -gt 0) { return $candidates[0] }

    $fallback = Join-Path $HOME (Join-Path 'Documents' (Join-Path 'PowerShell' 'Modules'))
    Write-Warning "No user-scope modules path found on PSModulePath. Falling back to: $fallback"
    return $fallback
}

function Install-ZellijTerminal {
    <#
    .SYNOPSIS
        Put ZellijTerminal on your module path as a junction back to the repo,
        and make sure this device has a config file.

    .DESCRIPTION
        A junction, not a symlink: junctions need no elevation and no developer
        mode. Edits in the repo are live in the next shell, which matters while
        the rig is still changing.

        No $PROFILE edit. The manifest exports its functions and aliases by
        name, so PowerShell autoloads the module the first time you type one.

    .EXAMPLE
        Import-Module C:\code\zt\module\ZellijTerminal
        Install-ZellijTerminal
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$ModulePath,

        # Replace an existing junction that points somewhere else.
        [switch]$Force
    )

    $source = Join-Path (Get-ZtRoot) (Join-Path 'module' 'ZellijTerminal')
    if (-not (Test-Path -LiteralPath $source)) {
        Write-Error "Module source not found: $source"
        return
    }
    $source = (Resolve-Path -LiteralPath $source).Path

    if (-not $ModulePath) { $ModulePath = Resolve-ZtUserModulePath }
    $dest = Join-Path $ModulePath 'ZellijTerminal'

    if (Test-Path -LiteralPath $dest) {
        $existing = Get-ZtReparseTarget $dest

        if (-not $existing) {
            Write-Error ("'$dest' already exists and is a real directory, not a link. " +
                         "Remove or rename it yourself, then re-run.")
            return
        }
        if ($existing.TrimEnd('\') -eq $source.TrimEnd('\')) {
            Write-Host "Already installed: $dest -> $existing" -ForegroundColor Green
        } elseif (-not $Force) {
            Write-Error ("'$dest' is already a link, but to '$existing'. " +
                         "Re-run with -Force to repoint it at '$source'.")
            return
        } elseif ($PSCmdlet.ShouldProcess($dest, "Remove junction pointing at '$existing'")) {
            if (-not (Remove-ZtLink $dest)) {
                Write-Error "Could not remove the existing junction at '$dest'. Remove it by hand and re-run."
                return
            }
        }
    }

    if (-not (Test-Path -LiteralPath $dest)) {
        if (-not (Test-Path -LiteralPath $ModulePath)) {
            if ($PSCmdlet.ShouldProcess($ModulePath, 'Create modules directory')) {
                New-Item -ItemType Directory -Path $ModulePath -Force | Out-Null
            }
        }
        if ($PSCmdlet.ShouldProcess($dest, "Create junction to '$source'")) {
            New-Item -ItemType Junction -Path $dest -Value $source -ErrorAction Stop | Out-Null
        }
    }

    # Retire the old name. It junctions into this same repo, so leaving it
    # behind means two module names exporting overlapping aliases and a coin
    # toss over which one wins.
    $old = Join-Path $ModulePath 'ClaudeZellij'
    if (Test-Path -LiteralPath $old) {
        $oldTarget = Get-ZtReparseTarget $old
        if ($oldTarget -and $oldTarget -like "$(Get-ZtRoot)*") {
            if ($PSCmdlet.ShouldProcess($old, 'Remove superseded ClaudeZellij junction')) {
                if (Remove-ZtLink $old) {
                    Write-Host '  removed the old ClaudeZellij junction' -ForegroundColor DarkGray
                } else {
                    Write-Warning ("Could not remove the old junction at '$old'. Two modules exporting " +
                                   "overlapping aliases is a coin toss - remove it by hand: rmdir `"$old`"")
                }
            }
        }
    }

    # A device config, so the first Register has roots to match against and the
    # file shows up in git as this machine declaring itself.
    if (-not (Test-Path -LiteralPath (Get-ZtDevicePath))) {
        if ($PSCmdlet.ShouldProcess((Get-ZtDevicePath), 'Create device config')) {
            Set-ZtDeviceConfig (New-ZtDeviceConfig)
        }
    }
    if (-not (Test-Path -LiteralPath (Get-ZtSharedPath))) {
        if ($PSCmdlet.ShouldProcess((Get-ZtSharedPath), 'Create shared config')) {
            Set-ZtSharedConfig (New-ZtSharedConfig)
        }
    }

    Write-Host ''
    Write-Host '  ZellijTerminal installed.' -ForegroundColor Green
    Write-Host "    $dest" -ForegroundColor DarkGray
    Write-Host "      -> $source" -ForegroundColor DarkGray
    Write-Host "    device: $(Get-ZtDeviceName)   $(Get-ZtDevicePath)" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  zt              list workspaces        zt start <id>' -ForegroundColor Cyan
    Write-Host '  zt add .        register this folder   zt stop <id>' -ForegroundColor Cyan
    Write-Host '  zac             attach / focus         zt restart <id>' -ForegroundColor Cyan
    Write-Host '  zt help         everything else' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Open a new shell, or run: Import-Module ZellijTerminal -Force' -ForegroundColor DarkGray
    Write-Host ''
}

function Test-ZellijTerminal {
    <#
    .SYNOPSIS
        Check every layer of the rig and print a pass/fail table.

    .DESCRIPTION
        Wraps scripts\Test-Setup.ps1. Fix the lowest failing layer first - a
        broken layer makes everything above it look broken too.

    .EXAMPLE
        zt check
    #>
    [CmdletBinding()]
    param(
        [string]$Session = 'claude',
        [string]$Prefix  = 'claude-'
    )

    & (Get-ZtScript 'Test-Setup.ps1') -Session $Session -Prefix $Prefix
}

function Get-ZellijTerminalDiagnostic {
    <#
    .SYNOPSIS
        Write one evidence bundle about this machine, for reading somewhere else.

    .DESCRIPTION
        Wraps scripts\Collect-Diagnostics.ps1.

        NOT the same job as `zt check`. That one asks whether each layer works
        and answers with a verdict; this one asks what is actually on the machine
        and answers with the bytes. It exists for the case the verdicts cannot
        reach: a clean `zt check` on a rig that does not work, because the files
        that decide whether it starts - the layout above all - are generated per
        machine and are not in any repository, so nobody can check them by
        reading the source.

        It changes nothing. -ParseLayout is the single exception and says so.

        Returns the path it wrote, so it can be piped somewhere.

    .EXAMPLE
        zt diag
        zt diag -ParseLayout
        zt diag -Path C:\temp\bundle.md -NoRedact
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Path,
        [string]$Session = 'claude',
        [string]$Prefix  = 'claude-',

        # Leave the user name, device name and profile path in the output.
        [switch]$NoRedact,

        # Ask Zellij to parse the deployed layout. Starts a throwaway session
        # and deletes it; the only way to tell a KDL error from a missing
        # session, because Zellij reports the first as the second.
        [switch]$ParseLayout
    )

    $splat = @{
        Session = $Session
        Prefix  = $Prefix
    }
    if ($Path)        { $splat['Path']        = $Path }
    if ($NoRedact)    { $splat['NoRedact']    = $true }
    if ($ParseLayout) { $splat['ParseLayout'] = $true }

    & (Get-ZtScript 'Collect-Diagnostics.ps1') @splat
}


