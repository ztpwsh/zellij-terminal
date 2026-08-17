<#
    Zellij SESSIONS, as distinct from tabs.

    Two levels, easily conflated:

        zellij list-sessions          the sessions - separate servers, each
                                      with its own tabs, its own clients
        zellij action query-tab-names the TABS inside ONE session

    Everything else in this module works inside a single session ('claude').
    `zt close` closes a TAB in that session; it never touches a session, which
    is why tabs do not and cannot appear in `list-sessions` - they are a level
    down.

    This file is the level up, because stray sessions accumulate silently:
    session_serialization keeps exited ones around to be resurrected, and a
    mistyped command creates a whole new server named after a random animal.
#>

function Get-ZellijTerminalSession {
    <#
    .SYNOPSIS
        List Zellij sessions - the level above tabs.

    .DESCRIPTION
        Marks which one this rig manages, which are exited (still resurrectable,
        because session_serialization is on), and how many tabs and clients each
        has.

    .EXAMPLE
        zt sessions
    #>
    [CmdletBinding()]
    param([string]$Session = 'claude')

    # No zellij means no sessions - an empty result, not an exception. See
    # Invoke-ZtZellij for why. A bare `return` rather than `return @()`: every
    # caller already wraps this in @(), and returning a literal Object[] trips
    # PSUseOutputTypeCorrectly, which this suite treats as fatal.
    if (-not (Get-Command zellij -ErrorAction SilentlyContinue)) { return }

    $raw = & zellij list-sessions 2>&1 | Out-String

    # list-sessions colours its output, and the escape codes would end up inside
    # the parsed names.
    $clean = $raw -replace "`e\[[0-9;]*m", ''

    $out = @()
    foreach ($line in ($clean -split "`r?`n")) {
        $line = $line.Trim()
        if (-not $line) { continue }

        $m = [regex]::Match($line, '^(?<name>\S+)\s+\[Created\s+(?<created>[^\]]+)\]\s*(?<rest>.*)$')
        if (-not $m.Success) { continue }

        $name   = $m.Groups['name'].Value
        $exited = $m.Groups['rest'].Value -match 'EXITED'

        # Tabs and clients only answer for a live session.
        $tabs = @()
        $clients = 0
        if (-not $exited) {
            $tabs = @(Get-ZtTabNames -Session $name)
            $r = Invoke-ZtZellij -Session $name -ZArgs @('list-clients')
            if ($r.Ok) { $clients = Measure-ZtClientRows $r.Output }
        }

        $out += [pscustomobject]@{
            PSTypeName = 'ZellijTerminal.Session'
            Name       = $name
            Managed    = ($name -eq $Session)
            Exited     = $exited
            Created    = $m.Groups['created'].Value.Trim()
            Tabs       = $tabs.Count
            Clients    = $clients
            TabNames   = $tabs
        }
    }

    return $out
}

function Show-ZtSessionTable {
    param([object[]]$Sessions)

    Write-Host ''
    Write-Host ('  {0,-24} {1,-8} {2,-6} {3,-8} {4}' -f 'SESSION', 'STATE', 'TABS', 'CLIENTS', 'CREATED') -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 72)) -ForegroundColor DarkGray

    foreach ($s in $Sessions) {
        $state  = 'running'
        $colour = 'Gray'
        if ($s.Exited)  { $state = 'EXITED'; $colour = 'DarkYellow' }
        if ($s.Managed) { $colour = 'Green' }

        $name = $s.Name
        if ($s.Managed) { $name += ' *' }

        Write-Host ('  {0,-24} {1,-8} {2,-6} {3,-8} {4}' -f
            $name, $state, $s.Tabs, $s.Clients, $s.Created) -ForegroundColor $colour
    }

    Write-Host ''
    Write-Host '  * the session this rig manages. Its tabs are what `zt` lists.' -ForegroundColor DarkGray
    Write-Host '    EXITED sessions still resurrect on attach - that is session_serialization.' -ForegroundColor DarkGray
    Write-Host ''
}

function Remove-ZellijTerminalSession {
    <#
    .SYNOPSIS
        Kill a Zellij session, and optionally forget it entirely.

    .DESCRIPTION
        `kill-session` stops it but leaves it resurrectable, which is usually
        what you want. -Delete removes it for good.

        The managed session is refused without -Force: killing it takes every
        Claude session in it down at once, which is not something to do by
        accident while tidying up strays.

    .EXAMPLE
        zt sessions rm likable-diplodocus
        zt sessions rm likable-diplodocus -Delete
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name,

        # Also remove it from the resurrectable list.
        [switch]$Delete,

        # Required to touch the session this rig manages.
        [switch]$Force,

        [string]$Session = 'claude'
    )

    if ($Name -eq $Session -and -not $Force) {
        Write-Error ("'$Name' is the session this rig manages - killing it takes every tab and " +
                     "every Claude session in it down at once. Re-run with -Force if that is " +
                     "really what you want.")
        return
    }

    $all = @(Get-ZellijTerminalSession -Session $Session)
    $hit = @($all | Where-Object { $_.Name -eq $Name })
    if ($hit.Count -eq 0) {
        Write-Warning "No session named '$Name'. Present: $((($all | ForEach-Object { $_.Name }) -join ', '))"
        return
    }

    $what = "Kill session '$Name'"
    if ($hit[0].Tabs -gt 0) { $what += " ($($hit[0].Tabs) tab(s))" }
    if ($Delete) { $what += ' and delete it permanently' }

    if (-not $PSCmdlet.ShouldProcess('Zellij', $what)) { return }

    if (-not $hit[0].Exited) {
        & zellij kill-session $Name 2>&1 | Out-Null
        Write-Host "Killed '$Name'" -ForegroundColor Green
    }

    if ($Delete) {
        & zellij delete-session $Name --force 2>&1 | Out-Null
        Write-Host "  deleted - it will not resurrect" -ForegroundColor DarkGray
    }
}

function Invoke-ZtSessions {
    <#
        `zt sessions [rm <name>]`. A sub-dispatcher, like `zt pad`, because
        session management is occasional and should not crowd the daily verbs.
    #>
    param([object[]]$Arguments = @())

    $sub  = ''
    $rest = @()
    if ($Arguments.Count -gt 0) { $sub = "$($Arguments[0])" }
    if ($Arguments.Count -gt 1) { $rest = $Arguments[1..($Arguments.Count - 1)] }

    switch -Regex ($sub) {
        '^(rm|remove|kill)$' { return (Invoke-ZtForward 'Remove-ZellijTerminalSession' $rest) }
        '^$'                 { return (Show-ZtSessionTable -Sessions @(Get-ZellijTerminalSession)) }
        default {
            # `zt sessions -Something` should still list, not error.
            if ($sub.StartsWith('-')) {
                return (Show-ZtSessionTable -Sessions @(Invoke-ZtForward 'Get-ZellijTerminalSession' $Arguments))
            }
            Write-Warning "Unknown: zt sessions '$sub'. Try: zt sessions | zt sessions rm <name>"
        }
    }
}
