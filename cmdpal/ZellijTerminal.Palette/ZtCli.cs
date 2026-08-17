using System.Diagnostics;

namespace ZellijTerminal.Palette;

/// <summary>
/// Running the zt module's commands.
///
/// This is the ACTION path, and it is allowed to use PowerShell where the READ
/// path is not. A pwsh start is ~500 ms measured, which would be intolerable
/// for drawing a list on every keystroke but is invisible for something you
/// deliberately invoked - and it means start/stop/restart keep exactly one
/// implementation rather than being reimplemented in C# and drifting.
///
/// Fire and forget: the palette dismisses immediately rather than sitting there
/// for half a second looking hung. The list picks the result up next time it is
/// drawn, because the registry is the shared truth.
/// </summary>
internal static class ZtCli
{
    private static string? _pwsh;

    /// <summary>
    /// Every invocation, with its exit code, appended to
    /// %LOCALAPPDATA%\ZellijTerminal\palette.log.
    ///
    /// This exists because the action path was invisible by construction and it
    /// cost a day. Close tab and Unregister were confirmed dead - the registry's
    /// mtime never moved, the tab stayed - while the palette showed a cheerful
    /// toast either way, because Run creates no window and ends in catch { }.
    /// The command strings were correct all along; the fault was environmental
    /// to the packaged MSIX, which is exactly the class of thing you cannot
    /// reason about from the C# and can only read off a log.
    ///
    /// Same lesson as the hook, which grew claude-zellij-hook.log for the same
    /// reason, and the Keyboard Manager engine log that settled "did the chord
    /// arrive, or arrive and fail?". A surface that cannot report its own
    /// failure will eventually be believed when it should not be.
    ///
    /// Best effort throughout: logging must never be the thing that breaks an
    /// action, so every failure here is swallowed.
    /// </summary>
    // internal, not private: ZellijCli logs through here too. Every action the
    // palette takes belongs in one file, or the README's promise that the log
    // records them all is only true of half of them.
    internal static void Log(string message)
    {
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ZellijTerminal");
            Directory.CreateDirectory(dir);
            File.AppendAllText(
                Path.Combine(dir, "palette.log"),
                $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}  {message}{Environment.NewLine}");
        }
        catch { }
    }

    private static string Pwsh
    {
        get
        {
            if (_pwsh is not null) return _pwsh;

            foreach (var c in new[]
                     {
                         @"C:\Program Files\PowerShell\7\pwsh.exe",
                         Path.Combine(
                             Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                             "Microsoft", "WindowsApps", "pwsh.exe"),
                     })
            {
                if (File.Exists(c)) { _pwsh = c; return _pwsh; }
            }

            _pwsh = "pwsh.exe";
            return _pwsh;
        }
    }

    /// <summary>
    /// Run a zt command. -NoProfile because a profile would add to the start
    /// cost for nothing; the module is autoloaded by name.
    /// </summary>
    internal static void Run(string command) => Start(command, visible: false);

    /// <summary>
    /// Run a zt command in a CONSOLE WINDOW you can read.
    ///
    /// Not a variant for the sake of it. `check the rig` and `validate` exist to
    /// show you output, and both were being launched through Run, which sets
    /// CreateNoWindow - so the four-layer check rendered to a console nobody
    /// could see and then blocked on its own `Read-Host 'enter to close'`,
    /// leaving an invisible pwsh alive until it was killed by hand. A command
    /// whose entire purpose is its output has to have somewhere to put it.
    /// </summary>
    internal static void RunVisible(string command) => Start(command, visible: true);

    private static void Start(string command, bool visible)
    {
        try
        {
            var psi = new ProcessStartInfo(Pwsh)
            {
                UseShellExecute = false,
                CreateNoWindow = !visible,
            };
            psi.ArgumentList.Add("-NoProfile");

            // -NonInteractive ONLY when there is nobody to be interactive with.
            //
            // It was passed on every invocation, which quietly disabled every
            // visible command. Under -NonInteractive, Read-Host does not
            // prompt: it fails with "PowerShell is in NonInteractive mode" and
            // execution CONTINUES, so
            //   * the trailing `Read-Host 'enter to close'` on the five "in a
            //     window" commands returned instantly, pwsh exited, and the
            //     console was destroyed before anything could be read - the
            //     exact failure RunVisible was written to fix, reintroduced one
            //     argument later;
            //   * "Define a root", whose whole implementation is two Read-Host
            //     prompts, could never collect a name or a path, and still
            //     exited 0, so the log said success.
            // Demonstrated: pwsh -NonInteractive -Command "Read-Host 'x'"
            // prints the NonInteractive error, runs on, and exits 0.
            //
            // The point of the visible path is a person answering, so the flag
            // is exactly wrong there. Hidden commands keep it: nothing can
            // answer them, and a prompt would hang an invisible process.
            if (!visible) psi.ArgumentList.Add("-NonInteractive");

            psi.ArgumentList.Add("-Command");
            psi.ArgumentList.Add("Import-Module ZellijTerminal -ErrorAction Stop; " + command);

            // Refresh the list when the command finishes, not when it starts.
            //
            // This stays fire-and-forget deliberately: "Register a folder" puts
            // up a folder dialog, so waiting here would freeze the palette for
            // as long as the user browses. But without the Exited hook nothing
            // ever re-read the registry, so a successful add left the list
            // unchanged and read as a failure. ZtStore caches for two seconds,
            // which is well short of how long a pwsh start plus a dialog takes,
            // so the refresh always sees the new file rather than the cache.
            //
            // Every mutating verb goes through here, so start / stop / rm /
            // park / restore all get the same treatment, not just add.
            var proc = new Process { StartInfo = psi, EnableRaisingEvents = true };
            proc.Exited += (_, _) =>
            {
                // The exit code is the whole point of the log. A non-zero here
                // is the difference between "the command never ran" and "it ran
                // and refused", which is not a distinction the palette can draw
                // on screen after it has dismissed itself.
                try { Log($"exit {proc.ExitCode}  {command}"); } catch { Log($"exit ?  {command}"); }
                WorkspacesPage.RequestRefresh();
                try { proc.Dispose(); } catch { }
            };
            proc.Start();
            Log($"start   {command}");
        }
        catch (Exception ex)
        {
            // Was: catch { }. A palette that is already closing still cannot
            // show this, but the log can - and "could not start pwsh at all" is
            // the single most likely cause of an action doing nothing, so it is
            // the one failure that must not be dropped on the floor.
            Log($"FAILED to start ({ex.GetType().Name}: {ex.Message})  {command}");
        }
    }

    internal static void Open(string path)
    {
        try
        {
            if (path.Length == 0) return;
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
            Log($"start   open {path}");
        }
        catch (Exception ex)
        {
            // Was: catch { }. "Open folder" doing nothing and writing nothing is
            // indistinguishable from the palette being broken - which is what
            // the README tells the reader an empty log means.
            Log($"FAILED  open {path} ({ex.GetType().Name}: {ex.Message})");
        }
    }

    internal static void OpenIn(string exe, string path)
    {
        try
        {
            if (path.Length == 0) return;
            Process.Start(new ProcessStartInfo(exe, path) { UseShellExecute = true });
            Log($"start   {exe} {path}");
        }
        catch (Exception ex)
        {
            // The commonest cause here is `code` not being on PATH, which is a
            // sentence the log can say and a dismissed palette cannot.
            Log($"FAILED  {exe} {path} ({ex.GetType().Name}: {ex.Message})");
        }
    }
}

