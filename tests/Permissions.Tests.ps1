<#
    The Zellij plugin permission grant.

    THE FAILURE THIS EXISTS FOR
      A second machine had a correct deployed layout, a zjstatus.wasm
      byte-identical to the one on a machine where the bar worked, a config
      setting `default_layout "claude"`, a hook that was demonstrably firing,
      and `zt check` reporting "No failures" on every single line. There was no
      status bar.

      Zellij gates plugins behind a permission. Ungranted, zjstatus loads and is
      held pending approval, and the prompt renders IN THE PLUGIN'S OWN PANE -
      which the layout declares as `pane size=1 borderless=true`. It renders
      perfectly well, as a single line reading "This plugin asks permission to:
      ... Allow? (y/n)"; a screenshot from the machine this was diagnosed on
      settles that. What it never receives is the KEYPRESS: the session starts
      in locked mode with focus in the terminal pane below, so `y` goes there
      instead. The prompt sits unanswered, reads as a banner rather than a
      question, and the outcome is no bar, no error, and nothing in any log.

      The first version of this file said the dialog could not be drawn at all.
      It was wrong, and it was wrong in eight places, which is its own lesson:
      an explanation invented to fit a symptom will fit it just as well as the
      true one until somebody photographs the screen.

      The grant is acquired interactively, once, and cached in
      %LOCALAPPDATA%\Zellij\cache\permissions.kdl - outside the clone, outside
      %APPDATA%, and named nowhere in the repository. So every development
      machine had one and nothing that ships did, and no test could see the
      difference. That is the whole bug: state the published set could not
      carry, in a place nothing looked.

    WHAT IS PINNED HERE
      The installer writes the grant, merges rather than replaces, and is
      idempotent - and `zt check` then reports PASS. Rather than matching text
      in three files, the cross-check RUNS the writer and then RUNS the reader,
      because the thing that matters is that the reader looks where the writer
      wrote. A check reading a different path from the writer reports a missing
      grant on a machine that has one, which is the same class of failure with
      the sign flipped.

      And it asserts the check can FAIL. The row is worthless if it cannot
      fire, and this whole entry exists because a table of passes described a
      machine that did not work.

    Pester 5/6. Runs install.ps1 in a child pwsh with APPDATA and LOCALAPPDATA
    redirected into a temp directory, so nothing here touches the real ones.
    Green on a machine with no Zellij: -SkipZellijCheck, and the grant is a
    statement about a path rather than about a file that has to exist.
#>

