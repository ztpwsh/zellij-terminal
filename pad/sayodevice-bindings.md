# SayoDevice 1_3P bindings

Device: `VID_8089` / `PID_000C`. Configurator: <https://app.sayodevice.com>
(Chrome or Edge only — Firefox and Safari don't implement WebHID).

## What to set

All four keys use plain **Default** mode (a.k.a. Keyboard) with **Ctrl** and
**Shift** ticked.

| Key | Purpose | Modifiers | Key | AHK form |
|-----|---------|-----------|-----|----------|
| 1 | Yes | Ctrl + Shift | F13 | `^+F13` |
| 2 | No | Ctrl + Shift | F14 | `^+F14` |
| 3 | Waiting / prev | Ctrl + Shift | F15 | `^+F15` |
| 4 | Next | Ctrl + Shift | F16 | `^+F16` |

## Procedure

1. Plug the pad in, open Chrome or Edge.
2. <https://app.sayodevice.com> — authorise `SayoDevice 1_3P` in the picker.
3. Click key 1 on the on-screen layout.
4. Right panel: mode **Default**, tick **Ctrl** and **Shift**, pick **F13**.
5. **Submit**.
6. Repeat for keys 2-4 with F14, F15, F16 — same two modifiers each time.
7. **Save to Device** (writes to flash).

## Verify

Open <https://keyboardtester.com> and press each key. You must see
`Ctrl+Shift+F13` through `Ctrl+Shift+F16`.

**Do not skip this.** The Win/GUI tickbox silently failed to save once already
(`docs/03-troubleshooting.md` B1) and the resulting mismatch is invisible
otherwise — everything "looks" configured and nothing fires.

## If the configurator won't connect

The official "Add device" button has been flaky. Fallback:
<https://github.com/AustinHay/sayo-configurator> — clone it, run
`python3 -m http.server`, open in a Chromium browser.

## If these chords ever collide

Program the pad to application-launch keys instead: `Launch_App1`,
`Launch_App2`, `Browser_Back`, `Browser_Forward`. Separate HID namespace, so
collision with F13-F24 is impossible. Downside: they do real things when no
listener is running, whereas unhandled F-keys fail silently.

Nuclear option: <https://github.com/evilC/AutoHotInterception> binds per
physical device, so the pad's F13 is a distinct event from the keyboard's F13
and any keycode becomes reusable. Needs the Interception kernel driver.
Device filter: VID `0x8089`, PID `0x000C`.
