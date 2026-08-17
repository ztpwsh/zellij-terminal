using Microsoft.CommandPalette.Extensions;
using Microsoft.CommandPalette.Extensions.Toolkit;
using Microsoft.CmdPal.Common.Commands;

namespace ZellijTerminal.Palette;

/// <summary>
/// Zellij itself, surfaced.
///
/// Zellij's own interface is a Linux-shaped CLI: you are expected to know that
/// sessions and tabs are different levels, that `kill-session` leaves a session
/// resurrectable while `delete-session` does not, and that a mistyped command
/// silently creates a whole new server named after a random animal. None of
/// that is discoverable, and this machine had two stray sessions nobody knew
/// about for a day because of it.
///
/// A palette page makes the level visible and the verbs obvious, which is the
/// one thing a list of commands is genuinely better at than a CLI.
/// </summary>
internal sealed partial class SessionsPage : DynamicListPage
{
    public SessionsPage()
    {
        Icon = ZtIcons.Terminal;
        Title = "Zellij sessions";
        Name = "Sessions";
        Id = "zt.sessions";
        PlaceholderText = "Search sessions";
        ShowDetails = true;
    }

    public override void UpdateSearchText(string oldSearch, string newSearch) => RaiseItemsChanged(0);

    public override IListItem[] GetItems()
    {
        var sessions = ZellijCli.ListSessions();

        var search = SearchText ?? string.Empty;
        if (search.Length > 0)
        {
            sessions = sessions
                .Where(s => s.Name.Contains(search, StringComparison.OrdinalIgnoreCase))
                .ToList();
        }

        if (sessions.Count == 0)
        {
            return
            [
                new ListItem(new NoOpCommand())
                {
                    Title = "No Zellij sessions",
                    Subtitle = "Attach to create one",
                }
            ];
        }

        return [.. sessions.Select(Build)];
    }

    private static ListItem Build(ZellijCli.ZellijSession s)
    {
        var managed = s.Name.Equals("claude", StringComparison.OrdinalIgnoreCase);

        var tags = new List<ITag> { new Tag(s.Exited ? "EXITED" : "running") };
        if (managed) tags.Add(new Tag("managed"));

        var more = new List<CommandContextItem>
        {
            new(new ConfirmableCommand(
                new ZellijSessionCommand("Kill", ZtIcons.Stop, s.Name, delete: false),
                $"Kill session '{s.Name}'?",
                "It stops, but stays resurrectable - attaching brings it back."))
            { IsCritical = true },

            new(new ConfirmableCommand(
                new ZellijSessionCommand("Delete permanently", ZtIcons.Delete, s.Name, delete: true),
                $"Delete session '{s.Name}'?",
                "Killed and forgotten. It will not resurrect."))
            { IsCritical = true },
        };

        var body = s.Exited
            ? "Exited, but still on disk. Attaching resurrects it with its tabs, names and directories - that is `session_serialization` in the config.\n\nDelete it to stop it coming back."
            : "Running. Its tabs are a level below this - the workspace list is the tabs inside `claude`.";

        if (managed)
        {
            body += "\n\n**This is the session the rig manages.** Killing it takes every tab, and every Claude session in them, down at once.";
        }

        return new ListItem(new AttachSessionCommand(s.Name))
        {
            Title = s.Name,
            Subtitle = $"created {s.Created}",
            Tags = [.. tags],
            MoreCommands = [.. more],
            Details = new Details { Title = s.Name, Body = body },
        };
    }
}

internal sealed partial class AttachSessionCommand : InvokableCommand
{
    private readonly string _name;

    public AttachSessionCommand(string name)
    {
        _name = name;
        Name = "Attach";
        Id = "zt.session.attach." + name;
        Icon = ZtIcons.Attach;
    }

    public override ICommandResult Invoke()
    {
        // Through the module, so the "one window, named, focused if it already
        // exists" behaviour is the same as `zac` rather than a second way of
        // attaching that fights it.
        ZtCli.Run($"Connect-ZellijTerminal -Session '{_name.Replace("'", "''")}'");
        return CommandResult.Dismiss();
    }
}

internal sealed partial class ZellijSessionCommand : InvokableCommand
{
    private readonly string _name;
    private readonly bool _delete;

    public ZellijSessionCommand(string name, IconInfo icon, string session, bool delete)
    {
        Name = name;
        Id = "zt.session." + (delete ? "delete." : "kill.") + session;
        Icon = icon;
        _name = session;
        _delete = delete;
    }

    public override ICommandResult Invoke()
    {
        ZellijCli.KillSession(_name);
        if (_delete) ZellijCli.DeleteSession(_name);
        return CommandResult.ShowToast(_delete ? $"Deleted {_name}" : $"Killed {_name}");
    }
}

/// <summary>
/// The macro pad's keys 1 and 2, as palette commands.
///
/// These exist so they can be bound to a global hotkey in Command Palette's own
/// settings, which is the test of whether the palette can replace Keyboard
/// Manager entirely. They inject into the session's FOCUSED pane, exactly as
/// the pad does - so the answer lands wherever you were already working,
/// without the terminal needing focus.
/// </summary>
internal sealed partial class AnswerPaneCommand : InvokableCommand
{
    private readonly int _byte;
    private readonly string _what;

    public AnswerPaneCommand(string name, string id, IconInfo icon, int b, string what)
    {
        Name = name;
        Id = id;
        Icon = icon;
        _byte = b;
        _what = what;
    }

    public override ICommandResult Invoke()
    {
        if (!ZellijCli.IsClientAttached())
        {
            // Without this the palette would close as though it had worked -
            // write is a silent no-op that still exits 0 when nothing is
            // attached.
            return CommandResult.ShowToast("Nothing is attached to the session - nothing was sent");
        }

        ZellijCli.Write(_byte);
        return CommandResult.ShowToast(_what);
    }
}

