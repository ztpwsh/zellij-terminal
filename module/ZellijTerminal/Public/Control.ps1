<#
    Control - start, stop, restart, move between, attach.

    A note on how Stop works, because it is not obvious. There is no way to ask
    Zellij for the PID running in a pane, and no way to signal one. What there
    is, is injection: focus the tab and write bytes into it, which this rig has
    already proved works even when the terminal is unfocused or minimised
    (measured at ~60 ms). So Stop types Ctrl+C, exactly as you would.

    That has one hard prerequisite: a client must be ATTACHED. With nothing
    attached, write / write-chars / go-to-tab-name are silent no-ops that still
    exit 0, so a Stop against a detached session would cheerfully report success
    having done nothing. Every function here checks first.
#>

function Start-ZellijTerminal {
    <#
    .SYNOPSIS
        Open a workspace - create its tab and run its command.

    .DESCRIPTION
        Never duplicates. If the workspace is already running, this focuses it
        and says so; if its tab exists but nothing is running in it, the command
        is typed into that shell rather than opening a second tab.

    .EXAMPLE
        zt start api
        Start-ZellijTerminal api -Resume     # continue the previous Claude session
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        # Omit it and you get the picker.
        [Parameter(Position = 0)]
        [string]$Name,

        # For claude workspaces: resume the last session in that folder rather
        # than starting a fresh one. The session id comes from the hook.
        [switch]$Resume,

        # Resume this specific session. -Resume normally reads the id from the
        # live record, but Restore has to clear that record first (or Start
        # would think the workspace is still running), so it passes the id in.
        [string]$SessionId,

        # Create the tab but do not run anything in it.
        [switch]$NoCommand,

        [string]$Session = 'claude',
        [string]$Prefix  = 'claude-'
    )

    $ws = Resolve-ZtTarget -Name $Name -Title 'Start which workspace?' -Session $Session -Prefix $Prefix
    if (-not $ws) { return }

    if ($ws.State -eq 'unavailable') {
        Write-Error ("'$($ws.Id)' is not available on $(Get-ZtDeviceName). " +
                     "Path: $($ws.Path). Define its root with Set-ZellijTerminalRoot.")
        return
    }

    # An unregistered tab has no directory - Zellij will not report one - so
    # there is nothing to open it in. Stop and close still work on it, because
    # those act on the tab name; only starting needs to know where it lives.
    if ($ws.State -eq 'unregistered' -or -not $ws.Path) {
        Write-Error ("'$($ws.Id)' is a tab with no registered directory, so there is nowhere to " +
                     "start it. Register it against its folder first, from inside that folder:" +
                     "`n    zt add . -Name $($ws.Tab)" +
                     "`nStopping and closing it work regardless.")
        return
    }

    if ($ws.State -eq 'running') {
        Write-Host "'$($ws.Id)' is already running - focusing it." -ForegroundColor Yellow
        Invoke-ZtZellij -Session $Session -ZArgs @('go-to-tab-name', (Get-ZtLiveTabName -Session $Session -Base $ws.Tab)) | Out-Null
        return
    }

    # What to run.
    $sid = $SessionId
    if (-not $sid) { $sid = $ws.Session }

    $cmd = ''
    if (-not $NoCommand) {
        if ($ws.Kind -eq 'claude') {
            # The tab keeps its claude- prefix; the session does not. See
            # Get-ZtSessionName - this name is what shows on mobile and desktop.
            $sessionName = Get-ZtSessionName -Tab $ws.Tab -Prefix $Prefix
            $cmd = "claude --name '$sessionName'"
            if ($Resume) {
                if ($sid) {
                    $cmd = "claude --resume $sid --name '$sessionName'"
                } else {
                    Write-Warning "No recorded Claude session for '$($ws.Id)' - starting a fresh one."
                }
            }
        } else {
            # A pwsh workspace with no command is deliberate - "a shell in this
            # folder" - so this is not the anomaly it once was and does not
            # warn. The tab opens, the prompt is yours.
            $cmd = $ws.Command
        }
    }

    # The tab is already there - type into it rather than opening a second one.
    # This is the path Restart takes, and the reason Stop leaves a live shell.
    if ($ws.State -eq 'tab-only' -or $ws.State -eq 'stale') {
        if (-not (Test-ZtClientAttached -Session $Session)) {
            Write-Error ("Nothing is attached to session '$Session', so typing into a tab would " +
                         "silently do nothing. Run zac first.")
            return
        }
        if (-not $PSCmdlet.ShouldProcess("tab '$($ws.Tab)'", "Run: $cmd")) { return }

        if ($cmd) {
            if (-not (Send-ZtKeys -Session $Session -Tab $ws.Tab -Text $cmd -Enter)) {
                Write-Error ("Could not focus tab '$($ws.Tab)', so nothing was typed. The command " +
                             "would otherwise have been typed into whatever tab is focused.")
                return
            }
            Set-ZtLive -Key $ws.Key -Cwd $ws.Path -Tab $ws.Tab -Kind $ws.Kind -SessionId $sid
            Write-Host "Started '$($ws.Id)' in its existing tab." -ForegroundColor Green
        } else {
            Invoke-ZtZellij -Session $Session -ZArgs @('go-to-tab-name', (Get-ZtLiveTabName -Session $Session -Base $ws.Tab)) | Out-Null
        }
        return
    }

    if (-not $PSCmdlet.ShouldProcess("session '$Session'", "Open '$($ws.Id)' as tab '$($ws.Tab)'")) { return }

    # Tab creation stays in zj-claude-project.ps1 - the pad and the hook use
    # that script directly and it must remain the one implementation.
    $splat = @{
        Add     = $ws.Path
        TabName = $ws.Tab
        Session = $Session
        Prefix  = $Prefix
    }
    if ($cmd) { $splat['Command'] = $cmd }

    & (Get-ZtScript 'zj-claude-project.ps1') @splat

    if ($cmd) {
        Set-ZtLive -Key $ws.Key -Cwd $ws.Path -Tab $ws.Tab -Kind $ws.Kind
    }
}

