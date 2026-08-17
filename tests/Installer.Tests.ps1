<#
    Calling install.ps1 from inside the module.

    `zt setup` offered to write the config and to register the hook, and both
    offers died the same way: install.ps1 got through its module step, printed
    the installed banner, and then failed with

        The term 'Write-Step' is not recognized

    on a function it defines at the top of itself and had used four lines
    earlier. Nothing was wrong with install.ps1. A script invoked with `&` from
    a module function runs inside that module's session state, install.ps1
    removes and re-imports ZellijTerminal as its first real step, and removing
    a module discards the scope its callers' script functions were defined
    into. Every helper still to be called stops existing mid-run.

    The first case below rebuilds that from scratch - a module, a script, no zt
    involved - because the fix is only worth keeping if the reason for it can
    still be demonstrated by somebody who was not here. The rest pin the call
    shape, since the repair is a call-site discipline and nothing in the
    language stops the next person writing `& install.ps1` again.

    Green on a machine with nothing installed: the fixture is built in a temp
    directory and the source checks read files.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Guide    = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Guide.ps1') -Raw
    $script:Install  = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'install.ps1') -Raw

    $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ("zt-installer-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $script:Work 'FixtureMod') -Force | Out-Null

    # A module with one function, which invokes a script the way Guide.ps1 used
    # to. Named uniquely so a real ZellijTerminal in the session is untouched.
    Set-Content -LiteralPath (Join-Path $script:Work 'FixtureMod/FixtureMod.psm1') -Encoding UTF8 -Value @'
function Invoke-FixtureGuide {
    param([string]$Script)
    & $Script
}
Export-ModuleMember -Function Invoke-FixtureGuide
'@

    # ... and a script shaped like install.ps1: define a helper, use it, remove
    # and re-import the module, use it again.
    Set-Content -LiteralPath (Join-Path $script:Work 'fixture-install.ps1') -Encoding UTF8 -Value @'
$ErrorActionPreference = 'Stop'
function Write-FixtureStep { param([string]$Text) Write-Output "step: $Text" }
Write-FixtureStep 'before'
Remove-Module FixtureMod -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $PSScriptRoot 'FixtureMod') -Force
Write-FixtureStep 'after'
'@

    function Invoke-Fixture {
        <#
            Run the fixture script the two ways, in a child pwsh each time so a
            half-removed fixture module cannot leak into the test session. The
            child prints OK or the error message; nothing here throws.
        #>
        param([ValidateSet('Shell', 'Module')][string]$From)

        $work = $script:Work
        $body = if ($From -eq 'Shell') {
            "& (Join-Path '$work' 'fixture-install.ps1')"
        } else {
            "Import-Module (Join-Path '$work' 'FixtureMod') -Force; " +
            "Invoke-FixtureGuide -Script (Join-Path '$work' 'fixture-install.ps1')"
        }

        $exe = (Get-Process -Id $PID).Path
        $out = & $exe -NoProfile -Command "try { $body } catch { Write-Output ('ERR: ' + `$_.Exception.Message) }" 2>&1
        return ($out | Out-String)
    }
}

AfterAll {
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) {
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Why install.ps1 cannot be called from inside the module' {

    It 'run from a shell, a script survives removing a module' {
        $out = Invoke-Fixture -From 'Shell'
        $out | Should -Match 'step: before'
        $out | Should -Match 'step: after'
    }

    It 'run from a module function, the same script loses its own functions' {
        # THE BUG, reproduced. If this ever starts passing straight through,
        # PowerShell changed the rule and Invoke-ZtInstaller can be simplified -
        # do not just delete this, work out which of the two happened.
        $out = Invoke-Fixture -From 'Module'
        $out | Should -Match 'step: before'
        $out | Should -Not -Match 'step: after'
        $out | Should -Match "Write-FixtureStep' is not recognized"
    }
}

Describe 'The guide starts the installer out of process' {

    It 'no module file invokes install.ps1 with the call operator' {
        # The call shape, not the file: a match here is the bug coming back.
        $offenders = @(
            Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'module') -Recurse -Filter '*.ps1' |
                Where-Object {
                    (Get-Content -LiteralPath $_.FullName -Raw) -match '&\s*\(Join-Path[^)]*install\.ps1'
                } |
                ForEach-Object { $_.Name }
        )
        $offenders | Should -BeNullOrEmpty
    }

    It 'both offers go through Invoke-ZtInstaller' {
        ([regex]::Matches($script:Guide, 'Invoke-ZtInstaller -Repo')).Count | Should -Be 2
    }

    It 'Invoke-ZtInstaller launches a child PowerShell with -File' {
        $script:Guide | Should -Match '-NoProfile -File \$script'
    }

    It 'it prefers the pwsh that is running, and falls back to PATH' {
        $script:Guide | Should -Match 'Get-Process -Id \$PID'
        $script:Guide | Should -Match "Get-Command pwsh"
    }

    It 'a failed install is reported rather than walked past' {
        # install.ps1 exits non-zero when its own $problems list is not empty.
        # A guide that ignored that would step on to "4/6 Session" as though
        # the hook had been written.
        $script:Guide | Should -Match '\$LASTEXITCODE -ne 0'
    }

    It 'install.ps1 says why it cannot be dot-called from the module' {
        # The comment is load-bearing: the Remove-Module line looks harmless
        # and reads as tidy-up.
        $script:Install | Should -Match 'CANNOT BE CALLED IN-PROCESS'
        $script:Install | Should -Match 'Invoke-ZtInstaller'
    }
}
