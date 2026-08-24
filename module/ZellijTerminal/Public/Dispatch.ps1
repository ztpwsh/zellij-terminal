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

            # -Switch:$false is ordinary PowerShell. Without splitting on the
            # colon the whole thing is treated as a parameter NAME, matches
            # nothing, and gets passed through positionally - where it bound
            # "False" to the first positional parameter and produced a
            # ValidateSet error about a parameter the caller never mentioned.
            #
            # IT DOES NOT ARRIVE AS ONE TOKEN. This code was written believing
            # `-Confirm:$false` reached ValueFromRemainingArguments as the single
            # string "-Confirm:False". It does not - PowerShell splits it into
            # TWO elements, the string "-Confirm:" and the BOOLEAN $false:
            #
            #   [1] String  [-Confirm:]
            #   [2] Boolean [False]
            #
            # so the value half was an empty string, which is not $null, which
            # took the inline-value branch and evaluated `'' -notmatch false` to
            # TRUE. `zt rm x -Confirm:$false` therefore turned confirmation ON
            # and then threw on the leftover `False` - a safety flag inverted by
            # the code that exists to forward it. Only `-Confirm:0`, an Int32,
            # behaves the same way, so this is every form of it.
            $inlineValue = $null
            $extra       = 0
            $colon = $name.IndexOf(':')
            if ($colon -ge 0) {
                $inlineValue = $name.Substring($colon + 1)
                $name        = $name.Substring(0, $colon)

                if ($inlineValue -eq '' -and ($i + 1) -lt $Arguments.Count) {
                    $inlineValue = "$($Arguments[$i + 1])"
                    $extra       = 1
                }
            }

            $p = @($cmd.Parameters.Values | Where-Object {
                    $_.Name -eq $name -or ($_.Aliases -contains $name)
                 })[0]
            if (-not $p) {
                $p = @($cmd.Parameters.Values | Where-Object { $_.Name -like "$name*" })[0]
            }

            if ($p -and $null -ne $inlineValue) {
                # The value came attached to the name - either in the same token
                # or, for `-Switch:$false`, as the element after it, which $extra
                # accounts for.
                if ($p.SwitchParameter) {
                    $named[$p.Name] = ($inlineValue -notmatch '^(?i)(false|0|\$false)$')
                } else {
                    $named[$p.Name] = $inlineValue
                }
                $i += (1 + $extra)
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

function Invoke-ZtPaste {
    <#
        `zt paste [fix]`. Bare word reports, `fix` changes files - the same shape
        as `zt pad`, and deliberately so: the fix rewrites Windows Terminal's
        settings.json, which the rest of the rig goes out of its way never to
        touch. That must be a thing you asked for by name.
    #>
    param([object[]]$Arguments = @())

    $sub  = ''
    $rest = @()
    if ($Arguments.Count -gt 0) { $sub = "$($Arguments[0])" }
    if ($Arguments.Count -gt 1) { $rest = $Arguments[1..($Arguments.Count - 1)] }

    switch -Regex ($sub) {
        '^(check|status)?$'  { return (Invoke-ZtForward 'Test-ZellijTerminalPaste' $rest) }
        '^(fix|repair)$'     { return (Invoke-ZtForward 'Repair-ZellijTerminalPaste' $rest) }
        default {
            Write-Warning "Unknown: zt paste '$sub'. Try: zt paste | zt paste fix"
        }
    }
}

function Write-ZtHelpLine {
    <#
        One row of the help table. Split so the command and its explanation can
        be coloured differently - the whole point of not using Get-Help.
    #>
    param([string]$Command, [string]$Does, [string]$Indent = '  ')

    # An empty Command with a Does is a CONTINUATION line - the description
    # carrying on under the one above it. The first version returned a blank
    # line for that case, which silently dropped every continuation in the file
    # and left a gap where the explanation should have been.
    if (-not $Command -and -not $Does) { Write-Host ''; return }
    if (-not $Does) { Write-Host ($Indent + $Command) -ForegroundColor White; return }

    Write-Host ($Indent + $Command.PadRight(26)) -NoNewline -ForegroundColor White
    Write-Host $Does -ForegroundColor DarkGray
}

function Write-ZtHelpHeading {
    param([string]$Text)
    Write-Host ''
    Write-Host ('  ' + $Text) -ForegroundColor Cyan
}

function Show-ZtHelp {
    <#
        WHY THIS IS NOT `Get-Help Invoke-ZellijTerminal -Detailed`.

        It was, and what a user got was a cmdlet reference wrapped around the
        useful part: NAME, SYNOPSIS, a full SYNTAX line reading
        `Invoke-ZellijTerminal [[-Verb] <String>] [-Rest <Object[]>]` - which is
        not how anyone types this - and then, at the bottom, REMARKS advising
        them to run `Get-Help Invoke-ZellijTerminal -Examples` to see examples.
        Asking for help and being told to run a longer command to get the rest
        of the help is the wrong answer for a tool whose entire pitch is a short
        verb surface.

        Two things this must say that the old one did not:

          - `zac`. It is one of only two aliases this module exports and it is
            the first command install.ps1 tells you to run, and it appeared
            nowhere in the help. The help listed `zt attach` instead, so the
            name you were taught and the name you were shown were different.

          - that `remove` and `close` are not the pair they look like. See the
            comment on the dispatch table.
    #>
    param([switch]$Full)

    Write-Host ''
    Write-Host '  zt' -NoNewline -ForegroundColor Green
    Write-Host ' - the workspaces you run inside one Zellij session.' -ForegroundColor Gray

    Write-ZtHelpHeading 'Getting to the session'
    Write-ZtHelpLine 'zac' 'attach, or focus the window already attached.'
    Write-ZtHelpLine '' 'The one command that works before you are inside.'
    Write-ZtHelpLine 'zt attach' 'the same thing, spelled the long way'

    Write-ZtHelpHeading 'Looking'
    Write-ZtHelpLine 'zt' 'what is registered on this device, and its state'
    Write-ZtHelpLine 'zt ls [filter]' 'same, filtered'
    Write-ZtHelpLine 'zt all' 'include ones this device cannot reach'
    Write-ZtHelpLine 'zt waiting' 'only the ones asking for input'
    Write-ZtHelpLine 'zt home' 'the table plus this rig''s cheat sheet'

    Write-ZtHelpHeading 'Registering a folder'
    Write-ZtHelpLine 'zt add [path]' 'register it for Claude (defaults to here)'
    Write-ZtHelpLine 'zt add . -Start' '...and open its tab now'
    Write-ZtHelpLine 'zt add . -Kind pwsh -Command ''<cmd>''' ''
    Write-ZtHelpLine '' '...run a command there instead of Claude'
    Write-ZtHelpLine 'zt add . -Kind pwsh' '...or just a shell, running nothing'
    Write-ZtHelpLine 'zt rm <id>' 'unregister - the folder is untouched'
    Write-ZtHelpLine 'zt publish <id>' 'promote it to the shared config'

    Write-ZtHelpHeading 'Running one'
    Write-ZtHelpLine 'zt start [id]' 'open its tab and run its command'
    Write-ZtHelpLine 'zt stop [id]' 'Ctrl+C what is running, keep the shell'
    Write-ZtHelpLine 'zt restart [id]' 'stop, then resume the same Claude session'
    Write-ZtHelpLine 'zt close [id]' 'close the TAB, keep the registration'
    Write-ZtHelpLine 'zt pick' 'choose one with the arrow keys and go to it'
    Write-Host ''
    Write-Host '    Leave the id off any of those and you get the picker, or' -ForegroundColor DarkGray
    Write-Host '    tab-complete it:  zt start <tab>' -ForegroundColor DarkGray

    Write-ZtHelpHeading 'Moving between them'
    Write-ZtHelpLine 'zt go' 'jump to whoever is waiting'
    Write-ZtHelpLine 'zt next | zt prev' 'cycle claude-* tabs'
    Write-ZtHelpLine 'zt flag [id]' 'raise its hand so key 3 jumps to it'
    Write-ZtHelpLine 'zt unflag [id]' 'lower it again'

    Write-ZtHelpHeading 'A whole day'
    Write-ZtHelpLine 'zt park' 'stop everything, remember what was running'
    Write-ZtHelpLine 'zt restore' 'bring it back, resuming each conversation'
    Write-ZtHelpLine 'zt sync' 'drop records whose tabs are gone'

    # TWO VERBS THAT LOOK LIKE A PAIR AND ARE NOT. Worth the ink: `remove` is
    # accepted for muscle memory and routes to UNREGISTER, while the cmdlet
    # actually named Remove-ZellijTerminalTab is what `close` calls. Someone
    # leaning on tab-completion meets this at the worst possible moment.
    Write-Host ''
    Write-Host '  Careful:' -ForegroundColor Yellow
    Write-Host '    zt close   closes the TAB and keeps the registration.' -ForegroundColor Gray
    Write-Host '    zt rm      forgets the WORKSPACE and leaves the folder alone.' -ForegroundColor Gray
    Write-Host '    `zt remove` is an alias for rm, NOT for close - they are' -ForegroundColor Gray
    Write-Host '    opposite ends of the thing, and neither deletes any files.' -ForegroundColor Gray

    Write-ZtHelpHeading 'First five minutes on a machine that is already set up'
    Write-Host '    zac                       start or attach the session'   -ForegroundColor White
    Write-Host '    cd C:\code\web-api'                                       -ForegroundColor White
    Write-Host '    zt add . -Start           register it and open its tab'   -ForegroundColor White
    Write-Host '    zt                        see it listed as running'       -ForegroundColor White
    Write-Host '    zt go                     later, jump to whoever wants you' -ForegroundColor White

    if (-not $Full) {
        Write-Host ''
        Write-Host '  zt help -Full' -NoNewline -ForegroundColor White
        Write-Host '             setup, diagnostics, the pad, the palette' -ForegroundColor DarkGray
        Write-Host ''
        return
    }

    Write-ZtHelpHeading 'Setting up and checking'
    Write-ZtHelpLine 'zt setup' 'guided setup - walks every layer, explains it,'
    Write-ZtHelpLine '' 'offers to do it. Start here on a new machine.'
    Write-ZtHelpLine 'zt check' 'layer check on this machine'
    Write-ZtHelpLine 'zt diag' 'one evidence bundle to a file, for reading'
    Write-ZtHelpLine '' 'elsewhere. Use it when check is clean and'
    Write-ZtHelpLine '' 'the rig still does not work.'
    Write-ZtHelpLine 'zt validate' 'check the JSON and say what is wrong'
    Write-ZtHelpLine 'zt config' 'open the JSON in your editor'
    Write-ZtHelpLine 'zt uninstall' 'remove what install.ps1 put here. Keeps your'
    Write-ZtHelpLine '' 'registrations; -Purge drops those too;'
    Write-ZtHelpLine '' '-WhatIf shows it first.'

    Write-ZtHelpHeading 'Where things live'
    Write-ZtHelpLine 'zt roots' 'what root names mean on this device'
    Write-ZtHelpLine 'zt root <name> <path>' 'define one'
    Write-ZtHelpLine 'zt export [path]' 'save registrations, roots and the palette'
    Write-ZtHelpLine '' 'setup to one portable file'
    Write-ZtHelpLine 'zt import <path>' 'merge one back in; -Force to overwrite'

    Write-ZtHelpHeading 'The hardware and the shells around it'
    Write-ZtHelpLine 'zt pad' 'what the macro pad is wired to'
    Write-ZtHelpLine 'zt pad explain' 'what it is for, and whether you need one'
    Write-ZtHelpLine 'zt pad install' 'wire it up (PowerToys; -Listener ahk)'
    Write-ZtHelpLine 'zt paste' 'why Ctrl+V shreds a multi-line paste in Zellij'
    Write-ZtHelpLine 'zt paste fix' 'fix it - both halves, with backups'
    Write-ZtHelpLine 'zt palette' 'what the Command Palette extension adds'
    Write-ZtHelpLine 'zt hotkeys' 'the palette''s global command hotkeys'
    Write-ZtHelpLine 'zt dock' 'pin the workspace band to the palette dock'
    Write-ZtHelpLine 'zt sessions' 'Zellij SESSIONS - the level above tabs'
    Write-ZtHelpLine 'zt sessions kill <name>' 'stop a stray one'

    Write-Host ''
    Write-Host '  Every verb also has PowerShell help:  Get-Help Register-ZellijTerminal -Full' -ForegroundColor DarkGray
    Write-Host ''
}

function Show-ZtHome {
    <#
        What the `home` tab lands on. The workspace table answers "what have I
        got"; the rest answers "and what do I type", which is the question a tab
        that opens on a cold start is actually being asked.

        Deliberately a PRINT, not a loop. A refreshing dashboard would be a
        resident process in a pane for information that changes a few times an
        hour, and this rig does not add resident processes.

        The pad rows come from Get-ZtPadKeyMap - the same definition that writes
        the remaps and checks them - so a cheat sheet cannot describe keys the
        pad is not wired to.
    #>
    Write-Host ''
    Write-Host '  zt' -NoNewline -ForegroundColor Green
    Write-Host ' - what you have, and what to type.' -ForegroundColor Gray

    Get-ZellijTerminal | Format-ZtTable

    Write-Host '  Most of what you need' -ForegroundColor Cyan
    Write-ZtHelpLine 'zt go' 'jump to whoever is waiting'
    Write-ZtHelpLine 'zt pick' 'choose a workspace with the arrow keys'
    Write-ZtHelpLine 'zt add . -Start' 'register the folder you are in, and open it'
    Write-ZtHelpLine 'zt start | stop | restart' 'run one, halt it, resume the conversation'
    Write-ZtHelpLine 'zt park / zt restore' 'put the day down, pick it back up'

    $keys = $null
    try { $keys = @(Get-ZtPadKeyMap) } catch { $keys = @() }
    if ($keys.Count -gt 0) {
        Write-Host ''
        Write-Host '  The pad' -ForegroundColor Cyan
        foreach ($k in $keys) {
            Write-ZtHelpLine ("key " + $k.Key + "  " + $k.Chord) $k.Does
        }
    }

    Write-Host ''
    Write-Host '  zt help' -NoNewline -ForegroundColor White
    Write-Host '                   everything else' -ForegroundColor DarkGray
    Write-Host ''
}

function Invoke-ZellijTerminal {
    <#
    .SYNOPSIS
        Short command surface: zt <verb> [args].

    .DESCRIPTION
        The full verb table is printed by `zt help`, and `zt help -Full` adds
        setup, diagnostics, the pad and the palette.

        It is deliberately NOT repeated here. This block used to carry the whole
        surface, which meant two copies of it with nothing keeping them in step,
        and `zt help` rendered this one wrapped in NAME / SYNOPSIS / SYNTAX plus
        a REMARKS footer advising the reader to run a second command to see the
        examples. Show-ZtHelp is now the one copy.

        The shape, so this page is not useless on its own:

            zac                 attach, or focus the window already attached
            zt                  what is registered here, and its state
            zt home             that table plus a cheat sheet
            zt add . -Start     register the folder you are in and open its tab
            zt go               jump to whoever is waiting
            zt help             all of it

    .EXAMPLE
        zt
        Lists every workspace registered on this device, with its state.

    .EXAMPLE
        zt add . -Start
        Registers the current folder and opens its tab in one step.

    .EXAMPLE
        zt start api -Resume
        Opens the api tab and resumes its previous Claude conversation.
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
        '^diag$'           { return (Invoke-ZtForward 'Get-ZellijTerminalDiagnostic' $Rest) }
        '^setup$'          { return (Invoke-ZtForward 'Start-ZellijTerminalSetup' $Rest) }
        '^uninstall$'      { return (Invoke-ZtForward 'Uninstall-ZellijTerminal' $Rest) }
        '^export$'         { return (Invoke-ZtForward 'Export-ZellijTerminal' $Rest) }
        '^import$'         { return (Invoke-ZtForward 'Import-ZellijTerminal' $Rest) }
        '^palette$'        { return (Invoke-ZtForward 'Show-ZellijTerminalPaletteGuide' $Rest) }
        '^pad$'            { return (Invoke-ZtPad $Rest) }
        '^paste$'          { return (Invoke-ZtPaste $Rest) }
        '^sessions?$'      { return (Invoke-ZtSessions $Rest) }
        '^hotkeys?$'       { return (Invoke-ZtForward 'Get-ZellijTerminalHotkey' $Rest) }
        '^dock$'           { if ($Rest -contains '-List' -or $Rest -contains '-list') { return (Get-ZellijTerminalDock) }; return (Invoke-ZtForward 'Add-ZellijTerminalDock' $Rest) }
        '^home$'           { return (Show-ZtHome) }

        # NOT Get-Help. See the comment on Show-ZtHelp: the cmdlet reference
        # buried the verb table in SYNTAX and NAME, and signed off by telling
        # you to run a second, longer command to see the examples.
        '^(help|-h|--help|\?)$' {
            if ($Rest -contains '-Full' -or $Rest -contains '-full' -or $Rest -contains 'full') {
                return (Show-ZtHelp -Full)
            }
            return (Show-ZtHelp)
        }

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
               'config', 'validate', 'check', 'diag', 'pad', 'paste', 'palette', 'dock', 'sessions', 'hotkeys', 'home', 'help')
    $verbs |
        Where-Object   { $_ -like "$wordToComplete*" } |
        ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
}










