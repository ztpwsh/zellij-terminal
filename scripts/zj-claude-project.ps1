<#
.SYNOPSIS
    Add, remove and list Claude Code project tabs in the Zellij session at
    runtime, so the layout file doesn't have to be edited for every project.

.DESCRIPTION
    Tabs are named <Prefix><leaf>, where <leaf> is the project directory's leaf
    folder name - the same convention claude-zj-hook.ps1 derives from the cwd
    Claude Code passes on stdin, and the same one zj-claude-tab.ps1 cycles.
    Because all three derive the name the same way, adding a project needs no
    configuration anywhere else.

    Compatible with Windows PowerShell 5.1 - no ternary, no ??, no && / ||.

    A NOTE ON REMOVAL
      `zellij action close-tab` closes the FOCUSED tab, not a named one - the
      same trap as `rename-tab` (see docs/00-background.md). So -Remove has to
      focus the target first, which means it changes which tab you are looking
      at. That is unavoidable via the CLI. -Remove refuses to run unless the
      name matches <Prefix>* so a stray argument cannot close a tab you did not mean.

.EXAMPLE
    # from inside a project directory
    .\zj-claude-project.ps1 -Add .

.EXAMPLE
    .\zj-claude-project.ps1 -Add C:\code\api
    .\zj-claude-project.ps1 -List
    .\zj-claude-project.ps1 -Remove api
    .\zj-claude-project.ps1 -Remove claude-api   # either form works

.EXAMPLE
    # Dry run first - every mutation supports -WhatIf and -Confirm
    .\zj-claude-project.ps1 -Remove api -WhatIf

.EXAMPLE
    # Reuse the project list you already curate as Windows Terminal profiles
    .\zj-claude-project.ps1 -FromBookmarks
    .\zj-claude-project.ps1 -FromBookmarks -Filter 'web*' -Launch

.NOTES
    Conventions borrowed from profile-bookmarking tools, which solve the same
    shape of problem for Windows Terminal profiles:

      * SupportsShouldProcess on everything that mutates, so -WhatIf / -Confirm
        work. close-tab is destructive and focus-dependent; it deserves a dry run.
      * Only touch what you own. That module filters by a GUID prefix so it can
        never disturb a hand-made profile. Zellij tabs carry no metadata to
        stamp, so the equivalent guard here is the name prefix - weaker, hence
        the before/after check on -Remove as a second line of defence.
      * Write-Warning, not throw, for "no match". Not finding something is
        usually a typo, not a crash.
      * Reading JSON-derived objects under Set-StrictMode throws on absent
        properties. Test with PSObject.Properties.Name -contains first.
#>

[CmdletBinding(DefaultParameterSetName = 'List', SupportsShouldProcess = $true)]
param(
    [Parameter(ParameterSetName = 'Add', Mandatory = $true, Position = 0)]
    [string]$Add,

    [Parameter(ParameterSetName = 'Remove', Mandatory = $true, Position = 0)]
    [string]$Remove,

    [Parameter(ParameterSetName = 'List')]
    [switch]$List,

    # Add a tab for every Windows Terminal profile that names a starting
    # directory, so a project list you already maintain there drives the Zellij
    # tabs too. No third-party module required - a bookmarks module curates
    # these same profiles.
    [Parameter(ParameterSetName = 'FromBookmarks', Mandatory = $true)]
    [Alias('FromTerminalProfiles')]
    [switch]$FromBookmarks,

    [Parameter(ParameterSetName = 'FromBookmarks')]
    [string]$Filter = '*',

    # Take every profile with a starting directory, not just the ones that
    # already launch Claude. Claude-only by default: a profile list also holds
    # SSH sessions and one-click shells, and importing those turns a curated
    # list into noise you then have to undo. Skips are always reported.
    [Parameter(ParameterSetName = 'FromBookmarks')]
    [switch]$IncludeAll,

    # Start Claude Code in the new tab rather than leaving a shell prompt.
    [Parameter(ParameterSetName = 'Add')]
    [Parameter(ParameterSetName = 'FromBookmarks')]
    [switch]$Launch,

    # Create the tab but stay where you are.
    [Parameter(ParameterSetName = 'Add')]
    [switch]$NoFocus,

    # Override the derived <Prefix><leaf> tab name. The registry passes this
    # when two projects share a leaf folder name and would otherwise both claim
    # the same tab - go-to-tab-name would then pick one arbitrarily and the pad
    # would answer the wrong session.
    [Parameter(ParameterSetName = 'Add')]
    [string]$TabName,

    # Run this in the tab instead of `claude`. Implies -Launch. This is how a
    # workspace of kind 'pwsh' starts whatever it starts.
    [Parameter(ParameterSetName = 'Add')]
    [string]$Command,

    [string]$Session = 'claude',
    [string]$Prefix  = 'claude-'
)

