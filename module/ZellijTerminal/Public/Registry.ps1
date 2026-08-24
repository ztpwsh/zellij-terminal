<#
    Registry - what exists, adding it, removing it, sharing it.
#>

function Get-ZellijTerminal {
    <#
    .SYNOPSIS
        List registered workspaces with their live state.

    .DESCRIPTION
        Emits objects, so it composes:

            zt | Where-Object Waiting
            zt | Where-Object State -eq 'stale'

        State is decided by live Zellij, not by the registry, which is only a
        cache:

            running      a tab exists and a session has checked in
            tab-only     the tab is there but nothing has reported into it
            stopped      registered, not currently open
            stale        a session checked in but its tab is gone - usually a
                         terminal closed with the X button
            unavailable  no root for it on this device, or the path is missing

    .EXAMPLE
        zt                    # everything
        zt ls -Waiting        # just the ones asking for you
    #>
    [CmdletBinding()]
    param(
        # Filter by id, tag, or state.
        [Parameter(Position = 0)]
        [string]$Name,

        [string]$Tag,

        [ValidateSet('running', 'tab-only', 'stopped', 'stale', 'unavailable', 'unregistered')]
        [string]$State,

        # Only the ones whose Claude session is asking for input.
        [switch]$Waiting,

        # Skip picking up sessions the hook has reported but the registry has
        # not seen yet. Discovery is on by default - that is what "started a
        # session in a folder and it just appeared" means.
        [switch]$NoDiscover,

        # Include workspaces this device cannot reach. Off by default: a laptop
        # listing the desktop's projects as if they were startable is noise.
        [switch]$All,

        [string]$Session = 'claude',
        [string]$Prefix  = 'claude-'
    )

    if (-not $NoDiscover) { Register-ZtDiscovered -Prefix $Prefix | Out-Null }

    $records = Get-ZtWorkspaceRecords -Session $Session -Prefix $Prefix

    if (-not $All)  { $records = @($records | Where-Object { $_.State -ne 'unavailable' }) }
    if ($Name)      { $records = @($records | Where-Object { $_.Id -like "$Name*" }) }
    if ($Tag)       { $records = @($records | Where-Object { $_.Tags -contains $Tag }) }
    if ($State)     { $records = @($records | Where-Object { $_.State -eq $State }) }
    if ($Waiting)   { $records = @($records | Where-Object { $_.Waiting }) }

    return $records
}

function Register-ZtDiscovered {
    <#
        Pick up sessions the hook has reported in folders the registry does not
        know about yet, and register them on this device.

        This is the automatic half of the design. The hook cannot do it itself -
        it runs under 5.1, off the pwsh module path, on the latency path of
        every session start - so it writes one small live record and this turns
        that into a registration the next time you look. Which, in practice, is
        immediately.
    #>
    param([string]$Prefix = 'claude-')

    $device = Get-ZtDeviceConfig
    $shared = Get-ZtSharedConfig

    $known = @()
    foreach ($w in (@(Get-ZtProp $device 'workspaces' @()) + @(Get-ZtProp $shared 'workspaces' @()))) {
        $k = Get-ZtProp $w 'key'
        if ($k) { $known += $k }
    }

    $added = @()
    foreach ($l in (Get-ZtLive)) {
        $k = Get-ZtProp $l 'key'
        if (-not $k) { continue }
        if ($known -contains $k) { continue }

        $cwd = Get-ZtProp $l 'cwd'
        if (-not $cwd) { continue }
        if (-not (Test-Path -LiteralPath $cwd)) { continue }

        Register-ZellijTerminal -Path $cwd -Discovered -Prefix $Prefix -Confirm:$false
        $known += $k
        $added += $cwd
    }

    return $added
}

