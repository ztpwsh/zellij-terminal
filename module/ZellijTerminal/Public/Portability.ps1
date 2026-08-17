<#
    Portability - take your setup somewhere else, and get it back.

    Two things made this necessary rather than nice.

    First, `zt uninstall -Purge` destroys the registrations, and a registration
    list is real work: paths, kinds, commands, tab-name overrides for the two
    projects that share a leaf name. Losing that to a reinstall is how people
    stop reinstalling.

    Second, the second machine. The registry already splits definitions into
    {root, rel} so a project can live on C: here and F: there, but nothing
    carried that across - you re-registered everything by hand and hoped you
    remembered the -Kind and -Command arguments.

    WHAT TRAVELS
      workspace registrations (this device's, and the shared list)
      root definitions
      Command Palette dock bands, command hotkeys and aliases - ours only

    WHAT DOES NOT, AND WHY
      Live state. Which tabs are open and which session is waiting describes a
      moment on one machine; importing it elsewhere would invent workspaces that
      are running when nothing is.

      Keyboard Manager remaps. They contain absolute paths to this clone and are
      rewritten by `zt pad install` in a second, so carrying them would only
      import a set of broken ones. The export records THAT the pad was set up,
      so the import can tell you to run one command.
#>

function Get-ZtPaletteState {
    <#
        Ours, and only ours, out of Command Palette's settings.

        That file is the whole application's configuration - theme, backdrop,
        every provider's settings, the user's own aliases and pinned commands.
        Exporting it wholesale would mean importing somebody's wallpaper along
        with their dock band, and would overwrite settings this rig never set.
        So each collection is filtered to entries naming ZellijTerminal.
    #>
    $path = Get-ZtCmdPalSettingsPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    $s = $null
    try { $s = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { return $null }
    if (-not $s) { return $null }

    $mine = { param($x) ("$x" -match 'ZellijTerminal|zt\.') }

    $bands = @()
    $dock = Get-ZtProp $s 'DockSettings'
    if ($dock) {
        $items = Get-ZtProp $dock 'Bands' @()
        $bands = @($items | Where-Object { & $mine ($_ | ConvertTo-Json -Depth 6 -Compress) })
    }

    $hotkeys = @(Get-ZtProp $s 'CommandHotkeys' @() |
                 Where-Object { & $mine ($_ | ConvertTo-Json -Depth 6 -Compress) })

    $aliases = @(Get-ZtProp $s 'Aliases' @() |
                 Where-Object { & $mine ($_ | ConvertTo-Json -Depth 6 -Compress) })

    if ($bands.Count -eq 0 -and $hotkeys.Count -eq 0 -and $aliases.Count -eq 0) { return $null }

    return [pscustomobject]@{
        dockBands      = $bands
        commandHotkeys = $hotkeys
        aliases        = $aliases
    }
}

function Export-ZellijTerminal {
    <#
    .SYNOPSIS
        Write your registrations, roots and Command Palette setup to one file.

    .DESCRIPTION
        A portable bundle you can commit, copy to another machine, or keep as a
        backup before something destructive.

        Workspaces defined as {root, rel} travel properly: the other machine
        resolves them against its own root definitions. Ones stored as an
        absolute path can only be device-only, and the export says how many of
        those there are rather than letting you find out on import.

    .EXAMPLE
        zt export
        zt export C:\backup\zt-2026-08-15.json
        zt export -NoPalette
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param(
        # Where to write it. Defaults to zt-export-<device>.json here.
        [Parameter(Position = 0)]
        [string]$Path,

        # Leave the Command Palette dock, hotkeys and aliases out.
        [switch]$NoPalette,

        # Emit the bundle object instead of only writing the file.
        [switch]$PassThru
    )

    $device = Get-ZtDeviceConfig
    $shared = Get-ZtSharedConfig

    $deviceWs = @(Get-ZtProp $device 'workspaces' @())
    $sharedWs = @(Get-ZtProp $shared 'workspaces' @())

    if (-not $Path) {
        $Path = Join-Path (Get-Location).Path ("zt-export-$(Get-ZtDeviceName).json")
    }

    $bundle = [pscustomobject]@{
        schema     = 1
        exportedAt = (Get-Date).ToString('o')
        fromDevice = Get-ZtDeviceName
        ztVersion  = "$((Get-Module ZellijTerminal).Version)"
        roots      = Get-ZtProp $device 'roots'
        workspaces = $deviceWs
        shared     = $sharedWs
        # Not the remaps themselves - see the note at the top of this file.
        padWasSetUp = (@(Get-ZtKbmGlobal (Get-ZtKbmConfig) | Where-Object { Test-ZtKbmOurs $_ }).Count -gt 0)
        palette     = $(if ($NoPalette) { $null } else { Get-ZtPaletteState })
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Write the export bundle')) { return }

    Write-ZtJson $Path $bundle

    $portable = @($deviceWs | Where-Object { Get-ZtProp $_ 'root' }).Count
    $deviceOnly = $deviceWs.Count - $portable

    Write-Host ''
    Write-Host "  Exported to $Path" -ForegroundColor Green
    Write-Host ("    {0,-3} workspace(s) on this device" -f $deviceWs.Count) -ForegroundColor DarkGray
    if ($sharedWs.Count -gt 0) { Write-Host ("    {0,-3} shared" -f $sharedWs.Count) -ForegroundColor DarkGray }
    Write-Host ("    {0,-3} root definition(s)" -f @(Get-ZtProp $device 'roots' | ForEach-Object { $_.PSObject.Properties }).Count) -ForegroundColor DarkGray
    if ($bundle.palette) {
        Write-Host ("    {0,-3} dock band(s), {1} hotkey(s), {2} alias(es) from Command Palette" -f
            @($bundle.palette.dockBands).Count, @($bundle.palette.commandHotkeys).Count,
            @($bundle.palette.aliases).Count) -ForegroundColor DarkGray
    }

    # Said at export time, while you can still define a root, rather than as a
    # surprise on the machine that cannot resolve them.
    if ($deviceOnly -gt 0) {
        Write-Host ''
        Write-Host ("  $deviceOnly workspace(s) are stored as absolute paths, so they will only") -ForegroundColor Yellow
        Write-Host ('  import onto a machine with the same drive layout. Define a root for them') -ForegroundColor Yellow
        Write-Host ('  and re-register to make them portable:  zt root <name> <path>') -ForegroundColor Yellow
    }
    Write-Host ''

    if ($PassThru) { return $bundle }
    return $Path
}

function Import-ZellijTerminal {
    <#
    .SYNOPSIS
        Merge an exported bundle into this device.

    .DESCRIPTION
        Adds what is missing and leaves what is already here alone, so importing
        the same file twice does nothing the second time. -Force overwrites
        entries that already exist.

        Reports which imported workspaces this machine cannot actually reach and
        exactly what would fix each one, rather than importing them silently and
        letting `zt` show a column of `unavailable`.

    .EXAMPLE
        zt import zt-export-DESKTOP.json -WhatIf
        zt import zt-export-DESKTOP.json
        zt import zt-export-DESKTOP.json -Force
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path,

        # Overwrite registrations and roots that already exist here.
        [switch]$Force,

        # Skip the Command Palette part.
        [switch]$NoPalette
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error "No such file: $Path"
        return
    }

    $bundle = $null
    try { $bundle = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch {
        Write-Error "Not valid JSON: $Path"
        return
    }

    $schema = Get-ZtProp $bundle 'schema' 0
    if ($schema -ne 1) {
        Write-Error ("This is schema $schema; this version understands 1. " +
                     'Export it again from a matching version of zt.')
        return
    }

    Write-Host ''
    Write-Host ("  From $(Get-ZtProp $bundle 'fromDevice' '?'), exported $(Get-ZtProp $bundle 'exportedAt' '?')") -ForegroundColor DarkGray
    Write-Host ''

    $device   = Get-ZtDeviceConfig
    $existing = @(Get-ZtProp $device 'workspaces' @())
    $roots    = Get-ZtProp $device 'roots'
    if (-not $roots) { $roots = [pscustomobject]@{} }

    # --- roots first: workspaces resolve against them -----------------------
    $rootsAdded = 0
    $incomingRoots = Get-ZtProp $bundle 'roots'
    if ($incomingRoots) {
        foreach ($p in $incomingRoots.PSObject.Properties) {
            $have = Get-ZtProp $roots $p.Name
            if ($have -and -not $Force) {
                Write-Host ("    root '$($p.Name)' already defined here as $have - kept") -ForegroundColor DarkGray
                continue
            }
            # Deliberately NOT validated against Test-Path. The other machine's
            # path may be right and simply not mounted yet, and refusing to
            # import it would make the fix harder rather than easier.
            if ($PSCmdlet.ShouldProcess("root '$($p.Name)'", "Define as $($p.Value)")) {
                $roots | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
                $rootsAdded++
            }
        }
    }

    # --- workspaces ---------------------------------------------------------
    $added = 0; $skipped = 0; $updated = 0
    $keys = @($existing | ForEach-Object { Get-ZtProp $_ 'key' })

    foreach ($w in @(Get-ZtProp $bundle 'workspaces' @())) {
        $k  = Get-ZtProp $w 'key'
        $id = Get-ZtProp $w 'id' '?'
        if ($keys -contains $k) {
            if (-not $Force) { $skipped++; continue }
            $existing = @($existing | Where-Object { (Get-ZtProp $_ 'key') -ne $k })
            $updated++
        } else {
            $added++
        }
        if ($PSCmdlet.ShouldProcess("workspace '$id'", 'Register on this device')) {
            $existing += $w
            $keys     += $k
        }
    }

    if ($PSCmdlet.ShouldProcess((Get-ZtDevicePath), 'Save the device registry')) {
        $device | Add-Member -NotePropertyName 'roots'      -NotePropertyValue $roots     -Force
        $device | Add-Member -NotePropertyName 'workspaces' -NotePropertyValue @($existing) -Force
        Set-ZtDeviceConfig $device
    }

    Write-Host ("  {0} added, {1} updated, {2} already here, {3} root(s) defined" -f
        $added, $updated, $skipped, $rootsAdded) -ForegroundColor Green

    # --- what this machine still cannot reach -------------------------------
    # The point of the whole exercise. An import that quietly produces a list of
    # `unavailable` rows has told you nothing you can act on.
    $unreachable = @()
    foreach ($w in @(Get-ZtProp $bundle 'workspaces' @())) {
        $resolved = Resolve-ZtPath -Workspace $w -DeviceConfig $device
        if (-not $resolved -or -not (Test-Path -LiteralPath $resolved)) {
            $unreachable += [pscustomobject]@{
                Id   = Get-ZtProp $w 'id' '?'
                Root = Get-ZtProp $w 'root'
                Rel  = Get-ZtProp $w 'rel'
                Abs  = Get-ZtProp $w 'abs'
            }
        }
    }
    if ($unreachable.Count -gt 0) {
        Write-Host ''
        Write-Host "  $($unreachable.Count) cannot be reached on this machine yet:" -ForegroundColor Yellow
        foreach ($u in $unreachable) {
            if ($u.Root) {
                Write-Host ("    {0,-20} needs root '{1}'  ->  zt root {1} <path>" -f $u.Id, $u.Root) -ForegroundColor DarkGray
            } else {
                Write-Host ("    {0,-20} absolute path not present here: {1}" -f $u.Id, $u.Abs) -ForegroundColor DarkGray
            }
        }
    }

    # --- palette and pad ----------------------------------------------------
    $pal = Get-ZtProp $bundle 'palette'
    if ($pal -and -not $NoPalette) {
        Write-Host ''
        Write-Host ("  Command Palette: {0} dock band(s), {1} hotkey(s), {2} alias(es) in the bundle." -f
            @($pal.dockBands).Count, @($pal.commandHotkeys).Count, @($pal.aliases).Count) -ForegroundColor DarkGray
        # Not written directly. Command Palette holds this file open and writes
        # it on exit, so an edit underneath a running palette is discarded - the
        # same trap as killing it to force a settings read. The commands below
        # go through the palette instead.
        Write-Host '    Apply with:  zt dock        (pin the band)' -ForegroundColor DarkGray
        Write-Host '                 zt hotkeys     (see what it expects)' -ForegroundColor DarkGray
        Write-Host '    Command Palette rewrites its settings on exit, so these are not' -ForegroundColor DarkGray
        Write-Host '    written underneath it.' -ForegroundColor DarkGray
    }

    if ((Get-ZtProp $bundle 'padWasSetUp' $false) -and
        @(Get-ZtKbmGlobal (Get-ZtKbmConfig) | Where-Object { Test-ZtKbmOurs $_ }).Count -eq 0) {
        Write-Host ''
        Write-Host '  The pad was set up on that machine. The remaps hold absolute paths,' -ForegroundColor DarkGray
        Write-Host '  so they are not imported - wire this one up with:  zt pad install' -ForegroundColor DarkGray
    }

    Write-Host ''
}
