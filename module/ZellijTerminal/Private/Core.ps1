<#
    Core - paths, storage, identity, and talking to Zellij.

    THE STORAGE MODEL, BECAUSE EVERYTHING ELSE FOLLOWS FROM IT

    Three stores, with three different lifecycles. Conflating them is what makes
    tools like this rot:

      config\workspaces.json          shared, in git. What you want on EVERY
                                      machine. Edited rarely, by you. Source:
                                      it ships with the clone.

      %LOCALAPPDATA%\ZellijTerminal\devices\<HOST>.json
                                      per-device, NOT in git. This machine's
                                      root paths, plus whatever was discovered
                                      here. ONLY THIS MACHINE EVER WRITES THIS
                                      FILE - which is what makes automatic
                                      registration safe across several PCs. Two
                                      machines cannot conflict because they
                                      never touch the same file.

                                      It lives outside the clone because it is
                                      state, not source, and state in a working
                                      tree dies to `git clean -xfd`, to a
                                      re-clone, or to a folder move. Set
                                      $env:ZT_CONFIG_HOME to <clone>\config to
                                      put it back in the repo and share it
                                      between PCs - which only a PRIVATE repo
                                      should ever do, since the file names your
                                      machines and drive layout.

      %LOCALAPPDATA%\ZellijTerminal\live\<key>.json
                                      never in git. One file per live session,
                                      written by the hook. A DIRECTORY of small
                                      files, not one JSON: several tabs write
                                      concurrently and a single shared document
                                      would need locking to survive that. The
                                      existing flag files already work this way.

    Paths are stored as {root, rel} - a named root plus a relative path - not as
    absolutes. Each device maps root names to its own drive letters, so the
    shared config is portable and a workspace whose root is undefined here is
    simply not available here. That is the whole of "only show me what this
    device can attach to"; it falls out of the schema instead of needing a
    filter. Absolutes are still allowed for one-offs, and are device-only by
    definition.

    THE REGISTRY IS A CACHE, NEVER THE TRUTH. Live truth is `zellij
    query-tab-names` and the flag files. A terminal killed with the X button
    leaves records behind, so everything reconciles on read and reports stale
    rather than lying.

    Windows PowerShell 5.1 compatible - no ternary, no ??, no && / ||.
#>

$script:ZtSchemaVersion = 1

# ---------------------------------------------------------------------------
#  Where things are
# ---------------------------------------------------------------------------

$script:ZtRoot = $null

function Get-ZtReparseTarget {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $null }

    # PowerShell 7 exposes LinkTarget (string); 5.1 exposes Target (string[]).
    $props = $item.PSObject.Properties.Name
    if (($props -contains 'LinkTarget') -and $item.LinkTarget) { return $item.LinkTarget }
    if (($props -contains 'Target') -and $item.Target) { return @($item.Target)[0] }
    return $null
}

function Remove-ZtLink {
    <#
        Delete a directory junction, and only the junction.

        DirectoryInfo.Delete() is the obvious way and it fails here with access
        denied - a junction reports the target's contents, so it does not look
        empty. `rmdir` on a junction removes the link and never follows it,
        which is exactly the guarantee needed: the target is the repo. Verify
        afterwards, because the whole point is not to claim a removal that did
        not happen.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    try { (Get-Item -LiteralPath $Path -Force).Delete() } catch { }
    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    & cmd.exe /c rmdir "$Path" 2>&1 | Out-Null
    return (-not (Test-Path -LiteralPath $Path))
}

function Test-ZtRoot {
    param([string]$Path)
    if (-not $Path) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Path (Join-Path 'scripts' 'zj-claude-project.ps1')))
}

function Get-ZtRootMarkerPath {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = $env:TEMP }
    return (Join-Path $base (Join-Path 'ZellijTerminal' 'root.txt'))
}

function Set-ZtRootMarker {
    <#
        Record where the repo is, for consumers that cannot deduce it.

        The module finds the repo by walking up from its own location, which
        works because it is junctioned there. The Command Palette extension
        cannot: it is installed into Program Files\WindowsApps and walking up
        from there finds nothing. So the module leaves a note.

        Written only when it would change, so this costs one file read per
        session rather than a write.
    #>
    param([string]$Path)

    $marker = Get-ZtRootMarkerPath
    $current = $null
    if (Test-Path -LiteralPath $marker) {
        $current = (Get-Content -LiteralPath $marker -Raw -ErrorAction SilentlyContinue)
        if ($current) { $current = $current.Trim() }
    }
    if ($current -eq $Path) { return }

    $dir = Split-Path $marker -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -LiteralPath $marker -Value $Path -Encoding UTF8
}

function Get-ZtRoot {
    <#
        The repo. Installed as a junction, and Windows resolves paths by string,
        so $PSScriptRoot inside the junction is the junction's own path - walking
        up from it lands in Documents\PowerShell, not in the repo. Follow the
        reparse point first.
    #>
    if ($script:ZtRoot) { return $script:ZtRoot }

    if ($env:ZT_ROOT -and (Test-ZtRoot $env:ZT_ROOT)) {
        $script:ZtRoot = (Resolve-Path -LiteralPath $env:ZT_ROOT).Path
        return $script:ZtRoot
    }

    $start  = Split-Path $PSScriptRoot -Parent      # ...\module\ZellijTerminal
    $target = Get-ZtReparseTarget $start
    if ($target) { $start = $target }

    $dir = $start
    while ($dir) {
        if (Test-ZtRoot $dir) {
            $script:ZtRoot = $dir
            Set-ZtRootMarker $dir
            return $script:ZtRoot
        }
        $parent = Split-Path $dir -Parent
        if ($parent -eq $dir) { break }
        $dir = $parent
    }

    throw ("ZellijTerminal cannot find the rig. Looked upward from '$start'. If the module " +
           "was copied rather than junctioned, set `$env:ZT_ROOT to the clone.")
}

function Get-ZtScript {
    param([Parameter(Mandatory = $true)][string]$Name)
    $path = Join-Path (Get-ZtRoot) (Join-Path 'scripts' $Name)
    if (-not (Test-Path -LiteralPath $path)) { throw "ZellijTerminal: script not found: $path" }
    return $path
}

function Get-ZtDeviceName {
    if ($env:ZT_DEVICE) { return $env:ZT_DEVICE }
    return $env:COMPUTERNAME
}

function Get-ZtConfigHome {
    <#
        Where THIS DEVICE's registry lives. $env:ZT_CONFIG_HOME wins; otherwise
        %LOCALAPPDATA%\ZellijTerminal, alongside live\ and root.txt.

        NOT THE CLONE, and the reason is the scope mismatch. The device file
        describes the machine - every root and every workspace on it - while a
        clone is one checkout of the code that happens to be sitting there.
        Storing machine state at repo scope means `git clean -xfd` deletes it,
        a re-clone loses it, and two clones give two registries with nothing
        saying which one is being read. It is gitignored in a public checkout,
        which is the tell: a file the tool writes and git is told to ignore is
        state, not source.

        This is not hypothetical. The rig was installed here from the release
        worktree, and Publish-Release.ps1 empties that directory on every run -
        ignored files included - so the registry was one publish away from
        vanishing with no diff and no gate message to notice it by.

        Set ZT_CONFIG_HOME to <clone>\config for the old layout. That is how
        several PCs share one registry through a PRIVATE repo, and it stays
        supported - as a deliberate opt-in, because it is only safe when you
        know the directory is not disposable.
    #>
    if ($env:ZT_CONFIG_HOME) { return $env:ZT_CONFIG_HOME }

    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = $env:TEMP }
    return (Join-Path $base 'ZellijTerminal')
}

