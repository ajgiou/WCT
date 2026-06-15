# Window Centering Tool (WCT)

A lightweight utility batch file for Windows that lets you center the active window with a customizable hotkey. Runs silently in the system tray.

## Features

- Customizable primary and secondary hotkeys (supports `Ctrl`, `Shift`, `Alt` combinations)
- Live hotkey recording via the settings window
- Two centering modes: respect taskbar bounds or ignore it
- System tray icon with context menu (pause, settings, restart as admin, exit)
- Left‑click tray icon to open settings
- Settings window stays on top for easy access
- **Unsaved hotkey changes** – record without applying immediately; explicit Save button
- **Open Config** button – view/edit `WindowCenteringTool.json` directly
- **Restart as Administrator** – elevate the tool when needed (e.g., to center windows of elevated apps)
- Config automatically saved (JSON)
- Fully silent launch (no command prompt flashes)
- Reduced memory footprint (periodic trimming)

## Tested on

- Windows 11 23H2
- Windows 11 25H2

## License

MIT License

## Work in Progress

It's still a work in progress, so expect some problems here and there.
