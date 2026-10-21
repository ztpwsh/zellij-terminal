<#
    The zjstatus pin, and the versions zt reports on.

    install.ps1 downloads one exact zjstatus build and refuses any download
    whose hash differs. scripts\Test-Setup.ps1 (`zt check`) reports whether the
    installed plugin IS that build. Two copies of one fact, because the check
    runs under Windows PowerShell 5.1 and must not read the installer to learn
    it. If they drift, the installer fetches one build and the check calls it
    the wrong one - a WARN on every machine, correct ones included.

    Nothing here touches the network: both scripts take an opt-out, and the
    runners that execute them pass it.
#>

BeforeAll {
    $script:RepoRoot  = Split-Path -Parent $PSScriptRoot
    $script:Install   = Get-Content -Raw (Join-Path $script:RepoRoot 'install.ps1')
    $script:TestSetup = Get-Content -Raw (Join-Path $script:RepoRoot 'scripts/Test-Setup.ps1')

    function Get-Pin {
        param([string]$Text, [string]$Name)
        $m = [regex]::Match($Text, '(?m)^\$' + $Name + "\s*=\s*'([^']+)'")
        if ($m.Success) { return $m.Groups[1].Value }
        return $null
    }
}

Describe 'The zjstatus pin' {

    It 'is written in both scripts' {
        Get-Pin $script:Install   'ZjstatusVersion' | Should -Not -BeNullOrEmpty
        Get-Pin $script:Install   'ZjstatusSha256'  | Should -Not -BeNullOrEmpty
        Get-Pin $script:TestSetup 'ZjstatusVersion' | Should -Not -BeNullOrEmpty
        Get-Pin $script:TestSetup 'ZjstatusSha256'  | Should -Not -BeNullOrEmpty
    }

    It 'names the same build in both' {
        Get-Pin $script:TestSetup 'ZjstatusVersion' | Should -Be (Get-Pin $script:Install 'ZjstatusVersion')
        Get-Pin $script:TestSetup 'ZjstatusSha256'  | Should -Be (Get-Pin $script:Install 'ZjstatusSha256')
    }

    It 'is a whole SHA-256, in the case Get-FileHash returns' {
        # -eq on strings is case-insensitive in PowerShell, but a truncated or
        # pasted-with-a-space hash would never match anything, and that reads
        # as "the download was tampered with" on every machine.
        Get-Pin $script:Install 'ZjstatusSha256' | Should -MatchExactly '^[0-9A-F]{64}$'
    }

    It 'is downloaded by the version it names, not by "latest"' {
        # A floating URL would install whatever was released last night and
        # then fail its own hash check - or, worse, pass it if both moved.
        $script:Install | Should -Match 'releases/download/v\$ZjstatusVersion/zjstatus\.wasm'
        $script:Install | Should -Not -Match 'zjstatus/releases/latest'
    }

    It 'is checked before the downloaded file is moved into place' {
        $hashAt = $script:Install.IndexOf('if ($got -ne $ZjstatusSha256)')
        $moveAt = $script:Install.IndexOf('Move-Item -LiteralPath $wasmTmp')
        $hashAt | Should -BeGreaterThan 0
        $moveAt | Should -BeGreaterThan $hashAt
    }
}

Describe 'The suite stays off the network' {

    It 'installer runners skip the plugin download' {
        foreach ($f in 'FreshInstall.Tests.ps1', 'Permissions.Tests.ps1') {
            $t = Get-Content -Raw (Join-Path $PSScriptRoot $f)
            $t | Should -Match '-SkipPluginDownload' -Because "$f runs install.ps1"
        }
    }

    It 'zt check runners pass -Offline' {
        $t = Get-Content -Raw (Join-Path $PSScriptRoot 'Permissions.Tests.ps1')
        $t | Should -Match "Test-Setup\.ps1'\)' -Offline"
    }
}

Describe 'zt check reports versions without changing them' {

    It 'never runs an upgrade' {
        # Saying "behind" is the whole job. A new Zellij has changed behaviour
        # on this rig before; upgrading it belongs to the person reading the
        # release notes.
        $script:TestSetup | Should -Not -Match '(?m)^\s*&?\s*winget\s+(upgrade|install)'
        $script:TestSetup | Should -Not -Match 'Invoke-WebRequest'
    }
}
