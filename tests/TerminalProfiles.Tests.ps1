<#
    Importing Windows Terminal profiles as workspaces.

    This replaced a hard dependency on a third-party bookmarks module. Such a
    module curates Windows Terminal profiles - its "bookmarks" ARE profiles - so
    reading settings.json directly serves everyone, including its users.

    Everything here runs against a fixture rather than the machine's real
    settings.json. That is the point: the interesting cases are a Claude
    profile, a dev-server profile, a bare shell and the rig's own session
    launcher, and no single machine is guaranteed to have all four. Testing
    against whatever profiles the author happens to own is exactly how the
    launcher false-positive survived long enough to be caught by hand.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'module/ZellijTerminal/ZellijTerminal.psd1') -Force -ErrorAction SilentlyContinue
    $script:M = Get-Module ZellijTerminal

    $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ("zt-wt-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:Work -Force | Out-Null

    # Two real directories, so "points somewhere that is not here" can be tested
    # as a separate case from "is not a Claude profile".
    $script:DirA = Join-Path $script:Work 'alpha'
    $script:DirB = Join-Path $script:Work 'beta'
    New-Item -ItemType Directory -Path $script:DirA, $script:DirB -Force | Out-Null

    $script:Fixture = Join-Path $script:Work 'settings.json'
    @{
        profiles = @{
            list = @(
                # launches Claude through a shell - the common bookmark shape
                @{ name = 'alpha'; guid = '{1}'; startingDirectory = $script:DirA
                   commandline = 'pwsh.exe -NoExit -Command "claude --continue --resume alpha"' }

                # the rig's own launcher. The word claude appears, as the SESSION
                # NAME, and importing it would register the thing that opens the
                # session as a project inside that session.
                @{ name = 'launcher'; guid = '{2}'; startingDirectory = $script:DirB
                   commandline = 'zellij.exe attach --create claude' }

                # a real command, not Claude
                @{ name = 'devserver'; guid = '{3}'; startingDirectory = $script:DirB
                   commandline = 'pwsh.exe -NoExit -Command "npm run dev"' }

                # a bare shell in a folder
                @{ name = 'shell'; guid = '{4}'; startingDirectory = $script:DirB
                   commandline = 'pwsh.exe' }

                # no commandline at all - uses the default profile's shell
                @{ name = 'plain'; guid = '{5}'; startingDirectory = $script:DirB }

                # no startingDirectory: not a workspace candidate at all
                @{ name = 'nodir'; guid = '{6}'; commandline = 'pwsh.exe' }
            )
        }
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:Fixture -Encoding UTF8
}

AfterAll {
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) {
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Unwrapping what a profile actually runs' {

    It '<Label> -> <Expected>' -ForEach @(
        @{ Label = 'claude behind a shell';     Cmd = 'pwsh.exe -NoExit -Command "claude --continue --resume x"'; Expected = 'claude' }
        @{ Label = 'claude behind -c';          Cmd = 'pwsh -c "claude --resume x"';                              Expected = 'claude' }
        @{ Label = 'claude bare';               Cmd = 'claude --continue';                                        Expected = 'claude' }
        @{ Label = 'claude.exe with a path';    Cmd = 'C:\tools\claude.exe --continue';                           Expected = 'claude' }
        @{ Label = 'zellij, claude as a value'; Cmd = 'zellij.exe attach --create claude';                        Expected = 'zellij' }
        @{ Label = 'a dev server';              Cmd = 'pwsh.exe -NoExit -Command "npm run dev"';                  Expected = 'npm' }
        @{ Label = 'a bare shell';              Cmd = 'pwsh.exe';                                                 Expected = 'pwsh' }
        @{ Label = 'nothing';                   Cmd = '';                                                         Expected = '' }
    ) {
        $got = & $script:M { param($c) Get-ZtProfileFirstToken (Get-ZtProfileCommand $c) } $Cmd
        $got | Should -Be $Expected
    }

    It 'does not mistake a session named claude for the claude command' {
        # The single most important case in this file. A substring match on
        # "claude" imports the rig's own launcher profile as a project.
        $got = & $script:M { Get-ZtProfileFirstToken (Get-ZtProfileCommand 'zellij.exe attach --create claude') }
        $got | Should -Not -Be 'claude'
    }
}

Describe 'Reading profiles as workspace candidates' {

    BeforeAll {
        $script:Found = & $script:M { param($f) Get-ZtTerminalProfile -SettingsPath $f } $script:Fixture
    }

    It 'ignores profiles with no startingDirectory' {
        @($script:Found | Where-Object { $_.Name -eq 'nodir' }) | Should -BeNullOrEmpty
    }

    It 'excludes the session launcher' {
        @($script:Found | Where-Object { $_.Name -eq 'launcher' }) | Should -BeNullOrEmpty
    }

    It 'infers kind claude for a profile that launches Claude' {
        $a = @($script:Found | Where-Object { $_.Name -eq 'alpha' })[0]
        $a          | Should -Not -BeNullOrEmpty
        $a.Kind     | Should -Be 'claude'
        # No command: zt start runs `claude --name <tab>` itself. Carrying the
        # profile's own --resume would pin every start to one stale session id.
        $a.Command  | Should -BeNullOrEmpty
    }

    It 'infers kind pwsh and keeps the command for a dev-server profile' {
        $d = @($script:Found | Where-Object { $_.Name -eq 'devserver' })[0]
        $d.Kind    | Should -Be 'pwsh'
        $d.Command | Should -Be 'npm run dev'
    }

    It 'infers a bare shell for <Name>' -ForEach @(@{ Name = 'shell' }, @{ Name = 'plain' }) {
        $p = @($script:Found | Where-Object { $_.Name -eq $Name })[0]
        $p.Kind    | Should -Be 'pwsh'
        $p.Command | Should -BeNullOrEmpty
    }

    It 'honours -Filter on the profile name' {
        $only = & $script:M { param($f) Get-ZtTerminalProfile -SettingsPath $f -Filter 'dev*' } $script:Fixture
        @($only).Count | Should -Be 1
        @($only)[0].Name | Should -Be 'devserver'
    }

    It 'expands environment variables in the starting directory' {
        $f2 = Join-Path $script:Work 'envvar.json'
        @{ profiles = @{ list = @(
            @{ name = 'home'; guid = '{9}'; startingDirectory = '%USERPROFILE%'; commandline = 'claude' }
        ) } } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $f2 -Encoding UTF8
        $got = & $script:M { param($f) Get-ZtTerminalProfile -SettingsPath $f } $f2
        @($got)[0].Path | Should -Be ($env:USERPROFILE.TrimEnd('\'))
    }

    It 'returns nothing rather than throwing when the settings file is absent' {
        $got = & $script:M { param($f) Get-ZtTerminalProfile -SettingsPath $f } (Join-Path $script:Work 'nope.json')
        @($got).Count | Should -Be 0
    }
}

Describe 'The import no longer depends on a third-party module' {

    It 'neither implementation imports a bookmarks module' {
        foreach ($f in @('module/ZellijTerminal/Public/Registry.ps1', 'scripts/zj-claude-project.ps1')) {
            $t = Get-Content -LiteralPath (Join-Path $script:RepoRoot $f) -Raw
            $t | Should -Not -Match 'Import-Module\s+Save-TerminalHere'
            $t | Should -Not -Match 'Get-TerminalHere'
        }
    }

    It 'both implementations skip the zellij launcher' {
        foreach ($f in @('module/ZellijTerminal/Private/Core.ps1', 'scripts/zj-claude-project.ps1')) {
            $t = Get-Content -LiteralPath (Join-Path $script:RepoRoot $f) -Raw
            $t | Should -Match "eq 'zellij'"
        }
    }

    It 'both default to Claude profiles only, and both offer -IncludeAll' {
        foreach ($f in @('module/ZellijTerminal/Public/Registry.ps1', 'scripts/zj-claude-project.ps1')) {
            $t = Get-Content -LiteralPath (Join-Path $script:RepoRoot $f) -Raw
            $t | Should -Match '\$IncludeAll'
        }
    }

    It 'both report what the default filtered out' {
        # A default that filters in silence is indistinguishable from one that
        # found nothing, which is the failure mode this project exists to refuse.
        (Get-Content -LiteralPath (Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Registry.ps1') -Raw) |
            Should -Match 'Skipped'
        (Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts/zj-claude-project.ps1') -Raw) |
            Should -Match 'Skipped'
    }
}
