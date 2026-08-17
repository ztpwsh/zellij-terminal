<#
.SYNOPSIS
    Install zt - the Zellij workspace rig - on this machine.

.DESCRIPTION
    Everything that has to know an absolute path is generated here rather than
    committed, because a committed path is right on exactly one machine and
    silently wrong on every other:

      1. junctions the PowerShell module onto your module path
      2. writes zellij\config.kdl and the claude layout into Zellij's own
         config directory, with your plugin path filled in
      3. writes .claude\settings.json from a template, pointing the Claude Code
         hook at this clone

    Nothing here needs elevation, and nothing is written outside your user
    profile and this repo.

.EXAMPLE
    .\install.ps1
    .\install.ps1 -SkipZellijConfig -SkipHook
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Where to junction the module. Defaults to your user-scope modules folder.
    [string]$ModulePath,

    # Leave Zellij's config and layout alone.
    [switch]$SkipZellijConfig,

    # Do not register the Claude Code hook for this repo.
    [switch]$SkipHook,

    # Register the hook in %USERPROFILE%\.claude instead of this repo, so it
    # fires for EVERY project rather than only this one. Merged into whatever is
    # already in that file; your permissions and plugins are left alone.
    [switch]$Global,

    # Replace an existing module junction that points somewhere else.
    [switch]$Force,

    # Install Zellij with winget if it is missing, without asking. For
    # unattended runs; interactively you get a prompt instead.
    [switch]$InstallZellij,

    # Do not look for Zellij at all.
    [switch]$SkipZellijCheck
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

# Anything that went wrong but did not stop the run. The closing banner is
# conditional on this being empty - an installer that says "Done" after a failed
# step is worse than one that crashes, because you go and use it.
$problems = @()

# bootstrap.ps1 gates on this, but README and the zt-setup skill both tell you
# to run install.ps1 directly, so the gate has to be here too or the documented
# path is the unguarded one. The module is installed to the pwsh 7 module path,
# which 5.1 does not scan, so `zt` would simply never resolve and the failure
# would surface later as "command not recognised" with nothing pointing here.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ''
    Write-Host '  zellij-terminal needs PowerShell 7 or later.' -ForegroundColor Red
    Write-Host "  You are running PowerShell $($PSVersionTable.PSVersion)." -ForegroundColor Yellow
    Write-Host '  The module installs to the pwsh 7 module path, which 5.1 does not' -ForegroundColor Yellow
    Write-Host '  scan, so zt would never autoload. Install it and retry:' -ForegroundColor Yellow
    Write-Host '    winget install --id Microsoft.PowerShell' -ForegroundColor Cyan
    Write-Host ''
    return
}

# 0.44 is the first native Windows release. Earlier versions are not "mostly
# fine", they are the wrong platform entirely.
$MinZellij = [version]'0.44'

function Write-Step { param([string]$Text) Write-Host "  $Text" -ForegroundColor Cyan }
function Write-Note { param([string]$Text) Write-Host "    $Text" -ForegroundColor DarkGray }
function Write-Warn { param([string]$Text) Write-Host "    $Text" -ForegroundColor Yellow }

Write-Host ''
Write-Host '  zt - Zellij workspace rig' -ForegroundColor Cyan
Write-Host "  $repo" -ForegroundColor DarkGray
Write-Host ''

# --- 0. Zellij itself --------------------------------------------------------
# Everything below writes config FOR Zellij, so without it this script cheerfully
# reports success and the first thing you run - zac - is the thing that fails.
# The old behaviour mentioned winget only in bootstrap.ps1, unconditionally,
# AFTER the install had already finished: too late to prevent the problem and
# shown to people who did not have it.
function Get-ZellijVersion {
    # Resolve fresh each call: after a winget install, PATH in THIS process is
    # still the old one, so a cached lookup would report "still missing" and
    # send you round the loop again.
    $cmd = Get-Command zellij -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    try {
        $raw = & zellij --version 2>&1 | Out-String
        if ($raw -match '(\d+)\.(\d+)(?:\.(\d+))?') {
            # No ?? here. This file must PARSE under Windows PowerShell 5.1 to
            # reach the version check below - a parse error happens before any
            # line runs, so 7-only syntax anywhere turns the friendly message
            # into a stack trace. Same rule the scripts/ headers state.
            $patch = $Matches[3]
            if (-not $patch) { $patch = '0' }
            return [version]("{0}.{1}.{2}" -f $Matches[1], $Matches[2], $patch)
        }
    } catch { }
    return [version]'0.0'
}

function Sync-PathFromRegistry {
    # winget updates the stored PATH, not the one this process started with.
    $parts = @(
        [Environment]::GetEnvironmentVariable('Path', 'Machine')
        [Environment]::GetEnvironmentVariable('Path', 'User')
    ) | Where-Object { $_ }
    if ($parts) { $env:PATH = ($parts -join ';') }
}