function Register-ZellijTerminal {
    <#
    .SYNOPSIS
        Register a directory as a workspace on this device.

    .DESCRIPTION
        Writes to this device's registry, %LOCALAPPDATA%\ZellijTerminal\devices\
        <HOSTNAME>.json by default - never to the shared list.
        That is deliberate: the hook calls this automatically on every session
        start, and only ever writing this machine's own file means several PCs
        can register freely without a single merge conflict. Use
        Publish-ZellijTerminal when you want an entry on the other machines too.

        Re-registering an existing directory updates it rather than adding a
        duplicate; the identity is the path, not the name.

    .EXAMPLE
        zt add .
        Register-ZellijTerminal . -Kind pwsh -Command 'npm run dev' -Tag web
    #>
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Path')]
    param(
        [Parameter(ParameterSetName = 'Path', Position = 0)]
        [string]$Path = '.',

        # Register every Windows Terminal profile that names a starting
        # directory, so a project list you already curate there drives this too.
        # Kind is inferred per profile from what it runs.
        [Parameter(ParameterSetName = 'FromBookmarks', Mandatory = $true)]
        [Alias('FromTerminalProfiles')]
        [switch]$FromBookmarks,

        [Parameter(ParameterSetName = 'FromBookmarks')]
        [string]$Filter = '*',

        # Import every profile with a starting directory, not just the ones that
        # already launch Claude.
        #
        # Claude-only by default because that is what the question "import my
        # projects" means here, and because a profile list is a general-purpose
        # thing - it holds SSH sessions, a shell in a downloads folder, whatever
        # else you keep one click away. Importing all of it turns a curated list
        # into noise you then have to unregister. What is skipped is always
        # reported, with this switch named, so the default never silently
        # discards anything.
        [Parameter(ParameterSetName = 'FromBookmarks')]
        [switch]$IncludeAll,

        # What to run in the tab. 'claude' needs no command.
        [ValidateSet('claude', 'pwsh')]
        [string]$Kind = 'claude',

        # For -Kind pwsh: the command line to run.
        [string]$Command,

        # Override the tab name. Needed when two projects share a leaf folder
        # name - see the warning this emits.
        [string]$Name,

        [string]$Id,

        [string[]]$Tag = @(),

        # Marks the entry as auto-discovered rather than deliberately added.
        [switch]$Discovered,

        # Emit the registered entry. The id is not always the folder leaf - a
        # tab-name collision appends the key - so a caller that wants to act on
        # what it just registered cannot re-derive the id and has to be told.
        # The Command Palette's folder picker registers then starts, and this is
        # how it knows what to start.
        [switch]$PassThru,

        # Open its tab straight away. Registering and opening are almost always
        # the same intent the first time you point this at a folder, and they
        # were two commands with nothing linking them.
        #
        # Off by default on purpose: the hook calls this on every session start,
        # so a default -Start would reopen tabs underneath you, and registration
        # is meant to work with no session attached.
        [switch]$Start,

        # Which session -Start opens the tab in.
        [string]$Session = 'claude',

        [string]$Prefix = 'claude-'
    )

    if ($FromBookmarks) {
        # Reads Windows Terminal's own profiles rather than depending on a
        # bookmarks module. Any such module curates profiles - its bookmarks
        # ARE profiles - so this covers the people who use one and the people
        # who just added a startingDirectory by hand, with nothing to install.
        $candidates = @(Get-ZtTerminalProfile -Filter $Filter)

        if ($candidates.Count -eq 0) {
            $where = Get-ZtTerminalProfilePath
            if (-not $where) {
                Write-Warning 'No Windows Terminal settings.json found. Register folders with: zt add <path>'
            } else {
                Write-Warning ("No profile matching '$Filter' has a startingDirectory. " +
                               "Looked in: $where")
            }
            return
        }

        $skipped = @($candidates | Where-Object { $_.Kind -ne 'claude' })
        if (-not $IncludeAll) {
            $candidates = @($candidates | Where-Object { $_.Kind -eq 'claude' })
        }

        if ($candidates.Count -eq 0 -and $skipped.Count -gt 0) {
            Write-Warning ("No profile matching '$Filter' launches Claude. " +
                           "$($skipped.Count) other(s) have a starting directory - import them with -IncludeAll.")
            return
        }

        foreach ($c in $candidates) {
            if (-not (Test-Path -LiteralPath $c.Path)) {
                Write-Warning "Profile '$($c.Name)' points at a directory that is not here, skipping: $($c.Path)"
                continue
            }

            # Kind comes from what the profile RUNS, not from -Kind. A profile
            # already launching Claude is a claude workspace; one running a dev
            # server is a pwsh workspace with that command. Passing -Kind
            # explicitly overrides the whole batch, which is the escape hatch.
            $useKind = $c.Kind
            $useCmd  = $c.Command
            if ($PSBoundParameters.ContainsKey('Kind')) { $useKind = $Kind; $useCmd = $Command }

            $splat = @{ Path = $c.Path; Kind = $useKind; Tag = $Tag; Prefix = $Prefix }
            if ($useCmd) { $splat['Command'] = $useCmd }

            # Named after the DIRECTORY, not the profile. That is load-bearing:
            # the hook derives its key and tab name from the cwd Claude reports,
            # so a name taken from the profile label would not match and the
            # waiting jump would never find it.
            Register-ZellijTerminal @splat
        }

        # Named, counted and actionable. A default that filters silently is
        # indistinguishable from one that failed to find anything.
        if ($skipped.Count -gt 0 -and -not $IncludeAll) {
            Write-Host ''
            Write-Host ("  Skipped $($skipped.Count) profile(s) that do not launch Claude:") -ForegroundColor DarkGray
            foreach ($s in $skipped) {
                Write-Host ("    {0,-24} {1}" -f $s.Name, $(if ($s.Command) { $s.Command } else { 'a shell' })) -ForegroundColor DarkGray
            }
            Write-Host '    Import them too with:  -IncludeAll' -ForegroundColor DarkGray
            Write-Host ''
        }
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "Path not found: $Path"
        return
    }
    $full = (Resolve-Path -LiteralPath $Path).Path
    if (-not (Get-Item -LiteralPath $full).PSIsContainer) {
        Write-Warning "Not a directory: $full"
        return
    }

    # -Kind pwsh with no -Command used to be an error. It is now how you say
    # "a shell in this folder, running nothing" - the third thing people want
    # after "Claude here" and "this command here", and previously the only one
    # with no way to express it. Start-ZellijTerminal already handles an empty
    # command: it opens the tab and leaves the prompt alone.

    $key    = Get-ZtKey $full
    $device = Get-ZtDeviceConfig
    $shared = Get-ZtSharedConfig

    $deviceWs = @(Get-ZtProp $device 'workspaces' @())
    $sharedWs = @(Get-ZtProp $shared 'workspaces' @())

    # Already known? Update in place. The hook calls this on every session
    # start, so this is the common path, not the exception.
    $existing = @($deviceWs | Where-Object { (Get-ZtProp $_ 'key') -eq $key })
    $inShared = @($sharedWs | Where-Object { (Get-ZtProp $_ 'key') -eq $key })

    if ($inShared.Count -gt 0 -and $existing.Count -eq 0) {
        Write-Verbose "Already in the shared config as '$(Get-ZtProp $inShared[0] 'id')'."
        return
    }

    $taken = @()
    foreach ($w in ($deviceWs + $sharedWs)) {
        $wid = Get-ZtProp $w 'id'
        if ($wid -and (Get-ZtProp $w 'key') -ne $key) { $taken += $wid }
    }

    if (-not $Id) {
        if ($existing.Count -gt 0) { $Id = Get-ZtProp $existing[0] 'id' }
    }
    if (-not $Id) { $Id = New-ZtId -Path $full -Taken $taken }

    # Tab-name collision. Two folders with the same leaf both want <leaf>, and
    # go-to-tab-name would then pick one arbitrarily - the pad would silently
    # answer the wrong session. Catch it here, where it can still be fixed,
    # rather than at 2am.
    #
    # BOTH SIDES LOST THE PREFIX IN 0.7.22. This built `claude-<leaf>` and
    # compared it to Get-ZtTabName, which has returned a bare leaf since 0.7.20 -
    # two spellings that could never be equal, so the branch stopped firing and
    # two folders sharing a leaf name quietly shared one tab with no warning.
    # The disambiguated name it assigns lost the prefix too: when this branch
    # last did fire it wrote `claude-<leaf>-<key>` into the registry, which is
    # unmatchable for the same reason and is where this machine's three bad
    # entries came from. A defect that repairs itself by writing more of itself.
    if (-not $Name) {
        $wantTab = Split-Path $full -Leaf
        foreach ($w in ($deviceWs + $sharedWs)) {
            if ((Get-ZtProp $w 'key') -eq $key) { continue }
            $otherPath = Resolve-ZtPath -Workspace $w -DeviceConfig $device
            if (-not $otherPath) { continue }
            $otherTab = Get-ZtTabName -Workspace $w -Path $otherPath -Prefix $Prefix
            if ($otherTab -eq $wantTab) {
                $Name = $wantTab + '-' + $key
                Write-Warning ("Tab name '$wantTab' is already used by '$(Get-ZtProp $w 'id')' " +
                               "($otherPath). Using '$Name' for this one instead - pass -Name to choose your own.")
                break
            }
        }
    }

    $loc = ConvertTo-ZtLocation -Path $full -DeviceConfig $device

    $entry = [pscustomobject]@{
        id      = $Id
        key     = $key
        kind    = $Kind
        command = $Command
        name    = $Name
        root    = $loc.root
        rel     = $loc.rel
        abs     = $loc.abs
        tags    = @($Tag)
    }

    if ($existing.Count -gt 0) {
        # Preserve fields the caller did not specify, so the hook re-registering
        # a workspace cannot quietly wipe the command you configured.
        $old = $existing[0]
        if (-not $PSBoundParameters.ContainsKey('Kind'))    { $entry.kind    = Get-ZtProp $old 'kind' 'claude' }
        if (-not $PSBoundParameters.ContainsKey('Command')) { $entry.command = Get-ZtProp $old 'command' }
        if (-not $PSBoundParameters.ContainsKey('Name') -and -not $Name) { $entry.name = Get-ZtProp $old 'name' }
        if (-not $PSBoundParameters.ContainsKey('Tag'))     { $entry.tags    = @(Get-ZtProp $old 'tags' @()) }
        $entry | Add-Member -NotePropertyName 'discovered' -NotePropertyValue (Get-ZtProp $old 'discovered') -Force
    } elseif ($Discovered) {
        $entry | Add-Member -NotePropertyName 'discovered' -NotePropertyValue (Get-Date).ToString('o') -Force
    }

    if (-not $PSCmdlet.ShouldProcess("device '$(Get-ZtDeviceName)'", "Register workspace '$Id' at $full")) {
        return
    }

    $kept = @($deviceWs | Where-Object { (Get-ZtProp $_ 'key') -ne $key })
    $device.workspaces = @($kept + $entry)
    Set-ZtDeviceConfig $device

    # Say the kind out loud. `zt add .` defaults to claude, and the confirmation
    # used to report only the id and path - so the one fact you could not verify
    # from the output was the one thing you had no way to specify by accident.
    # Print what will actually run, not just the kind name, because "pwsh" alone
    # does not distinguish a shell from a shell that starts a dev server.
    # Get-ZtTabName, not $entry.name - that field is only the override, empty
    # unless -Name was passed, and the derived name is what actually gets used.
    $tabName = Get-ZtTabName -Workspace $entry -Path $full -Prefix $Prefix
    $willRun = switch ($entry.kind) {
        'claude' { "claude --name $(Get-ZtSessionName -Tab $tabName -Prefix $Prefix)" }
        'pwsh'   { if ($entry.command) { $entry.command } else { 'a shell, nothing started' } }
        default  { $entry.kind }
    }

    # An update used to be Write-Verbose, i.e. silent: re-adding a registered
    # folder printed nothing at all and looked like a no-op that had failed.
    # Changing a registration is worth one line, and says what it now is.
    if ($existing.Count -gt 0) {
        Write-Host "Updated '$Id'" -ForegroundColor Green
        Write-Host ("  kind: {0,-8} -> {1}" -f $entry.kind, $willRun) -ForegroundColor DarkGray
    } else {
        Write-Host "Registered '$Id'" -ForegroundColor Green
        Write-Host "  $full" -ForegroundColor DarkGray
        Write-Host ("  kind: {0,-8} -> {1}" -f $entry.kind, $willRun) -ForegroundColor DarkGray
        if (-not $loc.root) {
            Write-Host ("  no root matches this path, so it is device-only. Define one with: " +
                        "Set-ZellijTerminalRoot <name> <path>") -ForegroundColor DarkGray
        }
    }

    # REGISTERING AND OPENING ARE ALMOST ALWAYS THE SAME INTENT the first time,
    # and they were two commands with nothing connecting them: `zt add .`
    # printed a registration and stopped, leaving "and now how do I actually
    # open it" as an exercise. So say it, always - a hint costs one line and is
    # read by the person who needs it - and offer -Start for when it is what you
    # meant.
    #
    # NOT the default. Registration is a fact about the folder and works with no
    # session attached; starting is an action that needs one, and silently
    # opening a tab because you registered something is the kind of surprise
    # this rig has no business springing. The hook calls this on EVERY session
    # start, which is the other reason: a default -Start would have it reopening
    # tabs underneath you.
    if ($Start) {
        if ($PSCmdlet.ShouldProcess($Id, 'Open its tab')) {
            Start-ZellijTerminal -Name $Id -Session $Session -Prefix $Prefix
        }
    } elseif ($existing.Count -eq 0) {
        Write-Host ("  open it with:  zt start {0}   (or -Start next time)" -f $Id) -ForegroundColor DarkGray
    }

    if ($PassThru) { return $entry }
}

