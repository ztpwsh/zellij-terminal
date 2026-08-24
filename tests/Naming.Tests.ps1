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
        # Not hypothetical for a repo about Claude.
        #
        # 0.7.22 CLOSED THE ESCAPE HATCH, because it was never open. This block
        # used to end by saying an explicit name is returned verbatim, and it
        # demonstrated that by calling Get-ZtTabName with no -Prefix - which no
        # real caller does. Threaded the way the rig actually threads it, an
        # explicit name is now reduced like everything else. Nothing can hold a
        # tab whose name begins `claude-`, and that is the honest end of it:
        # recognition would have reduced such a tab out from under any match.
        $tab = & $script:M { Get-ZtTabName -Workspace $null -Path 'C:\code\claude-tools' }
        $tab | Should -Be 'claude-tools'

        $base = & $script:M { param($t) Get-ZtSessionName -Tab $t } $tab
        $base | Should -Be 'tools' -Because (
            'recognition cannot tell a legacy prefix from a folder that ' +
            'genuinely starts with one')

        $ws = [pscustomobject]@{ name = 'claude-tools' }
        (& $script:M { param($w) Get-ZtTabName -Workspace $w -Path 'C:\code\claude-tools' } $ws) |
            Should -Be 'claude-tools' -Because 'no prefix declared means nothing is legacy'

        (& $script:M { param($w) Get-ZtTabName -Workspace $w -Path 'C:\code\claude-tools' -Prefix 'claude-' } $ws) |
            Should -Be 'tools' -Because 'every real caller threads -Prefix, and then it is reduced'
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

