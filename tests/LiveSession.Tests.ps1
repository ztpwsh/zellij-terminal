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
            $live = & zellij --session $name action dump-layout 2>&1 | Out-String
            $live | Should -Match 'tab name=' -Because 'the live session must report its own tabs'

            $want = [regex]::Match((Get-Content -LiteralPath $deployed -Raw), 'location="file:([^"]+)"')
            if ($want.Success -and (Test-Path -LiteralPath ($want.Groups[1].Value -replace '/', '\'))) {
                $live | Should -Match ([regex]::Escape($want.Groups[1].Value)) -Because (
                    'a session built from this layout carries the status bar pane; its absence, ' +
                    'with the plugin present on disk, is the failure worth catching')
            }
        } finally {
            if ($proc -and -not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit(3000) | Out-Null }
            & zellij delete-session $name --force 2>&1 | Out-Null
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
