# PowerToys Keyboard Manager as the listener

The scriptless alternative to AutoHotkey, and the default: PowerToys is already
running, so Keyboard Manager costs no extra process where AutoHotkey adds one.

**You do not have to do any of this by hand:**

```powershell
zt pad install        # writes all four remaps
zt pad check          # what is wired, and what is missing
zt pad uninstall      # removes only the ones this rig created
```

It backs up `default.json` first and leaves any remaps of your own alone — ours
are identified by what they run, not by which keys they use. The rest of this
page is what it writes, and how to do it by hand if you would rather.

Settings -> Keyboard Manager -> **Remap a shortcut**.

For every row: **Start App**, App `zellij.exe`, Visibility **Hidden**,
If running **Start another instance**.

| Key | Shortcut | Args |
|-----|----------|------|
| 1 | Ctrl+Shift+F13 | `--session claude action write 13` |
| 2 | Ctrl+Shift+F14 | `--session claude action write 27` |

Keys 3 and 4 run a script rather than zellij directly, so App becomes
`powershell.exe`:

| Key | Shortcut | Args |
|-----|----------|------|
| 3 | Ctrl+Shift+F15 | `-NoProfile -ExecutionPolicy Bypass -File C:\code\zt\scripts\zj-claude-tab.ps1 -Waiting` |
| 4 | Ctrl+Shift+F16 | `-NoProfile -ExecutionPolicy Bypass -File C:\code\zt\scripts\zj-claude-tab.ps1 -Direction next` |

Keep `-NoProfile`, but don't expect much from it: measured at **~22 ms** on this
machine (458 ms vs 480 ms mean), because the profile here is light. On a machine
with a heavy profile it would matter far more, so it stays.

The real cost of keys 3 and 4 is **PowerShell startup itself — ~460 ms per
press**, against ~60 ms for keys 1 and 2 calling `zellij.exe` directly. That is
the price of landing on the *right* tab rather than merely the next one. If it
ever grates, the fix is to stop starting PowerShell per press, not to trim the
script.

## Why this is attractive

**The elevation problem disappears.** Nothing is being injected into a window
any more; you're just launching a process. So it stops mattering whether your
terminal runs as administrator — which is the single most annoying failure mode
of the AutoHotkey route.

No script file to autostart either, assuming PowerToys already runs at login.

## What you give up

Conditional logic. No app scoping, no `yn` vs `claude` profile toggle, no
runtime mode switching, no diagnostic dialogs. On the Zellij route the commands
are unconditional so there's nothing to condition on — but if you go back to
reach mode you'll want AutoHotkey again.

## Constraints

- F13-F24 are remappable.
- Shortcuts must begin with a modifier — `Ctrl+Shift` satisfies this.
- Maximum 4 keys per shortcut.
- Reserved and unavailable: `Win+L`, `Ctrl+Alt+Del`, `Win+G`.

## Don't run both listeners

PowerToys and AutoHotkey bound to the same chords will both fire. Pick one.