function Unregister-ZellijTerminal {
    <#
    .SYNOPSIS
        Remove a workspace from the registry. Does not touch the directory.

    .DESCRIPTION
        Removes from this device's config, and from the shared config with
        -Shared. Stops it first unless -KeepRunning.

    .EXAMPLE
        zt rm api
        Unregister-ZellijTerminal api -Shared
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name,

        # Also remove it from the shared config, i.e. from every machine.
        [switch]$Shared,

        # Leave whatever is running alone.
        [switch]$KeepRunning,

        # Close the tab as well. `rm` forgets the project and leaves the tab;
        # `close` closes the tab and keeps the project. This is both, in the
        # order that works.
        [switch]$CloseTab,

        [string]$Session = 'claude',
        [string]$Prefix  = 'claude-'
    )

    $ws = Find-ZtWorkspace -Name $Name -Session $Session -Prefix $Prefix
    if (-not $ws) { return }

    $what = "Unregister '$($ws.Id)'"
    if ($Shared) { $what += ' from this device AND the shared config' }
    if (-not $PSCmdlet.ShouldProcess("registry", $what)) { return }

    if (-not $KeepRunning -and $ws.State -eq 'running') {
        Stop-ZellijTerminal -Name $ws.Id -Session $Session -Prefix $Prefix -Confirm:$false
    }

    # `rm` and `close` are easy to reach for interchangeably and do OPPOSITE
    # things, and doing them in this order used to strand the tab: the
    # registration goes, the tab stays, and `zt close` then cannot see it.
    # Say so at the moment the mistake is made rather than leaving a tab in the
    # bar that nothing addresses.
    $tabOpen = ($ws.Tab -and $ws.State -in @('running', 'tab-only', 'stale'))
    if ($tabOpen -and $CloseTab) {
        Remove-ZellijTerminalTab -Name $ws.Id -Session $Session -Prefix $Prefix -Confirm:$false
        $tabOpen = $false
    }

    $device = Get-ZtDeviceConfig
    $device.workspaces = @(@(Get-ZtProp $device 'workspaces' @()) |
        Where-Object { (Get-ZtProp $_ 'key') -ne $ws.Key })
    Set-ZtDeviceConfig $device

    if ($Shared) {
        $sh = Get-ZtSharedConfig
        $sh.workspaces = @(@(Get-ZtProp $sh 'workspaces' @()) |
            Where-Object { (Get-ZtProp $_ 'key') -ne $ws.Key })
        Set-ZtSharedConfig $sh
    }

    Remove-ZtLive $ws.Key
    Write-Host "Unregistered '$($ws.Id)'" -ForegroundColor Green

    if ($tabOpen) {
        Write-Warning ("The tab '$($ws.Tab)' is still open. 'zt rm' forgets the project; it does " +
                       "not close anything. Close it with: zt close $($ws.Tab)")
        Write-Host "  next time, both at once: zt rm $($ws.Id) -CloseTab" -ForegroundColor DarkGray
    }
}

