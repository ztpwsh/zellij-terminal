<#
    Ctrl+V inside a Zellij pane.

    THE BUG THIS EXISTS FOR

    Windows Terminal wraps a paste in the bracketed-paste sequence `ESC[200~` /
    `ESC[201~` ONLY when the application it is talking to has enabled mode 2004.
    Inside a session that application is Zellij, not the pane - and Zellij 0.44.3
    on Windows never asks. So Terminal types the clipboard in as ordinary
    keystrokes, every newline is Enter, and a ten-line paste into Claude Code
    becomes ten prompts. Zellij never sees a paste either, so it cannot bracket
    the inner hop to the pane: one missing negotiation breaks both hops.

    It reads as a Claude Code bug, then as a TERM/COLORTERM bug, and is neither.
    Prove the layer with Claude out of the picture - paste two lines at a plain
    pwsh prompt inside a pane - before touching anything. Full write-up is B6 in
    docs/03-troubleshooting.md.

    THE FIX IS TWO HALVES, ONE PER LAYER

    1. Terminal stops owning Ctrl+V, so the keystroke reaches the application
       instead of triggering Terminal's own broken paste. PSReadLine then handles
       it and reads the clipboard directly.
    2. Claude Code gains a Ctrl+V of its own. It has none by default - it relied
       entirely on the terminal paste - so after step 1 the key does nothing
       there until it is pointed at `chat:imagePaste`, which despite the name is
       the clipboard read and handles text.

    Either half alone leaves you worse off than before, which is why `zt paste`
    reports them together and `zt paste fix` does both.

    WHY THIS IS NOT IN install.ps1

    The installer touches Windows Terminal through FRAGMENTS precisely so it
    never rewrites settings.json, which is JSONC: round-tripping it through
    ConvertTo-Json silently deletes every comment in the user's file. Keybindings
    cannot be set from a fragment. So the rewrite happens only when asked for by
    name, it is a targeted text edit rather than a re-serialisation, and it takes
    a backup first.
#>

function Get-ZtClaudeConfigDir {
    <#
        Where Claude Code keeps its per-user config. CLAUDE_CONFIG_DIR wins if
        set, exactly as Claude Code itself resolves it; otherwise ~\.claude.
    #>
    $dir = $env:CLAUDE_CONFIG_DIR
    if ($dir) { return $dir }

    $base = $env:USERPROFILE
    if (-not $base) { $base = $HOME }
    return (Join-Path $base '.claude')
}

function Get-ZtClaudeKeybindingsPath {
    return (Join-Path (Get-ZtClaudeConfigDir) 'keybindings.json')
}

function Get-ZtJsoncLive {
    <#
        A JSONC file's live text, with full-line comments dropped.

        Same rule as Get-ZtWtWindowPreference, and for the same reason: Terminal
        writes its own defaults out commented, so matching the raw file reports
        settings the user does NOT have. Comments are dropped for READING only -
        nothing here ever writes this text back.
    #>
    param([string]$Path)

    if (-not $Path) { return '' }
    try { $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop } catch { return '' }
    if (-not $text) { return '' }

    return (($text -split "`r?`n" | Where-Object { $_.TrimStart() -notlike '//*' }) -join "`n")
}

