# Reference

## `zt`

| Command | Does |
|---|---|
| `zt setup` | guided setup — every layer, explained, with an offer to do it |
| `zt export [path]` | registrations, roots and this rig's Command Palette entries to one file |
| `zt import <file>` | merge one back in; `-Force` overwrites what is already here |
| `zt uninstall` | remove what the installer added; `-WhatIf` first, `-Purge` for registrations too, `-Force` when nothing can prompt |
| `zt` | list this device's workspaces and their state |
| `zt ls` / `zt all` / `zt waiting` | filtered lists; `all` includes ones this device can't reach |
| `zt add [path]` — also `register` | register a folder for Claude (defaults to here) |
| `zt add . -Kind pwsh -Command '…'` | register a command instead; omit `-Command` for a bare shell |
| `zt add -FromBookmarks` | import Windows Terminal profiles that launch Claude; `-Filter` by name, `-IncludeAll` for the rest |
| `zt rm <id>` — also `remove`, `unregister`, `forget` | unregister; also stops it unless `-KeepRunning`. The **directory is untouched** |
| `zt publish <id>` | promote a device entry to the shared config |
| `zt start <id>` | open its tab and run it; `-Resume` for the previous Claude session |
| `zt stop <id>` | Ctrl+C what's running, leave the tab as a shell |
| `zt restart <id>` | stop, then resume; `-Fresh` for a new session |
| `zt close <id>` | close the tab, keep the registration |
| `zt sync` | drop live records whose tabs are gone |
| `zt park` | stop everything running, remembering what it was |
| `zt restore` | reopen it, resuming each Claude session; `-Fresh` for new ones |
| `zt config` | open the JSON in your editor; `-Shared` for the shared one |
| `zt validate` | check both config files and say what is wrong |
| `zt go` / `next` / `prev` | jump to whoever's waiting, or cycle |
| `zt attach` (`zac`) | attach, or focus the window already attached |
| `zt roots` / `zt root <name> <path>` | what root names mean on this device |
| `zt check` | the layer check |
| `zt sessions` | Zellij **sessions** — the level above tabs |
| `zt sessions kill <name>` | stop a stray session; `-Delete` to forget it too |
| `zt dock` | pin the workspace band to the Command Palette dock |
| `zt pad` | what the macro pad is wired to, including remaps pointing at a different clone |
| `zt pad explain` | what the four keys are for, and whether you want one |
| `zt pad install` | write the PowerToys remaps; `-Listener ahk` for AutoHotkey |
| `zt pad uninstall` | remove only the remaps this rig created |
| `zt palette` | what the Command Palette extension adds, and whether it is installed |

Every verb is a `Verb-ZellijTerminal` function underneath — `Get-Help
Start-ZellijTerminal -Full` for the parameters. States are `running`,
`tab-only`, `stopped`, `stale`, `unavailable`; see `docs/06-workspaces.md`.

## Command Palette extension

| Where | Item |
|---|---|
| root | Zellij workspaces (subtitled `n registered, n running, n WAITING`) |
| root | go to whoever is waiting, attach, register a folder, park, restore, check |
| root | type a workspace name -> go straight there (fallback command) |
| dock | the workspace count, visible without summoning the palette |

Per workspace: `Enter` go to, `Ctrl+S` start, `Ctrl+T` stop, `Ctrl+R` restart,
`Ctrl+F` raise/lower its hand, `Ctrl+E` open folder, `Ctrl+Shift+C` copy path,
`Ctrl+W` close tab, `Ctrl+D` unregister. No `Ctrl+Alt` - that is AltGr here.

Every one of those is the command of the same name: `Ctrl+W` is `zt close`,
`Ctrl+D` is `zt unregister`. The two surfaces answer to the same words on
purpose - the CLI learned `register`, `unregister` and `forget` precisely
because the palette teaches those and `zt add` / `zt rm` did not accept them.

Build and install with `cmdpal\pack.ps1`. See `cmdpal/README.md`.

## Zellij CLI

Always target the session explicitly: `zellij --session <name> action <...>`.

