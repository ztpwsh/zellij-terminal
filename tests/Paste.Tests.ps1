<#
    Ctrl+V inside a Zellij pane.

    Zellij 0.44.3 on Windows never negotiates bracketed paste, so Windows
    Terminal types the clipboard in as ordinary keystrokes and every newline is
    Enter - which in Claude Code submits. The fix is two halves, one per layer,
    and the failure modes are all quiet:

      - Reading "no ctrl+v entry" as healthy. Terminal binds ctrl+v -> paste by
        DEFAULT, so a file that never mentions it is the broken case. A check
        that treated silence as neutrality would pass on every unfixed machine,
        which is every machine.
      - Fixing one half. Terminal unbound with no Claude binding leaves NOTHING
        pasting there, which is worse than the bug being fixed.
      - Round-tripping settings.json. It is JSONC; ConvertTo-Json deletes every
        comment in the user's file, including the ones Terminal writes itself.

    Green on a machine with no Zellij, no Windows Terminal and nothing
    installed: every case here runs against a fixture in a temp directory.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'module/ZellijTerminal/ZellijTerminal.psd1') -Force -ErrorAction SilentlyContinue
    $script:M = Get-Module ZellijTerminal

    $script:Paste     = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Paste.ps1') -Raw
    $script:Dispatch  = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Dispatch.ps1') -Raw
    $script:TestSetup = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts/Test-Setup.ps1') -Raw
    # The manifest is publishing machinery and is itself never published, so in
    # a published clone - which is where the release gate runs the suite - there
    # is nothing to read. See the ships assertion at the foot of this file.
    $script:ManifestPath = Join-Path $script:RepoRoot 'tools/publish.manifest'
    $script:Manifest     = $null
    if (Test-Path -LiteralPath $script:ManifestPath) {
        $script:Manifest = Get-Content -LiteralPath $script:ManifestPath -Raw
    }
    $script:Psd1      = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'module/ZellijTerminal/ZellijTerminal.psd1') -Raw

    $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ("zt-paste-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:Work -Force | Out-Null

    function New-WtFixture {
        param([string]$Body, [string]$Name = 'settings.json')
        $p = Join-Path $script:Work ((([guid]::NewGuid().ToString('N')).Substring(0, 6)) + '-' + $Name)
        Set-Content -LiteralPath $p -Value $Body -Encoding UTF8
        return $p
    }
}

AfterAll {
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) {
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Reading whether Terminal still owns Ctrl+V' {

    It '<Label> -> <Expected>' -ForEach @(
        @{ Label    = 'no ctrl+v entry at all, which is the DEFAULT and therefore broken'
           Expected = 'terminal'
           Body     = '{ "keybindings": [ { "id": "User.find", "keys": "ctrl+shift+f" } ] }' }

        @{ Label    = 'id-based paste binding, the current schema'
           Expected = 'terminal'
           Body     = '{ "keybindings": [ { "id": "User.paste", "keys": "ctrl+v" } ] }' }

        @{ Label    = 'old inline-command paste binding'
           Expected = 'terminal'
           Body     = '{ "actions": [ { "command": "paste", "keys": "ctrl+v" } ] }' }

        @{ Label    = 'unbound the id-based way'
           Expected = 'free'
           Body     = '{ "keybindings": [ { "id": null, "keys": "ctrl+v" } ] }' }

        @{ Label    = 'unbound the old way'
           Expected = 'free'
           Body     = '{ "actions": [ { "command": "unbound", "keys": "ctrl+v" } ] }' }

        @{ Label    = 'key order reversed - keys first, id second'
           Expected = 'free'
           Body     = '{ "keybindings": [ { "keys": "ctrl+v", "id": null } ] }' }
    ) {
        $f   = New-WtFixture -Body $Body
        $got = & $script:M { param($p) Get-ZtWtCtrlVState -Path $p } $f
        $got | Should -Be $Expected
    }

    It 'ignores a commented-out unbind, because Terminal writes its defaults out commented' {
        # A file carrying `// { "id": null, "keys": "ctrl+v" }` describes the
        # setting the user does NOT have. Reporting it as fixed would send
        # someone hunting the wrong layer - exactly what firstWindowPreference
        # had to learn.
        $f = New-WtFixture -Body @'
{
    // { "id": null, "keys": "ctrl+v" }
    "keybindings": [ { "id": "User.paste", "keys": "ctrl+v" } ]
}
'@
        (& $script:M { param($p) Get-ZtWtCtrlVState -Path $p } $f) | Should -Be 'terminal'
    }

    It 'says none, not terminal, when there is no settings.json to read' {
        # "Terminal owns it" is a claim about a file. With no file there is no
        # claim to make, and a WARN about a Terminal that is not installed is
        # noise.
        $missing = Join-Path $script:Work 'no-such-settings.json'
        (& $script:M { param($p) Get-ZtWtCtrlVState -Path $p } $missing) | Should -Be 'none'
    }
}

