using System.Runtime.InteropServices;
using Microsoft.CommandPalette.Extensions;

namespace ZellijTerminal.Palette;

/// <summary>
/// The COM server. Command Palette launches this out-of-process with
/// -RegisterProcessAsComServer and talks to it over COM; it is not a UI app and
/// has no window of its own.
/// </summary>
public static class Program
{
    [MTAThread]
    public static void Main(string[] args)
    {
        if (args.Length == 0 || !args.Contains("-RegisterProcessAsComServer"))
        {
            // Launched by hand. Say so rather than exiting silently, because a
            // silent exit is indistinguishable from a crash.
            Console.WriteLine("This is a Command Palette extension, not a standalone app.");
            Console.WriteLine("It is started by Command Palette with -RegisterProcessAsComServer.");
            return;
        }

        using var server = new ExtensionServer();
        var disposed = new ManualResetEvent(false);
        var extension = new ZtExtension(disposed);

        server.RegisterExtension(() => extension);

        // Block until the host lets go, or the process would exit immediately
        // and the palette would show an extension that vanishes.
        disposed.WaitOne();
    }
}

[Guid("6f0d5b1a-0f6a-4a4c-9d3e-2b7c8a1e5f40")]
public sealed partial class ZtExtension : IExtension, IDisposable
{
    private readonly ManualResetEvent _disposed;
    private readonly ZtCommandsProvider _provider = new();

    public ZtExtension(ManualResetEvent disposed) => _disposed = disposed;

    public object? GetProvider(ProviderType providerType) =>
        providerType == ProviderType.Commands ? _provider : null;

    public void Dispose() => _disposed.Set();
}

