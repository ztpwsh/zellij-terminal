using Microsoft.CommandPalette.Extensions;
using Microsoft.CommandPalette.Extensions.Toolkit;
using Microsoft.CmdPal.Common.Commands;   // ConfirmableCommand lives here, not in Toolkit

namespace ZellijTerminal.Palette;

/// <summary>
/// The list of workspaces, with every zt verb on each row.
///
/// DynamicListPage rather than ListPage because the state behind it changes
/// while the palette is open - a session finishes, a flag appears - and a page
/// showing what was true when it opened would be wrong in exactly the moments
/// this exists for.
/// </summary>
internal sealed partial class WorkspacesPage : DynamicListPage
{
    public WorkspacesPage()
    {
        Icon = ZtIcons.List;
        Title = "Zellij workspaces";
        Name = "Workspaces";

        // Stable, because Command Palette's dock pins bands by ProviderId plus
        // CommandId in its own settings. Without a fixed id the band cannot be
        // referenced, and a band that moves is worse than no band.
        Id = "zt.workspaces";
        PlaceholderText = "Search workspaces";
        ShowDetails = true;

        Current = this;
    }

    /// <summary>
    /// The live page, so a zt command that finishes in the background can ask
    /// for a redraw.
    ///
    /// Every mutating command runs through ZtCli.Run, which starts a detached
    /// pwsh and returns at once - it has to, because "Register a folder" opens
    /// a folder dialog and the user may take a minute over it. So the write
    /// lands long after Invoke() returned its toast, and nothing re-queried:
    /// you registered a folder, the palette said it had, and the list did not
    /// change. It looked like the add had failed when it had already succeeded.
    ///
    /// One instance is created, in ZtCommandsProvider's constructor.
    /// </summary>
    internal static WorkspacesPage? Current { get; private set; }

    internal static void RequestRefresh()
    {
        try { Current?.RaiseItemsChanged(0); } catch { }
    }

    public override void UpdateSearchText(string oldSearch, string newSearch) => RaiseItemsChanged(0);

    public override IListItem[] GetItems()
    {
        var all = ZtStore.GetWorkspaces();

        var search = SearchText ?? string.Empty;
        if (search.Length > 0)
        {
            all = all.Where(w =>
                    w.Id.Contains(search, StringComparison.OrdinalIgnoreCase) ||
                    w.Path.Contains(search, StringComparison.OrdinalIgnoreCase))
                .ToList();
        }

        if (all.Count == 0)
        {
            return
            [
                new ListItem(new NoOpCommand())
                {
                    Title = search.Length > 0 ? $"No workspace matches '{search}'" : "No workspaces registered on this device",
                    Subtitle = "Run  zt add .  in a project folder",
                }
            ];
        }

        // Said once rather than per row: while nothing is attached, every jump
        // below is a silent no-op that still reports success.
        var detached = !ZellijCli.IsClientAttached();

        return [.. all.Select(w => BuildItem(w, detached))];
    }

