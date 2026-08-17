# The `hooks` key in a Claude Code settings.json is SHARED. Nothing else in
# this rig owns a key somebody else also writes to, which is why this file
# exists on its own.
#
# Both halves used to treat it as exclusively ours: install replaced the whole
# key, uninstall deleted the whole key. Anybody who also had a formatter hook,
# or a plugin's hooks, registered globally lost them to a zt install and again
# to a zt uninstall - silently, recoverable only from a timestamped .bak, and
# with the uninstaller printing "rest of the file backed up and kept" while it
# happened. The file was kept. Their hooks were not.
#
# The fix is to select OUR entries by the hook script name. That rule is now
# written twice - install.ps1 cannot import the module, because it runs before
# the module is installed and under Windows PowerShell 5.1 - so the first
# Context here runs both copies over the same table and requires them to agree.

BeforeDiscovery {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
}

Describe 'Claude Code hook registration' {

    BeforeAll {
        $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
        $script:InstallPs1 = Join-Path $script:RepoRoot 'install.ps1'
        $script:CorePs1    = Join-Path $script:RepoRoot 'module/ZellijTerminal/Private/Core.ps1'
        $script:Uninstall  = Join-Path $script:RepoRoot 'module/ZellijTerminal/Public/Uninstall.ps1'

        function Get-ZtFunctionText {
            # Lift one function out of a file by AST rather than by regex, so
            # this keeps working when the surrounding file moves around.
            param([string]$Path, [string]$Name)
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
            $fn = $ast.Find({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
            }, $true)
            if (-not $fn) { return $null }
            return $fn.Extent.Text
        }

        function Invoke-ZtClassifier {
            # Define the extracted copy in a throwaway scope and call it, so the
            # two same-named copies cannot shadow one another.
            param([string]$FunctionText, $Entry)
            $sb = [scriptblock]::Create($FunctionText + "`nTest-ZtOwnHookEntry -Entry `$args[0]")
            return [bool](& $sb $Entry)
        }

        $script:FromInstall = Get-ZtFunctionText -Path $script:InstallPs1 -Name 'Test-ZtOwnHookEntry'
        $script:FromModule  = Get-ZtFunctionText -Path $script:CorePs1    -Name 'Test-ZtOwnHookEntry'

        function New-ZtHookEntry {
            param([string]$File, [string]$Command = 'powershell.exe')
            return ([pscustomobject]@{
                hooks = @(
                    [pscustomobject]@{
                        type    = 'command'
                        command = $Command
                        args    = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $File)
                    }
                )
            })
        }

        # The table both copies must agree on. The stale-path case is the one
        # that matters most in practice: an entry left by a clone that has moved
        # is still OURS, so install replaces it instead of adding a second
        # registration beside it and firing two hooks per event.
        $script:Cases = @(
            @{ Name = 'ours at the current path'
               Entry = (New-ZtHookEntry -File 'F:/zellij-repo/hooks/claude-zj-hook.ps1')
               Ours = $true }
            @{ Name = 'ours at a path this clone has never been at'
               Entry = (New-ZtHookEntry -File 'C:/Users/someone/zellij-terminal/hooks/claude-zj-hook.ps1')
               Ours = $true }
            @{ Name = 'ours named in the command rather than the args'
               Entry = (New-ZtHookEntry -File '-' -Command 'C:/zt/hooks/claude-zj-hook.ps1')
               Ours = $true }
            @{ Name = 'somebody else s hook'
               Entry = (New-ZtHookEntry -File 'C:/tools/pro-workflow/hooks/format-on-stop.ps1')
               Ours = $false }
            @{ Name = 'a hook with no args at all'
               Entry = ([pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = 'echo hi' }) })
               Ours = $false }
            @{ Name = 'an entry with no hooks array'
               Entry = ([pscustomobject]@{ matcher = 'Write' })
               Ours = $false }
            @{ Name = 'nothing'
               Entry = $null
               Ours = $false }
        )
    }

    Context 'The two copies of the rule' {

        It 'exists in install.ps1' {
            $script:FromInstall | Should -Not -BeNullOrEmpty -Because (
                'install.ps1 classifies entries before the module it would otherwise import is installed')
        }

        It 'exists in the module' {
            $script:FromModule | Should -Not -BeNullOrEmpty -Because 'the uninstaller classifies the same entries'
        }

        It 'classifies <Name> the same way in both copies' -ForEach @(
            @{ Name = 'ours at the current path' }
            @{ Name = 'ours at a path this clone has never been at' }
            @{ Name = 'ours named in the command rather than the args' }
            @{ Name = 'somebody else s hook' }
            @{ Name = 'a hook with no args at all' }
            @{ Name = 'an entry with no hooks array' }
            @{ Name = 'nothing' }
        ) {
            $case = $script:Cases | Where-Object { $_.Name -eq $Name }
            $case | Should -Not -BeNullOrEmpty

            $viaInstall = Invoke-ZtClassifier -FunctionText $script:FromInstall -Entry $case.Entry
            $viaModule  = Invoke-ZtClassifier -FunctionText $script:FromModule  -Entry $case.Entry

            $viaInstall | Should -Be $case.Ours -Because "install.ps1 must see '$Name' as ours=$($case.Ours)"
            $viaModule  | Should -Be $case.Ours -Because "the module must agree"
            $viaInstall | Should -Be $viaModule -Because (
                'install and uninstall disagreeing about which entries are ours shows up as ' +
                'either somebody else s hooks deleted, or two zt hooks firing per event')
        }
    }

    Context 'The installer' {

        BeforeAll {
            $script:InstallText = Get-Content -LiteralPath $script:InstallPs1 -Raw
        }

        It 'does not replace the whole hooks key' {
            # The specific line that ate other people's hooks.
            $script:InstallText | Should -Not -Match "NotePropertyName 'hooks' -NotePropertyValue \`$incoming\.hooks" -Because (
                'that assigns OUR hooks object over whatever was there, discarding every foreign entry')
        }

        It 'walks the events of both sides and keeps what is not ours' {
            $script:InstallText | Should -Match 'Test-ZtOwnHookEntry' -Because 'it has to ask the question at all'
            $script:InstallText | Should -Match '\$foreignKept' -Because 'and count what it preserved, to be able to report it'
        }

        It 'reports an existing global registration instead of claiming repo-only scope' {
            # The reported symptom: on a machine where zt was already registered
            # globally, a repo-scope install announced "THIS repo only", which is
            # true of its own action and misleading about the machine.
            $script:InstallText | Should -Match 'ALREADY registered globally' -Because (
                'the installer has to read the global file before describing the state of the machine')
        }
    }

    Context 'The uninstaller' {

        BeforeAll {
            $script:UninstallText = Get-Content -LiteralPath $script:Uninstall -Raw
        }

        It 'removes only our entries rather than the whole key' {
            $script:UninstallText | Should -Match 'Remove-ZtOwnHookEntries' -Because 'it must classify before it deletes'
            $script:UninstallText | Should -Match '\$survivors' -Because 'and write back what was not ours'
        }

        It 'still drops the key entirely when nothing survives' {
            # Leaving "hooks": {} behind is a registration that does nothing,
            # which is harder to explain than an absent key.
            $script:UninstallText | Should -Match "PSObject\.Properties\.Remove\('hooks'\)"
        }

        It 'never deletes the global settings file' {
            # That file holds permissions, plugins and autoMode. Deleting it to
            # remove one key would cost somebody their whole Claude Code config.
            $script:UninstallText | Should -Not -Match 'Remove-Item.*globalHook'
        }

        It 'does not claim to have kept hooks it removed' {
            # The old message said "rest of the file backed up and kept" whether
            # or not it had just deleted somebody else's hooks.
            $script:UninstallText | Should -Match 'other hook entries left in place' -Because (
                'the count of what survived is the only honest version of that claim')
        }
    }

    Context 'The uninstall surgery, run for real' {

        # Remove-ZtOwnHookEntries exists as a function precisely so this can
        # happen: Uninstall-ZellijTerminal itself also removes the module
        # junction and restores Zellij's config, so calling it to test six lines
        # would uninstall the rig from whatever machine ran the suite.

        BeforeAll {
            Import-Module (Join-Path $script:RepoRoot 'module/ZellijTerminal/ZellijTerminal.psd1') -Force
            $script:Surgery = {
                param($Hooks)
                & (Get-Module ZellijTerminal) { Remove-ZtOwnHookEntries -Hooks $args[0] } $Hooks
            }

            function New-ZtHooksObject {
                param([string]$Json)
                return ($Json | ConvertFrom-Json)
            }
        }

        It 'takes ours out and leaves theirs alone' {
            $hooks = New-ZtHooksObject -Json @'
{
  "SessionStart": [
    { "hooks": [ { "type": "command", "args": ["-File", "C:/zt/hooks/claude-zj-hook.ps1"] } ] }
  ],
  "Stop": [
    { "hooks": [ { "type": "command", "args": ["-File", "C:/other/format.ps1"] } ] },
    { "hooks": [ { "type": "command", "args": ["-File", "C:/zt/hooks/claude-zj-hook.ps1"] } ] }
  ],
  "PostToolUse": [
    { "hooks": [ { "type": "command", "command": "echo", "args": ["theirs"] } ] }
  ]
}
'@
            $r = & $script:Surgery $hooks

            $r.OursRemoved | Should -Be 2
            $r.ForeignKept | Should -Be 2
            $r.Survivors   | Should -Not -BeNullOrEmpty

            # SessionStart held only ours, so the event goes entirely rather
            # than being written back as an empty array.
            @($r.Survivors.PSObject.Properties.Name) | Should -Not -Contain 'SessionStart'

            # Stop held one of each: theirs survives, alone.
            @($r.Survivors.Stop).Count | Should -Be 1
            (@($r.Survivors.Stop)[0].hooks[0].args -join ' ') | Should -Match 'format\.ps1'

            @($r.Survivors.PSObject.Properties.Name) | Should -Contain 'PostToolUse'
        }

        It 'reports nothing to do when none of the hooks are ours' {
            $hooks = New-ZtHooksObject -Json '{ "Stop": [ { "hooks": [ { "args": ["-File", "C:/other/x.ps1"] } ] } ] }'
            $r = & $script:Surgery $hooks

            $r.OursRemoved | Should -Be 0 -Because 'the caller uses this to leave the file completely untouched'
            $r.ForeignKept | Should -Be 1
        }

        It 'returns nothing to keep when every entry was ours' {
            $hooks = New-ZtHooksObject -Json '{ "Stop": [ { "hooks": [ { "args": ["-File", "C:/zt/hooks/claude-zj-hook.ps1"] } ] } ] }'
            $r = & $script:Surgery $hooks

            $r.OursRemoved | Should -Be 1
            $r.ForeignKept | Should -Be 0
            # Null rather than an empty object, so the caller drops the key.
            # "hooks": {} is a registration that does nothing, and is harder to
            # explain than an absent key.
            $r.Survivors | Should -BeNullOrEmpty
        }

        It 'survives a hooks object that is empty or absent' {
            $r = & $script:Surgery $null
            $r.OursRemoved | Should -Be 0
            $r.Survivors   | Should -BeNullOrEmpty
        }
    }

    Context 'zt check' {

        BeforeAll {
            $script:CheckText = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts/Test-Setup.ps1') -Raw
        }

        It 'reports a registration whose hook script is not there' {
            # A registered path that does not resolve fails per event, in the
            # background. The visible symptom is a tab glyph that never changes,
            # which reads as a zellij fault rather than a stale path.
            $script:CheckText | Should -Match 'Hook path exists' -Because 'registered is not the same as working'
        }
    }
}
