<#
    Attaching: what zellij can be asked, and what Windows Terminal cannot.

    This file exists because the whole of 0.7.1 and 0.7.2 changed the attach
    path and nothing tested it. What that cost, in order:

      - The Terminal window check matched process name WindowsTerminal only, so
        on Preview and Canary it read every machine as having no window open and
        zac opened a second mirrored client every time.
      - The check it fed could never have worked anyway. Terminal hosts EVERY
        WINDOW IN ONE PROCESS, so a before/after count of processes cannot rise
        when a window appears, and the comparison reported success
        unconditionally.
      - The cold path recorded its window on wt.exe's exit code, which is 0 as
        soon as the tab is handed off and says nothing about whether
        `zellij attach` ever ran.

    So the tests here are about the difference between a question that can be
    answered and one that cannot. zellij answers "how many clients are attached
    and what is each running" - that parse is pure, and it is tested against
    captured output. Terminal answers nothing about window focus, and the tests
    that remain are source-level pins on the code NOT pretending otherwise.

    Green on a machine with no Zellij, no Windows Terminal and nothing
    installed: every case here is either a string operation or a fixture.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'module/ZellijTerminal/ZellijTerminal.psd1') -Force -ErrorAction SilentlyContinue
    $script:M = Get-Module ZellijTerminal

    $script:Control   = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Control.ps1') -Raw
    $script:Core      = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'module/ZellijTerminal/Private/Core.ps1') -Raw
    $script:Dispatch  = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Dispatch.ps1') -Raw
    $script:TestSetup = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts/Test-Setup.ps1') -Raw
    $script:Ahk       = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'pad/macropad.ahk') -Raw
}

Describe 'The list-clients parse' {

    # Captured from `zellij --session claude action list-clients` on 0.44.3.
    # The CLIENT_ID column is left-aligned and padded to the RIGHT, so rows
    # carry no leading whitespace - but the parse trims anyway, because a parse
    # anchored on today's padding is one release away from being wrong for no
    # reason.

    It '<Label> -> <Expected> client(s)' -ForEach @(
        @{ Label    = 'header only, which is what a detached session prints while still exiting 0'
           Expected = 0
           Text     = "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND" }

        @{ Label    = 'one attached client'
           Expected = 1
           Text     = "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND`n1         terminal_1     pwsh.exe" }

        @{ Label    = 'two clients, which is the mirrored case zac exists to avoid'
           Expected = 2
           Text     = "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND`n1         terminal_1     pwsh.exe`n2         terminal_3     claude.exe" }

        @{ Label    = 'CRLF line endings'
           Expected = 1
           Text     = "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND`r`n1         terminal_1     pwsh.exe`r`n" }

        @{ Label    = 'a trailing blank line'
           Expected = 1
           Text     = "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND`n1         terminal_1     pwsh.exe`n`n" }

        @{ Label    = 'rows indented by a future version that right-aligns the id'
           Expected = 2
           Text     = "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND`n  1       terminal_1     pwsh.exe`n  2       terminal_3     claude.exe" }

        @{ Label    = 'no output at all'
           Expected = 0
           Text     = '' }

        # THE ONE THAT WAS WRONG IN SHIPPED CODE. Captured verbatim on 0.44.3:
        # a missing session prints prose and exits 0, and a parse that counted
        # "every line that is not the header" read it as three attached clients.
        @{ Label    = 'the not-found message, which zellij prints while exiting 0'
           Expected = 0
           Text     = "Session 'nope' not found. The following sessions are active:`nauspicious-pigeon [Created 2h 10m 19s ago] `nclaude [Created 7h 44m 4s ago] (current)" }
    ) {
        (& $script:M { param($t) Measure-ZtClientRows $t } $Text) | Should -Be $Expected
    }

    It 'tells the two ends apart, so an always-zero parse cannot pass this file' {
        # The negative control. Every case above could be satisfied by a
        # function that returns 0, or by one that counts every line including
        # the header, if the table only ever held one shape.
        $none = & $script:M { Measure-ZtClientRows "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND" }
        $some = & $script:M { Measure-ZtClientRows "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND`n1  terminal_1  pwsh.exe" }
        $none | Should -Be 0
        $some | Should -Be 1
        $some | Should -BeGreaterThan $none
    }

    It 'reports -1 rather than 0 when zellij cannot answer' {
        # "No clients" and "no answer" lead to opposite decisions: the first
        # says open a window, the second says do not act on what you think you
        # know. zac compares this count before and after a launch, and 0 for a
        # failed call would read as "nothing changed".
        $count = & $script:M { Get-ZtClientCount -Session 'zt-no-such-session-xyz' }
        $count | Should -Be -1
    }

    It 'reports -1 rather than throwing when zellij is not installed at all' {
        # THIS IS THE CI CONDITION, and it is why the assertion above was not
        # enough. A hosted runner has no zellij, so `& zellij` threw
        # CommandNotFoundException straight out of Invoke-ZtZellij - and every
        # machine with the rig installed was structurally incapable of noticing,
        # because the command was always there. The suite was green on exactly
        # the population that could not see the bug.
        #
        # PATH is emptied rather than filtered, so this does not depend on where
        # zellij happens to be installed. Restored in a finally, because leaking
        # an empty PATH into the rest of the run would be its own mystery.
        $orig = $env:PATH
        try {
            $env:PATH = ''
            (& $script:M { Get-ZtClientCount -Session 'claude' }) | Should -Be -1
            (& $script:M { Test-ZtSession -Session 'claude' })    | Should -BeFalse
        } finally {
            $env:PATH = $orig
        }
    }
}

