<#
    Analyzer - PSScriptAnalyzer as a build gate, calibrated so it can stay on.

    WHY THIS IS NOT "ZERO FINDINGS"
      A clean run of PSScriptAnalyzer over this repo returns 467 records: 381
      Warning, 86 Information, no Error. 330 of the warnings are
      PSAvoidUsingWriteHost. A gate at zero would be red on the day it was
      written, and a gate that is red on day one is a gate everyone learns to
      ignore - which is worse than no gate, because it also hides the findings
      that do matter when they finally appear.

      So this fails on the things that are defects here and reports the rest.
      Fatal: anything of Severity Error, anything that will not parse, and four
      named Warning rules. Non-fatal: everything else, printed with a count so
      the number stays visible instead of quietly growing.

    THE FOUR FATAL WARNING RULES
      PSAvoidAssignmentToAutomaticVariable - assigning $args, $input, $matches
        and friends. This code is full of small helpers that take a couple of
        parameters and shell out; clobbering $matches next to a -match is the
        kind of bug that only shows up on the second call.
      PSShouldProcess - a function that declares SupportsShouldProcess and then
        never calls $PSCmdlet.ShouldProcess. That is the exact shape of a -WhatIf
        that silently does the thing anyway, on cmdlets that kill sessions and
        delete registry entries.
      PSUseOutputTypeCorrectly - an OutputType attribute that lies. The pad and
        the Command Palette both read what these commands emit.
      PSAvoidUsingCmdletAliases - scripts\ and hooks\ run under whatever
        powershell.exe hands them; an alias resolves differently, or not at all,
        depending on profile and module state.

      All four are at zero today. That is the point of naming them now: the gate
      costs nothing while it is green and catches the first regression.

    THE TWO EXCLUSIONS
      Both are argued in comments at the point of exclusion below, because an
      exclusion without a reason is how a gate rots into a formality.

    Measured against PSScriptAnalyzer 1.25.0 on PowerShell 7.6 with Pester 6.1.
    The counts quoted above are from that run; they are not asserted, so they
    can drift without turning anything red.

    Pester 5/6. Green on a machine with no Zellij, no session, no PowerToys and
    no .NET SDK: nothing here runs anything, it only reads source. The whole
    analyzer half skips if PSScriptAnalyzer is not installed.
#>

# Discovery scope on purpose. Pester 5/6 evaluates -Skip and expands -ForEach
# while discovering, before any BeforeAll has run, so both have to be settled
# out here.
$RepoRoot = Split-Path -Parent $PSScriptRoot

$NoAnalyzer = $null -eq (Get-Module -ListAvailable -Name 'PSScriptAnalyzer' -ErrorAction SilentlyContinue |
        Select-Object -First 1)

# Fail the build on these. Kept as data so the "is this still a real rule name"
# test below can check every one of them - a typo here does not error, it just
# gates nothing, forever.
$FatalRules = @(
    'PSAvoidAssignmentToAutomaticVariable'
    'PSShouldProcess'
    'PSUseOutputTypeCorrectly'
    'PSAvoidUsingCmdletAliases'
)

$ExcludedRules = @(
    'PSAvoidUsingWriteHost'
    'PSUseShouldProcessForStateChangingFunctions'
)

# The bridge from discovery to run. Pester keeps the two in separate scopes, so
# a plain $RepoRoot read inside an It comes back $null. A hashtable handed to
# -ForEach on the Describe injects its keys as run-time variables.
$Shared = @{
    RepoRoot      = $RepoRoot
    FatalRules    = $FatalRules
    ExcludedRules = $ExcludedRules
}

# The public cmdlets that destroy or take over something. Every one of them has
# to offer -WhatIf, which is the promise the Private-folder exclusion below
# leans on. Discovery scope so <_> can name them.
$DestructiveCmdlets = @(
    'Start-ZellijTerminal'
    'Stop-ZellijTerminal'
    'Register-ZellijTerminal'
    'Unregister-ZellijTerminal'
    'Install-ZellijTerminalPad'
    'Uninstall-ZellijTerminalPad'
)

