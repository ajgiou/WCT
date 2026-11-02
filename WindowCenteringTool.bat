@echo off
setlocal EnableExtensions DisableDelayedExpansion

REM =====================================================================
REM  Window Centering Tool - launcher
REM  Compatible with Windows 11 24H2 / 25H2 / 26H2 and later.
REM =====================================================================

REM VBScript (wscript.exe) is deprecated in Windows 11 and is scheduled to
REM be disabled by default around 2027 and removed afterwards, so this
REM launcher no longer creates or runs any .vbs file. It extracts the
REM embedded PowerShell script (between the :PS_START and :PS_END markers)
REM into a uniquely named temp file, then relaunches it in a hidden,
REM console-free PowerShell process. The extracted script deletes its own
REM temp file when it starts, so nothing is left behind in the temp folder.

REM Prefer in-box Windows PowerShell 5.1; fall back to PowerShell 7.
set "WCT_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%WCT_POWERSHELL%" set "WCT_POWERSHELL=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%WCT_POWERSHELL%" (
    echo Windows PowerShell 5.1 or PowerShell 7 is required but was not found.
    pause
    exit /b 1
)

set "me=%~f0"
set "CENTER_WINDOW_BATDIR=%~dp0"
set "CENTER_WINDOW_BATFILE=%me%"
"%WCT_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -Command "$bat = $env:CENTER_WINDOW_BATFILE; if (-not $bat) { Write-Host 'CENTER_WINDOW_BATFILE environment variable is missing.'; exit 1 }; $lines = [System.IO.File]::ReadAllLines($bat); $s = -1; $e = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^:PS_START') { if ($s -lt 0) { $s = $i + 1 } } elseif ($lines[$i] -match '^:PS_END') { if ($e -lt 0) { $e = $i - 1 } } }; if ($s -lt 0 -or $e -lt 0 -or $e -lt $s) { Write-Host 'Could not find the :PS_START / :PS_END markers in this batch file.'; exit 1 }; $ps1 = Join-Path $env:TEMP ('WCT_' + $PID + '.ps1'); Set-Content -LiteralPath $ps1 -Value $lines[($s..$e)] -Encoding UTF8; $q = [char]34; $psi = New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName = $env:WCT_POWERSHELL; $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + $q + $ps1 + $q; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $env:TEMP; [System.Diagnostics.Process]::Start($psi) | Out-Null"
REM The batch file's job is done - the tool now runs in the background.
REM Keep the console open if the launcher reported an error.
if errorlevel 1 pause
exit /b
:PS_START
# =====================================================================
#  Window Centering Tool - embedded PowerShell application (v2.0)
#  Extracted by the launcher above. Structure map:
#    1. Bootstrap   - paths, version, logging, temp-file cleanup
#    2. Config      - defaults, validation, atomic load/save
#    3. Interop     - commented WinAPI P/Invoke + message-only window
#    4. App state   - config instance, message window, pending values
#    5. Centering   - window filtering + centering logic
#    6. Hotkeys     - registration with collision fallback
#    7. Tray        - icon, context menu, memory trimming
#    8. Settings UI - recording, hints, save pipeline (ApplyPending...)
#    9. Lifecycle   - restart-as-admin, idempotent shutdown
#   10. Startup     - message loop inside try/finally + error dump
# =====================================================================

#region Bootstrap: paths, version, logging, temp-file cleanup
# Directory of the launcher .bat (passed in by the launcher via
# CENTER_WINDOW_BATDIR; falls back to this script's own folder).
$configDir = $env:CENTER_WINDOW_BATDIR
if (-not $configDir) { $configDir = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path) }

# Full path of the launcher batch file (needed for "Restart as Administrator").
$script:batFile = $env:CENTER_WINDOW_BATFILE
if (-not $script:batFile) { $script:batFile = "" }

# Script and config versioning: the script version goes into every log
# line, the config version is stored inside the JSON and bumped whenever
# the config layout changes (old files are upgraded automatically).
$script:scriptVersion = "2.0.1"
$script:configVersion = 2

# The extracted copy of this script lives in the user's temp folder and
# deletes itself; $script:selfPath lets us remove it again at shutdown.
$script:selfPath = $MyInvocation.MyCommand.Path

# Warning/error log lives next to the launcher. Assigned BEFORE the main
# try block so even a very early failure can be logged.
$script:errorLogFile = Join-Path $configDir "WindowCenterTool_error.log"

# The config JSON also lives next to the launcher. This MUST be assigned
# before Load-Config runs: v2.0 read $script:configFile while it was still
# $null, which crashed every startup with "Cannot bind argument to parameter
# 'LiteralPath' because it is null".
$script:configFile = Join-Path $configDir "WindowCenteringTool.json"

