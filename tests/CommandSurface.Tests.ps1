<#
    The surface a person meets: what `zt help` prints, what the home tab lands
    on, and whether `zt <verb> -Switch:$false` still means what it says.

    These are usability assertions, which is an unusual thing to test - but each
    one here is a defect that was found by reading the output as a newcomer
    would, not by reasoning about the code:

      - `zac` is one of only two aliases this module exports and the first
        command install.ps1 tells you to run, and it appeared NOWHERE in the
        help. The help offered `zt attach` instead, so the name you were taught
        and the name you were shown were different.

      - `zt help` was `Get-Help Invoke-ZellijTerminal -Detailed`, which buried
        the verb table under NAME / SYNOPSIS / a SYNTAX line nobody types, and
        signed off with REMARKS advising the reader to run a SECOND, longer
        command to see the examples.

      - `zt remove` routes to unregister while the cmdlet named
        Remove-ZellijTerminalTab is what `close` calls. Opposite ends of the
        thing, one word apart.

      - `zt add .` registered and stopped, leaving "and how do I open it" as an
        exercise.

    Write-Host goes to the INFORMATION stream, so capturing this output needs
    `6>&1`. Without it every match below passes against an empty string, which
    is the failure mode these tests are most likely to acquire.

    Pester 5/6. The help and home assertions need the module; they skip where it
    cannot be imported. The source assertions read files and always run.
#>

