<#
    Guide - the guided setup, and the two explanations it leans on.

    zt check tells you what is broken. It assumes you already know what the
    layers ARE. That is fine on the second machine and useless on the first,
    where the honest questions are "what is a macro pad doing in a terminal
    tool", "why would I want the Command Palette part", and "which of these do I
    actually need". Nothing answered those, so the optional layers read as
    mandatory-but-broken, and the pad in particular looked like a hardware
    requirement rather than an optional convenience.

    So: Start-ZellijTerminalSetup walks the layers in dependency order, explains
    each one before offering to do it, and never does anything without asking.
    The explanations are separate functions because they are worth reading on
    their own - `zt pad explain` when the keys stop working, `zt palette` when
    you are deciding whether to build the extension at all.

    Nothing here is required. Everything here is skippable, and says so.
#>

function Get-ZtInteractive {
    <#
        Whether there is a human present to answer.

        UserInteractive alone is not enough: under -NonInteractive, in CI, in a
        hook, or in an agent's shell, stdin is redirected and a prompt reads EOF.
        Asking anyway turns an offer into a crash, so every prompt in this file
        goes through here and falls back to printing the command instead.
    #>
    return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
}

function Read-ZtYesNo {
    param([string]$Question, [string]$Instead)

    if (-not (Get-ZtInteractive)) {
        if ($Instead) { Write-Host "      run: $Instead" -ForegroundColor DarkGray }
        return $false
    }
    Write-Host ''
    $a = Read-Host "      $Question [y/N]"
    return ($a -match '^(y|yes)$')
}

function Write-ZtGuideStep {
    param([string]$N, [string]$Title, [string]$State, [string]$Colour = 'DarkGray')
    Write-Host ''
    Write-Host ("  {0}  {1}" -f $N, $Title) -ForegroundColor Cyan
    if ($State) { Write-Host ("      {0}" -f $State) -ForegroundColor $Colour }
}

function Write-ZtGuideText {
    param([string[]]$Lines)
    foreach ($l in $Lines) { Write-Host "      $l" -ForegroundColor Gray }
}

function Show-ZellijTerminalPadGuide {
    <#
    .SYNOPSIS
        What the macro pad is, what the four keys do, and whether you need one.

    .DESCRIPTION
        Answers the question the rest of the docs skip: why does a terminal
        workspace tool care about a lump of plastic with four keys on it?

    .EXAMPLE
        zt pad explain
    #>
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-Host '  The macro pad' -ForegroundColor Cyan
    Write-Host '  -------------' -ForegroundColor DarkGray
    Write-Host ''
    Write-ZtGuideText @(
        'Optional. Everything works without it; this only removes reaching for'
        'the keyboard.'
        ''
        'The problem it solves: you have several Claude Code sessions running in'
        'tabs, and they stop to ask permission at unpredictable moments. Noticing'
        'which one is waiting, switching to it, and answering is three actions,'
        'and the first one needs you to be looking. Four keys collapse that to'
        'one press you can make without leaving what you are reading.'
        ''
        'Any device that can send a keyboard chord will do - a macro pad, a'
        'programmable keyboard layer, a foot pedal, a stream deck. There is no'
        'specific hardware here. Program it to send these four:'
    )
    Write-Host ''
    foreach ($k in (Get-ZtPadKeyMap)) {
        Write-Host ("      {0}  {1,-16} {2}" -f $k.Key, $k.Chord, $k.Does) -ForegroundColor White
    }
    Write-Host ''
    Write-ZtGuideText @(
        'Keys 1 and 2 answer the session you are looking at. They inject a'
        'keystroke straight into the focused tab, which is why they work even'
        'when the window is not focused, and why they are the fastest path -'
        'about 60 ms, with no PowerShell in the way.'
        ''
        'Key 3 is the one that needs the Claude Code hook, because "whoever is'
        'waiting" is knowledge only the hook has. Without it that key has nothing'
        'to jump to and will say so rather than pretending.'
        ''
        'Key 4 cycles project tabs and skips the ones that are not projects.'
        ''
        'Windows has no way to bind a chord globally on its own, so a listener'
        'does it: PowerToys Keyboard Manager by default, AutoHotkey if you prefer.'
        'Use one, never both - two listeners on the same chord double-fire every'
        'press, which reads as the pad stuttering.'
    )
    Write-Host ''
    Write-Host '      Set it up:  zt pad install       Check it:  zt pad' -ForegroundColor DarkGray
    Write-Host '      Diagnose:   zt pad probe' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '      After installing, toggle Keyboard Manager off and on in' -ForegroundColor Yellow
    Write-Host '      PowerToys Settings. Its engine reads the config when it' -ForegroundColor Yellow
    Write-Host '      starts, never when the file changes.' -ForegroundColor Yellow
    Write-Host ''
}

