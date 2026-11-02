# Window Centering Tool (WCT)

A lightweight utility batch file for Windows that lets you center the active window with a customizable hotkey. Runs silently in the system tray.

## Features

- Customizable primary and secondary hotkeys (supports `Ctrl`, `Shift`, `Alt` combinations)
- Default hotkey: `Ctrl+Shift+C` (change it any time in Settings)
- Live hotkey recording via the settings window (`Esc` cancels a recording)
- **Clear buttons for both hotkeys** – primary and secondary can be unset individually
- **Smart Save button** – enabled only when something actually changed *and* the pending combination is valid
- **Duplicate & invalid feedback** – identical primary/secondary hotkeys and modifier-only combos are flagged inline (red textboxes + hint text) and cannot be saved
- **Collision handling** – if a hotkey is already used by another program, the tool shows a clear warning (tray balloon + log) and keeps the previously working hotkey instead of leaving the app half-configured; this applies to the secondary hotkey too (it used to fail silently)
- Two centering modes: respect taskbar bounds or ignore it
- **Safe window filtering** – minimized, invisible, DWM-cloaked, tool/notification and shell/taskbar windows are never moved
- System tray icon with context menu (pause, settings, restart as admin, exit)
- Left‑click tray icon to open settings
- Settings window stays on top for easy access
- **Unsaved hotkey changes** – record without applying immediately; explicit Save button; save prompt on close
- **Open Config** button – view/edit `WindowCenteringTool.json` directly
- **Restart as Administrator** – elevate the tool when needed (e.g., to center windows of elevated apps)
- **Validated, versioned config** – `ConfigVersion` field; every load normalizes values, repairs malformed fields (keeping all valid settings) and logs what it fixed; duplicate hotkeys are rejected with a warning
- **Atomic config writes** – JSON is written to a temp file and moved into place, so an interrupted write can never corrupt the config
- **Safe exit & cleanup** – hotkeys, tray icon, message window, GDI icon handle, trim timer and the temp script are cleaned up in a `try/finally`, even when startup or the message loop crashes
- **Explicit logging** – `WindowCenterTool_error.log` lines carry timestamp + script version; startup logs the active hotkeys and mode; warnings/errors include the config state; log rotates at ~512 KB
- Reduced memory footprint (periodic working-set trimming)
- **Windows 11 26H2-ready launcher** – no VBScript dependency, no console flash, self-cleaning temp files

## Requirements

- Windows 10 or Windows 11 (24H2 / 25H2 / 26H2 and later)
- Windows PowerShell 5.1 (built into Windows). If 5.1 is ever missing, the launcher automatically falls back to PowerShell 7 (`pwsh.exe`) if it is installed.
- No VBScript/wscript dependency and nothing to install

## How It Works

1. Double-click `WindowCenteringTool.bat` (or a shortcut to it, e.g. one placed in the `shell:startup` folder to start it at logon).
2. The batch file extracts the PowerShell code embedded between the `:PS_START` and `:PS_END` markers into a unique temp file (`WCT_<ProcessId>.ps1` in your temp folder).
3. It relaunches that script in a hidden, console-free PowerShell process, so nothing flashes on screen. The temp file deletes itself as soon as the script starts (with a second defensive attempt at shutdown).
4. The tool then registers the configured hotkeys and sits in the system tray. Settings are stored in `WindowCenteringTool.json` next to the batch file; warnings and errors are written to `WindowCenterTool_error.log`.

## Hotkey Recording Rules

- Press `Ctrl`/`Shift`/`Alt` **plus** a key (e.g. `Ctrl+Shift+C`). Modifier keys on their own are not a valid hotkey.
- A combination without modifiers is only accepted for `F1`–`F24` (a bare letter would become unusable system-wide while the tool runs).
- The `Windows` key cannot be recorded (WinForms does not report it in `KeyDown`); use `Ctrl`/`Shift`/`Alt`.
- Primary and secondary hotkeys must differ; picking the same combination twice is flagged in the UI and cannot be saved.

## Config File (`WindowCenteringTool.json`)

- Created next to the batch file on first run.
- Fields: `ConfigVersion`, `Hotkey1`, `Hotkey2` (`null` or an object with `Modifiers`, `Key`, `ModifierFlags`, `VirtualKey`), `CenteringMode` (`RespectTaskbar` or `IgnoreTaskbar`).
- Every value is validated on load. Malformed fields are reset (and logged) while all valid settings are preserved; the repaired file is written back immediately.
- If the JSON is unreadable, it is kept as `WindowCenteringTool.json.bad` for inspection and defaults are used.

## Compatibility Notes (Windows 11 26H2)

- **VBScript removed from the launcher.** Microsoft deprecated VBScript starting with Windows 11 24H2 and is phasing it out of the OS entirely (the Feature on Demand will be disabled by default around 2027 and removed afterwards). The tool no longer uses `wscript.exe` or any `.vbs` file — the hidden launch is done entirely in PowerShell via `ProcessStartInfo` with `CreateNoWindow`, so there is also no window flash at startup.
- **Temp file collision fixed.** The old launcher used the undefined `%PID%` batch variable, so every instance actually shared the same temp name (`CenterWindowTray_.ps1`). Temp files are now named with the real PowerShell process ID (`$PID`), so multiple instances can never collide.
- **No more 2-second race or temp litter.** The extracted `.ps1` deletes itself immediately at startup. The old `.vbs` cleanup waited 2 seconds and could delete the script too early on slow systems, and the `.vbs` file itself was never removed.
- **Clearer failures.** If the `:PS_START` / `:PS_END` markers are missing (e.g., the file was edited incorrectly), the launcher shows a clear message and keeps the console open instead of failing silently. A PowerShell 7 fallback is used automatically if Windows PowerShell 5.1 is not present.
- **Config upgrades.** Config files written by older versions are upgraded automatically on first start (they gain the `ConfigVersion` field); no manual migration needed.
- **v2.0.1 startup fix.** Version 2.0 crashed on *every* start with `Cannot bind argument to parameter 'LiteralPath' because it is null`: the config file path (`$script:configFile`) was read in `Load-Config` before it was ever assigned. The path is now created during bootstrap, `Load-Config` additionally derives it defensively if bootstrap ever changes, and the log/footer version reads `v2.0.1` so you can confirm the fixed build is running.
- If SmartScreen blocks a freshly downloaded copy, right-click the `.bat` → Properties → **Unblock**, then run it again.

## Work in Progress

It's still a work in progress, so expect some problems here and there.
