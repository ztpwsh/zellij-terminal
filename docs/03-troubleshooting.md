# Troubleshooting

## Diagnose by layer, not by symptom

`zt check` — or `.\scripts\Test-Setup.ps1` if the module isn't installed —
exercises each layer separately and prints a table. Run it before changing
anything; "the pad doesn't work" has at least six distinct causes and they need
different fixes.

| Layer | Prove it in isolation |
|-------|----------------------|
| 1 device | Press the keys on <https://keyboardtester.com>. Expect `Ctrl+Shift+F13..F16`. |
| 2 listener | AHK: `Ctrl+Alt+W`. PowerToys: check the mapping list. |
| 3 transport | `zellij --session claude action write 13` from another window. |
| 4 target | `dir $env:TEMP\claude-zellij-flags` after Claude stops. |
| registry | `zt` lists workspaces; `zt sync` clears records whose tabs are gone. |

**A workspace stuck as `stale`** means a live record outlived its tab — a
terminal closed with the X button rather than detached. `zt sync` clears it.
**Stuck as `unavailable`** means this device has no root for it: see
`Get-ZellijTerminalRoot` and `docs/06-workspaces.md`.

**`zt stop` or `zt restart` refusing to run** is the attached-client check doing
its job. With nothing attached, the Ctrl+C it sends would be swallowed silently
and you would be told it worked. Run `zac` first.

## Two identical windows, and a window that will not resize

They are not two sessions. Zellij **mirrors**: a second client shows the same
tabs, takes your keystrokes in both, and — the part nobody guesses — sizes the
grid to the **smallest** client attached. So the window you are dragging never
changes width and the text never reflows, which reads as "Zellij cannot reflow
its scrollback" and sends you to the wrong layer entirely. Reflow returns the
moment one client is left.

```powershell
zellij --session claude action list-clients   # more than one row = mirrored
```

Close the spare window, or press `Ctrl+O d` in it to detach that client.
`zt check` warns when it sees more than one.

Where the second one comes from, if `zac` made it:

- **Terminal was not running at all.** `"firstWindowPreference":
  "persistedWindowLayout"` in Windows Terminal's `settings.json` restores the
  saved layout when the first window opens — and the saved layout is a window
  already running `zellij attach`. Your command line is then honoured on top of
  it, so you get two. Set it to `defaultProfile`. `zt check` reports this;
  nothing inside this rig can detect it after the fact.
- **A window was already open.** Then there is no restore, and `zac` reuses it —
  which is why the fault looks intermittent.

## The session tab has the wrong icon

`install.ps1` contributes a Windows Terminal profile as a *fragment*, and the
icon in it is extracted from your installed `zellij.exe`. **Terminal reads
fragments only at startup**, so a fresh install shows the generic console icon
until you restart Terminal. `zac` will not ask for a profile Terminal has not
discovered yet, because `wt -p <unknown>` falls back to something worse than the
default.

```powershell
type "$env:LOCALAPPDATA\Microsoft\Windows Terminal\Fragments\ZellijTerminal\zellij-terminal.json"
```

## Sessions and tabs are different levels

`zellij list-sessions` lists **sessions** — separate servers, each with its own
tabs and clients. `zt` works inside *one* session, so its tabs will never appear
there. `zt close` closes a tab; it never touches a session.

The session level accumulates strays silently — `session_serialization` keeps
exited sessions to resurrect, and a mistyped command creates a whole new server
named after a random animal. `zt sessions` is the level up:

```powershell
zt sessions                       # what exists, with tab and client counts
zt sessions kill <name> -Delete   # stop a stray and forget it
```

To wipe everything and start again, standard Zellij, in this order:

```powershell
zellij kill-all-sessions -y       # stops them
zellij delete-all-sessions -y     # and forgets them, or they resurrect
zac                               # rebuild `claude` from the layout
```

Claude Code's transcripts are on disk, not in the terminal, so `claude --resume`
in a project folder gets a conversation back afterwards. The `zt` registry is
unaffected — it lives in `config/` and `%LOCALAPPDATA%`.

## The macro pad does nothing, and nothing says why

Read the Keyboard Manager engine log. It is the only thing that distinguishes
"the chord never arrived" from "it launched and the target failed", which are
otherwise identical, because both are silent:

```
%LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager\Engine\Logs\v<version>\log_<date>.log
```

Filter out `HideProgram` lines — retry noise, and most of the file. What remains
is one line per press: `run_non_elevated with params=...`, showing exactly what
was launched with which arguments. If those lines are present, the pad and the
listener are fine and the fault is downstream.

`zt pad probe` answers the same question without reading a log: it points all
four keys at a trivial command and reports which ones arrive.

---

## Solved bugs

### B1 — Pad fired nothing at all

**Symptom:** AHK loaded, keyboardtester showed the keys, Windows Terminal
unaffected.

**Cause:** the GUI/Win tickbox did not save in the SayoDevice configurator. The
pad emitted `Ctrl+Shift+F13`; the script listened for `^+#F13`
(Ctrl+Shift+**Win**+F13). AutoHotkey requires an exact modifier match, so the
hotkey never fired.

