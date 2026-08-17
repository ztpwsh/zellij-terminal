using Microsoft.CommandPalette.Extensions;
using Microsoft.CommandPalette.Extensions.Toolkit;
using Microsoft.CmdPal.Common.Commands;

namespace ZellijTerminal.Palette;

/// <summary>
/// The registry itself - edit it, check it, move it between machines.
///
/// A PAGE rather than nine more entries in the palette root. The root is shared
/// with every other extension the user has installed, so each item added there
/// is a tax on everything else they type; these are also the rarest verbs in
/// the set. One entry that opens a list keeps the root honest and still puts
/// every one of them two keystrokes away.
///
/// Everything here goes through the module for the same reason the rest does:
/// the id allocation, the device-scoped write and the {root, rel} resolution
/// are rules, and a second implementation of a rule is a second thing to be
/// wrong. The dialogs are PowerShell because a palette command cannot show a
/// file picker - the same trick `register a folder` already uses.
/// </summary>
internal sealed partial class ConfigPage : ListPage
{
    public ConfigPage()
    {
        Icon = ZtIcons.Edit;
        Title = "Zellij registry and config";
        Name = "Registry";
        Id = "zt.config";
        PlaceholderText = "Search";
    }

    public override IListItem[] GetItems() =>
    [
        new ListItem(new ZtGlobalCommand(
            "Edit this device's registry", ZtIcons.Edit,
            "Edit-ZellijTerminalConfig",
            "Opening the device registry", "zt.config.device"))
        {
            Title = "Edit this device's registry",
            Subtitle = DevicePathHint(),
            Icon = ZtIcons.Edit,
        },

        new ListItem(new ZtGlobalCommand(
            "Edit the shared list", ZtIcons.Edit,
            "Edit-ZellijTerminalConfig -Shared",
            "Opening the shared list", "zt.config.shared"))
        {
            Title = "Edit the shared list",
            Subtitle = "config\\workspaces.json - the definitions every machine gets",
            Icon = ZtIcons.Edit,
        },

        // Visible: the entire output IS the answer. Run through ZtCli.Run it
        // would render into a console nobody can see.
        new ListItem(new ZtGlobalCommand(
            "Check both config files", ZtIcons.Check,
            "Test-ZellijTerminalConfig | Out-Host; Read-Host 'enter to close'",
            "Checking the config", "zt.config.validate", visible: true))
        {
            Title = "Check both config files",
            Subtitle = "What `zt validate` says - run this after hand-editing",
            Icon = ZtIcons.Check,
        },

        new ListItem(new ZtGlobalCommand(
            "Roots on this device", ZtIcons.Folder,
            "Get-ZellijTerminalRoot | Out-Host; Read-Host 'enter to close'",
            "Listing roots", "zt.config.roots", visible: true))
        {
            Title = "Roots on this device",
            Subtitle = "Where this machine says each named root lives",
            Icon = ZtIcons.Folder,
        },

        // A root name cannot come from a folder picker, and the palette has no
        // text prompt, so this one owns a console for the length of a question.
        // Worth it: an undefined root is why a workspace reads "unavailable"
        // here, and until now the only fix was to go and find a shell.
        new ListItem(new ZtGlobalCommand(
            "Define a root", ZtIcons.Folder,
            "$n = Read-Host 'Root name (e.g. code)'; " +
            "if ($n) { " +
            "  Add-Type -AssemblyName System.Windows.Forms; " +
            "  $d = New-Object System.Windows.Forms.FolderBrowserDialog; " +
            "  $d.Description = \"Where is root '$n' on this machine?\"; " +
            "  if ($d.ShowDialog() -eq 'OK') { " +
            "    Set-ZellijTerminalRoot -Name $n -Path $d.SelectedPath -Confirm:$false; " +
            "    Write-Host \"root '$n' = $($d.SelectedPath)\" -ForegroundColor Green " +
            "  } " +
            "}; Read-Host 'enter to close'",
            "Naming a root", "zt.config.defineroot", visible: true))
        {
            Title = "Define a root",
            Subtitle = "Name it, then pick the folder - fixes an 'unavailable' workspace",
            Icon = ZtIcons.Folder,
        },

        new ListItem(new ZtGlobalCommand(
            "Export a bundle", ZtIcons.Export,
            "Add-Type -AssemblyName System.Windows.Forms; " +
            "$d = New-Object System.Windows.Forms.SaveFileDialog; " +
            "$d.Filter = 'zt bundle (*.json)|*.json'; " +
            "$d.FileName = \"zt-export-$env:COMPUTERNAME.json\"; " +
            "if ($d.ShowDialog() -eq 'OK') { Export-ZellijTerminal -Path $d.FileName -Confirm:$false }",
            "Pick where to save it", "zt.config.export"))
        {
            Title = "Export a bundle",
            Subtitle = "Everything this device has registered, as one file",
            Icon = ZtIcons.Export,
        },

        // -Force is NOT passed. Import overwrites existing registrations with
        // it, and a silent overwrite of the project list is the one outcome
        // nobody could undo from here. It reports what it skipped; re-run from
        // a shell with -Force if that is genuinely what was meant.
        new ListItem(new ZtGlobalCommand(
            "Import a bundle", ZtIcons.Import,
            "Add-Type -AssemblyName System.Windows.Forms; " +
            "$d = New-Object System.Windows.Forms.OpenFileDialog; " +
            "$d.Filter = 'zt bundle (*.json)|*.json'; " +
            "if ($d.ShowDialog() -eq 'OK') { " +
            "  Import-ZellijTerminal -Path $d.FileName -Confirm:$false | Out-Host; " +
            "  Read-Host 'enter to close' " +
            "}",
            "Pick a bundle to import", "zt.config.import", visible: true))
        {
            Title = "Import a bundle",
            Subtitle = "Add another machine's workspaces - existing ones are kept, not overwritten",
            Icon = ZtIcons.Import,
        },
    ];

    /// <summary>
    /// Say WHICH file, not just "the device registry". It moved out of the
    /// clone in 0.6.0 and can be moved again with ZT_CONFIG_HOME, so "where is
    /// it actually" stopped being a question with one answer.
    /// </summary>
    private static string DevicePathHint()
    {
        try { return ZtStore.DevicePathForDisplay(); }
        catch { return "This machine's workspaces and roots"; }
    }
}
