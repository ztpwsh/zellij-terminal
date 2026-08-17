<#
    Live records, and why SessionEnd is not allowed to be load-bearing.

    The hook's SessionEnd branch is pure cleanup: it deletes the live record, the
    waiting flag, the status entry and the tab cache, and clears the tab glyph.
    All five leak when it does not run - and it frequently does not, because
    Claude Code cancels hooks that have not finished by the time it exits:

        SessionEnd hook [...] failed: Hook cancelled

    That fires for every registered hook, not just this one, and powershell.exe
    alone takes ~500 ms to start, so losing the race is normal. Before the pid
    was recorded, a leaked record was indistinguishable from a live one: `zt`
    listed a dead session as running, and Register-ZellijTerminal's auto-adopt
    would register the folder it pointed at.

    The rule lives in two languages, because the Command Palette reads these
    files directly and must not answer differently from `zt`. That pairing is
    what most of this file is about.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'module/ZellijTerminal/ZellijTerminal.psd1') -Force -ErrorAction SilentlyContinue
    $script:M = Get-Module ZellijTerminal

    $script:Core    = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'module/ZellijTerminal/Private/Core.ps1') -Raw
    $script:Hook    = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'hooks/claude-zj-hook.ps1') -Raw
    $script:ZtStore = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'cmdpal/ZellijTerminal.Palette/ZtStore.cs') -Raw

    # A pid that is genuinely gone, rather than a large number guessed to be
    # free. Guessing is how this kind of test passes locally and fails on the
    # one machine where the number happened to be in use.
    $script:DeadPid = (Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'exit' -PassThru -WindowStyle Hidden).Id
    Start-Sleep -Milliseconds 300
}

Describe 'Deciding whether a record is alive' {

    It 'treats a record with no pid as alive' {
        # Set-ZtLive writes these: zt starts a command inside a Zellij pane and
        # never learns its pid. Absence of evidence is not evidence of death,
        # and guessing dead here would delete a running workspace's record.
        $rec = [pscustomobject]@{ key = 'a'; startedAt = (Get-Date).ToString('o') }
        (& $script:M { param($r) Test-ZtLiveRecordAlive $r } $rec) | Should -BeTrue
    }

    # Not -ForEach @{ Pid = ... }: Pester binds each key as a variable, and $PID
    # is a read-only automatic. The failure is a confusing
    # "Cannot overwrite variable PID" from inside the test framework.
    It 'treats an empty or unparseable pid as alive: <Label>' -ForEach @(
        @{ Label = 'empty string';  Raw = '' }
        @{ Label = 'null';          Raw = $null }
        @{ Label = 'not a number';  Raw = 'not-a-number' }
        @{ Label = 'zero';          Raw = '0' }
    ) {
        $rec = [pscustomobject]@{ key = 'a'; pid = $Raw; startedAt = (Get-Date).ToString('o') }
        (& $script:M { param($r) Test-ZtLiveRecordAlive $r } $rec) | Should -BeTrue
    }

    It 'treats a running pid as alive' {
        $rec = [pscustomobject]@{ key = 'a'; pid = "$PID"; startedAt = (Get-Date).ToString('o') }
        (& $script:M { param($r) Test-ZtLiveRecordAlive $r } $rec) | Should -BeTrue
    }

    It 'treats a pid that is gone as dead' {
        $rec = [pscustomobject]@{ key = 'a'; pid = "$($script:DeadPid)"; startedAt = (Get-Date).ToString('o') }
        (& $script:M { param($r) Test-ZtLiveRecordAlive $r } $rec) | Should -BeFalse
    }

    It 'treats a REUSED pid as dead, not as our session' {
        # The record claims to have been written in 2001, so the process holding
        # that pid today cannot be the one that wrote it. Without this guard a
        # leaked record is kept alive indefinitely by a stranger who happened to
        # inherit the number.
        $rec = [pscustomobject]@{ key = 'a'; pid = "$PID"; startedAt = '2001-01-01T00:00:00.0000000+00:00' }
        (& $script:M { param($r) Test-ZtLiveRecordAlive $r } $rec) | Should -BeFalse
    }

    It 'accepts a pid written as a number as well as a string' {
        # The hook writes a string; nothing stops a future writer emitting a
        # number, and reading only one shape would treat the other as immortal.
        $rec = [pscustomobject]@{ key = 'a'; pid = $script:DeadPid; startedAt = (Get-Date).ToString('o') }
        (& $script:M { param($r) Test-ZtLiveRecordAlive $r } $rec) | Should -BeFalse
    }
}