function Remove-TempScript {
    # Deletes the extracted temp copy of this script. Called once at startup
    # and again from the final cleanup, so a file that was locked by an
    # antivirus scanner the first time gets a second chance.
    try {
        if ($script:selfPath -and (Test-Path -LiteralPath $script:selfPath)) {
            Remove-Item -LiteralPath $script:selfPath -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Write-WctLog {
    # Central logging helper: appends one timestamped, versioned line to the
    # log file. Makes sure the folder exists and rotates the log at ~512 KB
    # so it can never grow without bound. Never throws.
    param([string]$Message, [ValidateSet('Info','Warning','Error')][string]$Level = 'Info')
    try {
        $dir = Split-Path -Parent $script:errorLogFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        if ((Test-Path -LiteralPath $script:errorLogFile) -and ((Get-Item -LiteralPath $script:errorLogFile).Length -gt 512KB)) {
            Move-Item -LiteralPath $script:errorLogFile -Destination ($script:errorLogFile + '.old') -Force -ErrorAction SilentlyContinue
        }
        $line = "[{0}] [{1}] v{2} {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $script:scriptVersion, $Message
        Add-Content -LiteralPath $script:errorLogFile -Value $line -Encoding UTF8
    } catch { }
}

Remove-TempScript

try {
#endregion

#region Config: constants, helpers, validation, load & save
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing

    # WinAPI modifier flags for RegisterHotKey; also used to decode/rebuild
    # the ModifierFlags value from the config and the hotkey recorder.
    $MOD_ALT     = 0x0001
    $MOD_CONTROL = 0x0002
    $MOD_SHIFT   = 0x0004
    $MOD_WIN     = 0x0008

    # Ids passed to Register/UnregisterHotKey for the two hotkey slots.
    $script:hotkeyIds = @{ Primary = 1; Secondary = 2 }

    # Factory defaults; used when the config file is missing or unreadable.
    $script:defaultConfig = [PSCustomObject]@{
        ConfigVersion = $script:configVersion
        Hotkey1       = @{ Modifiers = "Control+Shift"; Key = "C"; ModifierFlags = 6; VirtualKey = 0x43 }  # Ctrl+Shift+C
        Hotkey2       = $null
        CenteringMode = "RespectTaskbar"
    }

    function Copy-HotkeyObject {
        # Detached copy of a hotkey record so pending values can never alias
        # the live config (hashtables are reference types).
        param($hotkey)
        if (-not $hotkey) { return $null }
        return @{
            Modifiers     = $hotkey.Modifiers
            Key           = $hotkey.Key
            ModifierFlags = $hotkey.ModifierFlags
            VirtualKey    = $hotkey.VirtualKey
        }
    }

    function Format-HotkeyString {
        # Single source of truth for displaying a hotkey in the UI and logs.
        param($hotkey)
        if (-not $hotkey) { return "None" }
        $mods = [string]$hotkey.Modifiers
        $key  = [string]$hotkey.Key
        if ([string]::IsNullOrEmpty($mods)) { return $key }
        return "$mods+$key"
    }

    function HotkeysEqual {
        # Two hotkeys are "the same" when their registration-relevant values
        # (modifier flags + virtual key) match; display strings may differ.
        param($a, $b)
        if ($null -eq $a -or $null -eq $b) { return $false }
        try {
            return ([int]$a.VirtualKey -eq [int]$b.VirtualKey) -and ([int]$a.ModifierFlags -eq [int]$b.ModifierFlags)
        } catch { return $false }
    }

    function HotkeysDiffer {
        # Inverse of HotkeysEqual, with explicit handling of $null slots.
        param($a, $b)
        if ($null -eq $a -and $null -eq $b) { return $false }
        if ($null -eq $a -or $null -eq $b)  { return $true }
        return -not (HotkeysEqual $a $b)
    }

    function Test-Hotkey {
        # Structural validation: a hotkey record must expose ModifierFlags and
        # VirtualKey, both convertible to integers, in a sane range.
        # $null is NOT considered valid here - callers decide per slot whether
        # "no hotkey" is allowed (Hotkey2) or not.
        param($hk)
        if ($null -eq $hk) { return $false }
        $flagsRaw = $null; $vkRaw = $null
        if ($hk -is [hashtable]) { $flagsRaw = $hk['ModifierFlags']; $vkRaw = $hk['VirtualKey'] }
        else                     { $flagsRaw = $hk.ModifierFlags;  $vkRaw = $hk.VirtualKey }
        if ($null -eq $flagsRaw -or $null -eq $vkRaw) { return $false }
        try { $flags = [int]$flagsRaw; $vk = [int]$vkRaw } catch { return $false }
        if ($flags -lt 0 -or $flags -gt 15) { return $false }   # ALT|CONTROL|SHIFT|WIN = 0x0F
        if ($vk -lt 1 -or $vk -gt 254)      { return $false }   # sane virtual-key range
        return $true
    }

    function ConvertTo-NormalizedHotkey {
        # Turns whatever the JSON contained into a canonical hotkey record,
        # or $null (with a logged warning) if the value is unusable.
        param($hk, [string]$Label)
        if ($null -eq $hk) { return $null }
        if (-not (Test-Hotkey $hk)) {
            Write-WctLog "$Label has an invalid structure or values; it was reset." 'Warning'
            return $null
        }
        $flags = [int]$hk.ModifierFlags
        $vk    = [int]$hk.VirtualKey

        # A hotkey without any modifier is only accepted for function keys
        # F1-F24 (0x70-0x87); anything else would make the bare key unusable
        # system-wide while the tool runs.
        if ($flags -eq 0 -and ($vk -lt 0x70 -or $vk -gt 0x87)) {
            Write-WctLog "$Label has no modifier and is not a function key; it was reset." 'Warning'
            return $null
        }

        # Rebuild the display string from the flags so hand-edited config
        # values and recorder values always look (and sort) the same.
        $parts = @()
        if ($flags -band $MOD_CONTROL) { $parts += 'Control' }
        if ($flags -band $MOD_SHIFT)   { $parts += 'Shift' }
        if ($flags -band $MOD_ALT)     { $parts += 'Alt' }
        if ($flags -band $MOD_WIN)     { $parts += 'Win' }

        $key = [string]$hk.Key
        if (-not $key) { $key = ('0x{0:X2}' -f $vk) }   # fallback display for exotic keys

        return @{
            Modifiers     = ($parts -join '+')
            Key           = $key
            ModifierFlags = $flags
            VirtualKey    = $vk
        }
    }

    function Normalize-Config {
        # Repairs a loaded config field by field, keeping everything that is
        # still valid ("preserve user settings"). Always returns a canonical
        # object that carries the current ConfigVersion.
        param($cfg)

        $hk1 = ConvertTo-NormalizedHotkey $cfg.Hotkey1 'Hotkey1 (primary)'
        $hk2 = ConvertTo-NormalizedHotkey $cfg.Hotkey2 'Hotkey2 (secondary)'

        # Never allow primary and secondary to be the same combination.
        if ($hk1 -and $hk2 -and (HotkeysEqual $hk1 $hk2)) {
            Write-Warning "Primary and secondary hotkeys are identical; keeping only the primary."
            Write-WctLog "Primary and secondary hotkeys are identical; keeping only the primary." 'Warning'
            $hk2 = $null
        }

        # CenteringMode must be one of the two known values. switch is
        # case-insensitive, so hand-edited spellings still normalize cleanly.
        $mode = switch ([string]$cfg.CenteringMode) {
            'RespectTaskbar' { 'RespectTaskbar' }
            'IgnoreTaskbar'  { 'IgnoreTaskbar' }
            default {
                Write-WctLog "Unknown CenteringMode '$($cfg.CenteringMode)'; resetting to '$($script:defaultConfig.CenteringMode)'." 'Warning'
                [string]$script:defaultConfig.CenteringMode
            }
        }

        return [PSCustomObject]@{
            ConfigVersion = $script:configVersion
            Hotkey1       = $hk1
            Hotkey2       = $hk2
            CenteringMode = $mode
        }
    }

    function Load-Config {
        # Loads the JSON config, falls back to defaults for unreadable files
        # (the broken file is kept as *.bad for inspection) and normalizes
        # every field. The normalized result is written back right away so
        # repairs and the ConfigVersion field persist.
        if (-not $script:configFile) {
            # Defensive fallback: the path is assigned during bootstrap. If a
            # future edit ever calls this function earlier than that, derive
            # the path here instead of crashing on Test-Path -LiteralPath $null.
            $dir = $env:CENTER_WINDOW_BATDIR
            if (-not $dir) { $dir = $PSScriptRoot }
            $script:configFile = Join-Path $dir "WindowCenteringTool.json"
        }
        $loaded = $null
        if (Test-Path -LiteralPath $script:configFile) {
            try {
                $loaded = Get-Content -LiteralPath $script:configFile -Raw | ConvertFrom-Json
            } catch {
                Write-WctLog "Config file is corrupted JSON; using defaults. Original kept as '$($script:configFile).bad'. ($($_.Exception.Message))" 'Warning'
                try { Move-Item -LiteralPath $script:configFile -Destination ($script:configFile + '.bad') -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
        if (-not $loaded) { $loaded = $script:defaultConfig }
        $cfg = Normalize-Config $loaded
        Save-Config $cfg
        return $cfg
    }

    function Save-Config {
        # Writes the config atomically: JSON goes to a temp file first and is
        # then moved over the real file, so a crash mid-write can never leave
        # a half-written (corrupt) config behind.
        param($config)
        try {
            $json = $config | ConvertTo-Json -Depth 4
            $tmp  = ($script:configFile + '.tmp')
            Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
            Move-Item -LiteralPath $tmp -Destination $script:configFile -Force
        } catch {
            Write-WctLog "Could not save config: $($_.Exception.Message)" 'Error'
        }
    }
#endregion

#region Native interop (WinAPI P/Invoke + message-only window)
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

// Thin P/Invoke layer. Every import used by the PowerShell side is commented.
public class WinAPI
{
    // ------------------------------------------------------------ geometry
    // Handle of the window the user is currently working with.
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    // Screen-coordinate rectangle of a window.
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    // Monitor a window is (mostly) displayed on.
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint dwFlags);
    // Fills in full + work-area (taskbar-aware) bounds of a monitor.
    [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);
    // Preferred move call (flags allow position-only changes).
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    // Fallback move if SetWindowPos fails for some window.
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);

    // -------------------------------------------------------- window state
    // Is the window maximized? (maximized windows already fill the screen)
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
    // Is the window minimized? (minimized windows must never be moved)
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    // Is the window visible at all?
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    // Walks up the owner chain to the root window.
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint gaFlags);
    // Reads style bits; with GWL_EXSTYLE used to detect tool windows.
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    // Window class name (used to skip shell/taskbar/overlay windows).
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    // Desktop Window Manager: detects "cloaked" (hidden but alive) windows,
    // e.g. UWP hosts, the Start menu host, suspended overlays.
    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hWnd, int dwAttribute, out int pvAttribute, int cbAttribute);

    // ------------------------------------------------------- global hotkeys
    // Registers a system-wide hotkey bound to our message-only window.
    // Returns false when the combination is already used by another program.
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    // Releases a previously registered hotkey id.
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    // -------------------------------------------------------------- cleanup
    // Destroys the icon handle created by GetHicon() (prevents a GDI leak).
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
    // Releases unused memory pages (periodic working-set trimming).
    [DllImport("kernel32.dll")] public static extern bool SetProcessWorkingSetSize(IntPtr hProcess, int dwMinimumWorkingSetSize, int dwMaximumWorkingSetSize);
    // Pseudo process handle for SetProcessWorkingSetSize.
    [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
    // Detaches the console the launcher spawned (nothing flashes on screen).
    [DllImport("kernel32.dll")] public static extern bool FreeConsole();

    // ------------------------------------------------------------ constants
    public const uint MONITOR_DEFAULTTONEAREST = 2;   // MonitorFromWindow flag
    public const uint SWP_NOSIZE       = 0x0001;      // keep current size
    public const uint SWP_NOZORDER     = 0x0004;      // keep current z-order
    public const uint SWP_NOACTIVATE   = 0x0010;      // do not steal focus
    public const uint GA_ROOT          = 2;           // GetAncestor: root window
    public const int  GWL_EXSTYLE      = -20;         // extended style index
    public const uint WS_EX_TOOLWINDOW = 0x00000080;  // tool/palette window style
    public const int  DWMWA_CLOAKED    = 14;          // DWM attribute: cloaked state

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;  // full monitor bounds
        public RECT rcWork;     // bounds minus taskbar
        public uint dwFlags;
    }

    // Special parent that creates an invisible message-only window.
    public static readonly IntPtr HWND_MESSAGE = new IntPtr(-3);
}

// Hidden message-only window that receives WM_HOTKEY for our registered
// global hotkeys. It is never shown and has no taskbar presence.
public class MessageOnlyWindow : NativeWindow
{
    public event Action HotkeyPressed;
    public const int WM_HOTKEY = 0x0312;

    public MessageOnlyWindow()
    {
        CreateHandle(new CreateParams { Parent = WinAPI.HWND_MESSAGE });
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY)   // one of our hotkeys was pressed
        {
            if (HotkeyPressed != null) HotkeyPressed();
            return;
        }
        base.WndProc(ref m);
    }
}
"@ -ReferencedAssemblies System.Windows.Forms
#endregion

#region App state
    [WinAPI]::FreeConsole() | Out-Null   # hide the launcher's console

    $script:config = Load-Config          # validated + normalized + persisted

    # Hotkey objects that are ACTUALLY registered right now. May differ from
    # the config after a collision fallback - the config stays untouched in
    # that case so a later retry (e.g. after un-pausing) can pick it up.
    $script:activeHotkeys = @{ Primary = $null; Secondary = $null }

    $script:paused        = $false
    $script:shuttingDown  = $false

    # Hidden receiver for WM_HOTKEY messages.
    $script:msgWindow = New-Object MessageOnlyWindow
    $script:msgWindow.add_HotkeyPressed({ Center-ActiveWindow })

    # Settings window state (created lazily on first use).
    $script:settingsForm = $null
    $script:txtHK1       = $null
    $script:txtHK2       = $null
    $script:btnSave      = $null
    $script:lblStatus    = $null
    $script:pendingHK1   = Copy-HotkeyObject $script:config.Hotkey1
    $script:pendingHK2   = Copy-HotkeyObject $script:config.Hotkey2
    $script:pendingMode  = $script:config.CenteringMode

    # Icon handle bookkeeping for the final DestroyIcon cleanup.
    $script:iconHandle = [IntPtr]::Zero

    # Window classes that must never be centered (shell, taskbar, overlays).
    $script:skipWindowClasses = @(
        'Shell_TrayWnd',                       # main taskbar
        'Shell_SecondaryTrayWnd',              # additional taskbars
        'Progman', 'WorkerW',                  # desktop / wallpaper hosts
        'Windows.UI.Core.CoreWindow',          # Start menu / search / touch keyboard
        'XamlExplorerHostIslandWindow',        # Win11 Start / Task View host
        'NotifyIconOverflowWindow',            # tray overflow flyout
        'TopLevelWindowForOverflowXamlIsland'  # Win11 tray overflow flyout
    )
#endregion

#region Centering logic
    function Get-WindowClassName {
        # Helper around GetClassName - returns e.g. "Shell_TrayWnd".
        param([IntPtr]$hWnd)
        try {
            $sb = New-Object System.Text.StringBuilder 256
            [WinAPI]::GetClassName($hWnd, $sb, 256) | Out-Null
            return $sb.ToString()
        } catch { return '' }
    }

    function Test-CloakedWindow {
        # True for windows the DWM hides but keeps alive (UWP hosts, the
        # Start menu, suspended overlays). Moving those would teleport
        # invisible windows, so we skip them.
        param([IntPtr]$hWnd)
        try {
            $cloaked = [int]0
            $hr = [WinAPI]::DwmGetWindowAttribute($hWnd, [WinAPI]::DWMWA_CLOAKED, [ref]$cloaked, 4)
            return ($hr -eq 0 -and $cloaked -ne 0)
        } catch { return $false }
    }

    function Center-ActiveWindow {
        # Centers the foreground window on its monitor. Windows that should
        # never be moved by a utility are filtered out first: minimized,
        # hidden, cloaked, shell/taskbar, tool/notification and maximized
        # windows.
        $hwndFore = [WinAPI]::GetForegroundWindow()
        if ($hwndFore -eq [IntPtr]::Zero) { return }

        # The foreground handle may point at a child control - use the root.
        $hwnd = [WinAPI]::GetAncestor($hwndFore, [WinAPI]::GA_ROOT)
        if ($hwnd -eq [IntPtr]::Zero) { return }

        # ---- skip windows we have no business moving -----------------------
        if ([WinAPI]::IsIconic($hwnd)) { return }                          # minimized
        if (-not [WinAPI]::IsWindowVisible($hwnd)) { return }              # not visible
        if (Test-CloakedWindow $hwnd) { return }                           # DWM-cloaked overlay
        if ($script:skipWindowClasses -contains (Get-WindowClassName $hwnd)) { return }  # shell/taskbar
        if (([WinAPI]::GetWindowLong($hwnd, [WinAPI]::GWL_EXSTYLE) -band [WinAPI]::WS_EX_TOOLWINDOW) -ne 0) {
            return                                                         # tool/notification windows
        }

        # Maximized windows already span their monitor - nothing to center.
        if ([WinAPI]::IsZoomed($hwnd)) { return }

        $rect = New-Object WinAPI+RECT
        if (-not [WinAPI]::GetWindowRect($hwnd, [ref]$rect)) { return }

        $wWidth  = $rect.Right  - $rect.Left
        $wHeight = $rect.Bottom - $rect.Top
        if ($wWidth -le 0 -or $wHeight -le 0) { return }

        $hMonitor = [WinAPI]::MonitorFromWindow($hwnd, [WinAPI]::MONITOR_DEFAULTTONEAREST)
        $monInfo = New-Object WinAPI+MONITORINFO
        $monInfo.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($monInfo)
        if (-not [WinAPI]::GetMonitorInfo($hMonitor, [ref]$monInfo)) { return }

        # Pick the reference bounds once, depending on the configured mode.
        switch ($script:config.CenteringMode) {
            'IgnoreTaskbar' { $bounds = $monInfo.rcMonitor }   # full monitor
            default         { $bounds = $monInfo.rcWork }      # RespectTaskbar + safe fallback
        }

        # Already covering the whole area? Leave it alone.
        if (($rect.Left  -le $bounds.Left)  -and ($rect.Top    -le $bounds.Top) -and
            ($rect.Right -ge $bounds.Right) -and ($rect.Bottom -ge $bounds.Bottom)) {
            return
        }

        $newX = $bounds.Left + [Math]::Floor(($bounds.Right - $bounds.Left - $wWidth) / 2)
        $newY = $bounds.Top  + [Math]::Floor(($bounds.Bottom - $bounds.Top - $wHeight) / 2)

        # Clamp into the chosen bounds (defensive; odd DPI scaling or windows
        # larger than the work area could otherwise drift out of range).
        $newX = [Math]::Max($bounds.Left, $newX)
        $newY = [Math]::Max($bounds.Top,  $newY)
        $maxX = $bounds.Right  - $wWidth
        $maxY = $bounds.Bottom - $wHeight
        if ($newX -gt $maxX) { $newX = $maxX }
        if ($newY -gt $maxY) { $newY = $maxY }
        if ($newX -lt $bounds.Left) { $newX = $bounds.Left }
        if ($newY -lt $bounds.Top)  { $newY = $bounds.Top }

        $result = [WinAPI]::SetWindowPos($hwnd, [IntPtr]::Zero, $newX, $newY, 0, 0,
            [WinAPI]::SWP_NOSIZE -bor [WinAPI]::SWP_NOZORDER -bor [WinAPI]::SWP_NOACTIVATE)
        if (-not $result) {
            # SetWindowPos can fail on some windows; MoveWindow is the hammer.
            [WinAPI]::MoveWindow($hwnd, $newX, $newY, $wWidth, $wHeight, $true) | Out-Null
        }
    }
#endregion

#region Hotkey registration (with collision fallback)
    function Register-Hotkey {
        # Thin wrapper so every registration attempt looks the same and any
        # exception (e.g. bad values) turns into a plain $false.
        param($Hotkey, [int]$Id)
        try {
            return [WinAPI]::RegisterHotKey($script:msgWindow.Handle, $Id,
                [uint32]$Hotkey.ModifierFlags, [uint32]$Hotkey.VirtualKey)
        } catch { return $false }
    }

    function Show-HotkeyBalloon {
        # Warns the user about registration problems via a tray balloon and
        # writes the same information into the log file.
        param([string]$Title, [string]$Text)
        Write-WctLog "$Title - $Text" 'Warning'
        if (-not $script:notifyIcon) { return }
        try {
            $script:notifyIcon.BalloonTipTitle = $Title
            $script:notifyIcon.BalloonTipText  = $Text
            $script:notifyIcon.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::Warning
            $script:notifyIcon.ShowBalloonTip(5000)
        } catch { }
    }

    function Update-HotkeyRegistration {
        # Re-registers all configured hotkeys. If a hotkey cannot be
        # registered (typically because another application already uses it),
        # the previously working hotkey - if any - is restored instead of
        # leaving the tool half-configured, and the user is warned via tray
        # balloon + log. This used to be silent, especially for Hotkey2.
        $hwnd = $script:msgWindow.Handle

        $previous = @{
            Primary   = $script:activeHotkeys.Primary
            Secondary = $script:activeHotkeys.Secondary
        }

        # Unregister both ids first so re-registration always starts clean.
        [WinAPI]::UnregisterHotKey($hwnd, $script:hotkeyIds.Primary)   | Out-Null
        [WinAPI]::UnregisterHotKey($hwnd, $script:hotkeyIds.Secondary) | Out-Null
        $script:activeHotkeys = @{ Primary = $null; Secondary = $null }

        if ($script:paused) { return }

        $configChanged = $false

        # ---- primary hotkey -------------------------------------------------
        $hk = $script:config.Hotkey1
        if ($hk) {
            if (Register-Hotkey -Hotkey $hk -Id $script:hotkeyIds.Primary) {
                $script:activeHotkeys.Primary = $hk
            } else {
                $newName  = Format-HotkeyString $hk
                $fallback = $previous.Primary
                Write-WctLog "Primary hotkey '$newName' could not be registered (probably in use by another program)." 'Warning'
                if ($fallback -and -not (HotkeysEqual $fallback $hk) -and (Register-Hotkey -Hotkey $fallback -Id $script:hotkeyIds.Primary)) {
                    # Restore the previously working primary hotkey.
                    $script:config.Hotkey1         = $fallback
                    $script:activeHotkeys.Primary  = $fallback
                    $configChanged                 = $true
                    Show-HotkeyBalloon "Primary hotkey already in use" ("'$newName' could not be registered - kept '$(Format-HotkeyString $fallback)' instead.")
                } else {
                    # Nothing to fall back to: keep the setting so a later
                    # retry (e.g. after un-pausing) can pick it up, but tell
                    # the user loudly instead of failing silently.
                    Show-HotkeyBalloon "Primary hotkey already in use" ("'$newName' could not be registered. The hotkey stays unassigned for now.")
                }
            }
        }

        # ---- secondary hotkey (same treatment as primary now) ---------------
        $hk = $script:config.Hotkey2
        if ($hk) {
            if (Register-Hotkey -Hotkey $hk -Id $script:hotkeyIds.Secondary) {
                $script:activeHotkeys.Secondary = $hk
            } else {
                $newName  = Format-HotkeyString $hk
                $fallback = $previous.Secondary
                Write-WctLog "Secondary hotkey '$newName' could not be registered (probably in use by another program)." 'Warning'
                if ($fallback -and -not (HotkeysEqual $fallback $hk) -and (Register-Hotkey -Hotkey $fallback -Id $script:hotkeyIds.Secondary)) {
                    # Restore the previously working secondary hotkey.
                    $script:config.Hotkey2            = $fallback
                    $script:activeHotkeys.Secondary   = $fallback
                    $configChanged                    = $true
                    Show-HotkeyBalloon "Secondary hotkey already in use" ("'$newName' could not be registered - kept '$(Format-HotkeyString $fallback)' instead.")
                } else {
                    Show-HotkeyBalloon "Secondary hotkey already in use" ("'$newName' could not be registered. The hotkey stays unassigned for now.")
                }
            }
        }

        if ($configChanged) {
            # Persist the repaired config and mirror it into the pending
            # values so the settings window (if open) shows what is active.
            Save-Config $script:config
            $script:pendingHK1 = Copy-HotkeyObject $script:config.Hotkey1
            $script:pendingHK2 = Copy-HotkeyObject $script:config.Hotkey2
            if ($script:settingsForm) {
                if ($script:txtHK1) { $script:txtHK1.Text = Format-HotkeyString $script:pendingHK1 }
                if ($script:txtHK2) { $script:txtHK2.Text = Format-HotkeyString $script:pendingHK2 }
                Update-SettingsUiState
            }
        }

        Write-WctLog ("Hotkeys after registration: Primary='{0}' (ok: {1}) | Secondary='{2}' (ok: {3}) | Paused: {4} | Mode: {5}" -f (Format-HotkeyString $script:config.Hotkey1), [bool]$script:activeHotkeys.Primary, (Format-HotkeyString $script:config.Hotkey2), [bool]$script:activeHotkeys.Secondary, $script:paused, $script:config.CenteringMode) 'Info'
    }
#endregion

#region Tray (icon / menu / events)
    # Draw a simple 16x16 icon in memory (dark disc, blue dot) - no .ico file
    # needed. Graphics and bitmap are disposed right away; the icon handle is
    # destroyed again in Stop-Application to avoid a GDI leak.
    $global:iconBitmap = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($global:iconBitmap)
    $g.Clear([System.Drawing.Color]::FromArgb(45,45,45))
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::DodgerBlue)
    $g.FillEllipse($brush, 1, 1, 14, 14)
    $brush.Dispose()
    $g.Dispose()
    $script:iconHandle = $global:iconBitmap.GetHicon()
    $script:icon = [System.Drawing.Icon]::FromHandle($script:iconHandle)
    $global:iconBitmap.Dispose()   # icon keeps its own copy; bitmap no longer needed

    $script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:notifyIcon.Text = "Window Centering Tool"
    $script:notifyIcon.Icon = $script:icon
    $script:notifyIcon.Visible = $true

    $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $script:menuSettings = New-Object System.Windows.Forms.ToolStripMenuItem -Property @{Text = "Settings"}
    $script:menuPause    = New-Object System.Windows.Forms.ToolStripMenuItem -Property @{Text = "Pause Hotkey"; CheckOnClick = $true}
    $script:menuRestart  = New-Object System.Windows.Forms.ToolStripMenuItem -Property @{Text = "Restart as Administrator"}
    $script:menuExit     = New-Object System.Windows.Forms.ToolStripMenuItem -Property @{Text = "Exit"}
    $contextMenu.Items.AddRange(@($script:menuSettings, $script:menuPause, $script:menuRestart, $script:menuExit))
    $script:notifyIcon.ContextMenuStrip = $contextMenu

    # Left-click opens settings; menu items route to their handlers.
    $script:notifyIcon.Add_Click({
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-SettingsWindow }
    })
    $script:menuSettings.Add_Click({ Show-SettingsWindow })
    $script:menuPause.Add_Click({
        $script:paused = $script:menuPause.Checked
        Write-WctLog "Hotkeys paused: $($script:paused)" 'Info'
        Update-HotkeyRegistration
    })
    $script:menuRestart.Add_Click({ Restart-AsAdmin })
    $script:menuExit.Add_Click({ Stop-Application })

    # Periodic working-set trim keeps the resident memory footprint small.
    $script:trimTimer = New-Object System.Windows.Forms.Timer
    $script:trimTimer.Interval = 300000   # 5 minutes
    $script:trimTimer.Add_Tick({
        [WinAPI]::SetProcessWorkingSetSize([WinAPI]::GetCurrentProcess(), -1, -1) | Out-Null
    })
    $script:trimTimer.Start()