# Discovery scope. Pester evaluates -Skip while discovering, before any
# BeforeAll has run, so this cannot live in setup. The refusal case needs a
# server to refuse for, and a CI runner has no Zellij at all.
$NoZellijServer = @(Get-Process -Name 'zellij' -ErrorAction SilentlyContinue).Count -eq 0

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Install  = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'install.ps1') -Raw
    $script:Check    = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts/Test-Setup.ps1') -Raw
    $script:Diag     = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts/Collect-Diagnostics.ps1') -Raw

    $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ("zt-perm-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

    function New-ZtSandbox {
        <#
            A fresh pair of redirected profile directories. Returned rather
            than shared, so one case cannot see another's leftovers.
        #>
        $root = Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $app  = Join-Path $root 'Roaming'
        $loc  = Join-Path $root 'Local'
        New-Item -ItemType Directory -Path $app -Force | Out-Null
        New-Item -ItemType Directory -Path $loc -Force | Out-Null
        return [pscustomobject]@{
            Root       = $root
            AppData    = $app
            LocalAppData = $loc
            Permissions  = (Join-Path $loc 'Zellij\cache\permissions.kdl')
            PluginKey    = ((Join-Path $app 'Zellij\data\plugins\zjstatus.wasm') -replace '\\', '/')
        }
    }

    function Invoke-ZtInstallInSandbox {
        <#
            install.ps1 in a child pwsh with the two profile variables
            redirected. A child because the variables have to be set for the
            whole run and this session must not inherit them; a file rather
            than -Command because the paths contain backslashes and quoting
            them through two parsers is how a test starts asserting about its
            own escaping.
        #>
        param($Sandbox, [switch]$KeepServerCheck)

        # -SkipServerCheck by default. The installer refuses to write the grant
        # while a zellij process exists, because the server rewrites that file
        # on exit - correct behaviour that would otherwise make this suite pass
        # or fail depending on whether the person running it happens to have a
        # session open. The redirected profile means no running server shares
        # this cache directory, so the refusal is guarding nothing here.
        #
        # The refusal itself is covered below, on a machine that has a server
        # to refuse for.
        $guard = '-SkipServerCheck'
        if ($KeepServerCheck) { $guard = '' }

        $runner = Join-Path $Sandbox.Root 'run.ps1'
        $log    = Join-Path $Sandbox.Root 'install.log'
        Set-Content -LiteralPath $runner -Encoding UTF8 -Value @"
`$env:APPDATA      = '$($Sandbox.AppData)'
`$env:LOCALAPPDATA = '$($Sandbox.LocalAppData)'
& '$(Join-Path $script:RepoRoot 'install.ps1')' ``
    -ModulePath '$(Join-Path $Sandbox.Root 'Modules')' ``
    -SkipHook -SkipZellijCheck -SkipLiveProbe -Force $guard *> '$log'
exit `$LASTEXITCODE
"@
        & pwsh -NoProfile -File $runner | Out-Null
        return $log
    }

    function Invoke-ZtCheckInSandbox {
        <#
            ...and then the reader, in the same redirected environment. The
            point of the pair is that nothing here tells the reader where the
            writer put the file.
        #>
        param($Sandbox)

        $runner = Join-Path $Sandbox.Root 'check.ps1'
        $log    = Join-Path $Sandbox.Root 'check.log'
        Set-Content -LiteralPath $runner -Encoding UTF8 -Value @"
`$env:APPDATA      = '$($Sandbox.AppData)'
`$env:LOCALAPPDATA = '$($Sandbox.LocalAppData)'
& '$(Join-Path $script:RepoRoot 'scripts/Test-Setup.ps1')' *> '$log'
"@
        & pwsh -NoProfile -File $runner | Out-Null
        return (Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue)
    }
}

AfterAll {
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) {
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'The plugin permission grant' {

    Context 'install.ps1 writes it' {

        It 'creates permissions.kdl granting zjstatus the three permissions' {
            $sb = New-ZtSandbox
            Invoke-ZtInstallInSandbox $sb | Out-Null

            $sb.Permissions | Should -Exist -Because (
                'without a grant the plugin loads and waits for a prompt that cannot be shown')

            $text = Get-Content -LiteralPath $sb.Permissions -Raw
            $text | Should -Match ([regex]::Escape($sb.PluginKey)) -Because (
                'the grant is keyed by the plugin path the layout names')

            # The exact three Zellij hands zjstatus. Taken from a file Zellij
            # wrote itself on a machine where the bar works, not from guesswork.
            foreach ($p in @('ReadApplicationState', 'ChangeApplicationState', 'RunCommands')) {
                $text | Should -Match $p
            }
        }

        It 'keys the grant by forward-slash path, which is Zellij''s own form' {
            $sb = New-ZtSandbox
            Invoke-ZtInstallInSandbox $sb | Out-Null

            $text = Get-Content -LiteralPath $sb.Permissions -Raw
            $text | Should -Not -Match ([regex]::Escape('\zjstatus.wasm')) -Because (
                'a backslash key does not match what Zellij looks up, and grants nothing')
        }

        It 'merges rather than replacing, so another plugin keeps its grant' {
            $sb = New-ZtSandbox
            New-Item -ItemType Directory -Path (Split-Path $sb.Permissions -Parent) -Force | Out-Null
            Set-Content -LiteralPath $sb.Permissions -Encoding UTF8 -Value @'
"C:/somewhere/else/other-plugin.wasm" {
    ReadApplicationState
}
'@
            Invoke-ZtInstallInSandbox $sb | Out-Null

            $text = Get-Content -LiteralPath $sb.Permissions -Raw
            $text | Should -Match ([regex]::Escape('other-plugin.wasm')) -Because (
                'this file is Zellij''s and can hold grants a person approved by hand; ' +
                'revoking one silently reproduces this same invisible failure elsewhere')
            $text | Should -Match ([regex]::Escape($sb.PluginKey))
        }

        It 'is idempotent - a second install does not duplicate the entry' {
            $sb = New-ZtSandbox
            Invoke-ZtInstallInSandbox $sb | Out-Null
            Invoke-ZtInstallInSandbox $sb | Out-Null

            $text = Get-Content -LiteralPath $sb.Permissions -Raw
            $hits = @([regex]::Matches($text, [regex]::Escape($sb.PluginKey)))
            $hits.Count | Should -Be 1 -Because 'a re-install re-states the grant, it does not accumulate'
        }
    }

    Context 'zt check reads what install.ps1 wrote' {

        It 'reports the grant as PASS after an install' {
            $sb = New-ZtSandbox
            Invoke-ZtInstallInSandbox $sb | Out-Null
            $out = Invoke-ZtCheckInSandbox $sb

            $out | Should -Match 'zjstatus permitted' -Because 'the row has to exist to be read'
            $out | Should -Match 'zjstatus permitted\s+PASS' -Because (
                'the reader must look where the writer wrote; a path disagreement reports ' +
                'a missing grant on a machine that has one')
        }

        It 'reports FAIL when the grant is missing - the check can actually fire' {
            $sb = New-ZtSandbox
            Invoke-ZtInstallInSandbox $sb | Out-Null
            Remove-Item -LiteralPath $sb.Permissions -Force

            $out = Invoke-ZtCheckInSandbox $sb
            $out | Should -Match 'zjstatus permitted\s+FAIL' -Because (
                'a check that cannot fail is worse than no check - this entry exists ' +
                'because a table of passes described a machine with no status bar')
        }
    }

    Context 'the three files agree about where the grant lives' {

        # Belt and braces over the two cases above, which already prove the
        # agreement by running both halves. These only pin that all three name
        # the file and reach for LOCALAPPDATA, so a future edit that moves one
        # of them to %APPDATA% - the mistake that hid this for months - is
        # caught at the point it is typed rather than on somebody's second PC.
        # Deliberately not matched against an exact Join-Path spelling: that
        # asserts about formatting, and the first draft of this test went red
        # over an argument nesting that changed nothing.

        It 'checks for a running server BEFORE writing, not after' {
            # The order is the whole point. As a warning after the write, the
            # message printed while the file was already on disk and already
            # doomed - it read as advice about next time rather than as a
            # statement that this run had just failed. The server holds its
            # permission state in memory and writes its own copy back on exit.
            #
            # That it rewrites the file is observed, not assumed: the installer
            # writes Read, Change, Run and the file came back Change, Run,
            # Read on the machine this was diagnosed on.
            $procCheck = $script:Install.IndexOf("Get-Process -Name 'zellij'")
            $write     = $script:Install.IndexOf('Set-Content -LiteralPath $permPath')

            $procCheck | Should -BeGreaterThan 0 -Because 'the server check has to exist'
            $write     | Should -BeGreaterThan 0 -Because 'the grant has to be written somewhere'
            $procCheck | Should -BeLessThan $write -Because (
                'checking after the write is a warning about a file that is already doomed')
        }

        It 'refuses to write while a zellij server is running, and says why' -Skip:$NoZellijServer {
            # Only meaningful where there is a server to refuse for. Skipped on
            # CI, which has no Zellij, and on any desktop with no session open -
            # so it is a bonus assertion on the machines that can make it,
            # never a gate that depends on the tester's window layout.
            $sb = New-ZtSandbox
            $log = Invoke-ZtInstallInSandbox $sb -KeepServerCheck
            $text = Get-Content -LiteralPath $log -Raw

            $sb.Permissions | Should -Not -Exist -Because (
                'writing under a live server is undone when that server exits, so not ' +
                'writing is the honest outcome')
            $text | Should -Match 'NOT granted'
            $text | Should -Match 'delete-session' -Because 'a refusal has to name the way out'
        }

        It 'tells you to DELETE the session, never to kill it' {
            # A killed session stays resurrectable and `attach --create`
            # resurrects it without reading the layout, so the grant is never
            # re-evaluated. Every route out of this failure goes through
            # delete-session, and saying "restart your session" sends people
            # round the loop that cost a night.
            $script:Install | Should -Match 'delete-session'
            $script:Check   | Should -Match 'delete-session'
        }

        It 'install.ps1 writes the grant under the Zellij cache directory' {
            $script:Install | Should -Match 'permissions\.kdl'
            $script:Install | Should -Match "'cache'"
            $script:Install | Should -Match 'LOCALAPPDATA'
        }

        It 'Test-Setup.ps1 reads the same place' {
            $script:Check | Should -Match 'permissions\.kdl'
            $script:Check | Should -Match 'LOCALAPPDATA' -Because (
                'the cache is under LOCALAPPDATA, not APPDATA - looking in the wrong one ' +
                'is exactly how this went unseen')
        }

        It 'Collect-Diagnostics.ps1 collects it' {
            $script:Diag | Should -Match 'permissions\.kdl'
            $script:Diag | Should -Match 'LOCALAPPDATA' -Because (
                'the first version of the bundle listed only %APPDATA%\Zellij and stopped ' +
                'one directory short of the answer')
        }
    }
}