function Get-ZtWtCtrlVState {
    <#
        Does Windows Terminal still own Ctrl+V?

        Returns 'terminal' (Terminal will paste, so pastes shred inside Zellij),
        'free' (explicitly unbound - the keystroke reaches the application), or
        'none' when there is no settings.json to read.

        Two schemas, both live in the wild and both must be recognised:
            {"command": "paste",       "keys": "ctrl+v"}   old, action inline
            {"id": "User.paste",       "keys": "ctrl+v"}   current, id-based
        and the two ways of saying "leave it alone":
            {"command": "unbound",     "keys": "ctrl+v"}
            {"id": null,               "keys": "ctrl+v"}

        NO ENTRY AT ALL MEANS TERMINAL OWNS IT. Ctrl+V -> paste is one of
        Terminal's built-in defaults, so silence is not neutrality - it is the
        broken case, and treating a missing entry as "fine" would report a clean
        bill of health on a machine that shreds every paste.

        scripts/Test-Setup.ps1 mirrors this rule, because it must run under 5.1
        and cannot import the module. tests/Paste.Tests.ps1 pins the two
        together.
    #>
    param([string]$Path)

    if (-not $Path) { $Path = Get-ZtTerminalProfilePath }
    if (-not $Path) { return 'none' }

    $live = Get-ZtJsoncLive -Path $Path
    if (-not $live) { return 'none' }

    # These entries are flat objects, so "no nested braces" is a safe way to
    # isolate one without a JSON parser - which 5.1 cannot use on JSONC anyway.
    $m = [regex]::Match($live, '\{[^{}]*"keys"\s*:\s*"ctrl\+v"[^{}]*\}', 'IgnoreCase')
    if (-not $m.Success) { return 'terminal' }

    $entry = $m.Value
    if ($entry -match '"id"\s*:\s*null')              { return 'free' }
    if ($entry -match '"command"\s*:\s*"unbound"')    { return 'free' }
    return 'terminal'
}

function Get-ZtClaudeCtrlVState {
    <#
        Has Claude Code been given a Ctrl+V of its own?

        'bound' when ctrl+v maps to chat:imagePaste in the Chat context, 'unset'
        otherwise. Plain JSON here - this file is ours, it has no comments, and
        ConvertFrom-Json is safe on it.
    #>
    param([string]$Path)

    if (-not $Path) { $Path = Get-ZtClaudeKeybindingsPath }
    if (-not (Test-Path -LiteralPath $Path)) { return 'unset' }

    $cfg = Read-ZtJson -Path $Path
    if (-not $cfg) { return 'unset' }
    if ($cfg.PSObject.Properties.Name -notcontains 'bindings') { return 'unset' }

    foreach ($group in @($cfg.bindings)) {
        if (-not $group) { continue }
        if ("$($group.context)" -ne 'Chat') { continue }
        if (-not $group.bindings) { continue }
        $val = Get-ZtProp $group.bindings 'ctrl+v'
        if ("$val" -eq 'chat:imagePaste') { return 'bound' }
    }
    return 'unset'
}

function Test-ZellijTerminalPaste {
    <#
    .SYNOPSIS
        Report whether Ctrl+V will paste properly inside a Zellij pane.

    .DESCRIPTION
        Checks both layers and says which half is missing. Reads only; the fix
        is `zt paste fix`.

        Both halves must be in place. Terminal unbound on its own leaves Claude
        Code with no paste key at all, which looks like a worse bug than the one
        being fixed.

    .EXAMPLE
        zt paste
    #>
    [CmdletBinding()]
    param([switch]$PassThru)

    $wtPath  = Get-ZtTerminalProfilePath
    $kbPath  = Get-ZtClaudeKeybindingsPath
    $wt      = Get-ZtWtCtrlVState   -Path $wtPath
    $claude  = Get-ZtClaudeCtrlVState -Path $kbPath
    $ok      = ($wt -eq 'free') -and ($claude -eq 'bound')

    Write-Host ''
    Write-Host '  Ctrl+V inside a Zellij pane' -ForegroundColor Cyan
    Write-Host '  ---------------------------' -ForegroundColor DarkGray

    if ($wt -eq 'none') {
        Write-Host '  Windows Terminal   NO SETTINGS  no settings.json found' -ForegroundColor DarkGray
    } elseif ($wt -eq 'free') {
        Write-Host '  Windows Terminal   OK           ctrl+v is unbound, so the app receives it' -ForegroundColor Green
    } else {
        Write-Host '  Windows Terminal   OWNS CTRL+V  Terminal pastes it itself - shreds inside Zellij' -ForegroundColor Yellow
    }
    if ($wtPath) { Write-Host "                     $wtPath" -ForegroundColor DarkGray }

    if ($claude -eq 'bound') {
        Write-Host '  Claude Code        OK           ctrl+v -> chat:imagePaste' -ForegroundColor Green
    } else {
        Write-Host '  Claude Code        NO CTRL+V    it has none by default - alt+v is the built-in' -ForegroundColor Yellow
    }
    Write-Host "                     $kbPath" -ForegroundColor DarkGray

    Write-Host ''
    if ($ok) {
        Write-Host '  Both halves in place.' -ForegroundColor Green
    } else {
        Write-Host '  Multi-line pastes will arrive one line at a time inside Zellij,' -ForegroundColor Yellow
        Write-Host '  and in Claude Code every newline submits. Fix both halves:' -ForegroundColor Yellow
        Write-Host '      zt paste fix' -ForegroundColor Cyan
        Write-Host '  Until then alt+v works - it reads the clipboard through the OS,' -ForegroundColor DarkGray
        Write-Host '  so no terminal is involved. See docs/03-troubleshooting.md B6.' -ForegroundColor DarkGray
    }
    Write-Host ''

    if ($PassThru) {
        return [pscustomobject]@{
            Terminal     = $wt
            TerminalPath = $wtPath
            Claude       = $claude
            ClaudePath   = $kbPath
            Ok           = $ok
        }
    }
}