#endregion

#region Settings UI - helpers and the save pipeline
    function Get-HotkeyFromKeyArgs {
        # Converts a KeyEventArgs from a recording textbox into a hotkey
        # record. Returns $null for keys that cannot form a usable hotkey:
        # pure modifier keys (Shift/Ctrl/Alt) and the Windows key (its state
        # is not exposed by WinForms KeyEvents, so it cannot be recorded).
        param($e)
        $mods = 0
        if ($e.Control) { $mods = $mods -bor $MOD_CONTROL }
        if ($e.Shift)   { $mods = $mods -bor $MOD_SHIFT }
        if ($e.Alt)     { $mods = $mods -bor $MOD_ALT }
        $keyCode = [int]$e.KeyCode
        if ($keyCode -in 0x10, 0x11, 0x12, 0x5B, 0x5C) { return $null }  # Shift/Ctrl/Alt/LWin/RWin alone

        $modStr = ""
        if ($e.Control) { $modStr += "Control+" }
        if ($e.Shift)   { $modStr += "Shift+" }
        if ($e.Alt)     { $modStr += "Alt+" }
        $modifiersOnly = $modStr.TrimEnd('+')
        $display = if ($modifiersOnly.Length -gt 0) { "$modifiersOnly+$($e.KeyCode)" } else { $e.KeyCode.ToString() }
        return @{
            Display       = $display
            Modifiers     = $modifiersOnly
            Key           = $e.KeyCode.ToString()
            ModifierFlags = $mods
            VirtualKey    = $keyCode
        }
    }

    function Test-PendingHotkeyValid {
        # A pending hotkey is savable when it is $null (cleared) or a valid
        # combination that is not a duplicate of the other slot and carries
        # at least one modifier (function keys F1-F24 are the exception).
        param($hk, $other)
        if ($null -eq $hk) { return $true }
        if (-not (Test-Hotkey $hk)) { return $false }
        $flags = [int]$hk.ModifierFlags
        $vk    = [int]$hk.VirtualKey
        if ($flags -eq 0 -and ($vk -lt 0x70 -or $vk -gt 0x87)) { return $false }  # needs a modifier
        if ($other -and (HotkeysEqual $hk $other)) { return $false }              # duplicate
        return $true
    }

    function Get-PendingChangesExist {
        # One definition of "the user changed something but has not saved it".
        return (HotkeysDiffer $script:pendingHK1 $script:config.Hotkey1) -or
               (HotkeysDiffer $script:pendingHK2 $script:config.Hotkey2) -or
               ($script:pendingMode -ne $script:config.CenteringMode)
    }

    function Update-SettingsUiState {
        # Keeps the Save button, the hint label and the textbox colours in
        # sync with the pending values. Called after every change in the
        # settings window. Guards make it safe to call during form building.
        if (-not $script:btnSave) { return }

        $valid1 = Test-PendingHotkeyValid $script:pendingHK1 $script:pendingHK2
        $valid2 = Test-PendingHotkeyValid $script:pendingHK2 $script:pendingHK1
        $script:btnSave.Enabled = ((Get-PendingChangesExist) -and $valid1 -and $valid2)

        $errorColor = [System.Drawing.Color]::FromArgb(255, 128, 64)
        $hintColor  = [System.Drawing.Color]::FromArgb(150, 150, 150)

        if (-not ($valid1 -and $valid2)) {
            if ($script:pendingHK1 -and $script:pendingHK2 -and (HotkeysEqual $script:pendingHK1 $script:pendingHK2)) {
                $script:lblStatus.Text = "Primary and secondary hotkeys are identical - please record two different combinations."
            } else {
                $script:lblStatus.Text = "Invalid combination: modifier keys alone or a plain key without Ctrl/Alt/Shift cannot be used (F1-F24 without modifiers are allowed)."
            }
            $script:lblStatus.ForeColor = $errorColor
            foreach ($tb in @($script:txtHK1, $script:txtHK2)) {
                if ($tb) { $tb.BackColor = $errorColor; $tb.ForeColor = [System.Drawing.Color]::FromArgb(20, 20, 20) }
            }
        } else {
            $script:lblStatus.Text = "Tip: press Ctrl/Alt/Shift plus a key to record (e.g. Ctrl+Shift+C). Modifier keys on their own are not valid. Esc cancels a recording."
            $script:lblStatus.ForeColor = $hintColor
            foreach ($tb in @($script:txtHK1, $script:txtHK2)) {
                if ($tb) { $tb.BackColor = $script:darkBoxBack; $tb.ForeColor = $script:darkFore }
            }
        }
    }

    function Reset-SettingsFields {
        # Rebuilds pending values + visible fields from the live config
        # (used on open and to discard unsaved changes).
        $script:pendingHK1  = Copy-HotkeyObject $script:config.Hotkey1
        $script:pendingHK2  = Copy-HotkeyObject $script:config.Hotkey2
        $script:pendingMode = $script:config.CenteringMode
        if ($script:txtHK1) { $script:txtHK1.Text = Format-HotkeyString $script:pendingHK1 }
        if ($script:txtHK2) { $script:txtHK2.Text = Format-HotkeyString $script:pendingHK2 }
        if ($script:radRespect -and $script:radIgnore) {
            $script:radRespect.Checked = ($script:pendingMode -eq "RespectTaskbar")
            $script:radIgnore.Checked  = ($script:pendingMode -eq "IgnoreTaskbar")
        }
        Update-SettingsUiState
    }

    function SaveConfigAndRefreshHotkeys {
        # THE one place that knows how to persist + apply configuration:
        # save to disk, re-register hotkeys, resync pending values and the
        # settings UI. Called everywhere a save happens.
        Save-Config $script:config
        Update-HotkeyRegistration
        $script:pendingHK1 = Copy-HotkeyObject $script:config.Hotkey1
        $script:pendingHK2 = Copy-HotkeyObject $script:config.Hotkey2
        if ($script:settingsForm) {
            if ($script:txtHK1) { $script:txtHK1.Text = Format-HotkeyString $script:pendingHK1 }
            if ($script:txtHK2) { $script:txtHK2.Text = Format-HotkeyString $script:pendingHK2 }
        }
        Update-SettingsUiState
    }

    function ApplyPendingSettings {
        # THE one place that applies the pending settings-window values to
        # the live config. Used by the Save button AND by "save on close",
        # so the save logic is no longer duplicated.
        $script:config.Hotkey1 = if ($script:pendingHK1) { Copy-HotkeyObject $script:pendingHK1 } else { $null }
        $script:config.Hotkey2 = if ($script:pendingHK2) { Copy-HotkeyObject $script:pendingHK2 } else { $null }
        $script:config.CenteringMode = $script:pendingMode
        # Normalize as a safety net (rejects duplicates / invalid values that
        # somehow slipped past the UI checks).
        $script:config = Normalize-Config $script:config
        SaveConfigAndRefreshHotkeys
    }