function Stop-ZellijTerminal {
    <#
    .SYNOPSIS
        Stop what is running in a workspace, leaving the tab as a shell.

    .DESCRIPTION
        Types Ctrl+C into the tab. The pane runs pwsh -NoExit, so what you are
        left with is a prompt in the right directory - the workspace is still
        there, just idle. Use Remove-ZellijTerminalTab to close the tab itself,
        or Unregister-ZellijTerminal to forget the workspace entirely.

    .EXAMPLE
        zt stop api
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        # Omit it and you get the picker.
        [Parameter(Position = 0)]
        [string]$Name,

        [string]$Session = 'claude',
        [string]$Prefix  = 'claude-'
    )

    $ws = Resolve-ZtTarget -Name $Name -Title 'Stop which workspace?' -Session $Session -Prefix $Prefix
    if (-not $ws) { return }

    if ($ws.State -eq 'stopped' -or $ws.State -eq 'unavailable') {
        Write-Host "'$($ws.Id)' is not running." -ForegroundColor Yellow
        return
    }

    if (-not (Test-ZtClientAttached -Session $Session)) {
        Write-Error ("Nothing is attached to session '$Session'. Ctrl+C would be swallowed and this " +
                     "would report a success that did not happen. Run zac first.")
        return
    }

    if (-not $PSCmdlet.ShouldProcess("tab '$($ws.Tab)'", "Send Ctrl+C to stop '$($ws.Id)'")) { return }

    # Twice, with a gap: Claude Code treats a single Ctrl+C as "clear the input
    # line" and only exits on a second one. For a plain command the second is
    # harmless at a bare prompt.
    if (-not (Send-ZtKeys -Session $Session -Tab $ws.Tab -Bytes @(3))) {
        Write-Error ("Could not focus tab '$($ws.Tab)', so nothing was sent. Refusing to report a " +
                     "stop that did not happen - Ctrl+C would have gone to whatever tab is focused.")
        return
    }
    Start-Sleep -Milliseconds 300
    Send-ZtKeys -Session $Session -Tab $ws.Tab -Bytes @(3) | Out-Null

    # SAY WHAT WAS SENT, NOT WHAT WAS ACHIEVED. Ctrl+C arriving in the right tab
    # is the whole of what this can observe: whether the program took it, took
    # it slowly, or ignored it is not visible from out here. This used to print
    # "Stopped 'x' - tab 'x' is now a shell", a claim about the other end of the
    # wire that nothing checked.
    #
    # The live record is what `zt` reads to decide the state, so it is removed:
    # the session was told to stop and the record would otherwise outlive the
    # truth either way. The hook rewrites it in seconds if the session is still
    # alive, which is the self-correcting half.
    Remove-ZtLive $ws.Key
    Write-Host "Sent Ctrl+C twice to tab '$($ws.Tab)' for '$($ws.Id)'." -ForegroundColor Green
    Write-Host "  Run zt to see whether it took - a session that ignores it stays listed as running." -ForegroundColor DarkGray
}

