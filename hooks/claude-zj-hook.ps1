<#
.SYNOPSIS
    Claude Code hook -> coloured activity in the zjstatus bar, plus flag files
    telling the macro pad which tab is waiting for you.

    Windows-native PowerShell equivalent of
    thoo/claude-code-zellij-status (bash + jq).

.DESCRIPTION
    Does two jobs from one hook:

      1. STATUS BAR. Keeps a per-project state map and pipes a single
         coloured line to the zjstatus "status" widget after every event.
         Uses zjstatus's dynamic render mode so #[fg=...] markup in the
         message is interpreted rather than printed.

      2. PAD TARGETING. Writes %TEMP%\claude-zellij-flags\<tab>.json when a
         session needs a human, so zj-claude-tab.ps1 -Waiting can jump
         straight there.

    The hook event is read from the stdin payload's hook_event_name, so ONE
    registration block covers every event - no per-event -Event argument.

    WHY NOT RENAME TABS
      `zellij action rename-tab` renames the FOCUSED tab, not the tab the
      command runs in, and there's no reliable pane->tab lookup on the CLI.
      A hook firing in a background tab would rename whatever you were
      looking at. The upstream project avoids this the same way - pane-keyed
      state piped to zjstatus, never a rename.

    WHEN IT GOES WRONG
      Failures are logged to %TEMP%\claude-zellij-hook.log, one line each, and
      `zt check` reports the file under "Hook errors". Nothing is logged on a
      healthy run; set ZT_HOOK_DEBUG=1 for successful events too.

      This exists because the hook is the least observable thing in the rig - it
      runs detached under powershell.exe with output going nowhere, so a
      malformed payload used to mean it quietly did nothing and every symptom
      pointed at the pad, or Zellij, or the layout. It still exits 0 whatever
      happens: a hook that fails a session is worse than a hook that fails.

.NOTES
    Registration JSON and the zjstatus layout block are at the bottom.
#>

[CmdletBinding()]
param(
    # THE LEGACY PREFIX, and only that. Tabs stopped being named `claude-<leaf>`
    # in 0.7.20 - seven columns on every tab, on a bar where the chunk that does
    # not fit is dropped whole. Nothing ADDS it any more; this is what recognises
    # a tab created before the change, so an old session keeps its tab, its flag
    # file and its place in the pad's cycle without being renamed.
    [string]$Prefix = 'claude-'
)

$ErrorActionPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
#  Failure log
# ---------------------------------------------------------------------------
#  This hook is the least observable thing in the rig. It runs detached under
#  powershell.exe on every session event, with stdout and stderr going nowhere.
#  Every catch below used to be empty, so a malformed payload or an unreadable
#  state file meant it quietly did nothing: no flag raised, no status piped, no
#  trace anywhere - and every downstream symptom pointed at the pad, or Zellij,
#  or the layout. That is exactly the silent-failure-that-exits-0 this whole
#  project exists to make impossible, sitting in the one component where it is
#  hardest to see.
#
#  So: one line per failure. Errors only unless ZT_HOOK_DEBUG is set, because
#  this runs on the latency path of every prompt. Truncated so it cannot grow
#  without bound, and wrapped in its own try so logging can never become the
#  thing that breaks the hook. `zt check` reports this file, so a failure here
#  surfaces in the same place you already look.
$ZtHookLog = Join-Path $env:TEMP 'claude-zellij-hook.log'

