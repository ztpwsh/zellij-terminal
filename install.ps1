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
    # already in that file; your permissions and plugins are left alone, and so
    # are any hooks in it that are not ours - only entries running
    # claude-zj-hook.ps1 are replaced.
    [switch]$Global,

    # Replace an existing module junction that points somewhere else.
    [switch]$Force,

    # Install Zellij with winget if it is missing, without asking. For
    # unattended runs; interactively you get a prompt instead.
    [switch]$InstallZellij,

    # Do not look for Zellij at all.
    [switch]$SkipZellijCheck,

    # Write the zjstatus permission grant even though a Zellij server is
    # running. The refusal exists because the server rewrites that file when it
    # exits, so a grant written underneath a live session is undone minutes
    # later - but the check is a process check, and a process is only a proxy
    # for the real question, which is whether that server shares THIS profile.
    # It does not when %LOCALAPPDATA% is redirected, which is how the test
    # suite runs the installer, and it need not when you are about to delete
    # every session anyway.
    [switch]$SkipServerCheck
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

function Test-ZtOwnHookEntry {
    <#
        Is one entry of a Claude Code `hooks.<Event>` array OURS?

        SECOND COPY of Test-ZtOwnHookEntry in
        module/ZellijTerminal/Private/Core.ps1, which explains the reasoning.
        It is duplicated rather than imported because this script runs BEFORE
        the module is installed - creating the junction is its own job - and
        under Windows PowerShell 5.1. tests/Hooks.Tests.ps1 pins the two
        together; if the marker in one drifts from the other, install and
        uninstall disagree about which entries belong to this rig, and the
        visible result is either somebody else's hooks deleted or two zt hooks
        firing per event.
    #>
    param($Entry)

    if ($null -eq $Entry) { return $false }

    # Every field here is optional in somebody else's hook. This script does not
    # set StrictMode, but the module copy runs under 2.0 where reading an absent
    # property throws - and the two have to CLASSIFY IDENTICALLY, so they are
    # written identically rather than each being as loose as its own file allows.
    $names = @()
    try { $names = @($Entry.PSObject.Properties | ForEach-Object { $_.Name }) } catch { return $false }
    if ($names -notcontains 'hooks') { return $false }

    foreach ($h in @($Entry.hooks)) {
        if ($null -eq $h) { continue }
        $hn = @()
        try { $hn = @($h.PSObject.Properties | ForEach-Object { $_.Name }) } catch { continue }

        if (($hn -contains 'command') -and $h.command -and ($h.command -like '*claude-zj-hook*')) {
            return $true
        }
        if ($hn -contains 'args') {
            foreach ($a in @($h.args)) {
                if ($a -and ($a -like '*claude-zj-hook*')) { return $true }
            }
        }
    }
    return $false
}

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
    Write-Step '[0/4] Zellij'
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
Write-Step '[1/4] PowerShell module'

$moduleSource = Join-Path $repo (Join-Path 'module' 'ZellijTerminal')
if (-not (Test-Path -LiteralPath $moduleSource)) { throw "Module not found at $moduleSource" }