Describe 'Reading whether Claude Code has a Ctrl+V' {

    It 'is unset when the file does not exist' {
        $missing = Join-Path $script:Work 'no-keybindings.json'
        (& $script:M { param($p) Get-ZtClaudeCtrlVState -Path $p } $missing) | Should -Be 'unset'
    }

    It 'is bound only for chat:imagePaste in the Chat context' {
        $f = Join-Path $script:Work 'kb-good.json'
        Set-Content -LiteralPath $f -Encoding UTF8 -Value '{ "bindings": [ { "context": "Chat", "bindings": { "ctrl+v": "chat:imagePaste" } } ] }'
        (& $script:M { param($p) Get-ZtClaudeCtrlVState -Path $p } $f) | Should -Be 'bound'
    }

    It 'is unset when ctrl+v is bound in some other context' {
        # A binding in Global does not give the chat input a paste key, and
        # counting it would report the fix as done while nothing pastes.
        $f = Join-Path $script:Work 'kb-wrong-context.json'
        Set-Content -LiteralPath $f -Encoding UTF8 -Value '{ "bindings": [ { "context": "Global", "bindings": { "ctrl+v": "chat:imagePaste" } } ] }'
        (& $script:M { param($p) Get-ZtClaudeCtrlVState -Path $p } $f) | Should -Be 'unset'
    }

    It 'is unset when ctrl+v points at some other action' {
        $f = Join-Path $script:Work 'kb-wrong-action.json'
        Set-Content -LiteralPath $f -Encoding UTF8 -Value '{ "bindings": [ { "context": "Chat", "bindings": { "ctrl+v": "chat:submit" } } ] }'
        (& $script:M { param($p) Get-ZtClaudeCtrlVState -Path $p } $f) | Should -Be 'unset'
    }
}

