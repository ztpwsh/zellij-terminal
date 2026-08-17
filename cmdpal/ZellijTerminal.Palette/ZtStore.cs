using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ZellijTerminal.Palette;

/// <summary>
/// Reads the zt registry directly. NO PowerShell.
///
/// A palette must answer instantly and a pwsh start is ~500 ms measured, so
/// shelling out would make this feel broken. It does not have to: the registry
/// is plain JSON plus a directory of small files, which is readable from here
/// with no process at all. Actions go to zellij.exe at ~60 ms.
///
/// This is the second consumer of that format, so the shape is now load-bearing
/// in two languages. See docs/06-workspaces.md.
/// </summary>
internal sealed record ZtWorkspace(
    string Id,
    string Key,
    string State,
    bool Waiting,
    string WaitEvent,
    string Kind,
    string Tab,
    string Path,
    string SessionId);

internal static class ZtStore
{
    private const string SessionName = "claude";
    private const string TabPrefix = "claude-";

    private static string LiveDir =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ZellijTerminal", "live");

    private static string FlagDir =>
        Path.Combine(Path.GetTempPath(), "claude-zellij-flags");

    /// <summary>
    /// This device's registry. ZT_CONFIG_HOME wins; otherwise
    /// %LOCALAPPDATA%\ZellijTerminal, next to live\ and root.txt - NOT the
    /// clone. It is state the rig writes, gitignored in a public checkout, and
    /// state inside a working tree dies to `git clean -xfd`, to a re-clone, or
    /// to the release worktree being emptied by a publish.
    ///
    /// Must stay in step with Get-ZtConfigHome and Get-ZtDevicePath in
    /// Private\Core.ps1 - two implementations of one rule, which Palette.Tests
    /// exists to keep from drifting.
    /// </summary>
    private static string ConfigHome
    {
        get
        {
            var env = Environment.GetEnvironmentVariable("ZT_CONFIG_HOME");
            if (!string.IsNullOrWhiteSpace(env)) return env;
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ZellijTerminal");
        }
    }

    private static string DevicePath =>
        Path.Combine(ConfigHome, "devices", Environment.MachineName + ".json");

    /// <summary>
    /// The device registry path, for showing a person. Exposed because the
    /// answer stopped being fixed: it left the clone in 0.6.0 and ZT_CONFIG_HOME
    /// can move it again, so a page that says "this device's registry" without
    /// saying which file is asking to be misread.
    /// </summary>
    internal static string DevicePathForDisplay() => DevicePath;

    /// <summary>
    /// workspaces.json is committed content that ships with the clone, so it
    /// stays there by default. ZT_CONFIG_HOME moves both files together - a
    /// registry split across two locations is worse than either one alone.
    /// Null when there is no clone to read and no override to point elsewhere.
    /// </summary>
    private static string? SharedPath(string? root)
    {
        var env = Environment.GetEnvironmentVariable("ZT_CONFIG_HOME");
        if (!string.IsNullOrWhiteSpace(env)) return Path.Combine(env, "workspaces.json");
        return root is null ? null : Path.Combine(root, "config", "workspaces.json");
    }

    /// <summary>
    /// The repo, so config/ can be found. ZT_ROOT wins; otherwise walk up from
    /// this assembly looking for the marker the module uses.
    /// </summary>
    internal static string? FindRoot()
    {
        var env = Environment.GetEnvironmentVariable("ZT_ROOT");
        if (!string.IsNullOrWhiteSpace(env) && IsRoot(env)) return env;

        // The module leaves a note saying where the repo is, because walking up
        // from here cannot work: a packaged extension lives in
        // Program Files\WindowsApps and has no relationship to the clone.
        try
        {
            var marker = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ZellijTerminal", "root.txt");
            if (File.Exists(marker))
            {
                var noted = File.ReadAllText(marker).Trim();
                if (noted.Length > 0 && IsRoot(noted)) return noted;
            }
        }
        catch { }

        var dir = AppContext.BaseDirectory;
        while (!string.IsNullOrEmpty(dir))
        {
            if (IsRoot(dir)) return dir;
            var parent = Path.GetDirectoryName(dir.TrimEnd(Path.DirectorySeparatorChar));
            if (parent == dir) break;
            dir = parent ?? string.Empty;
        }
        return null;
    }

    private static bool IsRoot(string dir) =>
        File.Exists(Path.Combine(dir, "scripts", "zj-claude-project.ps1"));

