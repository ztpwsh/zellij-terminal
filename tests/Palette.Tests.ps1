<#
    Palette - the agreement between the C# extension and the PowerShell module.

    ZtStore.cs says it out loud: "This is the second consumer of that format, so
    the shape is now load-bearing in two languages." Nothing checked it. The
    module can rename a field in config\devices\<DEVICE>.json or in a live
    record and every PowerShell test stays green, because the half that breaks
    is a .cs file the suite never reads. The break is silent in the worst way -
    the palette lists a workspace with an empty path and no state, which reads
    as "not registered" rather than as "the two sides disagree".

    THESE ARE SOURCE-LEVEL ASSERTIONS. Every one of them is Select-String over
    a .cs or .csproj file. They prove that a name, a constant or a guard is
    still written in the source; they do NOT run the extension, do not
    instantiate a type and cannot prove any of it compiles. `dotnet build` in
    CI is what proves it compiles, and a build is the only thing that should
    ever be quoted as evidence of that. What this file buys is the one thing a
    build cannot notice: that both languages still spell the contract the same
    way.

    Runs anywhere. No Zellij, no session, no .NET SDK, no packaged extension -
    it reads tracked text files. The one Context that imports the module is
    skipped if the manifest is not there.

    Pester 5/6.
#>

# Discovery scope: Pester evaluates -Skip while discovering, before any
# BeforeAll has run, so the file checks have to be settled out here.
$RepoRoot   = Split-Path -Parent $PSScriptRoot
$PaletteDir = Join-Path $RepoRoot (Join-Path 'cmdpal' 'ZellijTerminal.Palette')

# All four are tracked files, so absence means this is not a full checkout - a
# vendored copy, or an extracted zip of the module alone. Skip rather than
# fail: there is nothing wrong with the code in that case.
$HasSources = @(
    (Join-Path $PaletteDir 'ZtStore.cs'),
    (Join-Path $PaletteDir 'Commands.cs'),
    (Join-Path $PaletteDir 'ZtCli.cs'),
    (Join-Path $PaletteDir 'WorkspacesPage.cs')
) | ForEach-Object { Test-Path -LiteralPath $_ -PathType Leaf }
$HasSources = ($HasSources -notcontains $false)

$ManifestPath = Join-Path $RepoRoot (Join-Path 'module' (Join-Path 'ZellijTerminal' 'ZellijTerminal.psd1'))
$HasModule    = Test-Path -LiteralPath $ManifestPath -PathType Leaf

