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
    # LEGACY FALLBACK ONLY - see "WHICH TABS ARE PROJECTS?" below. Membership
    # comes from the registry now; this is what that falls back to when no
    # registry can be read, and what still matches tabs made before 0.7.20.
    [string]$Pattern = 'claude*',

    # The prefix those older tabs carry. Nothing ADDS it any more; this is how a
    # tab called `claude-web-api` is recognised as the workspace the registry
    # calls `web-api`, so a session that predates 0.7.20 keeps cycling instead
    # of quietly dropping out of the pad's rotation.
    [string]$Prefix = 'claude-',

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

    # WITH NOTHING ATTACHED, go-to-tab-name IS A SILENT NO-OP THAT EXITS 0. The
    # docstring above says the miss case looks like a dead pad; the detached
    # case looks identical and is far commoner - close the terminal, keep the
    # session. Writing the state file anyway made it worse than a no-op: the
    # next press cycled from a tab nobody ever moved to.
    $clients = Invoke-Zellij @('list-clients')
    $rows = @($clients -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+\s' })
    if ($rows.Count -eq 0) {
        Write-Error ("Nothing is attached to session '$Session', so a tab switch would do nothing " +
                     "and report success. Open a terminal on it first: zac")
        exit 3
    }

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

# ---------------------------------------------------------------------------
#  WHICH TABS ARE PROJECTS?
# ---------------------------------------------------------------------------
#  This used to be `-like 'claude*'`, and that string was the only thing making
#  the prefix load-bearing: tabs were called `claude-<leaf>` so that this line
#  could tell a project from your editor or log tab. Seven columns on every tab,
#  every day, to answer a question the registry can already answer - and on a bar
#  where the chunk that does not fit is dropped WHOLE, those columns are the
#  difference between reading your tab names and losing all of them at once.
#
#  So ask the registry. It is the same file `zt` reads, resolved the same way -
#  $env:ZT_CONFIG_HOME wins, else %LOCALAPPDATA%\ZellijTerminal - which is the
#  rule written in Get-ZtConfigHome, ZtStore.cs and Test-Setup.ps1, and pinned
#  across all of them by test. This is the fourth copy and it is here for the
#  same reason as the others: this script runs under 5.1 on the pad's latency
#  path and must not import the module.
#
#  FALLING BACK IS NOT OPTIONAL. If the registry cannot be read - fresh machine,
#  redirected config home, a corrupt file - cycling must still work rather than
#  reporting "nothing to cycle" on a session full of tabs. So an unreadable or
#  empty registry falls back to the old pattern, which also covers every tab
#  created before 0.7.20.
function Get-ZtRegisteredTabBases {
    $home_ = $env:ZT_CONFIG_HOME
    if (-not $home_) {
        $base = $env:LOCALAPPDATA
        if (-not $base) { return @() }
        $home_ = Join-Path $base 'ZellijTerminal'
    }

    $files = @(
        (Join-Path $home_ ('devices\' + $env:COMPUTERNAME + '.json')),
        (Join-Path $home_ 'workspaces.json')
    )

    $out = @()
    foreach ($f in $files) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try { $doc = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { continue }
        if (-not $doc) { continue }
        foreach ($w in @($doc.workspaces)) {
            if (-not $w) { continue }
            # An explicit name wins, exactly as Get-ZtTabName has it; otherwise
            # the tab is the leaf of whatever path this device resolved.
            $n = $null
            if ($w.PSObject.Properties.Name -contains 'name' -and $w.name) { $n = "$($w.name)" }
            if (-not $n -and $w.PSObject.Properties.Name -contains 'rel' -and $w.rel) { $n = Split-Path "$($w.rel)" -Leaf }
            if (-not $n -and $w.PSObject.Properties.Name -contains 'abs' -and $w.abs) { $n = Split-Path "$($w.abs)" -Leaf }
            if (-not $n -and $w.PSObject.Properties.Name -contains 'id'  -and $w.id ) { $n = "$($w.id)" }
            if ($n) { $out += $n }
        }
    }
    return @($out | Sort-Object -Unique)
}

$registered = @()
try { $registered = @(Get-ZtRegisteredTabBases) } catch { $registered = @() }

if ($registered.Count -gt 0) {
    # MATCH THE LEGACY SPELLING TOO. A tab opened before 0.7.20 is called
    # `claude-<leaf>` while the registry holds `<leaf>`, and a session mixing
    # old and new tabs would otherwise cycle only the new ones - which reads as
    # the pad skipping tabs at random rather than as a migration.
    $targets = @($names | Where-Object {
        $n = $_
        if ($registered -contains $n) { return $true }
        if ($Prefix -and $n.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return ($registered -contains $n.Substring($Prefix.Length))
        }
        return $false
    })
    # A registry that lists nothing OPEN is not a reason to refuse to cycle.
    if ($targets.Count -eq 0) { $targets = @($names | Where-Object { $_ -like $Pattern }) }
} else {
    $targets = @($names | Where-Object { $_ -like $Pattern })
}

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