# THIS SCRIPT CANNOT BE CALLED IN-PROCESS FROM THE MODULE. A script invoked
# with `&` from a module function runs inside that module's session state, so
# the line below throws away the scope holding this script's own functions -
# Write-Step, Write-Note, Write-Warn - and the run dies further down on one of
# them being "not recognized", having used it seconds earlier. `zt setup` did
# exactly this and could not complete a single offer. Invoke-ZtInstaller in
# module/ZellijTerminal/Public/Guide.ps1 is the supported way in, and it starts
# a child pwsh. Run from a shell, this is fine and always was.
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
    Write-Step '[2/4] Zellij config and layout'

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

    # --- the plugin permission grant ----------------------------------------
    #
    # ZELLIJ GATES PLUGINS BEHIND A PERMISSION, AND THIS RIG CANNOT ANSWER THE
    # PROMPT IN PRACTICE. Without a grant, zjstatus loads and is held pending
    # approval. The prompt DOES render - as a single line across the top row,
    # "This plugin asks permission to: ... Allow? (y/n)", perfectly legible.
    # What it cannot get is the keypress: the session starts in locked mode
    # with focus in the terminal pane below, so `y` goes to whatever is running
    # there rather than to the plugin. It reads as a banner rather than a
    # question, and it sits unanswered forever.
    #
    # An earlier version of this comment claimed the dialog could not draw in
    # one row. That was wrong, and it was wrong in eight files: a screenshot
    # from the machine this was diagnosed on shows it rendering fine. The
    # failure is input, not output, and the distinction matters to anyone
    # trying to answer it by hand.
    #
    # It went unnoticed for months because the grant is acquired INTERACTIVELY,
    # once, and then lives in a cache directory outside both the clone and
    # %APPDATA%. Every development machine had one; nothing that ships did, and
    # no test could see the difference. Found on a second PC where the whole rig
    # checked out clean and the bar was simply absent.
    #
    # Keyed by the plugin's absolute path with forward slashes - Zellij's own
    # form, taken from a file it wrote itself - so the grant is per machine and
    # copying the file between them grants nothing.
    #
    # Written even when the wasm is not there yet. The grant is a statement
    # about a path, so downloading the plugin afterwards then works without a
    # second install - which is the order the first machine to hit this
    # actually did it in.
    $permDir  = Join-Path $env:LOCALAPPDATA (Join-Path 'Zellij' 'cache')
    $permPath = Join-Path $permDir 'permissions.kdl'
    $permKey  = (Join-Path $zjPluginDir 'zjstatus.wasm') -replace '\\', '/'
    $permBody = @(
        ('"' + $permKey + '" {')
        '    ReadApplicationState'
        '    ChangeApplicationState'
        '    RunCommands'
        '}'
    ) -join [Environment]::NewLine

    if ($PSCmdlet.ShouldProcess($permPath, 'Grant zjstatus its Zellij plugin permissions')) {

        $permText = ''
        if (Test-Path -LiteralPath $permPath) {
            $permText = Get-Content -LiteralPath $permPath -Raw
            if (-not $permText) { $permText = '' }
        }

        # ALREADY GRANTED IS THE FIRST QUESTION, and it is asked before the
        # server check below, because a machine that is already correct must
        # not be told to close its sessions for a write that would change
        # nothing. Matched on the key rather than the whole block: ZELLIJ
        # REWRITES THIS FILE IN ITS OWN ORDER. Observed - the installer writes
        # Read, Change, Run and the file came back Change, Run, Read, which is
        # how we know the server owns it rather than us.
        $alreadyGranted = $false
        if ($permText -and ($permText -match [regex]::Escape('"' + $permKey + '"'))) {
            $alreadyGranted = $true
        }

        # THE ZELLIJ SERVER OWNS THIS FILE WHILE IT RUNS. It holds its
        # permission state in memory and writes its own copy back when it
        # exits, so a grant written underneath a live session is replaced by
        # the state that session started with - and the repair silently undoes
        # itself minutes later, which is indistinguishable from it never having
        # worked.
        #
        # THIS CHECK USED TO RUN AFTER THE WRITE, as a warning. That is the
        # wrong order and it is worse than useless: by the time it printed, the
        # file was already on disk and already doomed, and the message read as
        # advice about next time rather than as a statement that this run had
        # just failed. It refuses now, records a problem so the closing banner
        # cannot say "Done", and names the fix.
        $zjProc = @()
        if (-not $SkipServerCheck) {
            $zjProc = @(Get-Process -Name 'zellij' -ErrorAction SilentlyContinue)
        }

        if ($alreadyGranted) {
            Write-Note "$permPath (already granted)"
        } elseif ($zjProc.Count -gt 0) {
            Write-Warn "NOT granted: a zellij server is running ($($zjProc.Count) process(es))."
            Write-Warn 'It rewrites this file when it exits, so writing now would be undone.'
            Write-Warn ''
            Write-Warn '  zellij delete-session <name> --force     for every session listed by'
            Write-Warn '  zellij list-sessions                     then re-run this installer'
            Write-Warn ''
            Write-Warn 'DELETE, not kill. A killed session stays resurrectable, and'
            Write-Warn '`attach --create` resurrects it rather than reading the layout - so'
            Write-Warn 'the grant is never re-evaluated and the status bar never appears.'
            $problems += ('zjstatus was not granted its Zellij permission, because a zellij ' +
                          'server is running and would overwrite it. Close every session with ' +
                          'delete-session and re-run; until then there is no status bar.')
        } else {
            if (-not (Test-Path -LiteralPath $permDir)) {
                New-Item -ItemType Directory -Path $permDir -Force | Out-Null
            }

            # MERGE, never replace. This file is Zellij's and can hold grants
            # for other plugins the user has approved by hand; dropping those
            # would silently revoke them and produce this same invisible
            # failure somewhere else. Drop only a previous entry for THIS path,
            # so a re-install re-states the grant instead of accumulating
            # duplicates.
            $escaped = [regex]::Escape('"' + $permKey + '"')
            $permNew = [regex]::Replace($permText, '(?ms)^[ \t]*' + $escaped + '[ \t]*\{.*?\}[ \t]*\r?\n?', '')
            $permNew = $permNew.TrimEnd()
            if ($permNew -ne '') { $permNew = $permNew + [Environment]::NewLine }
            $permNew = $permNew + $permBody + [Environment]::NewLine

            if ($permText -ne '') {
                Copy-Item -LiteralPath $permPath -Destination "$permPath.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak" -Force
            }
            Set-Content -LiteralPath $permPath -Value $permNew -Encoding UTF8
            Write-Note "$permPath (zjstatus granted)"

            # A grant is read when a session STARTS. An existing session -
            # including an exited one, which resurrects - will not pick this up.
            Write-Note 'a session already running will not see this: delete it, do not kill it'
        }
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
    Write-Step '[3/4] Claude Code hook'

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

            # Replace OUR entries, event by event, and leave everybody else's
            # alone. This used to replace the whole `hooks` key, on the reasoning
            # that a half-updated block - some events still pointing at an old
            # clone - is worse than either state. That reasoning is right about
            # OUR entries and wrong about anybody else's: `hooks` is a shared
            # key, so a user with a formatter hook or a plugin's hooks
            # registered globally lost them to a zt install, silently, with only
            # a timestamped .bak to recover from.
            #
            # Selecting ours by script name gets both: every zt entry goes,
            # including one left at a path this clone has never been at, so a
            # moved or re-cloned install replaces its old registration instead
            # of firing twice.
            $existing = $null
            if ($merged.PSObject.Properties.Name -contains 'hooks') { $existing = $merged.hooks }

            $events = @()
            if ($existing) { $events += @($existing.PSObject.Properties.Name) }
            $events += @($incoming.hooks.PSObject.Properties.Name)
            $events = @($events | Select-Object -Unique)

            $result      = [pscustomobject]@{}
            $foreignKept = 0
            $ourOldPaths = @()

            foreach ($ev in $events) {
                $keep = @()
                if ($existing -and ($existing.PSObject.Properties.Name -contains $ev)) {
                    foreach ($entry in @($existing.$ev)) {
                        if (Test-ZtOwnHookEntry $entry) {
                            foreach ($h in @($entry.hooks)) {
                                foreach ($a in @($h.args)) {
                                    if ($a -and ($a -like '*claude-zj-hook*')) { $ourOldPaths += $a }
                                }
                            }
                        } else {
                            $keep += $entry
                            $foreignKept++
                        }
                    }
                }
                if ($incoming.hooks.PSObject.Properties.Name -contains $ev) {
                    $keep += @($incoming.hooks.$ev)
                }
                if ($keep.Count -gt 0) {
                    $result | Add-Member -NotePropertyName $ev -NotePropertyValue @($keep) -Force
                }
            }

            $merged | Add-Member -NotePropertyName 'hooks' -NotePropertyValue $result -Force

            # Depth matters: autoMode.environment and permissions.allow nest
            # further than the default of 2, which would silently stringify them.
            $merged | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $hookDst -Encoding UTF8

            Write-Note $hookDst
            Write-Note 'GLOBAL: fires for every project on this machine, not just this repo'

            # Say what was found, not just what was written. The installer used
            # to announce the scope it had just used while never having read the
            # file, so it reported "THIS repo only" on machines where zt was
            # already registered globally - true about its own action, and
            # actively misleading about the state of the machine.
            if ($foreignKept -gt 0) {
                Write-Note "$foreignKept hook entries here are not ours - left untouched"
            }
            $ourOldPaths = @($ourOldPaths | Select-Object -Unique)
            $stale = @($ourOldPaths | Where-Object { $_ -notlike "*$($repo -replace '\\', '/')/hooks/*" })
            if ($stale.Count -gt 0) {
                Write-Note "replaced a previous zt registration pointing at: $($stale -join ', ')"
            } elseif ($ourOldPaths.Count -gt 0) {
                Write-Note 'zt was already registered globally here - re-stamped at the same path'
            }
        } else {
            Set-Content -LiteralPath $hookDst -Value $hook -Encoding UTF8
            Write-Note $hookDst
            Write-Note 'this registers the hook for THIS repo only - re-run with'
            Write-Note '-Global to register it for every project instead'

            # ...unless it is already global, in which case saying "THIS repo
            # only" without qualification reads as "your other projects are not
            # covered", which is the opposite of the truth.
            $globalDst = Join-Path $HOME (Join-Path '.claude' 'settings.json')
            if (Test-Path -LiteralPath $globalDst) {
                $globalRaw = Get-Content -LiteralPath $globalDst -Raw -ErrorAction SilentlyContinue
                if ($globalRaw -and ($globalRaw -like '*claude-zj-hook*')) {
                    Write-Note 'NOTE: zt is ALREADY registered globally in'
                    Write-Note "      $globalDst - every project is already covered"
                }
            }
        }
    }
}

