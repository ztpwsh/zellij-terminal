<#
    zt - the short surface.

    Two front doors on purpose. The Verb-Noun functions are what PowerShell
    expects: they tab-complete, they take named parameters, Get-Help works on
    them, and they compose in a pipeline. `zt` is what you actually type fifty
    times a day.

    Everything here forwards; no behaviour lives in this file. Extra arguments
    pass straight through, so `zt start api -Resume` and `zt ls -Waiting` work
    exactly as the underlying command does.
#>

function Invoke-ZtForward {
    <#
        Forward `zt <verb> <args>` to the real command.

        WHY THIS IS NOT JUST `& $fn @Rest`

        Array splatting passes every element as a POSITIONAL argument. A string
        that looks like `-Waiting` is passed as the literal text "-Waiting", not
        as a switch. The failure is silent and total: `zt ls -Waiting` bound
        "-Waiting" to -Name and listed nothing, while `Get-ZellijTerminal
        -Waiting` worked; `zt restore -WhatIf` bound "-WhatIf" to -Session and
        went ahead and did the thing. Named parameters only survive HASHTABLE
        splatting, so the arguments have to be parsed back into one.

        Parsing needs to know which parameters are switches - otherwise
        `-Resume api` looks like -Resume taking the value "api". The target
        command's own metadata answers that, including common parameters like
        -WhatIf, so this stays correct as parameters are added.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [object[]]$Arguments = @()
    )

    $cmd   = Get-Command $Command -ErrorAction Stop
    $pos   = @()
    $named = @{}
    $i     = 0

    while ($i -lt $Arguments.Count) {
        $raw = "$($Arguments[$i])"

        if ($raw.StartsWith('-') -and $raw.Length -gt 1 -and $raw -notmatch '^-\d') {
            $name = $raw.Substring(1)

            # -Switch:$false is ordinary PowerShell and arrives here as the
            # single token "-Confirm:False". Without splitting on the colon the
            # whole thing is treated as a parameter NAME, matches nothing, and
            # gets passed through positionally - where it bound "False" to the
            # first positional parameter and produced a ValidateSet error about
            # a parameter the caller never mentioned.
            $inlineValue = $null
            $colon = $name.IndexOf(':')
            if ($colon -ge 0) {
                $inlineValue = $name.Substring($colon + 1)
                $name        = $name.Substring(0, $colon)
            }

            $p = @($cmd.Parameters.Values | Where-Object {
                    $_.Name -eq $name -or ($_.Aliases -contains $name)
                 })[0]
            if (-not $p) {
                $p = @($cmd.Parameters.Values | Where-Object { $_.Name -like "$name*" })[0]
            }

            if ($p -and $null -ne $inlineValue) {
                # The value came attached to the name, so do not eat the next
                # argument as well.
                if ($p.SwitchParameter) {
                    $named[$p.Name] = ($inlineValue -notmatch '^(?i)(false|0|\$false)$')
                } else {
                    $named[$p.Name] = $inlineValue
                }
                $i++
            } elseif ($p -and $p.SwitchParameter) {
                $named[$p.Name] = $true
                $i++
            } elseif ($p -and ($i + 1) -lt $Arguments.Count) {
                $named[$p.Name] = $Arguments[$i + 1]
                $i += 2
            } else {
                # Unknown parameter: pass it through and let the command say so
                # itself, rather than swallowing a typo.
                $pos += $Arguments[$i]
                $i++
            }
        } else {
            $pos += $Arguments[$i]
            $i++
        }
    }

    & $cmd @pos @named
}

function Invoke-ZtPad {
    <#
        `zt pad <sub>`. A sub-dispatcher rather than four more top-level verbs,
        because pad setup is a thing you do once and then forget, and it should
        not clutter the list you read every day.
    #>
    param([object[]]$Arguments = @())

    $sub  = ''
    $rest = @()
    if ($Arguments.Count -gt 0) { $sub = "$($Arguments[0])" }
    if ($Arguments.Count -gt 1) { $rest = $Arguments[1..($Arguments.Count - 1)] }

    switch -Regex ($sub) {
        '^(check|status)?$' { return (Invoke-ZtForward 'Test-ZellijTerminalPad' $rest) }
        '^(explain|help|what)$' { return (Invoke-ZtForward 'Show-ZellijTerminalPadGuide' $rest) }
        '^install$'         { return (Invoke-ZtForward 'Install-ZellijTerminalPad' $rest) }
        '^uninstall$'       { return (Invoke-ZtForward 'Uninstall-ZellijTerminalPad' $rest) }
        '^probe$'           { return (Invoke-ZtForward 'Debug-ZellijTerminalPad' $rest) }
        '^device$'          { return (Invoke-ZtForward 'Set-ZellijTerminalPadDevice' $rest) }
        default {
            Write-Warning "Unknown: zt pad '$sub'. Try: zt pad check | install | uninstall | probe | device"
        }
    }
}