$ErrorActionPreference = 'Stop'
$flagDir = Join-Path $env:TEMP 'claude-zellij-flags'

# ---------------------------------------------------------------------------
#  Pane prelude - runs in every tab this script creates
# ---------------------------------------------------------------------------
#  TERM / COLORTERM
#    Zellij on Windows sets NEITHER in the pane environment - verified with a
#    probe pane, both come back empty. Claude Code and most TUIs read them to
#    decide whether colour is supported, so without this everything renders
#    black and white inside Zellij while looking fine in a bare terminal.
#
#  CLAUDE_CODE_CHILD_SESSION
#    Zellij panes inherit the environment of the zellij SERVER process, not of
#    whatever asked for the tab. So if the server was ever started from inside
#    a Claude Code session, every pane in that session inherits the child
#    marker and Claude reports "Transcript saving is off". Clearing it here
#    makes each tab a proper top-level session regardless of how the server
#    happened to be launched.
#
#  NO_COLOR
#    The same server-inheritance trap, with a louder symptom. Claude Code sets
#    NO_COLOR=1 for every command it runs so its tool output comes back as
#    plain text. Install this rig BY ASKING CLAUDE TO - which docs/skill
#    zt-setup now tells people to do - and `zac` runs inside that environment,
#    so the server it starts inherits NO_COLOR=1 and hands it to every pane.
#    NO_COLOR is honoured before TERM and COLORTERM are even looked at, so the
#    two lines above do nothing and the whole session renders black and white:
#    Claude Code loses its colours and a themed prompt loses its styling, which
#    together read convincingly as "this is cmd, not pwsh".
#
#    Not set at User or Machine scope by anything sane, so removing it in the
#    pane costs a deliberate global NO_COLOR its effect INSIDE these tabs only.
#    That is the intended trade: the point of the rig is coloured TUIs.
$PanePrelude =
    "`$env:TERM='xterm-256color'; " +
    "`$env:COLORTERM='truecolor'; " +
    "Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue; " +
    "Remove-Item Env:CLAUDE_CODE_CHILD_SESSION -ErrorAction SilentlyContinue"

function Invoke-Zellij {
    param([string[]]$ZArgs)
    $all = @('--session', $Session, 'action') + $ZArgs
    $out = & zellij @all 2>&1
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = ($out -join "`n") }
}

function Get-ZtTabBase {
    <#
        Strip the hook's activity glyph: `claude-web-api ~` identifies as
        `claude-web-api`. One of four copies of this rule - hook,
        zj-claude-tab.ps1, the module, the palette - pinned together by a test,
        because a tab that cannot be found by name is a silent no-op here.
    #>
    param([string]$Name)
    if (-not $Name) { return $Name }
    return ($Name -replace ' [v!?*>~#@&+.]$', '')
}