# --- 4. verify what was just written ----------------------------------------
#
# AN INSTALLER THAT REPORTS SUCCESS WITHOUT READING BACK ITS OWN OUTPUT IS
# GUESSING. This one printed "Done. Next: zac" on a machine with no status bar,
# nine times in one evening, because every step it took returned without
# throwing. Not throwing is not the same as having worked: a grant written
# under a live Zellij server is deleted minutes later by that server, and a
# layout written with an unsubstituted marker is a file that exists and does
# nothing.
#
# So every claim this script makes is now re-read from disk before the banner.
# It checks ONLY what this script is responsible for - not whether a session is
# running or a client is attached, which are `zt check`'s business and are
# legitimately false one second after an install.
Write-Step '[4/4] Verifying'

$verified = $true
function Test-ZtClaim {
    param([string]$What, [bool]$Ok, [string]$Detail)
    if ($Ok) {
        Write-Note "OK   $What"
    } else {
        Write-Warn "BAD  $What - $Detail"
        $script:verified = $false
        $script:problems += "$What - $Detail"
    }
}

# Ask about the destination THIS RUN used, not about the name.
#
# The first version of this check called Get-Module -ListAvailable, which
# searches $env:PSModulePath - so with -ModulePath pointing anywhere else it
# reported BAD on a perfectly good install, and on a developer's machine it
# reported OK because a ZellijTerminal was already on that path from some
# earlier install. Passing for a reason unrelated to what the installer just
# did is the exact failure this whole verification step exists to catch, and it
# was caught by CI within minutes of shipping, on a runner with no pre-existing
# module. Worth leaving written down: the machine you develop on is the one
# machine that cannot tell you whether your install works.
#
# The destination is asked of the MODULE rather than recomputed here.
# Resolve-ZtUserModulePath does not guess: it takes the user-scope entry
# already on PSModulePath, because Documents is redirected under OneDrive on
# some profiles - including one of this project's own machines - and a guessed
# path installs where PowerShell never looks. Writing a second version of that
# rule here would be a fourth copy of it, and this repo already pins three
# copies of one path rule together for exactly this reason.
#
# It is not exported, so it is called inside the module's own scope. The module
# was imported from source in step 1; if that failed, the failure is already in
# $problems and there is nothing here to verify.
$modZt = Get-Module ZellijTerminal
if ($modZt) {
    $modBase = $ModulePath
    if (-not $modBase) { $modBase = & $modZt { Resolve-ZtUserModulePath } }
    $modDest = Join-Path $modBase 'ZellijTerminal'
    Test-ZtClaim 'zt module installed' (Test-Path -LiteralPath $modDest) "nothing at $modDest - re-run with -Force"
}