function Invoke-ZellijTerminal {
    <#
    .SYNOPSIS
        Short command surface: zt <verb> [args].

    .DESCRIPTION
        zt                       list workspaces on this device
        zt ls [filter]           same, with a filter
        zt all                   include ones this device cannot reach
        zt waiting               list only sessions asking for input

        zt add [path]            register a folder for Claude (defaults to here)
        zt add . -Kind pwsh -Command '<cmd>'
                                 ...to run a command there instead
        zt add . -Kind pwsh      ...or just a shell, running nothing
        zt rm <id>               unregister it - also: unregister, forget
        zt publish <id>          promote it to the shared config

        zt pick                  choose one with the arrow keys and go to it

        zt start [id]            open its tab and run its command
        zt stop [id]             Ctrl+C what is running, keep the shell
        zt restart [id]          stop, then resume the same Claude session
        zt close [id]            close the tab, keep the registration

        Leave the id off any of those and you get the picker. Tab-complete
        it if you would rather type: `zt start <tab>`.

        zt attach                attach, or focus the window already attached
        zt next | zt prev        cycle tabs
        zt go                    jump to whoever is waiting
        zt sync                  drop records whose tabs are gone
        zt flag [id]             raise its hand so key 3 jumps to it
        zt unflag [id]           lower it again

        zt park                  stop everything, remember what was running
        zt restore               bring it back, resuming each conversation

        zt setup                 guided setup - walks every layer, explains it,
                                 offers to do it. Start here on a new machine.
        zt uninstall             remove everything install.ps1 put on this
                                 machine. Keeps your registrations; -Purge drops
                                 those too. -WhatIf shows it first.

        zt export [path]         save registrations, roots and the Command
                                 Palette setup to one portable file
        zt import <path>         merge one back in; -Force to overwrite

        zt roots                 what root names mean on this device
        zt root <name> <path>    define one
        zt config                open the JSON in your editor
        zt validate              check the JSON and say what is wrong
        zt check                 layer check

        zt pad                   what the macro pad is wired to
        zt pad explain           what it is for, and whether you need one
        zt pad install           wire it up (PowerToys; -Listener ahk)
        zt pad uninstall         unwire it

        zt palette               what the Command Palette extension adds

        zt sessions              Zellij SESSIONS - the level above tabs
        zt sessions kill <name>  stop a stray one

        zt hotkeys               Command Palette's global command hotkeys

        zt dock                  pin the workspace band to the palette dock
        zt dock -List            what is on the dock now

        zt help                  this

    .EXAMPLE
        zt
        zt start api -Resume
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Verb,

        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]]$Rest = @()
    )

    if (-not $Verb) { return (Get-ZellijTerminal | Format-ZtTable) }

    switch -Regex ($Verb) {
        '^(ls|list)$'      { return (Invoke-ZtForward 'Get-ZellijTerminal' $Rest |
                                     Format-ZtTable -Empty 'No workspace matches that filter.' `
                                                    -EmptyHint 'Everything registered:  zt') }
        '^all$'            { return (Invoke-ZtForward 'Get-ZellijTerminal' (@('-All') + $Rest) | Format-ZtTable) }
        '^waiting$'        { return (Invoke-ZtForward 'Get-ZellijTerminal' (@('-Waiting') + $Rest) |
                                     Format-ZtTable -Empty 'Nothing is waiting for input.' `
                                                    -EmptyHint 'Everything registered:  zt') }

        # THE PALETTE'S WORDS WORK HERE TOO. Its buttons say "Register a folder"
        # and "Unregister", and the CLI accepted neither - it took `add` and
        # `rm`, so the vocabulary a user had just been taught did not transfer.
        #
        # `remove` was the worst of it: it routes HERE, to unregister, while the
        # cmdlet actually named Remove-ZellijTerminalTab is what `close` calls.
        # The one verb containing "remove" pointed at the opposite thing from
        # the cmdlet named for it. Kept for muscle memory, no longer alone.
        #
        # `forget` because it is what the operation does - the directory is
        # untouched and only this device's registry changes, which is exactly
        # what the palette's confirmation dialog promises.
        '^(add|register)$'                { return (Invoke-ZtForward 'Register-ZellijTerminal' $Rest) }
        '^(rm|remove|unregister|forget)$' { return (Invoke-ZtForward 'Unregister-ZellijTerminal' $Rest) }
        '^publish$'        { return (Invoke-ZtForward 'Publish-ZellijTerminal' $Rest) }

        '^pick$'           { return (Invoke-ZtForward 'Select-ZellijTerminal' (@('-Go') + $Rest)) }
        '^start$'          { return (Invoke-ZtForward 'Start-ZellijTerminal' $Rest) }
        '^stop$'           { return (Invoke-ZtForward 'Stop-ZellijTerminal' $Rest) }
        '^restart$'        { return (Invoke-ZtForward 'Restart-ZellijTerminal' $Rest) }
        '^close$'          { return (Invoke-ZtForward 'Remove-ZellijTerminalTab' $Rest) }

        '^attach$'         { return (Invoke-ZtForward 'Connect-ZellijTerminal' $Rest) }
        '^next$'           { return (Invoke-ZtForward 'Switch-ZellijTerminal' (@('-Direction','next') + $Rest)) }
        '^prev$'           { return (Invoke-ZtForward 'Switch-ZellijTerminal' (@('-Direction','prev') + $Rest)) }
        '^go$'             { return (Invoke-ZtForward 'Switch-ZellijTerminal' (@('-Waiting') + $Rest)) }
        '^sync$'           { return (Invoke-ZtForward 'Sync-ZellijTerminal' $Rest) }
        '^flag$'           { return (Invoke-ZtForward 'Set-ZellijTerminalWaiting' $Rest) }
        '^unflag$'         { return (Invoke-ZtForward 'Set-ZellijTerminalWaiting' (@('-Clear') + $Rest)) }

        '^park$'           { return (Invoke-ZtForward 'Suspend-ZellijTerminal' $Rest) }
        '^restore$'        { return (Invoke-ZtForward 'Resume-ZellijTerminal' $Rest) }

        '^roots$'          { return (Invoke-ZtForward 'Get-ZellijTerminalRoot' $Rest) }
        '^root$'           { return (Invoke-ZtForward 'Set-ZellijTerminalRoot' $Rest) }
        '^config$'         { return (Invoke-ZtForward 'Edit-ZellijTerminalConfig' $Rest) }
        '^validate$'       { return (Invoke-ZtForward 'Test-ZellijTerminalConfig' $Rest) }
        '^check$'          { return (Invoke-ZtForward 'Test-ZellijTerminal' $Rest) }
        '^setup$'          { return (Invoke-ZtForward 'Start-ZellijTerminalSetup' $Rest) }
        '^uninstall$'      { return (Invoke-ZtForward 'Uninstall-ZellijTerminal' $Rest) }
        '^export$'         { return (Invoke-ZtForward 'Export-ZellijTerminal' $Rest) }
        '^import$'         { return (Invoke-ZtForward 'Import-ZellijTerminal' $Rest) }
        '^palette$'        { return (Invoke-ZtForward 'Show-ZellijTerminalPaletteGuide' $Rest) }
        '^pad$'            { return (Invoke-ZtPad $Rest) }
        '^sessions?$'      { return (Invoke-ZtSessions $Rest) }
        '^hotkeys?$'       { return (Invoke-ZtForward 'Get-ZellijTerminalHotkey' $Rest) }
        '^dock$'           { if ($Rest -contains '-List' -or $Rest -contains '-list') { return (Get-ZellijTerminalDock) }; return (Invoke-ZtForward 'Add-ZellijTerminalDock' $Rest) }
        '^(help|-h|--help)$' { return (Get-Help Invoke-ZellijTerminal -Detailed) }

        default {
            # `zt api` most likely means "show me api", not a typo worth an
            # error - but say so, or a mistyped verb looks like a silent filter.
            $hit = @(Get-ZellijTerminal -Name $Verb)
            if ($hit.Count -gt 0) { return ($hit | Format-ZtTable) }
            Write-Warning "Unknown verb '$Verb' and no workspace matches it. Try: zt help"
        }
    }
}

