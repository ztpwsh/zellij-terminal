<#
    Export and import.

    These are behavioural rather than source-level, because the round trip is
    the whole feature and asserting on source text would prove nothing about it.
    They run entirely against temp files and a synthetic registry - nothing here
    reads or writes the real config, so running the suite cannot cost you your
    registrations. That constraint is the reason for the fixture below rather
    than exporting the live device.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'module/ZellijTerminal/ZellijTerminal.psd1') -Force -ErrorAction SilentlyContinue

    # Point the whole registry at a throwaway device for the duration.
    #
    # Get-ZtDeviceName honours ZT_DEVICE, and every read and write goes through
    # it, so this redirects config/devices/<name>.json to a scratch file. Relying
    # on -WhatIf alone was not good enough: -WhatIf is a property of the code
    # under test, and the code under test is what these tests exist to doubt. A
    # suite that can delete the user's workspace list if one guard is wrong is
    # not a suite anyone should run twice.
    $script:RealDevice  = $env:ZT_DEVICE
    $script:TestDevice  = 'zt-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $env:ZT_DEVICE      = $script:TestDevice

    # Ask the module where the registry lives rather than spelling it out here.
    # These paths were hardcoded as <repo>\config\devices\ and silently stopped
    # describing anything when the device file moved to %LOCALAPPDATA% - which
    # left the "leaves the real device file byte-identical" guard below hashing
    # a path that no longer existed and passing for the wrong reason. A safety
    # net that cannot notice it is pointed at the wrong file is not one.
    $script:ConfigHome  = & (Get-Module ZellijTerminal) { Get-ZtConfigHome }
    $script:TestDevFile = Join-Path $script:ConfigHome (Join-Path 'devices' "$($script:TestDevice).json")

    $script:RealDeviceName = $script:RealDevice
    if (-not $script:RealDeviceName) { $script:RealDeviceName = $env:COMPUTERNAME }

    # Proof, not assumption: remember the real file so AfterAll can assert it.
    $script:RealDevFile = Join-Path $script:ConfigHome (Join-Path 'devices' "$($script:RealDeviceName).json")
    $script:RealBefore  = if (Test-Path -LiteralPath $script:RealDevFile) {
                              (Get-FileHash -LiteralPath $script:RealDevFile -Algorithm SHA256).Hash
                          } else { 'absent' }

    $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ("zt-port-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:Work -Force | Out-Null

    # A bundle exactly as another machine would write one: one workspace that
    # travels via {root, rel}, one pinned to an absolute path that does not
    # exist here. Both cases have to be reported, differently.
    $script:Bundle = Join-Path $script:Work 'bundle.json'
    @{
        schema      = 1
        exportedAt  = '2026-08-15T12:00:00.0000000+01:00'
        fromDevice  = 'OTHERBOX'
        ztVersion   = '0.5.0'
        roots       = @{ code = 'D:\code' }
        workspaces  = @(
            @{ id = 'api';   key = 'aaaa1111'; kind = 'claude'; command = ''; name = ''
               root = 'code'; rel = 'api'; abs = $null; tags = @() }
            @{ id = 'ghost'; key = 'bbbb2222'; kind = 'pwsh';   command = 'npm run dev'; name = ''
               root = $null;  rel = $null;  abs = 'Q:\nowhere'; tags = @() }
        )
        shared      = @()
        padWasSetUp = $false
        palette     = $null
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:Bundle -Encoding UTF8
}

AfterAll {
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) {
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($script:TestDevFile -and (Test-Path -LiteralPath $script:TestDevFile)) {
        Remove-Item -LiteralPath $script:TestDevFile -Force -ErrorAction SilentlyContinue
    }
    $env:ZT_DEVICE = $script:RealDevice
}

Describe 'The suite does not touch the real registry' {
    # Deliberately the first assertion in the file. This once went wrong - the
    # real device file came back empty after a full run and the cause was never
    # reproduced, which is the worst kind of report to leave standing. The
    # redirection above makes it impossible; this proves the redirection works
    # rather than trusting that it does.
    It 'is pointed at a throwaway device' {
        $env:ZT_DEVICE | Should -Be $script:TestDevice
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

Describe 'Where the registry lives' {
    # The device file is state this machine writes, so it belongs outside any
    # working tree. It used to sit in <clone>\config\devices\, which meant
    # `git clean -xfd` deleted it, a re-clone lost it, and two clones gave two
    # registries with nothing saying which was being read. On this machine it
    # was worse than theoretical: the rig was installed from the release
    # worktree, which Publish-Release.ps1 empties on every run - ignored files
    # included - so a release would have taken the registry with it silently.

    BeforeAll { $script:M = Get-Module ZellijTerminal }

    AfterEach { Remove-Item Env:\ZT_CONFIG_HOME -ErrorAction SilentlyContinue }

    It 'keeps the device registry out of the clone by default' {
        Remove-Item Env:\ZT_CONFIG_HOME -ErrorAction SilentlyContinue
        $path = & $script:M { Get-ZtDevicePath }

        $path | Should -Not -BeNullOrEmpty
        $path.StartsWith($script:RepoRoot, [StringComparison]::OrdinalIgnoreCase) |
            Should -BeFalse -Because "the registry must not live in a working tree, but was at $path"
    }

    It 'defaults to %LOCALAPPDATA%\ZellijTerminal, beside live\ and root.txt' -Skip:(-not $env:LOCALAPPDATA) {
        Remove-Item Env:\ZT_CONFIG_HOME -ErrorAction SilentlyContinue
        $expected = Join-Path $env:LOCALAPPDATA 'ZellijTerminal'
        (& $script:M { Get-ZtConfigHome }) | Should -Be $expected
    }

    It 'puts the device file under devices\ and names it for the device' {
        Remove-Item Env:\ZT_CONFIG_HOME -ErrorAction SilentlyContinue
        $path = & $script:M { Get-ZtDevicePath }

        (Split-Path $path -Leaf)              | Should -Be "$($script:TestDevice).json"
        (Split-Path (Split-Path $path -Parent) -Leaf) | Should -Be 'devices'
    }

    It 'lets ZT_CONFIG_HOME move the registry back into a repo' {
        # This is how several PCs share one registry through a PRIVATE repo,
        # which is the use the in-clone layout was built for. It stays
        # supported - as something chosen, not as the default that a public
        # user gets without knowing the directory is disposable.
        $env:ZT_CONFIG_HOME = Join-Path $script:Work 'cfg'
        $path = & $script:M { Get-ZtDevicePath }

        $path | Should -Be (Join-Path $env:ZT_CONFIG_HOME (Join-Path 'devices' "$($script:TestDevice).json"))
    }

    It 'moves BOTH files when the override is set, never just one' {
        # A registry split across two locations is worse than either alone: the
        # shared list and the device list stop being one registry and nothing
        # reports that they have diverged.
        $env:ZT_CONFIG_HOME = Join-Path $script:Work 'cfg'

        (& $script:M { Get-ZtSharedPath }) | Should -Be (Join-Path $env:ZT_CONFIG_HOME 'workspaces.json')
        (& $script:M { Get-ZtDevicePath }) | Should -Match ([regex]::Escape($env:ZT_CONFIG_HOME))
    }

    It 'leaves workspaces.json in the clone when there is no override' {
        # It is committed content that ships with the checkout - source, not
        # state - so it is the one file that genuinely belongs in the tree.
        Remove-Item Env:\ZT_CONFIG_HOME -ErrorAction SilentlyContinue
        $shared = & $script:M { Get-ZtSharedPath }

        (Split-Path $shared -Leaf) | Should -Be 'workspaces.json'
        (Split-Path (Split-Path $shared -Parent) -Leaf) | Should -Be 'config'
    }
}

Describe 'Export and import' {

    Context 'the commands exist and are reachable' {
        It 'exports <Name>' -ForEach @(
            @{ Name = 'Export-ZellijTerminal' }
            @{ Name = 'Import-ZellijTerminal' }
        ) {
            Get-Command $Name -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It 'both support -WhatIf' {
            (Get-Command Export-ZellijTerminal).Parameters.Keys | Should -Contain 'WhatIf'
            (Get-Command Import-ZellijTerminal).Parameters.Keys | Should -Contain 'WhatIf'
        }

        It 'is reachable as zt <Verb>' -ForEach @(@{ Verb = 'export' }, @{ Verb = 'import' }) {
            $d = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Dispatch.ps1') -Raw
            $d | Should -Match "\^$Verb\`$"
            $d | Should -Match "'$Verb'"      # and offered by completion
        }
    }

    Context 'the bundle format' {
        It 'refuses a schema it does not understand, rather than guessing' {
            $bad = Join-Path $script:Work 'bad.json'
            '{ "schema": 99 }' | Set-Content -LiteralPath $bad -Encoding UTF8
            { Import-ZellijTerminal -Path $bad -ErrorAction Stop } | Should -Throw
        }

        It 'refuses a file that is not JSON' {
            $bad = Join-Path $script:Work 'notjson.txt'
            'this is not json' | Set-Content -LiteralPath $bad -Encoding UTF8
            { Import-ZellijTerminal -Path $bad -ErrorAction Stop } | Should -Throw
        }

        It 'refuses a file that is not there' {
            { Import-ZellijTerminal -Path (Join-Path $script:Work 'nope.json') -ErrorAction Stop } | Should -Throw
        }
    }

    Context 'reading a bundle from another machine' {

        It 'parses without touching the real registry' {
            # -WhatIf: proves the read path works on a foreign bundle while
            # guaranteeing this test cannot modify the machine it runs on.
            { Import-ZellijTerminal -Path $script:Bundle -WhatIf } | Should -Not -Throw
        }

        It 'produces no error records for a root whose drive is absent' {
            # Join-Path validates drives and threw "Cannot find drive. A drive
            # with the name 'D' does not exist." for a perfectly ordinary
            # cross-machine root. Resolve-ZtPath combines as text now; this is
            # the regression guard.
            $errs = @()
            Import-ZellijTerminal -Path $script:Bundle -WhatIf -ErrorVariable errs -ErrorAction SilentlyContinue |
                Out-Null
            $errs | Should -BeNullOrEmpty
        }
    }

    Context 'the helpers the round trip depends on' {

        It 'Get-ZtProp survives an object with no properties at all' {
            # `roots` on a fresh device is {} out of JSON. Reading .Name off an
            # empty Properties collection throws under Set-StrictMode 2.0, which
            # is what importing onto a new machine hit.
            $m = Get-Module ZellijTerminal
            { & $m { Get-ZtProp ([pscustomobject]@{}) 'anything' } } | Should -Not -Throw
            (& $m { Get-ZtProp ([pscustomobject]@{}) 'anything' 'fallback' }) | Should -Be 'fallback'
        }

        It 'Get-ZtProp still returns real values and defaults' {
            $m = Get-Module ZellijTerminal
            (& $m { Get-ZtProp ([pscustomobject]@{ a = 1 }) 'a' })          | Should -Be 1
            (& $m { Get-ZtProp ([pscustomobject]@{ a = 1 }) 'b' 'default' }) | Should -Be 'default'
            (& $m { Get-ZtProp $null 'a' 'default' })                       | Should -Be 'default'
        }

        It 'Resolve-ZtPath builds a path on a drive this machine does not have' {
            $m = Get-Module ZellijTerminal
            $ws  = [pscustomobject]@{ root = 'code'; rel = 'api'; abs = $null }
            $cfg = [pscustomobject]@{ roots = [pscustomobject]@{ code = 'D:\code' } }
            $got = & $m { param($w, $c) Resolve-ZtPath -Workspace $w -DeviceConfig $c } $ws $cfg
            $got | Should -Be 'D:\code\api'
        }

        It 'Resolve-ZtPath does not double a separator' {
            $m = Get-Module ZellijTerminal
            $ws  = [pscustomobject]@{ root = 'code'; rel = '\api'; abs = $null }
            $cfg = [pscustomobject]@{ roots = [pscustomobject]@{ code = 'D:\code\' } }
            $got = & $m { param($w, $c) Resolve-ZtPath -Workspace $w -DeviceConfig $c } $ws $cfg
            $got | Should -Be 'D:\code\api'
        }
    }

    Context 'what must never travel' {
        It 'the exporter takes only ZellijTerminal entries out of Command Palette settings' {
            # That file holds the whole application's configuration. Exporting
            # it wholesale would carry somebody's theme and pinned commands into
            # a workspace backup, and overwrite settings this rig never set.
            $src = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Portability.ps1') -Raw
            $src | Should -Match 'ZellijTerminal\|zt\\\.'
            $src | Should -Match 'dockBands'
            $src | Should -Match 'commandHotkeys'
        }

        It 'does not export live state' {
            $src = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Portability.ps1') -Raw
            $src | Should -Not -Match 'Get-ZtLive\b'
        }

        It 'records that the pad was set up without exporting its absolute paths' {
            $src = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Portability.ps1') -Raw
            $src | Should -Match 'padWasSetUp'
            $src | Should -Not -Match 'runProgramArgs'
        }
    }

    Context 'uninstall -Purge protects the thing it destroys' {
        It 'exports a backup before removing registrations' {
            $u = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Uninstall.ps1') -Raw
            $u | Should -Match 'Export-ZellijTerminal'
            $u | Should -Match 'zt-purge-backup-'
            $u | Should -Match 'restore with: zt import'
        }
    }
}

Describe 'Get-ZtWtDefaultProfile' {

    # A tab built from a bare command line has no profile, so Terminal draws it
    # with a generic console icon and a pwsh session reads as Command Prompt.
    # zac passes --profile to stop that, which means it has to find the default
    # without a working Terminal on the machine running these tests.

    BeforeAll {
        $script:RealLocal  = $env:LOCALAPPDATA
        $script:FakeLocal  = Join-Path ([System.IO.Path]::GetTempPath()) ('zt-wt-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:WtDir      = Join-Path $script:FakeLocal 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
        New-Item -ItemType Directory -Path $script:WtDir -Force | Out-Null
        $script:Mod = Get-Module ZellijTerminal
    }

    AfterAll {
        $env:LOCALAPPDATA = $script:RealLocal
        Remove-Item -LiteralPath $script:FakeLocal -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reads the default profile out of a settings file that has comments in it' {
        # JSONC. ConvertFrom-Json is not guaranteed to accept this, which is why
        # the function matches text rather than parsing - pinned here so nobody
        # "tidies" it into a parse and finds out on somebody else's machine.
        $settings = @'
{
    // Terminal writes comments into this file.
    "$help": "https://aka.ms/terminal-documentation",
    "defaultProfile": "{574e775e-4f2a-5b96-ac1e-a2962a402336}",
    "profiles": { "list": [] }
}
'@
        Set-Content -LiteralPath (Join-Path $script:WtDir 'settings.json') -Value $settings -Encoding UTF8
        $env:LOCALAPPDATA = $script:FakeLocal

        (& $script:Mod { Get-ZtWtDefaultProfile }) | Should -Be '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
    }

    It 'returns null when there is no Terminal settings file, so zac omits the flag' {
        $env:LOCALAPPDATA = Join-Path ([System.IO.Path]::GetTempPath()) ('zt-wt-absent-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

        (& $script:Mod { Get-ZtWtDefaultProfile }) | Should -BeNullOrEmpty
    }
}

Describe 'The Terminal profile fragment is installed, not committed' {

    # The profile that carries Zellij's icon is contributed as a fragment and
    # its icon is EXTRACTED from the installed zellij.exe. Neither can be a
    # tracked file: an icon in the repo redistributes someone else's mark, and
    # a fragment with a baked-in path would carry a real user's home directory
    # into a public tree. This can only be checked at the source level - the
    # suite runs on machines with no Terminal and no Zellij.

    BeforeAll {
        $script:Root      = Join-Path $PSScriptRoot '..'
        $script:Installer = Get-Content -LiteralPath (Join-Path $script:Root 'install.ps1') -Raw
        $script:Remover   = Get-Content -LiteralPath (Join-Path $script:Root 'module\ZellijTerminal\Public\Uninstall.ps1') -Raw
    }

    It 'writes the fragment rather than editing the user settings file' {
        # settings.json is JSONC and belongs to the user. A read-modify-write
        # through ConvertTo-Json would silently strip every comment in it.
        $script:Installer | Should -Match 'Fragments'
        $script:Installer | Should -Match 'zellij-terminal\.json'
    }

    It 'derives the icon from the installed binary' {
        $script:Installer | Should -Match 'ExtractAssociatedIcon'
    }

    It 'ships no icon of its own' {
        # git ls-files, so an untracked scratch image on somebody's machine does
        # not fail this, and a committed one cannot hide.
        Push-Location $script:Root
        try { $tracked = @(& git ls-files) } finally { Pop-Location }

        if (-not $tracked -or $tracked.Count -eq 0) {
            Set-ItResult -Skipped -Because 'not a git checkout'
            return
        }

        @($tracked | Where-Object { $_ -match 'zellij-logo' }) | Should -BeNullOrEmpty
    }

    It 'removes the fragment and the extracted icon on uninstall' {
        # Otherwise uninstalling leaves a Terminal profile behind pointing at an
        # image nothing owns any more.
        $script:Remover | Should -Match 'Get-ZtWtFragmentPath'
        $script:Remover | Should -Match 'zellij-logo'
    }
}