if (-not $SkipZellijCheck) {
    Write-Step '[0/3] Zellij'
    $zv = Get-ZellijVersion

    if ($zv -and $zv -ge $MinZellij) {
        Write-Note "$zv"
    } else {
        if ($zv) { Write-Warn "Zellij $zv is older than $MinZellij, the first native Windows release." }
        else     { Write-Warn 'Zellij is not on PATH.' }

        $winget = Get-Command winget -ErrorAction SilentlyContinue
        $doIt   = $false

        if ($InstallZellij) {
            $doIt = $true
        } elseif (-not $winget) {
            Write-Warn 'winget is not available either - install it from https://zellij.dev'
        } else {
            # Only ask when there is somebody there to answer. Under -NonInteractive
            # (CI, a hook, an agent shell) a prompt reads EOF and would either hang
            # or throw, turning a warning into a failed install.
            $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
            if ($interactive) {
                $doIt = $PSCmdlet.ShouldContinue(
                    'Install it now with: winget install zellij', 'Zellij is required')
            } else {
                Write-Warn 'Run: winget install zellij     (or pass -InstallZellij)'
            }
        }

        if ($doIt -and $winget -and $PSCmdlet.ShouldProcess('zellij', 'winget install')) {
            Write-Note 'winget install zellij ...'
            & winget install --id zellij --accept-source-agreements --accept-package-agreements
            Sync-PathFromRegistry
            $zv = Get-ZellijVersion
            if ($zv -and $zv -ge $MinZellij) { Write-Note "installed: $zv" }
            else { Write-Warn 'Still not resolvable here - REOPEN this shell, then re-run.' }
        }

        if (-not $zv -or $zv -lt $MinZellij) {
            Write-Warn 'Carrying on: the module and config are written either way,'
            Write-Warn 'and work as soon as Zellij is there.'
        }
    }
}

# --- 1. the module ----------------------------------------------------------
Write-Step '[1/3] PowerShell module'

$moduleSource = Join-Path $repo (Join-Path 'module' 'ZellijTerminal')
if (-not (Test-Path -LiteralPath $moduleSource)) { throw "Module not found at $moduleSource" }

Remove-Module ZellijTerminal -Force -ErrorAction SilentlyContinue
Import-Module $moduleSource -Force

$splat = @{}
if ($ModulePath) { $splat['ModulePath'] = $ModulePath }
if ($Force)      { $splat['Force']      = $true }

# Recorded, not just printed. Install-ZellijTerminal reports a refusal - an
# existing junction pointing at a different clone, say - with Write-Error, which
# is not terminating, so the script carried on and still printed "Done. Next:
# zac ..." at the end. The one step that makes `zt` exist had failed and the
# installer congratulated you. Found by running bootstrap.ps1 against a second
# clone; see $problems at the bottom.
Install-ZellijTerminal @splat -ErrorVariable moduleError -ErrorAction SilentlyContinue
if ($moduleError) {
    foreach ($e in $moduleError) { Write-Warn $e.Exception.Message }
    $problems += "the module was not installed: $($moduleError[0].Exception.Message)"
}