function Get-TabNames {
    # BASE names: every caller uses these to decide whether a tab exists, and
    # the glyph on the end changes with each tool call the session makes.
    $r = Invoke-Zellij @('query-tab-names')
    if (-not $r.Ok) { return @() }
    return @(
        $r.Output -split "`r?`n" |
            ForEach-Object { Get-ZtTabBase ($_.Trim()) } |
            Where-Object   { $_ -ne '' }
    )
}

function Get-LiveTabName {
    <#
        The string Zellij is holding for a tab right now, glyph included.
        go-to-tab-name and close-tab-by-name match exactly and no-op silently
        otherwise, so the decorated form is what they must be given.
    #>
    param([string]$Base)

    $r = Invoke-Zellij @('query-tab-names')
    if ($r.Ok) {
        foreach ($n in ($r.Output -split "`r?`n")) {
            $t = $n.Trim()
            if ($t -and (Get-ZtTabBase $t) -eq $Base) { return $t }
        }
    }
    return $Base
}

# --- session must exist before anything else is worth trying ----------------
$sessions = & zellij list-sessions 2>&1 | Out-String
if ($sessions -notmatch [regex]::Escape($Session)) {
    Write-Error "Session '$Session' is not running. Start it with: zellij attach --create $Session"
    exit 1
}

function Add-ProjectTab {
    <#
        Create a claude-<leaf> tab for a directory. Returns $true if a tab was
        created, $false if it already existed or the user declined.
    #>
    # SupportsShouldProcess declared here, not just inherited. This function does
    # call $PSCmdlet.ShouldProcess, and it worked only because PowerShell finds
    # the script's own $PSCmdlet up the scope chain - which is true today and
    # stops being true the moment this moves into a module. Declaring it makes
    # the contract explicit instead of accidental.
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [string]$Path,
        [switch]$LaunchClaude,
        [switch]$SkipFocus,
        [string]$TabNameOverride,
        [string]$CommandLine
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "Path not found, skipping: $Path"
        return $false
    }
    $full = (Resolve-Path -LiteralPath $Path).Path
    if (-not (Get-Item -LiteralPath $full).PSIsContainer) {
        Write-Warning "Not a directory, skipping: $full"
        return $false
    }

    $leaf = Split-Path $full -Leaf
    $tab  = $Prefix + $leaf
    if ($TabNameOverride) { $tab = $TabNameOverride }

    # Already there? Just go to it. A duplicate name would make go-to-tab-name
    # ambiguous for every other script in the rig.
    if ((Get-TabNames) -contains $tab) {
        Write-Host "Tab '$tab' already exists." -ForegroundColor Yellow
        # Focusing is a visible change to what you are looking at, so it has to
        # respect -WhatIf too. Without this guard a dry run moved you to another
        # tab while reporting that it had done nothing.
        if (-not $SkipFocus) {
            if ($PSCmdlet.ShouldProcess("session '$Session'", "Focus existing tab '$tab'")) {
                Invoke-Zellij @('go-to-tab-name', (Get-LiveTabName $tab)) | Out-Null
                Write-Host '  focused it' -ForegroundColor DarkGray
            }
        }
        return $false
    }

    if (-not $PSCmdlet.ShouldProcess("session '$Session'", "Add tab '$tab' at $full")) {
        return $false
    }

    # Zellij wants forward slashes; backslashes are a documented source of
    # silent failures on Windows.
    $cwdArg = $full -replace '\\', '/'

    # Always run a real shell, never `claude` as the pane command directly.
    # As the pane command, claude gets no shell: you cannot type anything else,
    # the profile never runs, and when claude exits the pane simply vanishes.
    # Running it inside pwsh -NoExit means the tab survives as a prompt in the
    # right directory afterwards.
    # `claude --name` sets the session's display name: it shows in the prompt
    # box, in the /resume picker, and in the terminal title. Naming it after the
    # tab means /resume lists recognisable names instead of directory-derived
    # ones like `my-app-3f`.
    #
    # NOT addressing. On macOS and Linux this name is also what `@name`
    # addresses for cross-session messaging - but that feature is not offered on
    # native Windows, confirmed here by CLAUDE_CODE_MESSAGING_SOCKET being unset
    # on 2.1.232. Setting the name now means nothing has to change if that ever
    # arrives.
    # The tab keeps the claude- prefix so the cycle keys and the hook can find
    # it; the Claude session does not. That prefix is Zellij bookkeeping, and it
    # is the display name that shows in the prompt box, the /resume picker and
    # on mobile - where "claude-web-api" reads as if the tool were part of
    # the project's name. Nothing matches on --name, so they are free to differ.
    $sessionName = $tab
    if ($sessionName.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
        $trimmed = $sessionName.Substring($Prefix.Length)
        if ($trimmed) { $sessionName = $trimmed }
    }

    $inner = $PanePrelude
    if ($CommandLine)       { $inner = $PanePrelude + '; ' + $CommandLine }
    elseif ($LaunchClaude)  { $inner = $PanePrelude + "; claude --name '$sessionName'" }

    $zargs = @('new-tab', '--name', $tab, '--cwd', $cwdArg,
               '--', 'pwsh', '-NoLogo', '-NoExit', '-Command', $inner)

    $r = Invoke-Zellij $zargs
    if (-not $r.Ok) {
        Write-Error "Failed to create tab '$tab': $($r.Output)"
        return $false
    }

    Write-Host "Added tab '$tab'" -ForegroundColor Green
    Write-Host "  cwd: $full" -ForegroundColor DarkGray
    if ($LaunchClaude) { Write-Host '  claude started in it' -ForegroundColor DarkGray }
    return $true
}

