using Microsoft.CommandPalette.Extensions;
using Microsoft.CommandPalette.Extensions.Toolkit;
using Microsoft.CmdPal.Common.Commands;   // ConfirmableCommand lives here, not in Toolkit

namespace ZellijTerminal.Palette;

/// <summary>
/// What appears in the palette's root.
///
/// The workspaces item's subtitle is the point of the whole exercise: "3
/// running, 1 WAITING" is visible every time the palette is opened for ANY
/// reason - launching a browser, finding a file - so a forgotten session
/// surfaces without anyone going looking for it. No other surface in this rig
/// can do that. zjstatus only reports while you are attached, which is exactly
/// when you least need telling.
/// </summary>
internal sealed partial class ZtCommandsProvider : CommandProvider
{
    private readonly CommandItem _workspaces;
    private readonly CommandItem _attach;
    private readonly CommandItem _waiting;
    private readonly CommandItem _park;
    private readonly CommandItem _restore;
    private readonly CommandItem _add;
    private readonly CommandItem _check;
    private readonly CommandItem _sessions;
    private readonly CommandItem _next;
    private readonly CommandItem _prev;
    private readonly CommandItem _sync;
    private readonly CommandItem _config;
    private readonly CommandItem _yes;
    private readonly CommandItem _no;

    public ZtCommandsProvider()
    {
        Id = "ZellijTerminal";
        DisplayName = "Zellij Terminal";
        Icon = ZtIcons.Terminal;

        _workspaces = new CommandItem(new WorkspacesPage())
        {
            Title = "Zellij workspaces",
            Subtitle = Summary(),
            Icon = ZtIcons.List,
        };

        _attach = new CommandItem(new ZtGlobalCommand(
            "Attach to the session", ZtIcons.Attach, "Connect-ZellijTerminal", "Attaching", "zt.attach"))
        {
            Title = "Zellij: attach",
            Subtitle = "Open a window on the session, or bring the existing one forward",
            Icon = ZtIcons.Attach,
        };

        _waiting = new CommandItem(new ZtGlobalCommand(
            "Jump to whoever is waiting", ZtIcons.Waiting, "Switch-ZellijTerminal -Waiting", "Jumping", "zt.waiting"))
        {
            Title = "Zellij: go to whoever is waiting",
            Subtitle = "Oldest waiter first; cycles if nobody is",
            Icon = ZtIcons.Waiting,
        };

        _park = new CommandItem(new ConfirmableCommand(
            new ZtGlobalCommand("Park everything", ZtIcons.Park, "Suspend-ZellijTerminal", "Parking"),
            "Park every running workspace?",
            "Stops each one and remembers what was running, so Restore can bring it back."))
        {
            Title = "Zellij: park everything",
            Subtitle = "Stop all running workspaces, remembering them",
            Icon = ZtIcons.Park,
        };

        _restore = new CommandItem(new ZtGlobalCommand(
            "Restore", ZtIcons.Restore, "Resume-ZellijTerminal", "Restoring"))
        {
            Title = "Zellij: restore",
            Subtitle = "Reopen what was running, resuming each conversation",
            Icon = ZtIcons.Restore,
        };

        _add = new CommandItem(new AddCurrentFolderCommand())
        {
            Title = "Zellij: register a folder",
            Subtitle = "Pick a directory and register it as a workspace",
            Icon = ZtIcons.Add,
        };

        _sessions = new CommandItem(new SessionsPage())
        {
            Title = "Zellij: sessions",
            Subtitle = "The level above tabs - attach, kill, delete",
            Icon = ZtIcons.Terminal,
        };

        // Pad keys 1 and 2, as commands. Here so they can be bound to a global
        // hotkey in Command Palette's settings - which is the test of whether
        // the palette can replace Keyboard Manager outright.
        _yes = new CommandItem(new AnswerPaneCommand(
            "Accept", "zt.answer.yes", ZtIcons.Check, 13, "Enter sent"))
        {
            Title = "Zellij: accept the prompt",
            Subtitle = "Enter into the focused pane - the pad's key 1",
            Icon = ZtIcons.Check,
        };

        _no = new CommandItem(new AnswerPaneCommand(
            "Reject", "zt.answer.no", ZtIcons.Close, 27, "Esc sent"))
        {
            Title = "Zellij: reject the prompt",
            Subtitle = "Esc into the focused pane - the pad's key 2",
            Icon = ZtIcons.Close,
        };

        _next = new CommandItem(new ZtGlobalCommand(
            "Next tab", ZtIcons.GoTo, "Switch-ZellijTerminal -Direction next", "Next tab", "zt.nexttab"))
        {
            Title = "Zellij: next tab",
            Subtitle = "Cycle the claude-* tabs - the pad's key 4",
            Icon = ZtIcons.GoTo,
        };

        // visible: this command is nothing BUT its output. It spent its whole
        // life claiming "in a window" while running under CreateNoWindow, so
        // the check rendered to a console nobody could see and then blocked on
        // its own Read-Host until the process was killed by hand.
        _check = new CommandItem(new ZtGlobalCommand(
            "Check the rig", ZtIcons.Check, "Test-ZellijTerminal | Out-Host; Read-Host 'enter to close'",
            "Running the layer check", "zt.check", visible: true))
        {
            Title = "Zellij: check the rig",
            Subtitle = "Run the four-layer check in a window",
            Icon = ZtIcons.Check,
        };

        _prev = new CommandItem(new ZtGlobalCommand(
            "Previous tab", ZtIcons.GoTo, "Switch-ZellijTerminal -Direction prev", "Previous tab", "zt.prevtab"))
        {
            Title = "Zellij: previous tab",
            Subtitle = "Cycle the claude-* tabs backwards",
            Icon = ZtIcons.GoTo,
        };

        // At the root rather than behind the config page, because the workspace
        // details pane tells you to run it - "a session checked in here but its
        // tab is gone ... `zt sync` clears it" - and then offered no way to.
        // Naming a fix you cannot perform is worse than not mentioning it.
        _sync = new CommandItem(new ZtGlobalCommand(
            "Sync", ZtIcons.Sync, "Sync-ZellijTerminal -Confirm:$false", "Clearing stale records", "zt.sync"))
        {
            Title = "Zellij: sync",
            Subtitle = "Forget sessions whose tab is gone - clears 'stale'",
            Icon = ZtIcons.Sync,
        };

        _config = new CommandItem(new ConfigPage())
        {
            Title = "Zellij: registry and config",
            Subtitle = "Edit, check, define roots, import and export",
            Icon = ZtIcons.Edit,
        };
    }