BeforeDiscovery {
    # -Skip: ON A DESCRIBE IS EVALUATED AT DISCOVERY, before any BeforeAll has
    # run. Deciding this in BeforeAll left every module-dependent Describe here
    # skipped on a machine where the module imports perfectly - 21 skips where
    # there should have been 4, and a green run that had checked none of it.
    # A skip that hides the thing it is skipping over is worse than a failure.
    $script:HasModule = $false
    try {
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'module/ZellijTerminal/ZellijTerminal.psd1') `
            -Force -ErrorAction Stop
        $script:HasModule = $true
    } catch { }
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Dispatch = Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Dispatch.ps1'
    $script:Registry = Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Registry.ps1'
    $script:Template = Join-Path $script:RepoRoot 'zellij/layouts/claude.kdl.template'

    $script:DispatchText = Get-Content -LiteralPath $script:Dispatch -Raw
    $script:RegistryText = Get-Content -LiteralPath $script:Registry -Raw
    $script:TemplateText = Get-Content -LiteralPath $script:Template -Raw

    # Import by explicit path. Importing by NAME loads whatever the junction
    # points at, which on this machine is a published clone - so a change here
    # would be tested against code it is not in.
    $script:HasModule = $false
    try {
        Import-Module (Join-Path $script:RepoRoot 'module/ZellijTerminal/ZellijTerminal.psd1') -Force -ErrorAction Stop
        $script:HasModule = $true
    } catch { }

    if ($script:HasModule) {
        $script:Help     = (Invoke-ZellijTerminal 'help' 6>&1 | Out-String)
        $script:HelpFull = (Invoke-ZellijTerminal 'help' '-Full' 6>&1 | Out-String)
    } else {
        $script:Help = ''; $script:HelpFull = ''
    }
}

Describe 'zt help' -Skip:(-not $script:HasModule) {

    It 'prints something at all' {
        # Guards every assertion below: Write-Host writes to the information
        # stream, so a capture without 6>&1 is empty and everything passes.
        $script:Help.Length | Should -BeGreaterThan 200
    }

    It 'is not a cmdlet reference' {
        # The three headings Get-Help emits. Their absence is the whole point.
        $script:Help | Should -Not -Match '(?m)^SYNTAX\s*$'
        $script:Help | Should -Not -Match 'Invoke-ZellijTerminal \[\[-Verb\]'
        $script:Help | Should -Not -Match 'To see the examples, type'
    }

    It 'names zac, which the old help never did' {
        $script:Help | Should -Match '(?m)^\s*zac\s'
    }

    It 'warns that close and rm are not the pair they look like' {
        $script:Help | Should -Match 'zt close'
        $script:Help | Should -Match 'zt rm'
        $script:Help | Should -Match 'remove'
    }

    It 'shows a worked sequence rather than pointing at one' {
        # The old help had two example lines and told you to run another command
        # to see them.
        $script:Help | Should -Match 'zt add \. -Start'
    }

    It 'offers the long form instead of printing everything' {
        $script:Help | Should -Match 'zt help -Full'
    }

    It 'keeps setup and diagnostics OUT of the short form' {
        # The short form is for the person who uses this daily. Setup is for the
        # person doing it once.
        $script:Help | Should -Not -Match 'Setting up and checking'
    }

    It 'puts them in the long form' {
        $script:HelpFull | Should -Match 'Setting up and checking'
        $script:HelpFull | Should -Match 'zt pad'
        $script:HelpFull | Should -Match 'zt palette'
    }

    It 'renders continuation lines rather than swallowing them' {
        # The first version returned a blank line for a row with no command,
        # which silently dropped every wrapped description in the file. Two of
        # them were gone before anyone read the output.
        $script:HelpFull | Should -Match 'run a command there instead of Claude'
        $script:HelpFull | Should -Match 'Start here on a new machine'
    }
}

Describe 'zt home' -Skip:(-not $script:HasModule) {

    It 'is a verb' {
        $script:DispatchText | Should -Match "'\^home\`$'"
    }

    It 'tab-completes' {
        $script:DispatchText | Should -Match "'hotkeys', 'home', 'help'"
    }

    It 'prints the table AND what to type' {
        $out = (Invoke-ZellijTerminal 'home' 6>&1 | Out-String)
        $out | Should -Match 'zt go'
        $out | Should -Match 'zt pick'
    }

    It 'takes its pad rows from the map that writes the remaps' {
        # A hand-typed cheat sheet can advertise a key the pad is not wired to.
        # Reading Get-ZtPadKeyMap means the sheet and the remaps cannot disagree.
        $script:DispatchText | Should -Match 'Get-ZtPadKeyMap'
    }

    It 'does not loop' {
        # A refreshing dashboard would be a resident process in a pane, which is
        # the one thing this rig does not do.
        $script:DispatchText | Should -Not -Match '(?m)^\s*while \(\$true\).*\n.*Show-ZtHome'
    }
}

Describe 'The home tab lands on it' {

    It 'runs zt home, not bare zt' {
        $script:TemplateText | Should -Match 'zt home"'
    }
}

Describe 'zt add -Start' {

    It 'exists' {
        $script:RegistryText | Should -Match '\[switch\]\$Start'
    }

    It 'is a switch, so it is off unless asked for' {
        # NOT the default: the hook calls Register on every session start, so a
        # default -Start would reopen tabs underneath you.
        $script:RegistryText | Should -Not -Match '\[switch\]\$Start\s*=\s*\$true'
    }

    It 'opens the tab through Start-ZellijTerminal rather than reimplementing it' {
        $script:RegistryText | Should -Match 'Start-ZellijTerminal -Name \$Id'
    }

    It 'tells you how to open it when you did not pass -Start' {
        # The gap this closes: `zt add .` printed a registration and stopped.
        $script:RegistryText | Should -Match 'open it with:'
    }

    It 'only says so for a NEW registration' {
        # The hook re-registers constantly; a hint on every tool call would be
        # noise on the latency path.
        $script:RegistryText | Should -Match 'elseif \(\$existing\.Count -eq 0\)'
    }
}

Describe 'Forwarding a -Switch:$false through zt' -Skip:(-not $script:HasModule) {

    It 'arrives as two elements, which is why this needed fixing' {
        # Pin the PowerShell behaviour the forwarder has to cope with. The code
        # was written believing it was one token, "-Confirm:False".
        function Test-ZtRemaining {
            param([Parameter(Position = 0)][string]$Verb,
                  [Parameter(ValueFromRemainingArguments = $true)][object[]]$Rest)
            return $Rest
        }
        $got = @(Test-ZtRemaining 'rm' 'x' -Confirm:$false)
        $got.Count             | Should -Be 3
        "$($got[1])"           | Should -Be '-Confirm:'
        $got[2]                | Should -BeOfType [bool]
        $got[2]                | Should -BeFalse
    }

    It 'does not invert the switch it is forwarding' {
        # The bug: the value half was an empty string, which is not $null, so it
        # took the inline-value branch and `'' -notmatch false` evaluated TRUE.
        # `zt rm x -Confirm:$false` turned confirmation ON and then threw on the
        # leftover boolean. A safety flag inverted by the code that forwards it.
        $script:DispatchText | Should -Match '\$extra\s*=\s*1'
        $script:DispatchText | Should -Match '\$i \+= \(1 \+ \$extra\)'
    }

    It 'still passes a bare switch, and a switch with a value, correctly' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('zt-cs-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $id = Split-Path $tmp -Leaf
        try {
            Invoke-ZellijTerminal 'add' $tmp 6>&1 | Out-Null
            @(Get-ZellijTerminal -Name $id -All).Count | Should -Be 1

            # -KeepRunning is a bare switch, -Confirm:$false is the split form.
            # Both have to survive the same call.
            Invoke-ZellijTerminal 'rm' $id '-KeepRunning' '-Confirm:$false' 6>&1 | Out-Null
        } finally {
            # Never leave a registration behind, whatever failed above - but
            # only if one survived, or the happy path prints a warning about
            # failing to remove what it has just successfully removed.
            if (@(Get-ZellijTerminal -Name $id -All).Count -gt 0) {
                try {
                    Unregister-ZellijTerminal -Name $id -KeepRunning -Confirm:$false `
                        -ErrorAction SilentlyContinue -WarningAction SilentlyContinue 6>&1 | Out-Null
                } catch { }
            }
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }

        @(Get-ZellijTerminal -Name $id -All).Count | Should -Be 0
    }
}
