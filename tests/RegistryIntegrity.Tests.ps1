<#
    Registry integrity - the repair pass `zt sync` gained in 0.7.22.

    A workspace's identity is Get-ZtKey, the hash of its normalised path. The
    hook writes its live record under the hash of cwd and cannot do anything
    else: it runs under 5.1, off the module path, on the latency path of every
    session start, with no config lookup available to it. So an entry whose
    stored key does not hash from its own path can never be joined to that
    record. It never reaches `running`, `zt restart` cannot resume it, and
    Register-ZtDiscovered - seeing a key it does not recognise - registers the
    folder a second time, splitting one workspace into two.

    Five of 33 entries were in that state on the machine that found it. No
    current code path can write it, which is exactly why detection had to be
    added rather than a write fixed: the failure was silent and nothing looked.

    BEHAVIOURAL, not source-level. This pass mutates a registry, so asserting on
    its text would prove nothing about what it does to one. It runs entirely
    against a redirected config home - $env:ZT_CONFIG_HOME moves the device
    file, the shared file and live\ together - so a run cannot cost you your
    registrations. The first Describe proves that redirection rather than
    trusting it.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'module/ZellijTerminal/ZellijTerminal.psd1') -Force -ErrorAction Stop
    $script:M = Get-Module ZellijTerminal

    $script:RealHome   = $env:ZT_CONFIG_HOME
    $script:RealDevice = $env:ZT_DEVICE

    # Remember the real device file BEFORE redirecting, so AfterAll can prove
    # this file did not touch it. Portability.Tests.ps1 learned that the hard
    # way: its guard hashed a path that had stopped existing and passed for the
    # wrong reason.
    $script:LiveHome = & $script:M { Get-ZtConfigHome }
    $realName        = $script:RealDevice
    if (-not $realName) { $realName = $env:COMPUTERNAME }
    $script:RealDevFile = Join-Path $script:LiveHome (Join-Path 'devices' "$realName.json")
    $script:RealBefore  = if (Test-Path -LiteralPath $script:RealDevFile) {
                              (Get-FileHash -LiteralPath $script:RealDevFile -Algorithm SHA256).Hash
                          } else { 'absent' }

    $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ('zt-integ-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:Work -Force | Out-Null

    $env:ZT_CONFIG_HOME = Join-Path $script:Work 'cfg'
    $env:ZT_DEVICE      = 'zt-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    New-Item -ItemType Directory -Path (Join-Path $env:ZT_CONFIG_HOME 'devices') -Force | Out-Null

    # Two real directories, because the pass resolves a path and hashes it. A
    # path that does not exist is a different case and is covered separately.
    $script:ProjA = Join-Path $script:Work 'projA'
    $script:ProjB = Join-Path $script:Work 'projB'
    New-Item -ItemType Directory -Path $script:ProjA -Force | Out-Null
    New-Item -ItemType Directory -Path $script:ProjB -Force | Out-Null

    $script:KeyA = & $script:M { param($p) Get-ZtKey $p } $script:ProjA
    $script:KeyB = & $script:M { param($p) Get-ZtKey $p } $script:ProjB

    # A session name nothing can be running under, so this never queries the
    # real one. `zt sync` reconciles live Zellij first and that half is not what
    # is under test here.
    $script:DeadSession = 'zt-test-nosuch-session'

    function script:Set-Fixture {
        <#
            The registry as it was found: one healthy entry, one whose key does
            not hash from its path, one duplicate of that same folder carrying
            another wrong key, and one on a root this device does not define.
        #>
        $doc = [pscustomobject]@{
            schema     = 1
            roots      = [pscustomobject]@{}
            workspaces = @(
                [pscustomobject]@{ id = 'good';    key = $script:KeyA;  kind = 'claude'; command = ''; name = ''
                                   root = $null; rel = $null; abs = $script:ProjA; tags = @() }
                [pscustomobject]@{ id = 'orphan';  key = 'deadbeef';    kind = 'claude'; command = ''; name = ''
                                   root = $null; rel = $null; abs = $script:ProjB; tags = @('keepme') }
                [pscustomobject]@{ id = 'dupe';    key = 'cafebabe';    kind = 'claude'; command = ''; name = ''
                                   root = $null; rel = $null; abs = $script:ProjB; tags = @() }
                [pscustomobject]@{ id = 'faraway'; key = '11112222';    kind = 'claude'; command = ''; name = ''
                                   root = 'nosuchroot'; rel = 'thing'; abs = $null; tags = @() }
            )
        }
        & $script:M { param($d) Set-ZtDeviceConfig $d } $doc
    }

    function script:Get-Entries {
        $d = & $script:M { Get-ZtDeviceConfig }
        return @(& $script:M { param($x) Get-ZtProp $x 'workspaces' @() } $d)
    }

    function script:Get-LiveNames {
        # The machine's REAL live directory - ZT_CONFIG_HOME does not move it.
        $dir = & $script:M { Get-ZtLiveDir }
        if (-not (Test-Path -LiteralPath $dir)) { return @() }
        return @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.Name } | Sort-Object)
    }

    $script:LiveBefore = @(script:Get-LiveNames)
}