function Get-ZtConfigDir  { return (Join-Path (Get-ZtRoot) 'config') }

function Get-ZtSharedPath {
    # workspaces.json is committed content that ships with the clone, so it
    # stays there by default - it is source, and the two files are genuinely
    # different in kind. An explicit ZT_CONFIG_HOME moves BOTH, because a
    # registry split across two locations is worse than either one alone.
    if ($env:ZT_CONFIG_HOME) { return (Join-Path $env:ZT_CONFIG_HOME 'workspaces.json') }
    return (Join-Path (Get-ZtConfigDir) 'workspaces.json')
}

function Get-ZtDevicePath {
    return (Join-Path (Join-Path (Get-ZtConfigHome) 'devices') ((Get-ZtDeviceName) + '.json'))
}

function Get-ZtLiveDir {
    # Not %TEMP%: live records should survive a temp sweep, and this is the
    # device store the whole design leans on. Transient waiting flags stay in
    # %TEMP% where the hook and the jump script already expect them.
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = $env:TEMP }
    return (Join-Path $base (Join-Path 'ZellijTerminal' 'live'))
}

# ---------------------------------------------------------------------------
#  JSON in and out
# ---------------------------------------------------------------------------

function Read-ZtJson {
    param([string]$Path, $Default = $null)

    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if (-not $raw -or -not $raw.Trim()) { return $Default }
        return ($raw | ConvertFrom-Json)
    } catch {
        Write-Warning "Unreadable JSON at $Path - $($_.Exception.Message)"
        return $Default
    }
}

function Write-ZtJson {
    param([string]$Path, $Object)

    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Write beside the target then move over it, so an interrupted write cannot
    # leave a half-file where a config used to be. Move-Item -Force is atomic
    # enough within one volume for this purpose.
    $tmp  = "$Path.tmp"
    $json = $Object | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Format-ZtAge {
    <#
        "3h 12m" rather than a timestamp. The question this answers is "have I
        forgotten about this?", and a duration answers it at a glance where an
        ISO date does not.
    #>
    param($From)

    if (-not $From) { return '' }
    $t = $null
    try { $t = [datetime]$From } catch { return '' }

    $span = (Get-Date) - $t
    if ($span.TotalMinutes -lt 1)  { return 'just now' }
    if ($span.TotalHours   -lt 1)  { return ('{0}m' -f [int]$span.TotalMinutes) }
    if ($span.TotalDays    -lt 1)  { return ('{0}h {1}m' -f [int]$span.TotalHours, $span.Minutes) }
    return ('{0}d {1}h' -f [int]$span.TotalDays, $span.Hours)
}

function Get-ZtProp {
    <#
        Reading an absent property throws under Set-StrictMode, and every one of
        these objects came from JSON that may predate a field.
    #>
    param($Object, [string]$Name, $Default = $null)

    if ($null -eq $Object) { return $Default }

    # An object with NO properties - `{}` out of JSON, which is exactly what an
    # untouched `roots` is - has a Properties collection that is empty, and
    # reading .Name off it throws under Set-StrictMode 2.0 rather than returning
    # nothing. The guard this function exists to provide was itself unguarded
    # for the empty case. Surfaced by importing a bundle onto a device with no
    # roots defined, which is the ordinary state of a new machine.
    $names = @()
    try { $names = @($Object.PSObject.Properties | ForEach-Object { $_.Name }) } catch { return $Default }
    if ($names -notcontains $Name) { return $Default }

    $v = $Object.$Name
    if ($null -eq $v) { return $Default }
    return $v
}

# ---------------------------------------------------------------------------
#  Identity
# ---------------------------------------------------------------------------

function Get-ZtKey {
    <#
        A workspace's stable identity is its directory, not its name: renaming a
        tab must not orphan its records, and two folders called 'api' are two
        workspaces. The key is a hash of the normalised path, which matters for
        one specific reason - the HOOK has to compute it with no config lookup
        and no state, on every session start, under 5.1.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $norm = $Path.TrimEnd('\', '/').ToLowerInvariant() -replace '/', '\'
    $sha  = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($norm))
    } finally {
        $sha.Dispose()
    }
    $hex = ''
    foreach ($b in $bytes[0..3]) { $hex += $b.ToString('x2') }
    return $hex
}

function New-ZtId {
    <#
        The friendly handle you type: `zt start api`. Derived from the leaf
        folder, uniquified against ids already in use, because a duplicate id
        would make every other command ambiguous.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Taken = @()
    )

    $leaf = Split-Path $Path -Leaf
    $slug = ($leaf -replace '[^A-Za-z0-9._-]', '-').Trim('-').ToLowerInvariant()
    if (-not $slug) { $slug = 'workspace' }

    if ($Taken -notcontains $slug) { return $slug }

    # Same leaf in two places. Disambiguate with the parent folder before
    # falling back to the key, because 'api' vs 'web-api' reads better than
    # 'api-3f9c1a20'.
    $parent = Split-Path (Split-Path $Path -Parent) -Leaf
    if ($parent) {
        $withParent = (($parent -replace '[^A-Za-z0-9._-]', '-').Trim('-') + '-' + $slug).ToLowerInvariant()
        if ($Taken -notcontains $withParent) { return $withParent }
    }
    return ($slug + '-' + (Get-ZtKey $Path))
}

function Get-ZtTabName {
    <#
        Tab names must agree with what the hook derives from cwd and what
        zj-claude-tab.ps1 cycles, or the pad jumps to tabs that do not exist.
        Default is the historic <prefix><leaf>; an explicit name on the
        workspace wins, which is how two folders called 'api' stop fighting
        over one tab name.
    #>
    param($Workspace, [string]$Path, [string]$Prefix = 'claude-')

    $explicit = Get-ZtProp $Workspace 'name'
    if ($explicit) { return $explicit }
    return ($Prefix + (Split-Path $Path -Leaf))
}

