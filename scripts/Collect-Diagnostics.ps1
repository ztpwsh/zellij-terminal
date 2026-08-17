<#
.SYNOPSIS
    Collect one evidence bundle about this machine's zt install, for reading
    somewhere else.

.DESCRIPTION
    Test-Setup.ps1 (`zt check`) answers "which layer is broken" and answers it
    with a verdict. This answers a different question: "what is actually on this
    machine", and answers it with bytes.

    The two are not the same tool and the second exists because of a specific
    failure: `zt check` reports PASS while the rig does not work. Every check in
    it asks whether a file is THERE, and the files that decide whether this rig
    starts are GENERATED PER MACHINE - %APPDATA%\Zellij\config\layouts\claude.kdl
    carries an absolute plugin path and an absolute cwd, both substituted at
    install time. A layout that exists, parses, and points at a plugin that is
    not there is a PASS on every question `zt check` knows how to ask, and a
    session with no status bar. A layout with an unreplaced `{{PLUGINS}}` is the
    same PASS and, per docs/05-usage.md, fails silently in exactly that way.

    So this reads those files out VERBATIM and, where there is a source to
    compare against, regenerates what the installer should have written and
    reports the difference. Judging the difference is a separate job, done by
    whoever reads the bundle, with the repo in front of them.

    IT DOES NOT CHANGE ANYTHING. No file is written outside the output bundle,
    no session is started, nothing is installed or repaired. The one exception
    is -ParseLayout, which is opt-in, says what it does before doing it, and
    cleans up after itself - see the switch.

    Compatible with Windows PowerShell 5.1 - no ternary, no ??, no && / ||.
    It has to be: on a machine where the module will not import, this script and
    `powershell.exe -File` are what is left.

.PARAMETER Path
    Where to write the bundle. Defaults to a timestamped file under %TEMP%.

.PARAMETER NoRedact
    Leave the user name, the device name and the profile path in the output.
    Off by default because the bundle is written to be sent somewhere.