    public override ICommandItem[] TopLevelCommands()
    {
        // Recomputed per call so the count is current rather than whatever was
        // true when the extension process started.
        _workspaces.Subtitle = Summary();
        // Order is frequency, not category: the things reached mid-flow come
        // first, the ones you touch when something is wrong come last.
        return
        [
            _workspaces, _waiting, _yes, _no, _next, _prev, _attach, _sessions,
            _add, _park, _restore, _sync, _config, _check,
        ];
    }

    /// <summary>
    /// Typing a workspace name in the palette root goes straight there, without
    /// opening the list first. FallbackCommandItem is the supported primitive
    /// for this - it is offered only when nothing else matches what was typed.
    /// </summary>
    public override IFallbackCommandItem[] FallbackCommands() => [new GoToFallbackItem()];

    /// <summary>
    /// The dock - Command Palette's persistent strip, as opposed to the palette
    /// itself which only exists while summoned.
    ///
    /// This is the surface the tray icon was going to be for, and it is better:
    /// no resident process of our own, no icon to maintain, and it reads the
    /// same registry everything else does. "2 running, 1 WAITING" sits there
    /// whether or not you are attached, which is precisely the case zjstatus
    /// cannot cover.
    ///
    /// Deliberately two items and no more. A dock that lists every workspace
    /// stops being glanceable, and the list is one keystroke away.
    /// </summary>
    public override ICommandItem[] GetDockBands()
    {
        // Summary() and GetWorkspaces() both read through the two-second cache
        // in ZtStore. Without it this method - called repeatedly for a strip
        // that is always on screen - spawned three zellij.exe processes every
        // time, forever.
        _workspaces.Subtitle = Summary();

        var waiting = 0;
        try { waiting = ZtStore.GetWorkspaces().Count(w => w.Waiting); } catch { }

        // Only offer the jump when there is something to jump to, so the dock
        // says something by its shape as well as its text.
        return waiting > 0 ? [_workspaces, _waiting] : [_workspaces];
    }