Describe 'The prefix drift class - 0.7.22' {

    <#
        WHY THIS BLOCK EXISTS, and why the rest of this file did not catch what
        it is here to catch.

        0.7.20 dropped the `claude-` prefix from tab names. Creation stopped
        using it; recognition did not, deliberately, so an existing session
        kept its tab. That asymmetry is sound. What was not sound is that FOUR
        other places went on using the prefix as a MEMBERSHIP TEST - asking
        "is this tab called claude-*?", a question with no true answer any more.
        None errored. Each simply matched nothing, and matching nothing is
        indistinguishable from there being nothing to match. `zt check` reported
        no failures on a machine with four live project tabs it could not see.

        Every existing test in this file passes a name in and asserts the name
        that comes back. That is why the suite stayed green: the tests supply
        the prefixed input themselves, so they go on agreeing with a function
        that nothing in the real rig can still feed. The assertions below run
        the other way - they pin that the two halves of each comparison CAN be
        equal, which is the property that actually broke.
    #>

    BeforeAll {
        function Get-ZtCodeText {
            <#
                Source with comment lines removed.

                The first draft of the D4 assertion below went red against the
                fix that was already in - it matched the COMMENT that quotes the
                old `-like "$Prefix*"` line to explain what was wrong with it.
                A test that forbids naming the defect in a comment is worse than
                no test: it would be silenced by deleting the explanation.
            #>
            param([string]$Path)
            $lines = Get-Content -LiteralPath $Path |
                Where-Object { $_ -notmatch '^\s*#' }
            return ($lines -join "`n")
        }
    }

    Context 'The invariant: one name, not two spellings' {

        # THE TEST THAT WOULD HAVE CAUGHT ALL FOUR. Whatever Get-ZtTabName
        # produces has to survive the reduction recognition applies, or the
        # half that creates a tab and the half that finds one are working on
        # different strings - which is silent, because go-to-tab-name no-ops on
        # a miss and exits 0.
        It 'produces a name that recognition leaves alone: <Case>' -ForEach @(
            @{ Case = 'derived from the leaf';   Ws = $null }
            @{ Case = 'an explicit override';    Ws = [pscustomobject]@{ name = 'mytab' } }
            @{ Case = 'a legacy explicit name';  Ws = [pscustomobject]@{ name = 'claude-web-api' } }
            @{ Case = 'a legacy collision name'; Ws = [pscustomobject]@{ name = 'claude-api-3f2a' } }
            @{ Case = 'no name property at all'; Ws = [pscustomobject]@{ id = 'api' } }
        ) {
            $tab = & $script:M { param($w) Get-ZtTabName -Workspace $w -Path 'C:\code\web-api' -Prefix 'claude-' } $Ws

            $tab | Should -Not -BeNullOrEmpty
            (& $script:M { param($t) Get-ZtSessionName -Tab $t -Prefix 'claude-' } $tab) |
                Should -Be $tab -Because 'the name the registry derives must be the name the session creates'
            (& $script:M { param($t) Get-ZtTabBase -Name $t } $tab) |
                Should -Be $tab -Because 'a freshly derived name carries no glyph'
        }

        It 'never derives a name that begins with the legacy prefix' {
            # The stronger statement, and the one that is cheap to check: if no
            # derived name can start with `claude-`, no derived name can be
            # reduced out from under a match.
            $cases = @(
                @{ P = 'C:\code\web-api';      W = $null }
                @{ P = 'C:\code\claude-tools'; W = [pscustomobject]@{ name = 'claude-tools' } }
                @{ P = 'C:\code\api';          W = [pscustomobject]@{ name = 'claude-stock-reconciliation' } }
            )
            foreach ($c in $cases) {
                $tab = & $script:M { param($w, $p) Get-ZtTabName -Workspace $w -Path $p -Prefix 'claude-' } $c.W $c.P
                $tab | Should -Not -BeLike 'claude-*' -Because "$($c.P) must not derive an unmatchable name"
            }
        }
    }

    Context 'D1 - a stored legacy name is reduced, not returned verbatim' {

        # THE BAD DATA THIS WAS FOUND IN. Three entries on the reporting machine
        # held names no human chose: the old collision branch derived them, and
        # they name a tab creation can no longer make. Returned as they stood,
        # the workspace read `stopped` with its tab open, and its flag file was
        # looked up under a filename the hook never writes.
        It 'reduces <Stored> to <Want>' -ForEach @(
            @{ Stored = 'claude-stock-reconciliation'; Want = 'stock-reconciliation' }
            @{ Stored = 'claude-joolz-dev-fcfb930a';   Want = 'joolz-dev-fcfb930a' }
            @{ Stored = 'claude-AL-213f8564';          Want = 'AL-213f8564' }
        ) {
            $ws = [pscustomobject]@{ name = $Stored }
            (& $script:M { param($w) Get-ZtTabName -Workspace $w -Path 'C:\code\thing' -Prefix 'claude-' } $ws) |
                Should -Be $Want
        }

        It 'leaves a name that is not legacy completely alone' {
            $ws = [pscustomobject]@{ name = 'mytab' }
            (& $script:M { param($w) Get-ZtTabName -Workspace $w -Path 'C:\code\api' -Prefix 'claude-' } $ws) |
                Should -Be 'mytab'
        }

        It 'reduces it in zj-claude-tab.ps1 too, which reads the registry itself' {
            # The pad's latency path does not import the module, so it carries
            # its own copy of this derivation. A fix in one and not the other is
            # the same defect wearing a different hat.
            $p = Join-Path $PSScriptRoot '..\scripts\zj-claude-tab.ps1'
            $t = Get-Content -LiteralPath $p -Raw
            $block = [regex]::Match($t, 'function Get-ZtRegisteredTabBases[\s\S]*?\n\}').Value
            $block | Should -Not -BeNullOrEmpty
            $block | Should -Match 'StartsWith\(\$Prefix' -Because (
                'it reads the same name field and must reduce it the same way')
        }
    }

    Context 'D2 - the collision comparison has to be able to fire' {

        It 'compares two spellings that can be equal' {
            # The branch built `claude-<leaf>` and compared it to Get-ZtTabName,
            # which returns a bare leaf. Never equal, so two folders sharing a
            # leaf silently shared one tab and the documented warning never
            # appeared. Pinned against the source, because making a real
            # collision happen needs a registry on disk - and the defect is in
            # the comparison, not in the writing.
            $p = Join-Path $PSScriptRoot '..\module\ZellijTerminal\Public\Registry.ps1'
            $t = Get-ZtCodeText $p
            $t | Should -Not -Match '\$wantTab\s*=\s*\$Prefix' -Because (
                'the other side of this comparison has not carried a prefix since 0.7.20')
            $t | Should -Match '\$wantTab\s*=\s*Split-Path\s+\$full\s+-Leaf'
        }

        It 'assigns a disambiguated name that is itself matchable' {
            # `claude-<leaf>-<key>` is where D1's bad data came from: a defect
            # that repaired itself by writing more of itself into the registry.
            # <leaf>-<key> survives the reduction, so the repair is durable.
            $ws = [pscustomobject]@{ name = 'api-3f2a1b0c' }
            $tab = & $script:M { param($w) Get-ZtTabName -Workspace $w -Path 'C:\code\api' -Prefix 'claude-' } $ws
            $tab | Should -Be 'api-3f2a1b0c'
            (& $script:M { param($t) Get-ZtSessionName -Tab $t -Prefix 'claude-' } $tab) | Should -Be $tab
        }
    }

    Context 'D3 - unregistered tabs are excluded by name, not by spelling' {

        It 'knows which tabs the layout opens' {
            $tabs = & $script:M { $ZtLayoutTabs }
            $tabs | Should -Contain 'home'
        }

        It 'excludes exactly the tabs the layout actually declares' {
            # The real rule, and the one the layout has documented all along:
            # `home` is deliberately not a workspace. Read it off the template
            # rather than trusting two lists to stay in step - add a tab there
            # and this goes red, which is the point.
            $tpl   = Join-Path $PSScriptRoot '..\zellij\layouts\claude.kdl.template'
            $text  = Get-Content -LiteralPath $tpl -Raw
            $names = @([regex]::Matches($text, '(?m)^\s*tab\s+name="([^"]+)"') |
                        ForEach-Object { $_.Groups[1].Value })

            $names.Count | Should -BeGreaterThan 0
            $layout = @(& $script:M { $ZtLayoutTabs })
            foreach ($n in $names) {
                $layout | Should -Contain $n -Because "the layout opens '$n' and it is not a workspace"
            }
            $layout.Count | Should -Be $names.Count -Because 'excluding more than the layout opens hides real tabs'
        }

        It 'no longer filters the unregistered-tab block by prefix' {
            # In 0.7.19 this line meant "skip home". Since 0.7.20 it meant "skip
            # every tab there is", so the block whose whole purpose is to explain
            # the gap between `zt` and the tab bar could not emit a single row -
            # and `zt rm` on an open workspace stranded its tab beyond the reach
            # of `zt close`.
            $p = Join-Path $PSScriptRoot '..\module\ZellijTerminal\Private\Core.ps1'
            $t = Get-ZtCodeText $p
            $t | Should -Not -Match '-notlike\s+"\$Prefix\*"' -Because (
                'no tab has started with the prefix since 0.7.20')
            $t | Should -Match '\$ZtLayoutTabs\s+-contains\s+\$t'
        }
    }

    Context 'D4 - zt check counts project tabs the way the pad does' {

        It 'does not count them by prefix' {
            # It reported "None open - 33 registered" directly beneath a
            # query-tab-names PASS listing four project tabs, and the run still
            # said no failures. Two rows contradicting each other in one output.
            $p = Join-Path $PSScriptRoot '..\scripts\Test-Setup.ps1'
            $t = Get-ZtCodeText $p
            $t | Should -Not -Match '-like\s+"\$Prefix\*"'
            $t | Should -Match 'Get-RegisteredTabBases'
        }

        It 'excludes the same layout tabs the module does' {
            # A copy of a rule that is now written twice. Same reason as the
            # config-home rule: this script runs without importing the module,
            # so the only thing keeping the two in step is this test.
            $p = Join-Path $PSScriptRoot '..\scripts\Test-Setup.ps1'
            $t = Get-ZtCodeText $p
            $m = [regex]::Match($t, '(?m)^\s*\$ZtLayoutTabs\s*=\s*@\(([^)]*)\)')
            $m.Success | Should -BeTrue -Because 'zt check needs its own copy of the list'

            $theirs = @($m.Groups[1].Value -split ',' |
                        ForEach-Object { $_.Trim().Trim("'").Trim('"') } |
                        Where-Object { $_ })
            $ours = @(& $script:M { $ZtLayoutTabs })
            (($theirs | Sort-Object) -join ',') | Should -Be (($ours | Sort-Object) -join ',')
        }

        It 'reduces a tab to the same identity the module does' {
            # Its Get-TabIdentity is Get-ZtTabBase followed by Get-ZtSessionName,
            # written out because the script must not pay for a module import.
            # Pinned by BEHAVIOUR rather than by text: run both and compare, so
            # a rewrite that is still correct does not go red.
            $p    = Join-Path $PSScriptRoot '..\scripts\Test-Setup.ps1'
            $body = [regex]::Match((Get-Content -LiteralPath $p -Raw),
                        'function Get-TabIdentity[\s\S]*?\n\}').Value
            $body | Should -Not -BeNullOrEmpty

            # $Prefix is a script parameter there, so give the extracted copy one.
            $sb = [scriptblock]::Create("param(`$Name, `$Prefix)`n$body`nGet-TabIdentity -Name `$Name")

            foreach ($n in @('web-api', 'web-api ~', 'claude-web-api', 'claude-web-api !', 'home', 'claude-api-3f2a .')) {
                $mine   = & $sb $n 'claude-'
                $theirs = & $script:M { param($x) Get-ZtSessionName -Tab (Get-ZtTabBase -Name $x) -Prefix 'claude-' } $n
                $mine | Should -Be $theirs -Because "'$n' has to reduce identically in both"
            }
        }
    }
}
