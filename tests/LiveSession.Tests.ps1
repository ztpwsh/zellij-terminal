<#
    The installer's live probe: does the config it just wrote actually produce a
    session with the status bar in it?

    WHY A LIVE ONE, WHEN EVERYTHING ELSE READS FILES
      Because the evening this rig lost was spent on a machine where every file
      was right. Layout correct, config correct, plugin binary byte-identical to
      a working machine, permission grant present, `zt check` reporting "No
      failures" on every line - and no status bar, because the session being
      attached to had been built before any of it and Zellij resurrects rather
      than rebuilds. No amount of reading files can see that. Something has to
      ask the running rig.

      Zellij is client/server, and `zellij action` talks to the SERVER over a
      socket rather than through the focused window - the same property the
      macro pad depends on to inject into an unfocused session. So the rig can
      be interrogated with no terminal, no window and no stolen focus:

          zellij -s <name>                              build one from the config
          zellij --session <name> action dump-layout    ask what it is made of
          zellij delete-session <name> --force          and remove it

      dump-layout answers with NO CLIENT ATTACHED, which is what makes this
      usable from an installer. Verified on 0.44.3.

    WHAT WAS TRIED AND DOES NOT WORK
      Dumping the rendered bar and diffing it against a known-good capture.
      `zellij action dump-screen` takes --pane-id and accepts plugin ids, so it
      looks like the answer, and it is not: a plugin pane returns zero bytes.
      Tested across every pane id from 0 to 8, with a client attached; only the
      terminal pane had content. A plugin pane is not a terminal grid, so there
      is no buffer to serialise. The bar's pixels remain unverifiable by
      machine; its PRESENCE does not.

      Also tried: using `zellij pipe`'s documented habit of never returning
      while zjstatus is listening as a liveness probe. It returned in 135 ms on
      a machine with a working bar, so it does not discriminate.

    Skipped where Zellij is absent, so CI reports it as skipped rather than
    failing on a runner that could never run it. That is the one honest
    treatment: this asserts about a live rig and there isn't one there.
#>

# Discovery scope - Pester evaluates -Skip before any BeforeAll runs.
$NoZellij = $null -eq (Get-Command zellij -ErrorAction SilentlyContinue)

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ("zt-live-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

    function Get-ZtSessionNames {
        return @(& zellij list-sessions --no-formatting --short 2>$null |
            ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne '' })
    }
}

