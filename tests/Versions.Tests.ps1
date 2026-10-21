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

Describe 'A Zellij client is never started in the caller''s console' {

    It 'no script or test launches zellij with -NoNewWindow' {
        # A client sets its console to raw mode and a killed one never sets it
        # back, so sharing the user's console left their prompt with no Ctrl+C
        # and mouse reports arriving as typed input - after a clean install.
        $files = @(Get-ChildItem -Path $script:RepoRoot -Recurse -Include '*.ps1', '*.psm1' -File |
            Where-Object { $_.FullName -notmatch '[\\/](spikes|\.git)[\\/]' })
        $hits = @()
        foreach ($f in $files) {
            $t = Get-Content -Raw -LiteralPath $f.FullName
            # One Start-Process call, continuation lines included.
            foreach ($m in [regex]::Matches($t, '(?s)Start-Process\b.*?(?<!`\r?)\n')) {
                if ($m.Value -match 'zellij|zjCmd|\$zj\.Source' -and $m.Value -match '-NoNewWindow') {
                    $hits += $f.Name
                }
            }
        }
        $hits | Should -BeNullOrEmpty
    }
}

Describe 'zt repairs a console something else left broken' {
    # Measured in a hidden console broken by a killed Zellij client: input
    # mode 0x1F7 -> 0x298, mouse tracking 1003/1006 left on (DECRQM). After
    # one `zt help`, 0x1F7 and both off again; the control run stayed broken.

    BeforeAll {
        $mod = Join-Path $script:RepoRoot 'module/ZellijTerminal'
        $script:Core     = Get-Content -Raw (Join-Path $mod 'Private/Core.ps1')
        $script:Dispatch = Get-Content -Raw (Join-Path $mod 'Public/Dispatch.ps1')
        $script:Select   = Get-Content -Raw (Join-Path $mod 'Public/Select.ps1')
    }

    It 'every zt verb resets the console before doing anything' {
        $body = [regex]::Match($script:Dispatch, '(?s)function Invoke-ZellijTerminal \{.*?switch -Regex \(\$Verb\)').Value
        $body | Should -Match 'Reset-ZtConsoleInput'
        $body.IndexOf('Reset-ZtConsoleInput') | Should -BeLessThan $body.IndexOf('if (-not $Verb)') -Because (
            'bare `zt` is the command most likely to be typed into a broken tab')
    }

    It 'the picker drops queued input before reading keys' {
        $body = [regex]::Match($script:Select, '(?s)function Select-ZtItem \{.*?\[Console\]::ReadKey\(').Value
        $body | Should -Match 'Reset-ZtConsoleInput -Flush' -Because (
            'a queued mouse report reads as Escape, then digits that pick an entry nobody chose')
    }

    It 'turns off every mouse tracking mode and encoding, and focus reports' {
        foreach ($m in 1000, 1002, 1003, 1004, 1005, 1006, 1015, 1016) {
            $script:Core | Should -Match ([regex]::Escape("[?$($m)l")) -Because "mode $m"
        }
    }

    It 'restores the default input mode, with VT input off' {
        # 0x298 & ~0x208 | 0x1E7 = 0x1F7, the mode the console started in.
        $script:Core | Should -Match ([regex]::Escape('(m & ~0x208u) | 0x1E7u'))
        ((0x298 -band (-bnot 0x208)) -bor 0x1E7) | Should -Be 0x1F7
    }

    It 'does nothing to a console it is not attached to' {
        # The palette and this suite call zt with output redirected;
        # escape sequences there would land in a log or a JSON stream.
        $script:Core | Should -Match '(?s)function Reset-ZtConsoleInput \{.*?IsOutputRedirected.*?\[Console\]::Write'
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