function Get-ZtTerminalProfilePaths {
    <#
        EVERY Windows Terminal settings.json on this machine, in preference
        order: Store, Preview, unpackaged.

        One list, because there were three. Two other readers carried their own
        two-entry copies that omitted the unpackaged path, so a Scoop or
        portable Terminal - which keeps its settings ONLY there - was invisible
        to them while this function found it. The test that was supposed to pin
        the three together grepped the whole FILE, so the copies satisfied it
        from this function's list and the drift was undetectable.
    #>
    return @(
        @(
            (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
            (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
        ) | Where-Object { Test-Path -LiteralPath $_ }
    )
}

function Get-ZtTerminalProfilePath {
    <#
        The first settings.json that exists, or $null. A machine may have more
        than one; callers that must read them all use the plural above.
    #>
    $all = @(Get-ZtTerminalProfilePaths)
    if ($all.Count -gt 0) { return $all[0] }
    return $null
}

function Get-ZtWtWindowPreference {
    <#
        Terminal's firstWindowPreference, or $null when there is nothing to read.

        "persistedWindowLayout" restores the saved layout when the FIRST window
        opens, and on this rig that saved layout is a window already running
        `zellij attach` - so a cold zac ends up with two clients on one session,
        mirrored, with the grid pinned to the smaller. Nothing downstream can
        tell those two windows apart, so the setting is the only place to catch
        it.

        Read as TEXT, not JSON: settings.json is JSONC and ConvertFrom-Json
        refuses it under Windows PowerShell 5.1.

        Full-line comments are dropped first. Terminal writes its own defaults
        out commented, so a file carrying
            // "firstWindowPreference": "persistedWindowLayout"
        would otherwise report the exact setting the user does NOT have - and a
        warning about a setting you cannot find is worse than silence.

        scripts/Test-Setup.ps1 mirrors this, because it must run under 5.1 and
        cannot import the module. tests/Attach.Tests.ps1 pins the two together.
    #>
    $path = Get-ZtTerminalProfilePath
    if (-not $path) { return $null }

    try { $text = Get-Content -LiteralPath $path -Raw -ErrorAction Stop } catch { return $null }
    if (-not $text) { return $null }

    $live = ($text -split "`r?`n" | Where-Object { $_.TrimStart() -notlike '//*' }) -join "`n"
    $m = [regex]::Match($live, '"firstWindowPreference"\s*:\s*"([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-ZtProfileCommand {
    <#
        The command a Windows Terminal profile actually runs, unwrapped from its
        shell.

        `pwsh.exe -NoExit -Command "claude --continue --resume x"` runs claude.
        `zellij.exe attach --create claude` runs zellij - the word claude is the
        session's NAME, not a command. Matching the string "claude" anywhere
        conflates the two, and this rig's own launcher profile is exactly that
        second shape, so a naive match imports the session launcher as a
        project. Unwrap first, then look at the first token only.
    #>
    param([string]$CommandLine)

    if (-not $CommandLine) { return '' }

    $inner = $CommandLine.Trim()

    # -Command / -c "<the real command>" - take what the shell was told to run.
    $m = [regex]::Match($inner, '(?i)\s-(?:Command|c)\s+(.+)$')
    if ($m.Success) {
        $inner = $m.Groups[1].Value.Trim()
        if ($inner.Length -ge 2) {
            $first = $inner.Substring(0, 1)
            if (($first -eq '"' -or $first -eq "'") -and $inner.EndsWith($first)) {
                $inner = $inner.Substring(1, $inner.Length - 2)
            }
        }
    }
    return $inner.Trim()
}

function Get-ZtProfileFirstToken {
    param([string]$Command)
    if (-not $Command) { return '' }
    $t = ($Command.Trim() -split '\s+')[0]
    $t = $t.Trim('"', "'")
    $t = Split-Path $t -Leaf
    if ($t -like '*.exe') { $t = $t.Substring(0, $t.Length - 4) }
    return $t.ToLowerInvariant()
}

function Get-ZtTerminalProfile {
    <#
        Windows Terminal profiles that name a starting directory, as workspace
        candidates.

        This replaced a hard dependency on a third-party bookmarks module. That
        module curates Windows Terminal profiles - its "bookmarks" ARE profiles -
        so reading settings.json directly gives the same list to everybody,
        including the people who use it, and to everybody who does not.

        Kind is inferred from what the profile runs, because a profile that
        already launches Claude should come in as a claude workspace rather than
        as a pwsh workspace whose command happens to start Claude a second way.
    #>
    param(
        [string]$Filter = '*',

        # Override the settings file. Exists so the kind inference can be tested
        # against a fixture holding the shapes that matter - a Claude profile, a
        # dev-server profile, a bare shell, the session launcher - none of which
        # a given machine is guaranteed to have. Testing it only against
        # whatever profiles the author happens to own is how the launcher
        # false-positive survived to be found by hand.
        [string]$SettingsPath
    )

    $path = $SettingsPath
    if (-not $path) { $path = Get-ZtTerminalProfilePath }
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return @() }

    $settings = Read-ZtJson $path $null
    if (-not $settings) { return @() }

    $profiles = Get-ZtProp (Get-ZtProp $settings 'profiles') 'list' @()
    $out = @()

    foreach ($p in @($profiles)) {
        $name = Get-ZtProp $p 'name'
        if (-not $name) { continue }
        if ($name -notlike $Filter) { continue }

        $dir = Get-ZtProp $p 'startingDirectory'
        if (-not $dir) { continue }

        # Bookmarks store %USERPROFILE%-style and ~ paths.
        $dir = [Environment]::ExpandEnvironmentVariables($dir)
        if ($dir -like '~*') { $dir = $HOME + $dir.Substring(1) }
        $dir = $dir.TrimEnd('\', '/')
        if (-not $dir) { continue }

        $cmd   = Get-ZtProfileCommand (Get-ZtProp $p 'commandline' '')
        $token = Get-ZtProfileFirstToken $cmd

        # The rig's own launcher. Registering the thing that opens the session
        # as a workspace inside that session is not a useful import.
        if ($token -eq 'zellij') { continue }

        if ($token -eq 'claude') {
            $kind = 'claude'; $run = ''
        } elseif (-not $token -or $token -in @('pwsh', 'powershell', 'cmd', 'wsl', 'bash', 'sh')) {
            # A plain shell in a folder. Now expressible exactly, rather than
            # being flattened into a claude workspace it never was.
            $kind = 'pwsh';   $run = ''
        } else {
            $kind = 'pwsh';   $run = $cmd
        }

        $out += [pscustomobject]@{
            Name    = $name
            Path    = $dir
            Kind    = $kind
            Command = $run
            Raw     = (Get-ZtProp $p 'commandline' '')
        }
    }

    return $out
}

function Get-ZtSessionName {
    <#
        What to pass to `claude --name`, which is NOT the tab name.

        The claude- prefix is Zellij bookkeeping: it is how zj-claude-tab.ps1
        knows which tabs to cycle and how the hook recognises its own. Claude
        Code has no use for it - the display name shows in the prompt box, the
        /resume picker, and on mobile and desktop, where "claude-web-api"
        reads as though the tool were part of the project's name.

        Safe to differ from the tab name because nothing matches on it. The hook
        derives the tab from cwd, and --name is not an address on Windows (see
        zj-claude-project.ps1). It is a label, and labels should read well.

        An explicit -Name that does not use the prefix is passed through
        untouched, and so is a collision suffix: 'claude-api-3f2a' becomes
        'api-3f2a', which is still what distinguishes it from the other api.
    #>
    param([string]$Tab, [string]$Prefix = 'claude-')

    if (-not $Tab) { return $Tab }
    if ($Prefix -and $Tab.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
        $stripped = $Tab.Substring($Prefix.Length)
        if ($stripped) { return $stripped }
    }
    return $Tab
}

# ---------------------------------------------------------------------------
#  Config documents
# ---------------------------------------------------------------------------

function New-ZtSharedConfig {
    return [pscustomobject]@{
        version    = $script:ZtSchemaVersion
        roots      = @()          # root names this config expects devices to define
        workspaces = @()
    }
}

function New-ZtDeviceConfig {
    return [pscustomobject]@{
        version    = $script:ZtSchemaVersion
        device     = (Get-ZtDeviceName)
        roots      = [pscustomobject]@{}
        workspaces = @()
    }
}

function Get-ZtSharedConfig {
    $cfg = Read-ZtJson (Get-ZtSharedPath) $null
    if (-not $cfg) { return (New-ZtSharedConfig) }
    return $cfg
}

function Get-ZtDeviceConfig {
    $cfg = Read-ZtJson (Get-ZtDevicePath) $null
    if (-not $cfg) { return (New-ZtDeviceConfig) }
    return $cfg
}

function Set-ZtSharedConfig { param($Config) Write-ZtJson (Get-ZtSharedPath) $Config }
function Set-ZtDeviceConfig { param($Config) Write-ZtJson (Get-ZtDevicePath) $Config }

function Resolve-ZtPath {
    <#
        Workspace + this device's roots -> an absolute path, or $null when this
        machine has no root by that name. $null is not an error: it is how a
        laptop says "that project lives on the desktop".
    #>
    param($Workspace, $DeviceConfig)

    $abs = Get-ZtProp $Workspace 'abs'
    if ($abs) { return $abs }

    $rootName = Get-ZtProp $Workspace 'root'
    $rel      = Get-ZtProp $Workspace 'rel' ''
    if (-not $rootName) { return $null }

    $roots = Get-ZtProp $DeviceConfig 'roots'
    if (-not $roots) { return $null }
    $base = Get-ZtProp $roots $rootName
    if (-not $base) { return $null }

    if (-not $rel) { return $base }

    # Not Join-Path: it validates the drive and throws "Cannot find drive. A
    # drive with the name 'D' does not exist." when the root names a volume this
    # machine has not got. That is the ORDINARY case for a shared workspace list
    # - the whole reason roots exist is that the other machine's layout differs -
    # and the caller's job is to notice the path is unreachable, not to be handed
    # an exception. Combine as text; Test-Path decides whether it is real.
    return ($base.TrimEnd('\', '/') + '\' + $rel.TrimStart('\', '/'))
}

function ConvertTo-ZtLocation {
    <#
        Absolute path -> {root, rel} against this device's roots, so anything
        registered under a known root is publishable to the other machines
        without further thought. Longest root wins, or nothing matches and it
        stays absolute and device-only.
    #>
    param([string]$Path, $DeviceConfig)

    $roots = Get-ZtProp $DeviceConfig 'roots'
    $best  = $null
    if ($roots) {
        foreach ($p in $roots.PSObject.Properties) {
            $base = $p.Value
            if (-not $base) { continue }
            $baseNorm = $base.TrimEnd('\')
            if ($Path.ToLowerInvariant().StartsWith(($baseNorm + '\').ToLowerInvariant())) {
                if (-not $best -or $baseNorm.Length -gt $best.Base.Length) {
                    $best = [pscustomobject]@{ Name = $p.Name; Base = $baseNorm }
                }
            }
        }
    }

    if ($best) {
        return [pscustomobject]@{
            root = $best.Name
            rel  = $Path.Substring($best.Base.Length).TrimStart('\')
            abs  = $null
        }
    }
    return [pscustomobject]@{ root = $null; rel = $null; abs = $Path }
}

# ---------------------------------------------------------------------------
#  Live records
# ---------------------------------------------------------------------------

function Test-ZtLiveRecordAlive {
    <#
        Is the session this record describes still running?

        A record carries the pid of the claude process that wrote it. Three
        answers, and the middle one matters most:

          - no pid at all  -> ALIVE. Records written by Set-ZtLive (a `zt start`
            of a pwsh workspace, or any older record) have none, and there is no
            evidence of death. Guessing dead here would delete a running
            workspace's record.
          - pid gone        -> dead.
          - pid present but that process started AFTER this record -> dead, and
            the pid has been reused by something unrelated. Without this a
            leaked record can be kept alive indefinitely by a stranger.

        cmdpal\ZellijTerminal.Palette\ZtStore.cs carries the same rule, because
        the palette reads these files directly and cannot report a different
        answer from `zt`. tests\Live.Tests.ps1 pins them together.
    #>
    param($Record)

    if (-not $Record) { return $false }

    $recPid = Get-ZtProp $Record 'pid'
    if (-not $recPid) { return $true }

    $n = 0
    if (-not [int]::TryParse("$recPid", [ref]$n)) { return $true }
    if ($n -le 0) { return $true }

    $proc = Get-Process -Id $n -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }

    $startedAt = Get-ZtProp $Record 'startedAt'
    if ($startedAt) {
        try {
            $recorded = [datetime]::Parse($startedAt)
            # One second of slack: the record is written moments after the
            # process starts, and clock granularity should not condemn it.
            if ($proc.StartTime -gt $recorded.AddSeconds(1)) { return $false }
        } catch { }
    }
    return $true
}

function Get-ZtLive {
    <#
        Everything the hook has told us is running on this machine.

        RETURNS DEAD RECORDS TOO, deliberately. A record left behind by a session
        that never said goodbye is not rubbish - it is the entire input to
        `zt restore`, which reopens what a crash took down (see
        Resume-ZellijTerminal). Deleting it here would quietly turn shutdown
        recovery into a no-op, and nothing would report the loss.

        What the pid buys is an honest STATE instead: a record whose process is
        gone means 'stale', not 'running'. Get-ZtWorkspaceRecords makes that
        call; `zt sync` is where a record is actually removed, because that is
        the command whose whole job is saying so.
    #>
    $dir = Get-ZtLiveDir
    if (-not (Test-Path -LiteralPath $dir)) { return @() }

    $out = @()
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        $rec = Read-ZtJson $f.FullName $null
        if ($rec) { $out += $rec }
    }
    return $out
}

function Set-ZtLive {
    <#
        Record that something is running here.

        Claude workspaces get this written by the hook on SessionStart, with the
        real session id. Everything else has no hook at all, so without this a
        `pwsh` workspace could never report as running - only ever 'tab-only',
        which would make Stop and Restart look broken. Start writes it for both
        kinds; for Claude the hook overwrites it moments later with the session
        id, which is the field that makes Restart able to resume.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Cwd,
        [string]$Tab,
        [string]$Kind = 'claude',
        [string]$SessionId,

        # Not $Event: PowerShell's eventing subsystem owns that name as an
        # automatic variable, and shadowing it inside a function is a quiet way
        # to make a future -ErrorAction trace read very strangely.
        [string]$EventName = 'Start'
    )

    $dir = Get-ZtLiveDir
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # No pid, deliberately. This runs in the `zt` process, not in the thing being
    # started - that is a command inside a Zellij pane whose pid we never learn.
    # The hook fills it in moments later for a Claude workspace, and a record
    # without one is treated as alive: absence of evidence, not evidence of
    # death. See Test-ZtLiveRecordAlive.
    $rec = [ordered]@{
        key       = $Key
        cwd       = $Cwd
        tab       = $Tab
        kind      = $Kind
        sessionId = $SessionId
        zjSession = $null
        pid       = $null
        startedAt = (Get-Date).ToString('o')
        lastEvent = $EventName
    }
    Write-ZtJson (Join-Path $dir ($Key + '.json')) ([pscustomobject]$rec)
}

function Remove-ZtLive {
    param([string]$Key)
    $p = Join-Path (Get-ZtLiveDir) ($Key + '.json')
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
#  Zellij
# ---------------------------------------------------------------------------

function Invoke-ZtZellij {
    <#
        Run a zellij action and report whether it worked.

        ZELLIJ MISSING IS A RESULT, NOT AN EXCEPTION. `& zellij` on a machine
        without it throws CommandNotFoundException, which used to escape this
        function and surface as a raw "The term 'zellij' is not recognized"
        from whatever the caller was doing - and, being a terminating error in
        a module under Set-StrictMode, took the caller down with it rather than
        letting it say something useful. Every caller here already handles
        Ok = $false, because a detached session and a refused action both come
        back that way, so "not installed" belongs in the same channel.

        Found by CI: a hosted runner has no zellij, and the assertion that
        Get-ZtClientCount returns -1 when zellij cannot answer failed with the
        CommandNotFoundException instead. The suite was green on every machine
        that had the rig installed, which is exactly the population that cannot
        detect this.
    #>
    param([string]$Session, [string[]]$ZArgs)

    if (-not (Get-Command zellij -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Ok = $false; Output = 'zellij is not installed, or not on PATH' }
    }

    $all = @('--session', $Session, 'action') + $ZArgs
    $out = & zellij @all 2>&1
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = ($out -join "`n") }
}

function Get-ZtWtDefaultProfile {
    <#
        Windows Terminal gives a tab launched from a COMMAND LINE no profile,
        so it renders with a generic console icon instead of the shell's. The
        title is ours and looks right; the icon is what makes the tab read as
        Command Prompt when it is running pwsh.

        This was invisible while Terminal was set to restore its window layout,
        because a restored tab keeps the profile identity it was first created
        with. Turning that off - which is how the duplicate-window bug is
        avoided - made every attach build the tab fresh, and the icon changed.

        Read as TEXT, not JSON: Terminal's settings.json is JSONC and carries
        comments. Returns $null when it cannot be read, and the caller then
        omits --profile and behaves exactly as before.
    #>
    foreach ($p in (Get-ZtTerminalProfilePaths)) {
        try {
            $text = Get-Content -LiteralPath $p -Raw -ErrorAction Stop
            $m    = [regex]::Match($text, '"defaultProfile"\s*:\s*"([^"]+)"')
            if ($m.Success) { return $m.Groups[1].Value }
        } catch {
            Write-Verbose "Could not read '$p': $($_.Exception.Message)"
        }
    }
    return $null
}

function Get-ZtWtFragmentPath {
    <#
        Windows Terminal's sanctioned extension point: a JSON file dropped here
        contributes a profile without editing the user's settings.json, and
        uninstalling is deleting it. That matters because settings.json is
        JSONC - read-modify-write through ConvertTo-Json would silently strip
        every comment in a file we do not own.

        Read at Terminal STARTUP only. A fragment written while Terminal is
        running does nothing until it restarts, and `wt -p <unknown>` falls back
        to the default profile without an error - so the symptom of "not loaded
        yet" is a tab with the wrong icon, not a failure.
    #>
    return (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\ZellijTerminal\zellij-terminal.json')
}

function Get-ZtWtProfile {
    <#
        Which Terminal profile a new session tab should use. The rig's own
        profile when its fragment is installed - that is the one carrying the
        icon - and otherwise whatever the user's default is, which at least
        gives the tab that shell's icon rather than the generic console one.
    #>
    param([string]$Name = 'zellij-terminal')

    # Gate on TERMINAL having loaded the fragment, not on the fragment existing.
    # Fragments are read at startup, and `wt -p <unknown>` falls back to a
    # generic console icon - WORSE than the default profile we would otherwise
    # have asked for. So the window between writing the fragment and restarting
    # Terminal made the very icon this exists to fix look wrong. Terminal
    # records the profiles it discovers in settings.json, so that file is the
    # honest answer to "is this profile real yet".
    if (Test-Path -LiteralPath (Get-ZtWtFragmentPath)) {
        foreach ($p in (Get-ZtTerminalProfilePaths)) {
            try {
                $text = Get-Content -LiteralPath $p -Raw -ErrorAction Stop
                if ($text -match ('"name"\s*:\s*"' + [regex]::Escape($Name) + '"')) { return $Name }
            } catch {
                Write-Verbose "Could not read '$p': $($_.Exception.Message)"
            }
        }
    }

    return (Get-ZtWtDefaultProfile)
}

function Get-ZtTerminalHostingSession {
    <#
        The Windows Terminal process id that is showing this session, or $null.

        A zellij client is a PROCESS, and processes have parents. The tab runs
        `zellij attach --create <session>`, and walking up from it arrives at
        the terminal hosting that tab. Demonstrated on this rig: the attach
        process for 'claude' reported parent WindowsTerminal.exe.

        This is a better question than "is any Terminal window open", which is
        all zac could ask before, and it is better in the direction that
        matters. A client can be attached from a different terminal application,
        from a bare console, or over SSH; in every one of those cases some
        Terminal window probably IS open somewhere, the old check said yes, and
        raising it did nothing for the session in question.

        EVERY CHANNEL. Preview is WindowsTerminalPreview.exe and Canary is
        WindowsTerminalCanary.exe - the same three names pad/macropad.ahk
        matches on and docs/04-reference.md lists. Knowing only the stable name
        read a Preview machine as "nothing is hosting it", which sent zac down
        the branch that opens a SECOND client on a session already attached: the
        exact bug zac exists to prevent, on the machines least likely to be
        tested.

        It still cannot say WHICH WINDOW, and no process-based check can:
        Terminal hosts EVERY WINDOW IN ONE PROCESS. Demonstrated - opening a
        second window left the process count at 1 and moved that process's
        MainWindowHandle rather than adding a row. That is why zac's old
        before/after window count could never rise, always concluded the focus
        was real, and had to go: a check that cannot fail is worse than no
        check, because it reads like evidence. Nothing here promises a focus; it
        answers whether a Terminal is hosting a view at all.

        Walks several hops, because the chain is not always one deep: a tab
        opened by this module runs the attach directly, but a person who typed
        `zellij attach` into a pwsh tab puts a shell in between.
    #>
    param(
        [string]$Session,
        [int]$MaxHops = 5
    )

    $terminals = 'WindowsTerminal.exe', 'WindowsTerminalPreview.exe', 'WindowsTerminalCanary.exe'

    $clients = @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and
                $_.CommandLine -match 'zellij(\.exe)?\s' -and
                $_.CommandLine -match 'attach' -and
                $_.CommandLine -match [regex]::Escape($Session)
            }
    )
    if ($clients.Count -eq 0) { return $null }

    foreach ($c in $clients) {
        $pid_ = $c.ParentProcessId
        for ($hop = 0; $hop -lt $MaxHops -and $pid_; $hop++) {
            $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$pid_" -ErrorAction SilentlyContinue
            if (-not $parent) { break }
            if ($terminals -contains $parent.Name) { return $parent.ProcessId }
            $pid_ = $parent.ParentProcessId
        }
    }
    return $null
}

function Test-ZtOwnHookEntry {
    <#
        Is one entry of a Claude Code `hooks.<Event>` array OURS?

        This exists because `hooks` is a SHARED key. Both halves of this rig
        used to treat it as exclusively zt's: install replaced the whole key and
        uninstall deleted the whole key, so anybody who also had, say, a
        formatter hook or a plugin's hooks registered globally lost them - while
        the uninstaller reported "rest of the file backed up and kept", which
        was true of the file and false of their hooks.

        Matched on the SCRIPT NAME rather than the full path on purpose: an
        entry left behind by an older clone somewhere else is still ours, and
        recognising it is what lets install replace it instead of accumulating a
        second registration beside it - two hooks firing per event, one of them
        pointing at a directory that may not exist any more.

        The same rule is written a second time in install.ps1, which cannot
        import this module: it runs before the module is installed, and under
        Windows PowerShell 5.1. tests/Hooks.Tests.ps1 pins the two together.
    #>
    param($Entry)

    if ($null -eq $Entry) { return $false }

    # Every field here is optional in somebody else's hook, and reading an
    # absent property throws under Set-StrictMode 2.0 - as does reading .Name
    # off an EMPTY Properties collection, which is why this goes through
    # ForEach-Object rather than $_.PSObject.Properties.Name. Found by the test:
    # a foreign entry with no `command` field took the whole uninstall down.
    $names = @()
    try { $names = @($Entry.PSObject.Properties | ForEach-Object { $_.Name }) } catch { return $false }
    if ($names -notcontains 'hooks') { return $false }

    foreach ($h in @($Entry.hooks)) {
        if ($null -eq $h) { continue }
        $hn = @()
        try { $hn = @($h.PSObject.Properties | ForEach-Object { $_.Name }) } catch { continue }

        if (($hn -contains 'command') -and $h.command -and ($h.command -like '*claude-zj-hook*')) {
            return $true
        }
        if ($hn -contains 'args') {
            foreach ($a in @($h.args)) {
                if ($a -and ($a -like '*claude-zj-hook*')) { return $true }
            }
        }
    }
    return $false
}

function Remove-ZtOwnHookEntries {
    <#
        Take a Claude Code `hooks` object and give back one with OUR entries
        taken out and everybody else's left exactly as they were.

        A function rather than a block inside the uninstaller because the
        uninstaller cannot be run to test it: it also removes the module
        junction and restores Zellij's config, so exercising the six lines that
        matter would uninstall the rig from the machine doing the testing. This
        is the part worth proving, so it is the part that is callable.

        Returns Survivors (null when nothing is left, so the caller drops the
        key rather than writing `"hooks": {}`, which is a registration that does
        nothing), OursRemoved and ForeignKept.
    #>
    param($Hooks)

    $survivors = [pscustomobject]@{}
    $ours      = 0
    $foreign   = 0

    $events = @()
    if ($Hooks) {
        try { $events = @($Hooks.PSObject.Properties | ForEach-Object { $_.Name }) } catch { $events = @() }
    }

    if ($events.Count -gt 0) {
        foreach ($ev in $events) {
            $keep = @()
            foreach ($entry in @($Hooks.$ev)) {
                if (Test-ZtOwnHookEntry $entry) { $ours++ }
                else { $keep += $entry; $foreign++ }
            }
            # An event left with nothing is dropped rather than written back as
            # an empty array.
            if ($keep.Count -gt 0) {
                $survivors | Add-Member -NotePropertyName $ev -NotePropertyValue @($keep) -Force
            }
        }
    }

    $left = @()
    try { $left = @($survivors.PSObject.Properties | ForEach-Object { $_.Name }) } catch { $left = @() }
    $anyLeft = ($left.Count -gt 0)

    return [pscustomobject]@{
        Survivors   = $(if ($anyLeft) { $survivors } else { $null })
        OursRemoved = $ours
        ForeignKept = $foreign
    }
}

function Get-ZtTabBase {
    <#
        The hook decorates a tab with what its session is doing right now -
        `claude-web-api ~` - via rename-tab -t, which targets a tab without
        moving focus. The glyph changes on every tool call; the identity does
        not. So everything that MATCHES a tab works on the base name, and only
        the calls that hand a string back to Zellij use the live one.

        The character class is the symbol table in hooks\claude-zj-hook.ps1.
        Four copies of this rule exist - hook, zj-claude-tab.ps1,
        zj-claude-project.ps1 and here, plus the palette in C# - and a test pins
        them together, because a name that no longer matches produces a silent
        no-op rather than an error.
    #>
    param([string]$Name)
    if (-not $Name) { return $Name }
    return ($Name -replace ' [v!?*>~#@&+.]$', '')
}

function Get-ZtTabNames {
    # BASE names. Callers use these to decide what exists; Get-ZtLiveTabName
    # converts back when Zellij needs the string it is actually holding.
    param([string]$Session)

    $r = Invoke-ZtZellij -Session $Session -ZArgs @('query-tab-names')
    if (-not $r.Ok) { return @() }

    # Same trap as list-clients, same answer. A missing session prints
    # "Session 'x' not found. The following sessions are active:" followed by
    # the session list, AND EXITS 0 - so this returned that prose as a list of
    # tab names, and every caller deciding "does tab X exist" got a confident
    # wrong answer built from other sessions' names.
    if ($r.Output -match "Session '.*' not found") { return @() }

    return @(
        $r.Output -split "`r?`n" |
            ForEach-Object { Get-ZtTabBase ($_.Trim()) } |
            Where-Object   { $_ -ne '' }
    )
}

function Get-ZtLiveTabName {
    <#
        go-to-tab-name matches the live string exactly and no-ops silently on a
        miss - which, with nothing attached, is indistinguishable from success.
        Falls back to the base name so a session with no decoration behaves
        exactly as it did before.
    #>
    param([string]$Session, [string]$Base)

    $r = Invoke-ZtZellij -Session $Session -ZArgs @('query-tab-names')
    if ($r.Ok) {
        foreach ($n in ($r.Output -split "`r?`n")) {
            $t = $n.Trim()
            if ($t -and (Get-ZtTabBase $t) -eq $Base) { return $t }
        }
    }
    return $Base
}

function Test-ZtSession {
    <#
        Is there a session with EXACTLY this name?

        It used to regex the whole `list-sessions` output for the name, which
        matches a substring of any other session. Demonstrated on this machine,
        with sessions 'claude' and 'auspicious-pigeon' live: the old expression
        answered True for 'auspicious', which is not a session - and would have
        answered True for 'laud'. Zellij names unattended sessions after random
        animals, so collisions are ordinary rather than contrived.

        The name is the first field of each row, before " [Created ...]".
    #>
    param([string]$Session)

    # No zellij means no session, which is an answer. See Invoke-ZtZellij for
    # why this is a return value here rather than an exception.
    if (-not (Get-Command zellij -ErrorAction SilentlyContinue)) { return $false }

    $raw   = & zellij list-sessions 2>&1 | Out-String
    $clean = $raw -replace "`e\[[0-9;]*m", ''
    foreach ($line in ($clean -split "`r?`n")) {
        $m = [regex]::Match($line.Trim(), '^(?<name>\S+)\s+\[Created\s')
        if ($m.Success -and $m.Groups['name'].Value -eq $Session) { return $true }
    }
    return $false
}

function Measure-ZtClientRows {
    <#
        How many clients a `list-clients` table describes.

        Split out from Test-ZtClientAttached so it can be tested against
        captured output: the rest of that function talks to zellij, but this
        part is a pure string operation and it is the part that decides whether
        anything at all is attached. Four copies of this parse existed - here,
        Get-ZellijTerminalSession, scripts/Test-Setup.ps1 and the C# side - and
        the two in the module now share this one.

        A row is COUNTED BY ITS SHAPE - a client id, which is digits, then
        whitespace - not by being any line that is not the header. That
        distinction is the whole function, because of this:

            zellij --session nope action list-clients
            Session 'nope' not found. The following sessions are active:
            auspicious-pigeon [Created 2h ago]
            claude [Created 7h ago] (current)
            exit code 0

        Three lines of prose, exit code 0. The old parse counted them as three
        attached clients, so a session that does not exist reported as attached
        - the silent success this module exists to refuse, sitting inside the
        function whose entire job is refusing it. Demonstrated on 0.44.3.

        Trim first, then match. Observed on 0.44.3 the CLIENT_ID column is
        left-aligned and padded to the RIGHT, so rows carry no leading
        whitespace today - but a parse anchored on that is one release away from
        being wrong for no reason.
    #>
    param([string]$Text)

    if (-not $Text) { return 0 }
    return @(
        $Text -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object   { $_ -match '^\d+\s' }
    ).Count
}

function Get-ZtClientCount {
    <#
        Clients attached to a session, or -1 when zellij could not answer.

        -1 rather than 0, because "no clients" and "no answer" lead to opposite
        decisions: the first says open a window, the second says do not act on
        anything you think you know. A caller comparing counts before and after
        a launch would read a failed call as "nothing changed" if this returned
        0, which is the silent-success shape this module exists to refuse.
    #>
    param([string]$Session)

    $r = Invoke-ZtZellij -Session $Session -ZArgs @('list-clients')
    if (-not $r.Ok) { return -1 }

    # The exit code does not cover this one: a missing session prints
    # "Session 'x' not found" and STILL EXITS 0, demonstrated on 0.44.3. The
    # shape-based parse already returns 0 for that prose, but 0 would mean "the
    # session is there with nobody watching", which is a different answer and
    # leads somewhere different.
    if ($r.Output -match "Session '.*' not found") { return -1 }

    return (Measure-ZtClientRows $r.Output)
}

function Test-ZtClientAttached {
    <#
        With nothing attached, write, write-chars, go-to-tab-name and close-tab
        are silent no-ops THAT STILL EXIT 0. Every command that
        depends on one has to check this itself or it will report success for
        work that never happened.
    #>
    param([string]$Session)

    return ((Get-ZtClientCount -Session $Session) -gt 0)
}

function Wait-ZtFocus {
    <#
        Confirm the focus actually moved before typing.

        `go-to-tab-name` returns as soon as the request is queued, not when the
        switch has happened. Writing immediately after it is a race, and the
        race is not benign: `write` goes to whatever pane is focused AT THE TIME
        THE BYTES ARRIVE, so losing it means Ctrl+C lands in a different tab -
        very possibly a live Claude session in the middle of something. Observed
        exactly that during development; the first Stop appeared to succeed and
        the target was still running.

        current-tab-info only answers for an attached client, which every caller
        of this already requires, and it prints "name: <tab> id: N position: N".
        Matching `name: <tab>` followed by whitespace and `id:` rather than a
        bare substring keeps 'claude1' from matching 'claude10'.
    #>
    param(
        [string]$Session,
        [string]$Tab,
        [int]$Attempts = 12
    )

    # The optional group is the hook's activity glyph, which is part of the live
    # name but not of the identity. Still anchored on `id:` rather than being a
    # bare substring, so 'claude1' cannot match 'claude10'.
    $pattern = 'name:\s*' + [regex]::Escape($Tab) + '(\s[v!?*>~#@&+.])?\s+id:'
    for ($i = 0; $i -lt $Attempts; $i++) {
        $info = (Invoke-ZtZellij -Session $Session -ZArgs @('current-tab-info')).Output
        if ($info -and ($info -notmatch 'No active tab') -and ($info -match $pattern)) {
            return $true
        }
        Start-Sleep -Milliseconds 80
    }
    return $false
}

function Send-ZtKeys {
    <#
        Type into a tab. Focus first, and wait for the focus to be real: `write`
        and `write-chars` go to the FOCUSED pane, the same trap as close-tab and
        rename-tab. Returns $false if the target could not be focused, and
        callers must treat that as a failure rather than reporting success.
    #>
    param(
        [string]$Session,
        [string]$Tab,
        [string]$Text,
        [switch]$Enter,
        [int[]]$Bytes
    )

    $f = Invoke-ZtZellij -Session $Session -ZArgs @('go-to-tab-name', (Get-ZtLiveTabName -Session $Session -Base $Tab))
    if (-not $f.Ok) { return $false }
    if (-not (Wait-ZtFocus -Session $Session -Tab $Tab)) { return $false }

    if ($Bytes) {
        foreach ($b in $Bytes) {
            Invoke-ZtZellij -Session $Session -ZArgs @('write', "$b") | Out-Null
        }
    }
    if ($Text) {
        Invoke-ZtZellij -Session $Session -ZArgs @('write-chars', $Text) | Out-Null
    }
    if ($Enter) {
        Invoke-ZtZellij -Session $Session -ZArgs @('write', '13') | Out-Null
    }
    return $true
}

# ---------------------------------------------------------------------------
#  The merged view
# ---------------------------------------------------------------------------

function Get-ZtWorkspaceRecords {
    <#
        Shared config + this device's config + live records + live Zellij state,
        reconciled into one list. Everything user-facing reads this.

        Shared and device entries are merged by key, with the device entry
        winning on conflicts - it is the more specific statement about this
        machine.
    #>
    param([string]$Session = 'claude', [string]$Prefix = 'claude-')

    $shared = Get-ZtSharedConfig
    $device = Get-ZtDeviceConfig
    $live   = Get-ZtLive

    $tabs = @()
    $sessionUp = Test-ZtSession -Session $Session
    if ($sessionUp) { $tabs = Get-ZtTabNames -Session $Session }

    $flagDir = Join-Path $env:TEMP 'claude-zellij-flags'

    $byKey = @{}
    $order = @()

    foreach ($pair in @(
        @{ Scope = 'shared'; Items = @(Get-ZtProp $shared 'workspaces' @()) },
        @{ Scope = 'device'; Items = @(Get-ZtProp $device 'workspaces' @()) }
    )) {
        foreach ($w in $pair.Items) {
            $key = Get-ZtProp $w 'key'
            if (-not $key) { continue }
            if (-not $byKey.ContainsKey($key)) { $order += $key }
            $byKey[$key] = [pscustomobject]@{ Scope = $pair.Scope; Ws = $w }
        }
    }

    $out = @()
    foreach ($key in $order) {
        $entry = $byKey[$key]
        $w     = $entry.Ws
        $path  = Resolve-ZtPath -Workspace $w -DeviceConfig $device
        $avail = $false
        if ($path) { $avail = (Test-Path -LiteralPath $path) }

        $tab = ''
        if ($path) { $tab = Get-ZtTabName -Workspace $w -Path $path -Prefix $Prefix }

        $rec = $null
        foreach ($l in $live) {
            if ((Get-ZtProp $l 'key') -eq $key) { $rec = $l; break }
        }

        $hasTab = $false
        if ($tab) { $hasTab = ($tabs -contains $tab) }

        # A record is not proof of a running session. SessionEnd deletes it, but
        # Claude Code cancels hooks that have not finished when it exits, so the
        # record outlives the session - and the TAB outlives it too, because the
        # pane drops back to a shell. Both survivors present used to read as
        # 'running' forever, with `zt go` jumping to a dead session.
        #
        # The pid settles it. Gone process, surviving record -> 'stale', which is
        # both honest and exactly what `zt restore` looks for.
        $recAlive = $false
        if ($rec) { $recAlive = Test-ZtLiveRecordAlive $rec }

        # State is decided by live Zellij, not by what the registry believes.
        $state = 'stopped'
        if (-not $avail)      { $state = 'unavailable' }
        elseif ($hasTab -and $rec -and $recAlive) { $state = 'running' }
        elseif ($hasTab -and $rec) { $state = 'stale' }
        elseif ($hasTab)      { $state = 'tab-only' }
        elseif ($rec)         { $state = 'stale' }

        $waiting   = $false
        $waitFor   = ''
        $waitSince = $null
        if ($tab) {
            $flag = Join-Path $flagDir ($tab + '.json')
            if (Test-Path -LiteralPath $flag) {
                $f = Read-ZtJson $flag $null
                if ($f -and (Get-ZtProp $f 'waiting')) {
                    $waiting   = $true
                    $waitFor   = Get-ZtProp $f 'event' '?'
                    $waitSince = Get-ZtProp $f 'since'
                }
            }
        }

        # One age, whichever question is live: how long it has been ignored if
        # it is asking for you, otherwise how long it has been up.
        $ageFrom = Get-ZtProp $rec 'startedAt'
        if ($waiting -and $waitSince) { $ageFrom = $waitSince }

        $o = [pscustomobject]@{
            PSTypeName = 'ZellijTerminal.Workspace'
            Id         = Get-ZtProp $w 'id' $key
            Key        = $key
            State      = $state
            Waiting    = $waiting
            WaitEvent  = $waitFor
            WaitSince  = $waitSince
            Age        = (Format-ZtAge $ageFrom)
            Kind       = Get-ZtProp $w 'kind' 'claude'
            Tab        = $tab
            Path       = $path
            Scope      = $entry.Scope
            Session    = Get-ZtProp $rec 'sessionId'
            StartedAt  = Get-ZtProp $rec 'startedAt'
            LastEvent  = Get-ZtProp $rec 'lastEvent'
            Command    = Get-ZtProp $w 'command'
            Tags       = @(Get-ZtProp $w 'tags' @())
        }
        $out += $o
    }

    # Tabs that exist but are in no registry.
    #
    # Without this, `zt` shows one workspace while the tab bar shows four, and
    # nothing explains the gap - which is exactly the confusion the claim "the
    # registry is a cache, live Zellij is the truth" was supposed to prevent.
    # Tabs made before the registry existed, or by hand with `zellij action
    # new-tab`, have no config entry and no live record; they are still real.
    #
    # No path, because Zellij will not tell us a tab's directory - so these
    # cannot be started or stopped until they are registered against a folder.
    $known = @($out | ForEach-Object { $_.Tab })
    foreach ($t in $tabs) {
        if ($t -notlike "$Prefix*") { continue }
        if ($known -contains $t) { continue }

        $flag    = Join-Path $flagDir ($t + '.json')
        $waiting = $false
        $waitFor = ''
        $since   = $null
        if (Test-Path -LiteralPath $flag) {
            $f = Read-ZtJson $flag $null
            if ($f -and (Get-ZtProp $f 'waiting')) {
                $waiting = $true
                $waitFor = Get-ZtProp $f 'event' '?'
                $since   = Get-ZtProp $f 'since'
            }
        }

        $out += [pscustomobject]@{
            PSTypeName = 'ZellijTerminal.Workspace'
            Id         = ($t -replace ('^' + [regex]::Escape($Prefix)), '')
            Key        = ''
            State      = 'unregistered'
            Waiting    = $waiting
            WaitEvent  = $waitFor
            WaitSince  = $since
            Age        = (Format-ZtAge $since)
            Kind       = 'unknown'
            Tab        = $t
            Path       = ''
            Scope      = 'tab'
            Session    = $null
            StartedAt  = $null
            LastEvent  = $null
            Command    = $null
            Tags       = @()
        }
    }

    return $out
}

function Find-ZtWorkspace {
    <#
        Resolve what the user typed - an id, a key, a tab name, or a path - to
        exactly one workspace, or explain why it could not.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Session = 'claude',
        [string]$Prefix  = 'claude-'
    )

    $all = Get-ZtWorkspaceRecords -Session $Session -Prefix $Prefix

    $hits = @($all | Where-Object { $_.Id -eq $Name })
    if ($hits.Count -eq 0) { $hits = @($all | Where-Object { $_.Key -eq $Name }) }
    if ($hits.Count -eq 0) { $hits = @($all | Where-Object { $_.Tab -eq $Name }) }
    if ($hits.Count -eq 0) { $hits = @($all | Where-Object { $_.Tab -eq ($Prefix + $Name) }) }
    if ($hits.Count -eq 0) {
        if (Test-Path -LiteralPath $Name) {
            $full = (Resolve-Path -LiteralPath $Name).Path
            $k    = Get-ZtKey $full
            $hits = @($all | Where-Object { $_.Key -eq $k })
        }
    }
    if ($hits.Count -eq 0) { $hits = @($all | Where-Object { $_.Id -like "$Name*" }) }

    if ($hits.Count -eq 0) {
        Write-Warning "No workspace matching '$Name'. Registered: $((($all | ForEach-Object { $_.Id }) -join ', '))"
        return $null
    }
    if ($hits.Count -gt 1) {
        Write-Warning "'$Name' matches several: $((($hits | ForEach-Object { $_.Id }) -join ', ')). Be more specific."
        return $null
    }
    return $hits[0]
}