    private static JsonNode? ReadJson(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            return JsonNode.Parse(File.ReadAllText(path));
        }
        catch { return null; }
    }

    private static string Str(JsonNode? n, string name, string fallback = "")
    {
        try { return n?[name]?.GetValue<string>() ?? fallback; }
        catch { return fallback; }
    }

    /// <summary>
    /// Is the session a live record describes still running?
    ///
    /// SessionEnd deletes these records, but Claude Code cancels hooks that have
    /// not finished by the time it exits - "Hook cancelled", for every hook
    /// registered - so records leak, and a leaked one is indistinguishable from
    /// a live one without this. The record carries the pid of the claude process
    /// that wrote it.
    ///
    /// No pid means ALIVE: records written by zt itself never have one, and
    /// there is no evidence of death to act on. A pid whose process started
    /// AFTER the record is a reused pid belonging to a stranger, not our
    /// session.
    ///
    /// Mirrors Test-ZtLiveRecordAlive in module\ZellijTerminal\Private\Core.ps1
    /// and is pinned to it by tests\Live.Tests.ps1. Used for STATE only: a dead
    /// record still gets listed, because it is what `zt restore` reopens after a
    /// crash. Removing one is `zt sync`'s job - this is a reader.
    /// </summary>
    private static bool IsLiveRecordAlive(JsonNode? n)
    {
        if (n is null) return false;

        // ToString rather than Str: a pid may be written as a JSON string or a
        // number, and reading only one of those shapes would silently treat
        // every record of the other shape as immortal.
        var raw = "";
        try { raw = n["pid"]?.ToString() ?? ""; } catch { raw = ""; }

        if (raw.Length == 0) return true;
        if (!int.TryParse(raw, out var pid) || pid <= 0) return true;

        Process proc;
        try { proc = Process.GetProcessById(pid); }
        catch { return false; }

        var started = Str(n, "startedAt");
        if (started.Length > 0 &&
            DateTime.TryParse(started, CultureInfo.InvariantCulture,
                              DateTimeStyles.RoundtripKind, out var recorded))
        {
            // A second of slack: the record is written moments after the process
            // starts, and clock granularity should not condemn it.
            try { if (proc.StartTime > recorded.AddSeconds(1)) return false; }
            catch { }
        }
        return true;
    }

    /// <summary>
    /// Everything this device knows about, reconciled against live Zellij.
    /// The registry is a cache; query-tab-names is the truth.
    /// </summary>
    // A short cache, because the dock band is PERSISTENT.
    //
    // Every uncached call spawns three zellij.exe processes - list-sessions,
    // query-tab-names, list-clients. That is fine for a page you opened; it is
    // not fine for a strip that redraws on a timer forever, which is process
    // churn with no upper bound and a plausible cause of the palette becoming
    // unstable.
    //
    // Two seconds is short enough that the count is honest and long enough that
    // a redraw storm collapses into one read.
    private static readonly object CacheLock = new();
    private static List<ZtWorkspace>? _cached;
    private static DateTime _cachedAt = DateTime.MinValue;
    private static readonly TimeSpan CacheFor = TimeSpan.FromSeconds(2);

    internal static List<ZtWorkspace> GetWorkspaces()
    {
        lock (CacheLock)
        {
            if (_cached is not null && DateTime.UtcNow - _cachedAt < CacheFor) return _cached;
        }

        var fresh = GetWorkspacesUncached();

        lock (CacheLock)
        {
            _cached = fresh;
            _cachedAt = DateTime.UtcNow;
        }
        return fresh;
    }

    private static List<ZtWorkspace> GetWorkspacesUncached()
    {
        var result = new List<ZtWorkspace>();
        var root = FindRoot();

        // Live records first - they are what says something is running, and
        // they exist even for workspaces the config has not caught up with.
        var live = new Dictionary<string, JsonNode>(StringComparer.OrdinalIgnoreCase);
        if (Directory.Exists(LiveDir))
        {
            foreach (var f in Directory.EnumerateFiles(LiveDir, "*.json"))
            {
                var n = ReadJson(f);
                var key = Str(n, "key");
                // Dead records are KEPT, same as Get-ZtLive keeps them: they are
                // what `zt restore` reopens after a crash. Aliveness decides the
                // state in Build, not whether the record exists.
                if (n is not null && key.Length > 0) live[key] = n;
            }
        }

        var tabs = ZellijCli.QueryTabNames();

        // The device file no longer depends on finding the clone, so a palette
        // that cannot locate a root still lists whatever this machine has
        // registered - which is most of what anyone asks it for.
        var defs = new List<JsonNode>();
        foreach (var p in new[] { SharedPath(root), DevicePath })
        {
            if (p is null) continue;
            if (ReadJson(p)?["workspaces"] is JsonArray arr)
            {
                foreach (var w in arr) if (w is not null) defs.Add(w);
            }
        }

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var w in defs)
        {
            var key = Str(w, "key");
            if (key.Length == 0 || !seen.Add(key)) continue;
            result.Add(Build(key, w, live.GetValueOrDefault(key), tabs, root));
        }

        // A session the config has not seen yet still deserves to be listed -
        // the module registers it on next run, but the palette should not lie
        // in the meantime.
        foreach (var (key, rec) in live)
        {
            if (!seen.Add(key)) continue;
            result.Add(Build(key, null, rec, tabs, root));
        }

        // Tabs that exist and are in no registry at all - made before the
        // registry existed, or by hand. Without these the palette shows one
        // workspace while the tab bar shows four, and nothing explains the gap.
        // No path, because Zellij will not report a tab's directory.
        var listed = result.Select(w => w.Tab).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var tab in tabs)
        {
            if (!tab.StartsWith(TabPrefix, StringComparison.OrdinalIgnoreCase)) continue;
            if (listed.Contains(tab)) continue;

            var (waiting, waitEvent) = ReadFlag(tab);
            result.Add(new ZtWorkspace(
                tab[TabPrefix.Length..], string.Empty, "unregistered",
                waiting, waitEvent, "unknown", tab, string.Empty, string.Empty));
        }

        return result
            .OrderByDescending(w => w.Waiting)
            .ThenBy(w => w.State == "running" ? 0 : 1)
            .ThenBy(w => w.Id, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static ZtWorkspace Build(
        string key, JsonNode? def, JsonNode? live, List<string> tabs, string? root)
    {
        var path = ResolvePath(def);
        if (path.Length == 0) path = Str(live, "cwd");

        var id = Str(def, "id");
        if (id.Length == 0) id = SafeLeaf(path);

        var tab = Str(def, "name");
        if (tab.Length == 0) tab = Str(live, "tab");
        if (tab.Length == 0 && path.Length > 0) tab = TabPrefix + SafeLeaf(path);

        var hasTab = tab.Length > 0 && tabs.Contains(tab, StringComparer.OrdinalIgnoreCase);
        var available = path.Length > 0 && Directory.Exists(path);

        // A record is not proof of a running session. SessionEnd deletes it, but
        // Claude Code cancels hooks that have not finished when it exits, so the
        // record outlives the session - and the tab outlives it too, because the
        // pane drops back to a shell. Both survivors present read as "running"
        // forever without this. Mirrors the ladder in Get-ZtWorkspaceRecords.
        var liveAlive = live is not null && IsLiveRecordAlive(live);

        var state =
            !available ? "unavailable"
            : hasTab && liveAlive ? "running"
            : hasTab && live is not null ? "stale"
            : hasTab ? "tab-only"
            : live is not null ? "stale"
            : "stopped";

        var (waiting, waitEvent) = ReadFlag(tab);

        var kind = Str(def, "kind", Str(live, "kind", "claude"));

        return new ZtWorkspace(id, key, state, waiting, waitEvent, kind, tab, path, Str(live, "sessionId"));
    }

    /// <summary>
    /// {root, rel} against this device's roots - the mechanism that lets one
    /// shared config work across machines with different drive letters. No
    /// root defined here means the workspace is simply not available here.
    /// </summary>
    private static string ResolvePath(JsonNode? def)
    {
        if (def is null) return string.Empty;

        var abs = Str(def, "abs");
        if (abs.Length > 0) return abs;

        var rootName = Str(def, "root");
        if (rootName.Length == 0) return string.Empty;

        // Root names are mapped by the DEVICE file, which is now findable
        // without the clone - so a named root resolves even when FindRoot()
        // came back empty.
        var device = ReadJson(DevicePath);
        var b = Str(device?["roots"], rootName);
        if (b.Length == 0) return string.Empty;

        var rel = Str(def, "rel");
        return rel.Length == 0 ? b : Path.Combine(b, rel);
    }

    /// <summary>
    /// The waiting queue is flag files the hook writes - and anything else can
    /// write them too, which is how a build raises its hand.
    /// </summary>
    private static (bool Waiting, string Event) ReadFlag(string tab)
    {
        if (tab.Length == 0) return (false, string.Empty);
        try
        {
            var flag = ReadJson(Path.Combine(FlagDir, tab + ".json"));
            if (flag?["waiting"]?.GetValue<bool>() == true)
            {
                return (true, Str(flag, "event", "?"));
            }
        }
        catch { }
        return (false, string.Empty);
    }

    private static string SafeLeaf(string path)
    {
        if (path.Length == 0) return "workspace";
        return Path.GetFileName(path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
    }
}

