# Command Palette extension

`zt` in PowerToys Command Palette. One keystroke from anywhere, whatever is
focused.

```powershell
.\pack.ps1        # build, package, sign, install - one command
```

Then reopen Command Palette. The first run creates a self-signed certificate and
prints the one elevated command needed to trust it.

## What it gives you

**At the palette root**

| Item | Does |
|---|---|
| Zellij workspaces | the list — subtitled `3 registered, 2 running, 1 WAITING` |
| go to whoever is waiting | oldest waiter first, cycles if nobody is |
| next tab / previous tab | cycle the `claude-*` tabs — the pad's key 4, both ways |
| attach | open a window on the session, or focus the existing one |
| register a folder | folder picker, then `Register-ZellijTerminal` |
| park everything / restore | stop it all, then bring it back resuming each session |
| sync | forget sessions whose tab is gone — clears `stale` |
| registry and config | a page; see below |
| check the rig | the four-layer check, in a window |

**Registry and config**, one level down. A page rather than eight more entries
in the palette root: the root is shared with every extension installed, and
these are the rarest verbs in the set.

| Item | Does |
|---|---|
| edit this device's registry | `zt config` — subtitled with the actual path, which moved in 0.6.0 |
| edit the shared list | `zt config -Shared` |
| check both config files | `zt validate`, in a window |
| roots on this device | where this machine says each named root lives |
| define a root | asks for a name, then a folder picker — fixes an `unavailable` workspace |
| export a bundle | save dialog, then `Export-ZellijTerminal` |
| import a bundle | open dialog, then `Import-ZellijTerminal` — **without** `-Force`, so nothing already here is overwritten |

Typing a workspace name at the root offers to go straight there, without opening
the list first.

**Per workspace**

| Key | Does | Typed |
|---|---|---|
| `Enter` | go to its tab | `zt go <id>` |
| `Ctrl+S` / `Ctrl+T` | start / stop | `zt start` / `zt stop` |
| `Ctrl+R` | restart, resuming the same Claude session | `zt restart` |
| `Ctrl+F` | raise or lower its hand — the thing pad key 3 jumps to | `zt flag` / `zt unflag` |
| `Ctrl+E` | open the folder | — |
| `Ctrl+Shift+C` | copy the path | — |
| `Ctrl+P` | publish to the shared list — the deliberate "every machine should have this" | `zt publish` |
| `Ctrl+W` | close the tab (confirms) | `zt close <id>` |
| `Ctrl+D` | unregister (confirms) | `zt unregister <id>` |

The last column is not a translation table you have to learn: the palette runs
those exact commands, and the CLI answers to the palette's words. `unregister`
was added for this reason — the button said "Unregister" and the only spellings
that worked were `rm` and `remove`, so the word you had just clicked was the one
word that failed when typed.

Both leave the directory alone. `Ctrl+W` closes the tab and keeps the
registration; `Ctrl+D` removes the registration and keeps the folder. Do them in
that order on a workspace you are finished with — unregistering first leaves the
tab on screen with nothing in the registry that knows about it.

No `Ctrl+Alt` anywhere: on a UK layout that is AltGr — see D21 in
`docs/02-decisions.md`.

**In the dock**

`GetDockBands` puts the workspace count in Command Palette's persistent strip,
so `2 running, 1 WAITING` is visible without summoning anything. That is the
surface the tray icon was going to provide, without a resident process of our
own.

## The one architectural rule

**Reads never touch PowerShell.** A pwsh start is ~500 ms measured, and the
list is redrawn on every keystroke, so `ZtStore` reads `config\` and the live
directory as plain JSON, and `ZellijCli` runs `zellij.exe` at ~60 ms.

**Actions do go through the module**, fire and forget. `Start-ZellijTerminal`
and friends carry rules that took a day to get right — attachment checks, focus
confirmation before injecting, resume-by-session-id — and reimplementing them in
C# would mean two versions that drift. Half a second on a command you
deliberately invoked is invisible.

## When an action appears to do nothing

Read `%LOCALAPPDATA%\ZellijTerminal\palette.log`. Every action writes a line
when it starts and another with its exit code when it finishes:

```
2026-08-16 14:02:11  start   Unregister-ZellijTerminal -Name 'api' -Confirm:$false
2026-08-16 14:02:12  exit 0  Unregister-ZellijTerminal -Name 'api' -Confirm:$false
```

The log exists because it once cost a day. Close tab and Unregister were both
completely dead — the registry's timestamp never moved, the tab stayed — while
the palette showed the same cheerful toast it shows on success, because the
action path created no window and ended in an empty `catch`. The command strings
were correct the whole time; the fault was environmental to the packaged MSIX,
which is not a thing anyone can deduce from reading the C#.

Three lines to look for:

- **no line at all** — the command never reached `ZtCli`; the palette itself is
  the problem, or you are reading a stale package.
- **`FAILED to start`** — pwsh could not be launched from inside the MSIX
  sandbox. The likeliest single cause.
- **`exit` non-zero** — it ran and refused, so the argument or the module is
  wrong. That is a different bug entirely, and worth knowing apart.

## Finding the repo

The extension installs into `Program Files\WindowsApps`, so it cannot find the
clone by looking around itself. The module writes
`%LOCALAPPDATA%\ZellijTerminal\root.txt` whenever it resolves the root, and the
extension reads that. `ZT_ROOT` overrides both.

## Rebuilding

`pack.ps1` handles the three things that otherwise make the loop painful:

- **a new version every pack**, derived from the clock, or `Add-AppxPackage`
  refuses with `0x80073CFB` — same identity, different contents
- **stopping the running instance**, because Command Palette keeps the COM
  server alive and Windows will not replace files in use (`0x80073D02`)
- **the certificate**, created once and reported rather than failing later

## If it does not appear

The failure mode is silence — no error, nothing logged. In order of likelihood:

1. Command Palette needs restarting after an install.
2. The class GUID in `Package.appxmanifest` must match the `[Guid]` on
   `ZtExtension` in `Program.cs`, in **both** the `com:Extension` and
   `uap3:AppExtension` blocks.
3. `Get-AppxPackage ZellijTerminal.Palette` — is it actually installed?
4. `Get-Process ZellijTerminal.Palette` — if the palette has launched it, the
   registration is working and the problem is in the code, not the manifest.

## What the build needs

All four, before `pack.ps1` will get through:

| | Why it fails without it |
|---|---|
| **.NET 10 SDK** — `winget install Microsoft.DotNet.SDK.10` | The 0.11 toolkit references `System.Runtime 10.0.0.0`, so SDK 9 fails with `CS1705` |
| **Windows SDK 10.0.26100** — `winget install Microsoft.WindowsSDK.10.0.26100` | `cswinrt` reads `Windows Kits\10\Platforms\UAP\<version>\Platform.xml` and fails with *"Could not read the Windows SDK's Platform.xml"* if that exact version is absent. It is named in `TargetFramework`, so a newer SDK alone is not enough |
| **A NuGet source** — `dotnet nuget add source https://api.nuget.org/v3/index.json -n nuget.org` | Some machines genuinely have none configured, and the restore fails on the first package |
| **Developer mode**, Settings → System → For developers | `Add-AppxPackage` refuses a self-signed package without it |

`pack.ps1` prints the tail of whatever failed, so start with what it shows you
rather than the exit code.

## Version pinning

`Microsoft.CommandPalette.Extensions 0.11.260520004`, matching the installed
`Microsoft.CommandPalette 0.11`. The API moves between releases and a skew shows
up as the extension simply not appearing.