function Repair-ZtWtCtrlV {
    <#
        Unbind ctrl+v in Windows Terminal, as a TARGETED TEXT EDIT.

        Never ConvertFrom-Json | ConvertTo-Json: settings.json is JSONC and a
        round-trip deletes every comment in it, including the ones Terminal
        writes itself. Only the matched entry is touched; the rest of the file
        comes through byte for byte.

        Returns the action taken: 'already', 'rewrote', 'inserted', or a string
        starting with 'manual:' when the file has no array to insert into and
        guessing would be worse than saying so.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param([string]$Path)

    if (-not $Path) { $Path = Get-ZtTerminalProfilePath }
    if (-not $Path) { return 'manual: no settings.json found' }

    if ((Get-ZtWtCtrlVState -Path $Path) -eq 'free') { return 'already' }

    try { $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop } catch { return 'manual: unreadable' }
    if (-not $text) { return 'manual: empty' }

    # Match against the raw text, not the comment-stripped copy: the result is
    # what gets written back, so offsets have to be the real ones.
    $m = [regex]::Match($text, '\{[^{}]*"keys"\s*:\s*"ctrl\+v"[^{}]*\}', 'IgnoreCase')

    if ($m.Success) {
        $entry = $m.Value
        $new   = $entry
        if ($entry -match '"id"\s*:\s*("[^"]*"|null)') {
            $new = [regex]::Replace($entry, '"id"\s*:\s*("[^"]*"|null)', '"id": null')
        } elseif ($entry -match '"command"\s*:\s*"[^"]*"') {
            $new = [regex]::Replace($entry, '"command"\s*:\s*"[^"]*"', '"command": "unbound"')
        } else {
            return 'manual: ctrl+v entry has neither id nor command'
        }
        $out    = $text.Substring(0, $m.Index) + $new + $text.Substring($m.Index + $m.Length)
        $result = 'rewrote'
    } else {
        # No entry at all - Terminal's built-in default is in force, so one has
        # to be added. Insert at the head of the array: last-wins ordering is not
        # something to rely on when first position is unambiguous.
        $arr = [regex]::Match($text, '"keybindings"\s*:\s*\[')
        if ($arr.Success) {
            $ins = '{ "id": null, "keys": "ctrl+v" },'
        } else {
            $arr = [regex]::Match($text, '"actions"\s*:\s*\[')
            $ins = '{ "command": "unbound", "keys": "ctrl+v" },'
        }
        if (-not $arr.Success) { return 'manual: no keybindings or actions array to add to' }

        $at     = $arr.Index + $arr.Length
        $out    = $text.Substring(0, $at) + "`n        " + $ins + $text.Substring($at)
        $result = 'inserted'
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Unbind ctrl+v so the application receives it')) { return $result }

    # Backup first, named so it is obvious who wrote it and when. Same convention
    # as the firstWindowPreference change.
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "$Path.zt-$stamp.bak"
    Copy-Item -LiteralPath $Path -Destination $backup -Force
    Set-Content -LiteralPath $Path -Value $out -Encoding UTF8 -NoNewline
    Write-Verbose "Backup: $backup"
    return $result
}

function Repair-ZtClaudeCtrlV {
    <#
        Point Claude Code's ctrl+v at chat:imagePaste.

        ADDITIVE, never a move: alt+v is the documented built-in and unbinding it
        would trade one missing paste key for another. Merges into an existing
        Chat group rather than appending a second one, because a duplicate
        context is a validation warning in Claude Code's own loader.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param([string]$Path)

    if (-not $Path) { $Path = Get-ZtClaudeKeybindingsPath }
    if ((Get-ZtClaudeCtrlVState -Path $Path) -eq 'bound') { return 'already' }

    $cfg = Read-ZtJson -Path $Path
    if (-not $cfg) {
        $cfg = [pscustomobject]@{
            '$schema' = 'https://www.schemastore.org/claude-code-keybindings.json'
            '$docs'   = 'https://code.claude.com/docs/en/keybindings'
            bindings  = @()
        }
    }
    if ($cfg.PSObject.Properties.Name -notcontains 'bindings') {
        Add-Member -InputObject $cfg -NotePropertyName 'bindings' -NotePropertyValue @() -Force
    }

    $groups = @($cfg.bindings | Where-Object { $_ })
    $chat   = @($groups | Where-Object { "$($_.context)" -eq 'Chat' })[0]

    if ($chat) {
        if (-not $chat.bindings) {
            Add-Member -InputObject $chat -NotePropertyName 'bindings' -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        Add-Member -InputObject $chat.bindings -NotePropertyName 'ctrl+v' -NotePropertyValue 'chat:imagePaste' -Force
    } else {
        $groups += [pscustomobject]@{
            context  = 'Chat'
            bindings = [pscustomobject]@{ 'ctrl+v' = 'chat:imagePaste' }
        }
        $cfg.bindings = $groups
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Bind ctrl+v to chat:imagePaste')) { return 'would' }

    if (Test-Path -LiteralPath $Path) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -LiteralPath $Path -Destination "$Path.zt-$stamp.bak" -Force
    }
    Write-ZtJson -Path $Path -Object $cfg
    return 'wrote'
}

function Repair-ZellijTerminalPaste {
    <#
    .SYNOPSIS
        Make Ctrl+V paste properly inside a Zellij pane.

    .DESCRIPTION
        Does both halves - unbinds ctrl+v in Windows Terminal so the keystroke
        reaches the application, and binds ctrl+v to chat:imagePaste in Claude
        Code so it has one to receive.

        Backs up every file it touches. Terminal reloads settings.json on save;
        Claude Code reads keybindings at startup, so restart it.

    .EXAMPLE
        zt paste fix

    .EXAMPLE
        zt paste fix -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Host ''
    $wt = Repair-ZtWtCtrlV
    switch -Regex ($wt) {
        '^already$'  { Write-Host '  Windows Terminal   already unbound' -ForegroundColor DarkGray }
        '^rewrote$'  { Write-Host '  Windows Terminal   ctrl+v unbound (backup written alongside)' -ForegroundColor Green }
        '^inserted$' { Write-Host '  Windows Terminal   ctrl+v unbind added (backup written alongside)' -ForegroundColor Green }
        default      { Write-Host "  Windows Terminal   NOT CHANGED - $wt" -ForegroundColor Yellow
                       Write-Host '                     add this to the keybindings array yourself:' -ForegroundColor DarkGray
                       Write-Host '                       { "id": null, "keys": "ctrl+v" }' -ForegroundColor Cyan }
    }

    $cc = Repair-ZtClaudeCtrlV
    switch -Regex ($cc) {
        '^already$' { Write-Host '  Claude Code        already bound' -ForegroundColor DarkGray }
        '^wrote$'   { Write-Host '  Claude Code        ctrl+v -> chat:imagePaste' -ForegroundColor Green }
        default     { Write-Host "  Claude Code        $cc" -ForegroundColor DarkGray }
    }

    Write-Host ''
    Write-Host '  Terminal reloads on save. Restart Claude Code to load its keybindings.' -ForegroundColor DarkGray
    Write-Host '  alt+v keeps working either way.' -ForegroundColor DarkGray
    Write-Host ''
}