#endregion

#region Settings UI - the window
    function Show-SettingsWindow {
        # Opens (or brings to front) the settings window. The form object is
        # reused; pending values are always rebuilt from the live config.
        if ($script:settingsForm -and $script:settingsForm.Visible) {
            $script:settingsForm.BringToFront()
            return
        }
        if ($script:settingsForm) {
            Reset-SettingsFields
            $script:settingsForm.TopMost = $true
            $script:settingsForm.Show()
            $script:settingsForm.BringToFront()
            return
        }

        # Shared dark-theme colors (script scope: helper functions need them).
        $script:darkBack    = [System.Drawing.Color]::FromArgb(30, 30, 30)
        $script:darkFore    = [System.Drawing.Color]::FromArgb(220, 220, 220)
        $script:darkBtnBack = [System.Drawing.Color]::FromArgb(60, 60, 60)
        $script:darkBoxBack = [System.Drawing.Color]::FromArgb(45, 45, 45)

        $script:settingsForm = New-Object System.Windows.Forms.Form
        $script:settingsForm.Text = "Window Centering Settings"
        $script:settingsForm.Size = New-Object System.Drawing.Size(390, 290)
        $script:settingsForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $script:settingsForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $script:settingsForm.MaximizeBox = $false
        $script:settingsForm.MinimizeBox = $false
        $script:settingsForm.TopMost = $true
        $script:settingsForm.BackColor = $script:darkBack
        $script:settingsForm.ForeColor = $script:darkFore

        Reset-SettingsFields   # seed pending values from the live config

        # ---- primary hotkey row --------------------------------------------
        $lblHK1 = New-Object System.Windows.Forms.Label
        $lblHK1.Text = "Primary Hotkey:"
        $lblHK1.Location = New-Object System.Drawing.Point(12, 18)
        $lblHK1.Size = New-Object System.Drawing.Size(105, 20)
        $lblHK1.ForeColor = $script:darkFore

        $script:txtHK1 = New-Object System.Windows.Forms.TextBox
        $script:txtHK1.Location = New-Object System.Drawing.Point(120, 15)
        $script:txtHK1.Size = New-Object System.Drawing.Size(110, 23)
        $script:txtHK1.ReadOnly = $true
        $script:txtHK1.BackColor = $script:darkBoxBack
        $script:txtHK1.ForeColor = $script:darkFore
        $script:txtHK1.Text = Format-HotkeyString $script:pendingHK1

        $btnRecordHK1 = New-Object System.Windows.Forms.Button
        $btnRecordHK1.Text = "Record"
        $btnRecordHK1.Location = New-Object System.Drawing.Point(235, 14)
        $btnRecordHK1.Size = New-Object System.Drawing.Size(62, 25)
        $btnRecordHK1.BackColor = $script:darkBtnBack
        $btnRecordHK1.ForeColor = $script:darkFore
        $btnRecordHK1.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnRecordHK1.Add_Click({
            $script:txtHK1.Text = "Press keys..."
            $script:txtHK1.Focus()
        })

        # Clear button for the PRIMARY hotkey (used to be HK2-only).
        $btnClearHK1 = New-Object System.Windows.Forms.Button
        $btnClearHK1.Text = "Clear"
        $btnClearHK1.Location = New-Object System.Drawing.Point(302, 14)
        $btnClearHK1.Size = New-Object System.Drawing.Size(62, 25)
        $btnClearHK1.BackColor = $script:darkBtnBack
        $btnClearHK1.ForeColor = $script:darkFore
        $btnClearHK1.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnClearHK1.Add_Click({
            $script:pendingHK1 = $null
            $script:txtHK1.Text = "None"
            Update-SettingsUiState
        })

        # ---- secondary hotkey row ------------------------------------------
        $lblHK2 = New-Object System.Windows.Forms.Label
        $lblHK2.Text = "Secondary Hotkey:"
        $lblHK2.Location = New-Object System.Drawing.Point(12, 63)
        $lblHK2.Size = New-Object System.Drawing.Size(105, 20)
        $lblHK2.ForeColor = $script:darkFore

        $script:txtHK2 = New-Object System.Windows.Forms.TextBox
        $script:txtHK2.Location = New-Object System.Drawing.Point(120, 60)
        $script:txtHK2.Size = New-Object System.Drawing.Size(110, 23)
        $script:txtHK2.ReadOnly = $true
        $script:txtHK2.BackColor = $script:darkBoxBack
        $script:txtHK2.ForeColor = $script:darkFore
        $script:txtHK2.Text = Format-HotkeyString $script:pendingHK2

        $btnRecordHK2 = New-Object System.Windows.Forms.Button
        $btnRecordHK2.Text = "Record"
        $btnRecordHK2.Location = New-Object System.Drawing.Point(235, 59)
        $btnRecordHK2.Size = New-Object System.Drawing.Size(62, 25)
        $btnRecordHK2.BackColor = $script:darkBtnBack
        $btnRecordHK2.ForeColor = $script:darkFore
        $btnRecordHK2.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnRecordHK2.Add_Click({
            $script:txtHK2.Text = "Press keys..."
            $script:txtHK2.Focus()
        })

        $btnClearHK2 = New-Object System.Windows.Forms.Button
        $btnClearHK2.Text = "Clear"
        $btnClearHK2.Location = New-Object System.Drawing.Point(302, 59)
        $btnClearHK2.Size = New-Object System.Drawing.Size(62, 25)
        $btnClearHK2.BackColor = $script:darkBtnBack
        $btnClearHK2.ForeColor = $script:darkFore
        $btnClearHK2.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnClearHK2.Add_Click({
            $script:pendingHK2 = $null
            $script:txtHK2.Text = "None"
            Update-SettingsUiState
        })

        # ---- centering mode group ------------------------------------------
        $grpMode = New-Object System.Windows.Forms.GroupBox
        $grpMode.Text = "Centering Mode"
        $grpMode.Location = New-Object System.Drawing.Point(12, 95)
        $grpMode.Size = New-Object System.Drawing.Size(342, 55)
        $grpMode.ForeColor = $script:darkFore

        $script:radRespect = New-Object System.Windows.Forms.RadioButton
        $script:radRespect.Text = "Respect taskbar"
        $script:radRespect.Location = New-Object System.Drawing.Point(15, 22)
        $script:radRespect.Size = New-Object System.Drawing.Size(150, 20)
        $script:radRespect.ForeColor = $script:darkFore
        $script:radRespect.Checked = ($script:pendingMode -eq "RespectTaskbar")

        $script:radIgnore = New-Object System.Windows.Forms.RadioButton
        $script:radIgnore.Text = "Ignore taskbar"
        $script:radIgnore.Location = New-Object System.Drawing.Point(172, 22)
        $script:radIgnore.Size = New-Object System.Drawing.Size(150, 20)
        $script:radIgnore.ForeColor = $script:darkFore
        $script:radIgnore.Checked = ($script:pendingMode -eq "IgnoreTaskbar")

        $grpMode.Controls.AddRange(@($script:radRespect, $script:radIgnore))

        # Radio buttons update the pending mode only (no immediate save).
        $script:radRespect.Add_CheckedChanged({
            if ($script:radRespect.Checked) { $script:pendingMode = "RespectTaskbar"; Update-SettingsUiState }
        })
        $script:radIgnore.Add_CheckedChanged({
            if ($script:radIgnore.Checked) { $script:pendingMode = "IgnoreTaskbar"; Update-SettingsUiState }
        })

        # ---- status / hint label -------------------------------------------
        # Shows the recording tip by default and inline errors for duplicate
        # or invalid pending combinations.
        $script:lblStatus = New-Object System.Windows.Forms.Label
        $script:lblStatus.Location = New-Object System.Drawing.Point(12, 156)
        $script:lblStatus.Size = New-Object System.Drawing.Size(342, 36)
        $script:lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150)

        # ---- bottom buttons ---------------------------------------------------
        $script:btnSave = New-Object System.Windows.Forms.Button
        $script:btnSave.Text = "Save"
        $script:btnSave.Location = New-Object System.Drawing.Point(12, 200)
        $script:btnSave.Size = New-Object System.Drawing.Size(105, 30)
        $script:btnSave.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
        $script:btnSave.ForeColor = [System.Drawing.Color]::White
        $script:btnSave.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $script:btnSave.Enabled = $false   # nothing changed yet
        $script:btnSave.Add_Click({ ApplyPendingSettings })

        $btnOpenConfig = New-Object System.Windows.Forms.Button
        $btnOpenConfig.Text = "Open Config"
        $btnOpenConfig.Location = New-Object System.Drawing.Point(125, 200)
        $btnOpenConfig.Size = New-Object System.Drawing.Size(105, 30)
        $btnOpenConfig.BackColor = $script:darkBtnBack
        $btnOpenConfig.ForeColor = $script:darkFore
        $btnOpenConfig.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnOpenConfig.Add_Click({
            if (Test-Path $script:configFile) { Start-Process $script:configFile }
            else { [System.Windows.Forms.MessageBox]::Show("Config file not found.`r`n$($script:configFile)", "Window Centering Tool", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null }
        })

        $btnRestartAdmin = New-Object System.Windows.Forms.Button
        $btnRestartAdmin.Text = "Restart Admin"
        $btnRestartAdmin.Location = New-Object System.Drawing.Point(238, 200)
        $btnRestartAdmin.Size = New-Object System.Drawing.Size(105, 30)
        $btnRestartAdmin.BackColor = $script:darkBtnBack
        $btnRestartAdmin.ForeColor = $script:darkFore
        $btnRestartAdmin.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnRestartAdmin.Add_Click({ Restart-AsAdmin })

        $script:settingsForm.Controls.AddRange(@(
            $lblHK1, $script:txtHK1, $btnRecordHK1, $btnClearHK1,
            $lblHK2, $script:txtHK2, $btnRecordHK2, $btnClearHK2,
            $grpMode, $script:lblStatus,
            $script:btnSave, $btnOpenConfig, $btnRestartAdmin
        ))

        # ---- hotkey recording (KeyDown) for the primary slot ----------------
        $script:txtHK1.Add_KeyDown({
            $e = $_
            $mods = 0
            if ($e.Control) { $mods = $mods -bor $MOD_CONTROL }
            if ($e.Shift)   { $mods = $mods -bor $MOD_SHIFT }
            if ($e.Alt)     { $mods = $mods -bor $MOD_ALT }
            # Bare Escape cancels an ongoing recording.
            if (($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) -and ($mods -eq 0)) {
                $script:txtHK1.Text = Format-HotkeyString $script:pendingHK1
                Update-SettingsUiState
                $e.SuppressKeyPress = $true
                return
            }
            if ($script:txtHK1.Text -eq "Press keys...") { $script:txtHK1.Text = "" }
            $hk = Get-HotkeyFromKeyArgs $e
            if (-not $hk) {
                # Modifier-only / Windows key: not usable. Restore the previous
                # display instead of leaving the box empty.
                $script:txtHK1.Text = Format-HotkeyString $script:pendingHK1
                Update-SettingsUiState
                $e.SuppressKeyPress = $true
                return
            }
            $script:pendingHK1 = Copy-HotkeyObject $hk
            $script:txtHK1.Text = $hk.Display
            Update-SettingsUiState
            $e.SuppressKeyPress = $true
        })

        # ---- hotkey recording (KeyDown) for the secondary slot --------------
        $script:txtHK2.Add_KeyDown({
            $e = $_
            $mods = 0
            if ($e.Control) { $mods = $mods -bor $MOD_CONTROL }
            if ($e.Shift)   { $mods = $mods -bor $MOD_SHIFT }
            if ($e.Alt)     { $mods = $mods -bor $MOD_ALT }
            # Bare Escape cancels an ongoing recording.
            if (($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) -and ($mods -eq 0)) {
                $script:txtHK2.Text = Format-HotkeyString $script:pendingHK2
                Update-SettingsUiState
                $e.SuppressKeyPress = $true
                return
            }
            if ($script:txtHK2.Text -eq "Press keys...") { $script:txtHK2.Text = "" }
            $hk = Get-HotkeyFromKeyArgs $e
            if (-not $hk) {
                $script:txtHK2.Text = Format-HotkeyString $script:pendingHK2
                Update-SettingsUiState
                $e.SuppressKeyPress = $true
                return
            }
            $script:pendingHK2 = Copy-HotkeyObject $hk
            $script:txtHK2.Text = $hk.Display
            Update-SettingsUiState
            $e.SuppressKeyPress = $true
        })

        # ---- save-on-close prompt -------------------------------------------
        $script:settingsForm.Add_FormClosing({
            if ($_.CloseReason -ne [System.Windows.Forms.CloseReason]::UserClosing) { return }  # real shutdown: allow
            if (-not (Get-PendingChangesExist)) {
                $_.Cancel = $true
                $script:settingsForm.Hide()   # keep the form alive for next time
                return
            }

            $valid = ((Test-PendingHotkeyValid $script:pendingHK1 $script:pendingHK2) -and
                      (Test-PendingHotkeyValid $script:pendingHK2 $script:pendingHK1))
            if (-not $valid) {
                # Pending values can never be applied; offer to discard them.
                $result = [System.Windows.Forms.MessageBox]::Show(
                    "The recorded hotkeys are not usable (duplicate or missing modifier).`r`nDiscard these changes?",
                    "Window Centering Tool",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question)
                $_.Cancel = $true
                if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
                    Reset-SettingsFields
                    $script:settingsForm.Hide()
                }
                return
            }

            $hkChanged   = (HotkeysDiffer $script:pendingHK1 $script:config.Hotkey1) -or
                           (HotkeysDiffer $script:pendingHK2 $script:config.Hotkey2)
            $modeChanged = ($script:pendingMode -ne $script:config.CenteringMode)
            $msg = if ($hkChanged -and $modeChanged) {
                "Do you want to save hotkey and centering mode changes?"
            } elseif ($hkChanged) {
                "Do you want to save hotkey changes?"
            } else {
                "Do you want to save centering mode change?"
            }
            $result = [System.Windows.Forms.MessageBox]::Show(
                $msg,
                "Window Centering Tool",
                [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
                ApplyPendingSettings   # single save pipeline, same as the button
            }
            if ($result -eq [System.Windows.Forms.DialogResult]::Cancel) {
                $_.Cancel = $true
                return
            }
            # No -> discard; pending values are rebuilt from config on next open.
            $_.Cancel = $true
            $script:settingsForm.Hide()
        })

        Update-SettingsUiState   # initial state: Save disabled, tip shown
        $script:settingsForm.Show()
    }
