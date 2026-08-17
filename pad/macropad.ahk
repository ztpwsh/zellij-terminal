#Requires AutoHotkey v2.0
#SingleInstance Force
;==============================================================================
;  SayoDevice 1_3P (VID 8089 / PID 000C) -> Windows Terminal / Claude Code
;  v4 - adds REACH mode: keys work even when the terminal isn't focused.
;
;  HOW REACH MODE WORKS  (and why it can't be invisible)
;    AHK's ControlSend posts WM_KEYDOWN/WM_KEYUP straight to a window's
;    handle, which is the usual way to type into a background app. Windows
;    Terminal ignores it - it renders through DirectX/XAML and reads the
;    focused-window keyboard path rather than posted messages. There is no
;    public API to inject a keystroke into an unfocused Terminal.
;
;    So REACH mode does the honest thing: activate the terminal, send the
;    key, then hand focus back to the window you were on. Round trip is
;    ~100ms and you will see a brief flash as the terminal comes forward.
;    Everything else is either unreliable or fiction.
;
;    Want it truly invisible? See OPTION B at the bottom - running Claude
;    Code inside tmux lets you inject with `tmux send-keys`, no focus needed.
;
;  MODES
;    "focused" - keys only act while the terminal is already active.
;    "reach"   - keys act from anywhere; terminal is briefly activated.
;
;  DIAGNOSTICS
;    Ctrl+Alt+W  active window / elevation / mode      <-- start here
;    Ctrl+Alt+M  switch between focused and reach mode
;    Ctrl+Alt+K  Key History - what did the pad send?
;    Ctrl+Alt+R  reload after editing
;    Ctrl+Alt+Q  quit
;==============================================================================

;------------------------------------------------------------------------------
; SETTINGS
;------------------------------------------------------------------------------
Global Mode := "reach"          ; "reach" or "focused"

Global Profile := "claude"      ; "claude" = Enter / Esc  (Claude Code prompts)
                                ; "yn"     = y+Enter / n+Enter  (git, apt, npm)

Global RestoreFocus := true     ; after acting, return to the window you were on
Global ActivateWait := 0.7      ; seconds to wait for the terminal to come up
Global SettleMs     := 60       ; pause before handing focus back

Global TerminalExes := [
    "WindowsTerminal.exe",
    "WindowsTerminalPreview.exe",
    "WindowsTerminalCanary.exe",
]

;==============================================================================
;  WINDOW HELPERS
;==============================================================================
IsTerminalExe(exe) {
    Global TerminalExes
    for name in TerminalExes
        if (exe = name)
            return true
    return false
}

ActiveExe() {
    try return WinGetProcessName("A")
    catch
        return ""
}

InTerminal() => IsTerminalExe(ActiveExe())

; Topmost terminal window in z-order = the one you used most recently.
FindTerminal() {
    for hwnd in WinGetList() {
        try exe := WinGetProcessName(hwnd)
        catch
            continue
        if IsTerminalExe(exe)
            return hwnd
    }
    return 0
}

;==============================================================================
;  THE DISPATCHER
;  Runs `action` with the terminal focused, then restores your previous window.
;==============================================================================
RunInTerminal(action) {
    Global Mode, RestoreFocus, ActivateWait, SettleMs

    ; Already there - just fire.
    if InTerminal() {
        action()
        return
    }

    if (Mode != "reach")
        return                          ; focused mode: do nothing elsewhere

    target := FindTerminal()
    if !target {
        ToolTip("No Windows Terminal window found")
        SetTimer(() => ToolTip(), -1500)
        return
    }

    prev := WinExist("A")               ; remember where we came from

    try WinActivate(target)
    catch
        return
    if !WinWaitActive("ahk_id " target, , ActivateWait)
        return                          ; focus refused - bail rather than
                                        ; fire the keystroke into the wrong app

    action()

    if (RestoreFocus && prev && prev != target) {
        Sleep SettleMs                  ; let the terminal consume the key
        try WinActivate("ahk_id " prev)
    }
}

;==============================================================================
;  ACTIONS
;==============================================================================
SendYes()     => Send((Profile = "yn") ? "y{Enter}" : "{Enter}")
SendNo()      => Send((Profile = "yn") ? "n{Enter}" : "{Esc}")
SendPrevTab() => Send("^+{Tab}")        ; Ctrl+Shift+Tab = prevTab
SendNextTab() => Send("^{Tab}")         ; Ctrl+Tab       = nextTab

;==============================================================================
;  PAD BINDINGS  -  global, because reach mode must work from any window.
;  ^ = Ctrl   + = Shift   # = Win   ! = Alt
;  Both the two- and three-modifier forms are bound, so it works whether or
;  not the GUI/Win tickbox saved on the pad.
;==============================================================================
^+F13::
^+#F13::  RunInTerminal(SendYes)          ; Key 1 - Yes

^+F14::
^+#F14::  RunInTerminal(SendNo)           ; Key 2 - No

^+F15::
^+#F15::  RunInTerminal(SendPrevTab)      ; Key 3 - Prev tab

^+F16::
^+#F16::  RunInTerminal(SendNextTab)      ; Key 4 - Next tab

;==============================================================================
;  DIAGNOSTICS
;==============================================================================
^!w:: {
    Global Mode, Profile, RestoreFocus, TerminalExes
    exe    := ActiveExe()
    target := FindTerminal()
    tname  := ""
    if target {
        try tname := WinGetTitle(target)
    }
    list := ""
    for name in TerminalExes
        list .= "    " name "`n"

    MsgBox(
        "ACTIVE WINDOW`n"
        "    process : " (exe = "" ? "(none)" : exe) "`n"
        "    is a terminal : " (InTerminal() ? "YES" : "NO") "`n`n"
        "TERMINAL REACH MODE WOULD TARGET`n"
        "    " (target ? tname : "(no terminal window found)") "`n`n"
        "Mode                    : " Mode "`n"
        "Profile                 : " Profile "`n"
        "Restore focus after     : " (RestoreFocus ? "YES" : "NO") "`n"
        "This script is elevated : " (A_IsAdmin ? "YES" : "NO") "`n"
        "AutoHotkey version      : " A_AhkVersion "`n`n"
        "Recognised terminal processes:`n" list "`n"
        "If your terminal's process name isn't listed, add it to TerminalExes "
        "at the top of this script.`n`n"
        "If the terminal runs as administrator and this script does not, Windows "
        "blocks the keystrokes. Run the script as administrator too.",
        "Macro pad diagnostics"
    )
}

^!m:: {
    Global Mode
    Mode := (Mode = "reach") ? "focused" : "reach"
    ToolTip("Mode: " Mode)
    SetTimer(() => ToolTip(), -1500)
}

^!k::KeyHistory
^!r::Reload
^!q::ExitApp

;==============================================================================
;  OPTION B - truly focus-free, via tmux
;==============================================================================
; The flash in reach mode exists only because Windows Terminal insists on being
; focused to receive input. Sidestep it by targeting the shell instead of the
; window: run Claude Code inside tmux, then inject with send-keys. No focus
; change, no flash, and it works while the terminal is minimised.
;
; Start Claude Code in a named session:   tmux new -s claude
;
; Then replace the bindings above with:
;
;   TmuxSend(keys) {
;       Run 'wsl.exe tmux send-keys -t claude ' keys, , "Hide"
;   }
;
;   ^+F13::TmuxSend("Enter")
;   ^+F14::TmuxSend("Escape")
;   ^+F15::TmuxSend("C-b p")
;   ^+F16::TmuxSend("C-b n")
;
; Drop `wsl.exe` if you run tmux natively rather than through WSL.
;
;==============================================================================
;  OTHER NOTES
;==============================================================================
; Per-device binding (reuse any keycode, ignore collisions entirely):
;   https://github.com/evilC/AutoHotInterception   VID 0x8089, PID 0x000C
;
; Application-launch keys instead of F-keys, if the chords ever collide:
;   Launch_App1 / Launch_App2 / Browser_Back / Browser_Forward
;==============================================================================
