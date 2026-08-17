<#
    Choosing a workspace without typing its id.

    Three ways, because they suit different moments:

      tab completion   you know roughly what it is called
      the picker       you do not, and want to see the list
      `zt go`          you do not care, you want whoever is waiting

    The picker is written against [Console]::ReadKey rather than pulling in
    Out-ConsoleGridView or fzf. Both are better tools; neither is present by
    default, and a workspace picker that says "install this first" is not a
    picker. This works on a bare 5.1 with nothing added.
#>

function Select-ZellijTerminal {
    <#
    .SYNOPSIS
        Pick a workspace from a list with the arrow keys.

    .DESCRIPTION
        Up/Down to move, Enter to choose, Esc to cancel, or press a number for
        a direct pick. Returns the chosen workspace object.

        With -Go it also acts on the choice: focuses that tab, or starts the
        workspace if it is not open yet. That is `zt pick`.

    .EXAMPLE
        zt pick
        $ws = Select-ZellijTerminal
    #>
    [CmdletBinding()]
    param(
        # Only offer workspaces in this state.
        [ValidateSet('running', 'tab-only', 'stopped', 'stale', 'unavailable', 'unregistered')]
        [string]$State,

        # Focus the chosen workspace - starting it first if it is not open.
        [switch]$Go,

        [string]$Title = 'Choose a workspace',

        [string]$Session = 'claude',
        [string]$Prefix  = 'claude-'
    )

    $items = @(Get-ZellijTerminal -Session $Session -Prefix $Prefix)
    if ($State) { $items = @($items | Where-Object { $_.State -eq $State }) }

    $chosen = Select-ZtItem -Items $items -Title $Title
    if (-not $chosen) { return }

    if (-not $Go) { return $chosen }

    if ($chosen.State -eq 'stopped' -or $chosen.State -eq 'unavailable') {
        Start-ZellijTerminal -Name $chosen.Id -Session $Session -Prefix $Prefix
        return
    }

    Invoke-ZtZellij -Session $Session -ZArgs @('go-to-tab-name', (Get-ZtLiveTabName -Session $Session -Base $chosen.Tab)) | Out-Null
    Write-Host "-> $($chosen.Id)  ($($chosen.Tab))" -ForegroundColor DarkGray
}

function Select-ZtItem {
    <#
        The list itself. Redraws in place by walking the cursor back up, so
        holding Down does not scroll a page of copies off the screen.

        Every line is truncated to the window width. Without that a long path
        wraps, the redraw's line arithmetic is wrong by however many lines
        wrapped, and the list smears down the terminal - which looks like a
        crash rather than a cosmetic problem.
    #>
    param(
        [object[]]$Items,
        [string]$Title = 'Choose'
    )

    if (-not $Items -or $Items.Count -eq 0) {
        Write-Warning 'Nothing to choose from.'
        return $null
    }
    if ($Items.Count -eq 1) { return $Items[0] }

    # Redirected input means no keys are coming. Say so rather than blocking
    # forever on ReadKey, which is indistinguishable from a hang.
    if ([Console]::IsInputRedirected) {
        Write-Warning 'No interactive console - name the workspace instead of picking it.'
        return $null
    }

    $index  = 0
    $height = $Items.Count + 3           # title, blank, items, footer
    $width  = 76
    try { $width = [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width - 4) } catch { }

    $drawn = $false
    try {
        while ($true) {
            if ($drawn) {
                try {
                    $pos = $Host.UI.RawUI.CursorPosition
                    $pos.Y = [Math]::Max(0, $pos.Y - $height)
                    $Host.UI.RawUI.CursorPosition = $pos
                } catch {
                    # A host without a settable cursor (some IDE consoles) just
                    # gets a fresh block each time. Ugly, still usable.
                }
            }

            Write-Host ''
            Write-Host ("  $Title".PadRight($width)) -ForegroundColor Cyan

            for ($i = 0; $i -lt $Items.Count; $i++) {
                $it    = $Items[$i]
                $state = $it.State
                if ($it.Waiting) { $state = 'WAITING' }

                $line = '{0} {1,2}. {2,-20} {3,-11} {4}' -f
                        $(if ($i -eq $index) { '>' } else { ' ' }),
                        ($i + 1), $it.Id, $state, $it.Path

                if ($line.Length -gt $width) { $line = $line.Substring(0, $width - 1) + '~' }
                $line = $line.PadRight($width)

                if ($i -eq $index) {
                    Write-Host "  $line" -ForegroundColor Black -BackgroundColor Cyan
                } else {
                    $colour = 'Gray'
                    if ($it.Waiting)             { $colour = 'Yellow' }
                    elseif ($it.State -eq 'running') { $colour = 'Green' }
                    elseif ($it.State -eq 'stale')   { $colour = 'DarkYellow' }
                    Write-Host "  $line" -ForegroundColor $colour
                }
            }

            Write-Host ('  up/down  enter to choose  esc to cancel'.PadRight($width)) -ForegroundColor DarkGray
            $drawn = $true

            $key = [Console]::ReadKey($true)

            switch ($key.Key) {
                'UpArrow'   { $index--; if ($index -lt 0) { $index = $Items.Count - 1 } }
                'DownArrow' { $index++; if ($index -ge $Items.Count) { $index = 0 } }
                'Home'      { $index = 0 }
                'End'       { $index = $Items.Count - 1 }
                'Enter'     { return $Items[$index] }
                'Escape'    { return $null }
                'Q'         { return $null }
                default {
                    # Digits pick directly - faster than arrowing to number 7.
                    $ch = $key.KeyChar
                    if ($ch -match '^[1-9]$') {
                        $n = [int]::Parse($ch)
                        if ($n -le $Items.Count) { return $Items[$n - 1] }
                    }
                }
            }
        }
    } finally {
        [Console]::CursorVisible = $true
    }
}

function Resolve-ZtTarget {
    <#
        What the control verbs call. A name resolves it directly; no name opens
        the picker. That is what makes `zt stop` on its own a sensible thing to
        type rather than an error.
    #>
    param(
        [string]$Name,
        [string]$Title = 'Choose a workspace',
        [string]$Session = 'claude',
        [string]$Prefix  = 'claude-'
    )

    if ($Name) { return (Find-ZtWorkspace -Name $Name -Session $Session -Prefix $Prefix) }
    return (Select-ZtItem -Items @(Get-ZellijTerminal -Session $Session -Prefix $Prefix) -Title $Title)
}