.PARAMETER ParseLayout
    Actually ask Zellij to parse the deployed layout, by running `zellij -l
    claude` in a child process with a time cap. This is the ONLY way to find a
    KDL error: a bad layout is reported as "Session 'claude' not found", which
    sends you hunting for a missing session.

    It is opt-in because it is the one part of this script that is not read-only.
    `--layout` cannot be combined with `--session` (that form means "add these
    tabs to an existing session"), so the session it creates gets a generated
    name and cannot be named in advance. The session list is captured before and
    after, and only a session that was not there before and appeared during the
    probe is deleted.

.EXAMPLE
    .\Collect-Diagnostics.ps1
    .\Collect-Diagnostics.ps1 -ParseLayout -Path C:\temp\zt-diag.md
#>

[CmdletBinding()]
param(
    [string]$Path,
    [string]$Session = 'claude',
    [string]$Prefix  = 'claude-',
    [switch]$NoRedact,
    [switch]$ParseLayout
)

# Never throw. A collector that dies on section 3 tells you less than one that
# records the failure and carries on to section 12, and the sections most likely
# to throw - reading somebody else's JSON, running an executable that may not be
# there - are the ones whose absence is the finding.
$ErrorActionPreference = 'Continue'

$script:Report      = New-Object System.Text.StringBuilder
$script:Signals     = New-Object System.Collections.ArrayList
$script:Failures    = New-Object System.Collections.ArrayList
$script:PluginPaths = @()

# ---------------------------------------------------------------------------
#  Writing the bundle
# ---------------------------------------------------------------------------

function Protect-ZtText {
    <#
        Strip this machine's identity from a string.

        The bundle is written to be pasted into a chat window or attached to an
        issue, so the default is redacted. The substitution is a REPLACEMENT and
        not a deletion on purpose: a path still reads as a path, so "the layout
        cwd does not exist" is still diagnosable when the cwd is
        %USERPROFILE%\code\thing.

        Longest first. The profile path contains the user name, so replacing the
        user name first would leave a mangled profile path that no longer
        matches its own pattern.
    #>
    param([string]$Text)

    if ($NoRedact) { return $Text }
    if (-not $Text) { return $Text }

    $out = $Text

    $profilePath = $env:USERPROFILE
    if ($profilePath) {
        $out = $out -replace [regex]::Escape($profilePath), '%USERPROFILE%'
        $out = $out -replace [regex]::Escape(($profilePath -replace '\\', '/')), '%USERPROFILE%'
    }

    $user = $env:USERNAME
    if ($user -and $user.Length -gt 2) {
        $out = $out -replace ('(?i)' + [regex]::Escape($user)), '<user>'
    }

    $device = $env:COMPUTERNAME
    if ($device -and $device.Length -gt 2) {
        $out = $out -replace ('(?i)' + [regex]::Escape($device)), '<device>'
    }

    return $out
}

function Add-Line {
    param([string]$Text = '')
    [void]$script:Report.AppendLine((Protect-ZtText $Text))
}

function Add-Head {
    param([string]$Title)
    Add-Line ''
    Add-Line ('## ' + $Title)
    Add-Line ''
}

function Add-Fact {
    param([string]$Name, $Value)
    $v = "$Value"
    if ($v -eq '') { $v = '(empty)' }
    Add-Line ('- **' + $Name + '**: ' + $v)
}

function Add-Block {
    <#
        A fenced block. Empty content is written as an explicit marker rather
        than as an empty fence, because "the file was there and had nothing in
        it" and "I could not read the file" are different findings and an empty
        fence reads as neither.
    #>
    param([string]$Text, [string]$Language = 'text')

    Add-Line ('```' + $Language)
    if ($null -eq $Text -or $Text -eq '') {
        [void]$script:Report.AppendLine('(no output)')
    } else {
        [void]$script:Report.AppendLine((Protect-ZtText ($Text.TrimEnd())))
    }
    Add-Line '```'
}

function Add-Signal {
    <#
        Something worth looking at first. Deliberately NOT a verdict: the point
        of this script is that the verdicts on this machine already say the rig
        is fine. A signal is "this is unusual, here is where the evidence for it
        is", and the evidence is always in the body as well.
    #>
    param([string]$Text)

    # Deduplicated. Two tabs with the same missing cwd is one thing to look at,
    # and a list that repeats itself reads as noise however true each line is.
    $clean = Protect-ZtText $Text
    if ($script:Signals -notcontains $clean) { [void]$script:Signals.Add($clean) }
}

function Add-Failure {
    param([string]$Where, $Error_)
    $msg = "$Where : $Error_"
    [void]$script:Failures.Add((Protect-ZtText $msg))
}

function Invoke-Section {
    <#
        Run one section's collection with its own error boundary, so a section
        that throws costs that section and nothing else.
    #>
    param([string]$Name, [scriptblock]$Body)

    Write-Host ('  ' + $Name) -ForegroundColor DarkGray
    try {
        & $Body
    } catch {
        Add-Line ''
        Add-Line ('> COLLECTION FAILED HERE: ' + $_.Exception.Message)
        Add-Line ''
        Add-Failure $Name $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
#  Reading things
# ---------------------------------------------------------------------------

function Get-ZtFileFacts {
    <#
        Existence, size, when it was written, and a hash. The hash is the point:
        it is how a file on that machine is compared with a file here without
        anybody having to eyeball two screens of KDL, and how a wasm binary is
        identified when nothing inside it says which release it came from.
    #>
    param([string]$FilePath)

    $facts = [pscustomobject]@{
        Path    = $FilePath
        Exists  = $false
        Size    = 0
        Written = ''
        Sha256  = ''
    }

    if (-not $FilePath) { return $facts }
    if (-not (Test-Path -LiteralPath $FilePath)) { return $facts }

    $item = Get-Item -LiteralPath $FilePath -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $facts }

    $facts.Exists  = $true
    $facts.Written = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
    if (-not $item.PSIsContainer) {
        $facts.Size = $item.Length
        $h = Get-FileHash -LiteralPath $FilePath -Algorithm SHA256 -ErrorAction SilentlyContinue
        if ($h) { $facts.Sha256 = $h.Hash }
    }
    return $facts
}

function Add-FileFacts {
    param([string]$Label, [string]$FilePath)

    $f = Get-ZtFileFacts $FilePath
    if ($f.Exists) {
        Add-Fact $Label ($f.Path + '  (' + $f.Size + ' bytes, written ' + $f.Written + ', sha256 ' + $f.Sha256 + ')')
    } else {
        Add-Fact $Label ($f.Path + '  -- NOT PRESENT')
    }
    return $f
}

function Get-ZtText {
    param([string]$FilePath)
    if (-not $FilePath) { return '' }
    if (-not (Test-Path -LiteralPath $FilePath)) { return '' }
    $t = Get-Content -LiteralPath $FilePath -Raw -ErrorAction SilentlyContinue
    if ($null -eq $t) { return '' }
    return $t
}

function Invoke-Probe {
    <#
        Run an external command and capture stdout, stderr and the exit code
        together.

        THE EXIT CODE IS ALWAYS RECORDED, because in this rig it is routinely
        the opposite of what the output implies: `query-tab-names` prints
        "Session not found" and exits 0; `current-tab-info` prints prose on
        stderr and exits 2. Neither can be read correctly without both halves,
        which is why nothing here summarises - it records the pair.
    #>
    param([string]$Exe, [string[]]$Arguments = @())

    $result = [pscustomobject]@{
        Command  = ($Exe + ' ' + ($Arguments -join ' '))
        Ran      = $false
        ExitCode = $null
        Output   = ''
    }

    $cmd = Get-Command $Exe -ErrorAction SilentlyContinue
    if (-not $cmd) {
        $result.Output = "'$Exe' is not resolvable on PATH"
        return $result
    }

    try {
        $global:LASTEXITCODE = 0
        $raw = & $Exe @Arguments 2>&1 | Out-String
        $result.Ran      = $true
        $result.ExitCode = $LASTEXITCODE
        $result.Output   = $raw
    } catch {
        $result.Output = 'threw: ' + $_.Exception.Message
    }
    return $result
}

function Add-Probe {
    param([string]$Exe, [string[]]$Arguments = @())

    $r = Invoke-Probe $Exe $Arguments
    Add-Line ''
    Add-Line ('`' + $r.Command + '`  -- exit ' + "$($r.ExitCode)")
    Add-Block $r.Output
    return $r
}

function Get-ZtDeviceConfigPath {
    <#
        FOURTH copy of one rule - Get-ZtConfigHome in Private\Core.ps1, ConfigHome
        in the palette's ZtStore.cs, and Get-DeviceConfigPath in Test-Setup.ps1
        are the others, and tests pin them together. It is copied rather than
        imported for the same reason as there: this runs with no module, under
        5.1, on a machine where the module may be the broken thing.
    #>
    $home_ = $env:ZT_CONFIG_HOME
    if (-not $home_) {
        $base = $env:LOCALAPPDATA
        if (-not $base) { $base = $env:TEMP }
        $home_ = Join-Path $base 'ZellijTerminal'
    }

    $device = $env:ZT_DEVICE
    if (-not $device) { $device = $env:COMPUTERNAME }

    return (Join-Path $home_ (Join-Path 'devices' ($device + '.json')))
}

function Get-ZtPrintable {
    <#
        Escape sequences out, and a cap on the length.

        For the layout probe specifically. A layout that PARSES means Zellij
        goes on to draw, and what it draws lands in the redirected stdout as
        tens of kilobytes of cursor positioning - measured at 45 KB in a 79 KB
        bundle, which is most of a file somebody has to read. The useful content
        in that case is one line long ("it got as far as drawing"); in the
        failing case it is a parse error, which is short. Either way the cap
        costs nothing and the escape codes are never the evidence.
    #>
    param([string]$Text, [int]$Limit = 2000)

    if (-not $Text) { return '' }

    # [char]27 and not `e. Backtick-e arrived in PowerShell 6, and Windows
    # PowerShell 5.1 - which this file promises to run under, and which is the
    # shell the hook uses - does not error on an unknown backtick escape, it
    # yields the literal character. So "`e\[..." there is a pattern matching a
    # literal letter e, and this function would quietly delete real text out of
    # the evidence instead of escape codes. It parses either way, which is
    # exactly why the compat test could not have caught it.
    $esc = [string][char]27
    # Order matters: the OSC and CSI forms both START with ESC, so removing
    # control characters first leaves their payloads behind as text - which is
    # how a first pass at this turned 45 KB of cursor moves into 36 KB of `]8;;`.
    $out = $Text -replace ($esc + '\][^\x07' + $esc + ']*(\x07|' + $esc + '\\)?'), ''
    $out = $out -replace ($esc + '\[[0-9;?]*[a-zA-Z]'), ''
    $out = $out -replace ($esc + '[=>()][0-9A-Za-z]?'), ''
    $out = $out -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''

    # A drawn screen is mostly padding. Runs of spaces carry no information here
    # and cost a page each.
    $out = $out -replace ' {3,}', ' '
    $out = ($out -split "`r?`n" | Where-Object { $_.Trim() -ne '' }) -join "`n"

    if ($out.Length -gt $Limit) {
        $out = $out.Substring(0, $Limit) + "`n... truncated at $Limit characters"
    }
    return $out
}

function Remove-KdlComment {
    <#
        Drop `//` comments, leaving anything inside a quoted string alone.

        NOT COSMETIC. The layout template ends in ~40 lines of commented
        VARIATIONS showing other people's example tabs, and the first run of
        this script duly reported that `C:/code/api`, `api` and `web` were tab
        working directories that do not exist - four signals, all of them from
        prose. A collector that cries wolf is worse than one that says nothing,
        because it teaches you to skip the list where the real one will be.

        The quote state has to be tracked rather than assumed: `location=
        "file://..."` is a legal thing to write, and cutting at the first `//`
        would silently truncate the one line this script exists to read.
    #>
    param([string]$Text)

    if (-not $Text) { return '' }

    $out = @()
    foreach ($line in ($Text -split "`r?`n")) {
        $inQuote = $false
        $cut     = -1
        for ($i = 0; $i -lt $line.Length; $i++) {
            $ch = $line[$i]
            if ($ch -eq '"') { $inQuote = -not $inQuote; continue }
            if ((-not $inQuote) -and $ch -eq '/' -and ($i + 1) -lt $line.Length -and $line[$i + 1] -eq '/') {
                $cut = $i
                break
            }
        }
        if ($cut -ge 0) { $out += $line.Substring(0, $cut) } else { $out += $line }
    }
    return ($out -join "`n")
}

function Get-ZtDiff {
    <#
        A line diff, rendered so it can be read in a chat window.

        Compare-Object rather than anything cleverer: it is in 5.1, it is
        stable, and the question here is only "which lines differ", not "what is
        the minimal edit". -SyncWindow 0 keeps it honest about ORDER, because a
        block moved is a real difference in a KDL file - the layout's own header
        says the bar pane must come before `children` or the bar renders at the
        bottom.
    #>
    param([string]$Expected, [string]$Actual, [int]$Limit = 60)

    $a = @($Expected -split "`r?`n")
    $b = @($Actual   -split "`r?`n")

    $delta = @(Compare-Object -ReferenceObject $a -DifferenceObject $b -SyncWindow 0 -ErrorAction SilentlyContinue)
    if ($delta.Count -eq 0) { return '' }

    $lines = @()
    $shown = 0
    foreach ($d in $delta) {
        if ($shown -ge $Limit) {
            $lines += ('... and ' + ($delta.Count - $shown) + ' more differing line(s)')
            break
        }
        $mark = '  '
        if ($d.SideIndicator -eq '<=') { $mark = '- expected  ' }
        if ($d.SideIndicator -eq '=>') { $mark = '+ on disk   ' }
        $lines += ($mark + $d.InputObject)
        $shown++
    }
    return ($lines -join "`n")
}

# ===========================================================================
#  Start
# ===========================================================================

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $Path) {
    $Path = Join-Path $env:TEMP ('zt-diag-' + $stamp + '.md')
}

$repoRoot = $null
try { $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path } catch { }

Write-Host ''
Write-Host '  zt - collecting a diagnostic bundle' -ForegroundColor Cyan
Write-Host '  nothing is changed; the output is one file' -ForegroundColor DarkGray
Write-Host ''

Add-Line '# zt diagnostic bundle'
Add-Line ''
Add-Line ('Collected ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz') + ' by `scripts/Collect-Diagnostics.ps1`.')
Add-Line ''
if (-not $NoRedact) {
    Add-Line ('User name, device name and profile path are redacted. Re-run with ' +
              '`-NoRedact` if a path itself is in question.')
    Add-Line ''
}
Add-Line 'Read the SIGNALS list first, then the evidence for it in the body. Signals are'
Add-Line 'observations, not verdicts - this machine already reports a clean `zt check`.'