# ============================================================================
#  ADD
# ============================================================================
if ($PSCmdlet.ParameterSetName -eq 'Add') {

    $created = Add-ProjectTab -Path $Add -LaunchClaude:$Launch -SkipFocus:$NoFocus `
                              -TabNameOverride $TabName -CommandLine $Command

    # new-tab focuses whatever it creates and there is no reliable way back
    # over the CLI, so -NoFocus is honest about being partial rather than
    # pretending to restore focus.
    if ($created -and $NoFocus) {
        Write-Host '  (-NoFocus: new-tab still focuses the new tab; returning is not' -ForegroundColor DarkGray
        Write-Host '   reliable over the CLI, so you may need to switch back by hand)' -ForegroundColor DarkGray
    }
    exit 0
}

# ============================================================================
#  FROM WINDOWS TERMINAL PROFILES
# ============================================================================
#  Reads Windows Terminal's own settings.json rather than depending on a
#  bookmarks module. Such a module curates profiles - its bookmarks ARE
#  profiles - so this covers people who use one and people who simply set a
#  startingDirectory by hand, with nothing extra to install.
#
#  Duplicated from the module on purpose, like everything else in this file:
#  scripts\ must run without the module, under Windows PowerShell 5.1.
# ============================================================================
if ($PSCmdlet.ParameterSetName -eq 'FromBookmarks') {

    $settingsPath = $null
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )
    foreach ($c in $candidates) {
        if ((-not $settingsPath) -and (Test-Path -LiteralPath $c)) { $settingsPath = $c }
    }
    if (-not $settingsPath) {
        Write-Error 'No Windows Terminal settings.json found. Use -Add per project instead.'
        exit 1
    }

    $settings = $null
    try { $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json } catch {
        Write-Error "Could not read $settingsPath : $($_.Exception.Message)"
        exit 1
    }

    $list = @()
    if ($settings.PSObject.Properties.Name -contains 'profiles') {
        if ($settings.profiles.PSObject.Properties.Name -contains 'list') { $list = @($settings.profiles.list) }
    }

    $added   = 0
    $matched = 0
    $skipped = @()
    foreach ($p in $list) {
        if ($p.PSObject.Properties.Name -notcontains 'name') { continue }
        if ($p.name -notlike $Filter) { continue }
        if ($p.PSObject.Properties.Name -notcontains 'startingDirectory') { continue }

        $dir = $p.startingDirectory
        if (-not $dir) { continue }
        $dir = [Environment]::ExpandEnvironmentVariables($dir)
        if ($dir -like '~*') { $dir = $HOME + $dir.Substring(1) }

        # Skip the profile that opens the session itself. Its command line is
        # `zellij.exe attach --create claude`, so anything matching the word
        # "claude" anywhere would import the launcher as a project - the session
        # name is not a command.
        $raw = ''
        if ($p.PSObject.Properties.Name -contains 'commandline') { $raw = $p.commandline }
        $inner = $raw
        $m = [regex]::Match($raw, '(?i)\s-(?:Command|c)\s+(.+)$')
        if ($m.Success) {
            $inner = $m.Groups[1].Value.Trim()
            if ($inner.Length -ge 2) {
                $q = $inner.Substring(0, 1)
                if (($q -eq '"' -or $q -eq "'") -and $inner.EndsWith($q)) {
                    $inner = $inner.Substring(1, $inner.Length - 2)
                }
            }
        }
        $token = ''
        if ($inner) {
            $token = ($inner.Trim() -split '\s+')[0]
            $token = $token.Trim('"', "'")
            $token = Split-Path $token -Leaf
            if ($token -like '*.exe') { $token = $token.Substring(0, $token.Length - 4) }
            $token = $token.ToLowerInvariant()
        }
        if ($token -eq 'zellij') { continue }

        $matched++
        if (-not (Test-Path -LiteralPath $dir)) {
            Write-Warning "Profile '$($p.name)' points at a directory that is not here, skipping: $dir"
            continue
        }

        # A profile that already launches Claude becomes a Claude tab. Anything
        # else is skipped unless -IncludeAll, and listed at the end rather than
        # dropped quietly - a default that filters in silence is
        # indistinguishable from one that found nothing.
        if ($token -eq 'claude') {
            if (Add-ProjectTab -Path $dir -LaunchClaude) { $added++ }
        } elseif (-not $IncludeAll) {
            $skipped += $p.name
        } elseif ($Launch) {
            if (Add-ProjectTab -Path $dir -LaunchClaude) { $added++ }
        } else {
            if (Add-ProjectTab -Path $dir) { $added++ }
        }
    }

    Write-Host ''
    Write-Host "  $added tab(s) added from $matched matching profile(s)." -ForegroundColor Cyan
    if ($skipped.Count -gt 0) {
        Write-Host "  Skipped $($skipped.Count) that do not launch Claude: $($skipped -join ', ')" -ForegroundColor DarkGray
        Write-Host '  Add them too with:  -IncludeAll' -ForegroundColor DarkGray
    }
    exit 0
}

# ============================================================================
#  REMOVE
# ============================================================================
if ($PSCmdlet.ParameterSetName -eq 'Remove') {

    # Accept either "foo" or "claude-foo".
    $tab = $Remove
    if ($tab -notlike "$Prefix*") { $tab = $Prefix + $tab }

    # Guard: never close a tab outside the managed namespace. close-tab acts on
    # whatever is focused, so a typo here would shut something else.
    if ($tab -notlike "$Prefix*") {
        Write-Error "Refusing to remove '$tab' - only tabs starting '$Prefix' are managed here."
        exit 1
    }

    $names = Get-TabNames
    if ($names -notcontains $tab) {
        # A miss here is nearly always a typo, not a failure worth an exception.
        Write-Warning "No tab named '$tab'. Present: $($names -join ', ')"
        exit 0
    }

    if (-not $PSCmdlet.ShouldProcess("session '$Session'", "Close tab '$tab'")) {
        exit 0
    }

    # close-tab has no --name, so the target must be focused first.
    $r = Invoke-Zellij @('go-to-tab-name', (Get-LiveTabName $tab))
    if (-not $r.Ok) {
        Write-Error "Could not focus '$tab': $($r.Output)"
        exit 1
    }

    # Confirming the focus moved is harder than it looks. `current-tab-info`
    # only answers for a client attached to the session; run from outside it
    # returns "No active tab found for current client" and exit 2, so trusting
    # it here would block every removal made from a script. Use it when it
    # works, and fall back to a before/after comparison of the tab list, which
    # is what actually proves the right tab went.
    $info = (Invoke-Zellij @('current-tab-info')).Output
    if ($info -and ($info -notmatch 'No active tab') -and ($info -notmatch [regex]::Escape($tab))) {
        Write-Error "Focus did not move to '$tab' (still: $info). Not closing anything."
        exit 1
    }

    $before = Get-TabNames
    Invoke-Zellij @('close-tab') | Out-Null
    $after  = Get-TabNames

    $went = @($before | Where-Object { $after -notcontains $_ })

    if ($after -contains $tab) {
        Write-Error "Tab '$tab' is still present - it may have refused to close."
        exit 1
    }
    if ($went.Count -ne 1 -or $went[0] -ne $tab) {
        Write-Error ("Closed the WRONG tab. Expected '$tab' to go; what actually " +
                     "disappeared: $($went -join ', '). Tabs now: $($after -join ', ')")
        exit 1
    }

    Write-Host "Removed tab '$tab'" -ForegroundColor Green

    # Drop its waiting flag too, or key 3 keeps jumping at a tab that is gone.
    $flag = Join-Path $flagDir ($tab + '.json')
    if (Test-Path -LiteralPath $flag) {
        Remove-Item -LiteralPath $flag -Force
        Write-Host '  cleared its waiting flag' -ForegroundColor DarkGray
    }
    exit 0
}

# ============================================================================
#  LIST  (default)
# ============================================================================
$names   = Get-TabNames
$targets = @($names | Where-Object { $_ -like "$Prefix*" })

Write-Host ''
Write-Host "  Session '$Session'" -ForegroundColor Cyan
Write-Host '  ------------------' -ForegroundColor Cyan

if ($targets.Count -eq 0) {
    Write-Host "  No tabs matching '$Prefix*'." -ForegroundColor Yellow
    Write-Host '  Add one with:  .\zj-claude-project.ps1 -Add <path>' -ForegroundColor DarkGray
} else {
    foreach ($t in $targets) {
        $state  = ''
        $colour = 'Gray'
        $flag   = Join-Path $flagDir ($t + '.json')
        if (Test-Path -LiteralPath $flag) {
            try {
                $f = Get-Content -LiteralPath $flag -Raw | ConvertFrom-Json
                # Flag files are written by the hook and may predate a field, or
                # be half-written. Under Set-StrictMode reading an absent
                # property throws, so test for each one before touching it.
                $props   = $f.PSObject.Properties.Name
                $waiting = ($props -contains 'waiting') -and $f.waiting
                if ($waiting) {
                    $since = ''
                    if (($props -contains 'since') -and $f.since) {
                        try {
                            $mins  = [int]((Get-Date) - [datetime]$f.since).TotalMinutes
                            $since = " for ${mins}m"
                        } catch { }
                    }
                    $ev = '?'
                    if (($props -contains 'event') -and $f.event) { $ev = $f.event }
                    $state  = "  <- waiting ($ev)$since"
                    $colour = 'Yellow'
                }
            } catch {
                $state  = '  <- unreadable flag file'
                $colour = 'Red'
            }
        }
        Write-Host ('  {0,-32}{1}' -f $t, $state) -ForegroundColor $colour
    }
}

$others = @($names | Where-Object { $_ -notlike "$Prefix*" })
if ($others.Count -gt 0) {
    Write-Host ''
    Write-Host "  Not managed: $($others -join ', ')" -ForegroundColor DarkGray
}
Write-Host ''