if (-not $SkipZellijConfig) {
    $zjConfigDir2 = Join-Path $env:APPDATA (Join-Path 'Zellij' 'config')
    $layDst2      = Join-Path $zjConfigDir2 (Join-Path 'layouts' 'claude.kdl')
    $cfgDst2      = Join-Path $zjConfigDir2 'config.kdl'

    Test-ZtClaim 'Zellij config written' (Test-Path -LiteralPath $cfgDst2) "missing at $cfgDst2"
    Test-ZtClaim 'claude layout written' (Test-Path -LiteralPath $layDst2) "missing at $layDst2"

    if (Test-Path -LiteralPath $layDst2) {
        $layCheck = Get-Content -LiteralPath $layDst2 -Raw
        if (-not $layCheck) { $layCheck = '' }

        # An unreplaced marker is the silent one: the file is there, it parses,
        # and the status bar never loads while the tab opens in the wrong
        # directory. Documented in docs/05-usage.md and never checked until now.
        $leftovers = @([regex]::Matches($layCheck, '\{\{[A-Z_]+\}\}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
        Test-ZtClaim 'layout fully substituted' ($leftovers.Count -eq 0) (
            'still contains ' + ($leftovers -join ', ') + ' - the status bar will not load and tabs open in the wrong place')

        # The plugin path in the layout must be the one the grant names. These
        # are computed in two places in this script and could drift.
        $locMatch = [regex]::Match($layCheck, 'location="file:([^"]+)"')
        if ($locMatch.Success) {
            $locFs = ($locMatch.Groups[1].Value -replace '/', '\')
            $grantText = ''
            if (Test-Path -LiteralPath $permPath) {
                $grantText = Get-Content -LiteralPath $permPath -Raw
                if (-not $grantText) { $grantText = '' }
            }
            $grantOk = $grantText -match [regex]::Escape(($locFs -replace '\\', '/'))
            Test-ZtClaim 'zjstatus permitted' $grantOk (
                "no grant for the path the layout names. Close every session with " +
                "``zellij delete-session <name> --force`` and re-run; until then there is no status bar")

            if (-not (Test-Path -LiteralPath $locFs)) {
                # NOT a failure: this script does not download the plugin, and
                # says so above. But it must not be silent either.
                Write-Warn "note: $locFs is not there yet - the bar appears once you download it"
            }
        }
    }
}

if (-not $SkipHook) {
    $claudeDir2 = Join-Path $repo '.claude'
    if ($Global) { $claudeDir2 = Join-Path $HOME '.claude' }
    $hookDst2 = Join-Path $claudeDir2 'settings.json'

    $hookOk = $false
    if (Test-Path -LiteralPath $hookDst2) {
        $hookBack = Get-Content -LiteralPath $hookDst2 -Raw
        # Read the PATH back out and test it, rather than trusting that a file
        # mentioning the hook is a file pointing at one that exists. A stamped
        # path survives the clone moving, and a hook whose script is gone fails
        # per event, in the background, where nobody is looking.
        $hookOk = $hookBack -match 'claude-zj-hook'
        foreach ($m in [regex]::Matches($hookBack, '"([^"]*claude-zj-hook[^"]*)"')) {
            if (-not (Test-Path -LiteralPath $m.Groups[1].Value)) { $hookOk = $false }
        }
    }
    Test-ZtClaim 'Claude Code hook registered' $hookOk "no working claude-zj-hook entry in $hookDst2"
}

if ($verified -and $problems.Count -eq 0) {
    Write-Note 'every file this installer wrote was read back and is correct'
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
