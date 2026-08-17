# Architecture

Four layers. Each is independently testable, which is the whole point — when
something breaks you want to isolate *which* layer before touching anything.

```
+----------------------------------------------------------+
| 1. DEVICE      SayoDevice 1_3P                            |
|                emits Ctrl+Shift+F13..F16 from flash       |
+----------------------------------------------------------+
                          |  global keystrokes
                          v
+----------------------------------------------------------+
| 2. LISTENER    PowerToys Keyboard Manager (or AHK v2)     |
|                catches the chords, spawns a command       |
+----------------------------------------------------------+
                          |  process launch
                          v
+----------------------------------------------------------+
| 3. TRANSPORT   zellij CLI                                 |
|                write 13 / write 27 / go-to-tab-name       |
+----------------------------------------------------------+
                          |  Zellij IPC
                          v
+----------------------------------------------------------+
| 4. TARGET      Claude Code, one tab per project           |
|                hooks write flag files back to layer 2/3   |
+----------------------------------------------------------+
```

## Layer 1 — device

Bindings live in the pad's flash, set via the WebHID configurator at
<https://app.sayodevice.com> (Chrome or Edge; Firefox and Safari don't
implement WebHID). See `pad/sayodevice-bindings.md`.

The pad deliberately emits *inert* chords rather than the final actions. If the
listener isn't running the pad does nothing, rather than misfiring — a better
failure mode than stray `Esc` keypresses landing in random applications.

## Layer 2 — listener

Two interchangeable options.

**PowerToys Keyboard Manager** — GUI config, no script file, and it removes the
elevation problem entirely: nothing is injected into a window, so it stops
mattering whether the terminal runs as administrator. See
`pad/powertoys-setup.md`.

**AutoHotkey v2** — needed if you want conditional behaviour: scoping to a
specific application, the `yn` vs `claude` profile toggle, runtime mode
switching, diagnostics. See `pad/macropad.ahk`.

Pick one. Running both means double-firing.

## Layer 3 — transport

Everything goes through the `zellij` CLI, always targeting the session
explicitly:

```powershell
zellij --session claude action write 13              # Enter
zellij --session claude action write 27              # Esc
zellij --session claude action go-to-tab-name "claude-api"
zellij --session claude action query-tab-names
zellij --session claude action current-tab-info
zellij --session claude pipe "zjstatus::pipe::pipe_status::..."
```

This layer is why the whole thing can be focus-free: it addresses the shell, not
the window. Windows Terminal becomes just a viewport.

Cost, measured: keys 1 and 2 call `zellij.exe` directly at **~60 ms** mean —
invisible for a confirm prompt. Keys 3 and 4 go through a PowerShell script at
**~460 ms**, almost all of it PowerShell startup
rather than the script's work. That buys landing on the *right* tab instead of
merely the next one.

**A client must be attached.** With no terminal window open on the session,
`write`, `write-chars`, `go-to-tab-name`, `close-tab` and `dump-screen` are all
silent no-ops **that still exit 0**, and injected bytes vanish. Minimised or
unfocused is fine; closed is not. `action current-tab-info` likewise only
answers for an attached client — from outside it prints `No active tab found for
current client` and exits 2, which is why the scripts keep a `%TEMP%` state file
as their primary record of the current tab.

## Layer 4 — target and feedback

Claude Code runs one instance per Zellij tab, tabs named `claude-<project>` to
match the leaf folder of the project directory. That naming is load-bearing —
`hooks/claude-zj-hook.ps1` derives the tab name from the `cwd` on stdin, and
`scripts/zj-claude-tab.ps1` filters on the prefix.

The hook closes the loop: it writes `%TEMP%\claude-zellij-flags\<tab>.json` when
a session needs a human, and pipes a coloured summary to zjstatus. That turns
key 3 from "next tab" into "take me to whoever needs me", which is a materially
better use of a key.

## The registry — `zt`

Above the four layers, and not part of any of them, sits the workspace registry
in `module/ZellijTerminal`. It answers "what do I have, what is running, start
and stop it" — the questions the pad cannot ask because a pad has four keys.

It is deliberately **not** on any latency path. The pad and the hook call
`scripts/` directly, so neither pays for a module import, and both work with the
module absent. The hook's only contribution is one small live record per
session, written inline in about twenty lines rather than by calling into the
module: importing one costs more than the whole hook, and the hook runs under
5.1 while the module sits on the pwsh 7 module path.

Definitions are split between `config/workspaces.json` (shared, in git, ships
with the clone) and `%LOCALAPPDATA%\ZellijTerminal\devices\<HOSTNAME>.json`
(**written only by that device**, which is what makes automatic registration
safe on several machines). The device file is state rather than source, so it
sits outside the working tree where `git clean` and a re-clone cannot reach it;
`ZT_CONFIG_HOME` moves both files into a private repo if you want them shared.
Live state sits under `%LOCALAPPDATA%` and is never committed. The registry is a cache;
`zellij query-tab-names` and the flag files are the truth, and every read
reconciles against them. Full design in `docs/06-workspaces.md`.

## Key map

| Key | Chord | Action | Rationale |
|-----|-------|--------|-----------|
| 1 | Ctrl+Shift+F13 | `write 13` -> Enter | accepts the highlighted option |
| 2 | Ctrl+Shift+F14 | `write 27` -> Esc | rejects |
| 3 | Ctrl+Shift+F15 | `zj-claude-tab.ps1 -Waiting` | jump to whoever needs you |
| 4 | Ctrl+Shift+F16 | `zj-claude-tab.ps1 -Direction next` | cycle Claude tabs |

**Why Enter and not `y`.** Claude Code's permission prompt is an arrow-key
select list, not a y/n question. `Enter` accepts the highlighted option and
`Esc` rejects; typing a literal `y` does nothing. The AHK script's
`Profile := "yn"` toggle exists for classic git/apt/npm prompts, which do want
`y`+Enter.

## Zellij's place in the stack

Zellij is **not** an alternative to Windows Terminal and you do not migrate to
it. Windows Terminal is the emulator — window, GPU rendering, fonts, profiles.
Zellij is a multiplexer that runs inside it.

Do not wrap every Windows Terminal profile in Zellij: you get two nested tab
systems, two competing keybinding sets, and Zellij's Ctrl shortcuts intercepting
keys the shell wants. Add **one** dedicated profile. See `zellij/README.md`.