function Show-ZellijTerminalPaletteGuide {
    <#
    .SYNOPSIS
        What the Command Palette extension is for, and whether to build it.

    .DESCRIPTION
        The extension is the only part of this rig that needs a compiler, so it
        deserves an explanation of what you get before you install a .NET SDK for
        it.

    .EXAMPLE
        zt palette
    #>
    [CmdletBinding()]
    param()

    $installed = $null
    try { $installed = Get-AppxPackage ZellijTerminal.Palette -ErrorAction SilentlyContinue } catch { }

    Write-Host ''
    Write-Host '  The Command Palette extension' -ForegroundColor Cyan
    Write-Host '  -----------------------------' -ForegroundColor DarkGray
    Write-Host ''
    Write-ZtGuideText @(
        'Optional. It puts the workspace list inside PowerToys Command Palette,'
        'so Win+Alt+Space then a few letters gets you to a session without a'
        'terminal to type zt into.'
        ''
        'What it adds:'
        '  - every workspace, with live state, searchable'
        '  - start / stop / restart / close on each row, with shortcuts'
        '  - a folder picker that registers a new project and opens it'
        '  - jump-to-waiting, when something needs an answer'
        '  - a dock band, so the list is on screen without opening anything'
        ''
        'It reads the same registry the module does and shells out to the same'
        'commands, so it cannot drift from what zt does in a terminal.'
        ''
        'Cost of entry: the .NET 10 SDK, and a one-time elevated command to trust'
        'the self-signed certificate it builds with. The build refuses to install'
        'until you run that, with the exact line to paste.'
    )
    Write-Host ''
    if ($installed) {
        Write-Host ("      Installed: version {0}" -f $installed.Version) -ForegroundColor Green
        Write-Host '      Rebuild after changes:  cmdpal\pack.ps1' -ForegroundColor DarkGray
    } else {
        Write-Host '      Not installed.' -ForegroundColor DarkGray
        Write-Host '      Build and install:  cmdpal\pack.ps1' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '      Restart Command Palette after installing, or it keeps' -ForegroundColor Yellow
    Write-Host '      running the extension it loaded at startup.' -ForegroundColor Yellow
    Write-Host ''
}

function Start-ZellijTerminalSetup {
    <#
    .SYNOPSIS
        Guided setup: walk every layer, explain it, offer to do it.

    .DESCRIPTION
        Dependency order, because a broken layer makes everything below it look
        broken too - the same rule zt check states. Each step says what the layer
        is for, whether it is required or optional, and what it would change
        before changing it.

        Answers nothing on your behalf. With no human present (CI, a hook, an
        agent shell) it prints the command it would have offered and moves on, so
        it is safe to run unattended as a report.

    .EXAMPLE
        zt setup
        zt setup -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Session = 'claude'
    )

    $repo = Get-ZtRoot

    Write-Host ''
    Write-Host '  zt - guided setup' -ForegroundColor Cyan
    Write-Host "  $repo" -ForegroundColor DarkGray
    Write-Host ''
    Write-ZtGuideText @(
        'Six layers, in the order they depend on each other. The first three are'
        'required; the last three are optional and say so. Nothing is changed'
        'without asking.'
    )

    # --- 1. Zellij ----------------------------------------------------------
    $zv = $null
    $zcmd = Get-Command zellij -ErrorAction SilentlyContinue
    if ($zcmd) {
        $raw = (& zellij --version 2>&1 | Out-String)
        if ($raw -match '(\d+)\.(\d+)') { $zv = [version]("{0}.{1}" -f $Matches[1], $Matches[2]) }
    }

    if ($zv -and $zv -ge [version]'0.44') {
        Write-ZtGuideStep '1/6' 'Zellij            REQUIRED' "found $zv" 'Green'
    } else {
        Write-ZtGuideStep '1/6' 'Zellij            REQUIRED' $(if ($zv) { "found $zv - too old" } else { 'not on PATH' }) 'Yellow'
        Write-ZtGuideText @(
            'The terminal multiplexer everything else drives. 0.44 is the first'
            'release with native Windows support; earlier ones are not "mostly'
            'fine", they are the wrong platform.'
        )
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            if (Read-ZtYesNo 'Install Zellij now with winget?' 'winget install zellij') {
                if ($PSCmdlet.ShouldProcess('zellij', 'winget install')) {
                    & winget install --id zellij --accept-source-agreements --accept-package-agreements
                    Write-Host '      Reopen this shell afterwards so PATH is picked up.' -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host '      winget not available - see https://zellij.dev' -ForegroundColor DarkGray
        }
    }

    # --- 2. Config and layout -----------------------------------------------
    $layout = Join-Path $env:APPDATA (Join-Path 'Zellij' (Join-Path 'config' (Join-Path 'layouts' 'claude.kdl')))
    if (Test-Path -LiteralPath $layout) {
        Write-ZtGuideStep '2/6' 'Config and layout REQUIRED' 'deployed' 'Green'
    } else {
        Write-ZtGuideStep '2/6' 'Config and layout REQUIRED' 'not deployed' 'Yellow'
        Write-ZtGuideText @(
            'Zellij reads its config from your profile, not from this repo, and'
            'the layout carries absolute paths - so it is generated rather than'
            'committed. install.ps1 writes both.'
        )
        if (Read-ZtYesNo 'Write them now?' '.\install.ps1') {
            if ($PSCmdlet.ShouldProcess($layout, 'Write Zellij config and layout')) {
                & (Join-Path $repo 'install.ps1') -SkipHook -SkipZellijCheck
            }
        }
    }

    # --- 3. The hook --------------------------------------------------------
    $globalHook = $false
    $gp = Join-Path $HOME (Join-Path '.claude' 'settings.json')
    if (Test-Path -LiteralPath $gp) {
        try { $globalHook = $null -ne ((Get-Content -LiteralPath $gp -Raw | ConvertFrom-Json).hooks) } catch { }
    }

    if ($globalHook) {
        Write-ZtGuideStep '3/6' 'Claude Code hook  REQUIRED' 'registered globally - fires for every project' 'Green'
    } else {
        Write-ZtGuideStep '3/6' 'Claude Code hook  REQUIRED' 'not registered globally' 'Yellow'
        Write-ZtGuideText @(
            'How a session tells the rig what it is doing. Without it a workspace'
            'never reports that it is waiting, so the status bar stays empty and'
            'jump-to-waiting has nothing to find - and none of that announces'
            'itself, it just looks like the pad is broken.'
            ''
            'Registered in one project it fires only there. Registered globally it'
            'fires everywhere, which is almost always what you want, at the cost'
            'of a short-lived powershell.exe per event in every session.'
        )
        if (Read-ZtYesNo 'Register the hook for every project?' '.\install.ps1 -Global') {
            if ($PSCmdlet.ShouldProcess($gp, 'Register the hook globally')) {
                & (Join-Path $repo 'install.ps1') -Global -SkipZellijConfig -SkipZellijCheck
            }
        }
    }

    # --- 4. Session ---------------------------------------------------------
    if (Test-ZtSession -Session $Session) {
        $attached = Test-ZtClientAttached -Session $Session
        if ($attached) { Write-ZtGuideStep '4/6' "Session '$Session'   REQUIRED" 'running, terminal attached' 'Green' }
        else {
            Write-ZtGuideStep '4/6' "Session '$Session'   REQUIRED" 'running, but NOTHING attached' 'Yellow'
            Write-ZtGuideText @(
                'With no terminal attached every Zellij action silently does'
                'nothing and still reports success. This is the single most'
                'confusing state the rig has.'
            )
            if (Read-ZtYesNo 'Open a window on it?' 'zac') {
                if ($PSCmdlet.ShouldProcess($Session, 'Attach')) { Connect-ZellijTerminal -Session $Session }
            }
        }
    } else {
        Write-ZtGuideStep '4/6' "Session '$Session'   REQUIRED" 'not started' 'Yellow'
        Write-ZtGuideText @('One Zellij session holds every workspace as a tab.')
        if (Read-ZtYesNo 'Start it now?' 'zac') {
            if ($PSCmdlet.ShouldProcess($Session, 'Start')) { Connect-ZellijTerminal -Session $Session }
        }
    }

    # --- 5. The pad ---------------------------------------------------------
    # Count OUR remaps, not every global remap: Keyboard Manager is a general
    # tool and a user with unrelated shortcuts of their own is not "set up".
    # Get-ZtKbmGlobal needs the config passed in - calling it bare returns empty
    # and silently reports a wired pad as missing.
    $mapped = @(Get-ZtKbmGlobal (Get-ZtKbmConfig) | Where-Object { Test-ZtKbmOurs $_ }).Count
    if ($mapped -gt 0) {
        Write-ZtGuideStep '5/6' 'Macro pad         OPTIONAL' "$mapped remap(s) configured" 'Green'
        Write-Host '      Explain it:  zt pad explain' -ForegroundColor DarkGray
    } else {
        Write-ZtGuideStep '5/6' 'Macro pad         OPTIONAL' 'not wired up' 'DarkGray'
        Show-ZellijTerminalPadGuide
        if (Read-ZtYesNo 'Wire the four chords up through PowerToys now?' 'zt pad install') {
            if ($PSCmdlet.ShouldProcess('Keyboard Manager', 'Write the pad remaps')) {
                Install-ZellijTerminalPad
            }
        }
    }

    # --- 6. The palette -----------------------------------------------------
    $pkg = $null
    try { $pkg = Get-AppxPackage ZellijTerminal.Palette -ErrorAction SilentlyContinue } catch { }
    if ($pkg) {
        Write-ZtGuideStep '6/6' 'Command Palette   OPTIONAL' "installed, version $($pkg.Version)" 'Green'
        Write-Host '      Explain it:  zt palette' -ForegroundColor DarkGray
    } else {
        Write-ZtGuideStep '6/6' 'Command Palette   OPTIONAL' 'not installed' 'DarkGray'
        Show-ZellijTerminalPaletteGuide
        $sdk = $false
        try { $sdk = @(& dotnet --list-sdks 2>$null | Where-Object { $_ -match '^10\.' }).Count -gt 0 } catch { }
        if (-not $sdk) {
            Write-Host '      Needs the .NET 10 SDK:  winget install Microsoft.DotNet.SDK.10' -ForegroundColor DarkGray
        } elseif (Read-ZtYesNo 'Build and install the extension now?' 'cmdpal\pack.ps1') {
            if ($PSCmdlet.ShouldProcess('ZellijTerminal.Palette', 'Build and install')) {
                & (Join-Path $repo (Join-Path 'cmdpal' 'pack.ps1'))
            }
        }
    }

    # --- done ---------------------------------------------------------------
    Write-Host ''
    Write-Host '  Done. Verify with:' -ForegroundColor Green
    Write-Host '    zt check           every layer, independently' -ForegroundColor White
    Write-Host '    zt add .           register the folder you are in' -ForegroundColor White
    Write-Host ''
}
