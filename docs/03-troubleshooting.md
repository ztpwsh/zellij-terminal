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

**No status bar, and everything checks out.** Zellij gates plugins behind a
permission grant kept in `%LOCALAPPDATA%\Zellij\cache\permissions.kdl` — not in
the clone, not under `%APPDATA%`, and acquired *interactively* the first time a
plugin loads. Without it zjstatus is held pending approval. The prompt does
render — one line across the top row, `This plugin asks permission to: … Allow?
(y/n)` — but the session starts in **locked** mode with focus in the terminal
pane, so `y` goes to whatever is running there and never reaches the plugin. It
looks like a banner rather than a question and sits unanswered, so the bar never
appears and nothing is logged, while the layout, the plugin binary and the
config are all provably correct. `zt check` reported "No failures" on every line
of the machine this was found on.

The fix, in this order, and the order is the whole difference:

```powershell
zellij list-sessions
zellij delete-session <name> --force     # every one of them
.\install.ps1                            # writes the grant
zac
```

**`delete-session`, not `kill-session`** — see the next entry. And the installer
refuses to write the grant while a Zellij server is running, because the server
holds its permission state in memory and writes its own copy back when it exits,
undoing anything written underneath it. That it rewrites the file is observable:
the installer writes the three permissions in a fixed order and Zellij hands
them back in a different one.

**A repair that keeps not taking effect.** `session_serialization true` is set
deliberately in `config.kdl`, so an exited session stays in `zellij
list-sessions` and `attach --create` **resurrects** it rather than building a new
one from the layout. Everything changed since — a rewritten layout, a plugin
permission granted, a config edit — is therefore never read, and reinstalling
changes nothing however many times you do it. A killed session resurrects too;
only `delete-session` clears it. `zt check` warns when any exited session is
still listed.

**When `zt check` is clean and the rig still does not work**, run `zt diag`. It
writes one file describing what is actually on the machine — the layer check
asks whether each file is *there*, and the two files that decide whether this rig
starts are generated per machine and are in no repository, so nothing can check
them by reading the source. A deployed `claude.kdl` whose plugin path points at a
file that was never downloaded, or that still contains a literal `{{PLUGINS}}`,
is a PASS on every question the layer check knows how to ask and a session with
no status bar. `zt diag` reads those files out and diffs them against what this
clone would generate. Send the file it writes; it is redacted by default.

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

### B6 — Multi-line paste arrives one line at a time inside Zellij

**Symptom:** Ctrl+V a block of text into a tab and each line arrives separately.
In Claude Code every newline submits, so a ten-line paste becomes ten prompts.
Outside Zellij the same paste lands as one block.

**Cause:** bracketed paste. Windows Terminal wraps a paste in `ESC[200~` /
`ESC[201~` **only when the application it is talking to has enabled mode 2004**,
and inside a session that application is Zellij, not the pane. Zellij 0.44.3 on
Windows does not negotiate it, so Terminal types the clipboard in as ordinary
keystrokes and every newline is Enter. Zellij never sees a paste, so it cannot
bracket the inner hop to the pane either — one missing negotiation, both hops
broken.

This is not `TERM`, `COLORTERM` or `NO_COLOR`, all of which look guilty and cost
an afternoon. **Prove which layer it is without Claude in the picture:** at a
plain `pwsh` prompt inside a Zellij pane, with nothing else running, paste two
lines. If they arrive separately, the fault is below Claude entirely.

**Fix:**

```powershell
zt paste          # which half is missing, if any
zt paste fix      # do both, with a backup of every file touched
```

`zt check` reports it too, as **Paste (Ctrl+V)** under `env`.

This is not part of `install.ps1` on purpose. The installer reaches Windows
Terminal through *fragments* precisely so it never rewrites `settings.json`,
which is JSONC — a `ConvertTo-Json` round-trip silently deletes every comment in
it. Keybindings cannot be set from a fragment, so the rewrite is a targeted text
edit, it happens only when asked for by name, and it takes a backup first.

What it does, if you would rather do it by hand — and it needs both halves, one
per layer:

- **Windows Terminal** — unbind Ctrl+V so it stops performing the broken paste
  and the keystroke reaches the application instead. In `settings.json`, in the
  `keybindings` array:

  ```json
  { "id": null, "keys": "ctrl+v" }
  ```

  PSReadLine then handles Ctrl+V itself, reading the clipboard directly, and a
  block paste at a shell prompt works.

- **Claude Code** — it has no Ctrl+V of its own, so after the unbind the key does
  nothing there. Point it at the clipboard action, in `~/.claude/keybindings.json`:

  ```json
  {
    "bindings": [
      { "context": "Chat", "bindings": { "ctrl+v": "chat:imagePaste" } }
    ]
  }
  ```

  Additive, so the built-in `alt+v` keeps working. Restart Claude to load it.

**Workaround if you change nothing:** `alt+v` already reads the clipboard through
the OS rather than the terminal, so it is immune to all of this — for text as
well as images, despite the action's name.

**Lesson:** a multiplexer is a terminal emulator. Any capability the pane
negotiates — colour, paste, mouse — is negotiated twice, and the outer half is
the one nobody thinks to check. `cmd.exe` has no clipboard binding of its own, so
Ctrl+V does nothing there once Terminal stops handling it; that is the one cost
of the fix, and `default_shell` is `pwsh.exe`.

### B7 — `SessionEnd hook [...] failed: Hook cancelled`

**Symptom:** quitting Claude Code prints one of these per registered hook —
this rig's and anybody else's:

```
SessionEnd hook [powershell.exe ... claude-zj-hook.ps1] failed: Hook cancelled
SessionEnd hook [node ".../session-end.js"] failed: Hook cancelled
```

**Cause:** not the hook. Two unrelated hooks failing identically is the tell.
Claude Code cancels hooks that have not finished by the time it exits, and
`powershell.exe` alone takes around 500 ms to start — run the same payload by
hand and it completes in well under a second with exit 0 and nothing in
`%TEMP%\claude-zellij-hook.log`. Losing that race is normal.

**What it costs:** `SessionEnd` is pure cleanup — it deletes the live record,
the waiting flag, the status entry and the tab cache, and clears the tab glyph.
All five leak. The one that shows is the live record: the tab outlives the
session too, because the pane drops back to a shell, so a workspace with both
survivors used to read `running` indefinitely and `zt go` would jump to a dead
session.

**Fix:** the live record carries `CLAUDE_PID` from 0.7.7, so a dead session is
recognised as one and reads `stale` instead. Clear the leftovers with:

```powershell
zt sync
```

**Lesson:** a shutdown hook is best-effort by construction — the process it runs
in is the one going away. Anything that must be true afterwards has to be
derivable from what is on disk, not from the hook having run. Note what this
does **not** do: it does not delete the record. A record with a dead process is
exactly what a crash leaves behind, and `zt restore` reads those to reopen what
went down — see `docs/06-workspaces.md`.

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
