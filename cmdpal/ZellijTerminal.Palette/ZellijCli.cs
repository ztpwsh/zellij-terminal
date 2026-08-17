using System.Diagnostics;
using System.Text.RegularExpressions;

namespace ZellijTerminal.Palette;

/// <summary>
/// Talking to Zellij. Direct process launch, ~60 ms measured.
///
/// Two things this rig has learned the hard way and that apply here too:
///
///   * With no client attached, every action is a silent no-op that STILL
///     EXITS 0. Exit codes prove nothing; the caller has to check separately.
///   * zellij is on the USER path, not the machine path, and a process launched
///     from an unusual parent may not have it. Resolve a full path once rather
///     than trusting PATH - the same bug that made pad keys 3 and 4 dead.
/// </summary>
internal static class ZellijCli
{
    private const string SessionName = "claude";

    private static string? _exe;

    internal static string Exe
    {
        get
        {
            if (_exe is not null) return _exe;

            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

            // The places zellij actually lands on Windows. This was one entry -
            // the installer's own - so a winget or cargo install fell straight
            // through to bare "zellij.exe" and depended on the palette process
            // having inherited a PATH that includes it, which is precisely the
            // assumption the module refuses to make.
            var candidates = new[]
            {
                Path.Combine(local, "Zellij", "zellij.exe"),
                Path.Combine(local, "Microsoft", "WinGet", "Links", "zellij.exe"),
                Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    ".cargo", "bin", "zellij.exe"),
                Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                    "zellij", "zellij.exe"),
            };
            foreach (var c in candidates)
            {
                if (File.Exists(c)) { _exe = c; return _exe; }
            }