AfterAll {
    if ($script:RealHome) { $env:ZT_CONFIG_HOME = $script:RealHome }
    else { Remove-Item Env:\ZT_CONFIG_HOME -ErrorAction SilentlyContinue }

    if ($script:RealDevice) { $env:ZT_DEVICE = $script:RealDevice }
    else { Remove-Item Env:\ZT_DEVICE -ErrorAction SilentlyContinue }

    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) {
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'This file cannot touch the real registry' {

    It 'is pointed at a throwaway config home' {
        $env:ZT_CONFIG_HOME | Should -Not -BeNullOrEmpty
        (& $script:M { Get-ZtDevicePath }) | Should -Match ([regex]::Escape($env:ZT_CONFIG_HOME))
        (& $script:M { Get-ZtSharedPath }) | Should -Match ([regex]::Escape($env:ZT_CONFIG_HOME))
    }

    It 'records that ZT_CONFIG_HOME does NOT relocate live records' {
        # Written down because the first draft of this file assumed it did, and
        # asserted so - which would have made the guard below claim a safety it
        # did not have. Get-ZtLiveDir goes to %LOCALAPPDATA%\ZellijTerminal\live
        # unconditionally, on purpose: live records must survive a temp sweep and
        # are per-machine by definition, so there is nothing for a redirected
        # config home to mean. ZT_CONFIG_HOME moves the two config FILES.
        #
        # The consequence for this file is real: Sync-ZellijTerminal calls
        # Remove-ZtLive, so it reaches the machine's actual live directory. The
        # next assertion is what makes that safe rather than assumed.
        (& $script:M { Get-ZtLiveDir }) |
            Should -Not -Match ([regex]::Escape($env:ZT_CONFIG_HOME))
    }

    It 'leaves the real device file byte-identical' {
        $now = if (Test-Path -LiteralPath $script:RealDevFile) {
                   (Get-FileHash -LiteralPath $script:RealDevFile -Algorithm SHA256).Hash
               } else { 'absent' }
        $now | Should -Be $script:RealBefore
    }

}

Describe 'zt sync repairs a drifted registry' {

    BeforeEach { script:Set-Fixture }

    It 'starts from a registry that is genuinely broken' {
        # Otherwise the assertions below could all pass against a fixture that
        # never had the defect in it.
        $before = @(script:Get-Entries)
        $before.Count | Should -Be 4

        $orphan = $before | Where-Object { $_.id -eq 'orphan' }
        $orphan.key | Should -Not -Be $script:KeyB -Because 'this is the condition under test'
    }

    It 're-keys an entry whose key does not hash from its path' {
        & $script:M { param($s) Sync-ZellijTerminal -Session $s -Confirm:$false } $script:DeadSession 6>$null

        $orphan = @(script:Get-Entries) | Where-Object { $_.id -eq 'orphan' }
        $orphan | Should -Not -BeNullOrEmpty
        $orphan.key | Should -Be $script:KeyB
    }

    It 'keeps everything else about a re-keyed entry' {
        # Re-keying is a repair, not a re-registration. Losing the tags or the
        # command while fixing the key would be a worse bug than the one being
        # fixed, and a quieter one.
        & $script:M { param($s) Sync-ZellijTerminal -Session $s -Confirm:$false } $script:DeadSession 6>$null

        $orphan = @(script:Get-Entries) | Where-Object { $_.id -eq 'orphan' }
        $orphan.id   | Should -Be 'orphan'
        $orphan.abs  | Should -Be $script:ProjB
        @($orphan.tags) | Should -Contain 'keepme'
    }

    It 'drops a duplicate that resolves to a path another entry already owns' {
        # The split half. This is what Register-ZtDiscovered creates when it
        # meets a key it does not recognise, and it is why the reporting machine
        # had two joolz-dev rows for one folder.
        & $script:M { param($s) Sync-ZellijTerminal -Session $s -Confirm:$false } $script:DeadSession 6>$null

        $after = @(script:Get-Entries)
        @($after | Where-Object { $_.id -eq 'dupe' }).Count | Should -Be 0
        @($after | Where-Object { $_.abs -eq $script:ProjB }).Count | Should -Be 1
    }

    It 'leaves a healthy entry completely alone' {
        & $script:M { param($s) Sync-ZellijTerminal -Session $s -Confirm:$false } $script:DeadSession 6>$null

        $good = @(script:Get-Entries) | Where-Object { $_.id -eq 'good' }
        $good.key | Should -Be $script:KeyA
        $good.abs | Should -Be $script:ProjA
    }

    It 'does not touch an entry whose path this device cannot resolve' {
        # A root this machine does not define is not a broken key - it is a
        # workspace belonging to another PC, and `zt list` already reports it as
        # unavailable. Re-keying it against a path that does not exist here
        # would break it ON THE OTHER MACHINE, silently, from this one.
        & $script:M { param($s) Sync-ZellijTerminal -Session $s -Confirm:$false } $script:DeadSession 6>$null

        $far = @(script:Get-Entries) | Where-Object { $_.id -eq 'faraway' }
        $far        | Should -Not -BeNullOrEmpty
        $far.key    | Should -Be '11112222'
        $far.root   | Should -Be 'nosuchroot'
    }

    It 'leaves the registry with no mismatch and no duplicate at all' {
        # The property, stated once, rather than four assertions about parts of
        # it. This is what a caller can rely on after a sync.
        & $script:M { param($s) Sync-ZellijTerminal -Session $s -Confirm:$false } $script:DeadSession 6>$null

        $paths = @()
        foreach ($w in (script:Get-Entries)) {
            $p = & $script:M { param($x) Resolve-ZtPath -Workspace $x -DeviceConfig (Get-ZtDeviceConfig) } $w
            if (-not $p) { continue }
            $w.key | Should -Be (& $script:M { param($q) Get-ZtKey $q } $p) -Because "'$($w.id)' must be keyed on its own path"
            $paths += $p.ToLowerInvariant()
        }
        ($paths | Sort-Object -Unique).Count | Should -Be $paths.Count -Because 'one folder is one workspace'
    }

    It 'is idempotent - a second run changes nothing' {
        & $script:M { param($s) Sync-ZellijTerminal -Session $s -Confirm:$false } $script:DeadSession 6>$null
        $once = (@(script:Get-Entries) | ForEach-Object { "$($_.id)=$($_.key)" } | Sort-Object) -join ';'

        & $script:M { param($s) Sync-ZellijTerminal -Session $s -Confirm:$false } $script:DeadSession 6>$null
        $twice = (@(script:Get-Entries) | ForEach-Object { "$($_.id)=$($_.key)" } | Sort-Object) -join ';'

        $twice | Should -Be $once
    }

    It 'writes nothing when there is nothing to repair' {
        # A repair pass that rewrites the file on every run makes every `zt sync`
        # look like a change and buries a real one.
        & $script:M { param($s) Sync-ZellijTerminal -Session $s -Confirm:$false } $script:DeadSession 6>$null

        $f = & $script:M { Get-ZtDevicePath }
        $before = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
        & $script:M { param($s) Sync-ZellijTerminal -Session $s -Confirm:$false } $script:DeadSession 6>$null
        (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash | Should -Be $before
    }

    It 'respects -WhatIf' {
        # This is the one command that deletes a registration without being
        # asked for it by name, so it has to be inspectable before it runs.
        & $script:M { param($s) Sync-ZellijTerminal -Session $s -WhatIf } $script:DeadSession 6>$null *>$null

        $after = @(script:Get-Entries)
        $after.Count | Should -Be 4
        ($after | Where-Object { $_.id -eq 'orphan' }).key | Should -Be 'deadbeef'
    }
}

Describe 'zt rm does not strand an open tab' {

    # The other half of the same afternoon. `zt rm` forgets the project and
    # leaves the tab; `zt close` closes the tab and keeps the project. They are
    # easy to reach for interchangeably, and in this order the tab used to be
    # left with nothing able to address it.
    #
    # Whether the WARNING fires needs a live session with a real tab open, which
    # no offline suite can produce - `zt check` is where that gets exercised. So
    # what is pinned here is the part that can be: the affordance exists, and
    # the message names the command that actually helps.

    It 'offers to close the tab in the same breath' {
        $cmd = Get-Command Unregister-ZellijTerminal -Module ZellijTerminal
        $cmd.Parameters.Keys | Should -Contain 'CloseTab'
    }

    It 'names zt close rather than leaving you to guess' {
        $p = Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Registry.ps1'
        $body = [regex]::Match((Get-Content -LiteralPath $p -Raw),
                    'function Unregister-ZellijTerminal[\s\S]*?\n\}\r?\n').Value
        $body | Should -Not -BeNullOrEmpty
        $body | Should -Match 'zt close'
        $body | Should -Match 'Write-Warning'
    }

    It 'closes the tab before dropping the registration, not after' {
        # Order is the whole bug. Remove-ZellijTerminalTab resolves its target
        # through the record list, so once the entry is gone it can no longer
        # find the tab it was asked to close.
        $p = Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Registry.ps1'
        $body = [regex]::Match((Get-Content -LiteralPath $p -Raw),
                    'function Unregister-ZellijTerminal[\s\S]*?\n\}\r?\n').Value

        $close = $body.IndexOf('Remove-ZellijTerminalTab')
        $write = $body.IndexOf('Set-ZtDeviceConfig')
        $close | Should -BeGreaterThan 0
        $write | Should -BeGreaterThan 0
        $close | Should -BeLessThan $write -Because 'the tab must be closed while the workspace is still findable'
    }
}

Describe 'And it left the machine alone' {

    # LAST IN THE FILE ON PURPOSE. Pester runs Describes in file order, so this
    # has to sit below the one that calls Sync-ZellijTerminal or it would be
    # asserting against a run that had not happened yet - passing for exactly
    # the reason it exists to rule out.

    It 'leaves the real live directory exactly as it found it' {
        # Sync-ZellijTerminal calls Remove-ZtLive, and live\ is NOT redirected
        # by ZT_CONFIG_HOME. The fixture keys are hashes of paths inside a GUID
        # temp directory, so nothing here can name a real record - but "cannot"
        # is the claim, and this is the check.
        (@(script:Get-LiveNames) -join ';') | Should -Be ($script:LiveBefore -join ';')
    }

    It 'still leaves the real device file byte-identical' {
        $now = if (Test-Path -LiteralPath $script:RealDevFile) {
                   (Get-FileHash -LiteralPath $script:RealDevFile -Algorithm SHA256).Hash
               } else { 'absent' }
        $now | Should -Be $script:RealBefore
    }
}
