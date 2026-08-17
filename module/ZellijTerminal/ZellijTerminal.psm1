<#
    ZellijTerminal (zt) - a registry and control surface for the workspaces you
    run inside one Zellij session.

    WHAT IS WHERE, AND WHY

    scripts\        the implementation for anything the macro pad or the Claude
                    Code hook touches. Those two callers cannot go through a
                    module: the pad runs `powershell.exe -NoProfile -File` and a
                    key press already costs ~458 ms, and the hook runs under
                    Windows PowerShell 5.1. Logic they need lives there.

    module\         everything you type. Registry, control, completion.

    config\         workspaces.json - shared, in git, ships with the clone. The
                    per-device registry is NOT here: it is state, so it lives in
                    %LOCALAPPDATA%\ZellijTerminal\devices\<HOST>.json. See
                    Private\Core.ps1 for why the split is what makes automatic
                    registration safe across machines, and why only one of the
                    two belongs in a working tree.

    The BODY here stays 5.1-clean - no ternary, no ??, no && / || chains -
    because code moves between here and scripts\ often enough that one syntax
    floor is safer than two, and scripts\ genuinely must parse under 5.1 for the
    hook. But the MODULE requires 7: install.ps1 junctions it onto the pwsh 7
    module path, which Windows PowerShell does not scan, so `zt` never autoloads
    there however compatible the syntax is. The manifest says 7.0 for that
    reason - describing the syntax rather than the product let a 5.1 user
    satisfy the manifest and still have nothing work.
#>

Set-StrictMode -Version 2.0

foreach ($folder in @('Private', 'Public')) {
    $dir = Join-Path $PSScriptRoot $folder
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.ps1' | Sort-Object Name)) {
        . $file.FullName
    }
}

# A default view, so `Get-ZellijTerminal` on its own is readable without anyone
# having to remember which of the fifteen properties matter.
Update-TypeData -TypeName 'ZellijTerminal.Workspace' `
    -DefaultDisplayPropertySet 'Id', 'State', 'Waiting', 'Kind', 'Tab', 'Path' `
    -Force

Set-Alias -Name zt  -Value Invoke-ZellijTerminal
Set-Alias -Name zac -Value Connect-ZellijTerminal

Export-ModuleMember `
    -Function @(
        'Invoke-ZellijTerminal',
        'Get-ZellijTerminal',
        'Select-ZellijTerminal',
        'Register-ZellijTerminal',
        'Unregister-ZellijTerminal',
        'Publish-ZellijTerminal',
        'Get-ZellijTerminalRoot',
        'Set-ZellijTerminalRoot',
        'Start-ZellijTerminal',
        'Stop-ZellijTerminal',
        'Restart-ZellijTerminal',
        'Remove-ZellijTerminalTab',
        'Sync-ZellijTerminal',
        'Set-ZellijTerminalWaiting',
        'Switch-ZellijTerminal',
        'Connect-ZellijTerminal',
        'Suspend-ZellijTerminal',
        'Resume-ZellijTerminal',
        'Edit-ZellijTerminalConfig',
        'Test-ZellijTerminalConfig',
        'Test-ZellijTerminalPad',
        'Debug-ZellijTerminalPad',
        'Install-ZellijTerminalPad',
        'Set-ZellijTerminalPadDevice',
        'Uninstall-ZellijTerminalPad',
        'Test-ZellijTerminal',
        'Get-ZellijTerminalDiagnostic',
        'Test-ZellijTerminalPaste',
        'Repair-ZellijTerminalPaste',
        'Get-ZellijTerminalHotkey',
        'Get-ZellijTerminalSession',
        'Remove-ZellijTerminalSession',
        'Add-ZellijTerminalDock',
        'Get-ZellijTerminalDock',
        'Install-ZellijTerminal',
        'Uninstall-ZellijTerminal',
        'Export-ZellijTerminal',
        'Import-ZellijTerminal',
        'Start-ZellijTerminalSetup',
        'Show-ZellijTerminalPadGuide',
        'Show-ZellijTerminalPaletteGuide'
    ) `
    -Alias @('zt', 'zac')

# This list and FunctionsToExport in the .psd1 must agree, and nothing enforced
# that until tests\Manifest.Tests.ps1 existed. A function present here but absent
# there is unreachable; present there but absent here is worse, because the
# dispatcher can still call it from inside the module, so `zt setup` works while
# Start-ZellijTerminalSetup does not - which is exactly how this drifted.








