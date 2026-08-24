<#
    Naming - the two pure derivations that three components have to agree on.

    The hook derives a tab name from the cwd Claude Code hands it, the tab
    cycler walks tabs whose names start with the prefix, and the registry
    derives the same name again when it decides whether a workspace is
    running. Nothing coordinates them: they agree only because they all
    compute the name the same way. When they stop agreeing the failure is
    quiet and infuriating - the pad jumps to a tab that does not exist, or
    reports a workspace stopped while it is plainly running in front of you.

    So these are worth pinning even though they look trivial. Both functions
    are pure, which is the point: no Zellij, no session, no config on disk.
    The suite is green on a machine with none of the rig installed.

    Pester 5/6. Private functions are reached through the module's own scope:
        $m = Get-Module ZellijTerminal; & $m { Get-ZtSessionName -Tab 'x' }
#>

BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..\module\ZellijTerminal\ZellijTerminal.psd1'
    Import-Module $manifest -Force -ErrorAction Stop
    $script:M = Get-Module ZellijTerminal
}

AfterAll {
    Remove-Module ZellijTerminal -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ZtSessionName' {

    It 'strips the bookkeeping prefix, which is what makes the mobile picker readable' {
        (& $script:M { Get-ZtSessionName -Tab 'claude-web-api' }) |
            Should -Be 'web-api'
    }

    It 'keeps a collision suffix, because that is the half that identifies the workspace' {
        # Two folders both called api get -3f2a and -9b11; dropping the suffix
        # would leave two sessions displaying the same name.
        (& $script:M { Get-ZtSessionName -Tab 'claude-api-3f2a' }) |
            Should -Be 'api-3f2a'
    }

    It 'passes a name that does not use the prefix straight through' {
        (& $script:M { Get-ZtSessionName -Tab 'mytab' }) |
            Should -Be 'mytab'
    }

    It 'matches the prefix case-insensitively' {
        # Tab names arrive from `zellij query-tab-names` and from user config,
        # neither of which guarantees the case the prefix was written in.
        (& $script:M { Get-ZtSessionName -Tab 'CLAUDE-Upper' }) |
            Should -Be 'Upper'
    }

    It 'refuses to reduce the degenerate "claude-" to an empty name' {
        # An empty --name is worse than an ugly one: it produces a session with
        # no label at all in /resume.
        (& $script:M { Get-ZtSessionName -Tab 'claude-' }) |
            Should -Be 'claude-'
    }

    It 'returns empty for empty input rather than inventing a name' {
        (& $script:M { Get-ZtSessionName -Tab '' }) |
            Should -Be ''
    }

    It 'returns empty for $null input, since the parameter is typed [string]' {
        # Documented rather than desired: [string]$Tab coerces $null to '', so
        # callers get '' back, not $null. Anything checking for $null will not
        # see one.
        (& $script:M { Get-ZtSessionName -Tab $null }) |
            Should -Be ''
    }

    It 'strips nothing when the prefix is empty' {
        (& $script:M { Get-ZtSessionName -Tab 'claude-api' -Prefix '' }) |
            Should -Be 'claude-api'
    }

    It 'honours a non-default prefix' {
        (& $script:M { Get-ZtSessionName -Tab 'work-api' -Prefix 'work-' }) |
            Should -Be 'api'
    }
}