Describe 'Command Palette extension - contract with the module' -Skip:(-not $HasSources) {

    BeforeAll {
        $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
        $script:PaletteDir = Join-Path $script:RepoRoot (Join-Path 'cmdpal' 'ZellijTerminal.Palette')

        function Get-Source {
            param([string]$Name)
            return (Get-Content -LiteralPath (Join-Path $script:PaletteDir $Name) -Raw -ErrorAction Stop)
        }

        $script:ZtStore        = Get-Source 'ZtStore.cs'
        $script:CommandsSource = Get-Source 'Commands.cs'
        $script:ZtCliSource    = Get-Source 'ZtCli.cs'
        $script:PageSource     = Get-Source 'WorkspacesPage.cs'
        $script:Csproj         = Get-Source 'ZellijTerminal.Palette.csproj'
        $script:ProviderSource = Get-Source 'Provider.cs'
        $script:ConfigSource   = Get-Source 'ConfigPage.cs'
        $script:ZellijCliSource = Get-Source 'ZellijCli.cs'

        # Everything the palette can invoke, in one string. Which FILE a verb
        # lives in is an implementation detail that has already moved once.
        $script:AllPalette = $script:CommandsSource + $script:PageSource +
                             $script:ProviderSource + $script:ConfigSource

        $script:CoreSource = Get-Content -Raw -ErrorAction SilentlyContinue -LiteralPath (
            Join-Path $script:RepoRoot (Join-Path 'module' (Join-Path 'ZellijTerminal' (Join-Path 'Private' 'Core.ps1'))))

        # The positional parameters of the record, in order. Parsed rather than
        # hard-coded so a field that is renamed shows up as a missing name here
        # instead of as a test that still passes against a stale copy.
        $script:RecordFields = @()
        $match = [regex]::Match($script:ZtStore, '(?s)record\s+ZtWorkspace\s*\((.*?)\)\s*;')
        if ($match.Success) {
            $script:RecordFields = @(
                $match.Groups[1].Value -split ',' |
                    ForEach-Object {
                        $parts = @($_.Trim() -split '\s+' | Where-Object { $_ })
                        if ($parts.Count -gt 0) { $parts[-1] }
                    }
            )
        }
    }

    Context 'The workspace record' {

        It 'parses as a positional record, or nothing below means anything' {
            # Every field assertion in this Context reads $RecordFields, and an
            # empty list would make all of them vacuously true.
            $script:RecordFields.Count | Should -BeGreaterThan 0 -Because (
                'the ZtWorkspace record declaration could not be found in ZtStore.cs, ' +
                'so the field checks below are not testing anything')
        }

        It 'declares a field for each stored value the palette has to show' {
            # These are the names the module writes: id, key, kind and the tags
            # in config\devices\<DEVICE>.json; tab and sessionId in a live
            # record; path derived from root+rel or abs. PowerShell property
            # names are PascalCase and the JSON is camelCase, so -contains is
            # doing the case-insensitive comparison the two conventions need.
            $expected = @('Id', 'Key', 'Kind', 'Tab', 'Path', 'SessionId')
            $missing  = @($expected | Where-Object { $script:RecordFields -notcontains $_ })

            $missing.Count | Should -Be 0 -Because (
                'ZtStore builds these from the registry the module writes, and a name that ' +
                "does not line up reads as an empty column in the palette: $($missing -join ', ')")
        }

        It 'declares the three values it derives rather than reads' {
            # State, Waiting and WaitEvent are computed from live Zellij and the
            # flag files, exactly as Get-ZtWorkspaceRecords computes them. They
            # are in the record because the list draws them, not because they
            # are in any file.
            $expected = @('State', 'Waiting', 'WaitEvent')
            $missing  = @($expected | Where-Object { $script:RecordFields -notcontains $_ })

            $missing.Count | Should -Be 0 -Because (
                "the page's tags and details are built from these: $($missing -join ', ')")
        }

        It 'carries no Command field, so a configured command is invisible to the palette' {
            # Recorded as it is, not as it ought to be. The module writes a
            # 'command' field on every entry (Registry.ps1) and surfaces it as
            # .Command; ZtStore never reads it and the record has no room for
            # it. Harmless today because Start-ZellijTerminal runs the command
            # and the palette only ever calls the verb - but anything in the
            # palette that wants to SHOW what a row will run has to add the
            # field on both sides first.
            $script:RecordFields | Should -Not -Contain 'Command'
        }

        It 'carries no Name field either - the override is folded into Tab' {
            # 'name' in the JSON is the tab-name override, and ZtStore applies
            # it while building Tab rather than keeping it separately. Same
            # answer as Get-ZtTabName, reached without a second field.
            $script:RecordFields | Should -Not -Contain 'Name'
            $script:ZtStore | Should -Match ([regex]::Escape('var tab = Str(def, "name");')) -Because (
                'the override has to be read from somewhere if it is not a field')
        }
    }

    Context 'The JSON field names' {

        It 'reads every registry field it needs by the name the module writes' {
            # Registry.ps1 writes id, key, kind, command, name, root, rel, abs,
            # tags. These are the ones the palette actually consumes; command
            # and tags it ignores (see the record tests above).
            $needed  = @('id', 'kind', 'name', 'root', 'rel', 'abs')
            $missing = @($needed | Where-Object { $script:ZtStore -notmatch [regex]::Escape("Str(def, `"$_`"") })

            $missing.Count | Should -Be 0 -Because (
                'a field the module writes and the palette spells differently is read as empty, ' +
                "and an empty root means the workspace silently reports unavailable: $($missing -join ', ')")

            # key is read a step earlier, while walking the workspaces array
            # rather than while building a row - it is what an entry is matched
            # to its live record by, so an entry without one is skipped outright.
            $script:ZtStore | Should -Match ([regex]::Escape('Str(w, "key")'))
        }

        It 'reads every live-record field by the name Set-ZtLive writes' {
            # Set-ZtLive writes key, cwd, tab, kind, sessionId, zjSession,
            # startedAt, lastEvent. The palette uses the first five; sessionId
            # is the one that matters most, because it is what the details pane
            # offers as "restart resumes this".
            $needed  = @('cwd', 'tab', 'kind', 'sessionId')
            $missing = @($needed | Where-Object { $script:ZtStore -notmatch [regex]::Escape("Str(live, `"$_`"") })

            $missing.Count | Should -Be 0 -Because (
                "these come from %LOCALAPPDATA%\ZellijTerminal\live\<key>.json: $($missing -join ', ')")

            $script:ZtStore | Should -Match ([regex]::Escape('Str(n, "key")')) -Because (
                'a live file is indexed by its key, which has to be read out of the record itself'
            )
        }

        It 'reads the waiting flag by the names the hook writes, from the directory the hook writes them to' {
            $script:ZtStore | Should -Match ([regex]::Escape('"claude-zellij-flags"'))
            $script:ZtStore | Should -Match ([regex]::Escape('flag?["waiting"]'))
            $script:ZtStore | Should -Match ([regex]::Escape('Str(flag, "event"'))
        }

        It 'looks for the two config files where the module puts them' {
            # Get-ZtSharedPath and Get-ZtDevicePath, spelled out in C#. The
            # device file is named after COMPUTERNAME on the PowerShell side and
            # Environment.MachineName here, which are the same string.
            #
            # The two files live in DIFFERENT places and that is deliberate:
            # workspaces.json is committed source and ships with the clone,
            # while the device registry is state this machine writes and so
            # belongs outside any working tree. Reading the device file from
            # the clone is the bug this pins down - it put the registry in a
            # directory that a publish empties.
            $script:ZtStore | Should -Match ([regex]::Escape('"config", "workspaces.json"'))
            $script:ZtStore | Should -Match ([regex]::Escape('"devices", Environment.MachineName + ".json"'))

            $script:ZtStore | Should -Not -Match ([regex]::Escape('"config", "devices"')) -Because (
                'the device registry must not be read out of the clone')
        }

        It 'can reach <Verb>, which the module exposes' -ForEach @(
            @{ Verb = 'Sync-ZellijTerminal';          Why = 'the details pane tells you to run zt sync for a stale workspace' }
            @{ Verb = 'Publish-ZellijTerminal';       Why = 'promoting a registration to the shared list' }
            @{ Verb = 'Edit-ZellijTerminalConfig';    Why = 'opening the registry JSON' }
            @{ Verb = 'Test-ZellijTerminalConfig';    Why = 'checking it after a hand edit' }
            @{ Verb = 'Export-ZellijTerminal';        Why = 'moving the registry to another machine' }
            @{ Verb = 'Import-ZellijTerminal';        Why = 'receiving it on the other machine' }
            @{ Verb = 'Set-ZellijTerminalRoot';       Why = 'an undefined root is why a workspace reads unavailable' }
            @{ Verb = 'Get-ZellijTerminalRoot';       Why = 'seeing where this device thinks its roots are' }
        ) {
            # The palette lagged the module by eight verbs, which nothing could
            # see: both sides were internally consistent and no test compared
            # them. A gap here is not a crash, it is a capability that quietly
            # only exists in the shell.
            $script:AllPalette | Should -Match ([regex]::Escape($Verb)) -Because $Why
        }

        It 'gives any command that waits for a person a window to wait in' {
            # The first draft of this test scanned for `visible: true` near each
            # Read-Host and was wrong twice over - it matched its own explanatory
            # comment, and the flag sits lines away from the string in a
            # multi-line argument list. That is the tell that it was the wrong
            # thing to assert: the rule does not belong in a text search over
            # call sites, it belongs in the constructor, where it cannot be
            # forgotten by the next command somebody adds.
            #
            # So the assertion is that the enforcement exists, not that every
            # call site remembered.
            $script:CommandsSource | Should -Match ([regex]::Escape('command.Contains("Read-Host"')) -Because (
                'a command that blocks on Read-Host must get a console whether or not the caller asked')
            $script:ZtCliSource | Should -Match 'CreateNoWindow = !visible' -Because (
                'and the visible flag has to actually reach ProcessStartInfo')
        }

        It 'logs every action with its exit code' {
            # The action path was invisible by construction - CreateNoWindow
            # plus catch { } - and two verbs were dead for a day behind a
            # cheerful toast. The log is the only place a packaged extension can
            # say "I could not start pwsh".
            $script:ZtCliSource | Should -Match 'palette\.log'
            $script:ZtCliSource | Should -Match ([regex]::Escape('proc.ExitCode')) -Because (
                'an exit code separates "never ran" from "ran and refused"')
            $script:ZtCliSource | Should -Not -Match '(?m)catch\s*\{\s*/\*[^*]*\*/\s*\}\s*$' -Because (
                'the bare catch on the start path is what hid the original failure')
        }

        It 'resolves the device registry the same way the module does' {
            # Get-ZtConfigHome: the override wins, otherwise LocalApplicationData
            # \ZellijTerminal. Two implementations of one rule, so the names have
            # to match exactly or the palette and `zt` disagree about which
            # registry is real - and the palette cannot report that it did.
            $script:ZtStore | Should -Match ([regex]::Escape('"ZT_CONFIG_HOME"')) -Because (
                'the module honours $env:ZT_CONFIG_HOME and both must agree')
            $script:ZtStore | Should -Match ([regex]::Escape('SpecialFolder.LocalApplicationData')) -Because (
                'the default is %LOCALAPPDATA%\ZellijTerminal, beside live\ and root.txt')
        }

        It 'finds the repo by the marker the module leaves, not by walking up' {
            # A packaged extension lives in Program Files\WindowsApps and has no
            # relationship to the clone, so Set-ZtRootMarker exists purely for
            # this reader. Both sides have to agree on the file name.
            $script:ZtStore | Should -Match ([regex]::Escape('"ZellijTerminal", "root.txt"'))
            $script:ZtStore | Should -Match ([regex]::Escape('"scripts", "zj-claude-project.ps1"')) -Because (
                'Test-ZtRoot recognises a checkout by that same file')
        }
    }

    Context 'The tab prefix' {

        It 'declares the claude- prefix as a constant' {
            $script:ZtStore | Should -Match ([regex]::Escape('private const string TabPrefix = "claude-";'))
        }

        It 'strips that same prefix to name an unregistered tab' {
            # Get-ZtWorkspaceRecords does the same with a regex. Both produce
            # 'api' from 'claude-api', and both list the tab rather than hiding
            # it - a tab made by hand is still real.
            $script:ZtStore | Should -Match ([regex]::Escape('tab.StartsWith(TabPrefix'))
            $script:ZtStore | Should -Match ([regex]::Escape('tab[TabPrefix.Length..]'))
            $script:ZtStore | Should -Match '"unregistered"'
        }

        It 'derives the same tab name as the module, with no prefix' -Skip:(-not $HasModule) {
            # The only assertion in this file that runs both sides. Get-ZtTabName
            # is pure, so this needs no Zellij and no config.
            #
            # Since 0.7.20 the answer is the bare leaf on both sides. The C#
            # constant survives ONLY as the legacy spelling to recognise, so this
            # no longer checks that the constant is the front of the derived
            # name - it checks the opposite, that it is not.
            $manifest = Join-Path $script:RepoRoot (Join-Path 'module' (Join-Path 'ZellijTerminal' 'ZellijTerminal.psd1'))
            Import-Module $manifest -Force -ErrorAction Stop
            try {
                $m = Get-Module ZellijTerminal
                $tab = & $m { Get-ZtTabName -Workspace $null -Path 'C:\code\api' }
                $tab | Should -Be 'api'

                $constant = [regex]::Match($script:ZtStore, 'TabPrefix\s*=\s*"([^"]*)"').Groups[1].Value
                $constant | Should -Not -BeNullOrEmpty -Because 'it still has to recognise an old tab'
                $tab      | Should -Not -BeLike ($constant + '*')

                # And both sides still agree on what an OLD tab reduces to.
                (& $m { Get-ZtSessionName -Tab 'claude-api' }) | Should -Be 'api'
            } finally {
                Remove-Module ZellijTerminal -Force -ErrorAction SilentlyContinue
            }
        }

        It 'invokes nothing the module cannot answer' -Skip:(-not $HasModule) {
            # The hand-written list above names EIGHT verbs somebody decided to
            # check. This reads every module command the palette actually calls
            # out of the C# and checks all of them, including the named
            # parameters - so a renamed parameter is caught, not just a renamed
            # command, and a call added to the palette next year is covered
            # without anybody remembering to add a row here.
            #
            # A break is silent by construction: the palette starts pwsh, pwsh
            # fails, and the palette redraws the list. There is no error anyone
            # sees except a line in palette.log saying a non-zero exit.
            $all = ''
            foreach ($f in (Get-ChildItem -LiteralPath $script:PaletteDir -Filter '*.cs')) {
                $all += (Get-Content -LiteralPath $f.FullName -Raw)
            }

            $calls = @([regex]::Matches($all, '"((?:Get|Set|New|Remove|Start|Stop|Restart|Test|Connect|Publish|Import|Export|Sync|Edit|Switch|Suspend|Resume|Unregister|Register)-ZellijTerminal[A-Za-z]*)((?:\s+-[A-Za-z]+(?::\$?[A-Za-z0-9]+)?)*)') |
                        ForEach-Object { @{ Name = $_.Groups[1].Value; Args = $_.Groups[2].Value } })

            $calls.Count | Should -BeGreaterThan 10 -Because (
                'if the extraction matches nothing this test passes having checked nothing')

            $manifest = Join-Path $script:RepoRoot (Join-Path 'module' (Join-Path 'ZellijTerminal' 'ZellijTerminal.psd1'))
            Import-Module $manifest -Force -ErrorAction Stop
            $problems = @()
            try {
                foreach ($call in $calls) {
                    $cmd = Get-Command $call.Name -ErrorAction SilentlyContinue
                    if (-not $cmd) { $problems += "no such command: $($call.Name)"; continue }

                    foreach ($m in [regex]::Matches($call.Args, '-([A-Za-z]+)')) {
                        $pn = $m.Groups[1].Value
                        $known = ($cmd.Parameters.Keys -contains $pn) -or
                                 @($cmd.Parameters.Values | Where-Object { $_.Aliases -contains $pn }).Count -gt 0
                        if (-not $known) { $problems += "$($call.Name) has no -$pn" }
                    }
                }
            } finally {
                Remove-Module ZellijTerminal -Force -ErrorAction SilentlyContinue
            }

            ($problems -join '; ') | Should -BeNullOrEmpty
        }

        It 'agrees with the module on the whole state vocabulary' {
            # These strings are compared against by the page (which tags rows
            # with them) and produced by the module (which the user reads in
            # `zt`). A state only one side knows about is a row that can never
            # be started or stopped.
            $states  = @('unavailable', 'running', 'tab-only', 'stale', 'stopped', 'unregistered')
            $missing = @($states | Where-Object { $script:ZtStore -notmatch [regex]::Escape("`"$_`"") })
            $missing.Count | Should -Be 0 -Because (
                "ZtStore has to be able to produce every state the module can: $($missing -join ', ')")

            if ($script:CoreSource) {
                $absent = @($states | Where-Object { $script:CoreSource -notmatch [regex]::Escape("'$_'") })
                $absent.Count | Should -Be 0 -Because (
                    "and the module has to produce every state ZtStore expects: $($absent -join ', ')")
            }
        }
    }

    Context 'The derived tab name, and the guard it makes necessary' {

        It 'derives a tab name for a workspace with a path and no tab' {
            # Mirrors Get-ZtTabName: the bare leaf whenever the override and the
            # live record have nothing to say. Without it a registered but
            # stopped workspace has no tab name at all, and Start could not be
            # matched back to the tab it creates.
            #
            # It was `TabPrefix + SafeLeaf(path)` until 0.7.20. If a prefix comes
            # back here the palette starts every stopped workspace into a tab the
            # module then cannot find.
            $script:ZtStore | Should -Match ([regex]::Escape('tab = SafeLeaf(path);'))
            $script:ZtStore | Should -Not -Match ([regex]::Escape('TabPrefix + SafeLeaf(path)'))
        }

        It 'knows which tabs are furniture, now that the prefix cannot say so' {
            # `claude-` used to exclude `home` for free, by it simply not
            # carrying one. With no prefix every tab looks adoptable, and the
            # palette would offer to register the rig's own home tab.
            $script:ZtStore | Should -Match 'NotWorkspaceTabs'
            $script:ZtStore | Should -Match '"home"'
        }

        It 'GoToCommand refuses to jump while nothing is attached' {
            # Detached, go-to-tab-name is a silent no-op that still exits 0, so
            # the palette would dismiss itself as though it had worked.
            $script:CommandsSource | Should -Match ([regex]::Escape('if (!ZellijCli.IsClientAttached())'))
        }

        It 'GoToCommand checks State before it calls GoToTab' {
            # The same silent no-op, one step further in: a non-empty Tab proves
            # nothing, because the line above hands every workspace with a path
            # a derived name whether or not the tab exists. Only running and
            # tab-only actually have one.
            $script:CommandsSource | Should -Match ([regex]::Escape('_ws.State is not ("running" or "tab-only")'))

            # Ordering, not presence. A check after the jump explains a failure
            # the user has already had.
            $guardAt = $script:CommandsSource.IndexOf('_ws.State is not')
            $callAt  = $script:CommandsSource.IndexOf('ZellijCli.GoToTab(')
            $guardAt | Should -BeGreaterThan -1
            $callAt  | Should -BeGreaterThan -1
            $guardAt | Should -BeLessThan $callAt -Because 'the guard must run before the jump it is guarding'
        }

        It 'starts the workspace instead, rather than doing nothing quietly' {
            # Selecting a stopped row means "put me in that folder". Starting is
            # what that means when the tab does not exist yet, and it is the
            # difference between a no-op and an outcome.
            $script:CommandsSource | Should -Match ([regex]::Escape('Start-ZellijTerminal'))
        }
    }

    Context 'Refreshing the list when a background command finishes' {

        It 'ZtCli.Run raises events on the process it starts' {
            # Without EnableRaisingEvents the Exited handler below never fires -
            # silently, because subscribing to it is perfectly legal.
            $script:ZtCliSource | Should -Match ([regex]::Escape('EnableRaisingEvents = true'))
        }

        It 'ZtCli.Run refreshes the page when the command exits' {
            # A successful add left the list unchanged, which reads as failure:
            # the write lands long after Invoke() returned its toast, and until
            # this nothing re-queried. Fire-and-forget is deliberate - Register
            # a folder puts up a folder dialog - so the refresh has to be hung
            # off Exited rather than done inline.
            $script:ZtCliSource | Should -Match ([regex]::Escape('proc.Exited +='))
            $script:ZtCliSource | Should -Match ([regex]::Escape('WorkspacesPage.RequestRefresh();'))
        }

        It 'WorkspacesPage offers something for that handler to call' {
            $script:PageSource | Should -Match ([regex]::Escape('internal static void RequestRefresh()'))
            $script:PageSource | Should -Match ([regex]::Escape('RaiseItemsChanged(0)'))
            $script:PageSource | Should -Match ([regex]::Escape('internal static WorkspacesPage? Current')) -Because (
                'a static handler needs a way to reach the live page')
        }

        It 'the store cache is short enough that the refresh sees the new file' {
            # Two seconds. A pwsh start plus a folder dialog is far longer, so
            # the refresh always reads the registry rather than the cache. A
            # longer window here would put the "add did nothing" bug back
            # without touching either of the tests above.
            $script:ZtStore | Should -Match ([regex]::Escape('CacheFor = TimeSpan.FromSeconds(2)'))
        }
    }

    Context 'The project as it is packaged' {

        It 'enables nullable reference types' {
            # ZtStore returns string? from FindRoot and leans on the compiler to
            # make every caller deal with it. With Nullable off those warnings
            # disappear and the null path stops being checked at all.
            $script:Csproj | Should -Match ([regex]::Escape('<Nullable>enable</Nullable>'))
        }

        It 'builds for x64' {
            # Command Palette loads the extension in-process, so the
            # architecture has to match. arm64 is configured alongside it; only
            # x64 is asserted here because that is the one this is built and
            # packaged on.
            $script:Csproj | Should -Match '<Platforms>[^<]*\bx64\b'
            $script:Csproj | Should -Match '<RuntimeIdentifiers>[^<]*\bwin-x64\b'
        }

        It 'does not send -NonInteractive to a command a person has to answer' {
            # -NonInteractive was added unconditionally and quietly disabled
            # every visible command: under it Read-Host does not prompt, it
            # errors and CARRIES ON. So the trailing "Read-Host 'enter to close'"
            # returned instantly and the console was destroyed before anything
            # could be read - the exact failure RunVisible exists to fix - and
            # "Define a root", which is two Read-Host prompts, could never
            # collect anything while still exiting 0.
            #
            # Asserted as the GUARD, not the absence of the string: the flag is
            # still correct for hidden commands, where nothing can answer.
            $script:ZtCliSource | Should -Match 'if\s*\(!visible\)\s*psi\.ArgumentList\.Add\("-NonInteractive"\)'

            $bare = @([regex]::Matches($script:ZtCliSource, 'ArgumentList\.Add\("-NonInteractive"\)')).Count
            $bare | Should -Be 1 -Because 'the flag must be added in exactly one place, behind the visibility test'
        }

        It 'does not redirect a stream nobody reads' {
            # Redirecting stderr while only ever reading stdout is how a child
            # deadlocks: zellij fills the stderr pipe, blocks, never exits, and
            # ReadToEnd never returns - so the timeout on the following line
            # could not fire, because control never reached it.
            $script:ZellijCliSource | Should -Match 'RedirectStandardError\s*=\s*false'
        }

        It 'waits for zellij before reading its output' {
            # WaitForExit must come first for the timeout to mean anything.
            $waitAt = $script:ZellijCliSource.IndexOf('WaitForExit(timeoutMs)')
            $readAt = $script:ZellijCliSource.IndexOf('StandardOutput.ReadToEnd()')
            $waitAt | Should -BeGreaterThan 0
            $readAt | Should -BeGreaterThan 0
            $waitAt | Should -BeLessThan $readAt -Because (
                'ReadToEnd on a process that never exits blocks forever, whatever timeout follows it')
        }

        It 'reports whether killing a session worked' {
            # These were void, and the caller toasted "Killed x" whether zellij
            # had killed anything, refused, or never run at all.
            $script:ZellijCliSource | Should -Match 'internal static bool KillSession'
            $script:ZellijCliSource | Should -Match 'internal static bool DeleteSession'
        }

        It 'logs the zellij-direct actions the README promises are logged' {
            # cmdpal/README.md tells the reader that every action writes a start
            # line and an exit line, and that an empty log means the palette
            # itself is broken. Four actions went through ZellijCli, which had
            # no logging at all, so that advice sent people to the wrong layer.
            $script:ZellijCliSource | Should -Match 'ZtCli\.Log'
        }

        It 'ships a pack script beside the project' {
            # There is no single-project MSIX here: publish, makeappx, signtool
            # and Add-AppxPackage are four separate steps and pack.ps1 is the
            # only record of the order and the flags.
            $pack = Join-Path (Split-Path -Parent $script:PaletteDir) 'pack.ps1'
            Test-Path -LiteralPath $pack -PathType Leaf | Should -BeTrue -Because (
                "the four packaging steps are not written down anywhere else: $pack")
        }
    }
}