function Publish-ZellijTerminal {
    <#
    .SYNOPSIS
        Promote a device-local workspace into the shared config, so your other
        machines see it too.

    .DESCRIPTION
        Only workspaces stored as {root, rel} can be published. An absolute path
        means nothing on another PC, so this refuses and tells you which root to
        define - failing here is much cheaper than a config that silently does
        not work on the laptop.

    .EXAMPLE
        zt publish api
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name,

        [string]$Session = 'claude',
        [string]$Prefix  = 'claude-'
    )

    $ws = Find-ZtWorkspace -Name $Name -Session $Session -Prefix $Prefix
    if (-not $ws) { return }

    $device = Get-ZtDeviceConfig
    $entry  = @(@(Get-ZtProp $device 'workspaces' @()) |
        Where-Object { (Get-ZtProp $_ 'key') -eq $ws.Key })

    if ($entry.Count -eq 0) {
        Write-Warning "'$($ws.Id)' is already shared, or is not registered on this device."
        return
    }
    $e = $entry[0]

    if (-not (Get-ZtProp $e 'root')) {
        Write-Error ("'$($ws.Id)' is stored as an absolute path ($($ws.Path)), which means nothing " +
                     "on another machine. Define a root that contains it first, e.g. " +
                     "Set-ZellijTerminalRoot code '$(Split-Path $ws.Path -Parent)', then re-register it.")
        return
    }

    if (-not $PSCmdlet.ShouldProcess('shared config', "Publish '$($ws.Id)'")) { return }

    $sh   = Get-ZtSharedConfig
    $rest = @(@(Get-ZtProp $sh 'workspaces' @()) | Where-Object { (Get-ZtProp $_ 'key') -ne $ws.Key })

    # 'discovered' is a device-local fact about how the entry got here; it has
    # no meaning once shared.
    $pub = [pscustomobject]@{
        id      = Get-ZtProp $e 'id'
        key     = Get-ZtProp $e 'key'
        kind    = Get-ZtProp $e 'kind' 'claude'
        command = Get-ZtProp $e 'command'
        name    = Get-ZtProp $e 'name'
        root    = Get-ZtProp $e 'root'
        rel     = Get-ZtProp $e 'rel'
        tags    = @(Get-ZtProp $e 'tags' @())
    }
    $sh.workspaces = @($rest + $pub)
    Set-ZtSharedConfig $sh

    # Keep the device copy out of the way so the merged view has one source.
    $device.workspaces = @(@(Get-ZtProp $device 'workspaces' @()) |
        Where-Object { (Get-ZtProp $_ 'key') -ne $ws.Key })
    Set-ZtDeviceConfig $device

    Write-Host "Published '$($ws.Id)' as $($pub.root)\$($pub.rel)" -ForegroundColor Green
    Write-Host '  commit config/ to see it on your other machines' -ForegroundColor DarkGray
}