Describe 'Get-ZtTabName' {

    # NO PREFIX SINCE 0.7.20. A tab is named for its project. The prefix was
    # seven columns on every tab, spent to answer a question the registry can
    # answer - and on a bar where the chunk that does not fit is dropped WHOLE,
    # those columns are the difference between reading your tab names and losing
    # every one of them at once.
    #
    # Creation stopped using the prefix; RECOGNITION did not. That asymmetry is
    # the migration, and Get-ZtTabBase below is the half that kept it.
    It 'derives the bare leaf from the path' {
        (& $script:M { Get-ZtTabName -Workspace $null -Path 'C:\code\web-api' }) |
            Should -Be 'web-api'
    }

    It 'never prefixes, even when a caller passes one' {
        # Every caller still threads -Prefix through, because Get-ZtTabBase needs
        # it to recognise a legacy tab. It must not come back here as a prefix on
        # a NEW name, or half the rig would create `claude-web-api` again while
        # the other half looked for `web-api`.
        (& $script:M { Get-ZtTabName -Workspace $null -Path 'C:\code\web-api' -Prefix 'claude-' }) |
            Should -Be 'web-api'
    }

    It 'derives the same name from a path with a trailing separator' {
        # The hook passes cwd through unmodified and Claude Code is not
        # consistent about the trailing slash.
        (& $script:M { Get-ZtTabName -Workspace $null -Path 'C:\code\web-api' }) |
            Should -Be 'web-api'
    }

    It 'lets an explicit name on the workspace win over the derivation' {
        # This is how two folders both called api stop fighting over one tab, and
        # it is also how you give a long project a short tab.
        $ws = [pscustomobject]@{ name = 'mytab' }
        (& $script:M { param($w) Get-ZtTabName -Workspace $w -Path 'C:\code\api' } $ws) |
            Should -Be 'mytab'
    }

    It 'falls back to the derivation when the name property is present but empty' {
        # name is empty for most registry entries; it is an override, not a field
        # that always holds the answer.
        $ws = [pscustomobject]@{ name = '' }
        (& $script:M { param($w) Get-ZtTabName -Workspace $w -Path 'C:\code\api' } $ws) |
            Should -Be 'api'
    }

    It 'ignores a name on a hashtable, because the workspace is expected to be an object' {
        # Get-ZtProp looks at PSObject.Properties, which for a hashtable lists
        # Count and Keys rather than the entries. Registry objects come from
        # ConvertFrom-Json so they are always pscustomobject; a hashtable passed
        # by hand silently loses its override. Recorded so a future caller does
        # not lose an afternoon to it.
        $ws = @{ name = 'mytab' }
        (& $script:M { param($w) Get-ZtTabName -Workspace $w -Path 'C:\code\api' } $ws) |
            Should -Be 'api'
    }
}

Describe 'The 0.7.20 migration - old tabs must keep working' {

    # An existing session is sitting in a tab called `claude-web-api`. Nothing
    # renames it. It has to reduce to the same identity as a tab created today,
    # or it loses its glyph, its flag file and its place in the pad's cycle -
    # silently, and only on machines that were already in use.
    It 'reduces a legacy tab and a new tab to the same base' {
        $legacy = (& $script:M { Get-ZtSessionName -Tab 'claude-web-api' })
        $modern = (& $script:M { Get-ZtSessionName -Tab 'web-api' })
        $legacy | Should -Be 'web-api'
        $modern | Should -Be 'web-api'
        $legacy | Should -Be $modern
    }

    It 'agrees with what Get-ZtTabName now creates' {
        $created = (& $script:M { Get-ZtTabName -Workspace $null -Path 'C:\code\web-api' })
        (& $script:M { param($t) Get-ZtSessionName -Tab $t } $created) | Should -Be $created
    }

    It 'still strips a legacy prefix from a decorated tab' {
        # Live names carry the activity glyph. Both halves have to come off.
        (& $script:M { Get-ZtSessionName -Tab 'claude-web-api' }) | Should -Be 'web-api'
    }
}

Describe 'Tab name and session name round trip' {

    It 'gives back the leaf for a default workspace' {
        # Since 0.7.20 the tab IS the leaf, so the round trip is the identity.
        # Still worth pinning: Get-ZtSessionName strips a legacy prefix, and a
        # tab that no longer carries one must survive that untouched.
        $tab = & $script:M { Get-ZtTabName -Workspace $null -Path 'C:\code\web-api' }
        $session = & $script:M { param($t) Get-ZtSessionName -Tab $t } $tab

        $tab     | Should -Be 'web-api'
        $session | Should -Be 'web-api'
    }

    It 'records that a folder literally called claude-something is ambiguous' {
        # THE COST OF THE MIGRATION, written down rather than discovered later.
        #
        # Recognition still strips a leading `claude-`, so a tab made before
        # 0.7.20 reduces to the same base as one made after. A project whose
        # FOLDER is called `claude-tools` therefore derives the tab
        # `claude-tools`, which recognition reduces to `tools` - and the
        # registry, holding `claude-tools`, no longer agrees with it.
        #
        # Not hypothetical for a repo about Claude. The escape hatch is an
        # explicit name, which Get-ZtTabName returns verbatim.
        $tab = & $script:M { Get-ZtTabName -Workspace $null -Path 'C:\code\claude-tools' }
        $tab | Should -Be 'claude-tools'

        $base = & $script:M { param($t) Get-ZtSessionName -Tab $t } $tab
        $base | Should -Be 'tools' -Because (
            'recognition cannot tell a legacy prefix from a folder that ' +
            'genuinely starts with one')

        $ws = [pscustomobject]@{ name = 'claude-tools' }
        (& $script:M { param($w) Get-ZtTabName -Workspace $w -Path 'C:\code\claude-tools' } $ws) |
            Should -Be 'claude-tools'
    }


    It 'leaves an explicit name untouched end to end' {
        # An override is a name someone chose. It is not derived, so it is not
        # stripped, and what shows in /resume is exactly what they typed.
        $ws = [pscustomobject]@{ name = 'mytab' }
        $tab = & $script:M { param($w) Get-ZtTabName -Workspace $w -Path 'C:\code\api' } $ws
        $session = & $script:M { param($t) Get-ZtSessionName -Tab $t } $tab

        $tab     | Should -Be 'mytab'
        $session | Should -Be 'mytab'
    }
}