function Format-ZtTable {
    <#
        A compact fixed-width view. Deliberately not Format-Table: colour per
        state is the whole point of glancing at this, and Format-Table cannot
        colour a row.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]$InputObject,

        # What an empty result means HERE. Every view shares this formatter, so
        # without it a filtered view with no matches reported "nothing
        # registered" - which `zt waiting` said while two workspaces were
        # registered and running. An empty filter is not an empty registry, and
        # saying so sends you off to fix the wrong thing.
        [string]$Empty,
        [string]$EmptyHint
    )

    begin { $rows = @() }
    process { if ($InputObject) { $rows += $InputObject } }
    end {
        if ($rows.Count -eq 0) {
            if (-not $Empty) {
                $Empty     = 'Nothing registered on this device yet.'
                $EmptyHint = 'Add the folder you are in with:  zt add .'
            }
            Write-Host ''
            Write-Host "  $Empty" -ForegroundColor Yellow
            if ($EmptyHint) { Write-Host "  $EmptyHint" -ForegroundColor DarkGray }
            Write-Host ''
            return
        }

        Write-Host ''
        Write-Host ('  {0,-20} {1,-12} {2,-9} {3,-8} {4}' -f 'ID', 'STATE', 'AGE', 'KIND', 'PATH') -ForegroundColor Cyan
        Write-Host ('  ' + ('-' * 76)) -ForegroundColor DarkGray

        foreach ($r in $rows) {
            $colour = 'Gray'
            if ($r.State -eq 'running')     { $colour = 'Green'  }
            if ($r.State -eq 'tab-only')    { $colour = 'Cyan'   }
            if ($r.State -eq 'stale')       { $colour = 'DarkYellow' }
            if ($r.State -eq 'unavailable')  { $colour = 'DarkGray'   }
            if ($r.State -eq 'unregistered') { $colour = 'Magenta'    }
            if ($r.Waiting)                 { $colour = 'Yellow' }

            $state = $r.State
            if ($r.Waiting) { $state = 'WAITING' }

            $path = $r.Path
            if (-not $path -and $r.State -eq 'unregistered') {
                # Say what to do about it. A row with no path and no explanation
                # is why "zt shows one and the tab bar shows four" was baffling.
                $path = "(tab only - register it:  zt add <path> -Name $($r.Tab))"
            }
            if (-not $path) { $path = '(no root on this device)' }

            Write-Host ('  {0,-20} {1,-12} {2,-9} {3,-8} {4}' -f $r.Id, $state, $r.Age, $r.Kind, $path) -ForegroundColor $colour

            if ($r.Waiting -and $r.WaitEvent) {
                Write-Host ('  {0,-20} {1}' -f '', "  ^ $($r.WaitEvent)") -ForegroundColor DarkYellow
            }
        }
        Write-Host ''
    }
}

