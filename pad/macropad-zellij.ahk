#Requires AutoHotkey v2.0
#SingleInstance Force
;==============================================================================
;  SayoDevice 1_3P -> Claude Code running inside Zellij on native Windows
;
;  WHAT THIS BUYS YOU
;    No focus change, no flash, no window activation. The keys reach Claude
;    Code even when Windows Terminal is minimised or you're in another app.
;
;  WHY IT WORKS WHEN REACH MODE CAN'T
;    Reach mode has to fight Windows Terminal for focus because Terminal only
;    accepts keystrokes when it's the foreground window. This script doesn't
;    touch the window at all - it asks Zellij to inject input into the pane
;    directly, over Zellij's own IPC. The terminal is just a viewport.
;
;  PREREQUISITES
;    1. Zellij 0.44.0 or newer, which is the first release to run natively on
;       Windows (not WSL).  https://zellij.dev
;    2. zellij.exe on your PATH.
;    3. Claude Code started inside a named Zellij session:
;
;           zellij --session claude
;           claude
;
;    Verify the plumbing before wiring the pad - run this from any other
;    terminal window while Claude Code sits at a prompt:
;
;           zellij --session claude action write 13
;
;    If Claude Code accepts the prompt, you're done; the rest is just keys.
;==============================================================================

Global Session := "claude"      ; must match: zellij --session <name>

; Set to "" if zellij.exe is on your PATH. Otherwise give the full path.
Global ZellijExe := "zellij.exe"

; Repo location - keys 3 and 4 call a script from here.
Global RepoDir := "C:\code\zt"

;==============================================================================
;  PLUMBING
;==============================================================================
Zellij(argstring) {
    Global Session, ZellijExe
    cmd := ZellijExe
    if (Session != "")
        cmd .= ' --session "' Session '"'
    cmd .= " action " argstring
    try
        ; Run zellij.exe directly. An earlier version wrapped this in
        ; `A_ComSpec /c`, which spawns a cmd.exe purely to spawn zellij:
        ; measured at 95 ms mean versus 60 ms direct, so the wrapper was
        ; costing ~35 ms on every press for nothing. Run(..., "Hide") already
        ; suppresses the console window.
        Run(cmd, , "Hide")
    catch as e {
        ToolTip("Zellij call failed: " e.Message)
        SetTimer(() => ToolTip(), -2500)
    }
}

; Run one of the repo's PowerShell scripts, hidden.
;   -NoProfile matters: loading a profile on every keypress adds real latency
;   (measured at ~500 ms per PowerShell start).
PSScript(scriptName, argstring) {
    Global RepoDir
    cmd := 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'
         . RepoDir '\scripts\' scriptName '" ' argstring
    try
        Run(cmd, , "Hide")
    catch as e {
        ToolTip("Script call failed: " e.Message)
        SetTimer(() => ToolTip(), -2500)
    }
}

;==============================================================================
;  ACTIONS
;    write <byte>  is the most literal way to inject a keystroke.
;      13 = Carriage Return (Enter)      27 = Escape
;    Newer Zellij also has:  action send-keys "Enter"
;    Swap if you prefer names over byte values.
;==============================================================================
ZYes(*)     => Zellij("write 13")
ZNo(*)      => Zellij("write 27")

; Keys 3 and 4 go through zj-claude-tab.ps1 rather than Zellij's own
; go-to-next-tab / go-to-previous-tab. Two reasons:
;
;   1. -Waiting is the whole point. It reads the flag files the hook writes and
;      jumps to the session that actually needs you, oldest first, walking the
;      queue on repeated presses. Zellij's own tab actions cannot know which
;      session is waiting. This path is proved end to end.
;
;   2. Even for plain cycling, the script filters to claude-* tabs. Zellij's
;      go-to-next-tab includes every tab, so it lands you on `scratch`.
;
; Costs a PowerShell start (~500 ms) versus a bare zellij call (~50 ms). Worth
; it for landing on the right tab; if you want raw speed on key 4, swap it back
; to Zellij("go-to-next-tab") and accept the scratch tab in the rotation.
ZWaiting(*) => PSScript("zj-claude-tab.ps1", "-Waiting")
ZNextTab(*) => PSScript("zj-claude-tab.ps1", "-Direction next")

;==============================================================================
;  PAD BINDINGS  -  global on purpose; the whole point is working from anywhere
;  ^ = Ctrl   + = Shift   # = Win   ! = Alt
;==============================================================================
^+F13::
^+#F13::  ZYes()             ; Key 1 - Yes  (Enter)