Describe 'PSScriptAnalyzer' -Skip:$NoAnalyzer -ForEach $Shared {

    BeforeAll {
        Import-Module PSScriptAnalyzer -ErrorAction Stop

        function Format-ZtFinding {
            <#
                One finding per line, file:line first, so a red build tells you
                where to go without opening the object.
            #>
            param([Parameter()][object[]]$Finding)

            return @($Finding | ForEach-Object {
                    $file = if ($_.ScriptPath) { Split-Path -Leaf $_.ScriptPath } else { '<no file>' }
                    '{0}:{1} {2} - {3}' -f $file, $_.Line, $_.RuleName, $_.Message
                })
        }

        # EXCLUSION 1: PSAvoidUsingWriteHost, everywhere.
        #
        # This is a CLI. `zt` prints a table where the colour IS the state -
        # running green, stale yellow, parked dim - and Show-ZtSessionTable and
        # the guides are nothing but formatted terminal output. Write-Output
        # would put those strings on the pipeline, where they lose their colour
        # and, worse, become the return value of commands whose return value is
        # consumed by the pad and by the Command Palette extension. The rule is
        # right about libraries and wrong about this program.
        #
        # The errors are collected rather than left to print. Analysing a file
        # while something else is rewriting it throws "Object reference not set
        # to an instance of an object" out of the analyzer - seen once here on
        # 1.25.0, with another editor saving into the working tree mid-scan. It
        # is per-file and recoverable, the finding count was unchanged, and a
        # raw NRE in the middle of a green run reads like the suite broke. They
        # are printed in the report below instead.
        $scanErrors = @()
        $script:AllFindings = @(
            Invoke-ScriptAnalyzer -Path $RepoRoot -Recurse -ExcludeRule 'PSAvoidUsingWriteHost' `
                -ErrorAction SilentlyContinue -ErrorVariable scanErrors
        )
        $script:ScanErrors = @($scanErrors)

        # EXCLUSION 2: PSUseShouldProcessForStateChangingFunctions, Private only.
        #
        # Private\Core.ps1 is where the verbs live that the rule reacts to -
        # Remove-ZtLink, Set-*, New-* - and they are internal helpers reached
        # only through a public cmdlet that has already asked. Threading
        # ShouldProcess through them would mean two confirmations for one
        # action, and the second one worded in terms the caller never typed.
        #
        # The exclusion is only defensible because the public surface really
        # does implement it, so that is asserted below rather than assumed. Note
        # this is scoped to the folder, not the rule: the same rule still fires
        # once in scripts\zj-claude-tab.ps1 and is reported there.
        $privatePrefix = (Join-Path (Join-Path (Join-Path $RepoRoot 'module') 'ZellijTerminal') 'Private') +
        [System.IO.Path]::DirectorySeparatorChar

        $script:Excused = @(
            $script:AllFindings | Where-Object {
                $_.RuleName -eq 'PSUseShouldProcessForStateChangingFunctions' -and
                $_.ScriptPath -and
                $_.ScriptPath.StartsWith($privatePrefix, [System.StringComparison]::OrdinalIgnoreCase)
            }
        )

        $script:Findings = @($script:AllFindings | Where-Object { $script:Excused -notcontains $_ })
    }

    Context 'The rule names the gate is built out of' {

        # A misspelled rule name is not an error and not a warning. It is a
        # filter that matches nothing, so the gate goes permanently green and
        # nobody finds out until the defect it was meant to catch ships.
        It '<_> is a rule PSScriptAnalyzer still ships' -ForEach ($FatalRules + $ExcludedRules) {
            $known = @((Get-ScriptAnalyzerRule).RuleName)
            $known | Should -Contain $_
        }
    }

    Context 'Fatal' {

        It 'finds nothing that fails to parse' {
            # A ParseError record means the file could not be analysed at all,
            # so every other rule silently skipped it. Compat.Tests.ps1 owns the
            # 5.1 parse contract; this is the 7 one, and it is fatal here
            # because a green analyzer run over an unparsed file is a lie.
            $parseErrors = @($script:AllFindings | Where-Object { $_.Severity -eq 'ParseError' })
            $detail = (Format-ZtFinding -Finding $parseErrors) -join "`n"
            $parseErrors.Count | Should -Be 0 -Because "nothing should fail to parse:`n$detail"
        }

        It 'finds nothing of Severity Error' {
            $errors = @($script:AllFindings | Where-Object { $_.Severity -eq 'Error' })
            $detail = (Format-ZtFinding -Finding $errors) -join "`n"
            $errors.Count | Should -Be 0 -Because "Error severity is always a defect:`n$detail"
        }

        It 'finds no <_>' -ForEach $FatalRules {
            # Captured before the pipeline: inside Where-Object, $_ is the
            # finding, not the rule name Pester handed this test case.
            $rule = $_
            $hits = @($script:Findings | Where-Object { $_.RuleName -eq $rule })
            $detail = (@($hits | ForEach-Object {
                        $file = if ($_.ScriptPath) { Split-Path -Leaf $_.ScriptPath } else { '<no file>' }
                        '{0}:{1} {2}' -f $file, $_.Line, $_.Message
                    })) -join "`n"
            $hits.Count | Should -Be 0 -Because "this rule is gated on purpose:`n$detail"
        }
    }

    Context 'The exclusions, and what they are not allowed to hide' {

        It 'drops PSAvoidUsingWriteHost before anything else looks at the results' {
            # Pins the exclusion to the run rather than to a comment: if someone
            # removes -ExcludeRule the fatal checks above start filtering a set
            # 330 records larger, which is slow and, the day Write-Host trips a
            # gated rule name, wrong.
            @($script:AllFindings | Where-Object { $_.RuleName -eq 'PSAvoidUsingWriteHost' }).Count |
                Should -Be 0
        }

        It 'excuses the state-changing rule only inside Private' {
            $strays = @($script:Excused | Where-Object { $_.ScriptPath -notmatch '[\\/]Private[\\/]' })
            $detail = (Format-ZtFinding -Finding $strays) -join "`n"
            $strays.Count | Should -Be 0 -Because "the excuse is folder-scoped:`n$detail"
        }

        It 'leaves every public state-changing function still answerable to the rule' {
            # The other half of the same bargain. Private is excused because the
            # public surface is not; if a new Public function starts changing
            # state without ShouldProcess, it shows up here even though the rule
            # is not in the fatal list.
            $public = @($script:Findings | Where-Object {
                    $_.RuleName -eq 'PSUseShouldProcessForStateChangingFunctions' -and
                    $_.ScriptPath -match '[\\/]Public[\\/]'
                })
            $detail = (Format-ZtFinding -Finding $public) -join "`n"
            $public.Count | Should -Be 0 -Because "public cmdlets implement ShouldProcess:`n$detail"
        }
    }

    Context 'Everything else' {

        It 'reports the findings it does not enforce' {
            # Deliberately not a gate and deliberately not a ratchet: a number
            # that fails the build the moment it goes up is the zero-findings
            # mistake wearing a hat. It prints, so the count is in front of
            # whoever runs the suite, and the assertion only checks the report
            # is usable - a record with no file and no line cannot be acted on.
            $byRule = $script:Findings | Group-Object RuleName | Sort-Object Count -Descending

            Write-Host ''
            Write-Host ("  PSScriptAnalyzer: {0} findings reported, not enforced" -f $script:Findings.Count)
            foreach ($group in $byRule) {
                Write-Host ('    {0,5}  {1}' -f $group.Count, $group.Name)
            }
            Write-Host ("  ({0} PSUseShouldProcessForStateChangingFunctions excused in Private, PSAvoidUsingWriteHost excluded repo-wide)" -f $script:Excused.Count)
            foreach ($scanError in $script:ScanErrors) {
                Write-Host ('  scan error: ' + $scanError.Exception.Message)
            }
            Write-Host ''

            $unusable = @($script:Findings | Where-Object { -not $_.ScriptPath })
            $unusable.Count | Should -Be 0
        }
    }
}

