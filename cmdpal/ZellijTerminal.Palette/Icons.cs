using Microsoft.CommandPalette.Extensions.Toolkit;

namespace ZellijTerminal.Palette;

/// <summary>
/// Segoe Fluent Icons glyphs, named once.
///
/// Every icon in the first cut was <c>new IconInfo("")</c> - an empty string,
/// so nothing rendered anywhere, including the dock band where the icon is the
/// entire point.
///
/// Written as escapes rather than pasted glyphs: the literal characters do not
/// survive every editor and encoding between here and the build, and a silently
/// emptied string is exactly the bug being fixed. A wrong codepoint shows as a
/// box, which is at least visible.
/// </summary>
internal static class ZtIcons
{
    internal static IconInfo Terminal => new("\uE756");
    internal static IconInfo List => new("\uE8FD");
    internal static IconInfo GoTo => new("\uE76C");
    internal static IconInfo Waiting => new("\uE7C1");
    internal static IconInfo Attach => new("\uE71B");
    internal static IconInfo Start => new("\uE768");
    internal static IconInfo Stop => new("\uE71A");
    internal static IconInfo Restart => new("\uE72C");
    internal static IconInfo Park => new("\uE74E");
    internal static IconInfo Restore => new("\uE895");
    internal static IconInfo Folder => new("\uE838");
    internal static IconInfo Code => new("\uE943");
    internal static IconInfo Copy => new("\uE8C8");
    internal static IconInfo Close => new("\uE711");
    internal static IconInfo Delete => new("\uE74D");
    internal static IconInfo Add => new("\uE710");
    internal static IconInfo Check => new("\uE73E");
    internal static IconInfo Edit => new("\uE70F");
    internal static IconInfo Sync => new("\uE117");
    internal static IconInfo Import => new("\uE896");
    internal static IconInfo Export => new("\uE898");
    internal static IconInfo Publish => new("\uE72D");
}