AfterAll {
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) {
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'The live probe' -Skip:$NoZellij {

    It 'builds a named session from the deployed config, and removes it again' {
        # THE MECHANISM THE INSTALLER'S PROBE IS MADE OF, against the real
        # deployed config, because it cannot be sandboxed: ZELLIJ IGNORES
        # $env:APPDATA. It resolves the roaming folder through the Windows
        # known-folder API, so redirecting the variable moves where this repo
        # WRITES and not where Zellij READS. Verified by pointing APPDATA at a
        # temp directory and asking `zellij setup --check`, which still reported
        # the real path. A sandboxed version of this test therefore compares a
        # sandbox layout against a session built from the machine's own config,
        # and fails for a reason that has nothing to do with the code.
        #
        # Nothing here writes any config. It starts a session, reads it, and
        # deletes it.
        $deployed = Join-Path $env:APPDATA 'Zellij\config\layouts\claude.kdl'
        if (-not (Test-Path -LiteralPath $deployed)) {
            Set-ItResult -Skipped -Because 'this machine has no deployed claude layout to build from'
            return
        }

        $before = Get-ZtSessionNames
        $name   = 'zt-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $dir    = Join-Path $script:Work $name
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $proc = $null

        try {
            $proc = Start-Process -FilePath (Get-Command zellij).Source -ArgumentList '-s', $name `
                -NoNewWindow -PassThru `
                -RedirectStandardOutput (Join-Path $dir 'o.txt') `
                -RedirectStandardError  (Join-Path $dir 'e.txt')

            $up = $false
            for ($i = 0; $i -lt 20; $i++) {
                Start-Sleep -Milliseconds 500
                if ((Get-ZtSessionNames) -contains $name) { $up = $true; break }
            }
            $up | Should -BeTrue -Because 'a named session must be creatable from default_layout'

            # dump-layout with NO CLIENT ATTACHED - the property that makes this
            # usable from an installer, and the same client/server channel the
            # macro pad uses to reach an unfocused session.
            #
            # POLLED, because BEING LISTED IS NOT BEING BUILT. The loop above
            # waits for the session NAME to appear, which means the server is
            # up; the tabs and the plugin pane are handed over by the client
            # some time afterwards. This test asked once, immediately, and so
            # did the installer it describes - and on the machine this was
            # written on the gap is 3 ms (listed at 233, built at 236), which is
            # not a margin, it is a coin toss with a bias. A second machine
            # reported all three claims failing at once; nothing was wrong with
            # it except that it was slower than three milliseconds.
            $live = ''
            $wait = [System.Diagnostics.Stopwatch]::StartNew()
            while ($wait.ElapsedMilliseconds -lt 15000) {
                $live = & zellij --session $name action dump-layout 2>&1 | Out-String
                if ($live -match 'tab name=') { break }
                Start-Sleep -Milliseconds 250
            }
            $live | Should -Match 'tab name=' -Because (
                "the live session must report its own tabs; waited $($wait.ElapsedMilliseconds) ms")

            $want = [regex]::Match((Get-Content -LiteralPath $deployed -Raw), 'location="file:([^"]+)"')
            if ($want.Success -and (Test-Path -LiteralPath ($want.Groups[1].Value -replace '/', '\'))) {
                $live | Should -Match ([regex]::Escape($want.Groups[1].Value)) -Because (
                    'a session built from this layout carries the status bar pane; its absence, ' +
                    'with the plugin present on disk, is the failure worth catching')
            }
        } finally {
            if ($proc -and -not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit(3000) | Out-Null }
            & zellij delete-session $name --force 2>&1 | Out-Null

            # And the same thing on the way out: the server takes a moment to
            # stop listing a session it has just been told to delete - 105 ms,
            # measured here. Asking once, at zero, reports a clean removal as a
            # leaked session.
            for ($i = 0; $i -lt 30; $i++) {
                if ((Get-ZtSessionNames) -notcontains $name) { break }
                Start-Sleep -Milliseconds 250
            }
        }

        $after = Get-ZtSessionNames
        @($after | Where-Object { $before -notcontains $_ }).Count | Should -Be 0 -Because (
            'a probe that leaks a session leaves a resurrectable corpse behind')
        @($before | Where-Object { $after -notcontains $_ }).Count | Should -Be 0 -Because (
            'and it must never touch a session it did not create')
    }

    It 'names its probe session, rather than letting Zellij name it' {
        # `--layout` cannot be combined with `--session`, so the obvious way to
        # start a session from a layout produces a random name and forces
        # cleanup to be inferred from a before-and-after list. `-s <name>` uses
        # default_layout and takes a name, which makes deletion exact. The
        # earlier random-name approach is why this is worth pinning.
        $install = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'install.ps1') -Raw
        $install | Should -Match ([regex]::Escape("'-s', ") + '\$probeName') -Because (
            'a named session is what makes the cleanup deterministic')
        $install | Should -Match 'delete-session'
    }

    It 'deletes rather than kills, so nothing is left resurrectable' {
        $install = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'install.ps1') -Raw
        $install | Should -Not -Match 'kill-session' -Because (
            'a killed session stays in the list and resurrects on the next attach --create')
    }
}

Describe 'What the probe must never go back to doing' {
    <#
        NOT -Skip. This is the regression guard for a bug that was only ever
        visible on a machine slower than this one, so it has to run on the
        machines that cannot reproduce it - which is every machine that has
        ever run this suite green.

        0.7.15 shipped a probe that waited for the session to be LISTED and
        then judged three separate claims from ONE dump-layout taken
        immediately afterwards. Being listed means the Zellij server is up; the
        client hands over the layout after that, so the tabs and the plugin
        pane arrive later. Here the gap is 3 ms - listed at 233, built at 236 -
        which is why it passed on every machine it was written on.

        On a second machine it lost the race and reported, in one run:

            BAD  a session starts from this config - reported no tabs
            BAD  the session carries the status bar - no plugin pane
            BAD  the probe session was removed - still listed

        Three failures, one cause, on a rig whose `zt check` said No failures
        and whose status bar was rendering. An installer that fails a working
        machine is worse than one that checks nothing, because the person then
        goes looking for a fault that is not there - twice now, after 0.7.13.

        These are source assertions and they are weak on purpose: the property
        is "it retries", and no test on a fast machine can demonstrate a race
        it cannot lose.
    #>

    BeforeAll {
        $script:Install = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1') -Raw
    }

    It 'waits for the claim to become true, rather than sampling once' {
        # dump-layout has to sit inside a bounded wait. Matched on the loop
        # rather than on a comment, so deleting the loop fails this.
        $script:Install | Should -Match '(?ms)while\s*\(\s*\$probeWait\.ElapsedMilliseconds\s*-lt\s*\d+\s*\).*?dump-layout' -Because (
            'listed is not built, and one sample at zero is a coin toss on any slower machine')
    }

    It 'waits for the session to actually go, rather than asking at zero' {
        $script:Install | Should -Match '(?ms)delete-session.*?for\s*\(\$i = 0.*?list-sessions' -Because (
            'the server stops listing a deleted session about 100 ms later, so a single ' +
            'check at zero reports a clean removal as a leak')
    }

    It 'says how long it waited, so a slow machine is visible rather than mysterious' {
        $script:Install | Should -Match '\$probeMs' -Because (
            'a machine that needed four seconds is working, and is also worth knowing about')
    }

    It 'keeps the probe output when the probe failed' {
        # It deleted the temp directory unconditionally, which threw away
        # Zellij's own stderr - the one thing that would have said why - before
        # anyone could read it. The diagnosis that followed was guesswork, and
        # had to be done from a second machine.
        $script:Install | Should -Match 'probe output kept for diagnosis'
        $script:Install | Should -Match '(?ms)if \(\$verified\) \{\s*Remove-Item -LiteralPath \$probeDir'
    }
}