Describe 'Get-ZtTabBase - the activity glyph is decoration, not identity' {

    # The hook renames its own tab to `claude-web-api ~` so the tab bar says
    # what that session is doing. The glyph changes on every tool call, so
    # anything that IDENTIFIES a tab has to strip it first. Five components do
    # that - the hook, both scripts, the module and the palette - and nothing
    # coordinates them. Drift here is silent: go-to-tab-name matches nothing
    # and exits 0, which is indistinguishable from success.

    It 'strips a trailing glyph' {
        (& $script:M { Get-ZtTabBase -Name 'claude-web-api ~' }) | Should -Be 'claude-web-api'
    }

    It 'leaves an undecorated name alone' {
        (& $script:M { Get-ZtTabBase -Name 'claude-web-api' }) | Should -Be 'claude-web-api'
    }

    It 'strips only the glyph, so a collision suffix survives' {
        (& $script:M { Get-ZtTabBase -Name 'claude-api-3f2a v' }) | Should -Be 'claude-api-3f2a'
    }

    It 'needs the space: a name ending in a glyph character is not decorated' {
        # `claude-c++` is a plausible tab name. Stripping on the character alone
        # would quietly rename that workspace every time the hook fired.
        (& $script:M { Get-ZtTabBase -Name 'claude-c++' }) | Should -Be 'claude-c++'
    }

    It 'covers every symbol the hook can emit' {
        # The character class and the symbol table in Get-Activity are written
        # independently. Add a symbol to the hook without adding it there and
        # that one state leaves the tab permanently misnamed.
        $hook    = Join-Path $PSScriptRoot '..\hooks\claude-zj-hook.ps1'
        $text    = Get-Content -LiteralPath $hook -Raw
        # Anchored on the shape of the table itself - `@{ s = 'x'; c = '#...'`
        # - because a looser match also picks up every other assignment in the
        # file that happens to end in s.
        $symbols = @([regex]::Matches($text, "\{\s*s\s*=\s*'([^']+)'\s*;\s*c\s*=") |
                        ForEach-Object { $_.Groups[1].Value } |
                        Select-Object -Unique)

        $symbols.Count | Should -BeGreaterThan 5
        foreach ($s in $symbols) {
            (& $script:M { param($n) Get-ZtTabBase -Name $n } "claude-web-api $s") |
                Should -Be 'claude-web-api' -Because "the hook can emit '$s'"
        }
    }

    It 'is the same rule in all five implementations' {
        # Written out five times rather than shared: the hook runs under 5.1
        # and off the module path, the scripts must not pay for an import, and
        # the palette is C#. So pin the text instead of the mechanism.
        $root  = Join-Path $PSScriptRoot '..'
        $rule  = ' [v!?*>~#@&+.]$'
        $files = @(
            'hooks\claude-zj-hook.ps1'
            'scripts\zj-claude-tab.ps1'
            'scripts\zj-claude-project.ps1'
            'module\ZellijTerminal\Private\Core.ps1'
            'cmdpal\ZellijTerminal.Palette\ZellijCli.cs'
        )

        foreach ($f in $files) {
            $p = Join-Path $root $f
            if (-not (Test-Path -LiteralPath $p)) { continue }
            # .Contains, not -BeLike: the rule is mostly wildcard metacharacters
            # - [ ] ? * . - so -like reads it as a pattern and matches nothing.
            ((Get-Content -LiteralPath $p -Raw).Contains($rule)) |
                Should -BeTrue -Because "$f has to strip the glyph the same way"
        }
    }
}