# ===========================================================================
#  1 - identity
# ===========================================================================
Invoke-Section 'identity' {
    Add-Head '1. This machine'

    Add-Fact 'OS' ((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption)
    Add-Fact 'OS build' ([System.Environment]::OSVersion.Version.ToString())
    Add-Fact 'Device' $env:COMPUTERNAME
    Add-Fact 'PowerShell (this process)' ($PSVersionTable.PSVersion.ToString() + ' ' + $PSVersionTable.PSEdition)

    # The hook runs under powershell.exe whatever this is running under, so the
    # 5.1 that matters is the one on the box, not the one collecting.
    $wps = Get-Command 'powershell.exe' -ErrorAction SilentlyContinue
    if ($wps) {
        $v = Invoke-Probe 'powershell.exe' @('-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()')
        Add-Fact 'Windows PowerShell (runs the hook)' ($v.Output.Trim())
    } else {
        Add-Fact 'Windows PowerShell (runs the hook)' 'powershell.exe NOT FOUND - the hook cannot run'
        Add-Signal 'powershell.exe is not resolvable, and the Claude Code hook is registered to run under it.'
    }

    $pwsh = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
    if ($pwsh) {
        Add-Fact 'pwsh.exe' $pwsh.Source
    } else {
        Add-Fact 'pwsh.exe' 'NOT FOUND'
        # The layout starts its one tab with `pane command="pwsh"`. A tab whose
        # command does not exist is a tab that closes the moment it opens.
        Add-Signal 'pwsh.exe is not on PATH, and the claude layout starts its home tab with `pane command="pwsh"`.'
    }

    # A profile path with a space, or one redirected into OneDrive, has bitten
    # enough Windows tooling that it is worth stating rather than leaving to be
    # inferred from a redacted string.
    Add-Fact 'Profile path shape' ('length ' + "$($env:USERPROFILE.Length)" +
        ', contains space: ' + "$($env:USERPROFILE -match ' ')" +
        ', under OneDrive: ' + "$($env:USERPROFILE -match 'OneDrive')")
}

# ===========================================================================
#  2 - which code is actually running
# ===========================================================================
Invoke-Section 'code location' {
    Add-Head '2. Which code is installed, and where it came from'

    Add-Fact 'Clone this script ran from' $repoRoot

    if ($repoRoot) {
        $g = Invoke-Probe 'git' @('-C', $repoRoot, 'rev-parse', 'HEAD')
        Add-Fact 'Clone HEAD' $g.Output.Trim()

        $b = Invoke-Probe 'git' @('-C', $repoRoot, 'rev-parse', '--abbrev-ref', 'HEAD')
        Add-Fact 'Clone branch' $b.Output.Trim()

        $st = Invoke-Probe 'git' @('-C', $repoRoot, 'status', '--porcelain')
        $dirty = @($st.Output -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
        Add-Fact 'Uncommitted files in the clone' $dirty.Count
        if ($dirty.Count -gt 0) { Add-Block ($dirty -join "`n") }

        # Remote NAMES and hosts only. The bundle travels, and this project's
        # whole publishing model rests on the private remote never being named
        # in something that leaves the machine.
        $rm = Invoke-Probe 'git' @('-C', $repoRoot, 'remote')
        Add-Fact 'Remotes configured' (($rm.Output -split "`r?`n" | Where-Object { $_.Trim() -ne '' }) -join ', ')
    }

    # THE JUNCTION. On this project's own machines it has pointed at three
    # different trees in a week, and a fix verified against the wrong tree looks
    # exactly like a fix that works. Report EVERY copy PowerShell can see, not
    # just the winner, because two copies on the module path is its own bug and
    # the loser is invisible from inside a session that imported the winner.
    Add-Line ''
    Add-Line '### Every ZellijTerminal PowerShell can see'
    Add-Line ''

    $mods = @(Get-Module -ListAvailable ZellijTerminal -ErrorAction SilentlyContinue)
    if ($mods.Count -eq 0) {
        Add-Line '(none - `zt` is not installed for this user)'
        Add-Signal 'No ZellijTerminal module is on the module path at all: `zt` cannot autoload.'
    } else {
        if ($mods.Count -gt 1) {
            Add-Signal ($mods.Count.ToString() + ' copies of the ZellijTerminal module are on the module path; the first one wins and the others are invisible.')
        }
        foreach ($m in $mods) {
            $base = Split-Path $m.Path -Parent
            $real = $base
            $link = ''
            $item = Get-Item -LiteralPath $base -Force -ErrorAction SilentlyContinue
            if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                $props = $item.PSObject.Properties.Name
                if (($props -contains 'LinkTarget') -and $item.LinkTarget) {
                    $real = $item.LinkTarget
                } elseif (($props -contains 'Target') -and $item.Target) {
                    $real = @($item.Target)[0]
                }
                $link = ' (junction)'
            }
            Add-Line ('- `' + $m.Version + '` at ' + $base + $link)
            Add-Line ('  - resolves to: ' + $real)

            # Which clone is that, and is it current? A junction pointing at a
            # clone three releases behind presents as "the fix did not work".
            $gv = Invoke-Probe 'git' @('-C', $real, 'rev-parse', '--short', 'HEAD')
            if ($gv.ExitCode -eq 0) {
                Add-Line ('  - that tree is at commit: ' + $gv.Output.Trim())
            } else {
                Add-Line '  - that tree is not a git clone'
            }

            if ($repoRoot) {
                $expect = (Join-Path $repoRoot (Join-Path 'module' 'ZellijTerminal'))
                if ($real.TrimEnd('\') -ne $expect.TrimEnd('\')) {
                    Add-Line ('  - NOT this clone (this clone is ' + $expect + ')')
                }
            }
        }
    }

    # What a fresh shell would load, as opposed to what is available. Done in a
    # CHILD process: importing here would change what this process is running
    # halfway through collecting, and on the machine this was written for the
    # module is a candidate for the broken thing.
    $imp = Invoke-Probe 'pwsh' @('-NoProfile', '-Command',
        'Import-Module ZellijTerminal -ErrorAction Stop; (Get-Module ZellijTerminal).Path + "  v" + (Get-Module ZellijTerminal).Version')
    Add-Line ''
    Add-Fact 'A fresh pwsh imports' ($imp.Output.Trim() + '   [exit ' + "$($imp.ExitCode)" + ']')
    if ($imp.ExitCode -ne 0) {
        Add-Signal 'A fresh pwsh cannot import ZellijTerminal - see section 2 for the error.'
    }
}

# ===========================================================================
#  3 - Zellij itself
# ===========================================================================
Invoke-Section 'zellij' {
    Add-Head '3. Zellij'

    $zj = Get-Command zellij -ErrorAction SilentlyContinue
    if (-not $zj) {
        Add-Fact 'zellij' 'NOT ON PATH'
        Add-Signal 'zellij is not resolvable on PATH, so nothing in this rig can run.'
        return
    }

    Add-Fact 'zellij' $zj.Source
    Add-Probe 'zellij' @('--version') | Out-Null

    # setup --check is authoritative about WHERE Zellij reads from, and this
    # project has already shipped one wrong path (a missing `config` level) that
    # made a check pass while reading nothing. Take the answer from Zellij
    # rather than from our own Join-Path.
    Add-Line ''
    Add-Line '### `zellij setup --check` - where Zellij says its directories are'
    Add-Probe 'zellij' @('setup', '--check') | Out-Null

    Add-Line ''
    Add-Line '### Sessions, clients, tabs'
    Add-Probe 'zellij' @('list-sessions') | Out-Null

    $clients = Add-Probe 'zellij' @('--session', $Session, 'action', 'list-clients')
    $rows = @([regex]::Matches($clients.Output, '(?m)^\d+\s'))
    Add-Fact 'Client rows (counted by shape, not by line)' $rows.Count
    if ($rows.Count -eq 0) {
        Add-Signal ('No client is attached to session "' + $Session + '": write, go-to-tab-name and close-tab are all silent no-ops that still exit 0.')
    }

    Add-Probe 'zellij' @('--session', $Session, 'action', 'query-tab-names') | Out-Null
}

# ===========================================================================
#  4 - the layout. The generated file, and the reason for this script.
# ===========================================================================
Invoke-Section 'layout' {
    Add-Head '4. The deployed layout (generated per machine)'

    Add-Line 'This file is written by `install.ps1` from `zellij/layouts/claude.kdl.template`'
    Add-Line 'with three markers substituted. It is not in any repository, so it is the one'
    Add-Line 'file that cannot be checked by reading the source, and both "the session will'
    Add-Line 'not start" and "there is no status bar" live here.'
    Add-Line ''

    $layPath = Join-Path $env:APPDATA (Join-Path 'Zellij' (Join-Path 'config' (Join-Path 'layouts' 'claude.kdl')))
    $lay     = Add-FileFacts 'Deployed layout' $layPath
    $layText = Get-ZtText $layPath

    if (-not $lay.Exists) {
        Add-Signal 'The claude layout is not deployed. With `default_layout "claude"` in config.kdl, Zellij starts nothing.'
        return
    }

    # Every pattern below reads the LIVE layout, not the commentary. The file is
    # two thirds prose - the template ships its own manual, including worked
    # examples of tabs on directories nobody has - and matching that prose is
    # how a diagnostic turns into noise. The verbatim dump at the end of this
    # section is the whole file, comments and all.
    $layLive = Remove-KdlComment $layText

    # --- unreplaced markers -------------------------------------------------
    # docs/05-usage.md: "Leave a {{...}} unreplaced and nothing errors: the
    # status bar silently never loads, and the tab opens in the wrong directory."
    # That is both reported symptoms, from one cause, with no error message.
    $markers = @([regex]::Matches($layLive, '\{\{[A-Z_]+\}\}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    if ($markers.Count -gt 0) {
        Add-Fact 'Unreplaced template markers' ($markers -join ', ')
        Add-Signal ('The deployed layout still contains ' + ($markers -join ', ') +
                    ' - the substitution did not run. This alone produces both a missing status bar and a tab in the wrong directory, with no error.')
    } else {
        Add-Fact 'Unreplaced template markers' 'none'
    }

    # --- the plugin path it actually points at ------------------------------
    $locs = @([regex]::Matches($layLive, 'location="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    if ($locs.Count -eq 0) {
        Add-Fact 'Plugin location in the layout' 'no plugin node found'
        Add-Signal 'The deployed layout declares no plugin at all, so there is no status bar to render.'
    }
    foreach ($loc in $locs) {
        Add-Fact 'Plugin location in the layout' $loc

        # `file:` plus a Windows path is the form install.ps1 writes. Resolve it
        # back to a filesystem path and ask whether the file is there - a
        # location pointing at nothing is not an error in Zellij, it is a
        # missing bar.
        $fsPath = $loc
        if ($fsPath -match '^file:') { $fsPath = $fsPath.Substring(5) }
        $fsPath = $fsPath.TrimStart('/')
        $fsPath = $fsPath -replace '/', '\'

        if ($fsPath -match '^[A-Za-z]:\\') {
            $exists = Test-Path -LiteralPath $fsPath
            Add-Fact '  resolves to' ($fsPath + '  -- exists: ' + $exists)

            # Handed to section 6, which asks whether Zellij is allowed to RUN
            # it. Taken from the layout rather than recomputed, because the
            # grant is keyed by the path the layout actually names.
            $script:PluginPaths += $fsPath
            if (-not $exists) {
                Add-Signal ('The layout points its plugin at ' + $fsPath + ', which is not there. Zellij does not report this; the bar is simply absent.')
            }
        } else {
            Add-Fact '  resolves to' ('not an absolute Windows path: ' + $fsPath)
            Add-Signal ('The plugin location "' + $loc + '" is not an absolute path, so whether it resolves depends on where Zellij was started.')
        }
    }

    # --- the settings the bar depends on ------------------------------------
    $mode = [regex]::Match($layLive, 'pipe_status_rendermode\s+"([^"]+)"')
    if ($mode.Success) {
        Add-Fact 'pipe_status_rendermode' $mode.Groups[1].Value
        if ($mode.Groups[1].Value -ne 'dynamic') {
            Add-Signal ('pipe_status_rendermode is "' + $mode.Groups[1].Value + '", not "dynamic" - the bar prints #[fg=...] as literal text.')
        }
    } else {
        Add-Fact 'pipe_status_rendermode' 'not set'
        Add-Signal 'pipe_status_rendermode is not set; the default is static, which prints the colour markup literally.'
    }

    $widget = [regex]::Match($layLive, '\{pipe_status\}')
    Add-Fact 'format references {pipe_status}' $widget.Success
    Add-Fact 'has default_tab_template' ([regex]::Match($layLive, 'default_tab_template').Success)

    # --- the cwd it opens in ------------------------------------------------
    foreach ($m in [regex]::Matches($layLive, 'cwd="([^"]+)"')) {
        $cwd = $m.Groups[1].Value
        $fs  = $cwd -replace '/', '\'
        $ok  = Test-Path -LiteralPath $fs
        Add-Fact 'Tab cwd' ($cwd + '  -- exists: ' + $ok)
        if (-not $ok) {
            Add-Signal ('A tab cwd in the layout (' + $cwd + ') does not exist. Zellij falls back silently and opens the tab somewhere else.')
        }
    }

    # --- structural sanity, offline ----------------------------------------
    # `{ pane }` is a parse error and `{ pane; }` is not, and a layout parse
    # error is REPORTED AS "Session not found" - which is the reported symptom.
    # This cannot replace asking Zellij (that is -ParseLayout) but an unbalanced
    # brace is worth catching without starting anything.
    $stripped = $layLive -replace '"[^"]*"', '""'
    $open  = @([regex]::Matches($stripped, '\{')).Count
    $close = @([regex]::Matches($stripped, '\}')).Count
    Add-Fact 'Braces outside comments and strings' ($open.ToString() + ' open, ' + $close.ToString() + ' close')
    if ($open -ne $close) {
        Add-Signal 'Braces do not balance in the deployed layout. A KDL parse error surfaces as "Session not found", not as a parse error.'
    }

    # --- what the installer SHOULD have written -----------------------------
    # The comparison that makes this bundle worth sending: regenerate the file
    # from the template in this clone, using this machine's paths, and diff.
    # Anything that differs was either hand-edited, written by a different clone,
    # or written by an older version of the installer.
    if ($repoRoot) {
        $tpl = Join-Path $repoRoot (Join-Path 'zellij' (Join-Path 'layouts' 'claude.kdl.template'))
        if (Test-Path -LiteralPath $tpl) {
            $zjPluginDir = Join-Path $env:APPDATA (Join-Path 'Zellij' (Join-Path 'data' 'plugins'))
            $expected = Get-ZtText $tpl
            $expected = $expected.Replace('{{PLUGINS}}', ($zjPluginDir -replace '\\', '/'))
            $expected = $expected.Replace('{{REPO}}',    ($repoRoot    -replace '\\', '/'))
            $expected = $expected.Replace('{{HOME}}',    ($HOME        -replace '\\', '/'))

            $diff = Get-ZtDiff -Expected $expected -Actual $layText
            Add-Line ''
            if ($diff -eq '') {
                Add-Fact 'Deployed layout vs this clone regenerated' 'IDENTICAL'
            } else {
                Add-Fact 'Deployed layout vs this clone regenerated' 'DIFFERS - see below'
                Add-Block $diff 'diff'
                # The commonest cause is benign and worth naming, because
                # otherwise this reads as corruption: the deployed file records
                # the clone that installed it, so a machine with two clones
                # differs here by one cwd line and nothing else.
                Add-Signal ('The deployed layout is not what this clone would generate - see the diff in section 4. ' +
                            'A single differing `cwd=` line means it was installed from a different clone; anything more means an older installer or a hand edit.')
            }
        }
    }

    # --- and the file itself ------------------------------------------------
    Add-Line ''
    Add-Line '### The deployed layout, verbatim'
    Add-Block $layText 'kdl'
}

# ===========================================================================
#  5 - Zellij config
# ===========================================================================
Invoke-Section 'config' {
    Add-Head '5. Zellij config'

    $cfgPath = Join-Path $env:APPDATA (Join-Path 'Zellij' (Join-Path 'config' 'config.kdl'))
    $cfg     = Add-FileFacts 'Deployed config' $cfgPath
    $cfgText = Get-ZtText $cfgPath

    if (-not $cfg.Exists) {
        Add-Signal 'There is no config.kdl, so `default_layout "claude"` is not set and `zellij attach --create claude` starts a default session with no bar.'
        return
    }

    $dl = [regex]::Match($cfgText, '(?m)^\s*default_layout\s+"([^"]+)"')
    if ($dl.Success) {
        Add-Fact 'default_layout' $dl.Groups[1].Value
        if ($dl.Groups[1].Value -ne 'claude') {
            Add-Signal ('default_layout is "' + $dl.Groups[1].Value + '", not "claude" - the claude layout is deployed but never loaded.')
        }
    } else {
        Add-Fact 'default_layout' 'NOT SET'
        Add-Signal 'default_layout is not set in config.kdl. The layout is deployed and nothing loads it, which is a session with no bar and no home tab.'
    }

    $dm = [regex]::Match($cfgText, '(?m)^\s*default_mode\s+"([^"]+)"')
    if ($dm.Success) { Add-Fact 'default_mode' $dm.Groups[1].Value }

    if ($repoRoot) {
        $repoCfg = Join-Path $repoRoot (Join-Path 'zellij' 'config.kdl')
        if (Test-Path -LiteralPath $repoCfg) {
            $diff = Get-ZtDiff -Expected (Get-ZtText $repoCfg) -Actual $cfgText
            if ($diff -eq '') {
                Add-Fact 'Deployed config vs this clone' 'IDENTICAL'
            } else {
                Add-Fact 'Deployed config vs this clone' 'DIFFERS - see below'
                Add-Block $diff 'diff'
            }
        }
    }

    Add-Line ''
    Add-Line '### The deployed config, verbatim'
    Add-Block $cfgText 'kdl'
}

# ===========================================================================
#  6 - the plugin and everything Zellij keeps on disk
# ===========================================================================
Invoke-Section 'plugin' {
    Add-Head '6. zjstatus, and the Zellij data directory'

    $pluginDir = Join-Path $env:APPDATA (Join-Path 'Zellij' (Join-Path 'data' 'plugins'))
    $wasm      = Join-Path $pluginDir 'zjstatus.wasm'
    $w         = Add-FileFacts 'zjstatus.wasm' $wasm

    if (-not $w.Exists) {
        Add-Signal 'zjstatus.wasm is not installed. install.ps1 does not download it - it prints a note and carries on, so a clean install has no status bar by design.'
    } else {
        # Nothing in the file says which release it is, and the hash is how it
        # gets identified against github.com/dj95/zjstatus/releases without
        # anybody having to trust a memory of which one was downloaded. A wasm
        # built for a different Zellij plugin API loads, does nothing visible,
        # and reports nothing - the same picture as a missing bar.
        Add-Line ''
        Add-Line 'Identify the build by its sha256 against the zjstatus releases page; the'
        Add-Line 'binary carries no version string of its own that can be trusted.'

        try {
            $bytes = [System.IO.File]::ReadAllBytes($wasm)
            $ascii = [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString($bytes)
            $vers  = @([regex]::Matches($ascii, 'zjstatus[^\x20-\x7E]{0,4}v?(\d+\.\d+\.\d+)') |
                        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            if ($vers.Count -gt 0) {
                Add-Fact 'Version strings found inside the binary' ($vers -join ', ')
            } else {
                Add-Fact 'Version strings found inside the binary' 'none (expected - use the hash)'
            }
        } catch {
            Add-Fact 'Version strings found inside the binary' ('could not read: ' + $_.Exception.Message)
        }
    }

    # --- may Zellij RUN it? -------------------------------------------------
    #
    # THE QUESTION THIS SECTION USED TO STOP ONE DIRECTORY SHORT OF. Zellij
    # gates plugins behind a permission grant kept in its CACHE directory,
    # under %LOCALAPPDATA% - not under %APPDATA%, which is all this section
    # listed. Without a grant the plugin loads and waits for an approval prompt
    # that renders in its own pane: one row, borderless, in a session that
    # starts locked. Nothing can draw or answer there, so the bar is absent
    # with no prompt, no error and nothing in any log.
    #
    # It is acquired interactively and once, which is why every development
    # machine had one and nothing that ships did. A bundle from a machine with
    # a correct layout, a byte-identical wasm and a clean `zt check` still had
    # no bar, and this file was the difference.
    Add-Line ''
    Add-Line '### Plugin permission grant'
    Add-Line ''

    $permPath = Join-Path $env:LOCALAPPDATA (Join-Path 'Zellij' (Join-Path 'cache' 'permissions.kdl'))
    $perm     = Add-FileFacts 'permissions.kdl' $permPath
    $permText = Get-ZtText $permPath

    if ($perm.Exists) {
        Add-Block $permText 'kdl'
    } else {
        Add-Line '  Nothing is permitted to run. No plugin in any layout will start.'
    }

    # Ask about the path the LAYOUT names, not a path recomputed here: the
    # grant is keyed by string, so a layout pointing somewhere else is
    # ungranted however many grants the file holds.
    $checked = @($script:PluginPaths)
    if ($checked.Count -eq 0) { $checked = @($wasm) }
    foreach ($p in $checked) {
        $key = $p -replace '\\', '/'
        $granted = $false
        if ($permText -and ($permText -match [regex]::Escape($key))) { $granted = $true }
        Add-Fact 'Granted' ($key + '  -- ' + $granted)
        if (-not $granted) {
            Add-Signal ('Zellij has no permission grant for ' + $key +
                        ' - the plugin loads and waits for an approval prompt that cannot be shown in a one-row locked pane, so the bar is absent with no error. This is the failure a clean `zt check` cannot see.')
        }
    }

    Add-Line ''
    Add-Line '### Everything under %LOCALAPPDATA%\Zellij (the cache dir)'
    Add-Line ''
    $zjCache = Join-Path $env:LOCALAPPDATA 'Zellij'
    if (Test-Path -LiteralPath $zjCache) {
        # Depth-limited on purpose: the cache holds one directory per session
        # ever created, which on a working machine is hundreds of entries and
        # none of them evidence.
        $cacheListing = @(Get-ChildItem -LiteralPath $zjCache -Force -ErrorAction SilentlyContinue |
            Select-Object -First 40 |
            ForEach-Object {
                $size = ''
                if (-not $_.PSIsContainer) { $size = "$($_.Length)" }
                ('{0,-12} {1,-19} {2}' -f $size, $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $_.Name)
            })
        $total = @(Get-ChildItem -LiteralPath $zjCache -Force -ErrorAction SilentlyContinue).Count
        Add-Block (($cacheListing -join "`n") + "`n(top level only; $total entries)")
    } else {
        Add-Block 'no %LOCALAPPDATA%\Zellij directory'
    }

    # The whole tree, because a stale compiled-plugin cache is a real failure
    # mode after a Zellij upgrade and guessing its path from memory is how this
    # project already shipped one wrong directory.
    Add-Line ''
    Add-Line '### Everything under %APPDATA%\Zellij'
    Add-Line ''
    $zjRoot = Join-Path $env:APPDATA 'Zellij'
    if (Test-Path -LiteralPath $zjRoot) {
        $listing = @(Get-ChildItem -LiteralPath $zjRoot -Recurse -Force -ErrorAction SilentlyContinue |
            Select-Object -First 400 |
            ForEach-Object {
                $rel = $_.FullName.Substring($zjRoot.Length).TrimStart('\')
                $size = ''
                if (-not $_.PSIsContainer) { $size = "$($_.Length)" }
                ('{0,-12} {1,-19} {2}' -f $size, $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $rel)
            })
        Add-Block ($listing -join "`n")
    } else {
        Add-Block 'no %APPDATA%\Zellij directory at all'
        Add-Signal 'There is no %APPDATA%\Zellij directory, so Zellij has never run or reads its config from somewhere else - compare with `zellij setup --check` in section 3.'
    }
}

# ===========================================================================
#  7 - ask Zellij to parse the layout (opt-in)
# ===========================================================================
Invoke-Section 'layout parse' {
    Add-Head '7. Layout parse check'

    if (-not $ParseLayout) {
        Add-Line 'Not run. This is the only check that can tell a KDL error from a missing'
        Add-Line 'session, because Zellij reports the first as the second. Re-run with'
        Add-Line '`-ParseLayout` to include it; it starts a throwaway session and deletes it.'
        return
    }

    $zj = Get-Command zellij -ErrorAction SilentlyContinue
    if (-not $zj) {
        Add-Line 'zellij is not on PATH; nothing to ask.'
        return
    }

    # Snapshot first. --layout cannot be combined with --session, so the session
    # this creates gets a generated name; the only safe way to clean up is to
    # delete a name that was not there a moment ago.
    $before = @()
    $b = Invoke-Probe 'zellij' @('list-sessions', '--no-formatting', '--short')
    if ($b.ExitCode -eq 0) {
        $before = @($b.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    }
    Add-Fact 'Sessions before the probe' (($before -join ', '))

    $probeDir = Join-Path $env:TEMP ('zt-layoutprobe-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
    $outFile = Join-Path $probeDir 'out.txt'
    $errFile = Join-Path $probeDir 'err.txt'

    try {
        $p = Start-Process -FilePath $zj.Source `
            -ArgumentList '-l', 'claude' `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError  $errFile `
            -NoNewWindow -PassThru

        # A parse error exits immediately. A layout that is fine tries to run a
        # terminal UI against redirected handles, which is not a state to leave
        # a process in - hence the cap and the kill.
        $exited = $p.WaitForExit(6000)
        if (-not $exited) {
            Add-Fact 'Probe outcome' 'still running after 6s - the layout parsed and Zellij tried to start'
            $p.Kill()
            $p.WaitForExit(3000) | Out-Null
        } else {
            Add-Fact 'Probe outcome' ('exited with ' + $p.ExitCode)
        }

        Add-Line ''
        Add-Line 'stdout (escape sequences stripped, capped):'
        Add-Block (Get-ZtPrintable (Get-ZtText $outFile))
        Add-Line 'stderr:'
        Add-Block (Get-ZtPrintable (Get-ZtText $errFile) 4000)

        $errText = Get-ZtText $errFile
        if ($errText -match 'expected|parse|Failed to|invalid') {
            Add-Signal 'Zellij reported an error parsing or starting the deployed layout - stderr is in section 7.'
        }
    } catch {
        Add-Fact 'Probe outcome' ('could not start: ' + $_.Exception.Message)
    } finally {
        Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Clean up whatever it made, and only that.
    $after = @()
    $a = Invoke-Probe 'zellij' @('list-sessions', '--no-formatting', '--short')
    if ($a.ExitCode -eq 0) {
        $after = @($a.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    }
    $new = @($after | Where-Object { $before -notcontains $_ })
    Add-Fact 'Sessions the probe created' (($new -join ', '))
    foreach ($n in $new) {
        $d = Invoke-Probe 'zellij' @('delete-session', $n, '--force')
        Add-Fact ('  deleted ' + $n) ('exit ' + "$($d.ExitCode)")
    }
}

# ===========================================================================
#  8 - the hook
# ===========================================================================
Invoke-Section 'hook' {
    Add-Head '8. The Claude Code hook'

    Add-Line 'Only the `hooks` key is reproduced. The rest of settings.json is permissions,'
    Add-Line 'plugins and model settings, and none of it is anybody else''s business.'
    Add-Line ''

    $settingsPaths = @(
        (Join-Path $env:USERPROFILE (Join-Path '.claude' 'settings.json'))
    )
    if ($repoRoot) { $settingsPaths += (Join-Path $repoRoot (Join-Path '.claude' 'settings.json')) }

    $anyRegistered = $false
    foreach ($s in $settingsPaths) {
        Add-Line ''
        $f = Add-FileFacts 'settings.json' $s
        if (-not $f.Exists) { continue }

        $raw = Get-ZtText $s
        try {
            $json = $raw | ConvertFrom-Json
        } catch {
            Add-Line ('  NOT VALID JSON: ' + $_.Exception.Message)
            Add-Signal ($s + ' is not valid JSON, so Claude Code loads no hooks from it at all.')
            continue
        }

        if ($json.PSObject.Properties.Name -notcontains 'hooks') {
            Add-Line '  no `hooks` key'
            continue
        }

        Add-Block (($json.hooks | ConvertTo-Json -Depth 20)) 'json'

        # Every path the hook block names, and whether it is there. A path
        # stamped in at install time survives the clone moving, and a hook whose
        # file is missing fails per event, in the background, where nobody
        # looks - which presents as a tab glyph that never changes.
        foreach ($m in [regex]::Matches($raw, '"([^"]*claude-zj-hook[^"]*)"')) {
            $anyRegistered = $true
            $p = $m.Groups[1].Value
            $ok = Test-Path -LiteralPath $p
            Add-Fact '  registered hook path' ($p + '  -- exists: ' + $ok)
            if (-not $ok) {
                Add-Signal ('A registered hook path does not exist: ' + $p)
            }
        }

        if ($raw -match '"(Pre|Post)ToolUse"') {
            Add-Signal ('Pre/PostToolUse hooks are registered in ' + $s + ' - measured at ~956 ms per tool call.')
        }
    }

    if (-not $anyRegistered) {
        Add-Signal 'No claude-zj-hook entry in either settings.json: no flags, no glyphs, no status bar content.'
    }

    # The hook's own log. It is the one component whose failures are invisible
    # by construction - detached, under powershell.exe, output going nowhere.
    Add-Line ''
    $logPath = Join-Path $env:TEMP 'claude-zellij-hook.log'
    $log = Add-FileFacts 'Hook error log' $logPath
    if ($log.Exists) {
        $lines = @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue)
        Add-Fact 'Lines logged' $lines.Count
        if ($lines.Count -gt 0) {
            $tail = @($lines | Select-Object -Last 40)
            Add-Block ($tail -join "`n")
            Add-Signal ($lines.Count.ToString() + ' hook failures are logged - the tail is in section 8.')
        }
    }

    foreach ($dir in @('claude-zellij-flags', 'claude-zellij-status')) {
        Add-Line ''
        $d = Join-Path $env:TEMP $dir
        if (Test-Path -LiteralPath $d) {
            $files = @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue)
            Add-Fact $dir ($files.Count.ToString() + ' file(s) in ' + $d)
            foreach ($file in $files) {
                Add-Line ('  - ' + $file.Name + '  (' + $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm') + ')')
                Add-Block (Get-ZtText $file.FullName) 'json'
            }
        } else {
            Add-Fact $dir ($d + ' -- NOT PRESENT (the hook has never fired)')
        }
    }
}

# ===========================================================================
#  9 - registry and live state
# ===========================================================================
Invoke-Section 'registry' {
    Add-Head '9. The registry and live state'

    Add-Fact 'ZT_CONFIG_HOME' $env:ZT_CONFIG_HOME
    Add-Fact 'ZT_DEVICE' $env:ZT_DEVICE

    $devPath = Get-ZtDeviceConfigPath
    $d = Add-FileFacts 'Device registry (this machine writes it)' $devPath
    if ($d.Exists) {
        Add-Block (Get-ZtText $devPath) 'json'
    } else {
        Add-Line '  Not an error on its own - the first `zt add` creates it.'
    }

    if ($repoRoot) {
        $shared = Join-Path $repoRoot (Join-Path 'config' 'workspaces.json')
        $s = Add-FileFacts 'Shared registry (ships with the clone)' $shared
        if ($s.Exists) { Add-Block (Get-ZtText $shared) 'json' }
    }

    Add-Line ''
    $liveBase = $env:LOCALAPPDATA
    if (-not $liveBase) { $liveBase = $env:TEMP }
    $liveDir = Join-Path $liveBase (Join-Path 'ZellijTerminal' 'live')
    if (Test-Path -LiteralPath $liveDir) {
        $recs = @(Get-ChildItem -LiteralPath $liveDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
        Add-Fact 'Live session records' ($recs.Count.ToString() + ' in ' + $liveDir)
        foreach ($r in $recs) {
            Add-Line ('  - ' + $r.Name)
            Add-Block (Get-ZtText $r.FullName) 'json'
        }
    } else {
        Add-Fact 'Live session records' ($liveDir + ' -- NOT PRESENT')
    }
}

# ===========================================================================
#  10 - Windows Terminal
# ===========================================================================
Invoke-Section 'terminal' {
    Add-Head '10. Windows Terminal'

    # The fragment is how the session gets its own profile and icon, and its
    # commandline is what actually runs when the profile is launched - so if the
    # window opens and closes, this is the command that did it.
    $frag = Join-Path $env:LOCALAPPDATA (Join-Path 'Microsoft' (Join-Path 'Windows Terminal' (Join-Path 'Fragments' (Join-Path 'ZellijTerminal' 'zellij-terminal.json'))))
    $f = Add-FileFacts 'Profile fragment' $frag
    if ($f.Exists) { Add-Block (Get-ZtText $frag) 'json' }

    $wtSettings = @(
        @(
            (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
            (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
            (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalCanary_8wekyb3d8bbwe\LocalState\settings.json'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
        ) | Where-Object { Test-Path -LiteralPath $_ }
    )
    Add-Fact 'Terminal settings.json found' $wtSettings.Count
    foreach ($w in $wtSettings) { Add-Line ('  - ' + $w) }

    # Findings only, never the file: it is the user's, it is long, and the two
    # settings that matter here are one regex each.
    if ($wtSettings.Count -gt 0) {
        $text = Get-ZtText $wtSettings[0]
        $live = ($text -split "`r?`n" | Where-Object { $_.TrimStart() -notlike '//*' }) -join "`n"

        $pref = [regex]::Match($live, '"firstWindowPreference"\s*:\s*"([^"]+)"')
        if ($pref.Success) { Add-Fact 'firstWindowPreference' $pref.Groups[1].Value }
        else { Add-Fact 'firstWindowPreference' 'not set (defaults to defaultProfile)' }

        $ctrlv = [regex]::Match($live, '\{[^{}]*"keys"\s*:\s*"ctrl\+v"[^{}]*\}', 'IgnoreCase')
        if ($ctrlv.Success) { Add-Fact 'ctrl+v entry' $ctrlv.Value }
        else { Add-Fact 'ctrl+v entry' 'none - Terminal owns it by default' }

        $profileHit = [regex]::Match($live, '"name"\s*:\s*"zellij-terminal"')
        Add-Fact 'zellij-terminal profile visible in settings' $profileHit.Success
    }

    $procs = @(Get-Process -Name 'WindowsTerminal*' -ErrorAction SilentlyContinue)
    Add-Fact 'Terminal processes running' ($procs.Count.ToString() + ' (' + (($procs | ForEach-Object { $_.ProcessName }) -join ', ') + ')')
}

# ===========================================================================
#  11 - environment
# ===========================================================================
Invoke-Section 'environment' {
    Add-Head '11. Environment'

    # NO_COLOR is inherited into every pane and is honoured BEFORE TERM and
    # COLORTERM, which is why the layout clears it explicitly. If it is set
    # here, panes started outside the layout are monochrome and it looks like a
    # Claude Code bug.
    foreach ($name in @('ZELLIJ', 'ZELLIJ_SESSION_NAME', 'ZELLIJ_PANE_ID',
                        'TERM', 'COLORTERM', 'NO_COLOR',
                        'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CONFIG_DIR', 'CLAUDE_PID',
                        'ZT_CONFIG_HOME', 'ZT_DEVICE')) {
        $val = [Environment]::GetEnvironmentVariable($name)
        if ($null -eq $val) { $val = '(not set)' }
        Add-Fact $name $val
    }

    if ($env:ZELLIJ) {
        Add-Signal 'This bundle was collected from INSIDE a Zellij pane. That is fine, but a pane inherits the server environment, so section 11 describes the pane rather than a fresh shell.'
    }

    Add-Line ''
    Add-Line '### PATH entries that matter'
    Add-Line ''
    $hits = @($env:PATH -split ';' | Where-Object { $_ -and ($_ -match 'zellij|PowerShell|WindowsApps|Claude') })
    Add-Block ($hits -join "`n")

    Add-Line ''
    Add-Fact 'Execution policy (this scope)' (Get-ExecutionPolicy -ErrorAction SilentlyContinue)
    $eps = @(Get-ExecutionPolicy -List -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Scope.ToString() + ' = ' + $_.ExecutionPolicy.ToString() })
    Add-Block ($eps -join "`n")

    # PowerToys and AutoHotkey, since one of them has to be listening for the
    # pad. Absent is not a fault - the pad is optional - so this is recorded
    # rather than signalled.
    $pt = @(Get-Process -Name 'PowerToys*' -ErrorAction SilentlyContinue)
    $ahk = @(Get-Process -Name 'AutoHotkey*' -ErrorAction SilentlyContinue)
    Add-Fact 'PowerToys processes' $pt.Count
    Add-Fact 'AutoHotkey processes' $ahk.Count

    $ptCfg = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\Keyboard Manager\default.json'
    $p = Add-FileFacts 'Keyboard Manager config' $ptCfg
    if ($p.Exists) { Add-Block (Get-ZtText $ptCfg) 'json' }
}

# ===========================================================================
#  12 - what zt check says
# ===========================================================================
Invoke-Section 'zt check' {
    Add-Head '12. `zt check`, for comparison'

    Add-Line 'Included because the interesting case is a clean run here next to a signal above.'
    Add-Line ''

    $check = Join-Path $PSScriptRoot 'Test-Setup.ps1'
    if (-not (Test-Path -LiteralPath $check)) {
        Add-Line ('Test-Setup.ps1 not found at ' + $check)
        return
    }

    # 6>&1 because Test-Setup writes with Write-Host, which is the Information
    # stream from PowerShell 5 onwards and is invisible to a plain capture.
    $out = & $check -Session $Session -Prefix $Prefix 6>&1 | Out-String
    Add-Block $out
}

# ===========================================================================
#  Assemble and write
# ===========================================================================

$header = New-Object System.Text.StringBuilder
[void]$header.AppendLine('')
[void]$header.AppendLine('## Signals')
[void]$header.AppendLine('')
if ($script:Signals.Count -eq 0) {
    [void]$header.AppendLine('None. Nothing this script knows how to notice is unusual, which means the')
    [void]$header.AppendLine('cause is something it does not check for - read the evidence sections.')
} else {
    foreach ($s in $script:Signals) {
        [void]$header.AppendLine('- ' + $s)
    }
}
if ($script:Failures.Count -gt 0) {
    [void]$header.AppendLine('')
    [void]$header.AppendLine('### Sections that failed to collect')
    [void]$header.AppendLine('')
    foreach ($f in $script:Failures) { [void]$header.AppendLine('- ' + $f) }
}

$final = $script:Report.ToString()
# The signals go after the preamble and before section 1, so the first screen of
# the bundle is the part worth reading first.
$anchor = '## 1. This machine'
$idx = $final.IndexOf($anchor)
if ($idx -ge 0) {
    $final = $final.Substring(0, $idx) + $header.ToString() + "`n" + $final.Substring($idx)
} else {
    $final = $final + $header.ToString()
}

$parent = Split-Path $Path -Parent
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}
Set-Content -LiteralPath $Path -Value $final -Encoding UTF8

Write-Host ''
if ($script:Signals.Count -eq 0) {
    Write-Host '  No signals raised. The bundle still carries the evidence.' -ForegroundColor DarkGray
} else {
    Write-Host ("  $($script:Signals.Count) signal(s):") -ForegroundColor Yellow
    foreach ($s in $script:Signals) { Write-Host ('    - ' + $s) -ForegroundColor Yellow }
}
Write-Host ''
Write-Host '  Bundle written to:' -ForegroundColor Green
Write-Host ("    $Path") -ForegroundColor White
Write-Host ''
Write-Host '  Send that file. It is redacted unless you passed -NoRedact.' -ForegroundColor DarkGray
Write-Host ''

return $Path