Describe 'Get-ZtLive keeps dead records, because restore is built on them' {

    BeforeAll {
        $script:OldLocal = $env:LOCALAPPDATA
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ("zt-live-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path (Join-Path $script:Work 'ZellijTerminal\live') -Force | Out-Null
        $env:LOCALAPPDATA = $script:Work

        $live = Join-Path $script:Work 'ZellijTerminal\live'
        @{ key = 'alive'; cwd = 'C:\one'; pid = "$PID";               startedAt = (Get-Date).ToString('o') } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $live 'alive.json') -Encoding UTF8
        @{ key = 'dead';  cwd = 'C:\two'; pid = "$($script:DeadPid)"; startedAt = (Get-Date).ToString('o') } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $live 'dead.json') -Encoding UTF8
        @{ key = 'nopid'; cwd = 'C:\three';                           startedAt = (Get-Date).ToString('o') } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $live 'nopid.json') -Encoding UTF8

        $script:Got = @(& $script:M { Get-ZtLive })
    }

    AfterAll {
        $env:LOCALAPPDATA = $script:OldLocal
        if ($script:Work -and (Test-Path -LiteralPath $script:Work)) {
            Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns every record, dead ones included' {
        # THE REGRESSION THIS BLOCKS. Filtering dead records out here looks like
        # tidying up, and silently guts `zt restore`: its whole input is records
        # left behind by sessions that never got to say goodbye, which by
        # definition have a dead pid. See Resume-ZellijTerminal.
        @($script:Got | ForEach-Object { $_.key } | Sort-Object) | Should -Be @('alive', 'dead', 'nopid')
    }

    It 'deletes nothing' {
        # Removal is `zt sync`'s job, and only there, so that a crash recovery is
        # never thrown away by something the user did not ask for.
        foreach ($n in @('alive', 'dead', 'nopid')) {
            (Test-Path -LiteralPath (Join-Path $script:Work "ZellijTerminal\live\$n.json")) | Should -BeTrue
        }
    }
}

Describe 'A dead session reads as stale, not running' {

    # The state ladder is what everything user-facing reads, and the pid only
    # matters because it feeds this decision.

    It 'requires the process to be alive before calling anything running' {
        # Record present AND tab present used to be sufficient. The tab survives
        # the session - the pane drops back to a shell - so a cancelled
        # SessionEnd left a dead session reading 'running' indefinitely, and
        # `zt go` would jump to it.
        $script:Core | Should -Match '\$hasTab -and \$rec -and \$recAlive.*running'
        $script:Core | Should -Match '\$hasTab -and \$rec\b.*stale'
    }

    It 'the palette applies the same ladder' {
        $script:ZtStore | Should -Match 'hasTab && liveAlive \? "running"'
        $script:ZtStore | Should -Match 'hasTab && live is not null \? "stale"'
    }

    It 'zt sync is what actually removes them, and says so' {
        $sync = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Control.ps1') -Raw
        $sync | Should -Match "Where-Object \{ \`$_\.State -eq 'stale' \}"
    }
}

Describe 'The hook records the pid' {

    It 'writes CLAUDE_PID into the live record' {
        # Free: Claude Code sets CLAUDE_PID in the environment of everything it
        # spawns, and it is the pid of the claude process itself. Deriving it any
        # other way - a CIM parent-process query - would put ~200 ms on the
        # latency path of every hook event.
        $script:Hook | Should -Match 'pid\s*=\s*\$env:CLAUDE_PID'
    }

    It 'still deletes the record on SessionEnd' {
        # The pid makes SessionEnd optional, not pointless: when it does run it
        # is instant and exact, and nothing has to wait for a process to die.
        $script:Hook | Should -Match "if \(\`$hookEvent -eq 'SessionEnd'\) \{\s*Remove-Item"
    }
}

Describe 'The rule is written in two languages and must not drift' {

    It 'both name the pid field and the startedAt guard' {
        $script:Core    | Should -Match "'pid'"
        $script:Core    | Should -Match "'startedAt'"
        $script:ZtStore | Should -Match '"pid"'
        $script:ZtStore | Should -Match '"startedAt"'
    }

    It 'both allow the same one second of slack against the recorded start' {
        # Different slack in the two readers is the drift that would matter: the
        # palette would call a session dead while zt called it running, on the
        # same file, with no way to tell which was right.
        $script:Core    | Should -Match 'AddSeconds\(1\)'
        $script:ZtStore | Should -Match 'AddSeconds\(1\)'
    }

    It 'both treat a missing pid as ALIVE' {
        # The inversion that would matter most. Treating "no pid" as dead would
        # delete every record zt itself wrote, i.e. every pwsh workspace.
        $script:Core    | Should -Match 'if \(-not \$recPid\) \{ return \$true \}'
        $script:ZtStore | Should -Match 'if \(raw\.Length == 0\) return true;'
    }

    It 'the palette never deletes a record' {
        # It is a reader. Writes go through zt, so the rules about what may be
        # removed live in one place - and a palette that pruned records would
        # destroy a crash recovery merely by being open.
        $script:ZtStore | Should -Match 'IsLiveRecordAlive\(live\)'
        $script:ZtStore | Should -Not -Match 'File\.Delete'
    }

    It 'each points at the other by name, so the pair is discoverable' {
        $script:Core    | Should -Match 'ZtStore\.cs'
        $script:ZtStore | Should -Match 'Test-ZtLiveRecordAlive'
    }
}
