<#
    The layout template's load-bearing lines, and the runtime prelude that has
    to match them.

    Every failure guarded here is silent. A pane that inherits NO_COLOR renders
    the whole session black and white while a bare terminal looks fine; a pane
    that inherits CLAUDE_CODE_CHILD_SESSION gets "Transcript saving is off"
    buried in Claude's startup; an unbalanced brace is a KDL parse error that
    Zellij reports as "Session not found", which sends you hunting for a
    session name that was never the problem. None of them produce an error at
    the point they are caused.

    The layout builds the startup tab and scripts\zj-claude-project.ps1 builds
    every tab after it. Nothing keeps the two preludes in step, so a tab you
    opened at runtime can behave differently from the one you started with -
    for no visible reason. Hence the cross-check at the end.

    Pester 5/6. Everything here reads files out of the repo: no Zellij, no
    session, no installed config. Green on a machine with none of the rig set up.
#>

BeforeAll {
    $script:TemplatePath = Join-Path $PSScriptRoot '..\zellij\layouts\claude.kdl.template'
    $script:ScriptPath   = Join-Path $PSScriptRoot '..\scripts\zj-claude-project.ps1'
    $script:ConfigPath   = Join-Path $PSScriptRoot '..\zellij\config.kdl'

    $script:TemplateText  = Get-Content -LiteralPath $script:TemplatePath -Raw
    $script:TemplateLines = Get-Content -LiteralPath $script:TemplatePath

    # The file is mostly commentary, and the commentary quotes KDL - including
    # a whole worked example under VARIATIONS. Counting anything without
    # dropping comment lines first counts the documentation too.
    $script:CodeLines = $script:TemplateLines | Where-Object { $_.TrimStart() -notmatch '^//' }

    # @() around each: a single match comes back as a bare string, and indexing
    # a string gives you a character rather than the line.
    $script:TabLines = @($script:CodeLines | Where-Object { $_ -match '^\s*tab\s+name=' })

    # A `pane command=` node carries its prelude on the `args` node beneath it.
    $script:PaneCommandLines = @($script:CodeLines | Where-Object { $_ -match '^\s*pane\s+command=' })
    $script:ArgsLines        = @($script:CodeLines | Where-Object { $_ -match '^\s*args\s' })

    # ---- the runtime prelude ----------------------------------------------
    # Read as text rather than dot-sourced: the script takes parameters and
    # does real work at load, so running it here would talk to Zellij.
    $projLines = Get-Content -LiteralPath $script:ScriptPath
    $i = 0
    while ($i -lt $projLines.Count -and $projLines[$i] -notmatch '^\s*\$PanePrelude\s*=') { $i++ }
    $block = @()
    if ($i -lt $projLines.Count) {
        $block += $projLines[$i]
        $j = $i + 1
        # The assignment is a run of concatenated string literals, one per line.
        while ($j -lt $projLines.Count -and $projLines[$j].TrimStart().StartsWith('"')) {
            $block += $projLines[$j]
            $j++
        }
    }
    $script:PreludeText = $block -join ' '

    $script:ConfigLines = (Get-Content -LiteralPath $script:ConfigPath) |
        Where-Object { $_.TrimStart() -notmatch '^//' }
}

