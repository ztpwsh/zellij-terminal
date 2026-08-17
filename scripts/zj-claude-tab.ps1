<#
.SYNOPSIS
    Move between Zellij tabs matching a pattern - either cycling them, or
    jumping straight to whichever one is waiting for you.

.DESCRIPTION
    Two modes:

      -Direction next|prev   cycle only tabs matching -Pattern, skipping
                             your shell/editor/log tabs entirely.

      -Waiting               jump to the tab whose Claude Code session is
                             asking for input. Needs claude-zj-hook.ps1
                             registered as a Claude Code hook. Falls back
                             to cycling if nothing is waiting.

    -Waiting is the one worth binding. Cycling makes you hunt; the hook
    makes the tab raise its hand.

    No Zellij plugin involved. A plugin runs inside Zellij and only sees
    keys typed into its own focused pane, so a macro pad could never reach
    it. Everything here goes through Zellij's CLI from outside.

.EXAMPLE
    .\zj-claude-tab.ps1 -Waiting
    .\zj-claude-tab.ps1 -Direction next
    .\zj-claude-tab.ps1 -Direction prev -Session claudexxx -Pattern "claude*"
#>

[CmdletBinding(DefaultParameterSetName = 'Cycle')]
param(
    [Parameter(ParameterSetName = 'Cycle')]
    [ValidateSet('next', 'prev')]
    [string]$Direction = 'next',

    [Parameter(ParameterSetName = 'Waiting')]
    [switch]$Waiting,

    [string]$Session = 'claude',
    [string]$Pattern = 'claude*',

    # Full path to zellij.exe, because PATH cannot be relied on here.
    #
    # PowerToys Keyboard Manager launches remapped commands through
    # `run_non_elevated`, and that environment does NOT necessarily have
    # zellij on PATH - zellij installs itself onto the *user* PATH, and the
    # de-elevated launch inherits the shell's environment block instead.
    # Bare `zellij` then resolves to nothing, every call in here returns null,
    # and the script dies on the first .Trim() - into a hidden window, so the
    # only symptom is that the pad key does nothing at all.
    #
    # Cost a morning. `zt pad install` now passes this explicitly.
    [string]$ZellijExe = 'zellij'
)

$ErrorActionPreference = 'Stop'
$stateFile = Join-Path $env:TEMP "zj-tab-$Session.txt"
$flagDir   = Join-Path $env:TEMP 'claude-zellij-flags'

# Fail loudly and immediately rather than eight lines later on a null.
if (-not (Get-Command $ZellijExe -ErrorAction SilentlyContinue)) {
    Write-Error ("Cannot find zellij ('$ZellijExe'). It is not on PATH in this process. " +
                 "Pass -ZellijExe with a full path - that is what the pad bindings do.")
    exit 2
}

function Invoke-Zellij {
    param([string[]]$ZArgs)
    $all = @('--session', $Session, 'action') + $ZArgs
    try   { return (& $ZellijExe @all 2>$null) }
    catch { return $null }
}

function Get-ZtTabBase {
    <#
        A tab carries the hook's activity glyph: `claude-web-api ~`. Everything
        that IDENTIFIES a tab has to work on the name without it, because the
        glyph changes on every tool call while the identity does not.

        The character class is the symbol table in claude-zj-hook.ps1; a test
        pins the two together, and pins this function against the copies in
        zj-claude-project.ps1, the module and the palette - four implementations
        that must not drift, for the same reason Get-ZtKey has two.

        A folder whose name genuinely ends in a space and one of those glyphs
        loses that character here. Accepted: the alternative is a delimiter in
        every tab name, paid by everyone, to protect a folder called `notes ~`.
    #>
    param([string]$Name)
    if (-not $Name) { return $Name }
    return ($Name -replace ' [v!?*>~#@&+.]$', '')
}

function Set-Tab {
    <#
        Takes a BASE name and resolves the decorated one, because
        go-to-tab-name matches the live string exactly - and silently no-ops
        when it matches nothing, so a stale name here looks like a dead pad.
    #>
    param([string]$Name)

    $target = $Name
    if ($script:LiveTabName.ContainsKey($Name)) { $target = $script:LiveTabName[$Name] }

    Invoke-Zellij @('go-to-tab-name', $target) | Out-Null
    Set-Content -LiteralPath $stateFile -Value $Name -Encoding UTF8
}