function Restart-ZellijTerminal {
    <#
    .SYNOPSIS
        Stop a workspace and start it again in the same tab.

    .DESCRIPTION
        For claude workspaces this resumes the previous session by default, so
        you get the same conversation back rather than a blank one. -Fresh
        opts out.

    .EXAMPLE
        zt restart api
        Restart-ZellijTerminal api -Fresh
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        # Omit it and you get the picker.
        [Parameter(Position = 0)]
        [string]$Name,

        # Start a new Claude session instead of resuming the old one.
        [switch]$Fresh,

        [string]$Session = 'claude',
        [string]$Prefix  = 'claude-'
    )

    $ws = Resolve-ZtTarget -Name $Name -Title 'Restart which workspace?' -Session $Session -Prefix $Prefix
    if (-not $ws) { return }

    if (-not $PSCmdlet.ShouldProcess("'$($ws.Id)'", 'Restart')) { return }

    # Capture the session id before Stop clears the live record.
    $sessionId = $ws.Session

    if ($ws.State -eq 'running' -or $ws.State -eq 'tab-only') {
        Stop-ZellijTerminal -Name $ws.Id -Session $Session -Prefix $Prefix -Confirm:$false
        Start-Sleep -Milliseconds 400
    }

    $resume = $false
    if (-not $Fresh -and $ws.Kind -eq 'claude' -and $sessionId) { $resume = $true }

    Start-ZellijTerminal -Name $ws.Id -Session $Session -Prefix $Prefix -Resume:$resume -Confirm:$false
}

function Remove-ZellijTerminalTab {
    <#
    .SYNOPSIS
        Close a workspace's tab, keeping it registered.

    .DESCRIPTION
        Wraps zj-claude-project.ps1 -Remove, which focuses the target first
        (close-tab acts on the focused tab) and verifies afterwards that exactly
        the intended tab disappeared.

    .EXAMPLE
        zt close api
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        # Omit it and you get the picker.
        [Parameter(Position = 0)]
        [string]$Name,

        [string]$Session = 'claude',
        [string]$Prefix  = 'claude-'
    )

    $ws = Resolve-ZtTarget -Name $Name -Title 'Close which tab?' -Session $Session -Prefix $Prefix
    if (-not $ws) { return }

    if (-not $PSCmdlet.ShouldProcess("tab '$($ws.Tab)'", 'Close')) { return }

    & (Get-ZtScript 'zj-claude-project.ps1') -Remove $ws.Tab -Session $Session -Prefix $Prefix
    Remove-ZtLive $ws.Key
}