# --- 2. Zellij config and layout -------------------------------------------
if (-not $SkipZellijConfig) {
    Write-Step '[2/3] Zellij config and layout'

    # Note the extra `config` level. Getting this wrong means Zellij reads
    # nothing and reports nothing, which looks like the config being ignored.
    $zjConfigDir = Join-Path $env:APPDATA (Join-Path 'Zellij' 'config')
    $zjLayoutDir = Join-Path $zjConfigDir 'layouts'
    $zjPluginDir = Join-Path $env:APPDATA (Join-Path 'Zellij' (Join-Path 'data' 'plugins'))

    foreach ($d in @($zjConfigDir, $zjLayoutDir, $zjPluginDir)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }

    $cfgSrc = Join-Path $repo (Join-Path 'zellij' 'config.kdl')
    $cfgDst = Join-Path $zjConfigDir 'config.kdl'
    if ($PSCmdlet.ShouldProcess($cfgDst, 'Write Zellij config')) {
        if (Test-Path -LiteralPath $cfgDst) {
            Copy-Item -LiteralPath $cfgDst -Destination "$cfgDst.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak" -Force
            Write-Note 'existing config backed up'
        }
        Copy-Item -LiteralPath $cfgSrc -Destination $cfgDst -Force
        Write-Note $cfgDst
    }

    # The layout carries an absolute plugin path, so it is a template.
    $layTpl = Join-Path $repo (Join-Path 'zellij' (Join-Path 'layouts' 'claude.kdl.template'))
    $layDst = Join-Path $zjLayoutDir 'claude.kdl'
    if ($PSCmdlet.ShouldProcess($layDst, 'Write the claude layout')) {
        $lay = Get-Content -LiteralPath $layTpl -Raw
        $lay = $lay.Replace('{{PLUGINS}}', ($zjPluginDir -replace '\\', '/'))
        $lay = $lay.Replace('{{REPO}}',    ($repo       -replace '\\', '/'))
        $lay = $lay.Replace('{{HOME}}',    ($HOME       -replace '\\', '/'))
        Set-Content -LiteralPath $layDst -Value $lay -Encoding UTF8
        Write-Note $layDst
    }

    if (-not (Test-Path -LiteralPath (Join-Path $zjPluginDir 'zjstatus.wasm'))) {
        Write-Note 'zjstatus.wasm not present - the status bar will not render.'
        Write-Note "  download it from github.com/dj95/zjstatus/releases into"
        Write-Note "  $zjPluginDir"
    }

    # --- the Terminal profile, so the session tab carries Zellij's icon ------
    #
    # A tab launched from a bare command line has no profile, so Terminal draws
    # it with the generic console icon - which reads as "it opened in cmd" while
    # the command line right there says pwsh. `zac` passes --profile to fix
    # that; this is what makes the profile exist.
    #
    # A FRAGMENT, not an edit to settings.json: that file is JSONC and belongs
    # to the user, and a read-modify-write through ConvertTo-Json would strip
    # every comment in it. Uninstalling is deleting one file.
    #
    # The icon is EXTRACTED FROM THE INSTALLED zellij.exe rather than committed.
    # Zellij is a hard prerequisite, so the asset is always there; shipping a
    # copy would mean redistributing someone else's mark in a public repo, and
    # baking an absolute path into a tracked file is exactly what
    # Placeholders.Tests.ps1 exists to catch. Derive it, and the path is this
    # machine's own.
    #
    # Terminal reads fragments at STARTUP. Until it restarts, `wt -p
    # zellij-terminal` falls back to the default profile - which is why
    # Get-ZtWtProfile gates on Terminal having discovered it, not on this file
    # existing.
    $fragDir  = Join-Path $env:LOCALAPPDATA (Join-Path 'Microsoft' (Join-Path 'Windows Terminal' (Join-Path 'Fragments' 'ZellijTerminal')))
    $fragFile = Join-Path $fragDir 'zellij-terminal.json'
    $iconDir  = Join-Path $env:LOCALAPPDATA 'ZellijTerminal'
    $iconFile = Join-Path $iconDir 'zellij-logo.png'

    if ($PSCmdlet.ShouldProcess($fragFile, 'Write the Windows Terminal profile fragment')) {
        $zjExe = $null
        $zjCmd = Get-Command zellij -ErrorAction SilentlyContinue
        if ($zjCmd) { $zjExe = $zjCmd.Source }

        $icon = $null
        if ($zjExe) {
            try {
                Add-Type -AssemblyName System.Drawing -ErrorAction Stop
                if (-not (Test-Path -LiteralPath $iconDir)) {
                    New-Item -ItemType Directory -Path $iconDir -Force | Out-Null
                }

                # PrivateExtractIcons, not ExtractAssociatedIcon: the latter is
                # hardcoded to 32x32, and zellij.exe carries a 256 - verified.
                # A tab renders at 16-24px, so 32 is only enough until somebody
                # looks at it on a high-DPI display.
                if (-not ('ZtIconExtract' -as [type])) {
                    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ZtIconExtract {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern int PrivateExtractIcons(string file, int index, int cx, int cy,
                                               IntPtr[] handles, int[] ids, int count, int flags);
}
'@ -ErrorAction Stop
                }

                $ico = $null
                foreach ($size in 256, 128, 64, 48, 32) {
                    $h  = New-Object IntPtr[] 1
                    $id = New-Object int[] 1
                    if (([ZtIconExtract]::PrivateExtractIcons($zjExe, 0, $size, $size, $h, $id, 1, 0) -gt 0) -and
                        ($h[0] -ne [IntPtr]::Zero)) {
                        $ico = [System.Drawing.Icon]::FromHandle($h[0])
                        break
                    }
                }
                # Whatever Windows associates, when the binary carries nothing.
                if (-not $ico) { $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($zjExe) }

                if ($ico) {
                    $bmp = $ico.ToBitmap()
                    try   { $bmp.Save($iconFile, [System.Drawing.Imaging.ImageFormat]::Png); $icon = $iconFile }
                    finally { $bmp.Dispose(); $ico.Dispose() }
                }
            } catch {
                # No icon is not a failure. The profile still gives the tab
                # pwsh's icon, which is already better than the generic one.
                Write-Note "could not read zellij's icon ($($_.Exception.Message))"
            }
        }

        if (-not (Test-Path -LiteralPath $fragDir)) {
            New-Item -ItemType Directory -Path $fragDir -Force | Out-Null
        }

        $wtProfile = [ordered]@{
            name                     = 'zellij-terminal'
            commandline              = 'pwsh.exe -NoLogo -NoExit -Command "zellij attach --create claude"'
            startingDirectory        = '%USERPROFILE%'
            suppressApplicationTitle = $true
        }
        if ($icon) { $wtProfile['icon'] = $icon }

        @{ profiles = @($wtProfile) } | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $fragFile -Encoding UTF8

        Write-Note $fragFile
        if ($icon) { Write-Note "icon extracted from $zjExe" }
        Write-Note 'Terminal reads fragments at startup - restart it to pick this up'
    }
}