function Get-CurrentTab {
    <#
        Which tab is focused? Both modes need this and both must answer it the
        same way, or repeated presses behave differently depending on mode.

        `current-tab-info` only answers for a client attached to the session.
        Called from outside - which is exactly how the macro pad calls it - it
        prints "No active tab found for current client" and exits 2. That is
        non-empty output meaning the opposite of success, so testing "did I get
        output?" is not enough; the error text has to be excluded explicitly or
        it gets pattern-matched against tab names.

        The state file written by Set-Tab is therefore the primary mechanism in
        pad use, not a rarely-hit fallback.
    #>
    param([string[]]$Candidates)

    $info = (Invoke-Zellij @('current-tab-info')) -join "`n"
    if ($info -and ($info -notmatch 'No active tab')) {
        # Longest names first so "claude1" never wins over "claude10" by being
        # a prefix of it.
        foreach ($n in ($Candidates | Sort-Object { $_.Length } -Descending)) {
            if ($info -match [regex]::Escape($n)) { return $n }
        }
    }

    if (Test-Path -LiteralPath $stateFile) {
        $remembered = (Get-Content -LiteralPath $stateFile -Raw).Trim()
        if ($Candidates -contains $remembered) { return $remembered }
    }

    return $null
}

# --- every tab in the session, in order -------------------------------------
# Two views of the same list: the BASE names drive every decision, and the map
# remembers what each one is actually called right now so go-to-tab-name gets
# the string Zellij is holding.
$raw = @(
    Invoke-Zellij @('query-tab-names') |
        ForEach-Object { $_.Trim() } |
        Where-Object   { $_ -ne '' }
)

if ($raw.Count -eq 0) {
    Write-Error "No tabs found. Is session '$Session' running? Check: zellij list-sessions"
    exit 1
}

$script:LiveTabName = @{}
$names = @(
    foreach ($r in $raw) {
        $b = Get-ZtTabBase $r
        if (-not $script:LiveTabName.ContainsKey($b)) { $script:LiveTabName[$b] = $r }
        $b
    }
)

$targets = @($names | Where-Object { $_ -like $Pattern })

# No project tabs is the normal cold start now that the layout opens only
# `home`, so this is not an error and must not exit non-zero: the pad calls this
# script, and a failing exit code there reads as the pad being broken - which is
# the one diagnosis this rig works hardest to keep honest. Say what is true and
# leave the user where they are.
if ($targets.Count -eq 0) {
    Write-Host "Nothing open to cycle - no tab matches '$Pattern'." -ForegroundColor DarkGray
    Write-Host '  Open one with:  zt start <id>' -ForegroundColor DarkGray
    exit 0
}

# ============================================================================
#  MODE 1 - jump to whatever is waiting
# ============================================================================
if ($Waiting) {
    $flagged = @()
    if (Test-Path -LiteralPath $flagDir) {
        $flagged = @(
            Get-ChildItem -LiteralPath $flagDir -Filter '*.json' -ErrorAction SilentlyContinue |
                ForEach-Object {
                    try {
                        $f = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
                        if ($f.waiting -and ($targets -contains $f.tab)) {
                            [pscustomobject]@{ Tab = $f.tab; Since = [datetime]$f.since }
                        }
                    } catch { }
                } | Sort-Object Since        # oldest first - longest ignored wins
        )
    }

    if ($flagged.Count -gt 0) {
        # Repeated presses must walk the queue rather than sticking on the
        # oldest waiter. That needs to know where we already are - and it must
        # use the SAME resolver as the cycling mode below, including the state
        # file fallback. An earlier version asked current-tab-info here and had
        # no fallback, so from outside the session $current was always null and
        # every press re-selected queue[0].
        $queue   = @($flagged.Tab)
        $current = Get-CurrentTab -Candidates $targets

        $index = 0
        if ($current -and $queue.Count -gt 1) {
            $at = [array]::IndexOf($queue, $current)
            if ($at -ge 0) { $index = ($at + 1) % $queue.Count }
        }

        Set-Tab $queue[$index]
        exit 0
    }

    # Nothing waiting - fall through to a plain cycle rather than doing nothing.
    $Direction = 'next'
}

# ============================================================================
#  MODE 2 - cycle the matching tabs
# ============================================================================
if ($targets.Count -eq 1) {
    Set-Tab $targets[0]
    exit 0
}

# Which tab are we on? Same resolver as -Waiting uses, so both modes agree.
$current = Get-CurrentTab -Candidates $targets

if (-not $current) {
    $index = if ($Direction -eq 'next') { 0 } else { $targets.Count - 1 }
}
else {
    $i = [array]::IndexOf($targets, $current)
    $index = if ($Direction -eq 'next') {
        ($i + 1) % $targets.Count
    } else {
        ($i - 1 + $targets.Count) % $targets.Count
    }
}

Set-Tab $targets[$index]
