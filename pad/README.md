# The pad — optional

> `zt pad explain` prints a shorter version of this from the terminal, and
> `zt setup` offers to wire it up after explaining it. This file is the long
> form: why these chords, and what to do when a key does nothing.

A physical key that answers a Claude prompt without switching windows, and
another that jumps to whichever session is asking for you.

**This is optional.** `zt go`, the Command Palette and the terminal all do the
same jobs. The pad only removes the last step: you don't have to be looking at
the right thing first.

## Any device will do

Nothing here needs a particular pad. The only requirement is four chords:

| Key | Chord | Does |
|---|---|---|
| 1 | `Ctrl+Shift+F13` | Enter — accept the highlighted option |
| 2 | `Ctrl+Shift+F14` | Esc — reject |
| 3 | `Ctrl+Shift+F15` | jump to whoever is waiting |
| 4 | `Ctrl+Shift+F16` | cycle the `claude-*` tabs |

A macro pad, a programmable layer on a mechanical keyboard, a spare numpad with
remapped keys, a foot pedal — anything that sends those.

`sayodevice-bindings.md` is a worked example for the pad this was built with.
An illustration, not a requirement.

## Choosing the keys

These four were picked to **collide with nothing**, and that is worth
understanding before you change them, because a clash here is miserable to
diagnose — the symptom is a key that mostly works.

**Pick chords nothing else claims.** `F13`–`F16` are the obvious candidates:
they are real, sendable key codes that almost nothing binds, because almost no
keyboard has the keys. Adding `Ctrl+Shift` makes an accidental match unlikelier
still.

**Prefer keys that do nothing when unhandled.** If the listener is not running,
`Ctrl+Shift+F13` does precisely nothing. Media or browser keys would still do
their real jobs — so a half-configured pad would skip tracks or navigate back
instead of failing quietly. Silent is the right failure here.

**Never use `Ctrl+Alt`.** On UK and most European layouts `Ctrl+Alt` *is*
AltGr, so a `Ctrl+Alt` hotkey fires while typing perfectly ordinary characters.
Everything here is `Ctrl+Shift` for that reason.

**Check what your machine already uses.** Windows claims a lot of `Win+` combos,
and applications claim `Ctrl+Shift+` liberally — but not with function keys this
high. If you must move them, four consecutive unused chords keep the mental
model simple.

**Then verify what the pad actually sends**, rather than what you told it to
send. Press each key at <https://keyboardtester.com>, or use `zt pad probe`,
which logs which chords arrive. A pad that saved three of four bindings looks
identical to one that saved all four until you check.

## Setting it up

Two halves, and they are independent — **programme the device**, then **tell
Windows what to do with it**.

### 1. Programme the pad

Whatever configurator your device uses, set each key to send a *keyboard* chord
— not a macro, not a text string, not a media key:

| Key | Send |
|---|---|
| 1 | `Ctrl` + `Shift` + `F13` |
| 2 | `Ctrl` + `Shift` + `F14` |
| 3 | `Ctrl` + `Shift` + `F15` |
| 4 | `Ctrl` + `Shift` + `F16` |

Most configurators have a "keyboard" or "default" mode with modifier tick-boxes
and a key picker; that is the one you want. If yours writes to the device's
flash, remember to save — several are browser-based and lose the setting
otherwise.

**Then check what actually arrived**, at <https://keyboardtester.com> or with
`zt pad probe`. Configurators do silently drop a modifier, and the resulting
mismatch is invisible: everything looks configured and nothing fires.

`sayodevice-bindings.md` walks through one specific device end to end, including
what to do when its configurator refuses to connect.

### 2. Wire the chords to commands

```powershell
zt pad install     # writes four PowerToys Keyboard Manager remaps
zt pad             # what is wired, and what is missing
```

**Then toggle Keyboard Manager off and on in PowerToys Settings.** Not optional,
and the single most confusing thing here: its engine reads the config **when it
starts**, never when the file changes. Until you toggle it, it runs whatever it
loaded last — which is why keys can go on working after the remaps are deleted,
and why console windows can go on flashing after being set back to hidden.
`zt pad` compares the engine's start time to the file and says when it is stale.

### Why PowerToys rather than AutoHotkey

Both work; `zt pad install -Listener ahk` uses the AutoHotkey script here
instead. PowerToys is the default only because most Windows machines already run
it, so Keyboard Manager costs no extra process where AutoHotkey adds a permanent
one.

Running **both** double-fires every key, which reads as the pad stuttering
rather than a configuration mistake, so `zt pad` refuses to set up one while the
other is live.

### Optional: the device-present check

`zt pad` can confirm the pad is plugged in, if you say what to look for:

```powershell
zt pad device 'USB\VID_8089&PID_000C*'
```

Find yours by unplugging it, running this, plugging it back in, and diffing:

```powershell
Get-PnpDevice -Class HIDClass,Keyboard -Status OK |
    Select-Object FriendlyName, InstanceId
```

Purely a convenience — Keyboard Manager matches the **chord**, not the device.

## When a key does nothing

`zt pad` first. As well as the STALE-engine check it reports **remap paths**: the
remaps store an absolute path to `scripts\zj-claude-tab.ps1`, so moving the clone
or installing from a second one leaves keys 3 and 4 launching the old location,
which Keyboard Manager reports by doing nothing at all. `zt pad install` rewrites
them.

```powershell
zt pad probe       # press all four, then: zt pad probe -Show, then -Stop
```

It points all four keys at a trivial logging command, separating three causes
that otherwise look identical because every one is silent:

- **all four logged** — chords arrive and launching works; the fault is in what
  the real remaps run
- **some logged** — those chords aren't reaching Keyboard Manager; check the
  pad's own programming
- **none logged** — Keyboard Manager can't launch anything, or hasn't reloaded

Two more, both learned the hard way:

- **Editing anything in the Keyboard Manager UI silently downgrades these
  remaps**, resetting launched windows to visible so a console flashes on every
  press. Re-run `zt pad install` afterwards.
- **Its per-entry toggle is not stored anywhere.** Entries can show as *off*
  while working perfectly, and making one stick needs a fake edit and a save.
  Ignore it.

## Files here

| | |
|---|---|
| `powertoys-setup.md` | the remap table, to do it by hand |
| `macropad-zellij.ahk` | the AutoHotkey alternative — no flash, targets Zellij |
| `macropad.ahk` | an older focus-stealing approach, kept for reference |
| `sayodevice-bindings.md` | worked example: programming one specific pad |

## If you use the AutoHotkey route

**AutoHotkey v2**, not v1 — the syntax is v2-only and v1 will not parse it.
`zt pad install -Listener ahk -Startup` also adds it to your Startup folder.

`macropad.ahk` is the older design and is kept only as a record of why the
current one exists: it activates the terminal, sends the key, then restores your
previous window — about 100 ms, with a visible flash. That flash is unavoidable
in that approach, because `ControlSend` posts messages to a window handle while
Windows Terminal renders through DirectX and reads the focused-window keyboard
path, ignoring them. `macropad-zellij.ahk` has no flash because it targets the
shell through Zellij rather than the window.