| Command | Does |
|---|---|
| `action write <byte>` | inject a raw byte. `13` = Enter, `27` = Esc, `9` = Tab |
| `action write-chars "text"` | inject a string |
| `action send-keys "Ctrl a" "Enter"` | inject named keys (0.44+) |
| `action query-tab-names` | list tab names, in order |
| `action current-tab-info` | which tab is focused — **only from an attached client**; from outside it prints an error and exits 2 |
| `action list-tabs --state --layout` | fuller tab dump |
| `action go-to-tab-name "name" [--create]` | focus a tab by name |
| `action go-to-tab <n>` | focus by index |
| `action go-to-next-tab` / `go-to-previous-tab` | cycle **all** tabs |
| `action rename-tab "name"` | renames the **focused** tab |
| `action rename-tab -t <id> "name"` | renames **that** tab, without moving focus — how the activity glyph is written |
| `action close-tab-by-id <id>` / `go-to-tab-by-id <id>` / `rename-tab-by-id <id> "name"` | act on a tab by stable id; unused so far, and the way out of focus-then-act — see D6 |
| `action new-tab --name N --cwd D --layout L` | new tab |
| `action list-panes` | pane inventory |
| `pipe "zjstatus::pipe::pipe_<w>::<msg>"` | feed a zjstatus pipe widget — **never returns** while a plugin is listening; never wait on it |
| `attach --create <name>` | attach, creating if absent — the **only** way to get a named session *and* a layout |
| `action list-clients` | is anything attached? empty = every action silently no-ops |
| `list-sessions` | includes exited sessions (resurrectable) |
| `setup --check` | prints the real config paths |

`--pane-id <id>` targets a specific pane on `write`, `write-chars`, `send-keys`.

## AutoHotkey v2 modifier prefixes

| Prefix | Key |
|---|---|
| `^` | Ctrl |
| `+` | Shift |
| `#` | Win / GUI |
| `!` | Alt |
| `*` | fire regardless of extra modifiers |
| `~` | also pass the key through |

So `^+F13` is Ctrl+Shift+F13. **v2 only** — v1 will not parse these scripts.

## Claude Code hooks

Events: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
`PermissionRequest`, `Notification`, `Stop`, `SubagentStop`, `SessionEnd`.

stdin payload includes `session_id`, `cwd`, `hook_event_name`,
`permission_mode`, `transcript_path`, and for tool events `tool_name`,
`tool_input`, `tool_use_id`.

Exit codes: `0` success · `2` blocking error · anything else non-blocking.

**Shell form** (no `args`) uses Git Bash on Windows unless `"shell":
"powershell"`. **Exec form** (with `args`) spawns the executable directly — no
shell, no quoting, but cannot launch `.cmd`/`.bat` shims.

Docs: <https://code.claude.com/docs/en/hooks>

## Windows Terminal

Defaults: `nextTab` = `Ctrl+Tab`, `prevTab` = `Ctrl+Shift+Tab`.
Process names: `WindowsTerminal.exe`, `WindowsTerminalPreview.exe`,
`WindowsTerminalCanary.exe`.

## PowerToys Keyboard Manager

Remap targets: Key · Shortcut · Text · **Start App** · URI.
Start App options: App, Args, Start in, Elevation, If running, **Visibility**.
F13-F24 are remappable. Shortcuts must begin with a modifier, max 4 keys.

## Device identification

```powershell
# all HID/keyboard devices - diff with the pad plugged and unplugged
Get-PnpDevice -Class HIDClass,Keyboard -Status OK |
  Select FriendlyName, InstanceId | Format-Table -Wrap

# marketing name of a known VID/PID
Get-PnpDevice -InstanceId 'USB\VID_8089&PID_000C*' |
  ForEach-Object { Get-PnpDeviceProperty -InstanceId $_.InstanceId `
                     -KeyName 'DEVPKEY_Device_BusReportedDeviceDesc' } |
  Select-Object InstanceId, Data
```

## Links

| What | Where |
|---|---|
| SayoDevice configurator | <https://app.sayodevice.com> |
| Configurator fallback | <https://github.com/AustinHay/sayo-configurator> |
| Verify emitted chords | <https://keyboardtester.com> |
| Zellij CLI actions | <https://zellij.dev/documentation/cli-actions> |
| Zellij layouts / cwd | <https://zellij.dev/documentation/creating-a-layout.html> |
| Zellij pipe | <https://zellij.dev/documentation/zellij-pipe.html> |
| Zellij 0.44 Windows | <https://zellij.dev/news/remote-sessions-windows-cli/> |
| zjstatus widgets | <https://github.com/dj95/zjstatus/wiki/4-%E2%80%90-Widgets> |
| Upstream status project | <https://github.com/thoo/claude-code-zellij-status> |
| Claude Code hooks | <https://code.claude.com/docs/en/hooks> |
| PowerToys Keyboard Manager | <https://learn.microsoft.com/en-us/windows/powertoys/keyboard-manager> |
| Per-device binding | <https://github.com/evilC/AutoHotInterception> |