function Set-ZellijTerminalRoot {
    <#
    .SYNOPSIS
        Define what a root name means on this device.

    .DESCRIPTION
        Roots are how one shared config works across machines with different
        drive letters: the shared entry says {root: 'code', rel: 'api'}, and
        each device decides where 'code' is.

    .EXAMPLE
        Set-ZellijTerminalRoot code C:\code
        Set-ZellijTerminalRoot code C:\dev      # on the laptop
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Name,
        [Parameter(Mandatory = $true, Position = 1)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "Path does not exist on this device: $Path"
    }

    if (-not $PSCmdlet.ShouldProcess("device '$(Get-ZtDeviceName)'", "Set root '$Name' = $Path")) { return }

    $device = Get-ZtDeviceConfig
    $roots  = Get-ZtProp $device 'roots'
    if (-not $roots) { $roots = [pscustomobject]@{} }
    $roots | Add-Member -NotePropertyName $Name -NotePropertyValue $Path -Force
    $device | Add-Member -NotePropertyName 'roots' -NotePropertyValue $roots -Force
    Set-ZtDeviceConfig $device

    Write-Host "Root '$Name' -> $Path" -ForegroundColor Green
}

function Get-ZellijTerminalRoot {
    <#
    .SYNOPSIS
        Show this device's root definitions.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $device = Get-ZtDeviceConfig
    $roots  = Get-ZtProp $device 'roots'
    # `return`, not `return @()`: an empty array is itself an object, so the
    # latter makes the declared OutputType a lie for the no-roots case.
    if (-not $roots) { return }

    $out = @()
    foreach ($p in $roots.PSObject.Properties) {
        $out += [pscustomobject]@{
            Name   = $p.Name
            Path   = $p.Value
            Exists = (Test-Path -LiteralPath $p.Value)
            Device = Get-ZtDeviceName
        }
    }
    return $out
}


