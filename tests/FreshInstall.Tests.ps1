<#
    A cold install, end to end, on a profile that has never seen this rig.

    WHY THIS FILE EXISTS
      Every other test here reads source or exercises one function. None of them
      answered the only question a stranger asks: if I clone this and run
      install.ps1, do I get a working rig? That gap is not academic - it cost an
      evening. A second PC ran the documented install, every step returned
      without throwing, the installer printed "Done", `zt check` reported "No
      failures" on every line, and there was no status bar. The missing piece
      was a Zellij plugin permission acquired interactively on the development
      machines and carried by nothing that ships.

      The general shape of that bug is the thing to defend against, because the
      specific one is now fixed and the next one will be different: the
      published set can only carry what the manifest can see, and a development
      machine accumulates state that no file records. The only reliable detector
      is to install onto a profile that has none of it and then READ BACK what
      the installer claims to have done.

      So this runs the real install.ps1 against redirected APPDATA and
      LOCALAPPDATA - a profile with no Zellij config, no layout, no plugin, no
      grant, no module - and asserts the installer's own verification pass says
      every file it wrote is correct. On CI, which has no Zellij at all, this is
      as close to a fresh Windows box as a test can get.

    IT EARNED ITS PLACE WITHIN MINUTES
      The first release carrying this file went red on CI, on the installer's
      own new verification step. That step asked whether the module resolved by
      NAME, via Get-Module -ListAvailable, which searches $env:PSModulePath - so
      it reported OK on every development machine, where a ZellijTerminal was
      already on that path from an earlier install, and BAD on a clean runner
      installing to a directory that is not on it. A check passing for a reason
      unrelated to what the installer just did is precisely the failure this
      file exists to catch, and it caught it in its first hour, in the one place
      that could: a machine with none of the state.

    WHAT IT DELIBERATELY DOES NOT ASSERT
      Anything needing a live session: a client attached, a tab open, a rendered
      status bar. Those are false one second after a real install too, and a
      test that demands them would be red on a correct machine - which is how a
      gate rots into a thing people skip.

    Pester 5/6. Nothing outside the temp directory is touched, and no Zellij is
    required: -SkipZellijCheck, and the grant is a statement about a path rather
    than about a file that has to exist.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot

    $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ("zt-fresh-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

    function New-ZtColdProfile {
        <#
            A profile directory with nothing in it. The point of the exercise
            is that NOTHING is pre-seeded - no config, no layout, no plugin, no
            permission grant, no module - so anything the rig needs afterwards
            has to have been put there by install.ps1 itself.
        #>
        $root = Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $app  = Join-Path $root 'Roaming'
        $loc  = Join-Path $root 'Local'
        New-Item -ItemType Directory -Path $app -Force | Out-Null
        New-Item -ItemType Directory -Path $loc -Force | Out-Null
        return [pscustomobject]@{
            Root         = $root
            AppData      = $app
            LocalAppData = $loc
            Layout       = (Join-Path $app 'Zellij\config\layouts\claude.kdl')
            Config       = (Join-Path $app 'Zellij\config\config.kdl')
            Permissions  = (Join-Path $loc 'Zellij\cache\permissions.kdl')
        }
    }

    function Invoke-ZtColdInstall {
        param(
            $Profile_,

            # Extra environment for the child, as name = value. Used to put the
            # installer inside a Zellij session without there being one: ZELLIJ
            # is exactly how Zellij itself tells a child shell that, so setting
            # it is not a stub, it is the same signal from the same variable.
            [hashtable]$WithEnv = @{}
        )

        # -SkipServerCheck because a zellij server on the machine running the
        # suite has nothing to do with this redirected profile, and without it
        # the result would depend on whether the tester happens to have a
        # session open. -SkipHook because the hook writes into the CLONE, which
        # is not redirectable and is not what this file is about.
        $runner = Join-Path $Profile_.Root 'run.ps1'
        $log    = Join-Path $Profile_.Root 'install.log'
        $extra  = (@($WithEnv.Keys | Sort-Object | ForEach-Object {
            "`$env:$_ = '$($WithEnv[$_])'"
        }) -join [Environment]::NewLine)
        Set-Content -LiteralPath $runner -Encoding UTF8 -Value @"
`$env:APPDATA      = '$($Profile_.AppData)'
`$env:LOCALAPPDATA = '$($Profile_.LocalAppData)'
$extra
& '$(Join-Path $script:RepoRoot 'install.ps1')' ``
    -ModulePath '$(Join-Path $Profile_.Root 'Modules')' ``
    -SkipHook -SkipZellijCheck -SkipServerCheck -SkipLiveProbe -Force *> '$log'
exit `$LASTEXITCODE
"@
        & pwsh -NoProfile -File $runner | Out-Null
        $code = $LASTEXITCODE
        return [pscustomobject]@{
            ExitCode = $code
            Log      = (Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue)
        }
    }

    $script:Cold   = New-ZtColdProfile
    $script:Result = Invoke-ZtColdInstall $script:Cold
}

AfterAll {
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) {
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'A cold install' {

    It 'exits 0' {
        # install.ps1 exits non-zero when anything went wrong but did not throw.
        # bootstrap.ps1 reads that code; it printed "keep the clone" after a
        # failed install once because it did not.
        $script:Result.ExitCode | Should -Be 0 -Because $script:Result.Log
    }

    It 'says every file it wrote was read back and is correct' {
        # The installer's own verification pass. Asserting on its conclusion
        # rather than re-deriving it here is deliberate: if that pass is
        # removed or quietly weakened, this goes red, which is the point.
        $script:Result.Log | Should -Match 'read back and is correct'
    }

    It 'reports no BAD claims' {
        $bad = @($script:Result.Log -split "`r?`n" | Where-Object { $_ -match '\bBAD\b' })
        $bad.Count | Should -Be 0 -Because ("the installer flagged: " + ($bad -join ' | '))
    }

    It 'leaves a deployed layout with every marker substituted' {
        # The silent one. An unreplaced {{PLUGINS}} is a file that exists and
        # parses, with no status bar and tabs in the wrong directory, and no
        # error anywhere. docs/05-usage.md has warned about it for months and
        # nothing checked it until the installer's verify pass.
        $script:Cold.Layout | Should -Exist
        $text = Get-Content -LiteralPath $script:Cold.Layout -Raw
        $text | Should -Not -Match '\{\{[A-Z_]+\}\}'
    }

    It 'leaves a config that loads that layout' {
        $script:Cold.Config | Should -Exist
        (Get-Content -LiteralPath $script:Cold.Config -Raw) | Should -Match 'default_layout\s+"claude"'
    }

    It 'grants the plugin the layout names, on a profile that had no grant' {
        # THE ONE THAT WAS MISSING. A cold profile has no permissions.kdl at
        # all, which is exactly the state every machine except a developer's
        # was in. The grant must be keyed by the path the LAYOUT names, because
        # Zellij looks it up by string - the two are computed in different
        # places in install.ps1 and could drift without this.
        $script:Cold.Permissions | Should -Exist

        $layout = Get-Content -LiteralPath $script:Cold.Layout -Raw
        $loc    = [regex]::Match($layout, 'location="file:([^"]+)"')
        $loc.Success | Should -BeTrue -Because 'the layout has to name a plugin for any of this to matter'

        $grant = Get-Content -LiteralPath $script:Cold.Permissions -Raw
        $grant | Should -Match ([regex]::Escape($loc.Groups[1].Value)) -Because (
            'a grant for a different path than the layout names grants nothing, and fails silently')
    }

    It 'does not claim the plugin binary is present, because it does not ship one' {
        # install.ps1 does not download zjstatus, and must not pretend
        # otherwise. A cold profile has no wasm, and the honest outcome is a
        # note rather than either silence or a failure.
        $script:Result.Log | Should -Match 'is not there yet'
        $script:Result.ExitCode | Should -Be 0 -Because 'a missing optional plugin is not a failed install'
    }
}

Describe 'The same install, run from inside Zellij' {
    <#
        THE UPGRADE PATH NOBODY DESIGNED FOR, AND THE ONE EVERYBODY TAKES.

        You are working in the session. You read that a new version exists. You
        paste the one-liner into the pane in front of you. Nesting is not
        blocked - `zellij -s <name>` with ZELLIJ set starts a real session that
        renders its own bar, tested - so the install runs and reports success,
        and three things go wrong that go wrong only here:

          * a Zellij server is running BY DEFINITION, so the permission grant
            defers, every time;
          * the module junction is replaced under a shell that has already
            imported ZellijTerminal, so zt in that window stays the old copy;
          * the printed way out of the first point - delete every session -
            includes the one it is being read in.

        Nothing checked $env:ZELLIJ anywhere in the repo before 0.7.15, which is
        why all three were found by having them happen rather than by reading.

        REPORT, NOT REFUSE. Blocking would break the obvious upgrade path in
        order to protect against a warning, so this asserts on what is SAID and
        on the run still completing. If a later change makes it refuse, the
        exit-code assertion below goes red, which is the intent.

        ZELLIJ is set rather than simulated: it is the variable Zellij itself
        exports into every shell it starts, so this is the same signal from the
        same source, without needing a session to be open on the test machine.
    #>

    BeforeAll {
        $script:Inside = New-ZtColdProfile
        $script:InsideResult = Invoke-ZtColdInstall $script:Inside -WithEnv @{
            ZELLIJ              = '0'
            ZELLIJ_SESSION_NAME = 'claude'
        }
    }

    It 'says so, and names the session it found' {
        $script:InsideResult.Log | Should -Match 'inside Zellij'
        $script:InsideResult.Log | Should -Match "session 'claude'" -Because (
            'ZELLIJ_SESSION_NAME is the only thing that says WHICH session this is')
    }

    It 'names all three consequences that bite only here' {
        $log = $script:InsideResult.Log
        $log | Should -Match 'grant cannot be written'
        $log | Should -Match 'junction'
        $log | Should -Match 'includes this one' -Because (
            'otherwise "delete every session" is an instruction to close this window, unlabelled')
    }

    It 'reports and carries on rather than refusing' {
        # Nesting works. An installer that refused here would be protecting the
        # user from a message.
        $script:InsideResult.ExitCode | Should -Be 0 -Because $script:InsideResult.Log
        $script:Inside.Layout | Should -Exist
    }

    It 'and bootstrap.ps1 says it too, before anything is cloned' {
        # The one-liner is the route that actually reaches this case, and it
        # chooses where to put a clone before install.ps1 gets a say. The
        # earliest moment at which opening a different window is still free is
        # in bootstrap.ps1, not in the installer it hands off to.
        $boot = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'bootstrap.ps1') -Raw
        $boot | Should -Match '\$env:ZELLIJ\b'
        $boot | Should -Match 'inside Zellij'
    }
}