function Sync-ZellijTerminal {
    <#
    .SYNOPSIS
        Reconcile the registry against what is actually running, and drop what
        is not.

    .DESCRIPTION
        Live records outlive their tabs when a terminal is closed with the X
        button rather than detached. Those show as 'stale'. This clears them.

    .EXAMPLE
        zt sync
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Session = 'claude',
        [string]$Prefix  = 'claude-'
    )

    $records = Get-ZtWorkspaceRecords -Session $Session -Prefix $Prefix
    $stale   = @($records | Where-Object { $_.State -eq 'stale' })

    $cleared = 0

    foreach ($s in $stale) {
        if ($PSCmdlet.ShouldProcess("'$($s.Id)'", 'Clear stale live record')) {
            Remove-ZtLive $s.Key
            Write-Host "Cleared stale record for '$($s.Id)'" -ForegroundColor DarkGray
            $cleared++
        }
    }

    # Waiting flags whose tab does not exist.
    #
    # The hook derives the tab name from the cwd Claude reports, so a session
    # that changes directory mid-flight raises a hand for a tab that was never
    # created - it happened during this rig's own development, leaving a flag
    # for 'claude-ZellijTerminal.CmdPal'. Harmless, but it makes the waiting
    # queue lie, and key 3 exists to trust that queue.
    $tabs    = @(Get-ZtTabNames -Session $Session)
    $flagDir = Join-Path $env:TEMP 'claude-zellij-flags'
    if (Test-Path -LiteralPath $flagDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $flagDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
            $tab = [IO.Path]::GetFileNameWithoutExtension($f.Name)
            if ($tabs -contains $tab) { continue }
            if ($PSCmdlet.ShouldProcess($tab, 'Clear waiting flag for a tab that does not exist')) {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                Write-Host "Cleared orphan flag for '$tab'" -ForegroundColor DarkGray
                $cleared++
            }
        }
    }

    if ($cleared -eq 0) { Write-Host 'Nothing stale.' -ForegroundColor Green }
}

function Switch-ZellijTerminal {
    <#
    .SYNOPSIS
        Jump to the workspace waiting for you, or cycle the tabs.

    .DESCRIPTION
        Wraps scripts\zj-claude-tab.ps1. The macro pad calls that script
        directly rather than this function, so key presses do not pay for a
        module import.

    .EXAMPLE
        zt waiting
        Switch-ZellijTerminal prev
    #>
    [CmdletBinding(DefaultParameterSetName = 'Cycle')]
    param(
        [Parameter(ParameterSetName = 'Cycle', Position = 0)]
        [ValidateSet('next', 'prev')]
        [string]$Direction = 'next',

        [Parameter(ParameterSetName = 'Waiting', Mandatory = $true)]
        [switch]$Waiting,

        [string]$Session = 'claude',
        [string]$Pattern = 'claude*'
    )

    $script = Get-ZtScript 'zj-claude-tab.ps1'
    if ($Waiting) {
        & $script -Waiting -Session $Session -Pattern $Pattern
    } else {
        & $script -Direction $Direction -Session $Session -Pattern $Pattern
    }
}

