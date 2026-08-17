<#
    The uninstaller's contract.

    Most of this is source-level rather than behavioural, for the obvious
    reason: a test that actually uninstalls leaves the machine it ran on
    without the thing being tested. The one behavioural test here is -WhatIf,
    which is safe by definition and is also the one people rely on before
    pulling the trigger - so it is worth proving it changes nothing rather
    than trusting that it does.

    The junction assertions are the point of the file. Removing the module
    means removing a REPARSE POINT: a recursive delete follows the link and
    takes module\ZellijTerminal out of the clone with it. That mistake is
    silent, immediate and unrecoverable without git, and it is exactly the sort
    of thing that gets refactored back in by someone tidying up.
#>

BeforeDiscovery {
    # Pester evaluates -Skip during DISCOVERY, before any BeforeAll has run, so
    # anything a -Skip depends on has to be computed here. Set in BeforeAll
    # instead, it is $null at discovery and every guarded test skips silently -
    # which is how the two -WhatIf tests below first "passed".
    $modulesRoot = $env:PSModulePath -split [System.IO.Path]::PathSeparator |
                   Where-Object { $_ -and $_ -match 'Documents.PowerShell.Modules$' } |
                   Select-Object -First 1
    $script:JunctionPath = if ($modulesRoot) { Join-Path $modulesRoot 'ZellijTerminal' } else { $null }
    $script:IsInstalled  = $script:JunctionPath -and (Test-Path -LiteralPath $script:JunctionPath)
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Source   = Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Uninstall.ps1'
    $script:Text     = Get-Content -LiteralPath $script:Source -Raw

    # Redirect the registry to a throwaway device before invoking anything.
    # These are the only tests in the suite that call the uninstaller at all,
    # including with -Purge, and -WhatIf is the very guard under test - relying
    # on it to protect the real workspace list is circular.
    $script:RealDevice  = $env:ZT_DEVICE
    $script:TestDevice  = 'zt-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $env:ZT_DEVICE      = $script:TestDevice
    $script:TestDevFile = Join-Path $script:RepoRoot "config/devices/$($script:TestDevice).json"
    $script:RealDevFile = Join-Path $script:RepoRoot "config/devices/$env:COMPUTERNAME.json"
    $script:RealBefore  = if (Test-Path -LiteralPath $script:RealDevFile) {
                              (Get-FileHash -LiteralPath $script:RealDevFile -Algorithm SHA256).Hash
                          } else { 'absent' }

    Import-Module (Join-Path $script:RepoRoot 'module/ZellijTerminal/ZellijTerminal.psd1') -Force -ErrorAction SilentlyContinue
    $script:Cmd = Get-Command Uninstall-ZellijTerminal -ErrorAction SilentlyContinue
}

AfterAll {
    if ($script:TestDevFile -and (Test-Path -LiteralPath $script:TestDevFile)) {
        Remove-Item -LiteralPath $script:TestDevFile -Force -ErrorAction SilentlyContinue
    }
    $env:ZT_DEVICE = $script:RealDevice
}

Describe 'These tests cannot reach the real registry' {
    It 'is pointed at a throwaway device' {
        $m = Get-Module ZellijTerminal
        (& $m { Get-ZtDevicePath }) | Should -Match ([regex]::Escape($script:TestDevice))
    }

    It 'leaves the real device file byte-identical' {
        $now = if (Test-Path -LiteralPath $script:RealDevFile) {
                   (Get-FileHash -LiteralPath $script:RealDevFile -Algorithm SHA256).Hash
               } else { 'absent' }
        $now | Should -Be $script:RealBefore
    }
}