    private static string Summary()
    {
        try
        {
            if (!ZellijCli.SessionExists()) return "session 'claude' is not running";

            var all = ZtStore.GetWorkspaces();
            var running = all.Count(w => w.State == "running");
            var waiting = all.Count(w => w.Waiting);

            var s = $"{all.Count} registered, {running} running";
            if (waiting > 0) s += $", {waiting} WAITING";
            if (!ZellijCli.IsClientAttached()) s += "  -  nothing attached";
            return s;
        }
        catch
        {
            return "Zellij workspaces";
        }
    }
}

/// <summary>Root-level "type a name, go there".</summary>
internal sealed partial class GoToFallbackItem : FallbackCommandItem
{
    private readonly GoToFallbackCommand _command;

    public GoToFallbackItem()
        : this(new GoToFallbackCommand()) { }

    // Both constructor parameters are strings - the command goes on the
    // inherited Command property rather than through the constructor, which is
    // not what the shape of the other item types suggests.
    private GoToFallbackItem(GoToFallbackCommand command)
        : base("Go to a Zellij workspace", "ZellijTerminal.GoTo")
    {
        _command = command;
        Command = command;
        Title = string.Empty;
        Subtitle = "Go to a Zellij workspace";
        Icon = ZtIcons.GoTo;
    }

    public override void UpdateQuery(string query)
    {
        var match = _command.Match(query);
        Title = match is null ? string.Empty : $"Go to {match.Id}";
        Subtitle = match?.Path ?? "Go to a Zellij workspace";
    }
}

internal sealed partial class GoToFallbackCommand : InvokableCommand
{
    private ZtWorkspace? _match;

    public GoToFallbackCommand()
    {
        Name = "Go to";
        Icon = ZtIcons.GoTo;
    }

    internal ZtWorkspace? Match(string query)
    {
        if (string.IsNullOrWhiteSpace(query)) { _match = null; return null; }

        var all = ZtStore.GetWorkspaces();
        _match = all.FirstOrDefault(w => w.Id.Equals(query, StringComparison.OrdinalIgnoreCase))
                 ?? all.FirstOrDefault(w => w.Id.StartsWith(query, StringComparison.OrdinalIgnoreCase));
        return _match;
    }

    public override ICommandResult Invoke()
    {
        if (_match is null || _match.Tab.Length == 0) return CommandResult.KeepOpen();
        ZellijCli.GoToTab(_match.Tab);
        return CommandResult.Dismiss();
    }
}

/// <summary>
/// Register a folder. Uses zt so the id allocation, tab-name collision check
/// and device-scoped write all behave exactly as they do from a shell.
/// </summary>
internal sealed partial class AddCurrentFolderCommand : InvokableCommand
{
    public AddCurrentFolderCommand()
    {
        Name = "Register a folder";
        Icon = ZtIcons.Add;
    }

    public override ICommandResult Invoke()
    {
        // No folder picker from a palette command, so hand it to a shell that
        // can show one and then register whatever comes back.
        //
        // Register AND start. `zt add` in a shell stays registration-only,
        // because -FromBookmarks can register twenty folders at once and
        // twenty tabs is not what anyone meant. Choosing one folder by hand in
        // a dialog carries the opposite intent: you picked it because you want
        // to work in it. Registering silently and leaving you to find the row
        // and press Enter is the same work split across two gestures, with
        // nothing on screen in between to say the first one worked.
        //
        // Passthru so the id is known without re-deriving it here - the leaf
        // is not always the id, since collisions get a key suffix.
        ZtCli.Run(
            "Add-Type -AssemblyName System.Windows.Forms; " +
            "$d = New-Object System.Windows.Forms.FolderBrowserDialog; " +
            "if ($d.ShowDialog() -eq 'OK') { " +
            "  $w = Register-ZellijTerminal -Path $d.SelectedPath -PassThru; " +
            "  if ($w) { Start-ZellijTerminal -Name $w.id } " +
            "}");
        return CommandResult.ShowToast("Pick a folder in the dialog");
    }
}