**Fix:** script now binds both the two- and three-modifier forms.

**Lesson:** always verify the *emitted* chord on keyboardtester.com and match
the hotkey to it exactly. Ticking a modifier in the configurator does not mean
it saved.

---

### B2 — `error 2147942402 (0x80070002)` launching the Zellij WT profile

**Symptom:** "The system cannot find the file specified" when Windows Terminal
opened the profile, though the identical command worked typed into a shell.

**Cause:** `0x80070002` is `ERROR_FILE_NOT_FOUND` raised by CreateProcess —
`zellij.exe` was not resolvable. Nothing to do with the arguments; they are
never even parsed. Environment variables are captured when a process starts and
never refresh, so Windows Terminal was still running with the pre-install PATH.

**Fix:** fully restart Windows Terminal (all windows).

**Lesson:** after any PATH-modifying install, every already-running process
keeps the stale PATH. Restart the app before debugging further. If a restart
doesn't fix it, the installer probably edited only a shell profile rather than
the user PATH — find the real location with `(Get-Command zellij).Source` and
hard-code it in the profile's `commandline`, escaping backslashes for JSON.

---

### B3 — Every pane black and white, and the prompt unstyled

Claude Code sets `NO_COLOR=1` for the commands it runs. Ask Claude to set this
rig up and `zac` runs inside that environment, so the zellij **server** it starts
inherits `NO_COLOR=1` — and panes inherit the server's environment, not the
environment of whatever asked for the tab. `NO_COLOR` is honoured before `TERM`
and `COLORTERM` are consulted, so the pane prelude's colour settings do nothing.

It reads as "this is cmd, not pwsh", because a themed prompt loses its styling at
the same time.

Fixed in two places, and it needs both: `zac` scrubs `NO_COLOR` and
`CLAUDE_CODE_CHILD_SESSION` before `attach --create`, so the server never
inherits them; and the pane prelude clears them too, for a server that was
started some other way. Only the first covers a tab opened with Zellij's own
keybinding, which uses `new_tab_template` and gets no prelude.

### B4 — Keys 3 and 4 stop working after moving the clone

The Keyboard Manager remaps store an **absolute** path to
`scripts\zj-claude-tab.ps1`, frozen when they were written. Move the clone, or
install from a second one, and those two keys go on launching the old path —
which Keyboard Manager reports by doing nothing at all.

`zt pad` now checks it and prints `remap paths`, naming both the stale path and
the current repo. Fix with `zt pad install`, then toggle Keyboard Manager.

### B5 — The hook seems to do nothing, and leaves no trace

The hook runs detached under `powershell.exe` with output going nowhere, so a
malformed payload or an unreadable state file used to mean it quietly did
nothing: no flag, no status, no error. Every symptom then pointed at the pad, or
Zellij, or the layout.

It now logs failures to `%TEMP%\claude-zellij-hook.log`, one line each, and
`zt check` reports the file under **Hook errors**. Set `ZT_HOOK_DEBUG=1` to log
successful events too. It still exits 0 whatever happens — a hook that fails a
session is worse than a hook that fails.

If the log is empty and nothing is happening, the hook is not registered for that
project. It fires only where it is registered; `install.ps1 -Global` registers it
for every project.

## Known traps not yet hit

### Elevation mismatch (reach mode only)

If Windows Terminal runs as administrator and AutoHotkey does not, Windows
silently blocks the keystrokes. Classic symptom: keys work everywhere **except**
the terminal. `Ctrl+Alt+W` reports the script's elevation state. Fix: run the
script as administrator too, or launch the terminal unelevated.

Does not apply to the Zellij route — nothing is injected into a window there.

### Wrong Windows Terminal process name

Preview is `WindowsTerminalPreview.exe`, not `WindowsTerminal.exe`. All three
channel names are in the script's `TerminalExes` list; `Ctrl+Alt+W` shows what
the active window actually is.

### zjstatus shows escape codes instead of colour

`pipe_status_rendermode` is `static` (the default). It must be `dynamic` for
zjstatus to interpret `#[fg=...]` markup in the piped message rather than print
it literally.

### Git Bash mangles the zjstatus pipe string

If you run the upstream bash hook rather than the PowerShell port: MSYS rewrites
arguments that look like Unix paths when passing them to a Windows `.exe`, which
can silently corrupt `zjstatus::pipe::...`. Set `MSYS_NO_PATHCONV=1`.

Also: the bash script needs `jq` (`winget install jqlang.jq`), and its `/tmp`
paths land inside the Git Bash root where nothing else on Windows will find
them.

### PowerShell 5.1 syntax errors

Hooks registered against `powershell.exe` run Windows PowerShell 5.1, which has
no ternary `? :`, no `??`, and no `&&`/`||` chains. Scripts here avoid all
three deliberately. If you add PowerShell 7 syntax, either register `pwsh.exe`
instead or don't.