Describe 'Fixing Terminal, without destroying the file' {

    It 'rewrites an existing binding and leaves every comment intact' {
        # THE WHOLE REASON THIS IS A TEXT EDIT. A JSON round-trip would drop
        # both comments below and the user would never be told.
        $body = @'
{
    // keep me
    "keybindings": [
        { "id": "User.paste", "keys": "ctrl+v" }
    ],
    // and me
    "copyOnSelect": false
}
'@
        $f = New-WtFixture -Body $body

        $r = & $script:M { param($p) Repair-ZtWtCtrlV -Path $p -Confirm:$false } $f
        $r | Should -Be 'rewrote'

        $after = Get-Content -LiteralPath $f -Raw
        $after | Should -Match '// keep me'
        $after | Should -Match '// and me'
        $after | Should -Match '"copyOnSelect"'
        (& $script:M { param($p) Get-ZtWtCtrlVState -Path $p } $f) | Should -Be 'free'
    }

    It 'inserts an unbind when the file never mentions ctrl+v' {
        $f = New-WtFixture -Body '{ "keybindings": [ { "id": "User.find", "keys": "ctrl+shift+f" } ] }'

        $r = & $script:M { param($p) Repair-ZtWtCtrlV -Path $p -Confirm:$false } $f
        $r | Should -Be 'inserted'
        (& $script:M { param($p) Get-ZtWtCtrlVState -Path $p } $f) | Should -Be 'free'

        # The binding it was told to keep must survive.
        (Get-Content -LiteralPath $f -Raw) | Should -Match 'ctrl\+shift\+f'
    }

    It 'converts the old inline-command form to unbound' {
        $f = New-WtFixture -Body '{ "actions": [ { "command": "paste", "keys": "ctrl+v" } ] }'

        (& $script:M { param($p) Repair-ZtWtCtrlV -Path $p -Confirm:$false } $f) | Should -Be 'rewrote'
        (Get-Content -LiteralPath $f -Raw) | Should -Match '"command"\s*:\s*"unbound"'
    }

    It 'is a no-op the second time, and reports it rather than writing again' {
        $f = New-WtFixture -Body '{ "keybindings": [ { "id": null, "keys": "ctrl+v" } ] }'
        (& $script:M { param($p) Repair-ZtWtCtrlV -Path $p -Confirm:$false } $f) | Should -Be 'already'
    }

    It 'writes a backup beside the file it changes' {
        # Recoverable by hand. The rest of the rig never touches settings.json,
        # so this is the one place that has to leave a way back.
        $f = New-WtFixture -Body '{ "keybindings": [ { "id": "User.paste", "keys": "ctrl+v" } ] }'
        & $script:M { param($p) Repair-ZtWtCtrlV -Path $p -Confirm:$false } $f | Out-Null

        @(Get-ChildItem -LiteralPath $script:Work -Filter '*.bak').Count | Should -BeGreaterThan 0
    }

    It 'changes nothing under -WhatIf' {
        $body = '{ "keybindings": [ { "id": "User.paste", "keys": "ctrl+v" } ] }'
        $f    = New-WtFixture -Body $body

        & $script:M { param($p) Repair-ZtWtCtrlV -Path $p -WhatIf } $f | Out-Null
        (Get-Content -LiteralPath $f -Raw).Trim() | Should -Be $body
    }
}

Describe 'Fixing Claude Code' {

    It 'creates the file when there is none, keeping alt+v alive by not touching it' {
        $f = Join-Path $script:Work 'kb-new.json'
        (& $script:M { param($p) Repair-ZtClaudeCtrlV -Path $p -Confirm:$false } $f) | Should -Be 'wrote'
        (& $script:M { param($p) Get-ZtClaudeCtrlVState -Path $p } $f) | Should -Be 'bound'

        # Additive, never a move: alt+v is the built-in and unbinding it would
        # trade one missing paste key for another.
        (Get-Content -LiteralPath $f -Raw) | Should -Not -Match 'alt\+v'
    }

    It 'merges into an existing Chat group rather than adding a second one' {
        # A duplicate context is a validation warning in Claude Code's own
        # loader, and the last one wins - so appending would silently drop
        # whatever the user already had in Chat.
        $f = Join-Path $script:Work 'kb-merge.json'
        Set-Content -LiteralPath $f -Encoding UTF8 -Value '{ "bindings": [ { "context": "Chat", "bindings": { "ctrl+e": "chat:externalEditor" } } ] }'

        & $script:M { param($p) Repair-ZtClaudeCtrlV -Path $p -Confirm:$false } $f | Out-Null

        $cfg  = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        $chat = @($cfg.bindings | Where-Object { $_.context -eq 'Chat' })
        $chat.Count | Should -Be 1
        "$($chat[0].bindings.'ctrl+e')" | Should -Be 'chat:externalEditor'
        "$($chat[0].bindings.'ctrl+v')" | Should -Be 'chat:imagePaste'
    }

    It 'is a no-op the second time' {
        $f = Join-Path $script:Work 'kb-twice.json'
        & $script:M { param($p) Repair-ZtClaudeCtrlV -Path $p -Confirm:$false } $f | Out-Null
        (& $script:M { param($p) Repair-ZtClaudeCtrlV -Path $p -Confirm:$false } $f) | Should -Be 'already'
    }
}