^+F14::
^+#F14::  ZNo()              ; Key 2 - No   (Esc)

^+F15::
^+#F15::  ZWaiting()         ; Key 3 - Jump to whichever session is waiting

^+F16::
^+#F16::  ZNextTab()         ; Key 4 - Cycle claude-* tabs

;==============================================================================
;  DIAGNOSTICS
;==============================================================================
; Win+Shift+Z - is Zellij reachable, is the session alive, and is anything
; attached to it?
;
; NOT Ctrl+Alt+Z. On a UK layout Ctrl+Alt IS AltGr, so a Ctrl+Alt hotkey fires
; while typing perfectly ordinary characters - which is why D21 in
; docs/02-decisions.md rules it out outright. This script had one anyway.
#+z:: {
    Global Session, ZellijExe
    tmp  := A_Temp "\zellij-sessions.txt"
    tmp2 := A_Temp "\zellij-clients.txt"

    RunWait(A_ComSpec ' /c ' ZellijExe ' list-sessions > "' tmp '" 2>&1', , "Hide")
    out := ""
    try out := FileRead(tmp)

    ; A DETACHED session is the failure mode that looks exactly like a dead pad:
    ; every action still exits 0, but nothing happens and no bytes arrive
    ; Check it here, because nothing else will tell you.
    RunWait(A_ComSpec ' /c ' ZellijExe ' --session "' Session '" action list-clients > "' tmp2 '" 2>&1', , "Hide")
    clients := ""
    try clients := FileRead(tmp2)

    ; The header line is always printed; a real client is a numbered row.
    attached := RegExMatch(clients, "m)^\d+\s") ? "YES" : "NO  <-- THIS IS YOUR PROBLEM"

    MsgBox(
        "Configured session : " Session "`n"
        "Zellij executable  : " ZellijExe "`n"
        "Script elevated    : " (A_IsAdmin ? "YES" : "NO") "`n"
        "Client attached    : " attached "`n`n"
        "zellij list-sessions:`n`n" (Trim(out) = "" ? "(no output - is zellij.exe on PATH?)" : out)
        "`n`nlist-clients:`n`n" (Trim(clients) = "" ? "(no output)" : clients)
        "`n`nThe session named above must appear in the list AND have a client "
        "attached. Without a client, every key silently does nothing while still "
        "reporting success. A minimised or unfocused window is fine - a closed "
        "one is not."
        "`n`nStart it with:`n`n    zellij attach --create " Session,
        "Zellij macro pad diagnostics"
    )
}

^!k::KeyHistory
^!r::Reload
^!q::ExitApp

;==============================================================================
;  NOTES
;==============================================================================
; Latency, measured on this machine (8 runs each):
;
;   keys 1/2, zellij.exe direct .................  60 ms mean (51-98)
;   keys 1/2, wrapped in cmd.exe /c .............  95 ms mean  <- avoid
;   keys 3/4, powershell.exe -NoProfile ......... 458 ms mean (430-502)
;   keys 3/4, powershell.exe with profile ....... 480 ms mean
;
; Keys 1 and 2 are comfortably imperceptible. Keys 3 and 4 are not - the ~460 ms
; is almost entirely PowerShell process startup, not the script's work, and
; -NoProfile only saves ~22 ms of it on this machine. If key 3 ever feels slow
; enough to matter, the fix is to stop starting PowerShell per press (read the
; flag files from AHK directly, or use a small compiled helper), not to shave
; the script.
;
; Targeting a specific pane rather than the focused one:
;     zellij --session claude action write --pane-id terminal_3 13
;     zellij --session claude action list-panes      (to find the id)
;
; If `--session` is rejected by your Zellij build, check `zellij --help`.
; With only one session running you can drop the flag entirely - set
; Session := "" at the top.
;
; Keys 3 and 4 now switch ZELLIJ tabs, not Windows Terminal tabs. If you want
; Windows Terminal tabs instead, keep those two keys in the reach-mode script
; and use this one only for keys 1 and 2.
;
; A CLIENT MUST BE ATTACHED to the session. With no terminal window open on it,
; every action here - write, go-to-tab-name, close-tab - is a silent no-op that
; STILL EXITS 0, and injected bytes vanish entirely. Minimised or unfocused is
; fine; closed is not. If the pad appears dead, check this first:
;
;     zellij --session claude action list-clients
;
; An empty table under the header is the whole diagnosis.
;==============================================================================

