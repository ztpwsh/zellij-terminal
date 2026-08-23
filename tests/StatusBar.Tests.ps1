<#
    The right-hand activity strip, and the width it is allowed to cost.

    This widget shares one row with the tab names, and zjstatus does not
    arbitrate between them by shrinking: over budget it emits a line longer
    than the pane, the one-row pane wraps, and the front of the line - the mode
    indicator and every tab name - scrolls out of view. What is left on screen
    is this strip. So a change here that spends a few more columns per project
    does not look like a bug in this file; it looks like the tab bar breaking.

    Hence the assertions about SHAPE rather than about content: a working
    project must not print its name, and only a waiting one may. The layout
    carries the hard guard (`format_hide_on_overlength`, pinned in
    Layout.Tests.ps1); this keeps the strip inside its means so the guard
    rarely has to fire and take the whole strip away.

    Get-ZtStatusLine is lifted out of the hook by AST and called directly. The
    hook cannot be dot-sourced - it reads stdin and talks to Zellij at load -
    and it must not import the module, so this is the same trick
    Hooks.Tests.ps1 uses on Test-ZtOwnHookEntry.

    Pester 5/6. Reads one file out of the repo: no Zellij, no session, no
    installed config.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:HookPath = Join-Path $script:RepoRoot 'hooks/claude-zj-hook.ps1'

    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:HookPath, [ref]$null, [ref]$null)

    $fn = $ast.Find({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq 'Get-ZtStatusLine'
    }, $true)

    $script:FunctionText = if ($fn) { $fn.Extent.Text } else { $null }

    function Invoke-StatusLine {
        # Defined in a throwaway scope per call, so nothing leaks between tests.
        param($State)
        $sb = [scriptblock]::Create($script:FunctionText + "`nGet-ZtStatusLine -State `$args[0]")
        return [string](& $sb $State)
    }

    function Get-TestState {
        # A hashtable keyed by project, exactly as the hook holds it in memory
        # after reading the state file.
        param([hashtable]$Entries)
        $h = @{}
        foreach ($k in $Entries.Keys) {
            $v = $Entries[$k]
            $h[$k] = [pscustomobject]@{
                symbol = $v.symbol
                color  = $v.color
                wait   = $v.wait
                ts     = '2026-08-23T00:00:00.0000000+01:00'
            }
        }
        return $h
    }
}

Describe 'Get-ZtStatusLine' {

    It 'is still a function in the hook' {
        # If it is inlined again the extraction returns nothing and every check
        # below passes against an empty string.
        $script:FunctionText | Should -Not -BeNullOrEmpty
    }

    It 'names a project that is waiting for you' {
        # The whole point of the strip: the tab that wants you may be one you
        # cannot see, so it has to say which one.
        $line = Invoke-StatusLine (Get-TestState @{
            'web-api' = @{ symbol = 'v'; color = '#A6E3A1'; wait = $true }
        })
        $line | Should -BeLike '*v web-api*'
    }

    It 'does not name a project that is merely working' {
        # The name is already on screen, on that project's own tab, a few
        # columns to the left. Printing it twice is what pushed it off.
        $line = Invoke-StatusLine (Get-TestState @{
            'web-api' = @{ symbol = '~'; color = '#89B4FA'; wait = $false }
        })
        $line | Should -Not -BeLike '*web-api*'
        $line | Should -BeLike '*~*'
    }

    It 'costs one column per working project, plus its separator' {
        # The regression this file exists to catch. Measured on the visible
        # text, with the colour markup removed - that is what occupies the row.
        $line = Invoke-StatusLine (Get-TestState @{
            'web-api'      = @{ symbol = '~'; color = '#89B4FA'; wait = $false }
            'web-frontend' = @{ symbol = '*'; color = '#F9E2AF'; wait = $false }
            'web-worker'   = @{ symbol = '>'; color = '#FAB387'; wait = $false }
        })
        $visible = $line -replace '#\[[^\]]*\]', ''
        $visible.Length | Should -BeLessOrEqual 6 -Because (
            'three busy projects used to cost 43 columns and now cost 5')
    }

    It 'treats a record written before the wait field as working' {
        # Old state files are on disk on every machine that has ever run this,
        # and they have no `wait`. Reading one must not promote it to the named
        # form - $null -eq $true is false, and that is load-bearing.
        $h = @{ 'web-api' = [pscustomobject]@{ symbol = '*'; color = '#F9E2AF' } }
        $line = Invoke-StatusLine $h
        $line | Should -Not -BeLike '*web-api*'
    }

    It 'puts the projects that want you before the ones that do not' {
        $line = Invoke-StatusLine (Get-TestState @{
            'web-api'      = @{ symbol = '~'; color = '#89B4FA'; wait = $false }
            'web-frontend' = @{ symbol = 'v'; color = '#A6E3A1'; wait = $true  }
        })
        $visible = $line -replace '#\[[^\]]*\]', ''
        $visible | Should -Match '^v web-frontend'
    }

    It 'emits nothing at all when no project has any state' {
        # The caller guards on a non-empty line before starting a process, so
        # an empty state must produce an empty string rather than a stray
        # separator - `zellij pipe` with an empty payload is a process start
        # on the latency path of every tool call, for nothing.
        Invoke-StatusLine @{} | Should -BeNullOrEmpty
    }

    It 'never emits a newline' {
        # The payload is passed as one CLI argument to `zellij pipe`. A newline
        # in it truncates the strip silently at the break.
        $line = Invoke-StatusLine (Get-TestState @{
            'web-api'      = @{ symbol = 'v'; color = '#A6E3A1'; wait = $true  }
            'web-frontend' = @{ symbol = '~'; color = '#89B4FA'; wait = $false }
        })
        $line | Should -Not -Match "`n"
        $line | Should -Not -Match "`r"
    }

    It 'never emits a double quote' {
        # The hook wraps this in double quotes to build a single
        # ProcessStartInfo.Arguments string, because .ArgumentList is .NET Core
        # only and the hook must run under Windows PowerShell 5.1.
        $line = Invoke-StatusLine (Get-TestState @{
            'web-api' = @{ symbol = 'v'; color = '#A6E3A1'; wait = $true }
        })
        $line | Should -Not -Match '"'
    }
}

Describe 'The hook records what the strip needs' {

    It 'writes the wait flag into the state file' {
        # The strip reads `wait` back out of the state file on the next event,
        # so the write and the read have to agree. Without this the strip
        # silently degrades to showing every project as working.
        $text = Get-Content -LiteralPath $script:HookPath -Raw
        $text | Should -Match 'wait\s*=\s*\$act\.wait'
    }

    It 'takes wait from the same table as the symbol and the colour' {
        # One table, so the glyph on the tab and the promotion on the bar can
        # never disagree about whether a project wants you.
        $text = Get-Content -LiteralPath $script:HookPath -Raw
        $entries = [regex]::Matches($text, "\{\s*s\s*=\s*'[^']+'\s*;\s*c\s*=\s*'[^']+'\s*;\s*wait\s*=\s*\`$(true|false)\s*\}")
        $entries.Count | Should -BeGreaterThan 5
    }

    It 'still calls the builder rather than rebuilding the line inline' {
        $text = Get-Content -LiteralPath $script:HookPath -Raw
        $text | Should -Match 'Get-ZtStatusLine\s+-State\s+\$state'
    }
}