Describe 'claude.kdl.template' {

    It 'is where install.ps1 expects to find it' {
        Test-Path -LiteralPath $script:TemplatePath | Should -BeTrue
    }

    It 'still carries the {{PLUGINS}} placeholder' {
        # install.ps1 substitutes this; a template that has lost it installs
        # cleanly and then fails to load zjstatus.wasm from a literal path.
        $script:TemplateText | Should -BeLike '*{{PLUGINS}}*'
    }

    It 'still carries the {{REPO}} placeholder' {
        # install.ps1 also substitutes {{HOME}}, but nothing in the template
        # uses it any more, so it is deliberately not asserted here.
        $script:TemplateText | Should -BeLike '*{{REPO}}*'
    }

    It 'declares exactly one startup tab' {
        # A session must have at least one tab, and any more than one duplicates
        # what the workspace registry already opens at runtime. That is the bug
        # this file was cut down to fix: the layout opened a tab on the repo,
        # `zt add .` registered the same folder, and you got two.
        $script:TabLines.Count | Should -Be 1
    }

    It 'names that tab home' {
        # Not claude-*, so the pad's next/prev keys walk past it.
        $name = [regex]::Match($script:TabLines[0], 'name="([^"]+)"').Groups[1].Value
        $name | Should -Be 'home'
    }

    It 'points that tab at the repo' {
        $script:TabLines[0] | Should -BeLike '*cwd="{{REPO}}"*'
    }

    It 'gives every pane command an args node to hold the prelude' {
        # The four checks below iterate the args lines. Without this, a pane
        # added with no args at all would let them pass by having nothing to
        # look at.
        $script:PaneCommandLines.Count | Should -BeGreaterThan 0
        $script:ArgsLines.Count        | Should -Be $script:PaneCommandLines.Count
    }

    It 'has every pane command <Why>' -ForEach @(
        @{ Why = 'clear NO_COLOR, or the session is black and white'
           Pattern = 'Remove-Item\s+(-Path\s+)?Env:NO_COLOR' }
        @{ Why = 'clear CLAUDE_CODE_CHILD_SESSION, or Claude stops saving transcripts'
           Pattern = 'Remove-Item\s+(-Path\s+)?Env:CLAUDE_CODE_CHILD_SESSION' }
        @{ Why = 'set TERM, which Zellij leaves empty on Windows'
           Pattern = '\$env:TERM\s*=\s*.xterm-256color' }
        @{ Why = 'set COLORTERM, which Zellij also leaves empty on Windows'
           Pattern = '\$env:COLORTERM\s*=\s*.truecolor' }
    ) {
        foreach ($line in $script:ArgsLines) {
            $line | Should -Match $Pattern
        }
    }

    It 'bounds the tab list, so it can never be dropped for being too wide' {
        # The failure this prevents is not cosmetic and not gradual. A bar over
        # budget is not wrapped and not truncated - the chunk that does not fit
        # is dropped WHOLE, so you lose every tab name at once while the mode
        # indicator and the activity codes carry on painting. Measured on a
        # 280-column probe: 12 tabs painted every name, 14 painted none.
        #
        # A window bounds what {tabs} asks for, so the list cannot grow big
        # enough to be dropped, and zjstatus always keeps the ACTIVE tab in it.
        ($script:CodeLines | Where-Object {
            $_ -match '^\s*tab_display_count\s+"\d+"' }).Count |
            Should -Be 1
    }

    It 'says how many tabs it is not showing, at both ends' {
        # Without these, truncation is silent: the window just renders fewer
        # tabs and nothing says the others exist. `{count}` is the only reason
        # a hidden tab is discoverable rather than apparently gone.
        foreach ($key in 'tab_truncate_start_format', 'tab_truncate_end_format') {
            $line = @($script:CodeLines | Where-Object { $_ -match "^\s*$key\s" })
            $line.Count | Should -Be 1 -Because "$key must be set"
            $line[0]    | Should -BeLike '*{count}*'
        }
    }

    It 'does not set format_hide_on_overlength, which measured as a no-op' {
        # 0.7.17 shipped this believing it kept the tab names. It does not.
        # Rendered with and without it on the tabs-too-wide case the painted
        # output was IDENTICAL, because Zellij drops the over-wide chunk on its
        # own; and on 14 tabs it was actively worse, taking the activity codes
        # away as well and still giving back no tab names. Pinned so it is not
        # reintroduced by someone reading the zjstatus docs and reasoning from
        # the name, which is exactly how it got in.
        ($script:CodeLines | Where-Object { $_ -match '^\s*format_hide_on_overlength\s' }).Count |
            Should -Be 0
    }

    It 'balances its braces' {
        # Placeholders are braces too and are gone by the time Zellij reads the
        # file, so they come out before counting.
        $code = ($script:CodeLines -join "`n") -replace '\{\{[A-Z]+\}\}', ''
        ([regex]::Matches($code, '\{')).Count |
            Should -Be ([regex]::Matches($code, '\}')).Count
    }

    It 'never closes a brace it did not open' {
        # Equal totals are not enough: `} {` also balances and is still a parse
        # error, reported as "Session not found".
        $code  = ($script:CodeLines -join "`n") -replace '\{\{[A-Z]+\}\}', ''
        $depth = 0
        foreach ($c in $code.ToCharArray()) {
            if ($c -eq '{') { $depth++ }
            if ($c -eq '}') { $depth-- }
            if ($depth -lt 0) { break }
        }
        $depth | Should -BeGreaterOrEqual 0
    }
}

Describe 'Runtime pane prelude in zj-claude-project.ps1' {

    It 'is where the layout test expects to find it' {
        Test-Path -LiteralPath $script:ScriptPath | Should -BeTrue
    }

    It 'still assigns $PanePrelude as a run of string literals' {
        # If the assignment is reshaped, the extraction above quietly returns
        # nothing and every check below passes on an empty string.
        $script:PreludeText | Should -Not -BeNullOrEmpty
    }

    It 'makes the prelude <Why>' -ForEach @(
        @{ Why = 'clear NO_COLOR, matching the layout'
           Pattern = 'Remove-Item\s+(-Path\s+)?Env:NO_COLOR' }
        @{ Why = 'clear CLAUDE_CODE_CHILD_SESSION, matching the layout'
           Pattern = 'Remove-Item\s+(-Path\s+)?Env:CLAUDE_CODE_CHILD_SESSION' }
        @{ Why = 'set TERM, matching the layout'
           Pattern = '\$env:TERM\s*=\s*.xterm-256color' }
        @{ Why = 'set COLORTERM, matching the layout'
           Pattern = '\$env:COLORTERM\s*=\s*.truecolor' }
    ) {
        $script:PreludeText | Should -Match $Pattern
    }

    It 'clears the same variables as the layout, no more and no fewer' {
        # Catches the case the four checks above cannot: a third variable added
        # to one prelude and forgotten in the other, so the tab you started with
        # behaves differently from the tabs you open later.
        $pattern = 'Remove-Item\s+(?:-Path\s+)?Env:(\w+)'
        $inLayout  = [regex]::Matches(($script:ArgsLines -join "`n"), $pattern) |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $inScript = [regex]::Matches($script:PreludeText, $pattern) |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

        ($inScript -join ',') | Should -Be ($inLayout -join ',')
    }
}

Describe 'zellij config.kdl' {

    It 'is where install.ps1 expects to find it' {
        Test-Path -LiteralPath $script:ConfigPath | Should -BeTrue
    }

    It 'sets default_layout to claude' {
        # The only form that gives a named session AND the layout is
        # default_layout plus `attach --create`. Lose this line and the Windows
        # Terminal profile opens a bare session with no status bar and no home
        # tab, which looks like the layout file is broken.
        ($script:ConfigLines | Where-Object { $_ -match '^\s*default_layout\s+"claude"' }).Count |
            Should -Be 1
    }

    It 'sets default_shell' {
        # With nothing set you get cmd.exe, not PowerShell: there is no $SHELL
        # on Windows.
        ($script:ConfigLines | Where-Object { $_ -match '^\s*default_shell\s+"[^"]+"' }).Count |
            Should -Be 1
    }
}