#endregion

#region Lifecycle (Restart-AsAdmin + Stop-Application)
    function Restart-AsAdmin {
        # Saves the current config, then relaunches the batch file elevated.
        Write-WctLog "Restart with administrator rights requested." 'Info'
        Save-Config $script:config

        if (-not $script:batFile) {
            [System.Windows.Forms.MessageBox]::Show("Cannot restart: batch file path unknown.", "Window Centering Tool", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
        }
        try {
            Start-Process -FilePath $script:batFile -Verb RunAs -ErrorAction Stop
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Administrator elevation was cancelled or failed. The tool will continue without admin rights.", "Window Centering Tool", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }

        Stop-Application
    }

    function Stop-Application {
        # Idempotent shutdown: releases hotkeys, removes the tray icon,
        # destroys the message window, disposes UI/GDI resources (form, icon,
        # timer) and stops the message loop. Safe to call twice - the menu
        # handler and the finally block around Application::Run both use it.
        if ($script:shuttingDown) { return }
        $script:shuttingDown = $true

        # Release hotkeys first so they are free even if the rest fails.
        if ($script:msgWindow) {
            foreach ($id in @($script:hotkeyIds.Primary, $script:hotkeyIds.Secondary)) {
                try { [WinAPI]::UnregisterHotKey($script:msgWindow.Handle, $id) | Out-Null } catch { }
            }
        }
        if ($script:notifyIcon) {
            try { $script:notifyIcon.Visible = $false } catch { }
            try { $script:notifyIcon.Dispose() } catch { }
            $script:notifyIcon = $null
        }
        if ($script:settingsForm) {
            try { $script:settingsForm.Dispose() } catch { }
            $script:settingsForm = $null
        }
        if ($script:msgWindow) {
            try { $script:msgWindow.DestroyHandle() } catch { }
            $script:msgWindow = $null
        }
        if ($script:trimTimer) {
            try { $script:trimTimer.Stop(); $script:trimTimer.Dispose() } catch { }
            $script:trimTimer = $null
        }
        # Free the GDI icon handle that was created from the in-memory bitmap.
        if ($script:icon) {
            try { $script:icon.Dispose() } catch { }
            $script:icon = $null
        }
        if ($script:iconHandle -and $script:iconHandle -ne [IntPtr]::Zero) {
            try { [WinAPI]::DestroyIcon($script:iconHandle) | Out-Null } catch { }
            $script:iconHandle = [IntPtr]::Zero
        }
        [System.Windows.Forms.Application]::Exit()
    }
#endregion

#region Startup & safe exit
    try {
        Update-HotkeyRegistration
        Write-WctLog "Window Centering Tool v$($script:scriptVersion) started. Config: Hotkey1='$(Format-HotkeyString $script:config.Hotkey1)' | Hotkey2='$(Format-HotkeyString $script:config.Hotkey2)' | Mode: $($script:config.CenteringMode) | ConfigVersion: $($script:config.ConfigVersion)" 'Info'

        # Application::Run blocks until Application.Exit(); the finally block
        # below runs on normal exit AND when the message loop throws, so the
        # app can never leave hotkeys registered or litter the temp folder.
        [System.Windows.Forms.Application]::Run()
    }
    finally {
        Stop-Application
        Remove-TempScript   # second, defensive attempt to clean the temp file
    }
}
catch {
    # Build a single detailed report: version, time, config state, exceptions.
    $configSummary = 'unavailable (failed before config was loaded)'
    try {
        $configSummary = "Hotkey1='{0}' (registered: {1}) | Hotkey2='{2}' (registered: {3}) | Mode: {4} | Paused: {5}" -f (Format-HotkeyString $script:config.Hotkey1), [bool]$script:activeHotkeys.Primary, (Format-HotkeyString $script:config.Hotkey2), [bool]$script:activeHotkeys.Secondary, $script:config.CenteringMode, $script:paused
    } catch { }

    $msg = "=== Window Centering Tool v$($script:scriptVersion) - unhandled error ===`r`n"
    $msg += "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n"
    $msg += "Message: $($_.Exception.Message)`r`n"
    if ($_.Exception.InnerException) { $msg += "Inner Exception: $($_.Exception.InnerException.Message)`r`n" }
    if ($_.Exception -is [System.Management.Automation.MethodInvocationException]) {
        $inner = $_.Exception.InnerException
        while ($inner) {
            if ($inner -is [System.Reflection.ReflectionTypeLoadException]) {
                foreach ($lex in $inner.LoaderExceptions) { $msg += "Loader Exception: $($lex.Message)`r`n" }
            }
            $inner = $inner.InnerException
        }
    }
    $msg += "Config state: $configSummary`r`n"
    $msg += "Full Exception Details:`r`n$($_.Exception.ToString())`r`n"
    $msg += "Stack Trace:`r`n$($_.ScriptStackTrace)`r`n"
    $msg += "`r`n`$Error[0]:`r`n$($Error[0] | Out-String)`r`n"

    # Make sure the log folder exists, then append the report.
    try {
        $logDir = Split-Path -Parent $script:errorLogFile
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Add-Content -LiteralPath $script:errorLogFile -Value $msg -Encoding UTF8
    } catch { Write-WctLog "Unhandled error; could not write the detailed log: $($_.Exception.Message)" 'Error' }
    Write-WctLog "Unhandled error - details were written to the log." 'Error'

    try {
        [System.Windows.Forms.MessageBox]::Show("The tool encountered an error:`r`n`r`n$($_.Exception.Message)`r`n`r`nSee $script:errorLogFile for details.", "Window Centering Tool Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch { }

    if (Test-Path -LiteralPath $script:errorLogFile) { try { Start-Process $script:errorLogFile } catch { } }
}
#endregion
:PS_END