# ---------------------------------------------------------------------------
#  Completion
# ---------------------------------------------------------------------------
#  Typing an id you have to remember is the difference between a tool you use
#  and one you look up. Tab-complete every -Name from the registry.

$ztNameCompleter = {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

    try {
        Get-ZellijTerminal -All |
            Where-Object   { $_.Id -like "$wordToComplete*" } |
            ForEach-Object {
                $tip = "$($_.State) - $($_.Path)"
                [System.Management.Automation.CompletionResult]::new(
                    $_.Id, $_.Id, 'ParameterValue', $tip)
            }
    } catch { }
}

foreach ($fn in @('Start-ZellijTerminal', 'Stop-ZellijTerminal', 'Restart-ZellijTerminal',
                  'Remove-ZellijTerminalTab', 'Unregister-ZellijTerminal',
                  'Publish-ZellijTerminal', 'Get-ZellijTerminal')) {
    Register-ArgumentCompleter -CommandName $fn -ParameterName 'Name' -ScriptBlock $ztNameCompleter
}

# `zt start <tab>` has to complete too, or the short surface is worse than the
# long one. Without this it falls through to filesystem paths, which is actively
# unhelpful: the ids are not filenames.
Register-ArgumentCompleter -CommandName 'Invoke-ZellijTerminal' -ParameterName 'Rest' -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

    $verb = ''
    if ($commandAst -and $commandAst.CommandElements.Count -ge 2) {
        $verb = "$($commandAst.CommandElements[1].Extent.Text)"
    }

    try {
        if (@('start', 'stop', 'restart', 'close', 'rm', 'remove', 'unregister', 'forget',
              'publish', 'ls', 'list') -contains $verb) {
            Get-ZellijTerminal -All |
                Where-Object   { $_.Id -like "$wordToComplete*" } |
                ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new(
                        $_.Id, $_.Id, 'ParameterValue', "$($_.State) - $($_.Path)")
                }
        } elseif ($verb -eq 'root' -and $commandAst.CommandElements.Count -le 3) {
            # First argument only - the second is a path, and returning nothing
            # lets the shell offer its own path completion.
            Get-ZellijTerminalRoot |
                Where-Object   { $_.Name -like "$wordToComplete*" } |
                ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new(
                        $_.Name, $_.Name, 'ParameterValue', $_.Path)
                }
        }
    } catch { }
}

Register-ArgumentCompleter -CommandName 'Invoke-ZellijTerminal' -ParameterName 'Verb' -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

    # Must stay in step with the switch in Invoke-ZellijTerminal. A verb missing
    # here still works when typed - it just cannot be discovered, which for
    # something like `zt setup` defeats the point of it existing.
    $verbs = @('setup', 'uninstall', 'export', 'import', 'ls', 'all', 'waiting', 'pick', 'add', 'rm', 'publish', 'start', 'stop', 'restart',
               'close', 'attach', 'next', 'prev', 'go', 'sync', 'flag', 'unflag', 'park', 'restore', 'roots', 'root',
               'config', 'validate', 'check', 'pad', 'palette', 'dock', 'sessions', 'hotkeys', 'help')
    $verbs |
        Where-Object   { $_ -like "$wordToComplete*" } |
        ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
}