Describe 'Get-ZtWtWindowPreference' {

    # firstWindowPreference = persistedWindowLayout restores the saved layout
    # when the FIRST window opens, and on this rig that layout is a window
    # already running `zellij attach` - so a cold zac gets two clients on one
    # session and nothing downstream can tell them apart. The setting is the
    # only place to catch it, which makes reading it correctly load-bearing.

    BeforeAll {
        $script:RealLocal = $env:LOCALAPPDATA
        $script:FakeLocal = Join-Path ([System.IO.Path]::GetTempPath()) ('zt-wtpref-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:WtDir     = Join-Path $script:FakeLocal 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
        New-Item -ItemType Directory -Path $script:WtDir -Force | Out-Null
        $script:Mod = Get-Module ZellijTerminal
    }

    # Restored after EVERY case, not just at the end. Portability.Tests.ps1
    # only restores in AfterAll, so a test appended to that Describe would
    # silently inherit a fake LOCALAPPDATA - the sort of thing that makes a
    # later failure impossible to read.
    AfterEach {
        $env:LOCALAPPDATA = $script:RealLocal
    }

    AfterAll {
        $env:LOCALAPPDATA = $script:RealLocal
        Remove-Item -LiteralPath $script:FakeLocal -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'finds the setting in a file that has comments in it' {
        $settings = @'
{
    // Terminal writes comments into this file.
    "$help": "https://aka.ms/terminal-documentation",
    "firstWindowPreference": "persistedWindowLayout",
    "profiles": { "list": [] }
}
'@
        Set-Content -LiteralPath (Join-Path $script:WtDir 'settings.json') -Value $settings -Encoding UTF8
        $env:LOCALAPPDATA = $script:FakeLocal

        (& $script:Mod { Get-ZtWtWindowPreference }) | Should -Be 'persistedWindowLayout'
    }

    It 'ignores a commented-out setting rather than reporting it' {
        # Terminal writes its own defaults out commented. Matching the first
        # occurrence anywhere in the text would warn about a setting the user
        # does not have, and a warning you cannot find in the file is worse
        # than silence.
        $settings = @'
{
    // "firstWindowPreference": "persistedWindowLayout",
    "defaultProfile": "{574e775e-4f2a-5b96-ac1e-a2962a402336}",
    "profiles": { "list": [] }
}
'@
        Set-Content -LiteralPath (Join-Path $script:WtDir 'settings.json') -Value $settings -Encoding UTF8
        $env:LOCALAPPDATA = $script:FakeLocal

        (& $script:Mod { Get-ZtWtWindowPreference }) | Should -BeNullOrEmpty
    }

    It 'reads the live setting when a commented one appears above it' {
        $settings = @'
{
    // "firstWindowPreference": "persistedWindowLayout",
    "firstWindowPreference": "defaultProfile",
    "profiles": { "list": [] }
}
'@
        Set-Content -LiteralPath (Join-Path $script:WtDir 'settings.json') -Value $settings -Encoding UTF8
        $env:LOCALAPPDATA = $script:FakeLocal

        (& $script:Mod { Get-ZtWtWindowPreference }) | Should -Be 'defaultProfile'
    }

    It 'returns null when there is no settings file at all, instead of throwing' {
        $env:LOCALAPPDATA = Join-Path ([System.IO.Path]::GetTempPath()) ('zt-wtpref-absent-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

        (& $script:Mod { Get-ZtWtWindowPreference }) | Should -BeNullOrEmpty
    }
}

Describe 'Where Windows Terminal keeps settings.json' {

    It 'the module has ONE list of the three locations, and every reader uses it' {
        # Store, Preview and unpackaged. A Scoop or portable install keeps its
        # settings ONLY in the third, and leaving it out made the checks that
        # depend on it report "not found - skipped" on exactly the installs
        # they were written for.
        #
        # This used to grep the whole file for the three strings, which passed
        # while TWO other readers carried their own two-entry copies that
        # omitted the unpackaged path - the file contained all three, just not
        # in the places that mattered. Now: the list exists exactly once, and no
        # reader builds its own.
        $script:Core | Should -Match 'Microsoft\.WindowsTerminal_8wekyb3d8bbwe'
        $script:Core | Should -Match 'Microsoft\.WindowsTerminalPreview_8wekyb3d8bbwe'
        $script:Core | Should -Match 'Microsoft\\Windows Terminal\\settings\.json'

        $stable = @([regex]::Matches($script:Core, 'Microsoft\.WindowsTerminal_8wekyb3d8bbwe')).Count
        $stable | Should -Be 1 -Because (
            "the settings.json locations must be listed once, in Get-ZtTerminalProfilePaths - $stable copies found, " +
            'and a second copy is how the unpackaged path came to be missing from two readers')
    }

    It 'Test-Setup.ps1 mirrors that list, because it cannot import the module' {
        # It has to parse under Windows PowerShell 5.1, so it carries its own
        # copy. A mirror nobody pins is a mirror that drifts.
        $script:TestSetup | Should -Match 'Microsoft\.WindowsTerminal_8wekyb3d8bbwe'
        $script:TestSetup | Should -Match 'Microsoft\.WindowsTerminalPreview_8wekyb3d8bbwe'
        $script:TestSetup | Should -Match 'Microsoft\\Windows Terminal\\settings\.json'
    }

    It 'both copies drop full-line comments before matching' {
        $script:Core      | Should -Match "TrimStart\(\) -notlike '//\*'"
        $script:TestSetup | Should -Match "TrimStart\(\) -notlike '//\*'"
    }
}

Describe 'What zac must keep doing' {

    # Source-level, following Uninstall.Tests.ps1. Attaching for real would need
    # a Zellij session, a Terminal window and a machine nobody is using, and the
    # things worth pinning here are decisions rather than behaviour.

    It 'matches every Windows Terminal channel, not just the stable one' {
        # This IS the bug that shipped. Preview and Canary are separate
        # processes under separate names, so knowing only WindowsTerminal read
        # those machines as having nothing hosting the session and sent zac down
        # the branch that opens a second mirrored client.
        #
        # PIN THE ASSIGNMENT, NOT THE TOKENS. The first version of this test
        # matched the three names anywhere in Core.ps1 read raw - and the
        # COMMENTS above the code name all three, so deleting them from the
        # actual list would have left this green. A pin satisfied by prose is
        # not a pin; it is the same reporting-success-without-checking this file
        # was written to prevent, one level up.
        $script:Core | Should -Match "\`$terminals\s*=\s*'WindowsTerminal\.exe',\s*'WindowsTerminalPreview\.exe',\s*'WindowsTerminalCanary\.exe'"
    }

    It 'agrees with the pad script about what those processes are called' {
        # pad/macropad.ahk matches the same three to decide whether the chord
        # arrived in a terminal. Two lists of the same three names, and nothing
        # holding them together, is how the module came to know only one.
        #
        # Comments stripped from both sides first, for the reason above.
        $coreCode = ($script:Core -split "`r?`n" | Where-Object { $_.TrimStart() -notlike '#*' }) -join "`n"
        $ahkCode  = ($script:Ahk  -split "`r?`n" | Where-Object { $_.TrimStart() -notlike ';*' }) -join "`n"

        foreach ($name in 'WindowsTerminal', 'WindowsTerminalPreview', 'WindowsTerminalCanary') {
            $ahkCode  | Should -Match ([regex]::Escape($name + '.exe'))
            $coreCode | Should -Match ([regex]::Escape($name + '.exe'))
        }
    }

    It 'asks whether a Terminal hosts THIS session, not whether any window is open' {
        # The old gate was "does any Terminal window exist on this machine",
        # which is true while the client is attached from a different terminal
        # application entirely - and raising a window then did nothing for the
        # session being asked about.
        $script:Control | Should -Match 'Get-ZtTerminalHostingSession'
    }

    It 'finds nothing hosting a session that does not exist' {
        # Machine-independent: whatever is or is not running here, no terminal
        # is hosting a client of a session with this name.
        (& $script:M { Get-ZtTerminalHostingSession -Session 'zt-no-such-session-xyz' }) | Should -BeNullOrEmpty
    }

    It 'finds the terminal hosting a session that IS running here' {
        # THE NEGATIVE CONTROL. Without this, a function that returned $null
        # unconditionally would satisfy the test above and prove nothing - the
        # same false green this file exists to refuse.
        #
        # It needs a real session in a real Terminal, which a CI runner has
        # neither of, so it skips rather than asserting. A skip that names its
        # reason is honest; a test that passes vacuously is not.
        $sessions = if (Get-Command zellij -ErrorAction SilentlyContinue) {
            (& zellij list-sessions 2>&1 | Out-String)
        } else { '' }

        $name = $null
        foreach ($line in ($sessions -replace "`e\[[0-9;]*m", '' -split "`r?`n")) {
            $m = [regex]::Match($line.Trim(), '^(?<n>\S+)\s+\[Created\s')
            if ($m.Success -and $line -notmatch 'EXITED') { $name = $m.Groups['n'].Value; break }
        }

        if (-not $name) {
            Set-ItResult -Skipped -Because 'no live zellij session on this machine to find a terminal for'
            return
        }

        $hostPid = & $script:M { param($s) Get-ZtTerminalHostingSession -Session $s } $name
        if (-not $hostPid) {
            Set-ItResult -Skipped -Because "session '$name' is not being hosted by a Windows Terminal here"
            return
        }

        $proc = Get-Process -Id $hostPid -ErrorAction SilentlyContinue
        $proc | Should -Not -BeNullOrEmpty -Because 'the returned id must be a live process'
        $proc.Name | Should -BeIn @('WindowsTerminal', 'WindowsTerminalPreview', 'WindowsTerminalCanary')
    }

    It 'does not decide anything from wt.exe exit codes' {
        # wt hands the tab off to Terminal and returns 0 immediately; it cannot
        # know whether `zellij attach --create` ever ran inside it. The marker
        # used to be written on that exit code.
        $script:Control | Should -Not -Match '\$LASTEXITCODE\s+-eq\s+0'
    }

    It 'records its window only once a client has actually arrived' {
        # The one observable in this whole path that zellij can answer.
        $script:Control | Should -Match 'Get-ZtClientCount'
        $script:Control | Should -Match '\$now -gt 0 -and \$now -gt \$clientsBefore'
    }

    It 'does not claim to have verified a Terminal focus' {
        # There is no observable for "did that window come forward": focus-tab
        # exits 0 either way, it does not conjure a window that could be
        # counted, and Terminal hosts every window in one process so a process
        # count cannot move. Saying "brought it forward" was an assertion the
        # code had no way to make.
        $script:Control | Should -Not -Match 'brought window'
        $script:Control | Should -Match 'asked Terminal to raise window'
    }

    It 'still scrubs the Claude Code environment before attach --create' {
        # This process starts the zellij SERVER when the session does not exist
        # yet, and every pane inherits that server's environment for as long as
        # it lives. NO_COLOR is the one that hurts: it is honoured before TERM
        # and COLORTERM are consulted, so every pane renders black and white and
        # the two assignments in the layout are silently pointless.
        $script:Control | Should -Match 'NO_COLOR'
        $script:Control | Should -Match 'CLAUDE_CODE_CHILD_SESSION'
    }

    It 'is reachable as zt attach' {
        $script:Dispatch | Should -Match "Connect-ZellijTerminal"
    }

    It 'defaults its window name to the session rather than a literal' {
        # The Command Palette attaches every session with -Session only, so a
        # fixed 'claude' default made a second session's attach raise the claude
        # window instead of its own.
        $script:Control | Should -Match '\$Window = \$Session'
    }
}