Describe 'The rule is written twice and must not drift' {

    # Test-Setup.ps1 cannot import the module: it runs under Windows PowerShell
    # 5.1 from the hook and the pad. So the ctrl+v rule exists in two places,
    # and this is what keeps them the same rule.

    It 'Test-Setup.ps1 uses the same entry-matching pattern as the module' {
        $pattern = '"keys"\\s\*:\\s\*"ctrl\\\+v"'
        $script:Paste     | Should -Match $pattern
        $script:TestSetup | Should -Match $pattern
    }

    It 'both treat a missing entry as Terminal owning the key' {
        # The single most important line in either copy. If this inverts, every
        # unfixed machine reports a clean bill of health.
        $script:Paste     | Should -Match 'if \(-not \$m\.Success\) \{ return .terminal. \}'
        $script:TestSetup | Should -Match '\$termOwnsCtrlV = \$true'
    }

    It 'both accept either way of saying unbound' {
        foreach ($src in @($script:Paste, $script:TestSetup)) {
            $src | Should -Match '"id"\\s\*:\\s\*null'
            $src | Should -Match '"command"\\s\*:\\s\*"unbound"'
        }
    }

    It 'both strip full-line comments before matching' {
        foreach ($src in @($script:Paste, $script:TestSetup)) {
            $src | Should -Match "notlike '//\*'"
        }
    }

    It 'the module never round-trips settings.json through ConvertTo-Json' {
        # The comment-destroying move. Write-ZtJson is fine for OUR json; it is
        # what writes Claude's keybindings. It must never see Terminal's file.
        $script:Paste | Should -Not -Match 'Write-ZtJson[^\r\n]*Terminal'
        $script:Paste | Should -Match 'Set-Content[^\r\n]*-NoNewline'
    }
}

Describe 'The worktree check' {

    It 'reads git worktree list rather than hard-coding a path' {
        # The release worktree has moved at least once, and a hard-coded path
        # silently stops checking anything when it does.
        $script:TestSetup | Should -Match 'worktree list --porcelain'
        $script:TestSetup | Should -Not -Match 'F:\\\\zellij-terminal'
    }

    It 'fails rather than warns, because the cost is destroyed work' {
        $script:TestSetup | Should -Match "'Release worktree' 'FAIL'"
    }

    It 'looks at live session records as well as registrations' {
        # A session running in the worktree is the urgent case: the publish
        # empties the directory under it and cannot even complete, because the
        # session holds it open.
        $script:TestSetup | Should -Match 'LIVE SESSION'
    }
}

Describe 'It is reachable and it ships' {

    It 'zt paste and zt paste fix both dispatch' {
        $script:Dispatch | Should -Match "'\^paste\$'"
        $script:Dispatch | Should -Match 'Test-ZellijTerminalPaste'
        $script:Dispatch | Should -Match 'Repair-ZellijTerminalPaste'
    }

    It 'paste is offered by tab completion' {
        # A verb missing from the completer still works when typed - it just
        # cannot be discovered, which for a fix nobody knows they need defeats
        # the point of it existing.
        $script:Dispatch | Should -Match "'pad', 'paste'"
    }

    It 'both commands are exported' {
        $script:Psd1 | Should -Match "'Test-ZellijTerminalPaste'"
        $script:Psd1 | Should -Match "'Repair-ZellijTerminalPaste'"
    }

    It 'Paste.ps1 is in the publish manifest, or the module ships broken' {
        # A file absent from the manifest is simply not copied, and the psd1
        # still lists functions whose source is gone.
        #
        # Two trees, two ways of asking the same question. In the source repo
        # the manifest is the only evidence available, because Paste.ps1 being
        # present there says nothing about whether it ships. In a published
        # clone the manifest is gone by design and the file itself is the
        # evidence - it is here precisely because the manifest named it. So
        # this stays a real assertion in both places rather than a skip, which
        # would have hidden the very omission it is here to catch.
        if ($script:Manifest) {
            $script:Manifest | Should -Match 'module/ZellijTerminal/Public/Paste\.ps1'
        } else {
            Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Paste.ps1' |
                Should -Exist
        }
    }
}
