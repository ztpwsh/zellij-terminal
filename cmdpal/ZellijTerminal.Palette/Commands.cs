using Microsoft.CommandPalette.Extensions;
using Microsoft.CommandPalette.Extensions.Toolkit;

namespace ZellijTerminal.Palette;

/// <summary>
/// One command per zt verb.
///
/// Each is a thin call into the module, so behaviour cannot drift between the
/// palette and the shell - the rules about attachment, focus confirmation and
/// resume-by-session-id all live in one place and this inherits them.
/// </summary>
internal static class ZtCommands
{
    // Ctrl+Alt is AltGr on a UK layout and is ruled out outright by D21 in
    // docs/02-decisions.md, so
    // every shortcut here is Ctrl or Ctrl+Shift. Chosen to be mnemonic rather
    // than clever: S start, T sTop, R restart, W close (window), F flag.
    internal static KeyChord Ctrl(int vkey) => KeyChordHelpers.FromModifiers(true, false, false, false, vkey, 0);
    internal static KeyChord CtrlShift(int vkey) => KeyChordHelpers.FromModifiers(true, false, true, false, vkey, 0);

    internal const int VkS = 0x53, VkT = 0x54, VkR = 0x52, VkW = 0x57,
                       VkF = 0x46, VkE = 0x45, VkC = 0x43, VkD = 0x44,
                       VkA = 0x41, VkG = 0x47, VkP = 0x50, VkO = 0x4F;
}

/// <summary>Focus a workspace's tab - the default action on every row.</summary>
internal sealed partial class GoToCommand : InvokableCommand
{
    private readonly ZtWorkspace _ws;

    public GoToCommand(ZtWorkspace ws)
    {
        _ws = ws;
        Name = "Go to";
        Icon = new IconInfo("");
    }

    public override ICommandResult Invoke()
    {
        if (_ws.Tab.Length == 0) return CommandResult.KeepOpen();

        // Not a formality. With nothing attached, go-to-tab-name is a silent
        // no-op that still exits 0, so without this the palette would close as
        // though it had worked.
        if (!ZellijCli.IsClientAttached())
        {
            return CommandResult.ShowToast("Nothing is attached to the session - use Attach first");
        }

        // Every workspace with a path gets a derived tab name whether or not a
        // tab exists (ZtStore.Build), so a non-empty Tab proves nothing. Only
        // running and tab-only actually have one. For the rest, go-to-tab-name
        // is another silent no-op that exits 0 - so a freshly registered
        // workspace swallowed Enter and dismissed the palette, which is
        // indistinguishable from having worked.
        //
        // Starting is what "go to" means for something not yet open, and it is
        // what you wanted if you selected the row. zt start creates the tab,
        // runs the command and focuses it, so the outcome is the same either
        // way: you end up looking at that folder.
        if (_ws.State is not ("running" or "tab-only"))
        {
            ZtCli.Run($"Start-ZellijTerminal -Name '{_ws.Id.Replace("'", "''")}'");
            return CommandResult.Dismiss();
        }

        ZellijCli.GoToTab(_ws.Tab);
        return CommandResult.Dismiss();
    }
}

/// <summary>Any zt verb that takes a workspace id.</summary>
internal sealed partial class ZtVerbCommand : InvokableCommand
{
    private readonly string _verb;
    private readonly string _id;
    private readonly string _toast;

    public ZtVerbCommand(string name, IconInfo icon, string verb, string id, string toast)
    {
        Name = name;
        Id = "zt." + verb + "." + id;
        Icon = icon;
        _verb = verb;
        _id = id;
        _toast = toast;
    }

    public override ICommandResult Invoke()
    {
        ZtCli.Run($"{_verb} -Name '{_id.Replace("'", "''")}' -Confirm:$false");
        return CommandResult.ShowToast(_toast);
    }
}

/// <summary>
/// A zt verb with no target - park, restore, attach - and anything else that is
/// just a line of PowerShell, including the ones that put up a file dialog.
///
/// `visible` gives the command a console window. Commands that exist to SHOW
/// you something (validate, roots, check) need one; commands that just act do
/// not, and a window flashing up for every start/stop would be noise.
/// </summary>
internal sealed partial class ZtGlobalCommand : InvokableCommand
{
    private readonly string _command;
    private readonly string _toast;
    private readonly bool _visible;

    public ZtGlobalCommand(string name, IconInfo icon, string command, string toast, string? id = null, bool visible = false)
    {
        Name = name;
        // An explicit id where one is going to be bound to a global hotkey -
        // deriving it from the display name makes the binding break the moment
        // the wording changes.
        Id = id ?? ("zt.global." + name.Replace(" ", string.Empty));
        Icon = icon;
        _command = command;
        _toast = toast;

        // A command containing Read-Host is, by definition, waiting for a
        // person - so it must have a window for that person to answer in.
        // Deciding it here rather than trusting each call site means it can
        // only be got wrong once, and it already was: `check the rig` shipped
        // promising "in a window", ran under CreateNoWindow, and left an
        // invisible pwsh blocked on its own prompt until it was killed by hand.
        _visible = visible || command.Contains("Read-Host", StringComparison.Ordinal);
    }

    public override ICommandResult Invoke()
    {
        if (_visible) ZtCli.RunVisible(_command); else ZtCli.Run(_command);
        return CommandResult.ShowToast(_toast);
    }
}

/// <summary>Open the workspace's directory, or open it in an editor.</summary>
internal sealed partial class OpenPathCommand : InvokableCommand
{
    private readonly string _path;
    private readonly string? _exe;

    public OpenPathCommand(string name, IconInfo icon, string path, string? exe = null)
    {
        Name = name;
        Icon = icon;
        _path = path;
        _exe = exe;
    }

    public override ICommandResult Invoke()
    {
        if (_exe is null) ZtCli.Open(_path);
        else ZtCli.OpenIn(_exe, _path);
        return CommandResult.Dismiss();
    }
}

/// <summary>Copy the workspace path.</summary>
internal sealed partial class CopyPathCommandZt : InvokableCommand
{
    private readonly string _path;

    public CopyPathCommandZt(string path)
    {
        _path = path;
        Name = "Copy path";
        Icon = new IconInfo("");
    }

    public override ICommandResult Invoke()
    {
        ClipboardHelper.SetText(_path);
        return CommandResult.ShowToast("Path copied");
    }
}