function Write-ZtHookLog {
    param([string]$Stage, [string]$Detail)
    try {
        if ((Test-Path -LiteralPath $ZtHookLog) -and
            ((Get-Item -LiteralPath $ZtHookLog).Length -gt 256KB)) {
            Remove-Item -LiteralPath $ZtHookLog -Force -ErrorAction SilentlyContinue
        }
        Add-Content -LiteralPath $ZtHookLog -ErrorAction SilentlyContinue -Value (
            '{0}  {1,-14} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Stage, $Detail)
    } catch { }
}

function Write-ZtHookDebug {
    param([string]$Stage, [string]$Detail)
    if ($env:ZT_HOOK_DEBUG) { Write-ZtHookLog $Stage $Detail }
}

# ---------------------------------------------------------------------------
#  Read the hook payload
# ---------------------------------------------------------------------------
$payload = $null
try {
    $raw = [Console]::In.ReadToEnd()
    if ($raw) { $payload = $raw | ConvertFrom-Json }
} catch {
    # The one that mattered most: if Claude Code's payload cannot be parsed,
    # everything below falls back to defaults and the hook reports on the wrong
    # tab - or no tab - while looking like it ran fine.
    Write-ZtHookLog 'payload' ("could not read or parse stdin: " + $_.Exception.Message)
}

$hookEvent = if ($payload.hook_event_name) { $payload.hook_event_name } else { 'Unknown' }
$cwd       = if ($payload.cwd)             { $payload.cwd }             else { (Get-Location).Path }
$toolName  = $payload.tool_name

$project   = Split-Path $cwd -Leaf
$tab       = $project          # no prefix since 0.7.20; see -Prefix above
$zjSess    = $env:ZELLIJ_SESSION_NAME
$sessionId = $payload.session_id

# ---------------------------------------------------------------------------
#  Live record - tells `zt` this folder has a session running in it
# ---------------------------------------------------------------------------
#  Written on SessionStart, deleted on SessionEnd, and touched by nothing else.
#  Deliberately NOT a call into the ZellijTerminal module: importing a module
#  costs more than this whole hook, the module lives on the pwsh 7 module path
#  and this runs under 5.1, and this code is on the latency path of every
#  session. So it writes one small file and lets `zt` do the thinking.
#
#  The key is a hash of the normalised path because the identity of a workspace
#  is its directory - two folders called 'api' are two workspaces - and the hook
#  has to compute that with no config lookup and no state. Get-ZtKey in the
#  module computes the same value the same way; they must not drift.
function Get-ZtKeyForPath {
    param([string]$Path)

    $norm  = ($Path.TrimEnd('\', '/').ToLowerInvariant()) -replace '/', '\'
    $sha   = [System.Security.Cryptography.SHA1]::Create()
    try   { $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($norm)) }
    finally { $sha.Dispose() }

    $hex = ''
    foreach ($b in $bytes[0..3]) { $hex += $b.ToString('x2') }
    return $hex
}

# ---------------------------------------------------------------------------
#  Which tab is this session ACTUALLY in?
# ---------------------------------------------------------------------------
#  $tab above is a guess from the cwd leaf, and it is wrong the moment a
#  session works in a subfolder: `F:\proj\cmdpal` derives `claude-cmdpal`, a
#  tab that does not exist. Everything downstream then points somewhere
#  useless - the bar shows a name matching no tab, `zj-claude-tab.ps1 -Waiting`
#  filters the flag out as unreachable so key 3 will not jump to it, and the
#  tab it is really in never gets its glyph. Observed live: a session in
#  `zellij-terminal\cmdpal` sat on the bar saying `! cmdpal` with no way to
#  reach it and no indication which tab wanted attention.
#
#  So walk up from the cwd and take the first ancestor that has a real tab.
#  One list-tabs per session - cached beside the other transient state, the
#  negative included, because this is the latency path of every event.
$tabCacheFile = Join-Path (Join-Path $env:TEMP 'claude-zellij-status') ('tab-' + (Get-ZtKeyForPath $cwd) + '.txt')
$tabId        = $null
$lastGlyph    = ''

if ($zjSess) {
    if ($hookEvent -ne 'SessionStart' -and (Test-Path -LiteralPath $tabCacheFile)) {
        $cached = (Get-Content -LiteralPath $tabCacheFile -Raw) -split '\|'
        if ($cached.Count -ge 3 -and $cached[1] -match '^-?\d+$') {
            $tab       = $cached[0]
            $tabId     = [int]$cached[1]
            $lastGlyph = $cached[2].Trim()
        }
    }

    if ($null -eq $tabId) {
        # Candidates, nearest first. Bounded: past a handful of levels this is
        # matching coincidences rather than the project a session belongs to.
        # Carry the DIRECTORY each candidate came from, not just its name. The
        # tab name gets corrected below when a subfolder session matches an
        # ancestor's tab, and the live record has to be keyed by that same
        # ancestor or the correction is only half done - see $keyPath.
        $candidates = @()
        $walk = $cwd
        for ($d = 0; $d -lt 6 -and $walk; $d++) {
            $leaf = Split-Path $walk -Leaf
            if (-not $leaf) { break }
            # BOTH SPELLINGS, new first. A session that predates 0.7.20 is
            # sitting in a tab called `claude-<leaf>` and must still be found,
            # or the hook silently decorates nothing and the glyph never moves.
            $candidates += New-Object psobject -Property @{ Name = $leaf;             Path = $walk }
            $candidates += New-Object psobject -Property @{ Name = ($Prefix + $leaf); Path = $walk }
            $up = Split-Path $walk -Parent
            if (-not $up -or $up -eq $walk) { break }
            $walk = $up
        }

        $live = @{}
        foreach ($row in (& zellij --session $zjSess action list-tabs 2>$null)) {
            # "ID  POSITION  NAME", and NAME carries a glyph once decorated, so
            # it is everything after the second column rather than the third
            # whitespace-separated field.
            $m = [regex]::Match([string]$row, '^\s*(\d+)\s+\d+\s+(.+?)\s*$')
            if ($m.Success) {
                $nm = $m.Groups[2].Value -replace ' [v!?*>~#@&+.]$', ''
                if (-not $live.ContainsKey($nm)) { $live[$nm] = [int]$m.Groups[1].Value }
            }
        }

        $tabId = -1
        foreach ($c in $candidates) {
            if ($live.ContainsKey($c.Name)) {
                $tab     = $c.Name
                $tabId   = $live[$c.Name]
                $keyPath = $c.Path
                break
            }
        }
    }

    # The bar is keyed by project, and it should agree with the tab rather than
    # with whichever folder the session is sitting in.
    $project = $tab -replace ('^' + [regex]::Escape($Prefix)), ''
}

# THE RECORD IS KEYED BY THE PROJECT, NOT BY WHERE THE SESSION IS SITTING.
#
# The tab name is corrected above when a session runs in a subfolder - a session
# in F:\proj\cmdpal derives claude-cmdpal, no such tab exists, and the walk finds
# the ancestor whose tab does. The record used to be written from the raw cwd
# anyway, so the two halves disagreed: `zt` matches records to workspaces by key
# alone, so the workspace registered at F:\proj never saw a record and reported
# stopped while its session was plainly running - and the orphan record under the
# subfolder key got offered as a workspace of its own.
#
# $keyPath is the directory whose tab was matched, and falls back to the cwd when
# nothing was corrected, which is every ordinary session.
if (-not $keyPath) { $keyPath = $cwd }

$liveBase = $env:LOCALAPPDATA
if (-not $liveBase) { $liveBase = $env:TEMP }
$liveDir  = Join-Path $liveBase 'ZellijTerminal\live'
$liveFile = Join-Path $liveDir ((Get-ZtKeyForPath $keyPath) + '.json')

if ($hookEvent -eq 'SessionEnd') {
    Remove-Item -LiteralPath $liveFile -Force -ErrorAction SilentlyContinue
}
elseif ($hookEvent -eq 'SessionStart') {
    if (-not (Test-Path -LiteralPath $liveDir)) {
        New-Item -ItemType Directory -Path $liveDir -Force | Out-Null
    }
    # THE PID IS WHAT MAKES SessionEnd OPTIONAL.
    #
    # SessionEnd is pure cleanup - it deletes this record, the waiting flag, the
    # status entry and the tab cache. But it runs while Claude Code is shutting
    # down, and Claude cancels hooks that have not finished by the time it goes:
    # "SessionEnd hook [...] failed: Hook cancelled", for every hook registered,
    # not just this one. powershell.exe alone takes ~500 ms to start, so losing
    # that race is normal rather than exceptional. Every one of those five files
    # then leaks, and nothing could tell a leaked record from a live one.
    #
    # CLAUDE_PID is set by Claude Code in the environment of everything it
    # spawns, and it is the pid of the claude process itself - so it costs
    # nothing to record here and lets a reader prove the session is gone.
    # startedAt doubles as the guard against pid reuse: a process holding this
    # pid that started AFTER we did is somebody else.
    [ordered]@{
        key       = (Get-ZtKeyForPath $keyPath)
        cwd       = $keyPath
        tab       = $tab
        kind      = 'claude'
        sessionId = $sessionId
        zjSession = $zjSess
        pid       = $env:CLAUDE_PID
        startedAt = (Get-Date).ToString('o')
        lastEvent = $hookEvent
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $liveFile -Encoding UTF8
}

# ---------------------------------------------------------------------------
#  Symbol + colour for the current activity
#  Catppuccin-ish palette; swap freely.
# ---------------------------------------------------------------------------
function Get-Activity {
    param([string]$EventName, [string]$Tool)

    switch ($EventName) {
        'Notification'      { return @{ s = '!'; c = '#F38BA8'; wait = $true  } }  # red
        'PermissionRequest' { return @{ s = '?'; c = '#F38BA8'; wait = $true  } }  # red
        'Stop'              { return @{ s = 'v'; c = '#A6E3A1'; wait = $true  } }  # green
        'SubagentStop'      { return @{ s = 'v'; c = '#A6E3A1'; wait = $true  } }
        'SessionStart'      { return @{ s = '.'; c = '#6C7086'; wait = $false } }  # grey
        'UserPromptSubmit'  { return @{ s = '*'; c = '#F9E2AF'; wait = $false } }  # yellow
        'PostToolUse'       { return @{ s = '*'; c = '#F9E2AF'; wait = $false } }
        'PreToolUse' {
            switch -Regex ($Tool) {
                '^Bash$'                 { return @{ s = '>'; c = '#FAB387'; wait = $false } }  # orange
                '^(Read|Glob|Grep)$'     { return @{ s = '~'; c = '#89B4FA'; wait = $false } }  # blue
                '^(Write|Edit)$'         { return @{ s = '#'; c = '#F5C2E7'; wait = $false } }  # pink
                '^(WebSearch|WebFetch)$' { return @{ s = '@'; c = '#94E2D5'; wait = $false } }  # teal
                '^(Task|Skill)$'         { return @{ s = '&'; c = '#CBA6F7'; wait = $false } }  # purple
                '^AskUserQuestion$'      { return @{ s = '?'; c = '#F38BA8'; wait = $true  } }
                '^mcp'                   { return @{ s = '+'; c = '#CBA6F7'; wait = $false } }
                default                  { return @{ s = '*'; c = '#F9E2AF'; wait = $false } }
            }
        }
        default             { return @{ s = '*'; c = '#F9E2AF'; wait = $false } }
    }
}

# ---------------------------------------------------------------------------
#  The right-hand strip: what each project is doing, in as few columns as it can
# ---------------------------------------------------------------------------
#  WIDTH IS THE SCARCE RESOURCE, and this widget shares it with the tabs.
#
#  A bar over its width budget is not wrapped and not truncated: the chunk that
#  does not fit is DROPPED WHOLE, and which chunk loses is whichever one does
#  not fit in what the others left. Rendered into a 280-column probe screen and
#  read back off the client, 8 tabs beside a 196-column strip painted every tab
#  name and not one character of the strip. So every column spent here is a
#  column the tab names do not get, and past the budget this widget simply
#  stops existing. The way to spend them is on the projects that need you
#  rather than the ones that are merely busy:
#
#    waiting   `v web-api`   named, because you have to go and find it
#    working   `~`           one coloured glyph, no name
#
#  Nothing is lost by dropping the name from a working project. The tab it
#  belongs to carries the same glyph, so the name is already on screen a few
#  columns to the left - printing it again here is what was pushing it off.
#  Three busy projects cost 5 columns instead of 43.
#
#  `wait` comes from the same table as the symbol and the colour, so what this
#  strip promotes cannot drift from what the glyph says. A record written
#  before 0.7.17 has no `wait` field at all; $null -eq $true is false, so it
#  reads as working and corrects itself on that project's next event.
function Test-ZtHookLiveRecordAlive {
    <#
        Is the session this live record describes still running?

        THIRD COPY OF THIS RULE. The other two are Test-ZtLiveRecordAlive in
        module\ZellijTerminal\Private\Core.ps1 and IsLiveRecordAlive in
        cmdpal\...\ZtStore.cs, and tests\Live.Tests.ps1 pins all three together -
        the hook cannot report a different answer from `zt` about whether a
        session is alive. It needs its own copy because it must not import the
        module: it runs under Windows PowerShell 5.1, off the pwsh module path,
        on the latency path of every session start.

          - no pid at all -> ALIVE. Older records and `zt start` of a pwsh
            workspace have none, and absence of evidence is not death.
          - pid gone -> dead.
          - pid present but that process started AFTER the record -> dead, and
            the pid has been reused by somebody unrelated.
    #>
    param($Record)

    if (-not $Record) { return $false }

    $recPid = $null
    if ($Record.PSObject.Properties.Name -contains 'pid') { $recPid = $Record.pid }
    if (-not $recPid) { return $true }

    $n = 0
    if (-not [int]::TryParse("$recPid", [ref]$n)) { return $true }
    if ($n -le 0) { return $true }

    $proc = Get-Process -Id $n -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }

    $startedAt = $null
    if ($Record.PSObject.Properties.Name -contains 'startedAt') { $startedAt = $Record.startedAt }
    if ($startedAt) {
        $when = [datetime]::MinValue
        if ([datetime]::TryParse("$startedAt", [ref]$when)) {
            try { if ($proc.StartTime -gt $when) { return $false } } catch { }
        }
    }

    return $true
}

function Remove-ZtDeadStatus {
    <#
        Drop projects from the status map whose Claude session is gone.

        THE MAP NEVER FORGOT ANYTHING. Until now the only thing that removed an
        entry was SessionEnd - and SessionEnd is the event this rig already
        knows it cannot rely on, because Claude cancels hooks that have not
        finished as it shuts down and powershell.exe alone costs ~500 ms to
        start. So a window closed with the X, a reboot, or a killed Claude left
        its entry behind forever. There was no expiry, no reconciliation and no
        cap.

        That is a slow failure and it takes the TAB NAMES with it. Both sides of
        the bar spend from one width budget, and a chunk that does not fit is
        dropped whole rather than truncated - so the strip grows by two columns
        per dead project, silently, for days, and then one morning every tab
        name is gone at once and nothing the user did that day explains it.
        `tab_display_count` does not help: it bounds the tab COUNT, and this is
        the other side of the bar.

        CLAUDE_PID is already written into the live record for exactly this -
        "lets a reader prove the session is gone" is what the comment there
        says. The status map was the one consumer that never asked.

        Conservative on purpose: an entry is dropped only when a live record
        exists for it AND that record is provably dead. An entry with NO record
        is kept, because the hook may have been registered mid-session and
        guessing dead would erase a project that is running.
    #>
    param($State, [string]$LiveDir, [string]$Prefix, [string]$Keep)

    if (-not $State -or $State.Count -eq 0) { return $State }
    if (-not $LiveDir -or -not (Test-Path -LiteralPath $LiveDir)) { return $State }

    $dead = @{}
    try {
        foreach ($f in (Get-ChildItem -LiteralPath $LiveDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
            $rec = $null
            try { $rec = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
            if (-not $rec) { continue }

            $recTab = ''
            if ($rec.PSObject.Properties.Name -contains 'tab') { $recTab = "$($rec.tab)" }
            if (-not $recTab) { continue }

            # The live name can carry the activity glyph; the identity does not.
            $base = ($recTab -replace '\s+[^\s]$', '')
            $base = $base -replace ('^' + [regex]::Escape($Prefix)), ''
            if (-not $base) { continue }

            if (-not (Test-ZtHookLiveRecordAlive $rec)) { $dead[$base] = $true }
        }
    } catch { return $State }

    foreach ($k in @($State.Keys)) {
        if ($k -eq $Keep) { continue }
        if ($dead.ContainsKey($k)) { $State.Remove($k) }
    }

    return $State
}

function Get-ZtStatusLine {
    param($State)

    $waiting = @()
    $working = @()
    foreach ($k in ($State.Keys | Sort-Object)) {
        $e = $State[$k]
        if ($e.wait -eq $true) { $waiting += "#[fg=$($e.color)]$($e.symbol) $k" }
        else                   { $working += "#[fg=$($e.color)]$($e.symbol)" }
    }

    $groups = @()
    if ($waiting.Count) { $groups += ($waiting -join '  ') }
    if ($working.Count) { $groups += ($working -join ' ') }
    return ($groups -join '  ')
}

$act = Get-Activity -EventName $hookEvent -Tool $toolName

# ---------------------------------------------------------------------------
#  Flag file - drives  zj-claude-tab.ps1 -Waiting
# ---------------------------------------------------------------------------
$flagDir  = Join-Path $env:TEMP 'claude-zellij-flags'
$flagFile = Join-Path $flagDir ($tab + '.json')
if (-not (Test-Path -LiteralPath $flagDir)) {
    New-Item -ItemType Directory -Path $flagDir -Force | Out-Null
}

if ($hookEvent -eq 'SessionEnd') {
    Remove-Item -LiteralPath $flagFile -Force -ErrorAction SilentlyContinue
}
elseif ($act.wait) {
    [ordered]@{
        tab = $tab; cwd = $cwd; event = $hookEvent
        waiting = $true; since = (Get-Date).ToString('o')
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $flagFile -Encoding UTF8
}
else {
    Remove-Item -LiteralPath $flagFile -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
#  Shared state map, so the bar shows EVERY project at once
# ---------------------------------------------------------------------------
$stateDir  = Join-Path $env:TEMP 'claude-zellij-status'
if (-not (Test-Path -LiteralPath $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}
# if/else rather than a ternary: `? :` is PowerShell 7+ only, and this must
# also run under the Windows PowerShell 5.1 that ships with Windows.
if ($zjSess) { $sessKey = $zjSess } else { $sessKey = 'default' }
$stateFile = Join-Path $stateDir ($sessKey + '.json')

# Crude lock - several sessions can fire hooks at the same moment.
$lockFile = $stateFile + '.lock'
$lock = $null
for ($i = 0; $i -lt 25; $i++) {
    try {
        $lock = [System.IO.File]::Open($lockFile, 'OpenOrCreate', 'ReadWrite', 'None')
        break
    } catch { Start-Sleep -Milliseconds 20 }
}

try {
    $state = @{}
    if (Test-Path -LiteralPath $stateFile) {
        try {
            (Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json).PSObject.Properties |
                ForEach-Object { $state[$_.Name] = $_.Value }
        } catch { }
    }

    if ($hookEvent -eq 'SessionEnd') {
        $state.Remove($project)
    } else {
        $state[$project] = [pscustomobject]@{
            symbol = $act.s
            color  = $act.c
            wait   = $act.wait
            ts     = (Get-Date).ToString('o')
        }
    }

    # PRUNE BEFORE THE WRITE, not just before the render. Pruning only the
    # rendered line would leave the dead entries on disk to be re-read, re-
    # pruned and re-written for ever - correct on screen, and a file that grows
    # without bound behind it.
    $state = Remove-ZtDeadStatus -State $state -LiveDir $liveDir -Prefix $Prefix -Keep $project

    $state | ConvertTo-Json -Depth 4 -Compress |
        Set-Content -LiteralPath $stateFile -Encoding UTF8

    # ---- build one line, no newlines allowed -------------------------------
    # Already pruned above, before the write.
    $line = Get-ZtStatusLine -State $state

    if ($zjSess -and $line) {
        # DO NOT call `zellij pipe` and wait for it.
        #
        # With zjstatus listening, `zellij pipe` NEVER RETURNS - it holds the
        # pipe open streaming plugin output back, and the plugin never closes
        # it. Every invocation form blocks: bare payload, --name, --name with
        # --plugin. Claude Code waits for its hooks, so a blocking call here
        # freezes Claude on every single event. Verified on Zellij 0.44.3 with
        # zjstatus v0.24.0.
        #
        # So: start it, give it a moment to deliver, then stop waiting. With no
        # plugin listening it exits by itself in ~50 ms and the grace period
        # costs nothing; only the zjstatus case pays the cap.
        #
        # ProcessStartInfo.Arguments (a single string) rather than .ArgumentList
        # - the latter is .NET Core only and this must run on Windows
        # PowerShell 5.1. $line is built from a fixed symbol/colour table and
        # never contains a double quote, so wrapping it is safe.
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName        = 'zellij'
            $psi.Arguments       = '--session "' + $zjSess + '" pipe "zjstatus::pipe::pipe_status::' + $line + '"'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow  = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            if ($proc) {
                if (-not $proc.WaitForExit(200)) {
                    # Expected whenever zjstatus is loaded. The payload has been
                    # delivered; we are only declining to wait for a stream that
                    # will never end.
                    try { $proc.Kill() } catch { }
                }
                $proc.Dispose()
            }
        } catch { }
    }
}
finally {
    if ($lock) { $lock.Close() }
    Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
#  The tab says what it is doing, in the tab bar itself
# ---------------------------------------------------------------------------
#  The status widget on the right can only say WHICH project is busy; it cannot
#  point at a tab. So the tab carries its own glyph: `claude-web-api ~`.
#
#  `rename-tab -t <id>` targets a tab without moving focus - verified on 0.44.3,
#  and it is why the old rule "hooks must never call rename-tab" no longer
#  holds. The bare form still renames whatever is FOCUSED, so the -t is not
#  optional here; without it a background session would rename the tab you are
#  looking at.
#
#  The colour cannot come along. zjstatus substitutes {name} as plain text, so
#  #[fg=...] inside a tab name prints literally - tested. Glyph here, colour on
#  the right, and they are fed from the same table.
#
#  NEVER rename a tab that was not positively identified. $tabId is -1 when the
#  walk up from the cwd found nothing, and renaming on a near-miss would rewrite
#  somebody else's tab.
if ($zjSess) {
    try {
        if ($tabId -ge 0) {
            if ($hookEvent -eq 'SessionEnd') { $want = '' } else { $want = $act.s }

            if ($want -ne $lastGlyph) {
                if ($want) { $newName = $tab + ' ' + $want } else { $newName = $tab }

                # Detached, like the pipe above: this is on the latency path of
                # every tool call and Claude Code waits for its hooks. rename-tab
                # answers in ~50 ms, so the cap is a backstop rather than the
                # normal path.
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName        = 'zellij'
                $psi.Arguments       = '--session "' + $zjSess + '" action rename-tab -t ' + $tabId + ' "' + $newName + '"'
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow  = $true
                $proc = [System.Diagnostics.Process]::Start($psi)
                if ($proc) {
                    if (-not $proc.WaitForExit(400)) { try { $proc.Kill() } catch { } }
                    $proc.Dispose()
                }
            }
        }

        # tab|id|glyph. The resolved TAB NAME is cached too, not just the id:
        # re-deriving it from the cwd on the next event would land back on the
        # subfolder guess this block exists to correct.
        if ($hookEvent -eq 'SessionEnd') {
            Remove-Item -LiteralPath $tabCacheFile -Force -ErrorAction SilentlyContinue
        } else {
            $dir = Split-Path $tabCacheFile -Parent
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Set-Content -LiteralPath $tabCacheFile -Value ($tab + '|' + $tabId + '|' + $act.s) -Encoding UTF8
        }
    } catch {
        Write-ZtHookLog 'tabname' ("could not decorate the tab: " + $_.Exception.Message)
    }
}

exit 0

<#
==============================================================================
 1. ZJSTATUS LAYOUT  -  add to your claude.kdl (or default.kdl)
==============================================================================

 layout {
     default_tab_template {
         children
         pane size=1 borderless=true {
             plugin location="zjstatus" {
                 format_left   "{mode} {tabs}"
                 format_right  "{pipe_status}"

                 tab_display_count "8"

                 pipe_status_format     "{output}"
                 pipe_status_rendermode "dynamic"
             }
         }
     }

     tab name="claude-api" cwd="C:/code/api" { pane command="claude" }
     tab name="claude-web" cwd="C:/code/web" { pane command="claude" }
 }

 `rendermode "dynamic"` is the line that makes colours work - it tells
 zjstatus to interpret the #[fg=...] markup in the piped message instead of
 printing it literally. With the default "static" mode you get grey text and
 visible escape codes.

 `tab_display_count` is the line that keeps the tab names on screen. A bar over
 its width budget is not wrapped and not truncated - the chunk that does not
 fit is dropped WHOLE, so an over-long tab list does not shorten, it vanishes,
 leaving the mode indicator and this widget painting on their own. A window
 bounds what the tab list can ask for, and zjstatus always keeps the active tab
 inside it. `format_hide_on_overlength` sounds like the fix and is not: measured
 with and without, the painted output was identical. This widget still spends as
 few columns as it can (see Get-ZtStatusLine), because past the budget it is the
 one that gets dropped.

 Widget naming: sending  zjstatus::pipe::pipe_status::MSG  feeds the widget
 referenced as {pipe_status} and configured via pipe_status_format.

==============================================================================
 2. HOOK REGISTRATION  -  ~/.claude/settings.json
==============================================================================
 One identical block per event; the script reads hook_event_name from stdin,
 so no per-event arguments are needed.

{
  "hooks": {
    "SessionStart":      [ { "hooks": [ { "type": "command", "command": "powershell.exe",
      "args": ["-NoProfile","-ExecutionPolicy","Bypass","-File","C:/tools/claude-zj-hook.ps1"] } ] } ],
    "UserPromptSubmit":  [ { "hooks": [ { "type": "command", "command": "powershell.exe",
      "args": ["-NoProfile","-ExecutionPolicy","Bypass","-File","C:/tools/claude-zj-hook.ps1"] } ] } ],
    "PreToolUse":        [ { "hooks": [ { "type": "command", "command": "powershell.exe",
      "args": ["-NoProfile","-ExecutionPolicy","Bypass","-File","C:/tools/claude-zj-hook.ps1"] } ] } ],
    "PostToolUse":       [ { "hooks": [ { "type": "command", "command": "powershell.exe",
      "args": ["-NoProfile","-ExecutionPolicy","Bypass","-File","C:/tools/claude-zj-hook.ps1"] } ] } ],
    "PermissionRequest": [ { "hooks": [ { "type": "command", "command": "powershell.exe",
      "args": ["-NoProfile","-ExecutionPolicy","Bypass","-File","C:/tools/claude-zj-hook.ps1"] } ] } ],
    "Notification":      [ { "hooks": [ { "type": "command", "command": "powershell.exe",
      "args": ["-NoProfile","-ExecutionPolicy","Bypass","-File","C:/tools/claude-zj-hook.ps1"] } ] } ],
    "Stop":              [ { "hooks": [ { "type": "command", "command": "powershell.exe",
      "args": ["-NoProfile","-ExecutionPolicy","Bypass","-File","C:/tools/claude-zj-hook.ps1"] } ] } ],
    "SessionEnd":        [ { "hooks": [ { "type": "command", "command": "powershell.exe",
      "args": ["-NoProfile","-ExecutionPolicy","Bypass","-File","C:/tools/claude-zj-hook.ps1"] } ] } ]
  }
}

 Providing "args" selects exec form: no shell, no quoting problems, and
 powershell.exe is a real executable. Shell form would default to Git Bash on
 Windows unless you set "shell": "powershell".

 PreToolUse and PostToolUse fire constantly. If the bar feels noisy or Claude
 feels sluggish, drop those two - Stop / Notification / PermissionRequest /
 UserPromptSubmit alone still give you the colours that matter.

==============================================================================
 3. TEST
==============================================================================
   type $env:TEMP\claude-zellij-status\claude.json     # state map
   dir  $env:TEMP\claude-zellij-flags                  # waiting flags

 Pipe a line by hand to prove zjstatus is wired up:
   zellij --session claude pipe "zjstatus::pipe::pipe_status::#[fg=#A6E3A1]v test"
==============================================================================
#>