    private static ListItem BuildItem(ZtWorkspace w, bool detached)
    {
        var tags = new List<ITag> { new Tag(w.Waiting ? "WAITING" : w.State) };
        if (w.Kind != "claude") tags.Add(new Tag(w.Kind));

        var subtitle = w.Path;
        if (w.Waiting && w.WaitEvent.Length > 0) subtitle = $"{w.WaitEvent}  -  {w.Path}";
        if (detached) subtitle = "(nothing attached)  " + subtitle;

        var more = new List<CommandContextItem>();

        if (w.State is "stopped" or "tab-only" or "stale")
        {
            more.Add(new CommandContextItem(
                new ZtVerbCommand("Start", ZtIcons.Start, "Start-ZellijTerminal", w.Id, $"Starting {w.Id}"))
            { RequestedShortcut = ZtCommands.Ctrl(ZtCommands.VkS) });
        }

        if (w.State is "running" or "tab-only")
        {
            more.Add(new CommandContextItem(
                new ZtVerbCommand("Stop", ZtIcons.Stop, "Stop-ZellijTerminal", w.Id, $"Stopping {w.Id}"))
            { RequestedShortcut = ZtCommands.Ctrl(ZtCommands.VkT) });

            more.Add(new CommandContextItem(
                new ZtVerbCommand("Restart (resumes the session)", ZtIcons.Restart, "Restart-ZellijTerminal", w.Id, $"Restarting {w.Id}"))
            { RequestedShortcut = ZtCommands.Ctrl(ZtCommands.VkR) });
        }

        more.Add(new CommandContextItem(
            w.Waiting
                ? new ZtVerbCommand("Lower its hand", ZtIcons.Waiting, "Set-ZellijTerminalWaiting -Clear", w.Id, $"Lowered {w.Id}")
                : new ZtVerbCommand("Raise its hand", ZtIcons.Waiting, "Set-ZellijTerminalWaiting", w.Id, $"Flagged {w.Id}"))
        { RequestedShortcut = ZtCommands.Ctrl(ZtCommands.VkF) });

        // Promote this device's registration to the shared list. Not
        // destructive and not confirmed, but deliberately not the default
        // action either: `zt publish` is the separate, considered step that
        // says "every machine should have this", which is the whole reason
        // automatic registration only ever writes the device file.
        more.Add(new CommandContextItem(
            new ZtVerbCommand("Publish to the shared list", ZtIcons.Publish,
                "Publish-ZellijTerminal", w.Id, $"Published {w.Id} to the shared list"))
        { RequestedShortcut = ZtCommands.Ctrl(ZtCommands.VkP) });

        if (w.Path.Length > 0)
        {
            more.Add(new CommandContextItem(
                new OpenPathCommand("Open folder", ZtIcons.Folder, w.Path))
            { RequestedShortcut = ZtCommands.Ctrl(ZtCommands.VkE) });

            more.Add(new CommandContextItem(new OpenPathCommand("Open in VS Code", ZtIcons.Code, w.Path, "code")));
            more.Add(new CommandContextItem(new CopyPathCommandZt(w.Path))
            { RequestedShortcut = ZtCommands.CtrlShift(ZtCommands.VkC) });
        }

        // Destructive, so they carry confirmation and sit at the bottom.
        // IsCritical colours them as the dangerous ones they are.
        more.Add(new CommandContextItem(
            new ConfirmableCommand(
                new ZtVerbCommand("Close tab", ZtIcons.Close, "Remove-ZellijTerminalTab", w.Id, $"Closed {w.Id}"),
                $"Close {w.Id}?",
                "The tab and whatever is running in it will be closed. The workspace stays registered."))
        { RequestedShortcut = ZtCommands.Ctrl(ZtCommands.VkW), IsCritical = true });

        more.Add(new CommandContextItem(
            new ConfirmableCommand(
                new ZtVerbCommand("Unregister", ZtIcons.Delete, "Unregister-ZellijTerminal", w.Id, $"Unregistered {w.Id}"),
                $"Unregister {w.Id}?",
                "Removes it from this device's registry. The directory itself is untouched."))
        { RequestedShortcut = ZtCommands.Ctrl(ZtCommands.VkD), IsCritical = true });

        return new ListItem(new GoToCommand(w))
        {
            Title = w.Id,
            Subtitle = subtitle,
            Tags = [.. tags],
            MoreCommands = [.. more],
            Details = new Details
            {
                Title = w.Id,
                Body = BuildDetails(w, detached),
            },
        };
    }

    private static string BuildDetails(ZtWorkspace w, bool detached)
    {
        var lines = new List<string>
        {
            $"**State**  {(w.Waiting ? "WAITING - " + w.WaitEvent : w.State)}",
            $"**Kind**   {w.Kind}",
            $"**Tab**    {w.Tab}",
            $"**Path**   {w.Path}",
        };

        if (w.SessionId.Length > 0) lines.Add($"**Session** `{w.SessionId}`  (restart resumes this)");

        if (detached)
        {
            lines.Add(string.Empty);
            lines.Add("> Nothing is attached to the session, so jumps and keystrokes will silently do nothing. Attach first.");
        }

        if (w.State == "stale")
        {
            lines.Add(string.Empty);
            lines.Add("> A session checked in here but its tab is gone - usually a terminal closed with the X button. `zt sync` clears it.");
        }

        return string.Join("\n\n", lines);
    }
}