            // Last resort: let the OS resolve it, and accept that it may not.
            // Logged, because "zellij was never found" and "the session is not
            // running" produce the same empty answer everywhere downstream, and
            // only this line can tell them apart afterwards.
            _exe = "zellij.exe";
            ZtCli.Log("zellij.exe not found in any known location - falling back to PATH");
            return _exe;
        }
    }

    // Same reasoning as the workspace cache: SessionExists and
    // IsClientAttached are called from the dock band, which is permanent.
    private static readonly Dictionary<string, (DateTime At, string Out)> Recent = new();
    private static readonly TimeSpan RecentFor = TimeSpan.FromSeconds(2);

    /// <summary>
    /// ONLY read-only queries may be cached. Caching an action would mean a
    /// second identical press inside the window silently did nothing - pressing
    /// Enter twice would send it once. Hence the explicit opt-in rather than a
    /// default that is right most of the time.
    /// </summary>
    private static string Run(string args, int timeoutMs = 4000, bool cacheable = false)
    {
        if (!cacheable) return RunUncached(args, timeoutMs);

        lock (Recent)
        {
            if (Recent.TryGetValue(args, out var hit) && DateTime.UtcNow - hit.At < RecentFor)
            {
                return hit.Out;
            }
        }

        var result = RunUncached(args, timeoutMs);

        lock (Recent)
        {
            Recent[args] = (DateTime.UtcNow, result);
        }
        return result;
    }

    private static string RunUncached(string args, int timeoutMs) => Exec(args, timeoutMs).Out;

    /// <summary>
    /// Run zellij and report BOTH whether it worked and what it said. Actions
    /// need the first, queries the second; conflating them is how kill-session
    /// came to report success on a session that was never there.
    /// </summary>
    private static bool RunOk(string args, int timeoutMs = 4000)
    {
        var r = Exec(args, timeoutMs);
        ZtCli.Log($"{(r.Ok ? "exit 0 " : "FAILED ")} zellij {args}");
        return r.Ok;
    }

    private static (bool Ok, string Out) Exec(string args, int timeoutMs)
    {
        try
        {
            var psi = new ProcessStartInfo(Exe, args)
            {
                RedirectStandardOutput = true,

                // NOT redirected. Redirecting a stream nobody reads is how a
                // child deadlocks: zellij fills the stderr pipe buffer, blocks
                // writing, never exits, and the ReadToEnd below never returns -
                // so the timeout on the next line cannot fire, because control
                // has not reached it. Either read both streams or redirect
                // neither; nothing here wants stderr, so it goes to the void
                // with the parent's own handle.
                RedirectStandardError = false,

                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using var p = Process.Start(psi);
            if (p is null) return (false, string.Empty);

            // Wait FIRST, then read. ReadToEnd on a process that never exits
            // blocks forever regardless of any timeout after it, and a hung
            // zellij would have taken the dock band with it.
            if (!p.WaitForExit(timeoutMs))
            {
                ZtCli.Log($"TIMEOUT after {timeoutMs}ms  zellij {args}");
                try { p.Kill(entireProcessTree: true); } catch (Exception ex) { ZtCli.Log($"kill failed: {ex.Message}"); }
                return (false, string.Empty);
            }

            var stdout = p.StandardOutput.ReadToEnd();
            return (p.ExitCode == 0, p.ExitCode == 0 ? stdout : string.Empty);
        }
        catch (Exception ex)
        {
            // Was: catch { return string.Empty; }. Every zellij-direct action -
            // go-to-tab, the accept/reject keystrokes, kill and delete session -
            // came through here and could fail in total silence, while the
            // README told the reader that an empty palette.log means the palette
            // itself is broken.
            ZtCli.Log($"FAILED  zellij {args} ({ex.GetType().Name}: {ex.Message})");
            return (false, string.Empty);
        }
    }

    /// <summary>
    /// The hook decorates a tab with what its session is doing right now -
    /// <c>claude-web-api ~</c> - so the live name carries a glyph that is not
    /// part of the tab's identity. Strip it here: the page compares these
    /// against registry entries, and a mismatch shows a running workspace as
    /// missing.
    ///
    /// Fourth copy of a rule written three times in PowerShell (the hook,
    /// zj-claude-tab.ps1, zj-claude-project.ps1 and the module). Tests pin them
    /// together; the palette cannot report that it read a different rule.
    /// </summary>
    private static readonly Regex TabGlyph = new(@" [v!?*>~#@&+.]$", RegexOptions.Compiled);

    internal static string TabBase(string name) =>
        string.IsNullOrEmpty(name) ? name : TabGlyph.Replace(name, string.Empty);

    internal static List<string> QueryTabNames() =>
        Run($"--session {SessionName} action query-tab-names", cacheable: true)
            .Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(s => TabBase(s.Trim()))
            .Where(s => s.Length > 0)
            .ToList();

    /// <summary>
    /// The string Zellij is holding for a tab right now, glyph included.
    /// go-to-tab-name matches exactly and no-ops silently on a miss.
    /// </summary>
    internal static string LiveTabName(string baseName) =>
        Run($"--session {SessionName} action query-tab-names", cacheable: true)
            .Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(s => s.Trim())
            .FirstOrDefault(s => s.Length > 0 && TabBase(s) == baseName)
        ?? baseName;

    /// <summary>
    /// Empty table under the header means nothing is attached, which makes
    /// every go-to / write below a no-op. Worth showing the user rather than
    /// letting a command appear to succeed.
    /// </summary>
    internal static bool IsClientAttached() =>
        Run($"--session {SessionName} action list-clients", cacheable: true)
            .Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(s => s.Trim())
            .Any(s => s.Length > 0 && !s.StartsWith("CLIENT_ID", StringComparison.OrdinalIgnoreCase));

    internal static bool SessionExists() =>
        Run("list-sessions", cacheable: true).Contains(SessionName, StringComparison.OrdinalIgnoreCase);

    internal static void GoToTab(string tab) =>
        Run($"--session {SessionName} action go-to-tab-name \"{LiveTabName(tab)}\"");

    /// <summary>
    /// Inject a byte into the session's FOCUSED pane. 13 is Enter, 27 is Esc -
    /// the macro pad's keys 1 and 2, which is the entire trick this rig is
    /// built on: it reaches the pane without the terminal being focused, or
    /// even visible.
    /// </summary>
    internal static void Write(int b) =>
        Run($"--session {SessionName} action write {b}");

    internal sealed record ZellijSession(string Name, bool Exited, string Created);

    /// <summary>
    /// Sessions, as opposed to tabs. list-sessions colours its output, and the
    /// escape codes end up inside the parsed names if they are not stripped.
    /// </summary>
    internal static List<ZellijSession> ListSessions()
    {
        var raw = Run("list-sessions", cacheable: true);
        var clean = System.Text.RegularExpressions.Regex.Replace(raw, "\\[[0-9;]*m", string.Empty);

        var result = new List<ZellijSession>();
        foreach (var line in clean.Split('\n'))
        {
            var t = line.Trim();
            if (t.Length == 0) continue;

            var m = System.Text.RegularExpressions.Regex.Match(
                t, @"^(?<name>\S+)\s+\[Created\s+(?<created>[^\]]+)\]\s*(?<rest>.*)$");
            if (!m.Success) continue;

            result.Add(new ZellijSession(
                m.Groups["name"].Value,
                m.Groups["rest"].Value.Contains("EXITED", StringComparison.OrdinalIgnoreCase),
                m.Groups["created"].Value.Trim()));
        }
        return result;
    }

    // Return whether it worked. These used to be void, and the caller toasted
    // "Killed x" whether zellij had killed anything, refused, or never run.
    internal static bool KillSession(string name) => RunOk($"kill-session {name}");

    internal static bool DeleteSession(string name) => RunOk($"delete-session {name} --force");
}