Describe 'ShouldProcess on the public cmdlets that change something' {

    # Deliberately outside the analyzer Describe: this is the claim the Private
    # exclusion rests on, so it has to hold on a machine where PSScriptAnalyzer
    # is not installed and that half of the file is skipped. It needs no Zellij
    # and no session - importing the module and reading metadata is enough.

    BeforeAll {
        $manifest = Join-Path $PSScriptRoot '..\module\ZellijTerminal\ZellijTerminal.psd1'
        Import-Module $manifest -Force -ErrorAction Stop
    }

    AfterAll {
        Remove-Module ZellijTerminal -Force -ErrorAction SilentlyContinue
    }

    It '<_> offers -WhatIf' -ForEach $DestructiveCmdlets {
        # -WhatIf on these is not a nicety. Stop- and Unregister- take away a
        # session or a registry entry with no undo, and Install-/Uninstall-Pad
        # rewrite the keyboard remapper's global config - the one that decides
        # what the keys on the machine do. Being able to ask first is the
        # difference between a mistake and a lost afternoon.
        $command = Get-Command -Name $_ -ErrorAction SilentlyContinue
        $command | Should -Not -BeNullOrEmpty -Because "$_ should be exported"
        $command.Parameters.ContainsKey('WhatIf') | Should -BeTrue
    }

    It '<_> offers -Confirm too' -ForEach $DestructiveCmdlets {
        # Falls out of SupportsShouldProcess rather than being written by hand,
        # so this is really a check that -WhatIf came from the attribute and not
        # from someone declaring a [switch]$WhatIf parameter that does nothing.
        (Get-Command -Name $_).Parameters.ContainsKey('Confirm') | Should -BeTrue
    }
}