function Connect-ZellijTerminal {
    <#
    .SYNOPSIS
        Show the session - attaching if nothing is viewing it, or bringing the
        existing window forward if something already is.

    .DESCRIPTION
        The session runs on a server with no window of its own. Tabs keep
        working with nothing attached, which is the trap: list-sessions says the
        session is fine while list-clients is empty, and in that state
        go-to-tab-name, close-tab and write-chars are silent no-ops that still
        exit 0. So the pad does nothing and there is no error to explain it.

        The window is a NAMED Windows Terminal window (`wt -w claude`): naming
        it is what makes it findable later, since Windows Terminal offers no way
        to focus a specific tab from outside. That handle only works on a window
        this command opened, so it leaves a marker in the state directory -
        without it, "something is attached" would be read as "my window exists"
        and `wt -w claude focus-tab` against a window that never existed opens a
        blank one.

        Opening a second window on an attached session is never what you want:
        Zellij mirrors, so you get two clients on one session showing the same
        pane, and every keystroke lands in both. It also pins the grid to the
        smallest client, so resizing either window stops doing anything - which
        surfaces as "the text will not reflow" and sends you looking at the
        wrong layer entirely. So every path that ends in `focus-tab` watches for
        a Terminal window APPEARING - across all three channels, stable, Preview
        and Canary - to find out whether that focused a window or conjured a
        blank one. That includes the path where the marker exists: the marker
        says a window was opened once, not that it is still there, and when it
        turns out to be stale the marker is deleted rather than trusted again.
        Nothing here concludes from an exit code; `wt` returns 0 either way.
    .NOTES
        If a cold `zt attach` opens TWO windows, the cause is not here: Windows
        Terminal's "firstWindowPreference": "persistedWindowLayout" restores the
        saved layout when the FIRST window opens, and the saved layout is a
        window already running `zellij attach`. The command line is honoured on
        top of it. `zt check` reports this; the fix is "defaultProfile" in
        Terminal's settings.

    .EXAMPLE
        zac
        Connect-ZellijTerminal -Here
    #>
    [CmdletBinding()]
    param(
        # Attach in the current shell rather than opening a Terminal window.
        [switch]$Here,

        [string]$Session = 'claude',

        # The Windows Terminal window name. Defaults to the SESSION name rather
        # than a literal 'claude': the Command Palette attaches every session
        # with -Session only, so a fixed default made a second session's attach
        # raise the claude window instead of its own. Identical for every
        # default caller, since Session is 'claude' too.
        [string]$Window,

        # What the Windows Terminal TAB says. Not the window handle above and
        # not the session name: the tab names what is running in it, and what is
        # running in it is this rig.
        [string]$Title = 'zellij-terminal'
    )

    if ($env:ZELLIJ) {
        $inside = $env:ZELLIJ_SESSION_NAME
        if (-not $inside) { $inside = '(unknown)' }
        Write-Host "You are already inside a Zellij session: $inside" -ForegroundColor Yellow
        return
    }

    if ($Here) {
        # --create, never `--session x --layout y`: with --session, --layout
        # means "add these tabs to the existing session" and fails outright on a
        # session that does not exist yet.
        & zellij attach --create $Session
        return
    }

    if (-not (Get-Command wt -ErrorAction SilentlyContinue)) {
        Write-Warning 'wt.exe not found - attaching in this shell instead.'
        & zellij attach --create $Session
        return
    }

    $windowGiven = $PSBoundParameters.ContainsKey('Window')
    if (-not $windowGiven) { $Window = $Session }

    $attached = Test-ZtClientAttached -Session $Session

    $stateDir  = Join-Path $env:TEMP 'claude-zellij-status'
    $marker    = Join-Path $stateDir "wt-window-$Session.txt"
    $ownWindow = $false
    if (Test-Path -LiteralPath $marker) {
        $ownWindow = $true
        if (-not $windowGiven) {
            $recorded = (Get-Content -LiteralPath $marker -Raw).Trim()
            if ($recorded) { $Window = $recorded }
        }
    }

    if ($attached) {
        # WHAT CAN AND CANNOT BE CHECKED HERE, all of it demonstrated on 0.44.3
        # with Windows Terminal 1.23 rather than reasoned about:
        #
        #   `wt -w <unknown> focus-tab -t 0` exits 0 and does NOTHING. It does
        #   not conjure a window - watched for three seconds, no process and no
        #   window appeared. The comment this function used to carry, that
        #   focus-tab "creates the window when the name is unknown", is true of
        #   new-tab and not of this.
        #
        #   Terminal hosts EVERY WINDOW IN ONE PROCESS. Opening a second window
        #   left the process count at 1 and simply moved that process's
        #   MainWindowHandle. So the before/after window count this code used to
        #   run could never rise, `$after -le $before` was always true, and the
        #   branch handling "it made a window instead" was unreachable. It
        #   reported success unconditionally - a check that cannot fail, which
        #   is worse than no check, because it reads like evidence.
        #
        # So there is no observable for "did that window come forward", and this
        # says what it did rather than what it achieved. The failure mode is a
        # silent no-op - nothing comes forward and nothing is broken - which is
        # why guessing the name is cheap and why the marker is worth keeping.
        #
        # What IS answerable: whether a Windows Terminal is hosting a view of
        # THIS session. A zellij client is a process, and walking up from it
        # reaches the terminal that owns its tab - so the question stops being
        # "does any Terminal window exist somewhere on this machine", which was
        # true even when the client was attached from a different terminal
        # application entirely, and raising a window did nothing for the session
        # being asked about.
        if (Get-ZtTerminalHostingSession -Session $Session) {
            & wt -w $Window focus-tab -t 0
            Write-Host "Session '$Session' is already attached - asked Terminal to raise window '$Window'." -ForegroundColor DarkGray
            if (-not $ownWindow) {
                if (-not (Test-Path -LiteralPath $stateDir)) {
                    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
                }
                Set-Content -LiteralPath $marker -Value $Window -Encoding UTF8
            }
            return
        } else {
            Write-Host ("Session '$Session' has a client, but no Windows Terminal is hosting it - it is " +
                        "attached from somewhere else. Opening a window here; close the other client if " +
                        "one appears, because zellij mirrors and the grid is pinned to the smaller.") -ForegroundColor Yellow
        }
    } else {
        Write-Host "Nothing was attached to '$Session' - opening a window on it." -ForegroundColor Green
    }

    # Read BEFORE the launch, because the only honest evidence that this worked
    # is a client arriving that was not there a moment ago.
    $clientsBefore = Get-ZtClientCount -Session $Session

    # Scrub the Claude Code environment before `attach --create`, because THIS
    # is the process that starts the zellij SERVER when the session does not
    # exist yet, and every pane inherits the server's environment for as long as
    # that server lives. Claude Code sets both of these for the commands it
    # runs, so asking Claude to set this rig up - which the zt-setup skill tells
    # you to do - otherwise bakes them into the session permanently:
    #
    #   NO_COLOR=1                  every pane renders black and white
    #   CLAUDE_CODE_CHILD_SESSION=1 Claude reports "Transcript saving is off"
    #
    # The pane prelude clears both, which covers `home` and everything `zt
    # start` opens. It does NOT cover a tab opened with Zellij's own keybinding:
    # that uses new_tab_template, a bare `pane` with no prelude, so it inherits
    # the server copy and misbehaves while every other tab looks fine - the
    # worst shape of bug this rig gets, because the working tabs argue that the
    # setup is sound. Clearing here fixes the source; the prelude stays as the
    # belt to this braces, since the server may have been started by hand.
    #
    # Restored afterwards so this only affects the child, not the caller.
    $inherited = @{}
    foreach ($v in 'NO_COLOR', 'CLAUDE_CODE_CHILD_SESSION') {
        $cur = [Environment]::GetEnvironmentVariable($v)
        if ($cur) {
            $inherited[$v] = $cur
            Remove-Item "Env:$v" -ErrorAction SilentlyContinue
        }
    }
    try {
        # --profile anchors the tab to a real profile so it gets that profile's
        # ICON. Without it the tab is built from a bare command line, Terminal
        # has no profile to draw from, and a pwsh session renders with the
        # generic console icon - which reads as "it opened in cmd" even though
        # the command line right there says pwsh. Omitted entirely when the
        # default cannot be read, which is the pre-0.7.2 behaviour.
        $wtArgs = @('-w', $Window, 'new-tab', '--title', $Title)
        $prof   = Get-ZtWtProfile
        if ($prof) { $wtArgs += @('--profile', $prof) }
        $wtArgs += @('pwsh', '-NoLogo', '-NoExit', '-Command', "zellij attach --create $Session")

        & wt @wtArgs
    } finally {
        foreach ($k in $inherited.Keys) { [Environment]::SetEnvironmentVariable($k, $inherited[$k]) }
    }

    # NOT $LASTEXITCODE. wt.exe hands the tab off to Terminal and returns 0
    # immediately; it does not wait for the tab and cannot know whether `zellij
    # attach --create` ever ran inside it. Recording the window on that exit
    # code is the same mistake this function spends three branches refusing to
    # make about focus-tab. The observable is a client arriving on the session.
    #
    # Rises ABOVE the count read before the launch, rather than merely being
    # non-zero, so the recovery path - where a client was already attached and
    # this tab is the second - is judged on its own arrival. -1 means zellij
    # could not answer at all, which is why the count must also be positive.
    $arrived = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 100
        $now = Get-ZtClientCount -Session $Session
        if ($now -gt 0 -and $now -gt $clientsBefore) { $arrived = $true; break }
    }

    if ($arrived) {
        if (-not (Test-Path -LiteralPath $stateDir)) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        }
        Set-Content -LiteralPath $marker -Value $Window -Encoding UTF8
    } else {
        Write-Warning ("A Terminal tab was opened, but nothing has attached to '$Session' within 4s. " +
                       "No window was recorded, so the next zac starts from the verified path rather " +
                       "than trusting this one. If the tab is showing an error, that is where the reason is.")
    }
}
