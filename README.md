# Window Centering Tool (WCT)

A lightweight utility batch file for Windows that lets you center the active window with a customizable hotkey. Runs silently in the system tray.

## Features

- Customizable primary and secondary hotkeys (supports `Ctrl`, `Shift`, `Alt` combinations)
- Default hotkey: `Ctrl+Shift+C` (change it any time in Settings)
- Live hotkey recording via the settings window
- Two centering modes: respect taskbar bounds or ignore it
- System tray icon with context menu (pause, settings, restart as admin, exit)
- Left‑click tray icon to open settings
- Settings window stays on top for easy access
- **Unsaved hotkey changes** – record without applying immediately; explicit Save button
- **Open Config** button – view/edit `WindowCenteringTool.json` directly
- **Restart as Administrator** – elevate the tool when needed (e.g., to center windows of elevated apps)
- Config automatically saved (JSON)
- Reduced memory footprint (periodic trimming)
- **Windows 11 26H2-ready launcher** – no VBScript dependency, no console flash, self-cleaning temp files

## Requirements

- Windows 10 or Windows 11 (24H2 / 25H2 / 26H2 and later)
- Windows PowerShell 5.1 (built into Windows). If 5.1 is ever missing, the launcher automatically falls back to PowerShell 7 (`pwsh.exe`) if it is installed.
- No VBScript/wscript dependency and nothing to install

## How It Works

1. Double-click `WindowCenteringTool.bat` (or a shortcut to it, e.g. one placed in the `shell:startup` folder to start it at logon).
2. The batch file extracts the PowerShell code embedded between the `:PS_START` and `:PS_END` markers into a unique temp file (`WCT_<ProcessId>.ps1` in your temp folder).
3. It relaunches that script in a hidden, console-free PowerShell process, so nothing flashes on screen. The temp file deletes itself as soon as the script starts.
4. The tool then registers the configured hotkeys and sits in the system tray. Settings are stored in `WindowCenteringTool.json` next to the batch file; errors are written to `WindowCenterTool_error.log`.

## Compatibility Notes (Windows 11 26H2)

- **VBScript removed from the launcher.** Microsoft deprecated VBScript starting with Windows 11 24H2 and is phasing it out of the OS entirely (the Feature on Demand will be disabled by default around 2027 and removed afterwards). The tool no longer uses `wscript.exe` or any `.vbs` file — the hidden launch is done entirely in PowerShell via `ProcessStartInfo` with `CreateNoWindow`, so there is also no window flash at startup.
- **Temp file collision fixed.** The old launcher used the undefined `%PID%` batch variable, so every instance actually shared the same temp name (`CenterWindowTray_.ps1`). Temp files are now named with the real PowerShell process ID (`$PID`), so multiple instances can never collide.
- **No more 2-second race or temp litter.** The extracted `.ps1` deletes itself immediately at startup. The old `.vbs` cleanup waited 2 seconds and could delete the script too early on slow systems, and the `.vbs` file itself was never removed.
- **Clearer failures.** If the `:PS_START` / `:PS_END` markers are missing (e.g., the file was edited incorrectly), the launcher shows a clear message and keeps the console open instead of failing silently. A PowerShell 7 fallback is used automatically if Windows PowerShell 5.1 is not present.
- If SmartScreen blocks a freshly downloaded copy, right-click the `.bat` → Properties → **Unblock**, then run it again.

## Work in Progress

It's still a work in progress, so expect some problems here and there.