Describe 'Uninstall-ZellijTerminal' {

    Context 'is reachable at all' {
        It 'exists and is exported' {
            $script:Cmd | Should -Not -BeNullOrEmpty
        }

        It 'is reachable as: zt uninstall' {
            $dispatch = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Dispatch.ps1') -Raw
            $dispatch | Should -Match "\^uninstall\`$"
            $dispatch | Should -Match 'Uninstall-ZellijTerminal'
        }

        It 'is offered by tab completion, or nobody discovers it' {
            $dispatch = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Dispatch.ps1') -Raw
            $dispatch | Should -Match "'uninstall'"
        }
    }

    Context 'the safety surface' {
        It 'supports -WhatIf and -Confirm' {
            $script:Cmd.Parameters.Keys | Should -Contain 'WhatIf'
            $script:Cmd.Parameters.Keys | Should -Contain 'Confirm'
        }

        It 'has <Name>, so the destructive parts are opt-in or skippable' -ForEach @(
            @{ Name = 'Purge' }
            @{ Name = 'Force' }
            @{ Name = 'KeepPad' }
            @{ Name = 'KeepPalette' }
            @{ Name = 'KeepSession' }
        ) {
            $script:Cmd.Parameters.Keys | Should -Contain $Name
        }

        # ConfirmImpact High makes every ShouldProcess call prompt at the
        # default preference. With no TTY each one throws "PowerShell is in
        # NonInteractive mode", so the command aborts step by step and still
        # prints a summary claiming it kept everything. It was written High and
        # this test exists because that actually happened.
        It 'does not declare ConfirmImpact High' {
            $script:Text | Should -Not -Match "ConfirmImpact\s*=\s*'High'"
        }

        It 'refuses rather than proceeding when there is nobody to confirm with' {
            $script:Text | Should -Match 'Refusing to uninstall without confirmation'
        }

        It 'gates on one confirmation, not one per step' {
            # Count the CALL, not the word. The first version matched the
            # comment above the call as well and reported two gates where there
            # is one - a test that fails for a reason unrelated to the code is
            # just a slower way of not testing it.
            ([regex]::Matches($script:Text, '\$PSCmdlet\.ShouldContinue\(')).Count | Should -Be 1
        }
    }

    Context 'the junction, which is the dangerous part' {

        It 'checks for a reparse point before deleting the module path' {
            $script:Text | Should -Match 'ReparsePoint'
        }

        It 'refuses when the module path is a real directory rather than a link' {
            # Without this branch the fallback is deleting somebody's own
            # ZellijTerminal folder because it happened to share the name.
            $script:Text | Should -Match 'Refusing to delete it'
        }

        It 'never recursively deletes the module path' {
            # -Recurse on a junction follows it into the clone. Any Remove-Item
            # -Recurse aimed at $modulePath is the bug this file exists to stop.
            $lines = $script:Text -split "`r?`n" | Where-Object { $_ -match 'modulePath' -and $_ -match 'Remove-Item' }
            $lines | Should -BeNullOrEmpty
        }

        It 'clears ReadOnly before deleting, or the delete fails with access denied' {
            $script:Text | Should -Match 'FileAttributes\]::ReadOnly'
        }
    }

    Context 'what it must not destroy' {

        It 'keeps workspace registrations unless -Purge is given' {
            # The registrations are the user's work. Losing them to a reinstall
            # is how people stop reinstalling.
            $script:Text | Should -Match 'if \(\$Purge\)'
            $script:Text | Should -Match 'remove with -Purge'
        }

        It 'removes only the hooks key from the global settings, never the file' {
            # That file holds permissions, plugins and autoMode. Deleting it to
            # remove one key would cost somebody their whole Claude Code config.
            $script:Text | Should -Match "PSObject\.Properties\.Remove\('hooks'\)"
            $script:Text | Should -Not -Match 'Remove-Item.*globalHook'
        }

        It 'backs the global settings up before rewriting them' {
            $script:Text | Should -Match 'Copy-Item -LiteralPath \$globalHook'
        }

        It 'restores the pre-install Zellij config rather than leaving a hole' {
            $script:Text | Should -Match 'Restore your pre-install config'
        }

        It 'picks the backup by its filename timestamp, not LastWriteTime' {
            # Copy-Item preserves the source mtime, so a backup's LastWriteTime
            # is the age of its CONTENTS. Sorting by it picks the wrong file.
            $script:Text | Should -Match "Sort-Object \{ \[regex\]::Match\(\`$_\.Name"
        }

        It 'says what it deliberately did not touch' {
            $script:Text | Should -Match 'Not touched, because this did not install them'
        }
    }

    # Only meaningful where zt is actually installed. Skipped on a clean CI
    # runner, which has no junction to leave in place.
    Context '-WhatIf really is inert' -Skip:(-not $script:IsInstalled) -ForEach @(
        @{ Junction = $script:JunctionPath }
    ) {
        It 'leaves the module junction in place' {
            Uninstall-ZellijTerminal -WhatIf -WarningAction SilentlyContinue | Out-Null
            Test-Path -LiteralPath $Junction | Should -BeTrue
        }

        It 'leaves the workspace registrations alone, even with -Purge' {
            $devFile = Join-Path $script:RepoRoot "config/devices/$env:COMPUTERNAME.json"
            $before = if (Test-Path -LiteralPath $devFile) { (Get-Item -LiteralPath $devFile).Length } else { 0 }
            Uninstall-ZellijTerminal -WhatIf -Purge -WarningAction SilentlyContinue | Out-Null
            $after = if (Test-Path -LiteralPath $devFile) { (Get-Item -LiteralPath $devFile).Length } else { 0 }
            $after | Should -Be $before
        }
    }
}