# --- 3. the Claude Code hook ------------------------------------------------
if (-not $SkipHook) {
    Write-Step '[3/3] Claude Code hook'

    $hookTpl = Join-Path $repo (Join-Path 'hooks' 'settings.hooks.template.json')

    # Repo scope writes the file outright, because we own it. Global scope must
    # MERGE: %USERPROFILE%\.claude\settings.json is where permissions, plugins,
    # effortLevel and autoMode live, and replacing it to add a hooks block would
    # be a spectacular way to lose all of that.
    $claudeDir = if ($Global) { Join-Path $HOME '.claude' } else { Join-Path $repo '.claude' }
    $hookDst   = Join-Path $claudeDir 'settings.json'

    if (-not (Test-Path -LiteralPath $claudeDir)) {
        New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
    }

    if ($PSCmdlet.ShouldProcess($hookDst, 'Write the hook config')) {
        if (Test-Path -LiteralPath $hookDst) {
            Copy-Item -LiteralPath $hookDst -Destination "$hookDst.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak" -Force
            Write-Note 'existing settings backed up'
        }

        $hook = Get-Content -LiteralPath $hookTpl -Raw
        $hook = $hook.Replace('{{REPO}}', ($repo -replace '\\', '/'))

        if ($Global) {
            $incoming = $hook | ConvertFrom-Json
            $merged   = $null
            if (Test-Path -LiteralPath $hookDst) {
                try { $merged = Get-Content -LiteralPath $hookDst -Raw | ConvertFrom-Json } catch {
                    throw ("$hookDst is not valid JSON, so it cannot be merged into. " +
                           'Fix or move it and re-run; the backup above is untouched.')
                }
            }
            if (-not $merged) { $merged = [pscustomobject]@{} }

            # Replace the hooks key wholesale rather than merging event by event.
            # A half-updated hooks block - some events pointing at an old clone -
            # is worse than either state, and the backup covers the loss of any
            # hooks that were there before.
            $merged | Add-Member -NotePropertyName 'hooks' -NotePropertyValue $incoming.hooks -Force

            # Depth matters: autoMode.environment and permissions.allow nest
            # further than the default of 2, which would silently stringify them.
            $merged | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $hookDst -Encoding UTF8

            Write-Note $hookDst
            Write-Note 'GLOBAL: fires for every project on this machine, not just this repo'
        } else {
            Set-Content -LiteralPath $hookDst -Value $hook -Encoding UTF8
            Write-Note $hookDst
            Write-Note 'this registers the hook for THIS repo only - re-run with'
            Write-Note '-Global to register it for every project instead'
        }
    }
}

# --- done -------------------------------------------------------------------
Remove-Module ZellijTerminal -Force -ErrorAction SilentlyContinue
Import-Module ZellijTerminal -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($problems.Count -gt 0) {
    Write-Host "  Finished with $($problems.Count) problem(s):" -ForegroundColor Red
    Write-Host ''
    foreach ($p in $problems) { Write-Host "    $p" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '    zt check           what works and what does not' -ForegroundColor White
    Write-Host ''
    # Non-zero, so a script or a CI step calling this notices. bootstrap.ps1
    # printing "keep the clone" after a failed install was the visible symptom;
    # an exit code is what stops the next thing in the chain from assuming.
    exit 1
}

Write-Host '  Done. Next:' -ForegroundColor Green
Write-Host ''
Write-Host '    zt setup           guided - explains each layer, offers to do it' -ForegroundColor White
Write-Host '    zac                start or attach the session' -ForegroundColor White
Write-Host '    zt add .           register a project folder' -ForegroundColor White
Write-Host '    zt check           verify every layer' -ForegroundColor White
Write-Host ''
Write-Host '  Optional:' -ForegroundColor DarkGray
Write-Host '    zt pad explain     what the macro pad is for' -ForegroundColor DarkGray
Write-Host '    zt palette         what the Command Palette extension adds' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  To remove it again:  zt uninstall -WhatIf' -ForegroundColor DarkGray
Write-Host ''
