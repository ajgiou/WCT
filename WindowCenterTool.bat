@echo off
setlocal EnableExtensions DisableDelayedExpansion

:: ===========================================================================
:: Window Centering Tool – Silent Launcher (VBS + PowerShell)
:: ===========================================================================
:: Extracts the PowerShell script to a temp .ps1, creates a small VBS launcher
:: that runs it hidden, then deletes itself. No console ever appears.
:: ===========================================================================

set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%POWERSHELL%" (
    echo PowerShell not found. Please install Windows Management Framework 5.1.
    pause >nul
    exit /b 1
)

set "me=%~f0"
set "tempPs=%TEMP%\CenterWindowTray.ps1"
set "tempVbs=%TEMP%\CenterWindowTray.vbs"

:: 1) Extract the PowerShell script from this file (between markers)
for /f "tokens=1 delims=:" %%N in ('findstr /n "^:PS_START" "%me%"') do set "startLine=%%N"
for /f "tokens=1 delims=:" %%N in ('findstr /n "^:PS_END"   "%me%"') do set "endLine=%%N"
set /a "startLine+=1"
set /a "endLine-=1"

"%POWERSHELL%" -NoProfile -Command ^
  "$lines = Get-Content '%me%'; $lines[(%startLine%-1)..(%endLine%-1)] | Set-Content '%tempPs%' -Encoding UTF8"

:: 2) Create a VBS launcher that runs the PowerShell script completely hidden
(
echo Set WshShell = CreateObject^("WScript.Shell"^)
echo WshShell.Run """%POWERSHELL%"" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""%tempPs%""", 0, False
echo WScript.Sleep 2000
echo ' Clean up temporary files
echo Set fso = CreateObject^("Scripting.FileSystemObject"^)
echo fso.DeleteFile "%tempPs%", True
echo fso.DeleteFile "%tempVbs%", True
) > "%tempVbs%"

:: 3) Launch the VBS silently (wscript.exe runs with no console)
wscript.exe //nologo "%tempVbs%"

exit /b

:PS_START
# =============================================================================
# Window Centering Tool – Tray Application (PowerShell)
# =============================================================================

$configDir = $env:CENTER_WINDOW_BATDIR
if (-not $configDir) {
    # Fallback (should not be needed)
    $configDir = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
}
$errorLog = Join-Path $configDir "WindowCenterTool_error.log"

# Self‑delete the temporary .ps1 (VBS already does it, but belt‑and‑suspenders)
$selfPath = $MyInvocation.MyCommand.Path
if ($selfPath -and (Test-Path $selfPath)) {
    Remove-Item $selfPath -Force -ErrorAction SilentlyContinue
}

try {
    # -----------------------------------------------------------------------------
    # Config file
    # -----------------------------------------------------------------------------
    $script:configFile = Join-Path $configDir "WindowCenteringTool.json"

    Add-Type -AssemblyName System.Windows.Forms, System.Drawing

    # -----------------------------------------------------------------------------
    # Single C# block (WinAPI + HiddenForm + FreeConsole)
    # -----------------------------------------------------------------------------
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class WinAPI
{
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint dwFlags);

    [DllImport("user32.dll")]
    public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
        int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    public static extern bool IsZoomed(IntPtr hWnd);

    [DllImport("kernel32.dll")]
    public static extern bool FreeConsole();

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left, Top, Right, Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    public const uint MONITOR_DEFAULTTONEAREST = 2;
    public const uint SWP_NOSIZE   = 0x0001;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;
}

public class HiddenForm : Form
{
    public const int WM_HOTKEY = 0x0312;
    public event Action HotkeyPressed;

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY)
        {
            if (HotkeyPressed != null) HotkeyPressed();
            return;
        }
        base.WndProc(ref m);
    }
}
"@ -ReferencedAssemblies System.Windows.Forms

    # Detach from any remaining console (belt‑and‑suspenders)
    [WinAPI]::FreeConsole() | Out-Null

    # -----------------------------------------------------------------------------
    # Constants & helpers
    # -----------------------------------------------------------------------------
    $WM_HOTKEY   = 0x0312
    $MOD_ALT     = 0x0001
    $MOD_CONTROL = 0x0002
    $MOD_SHIFT   = 0x0004
    $MOD_WIN     = 0x0008

    $script:hotkeyIds = @{ Primary = 1; Secondary = 2 }

    $script:defaultConfig = [PSCustomObject]@{
        Hotkey1       = @{
            Modifiers    = "Control+Shift"
            Key          = "C"
            ModifierFlags = 6          # MOD_CONTROL | MOD_SHIFT
            VirtualKey   = 0x43        # 'C'
        }
        Hotkey2       = $null
        CenteringMode = "RespectTaskbar"
    }

    # -----------------------------------------------------------------------------
    # Config persistence
    # -----------------------------------------------------------------------------
    function Load-Config {
        if (Test-Path $script:configFile) {
            try {
                $cfg = Get-Content $script:configFile -Raw | ConvertFrom-Json
                if (-not $cfg.Hotkey1)       { $cfg.Hotkey1 = $script:defaultConfig.Hotkey1 }
                if (-not $cfg.CenteringMode) { $cfg.CenteringMode = $script:defaultConfig.CenteringMode }
                return $cfg
            } catch {
                Write-Warning "Config corrupted, using defaults"
            }
        }
        return $script:defaultConfig | ConvertTo-Json -Depth 4 | ConvertFrom-Json
    }

    function Save-Config {
        param($config)
        $config | ConvertTo-Json -Depth 4 | Set-Content $script:configFile -Encoding UTF8
    }

    $script:config = Load-Config
    $script:paused = $false

    # -----------------------------------------------------------------------------
    # Hidden form for hotkey messages
    # -----------------------------------------------------------------------------
    $script:hiddenForm = New-Object HiddenForm
    $script:hiddenForm.WindowState       = [System.Windows.Forms.FormWindowState]::Minimized
    $script:hiddenForm.ShowInTaskbar     = $false
    $script:hiddenForm.FormBorderStyle   = [System.Windows.Forms.FormBorderStyle]::None
    $script:hiddenForm.Opacity           = 0

    # -----------------------------------------------------------------------------
    # Hotkey registration
    # -----------------------------------------------------------------------------
    function Update-HotkeyRegistration {
        [WinAPI]::UnregisterHotKey($script:hiddenForm.Handle, $script:hotkeyIds.Primary)   | Out-Null
        [WinAPI]::UnregisterHotKey($script:hiddenForm.Handle, $script:hotkeyIds.Secondary) | Out-Null

        if (-not $script:paused) {
            if ($script:config.Hotkey1) {
                $mod = [uint32]$script:config.Hotkey1.ModifierFlags
                $vk  = [uint32]$script:config.Hotkey1.VirtualKey
                $success = [WinAPI]::RegisterHotKey($script:hiddenForm.Handle, $script:hotkeyIds.Primary, $mod, $vk)
                if (-not $success) {
                    $script:notifyIcon.BalloonTipTitle = "Hotkey Registration Failed"
                    $script:notifyIcon.BalloonTipText  = "Could not register primary hotkey (maybe already in use)."
                    $script:notifyIcon.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::Warning
                    $script:notifyIcon.ShowBalloonTip(5000)
                }
            }
            if ($script:config.Hotkey2) {
                $mod = [uint32]$script:config.Hotkey2.ModifierFlags
                $vk  = [uint32]$script:config.Hotkey2.VirtualKey
                [WinAPI]::RegisterHotKey($script:hiddenForm.Handle, $script:hotkeyIds.Secondary, $mod, $vk) | Out-Null
            }
        }
    }

    # -----------------------------------------------------------------------------
    # Window centering logic
    # -----------------------------------------------------------------------------
    function Center-ActiveWindow {
        $hwnd = [WinAPI]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return }

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

        if ($script:config.CenteringMode -eq "RespectTaskbar") {
            $bounds = $monInfo.rcWork
        } else {
            $bounds = $monInfo.rcMonitor
        }

        # Skip full‑screen windows
        if (($rect.Left  -le $bounds.Left)  -and ($rect.Top    -le $bounds.Top) -and
            ($rect.Right -ge $bounds.Right) -and ($rect.Bottom -ge $bounds.Bottom)) {
            return
        }

        $newX = $bounds.Left + [Math]::Floor(($bounds.Right  - $bounds.Left - $wWidth)  / 2)
        $newY = $bounds.Top  + [Math]::Floor(($bounds.Bottom - $bounds.Top  - $wHeight) / 2)

        $newX = [Math]::Max($bounds.Left, $newX)
        $newY = [Math]::Max($bounds.Top,  $newY)
        $maxX = $bounds.Right  - $wWidth
        $maxY = $bounds.Bottom - $wHeight
        if ($newX -gt $maxX) { $newX = $maxX }
        if ($newY -gt $maxY) { $newY = $maxY }
        if ($newX -lt $bounds.Left) { $newX = $bounds.Left }
        if ($newY -lt $bounds.Top)  { $newY = $bounds.Top }

        $flags = [WinAPI]::SWP_NOSIZE -bor [WinAPI]::SWP_NOZORDER -bor [WinAPI]::SWP_NOACTIVATE
        [WinAPI]::SetWindowPos($hwnd, [IntPtr]::Zero, $newX, $newY, 0, 0, $flags) | Out-Null
    }

    $script:hiddenForm.add_HotkeyPressed({ Center-ActiveWindow })

    # -----------------------------------------------------------------------------
    # System‑tray icon
    # -----------------------------------------------------------------------------
    $global:iconBitmap = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($global:iconBitmap)
    $g.Clear([System.Drawing.Color]::FromArgb(45,45,45))
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::DodgerBlue)
    $g.FillEllipse($brush, 1, 1, 14, 14)
    $g.Dispose()
    $iconHandle = $global:iconBitmap.GetHicon()
    $script:icon = [System.Drawing.Icon]::FromHandle($iconHandle)

    $script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:notifyIcon.Text = "Window Centering Tool"
    $script:notifyIcon.Icon = $script:icon
    $script:notifyIcon.Visible = $true

    # Prevent tray icon from being hidden on Windows 11 22H2+
    function Protect-TrayIcon {
        $regRoot = 'HKCU:\Control Panel\NotifyIconSettings'
        if (Test-Path $regRoot) {
            Get-ChildItem -Path $regRoot -Recurse | ForEach-Object {
                $ep = (Get-ItemProperty $_.PSPath -Name ExecutablePath -EA SilentlyContinue).ExecutablePath
                if ($ep -match 'powershell') {
                    Set-ItemProperty $_.PSPath -Name IsPromoted -Value 1 -Type DWORD -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    Protect-TrayIcon

    # -----------------------------------------------------------------------------
    # Context menu
    # -----------------------------------------------------------------------------
    $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

    $script:menuSettings = New-Object System.Windows.Forms.ToolStripMenuItem -Property @{Text = "Settings"}
    $script:menuPause    = New-Object System.Windows.Forms.ToolStripMenuItem -Property @{Text = "Pause Hotkey"; CheckOnClick = $true}
    $script:menuExit     = New-Object System.Windows.Forms.ToolStripMenuItem -Property @{Text = "Exit"}

    $contextMenu.Items.AddRange(@($script:menuSettings, $script:menuPause, $script:menuExit))
    $script:notifyIcon.ContextMenuStrip = $contextMenu

    # Left‑click → show settings
    $script:notifyIcon.Add_Click({
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            Show-SettingsWindow
        }
    })

    # Right‑click Settings menu item → show settings
    $script:menuSettings.Add_Click({
        Show-SettingsWindow
    })

    $script:menuPause.Add_Click({
        $script:paused = $script:menuPause.Checked
        Update-HotkeyRegistration
    })

    $script:menuExit.Add_Click({
        [WinAPI]::UnregisterHotKey($script:hiddenForm.Handle, $script:hotkeyIds.Primary)
        [WinAPI]::UnregisterHotKey($script:hiddenForm.Handle, $script:hotkeyIds.Secondary)
        $script:notifyIcon.Visible = $false
        $script:notifyIcon.Dispose()
        $script:hiddenForm.Close()
        [System.Windows.Forms.Application]::Exit()
    })

    # -----------------------------------------------------------------------------
    # Settings window – always on top, all controls are script‑scoped
    # -----------------------------------------------------------------------------
    $script:settingsForm = $null
    $script:txtHK1 = $null
    $script:txtHK2 = $null

    function Show-SettingsWindow {
        if ($script:settingsForm -and $script:settingsForm.Visible) {
            $script:settingsForm.BringToFront()
            return
        }

        # Create the form
        $script:settingsForm = New-Object System.Windows.Forms.Form
        $script:settingsForm.Text            = "Window Centering Settings"
        $script:settingsForm.Size            = New-Object System.Drawing.Size(390, 290)
        $script:settingsForm.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $script:settingsForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $script:settingsForm.MaximizeBox     = $false
        $script:settingsForm.MinimizeBox     = $false
        $script:settingsForm.TopMost         = $true   # Always on top

        $darkBack       = [System.Drawing.Color]::FromArgb(30, 30, 30)
        $darkFore       = [System.Drawing.Color]::FromArgb(220, 220, 220)
        $darkButtonBack = [System.Drawing.Color]::FromArgb(60, 60, 60)

        $script:settingsForm.BackColor = $darkBack
        $script:settingsForm.ForeColor = $darkFore

        # ===== Primary Hotkey =====
        $lblHK1 = New-Object System.Windows.Forms.Label
        $lblHK1.Text     = "Primary Hotkey:"
        $lblHK1.Location = New-Object System.Drawing.Point(12, 15)
        $lblHK1.Size     = New-Object System.Drawing.Size(105, 20)
        $lblHK1.ForeColor = $darkFore

        $script:txtHK1 = New-Object System.Windows.Forms.TextBox
        $script:txtHK1.Location  = New-Object System.Drawing.Point(120, 12)
        $script:txtHK1.Size      = New-Object System.Drawing.Size(140, 20)
        $script:txtHK1.ReadOnly  = $true
        $script:txtHK1.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
        $script:txtHK1.ForeColor = $darkFore
        $script:txtHK1.Text      = Format-HotkeyString $script:config.Hotkey1

        $btnRecordHK1 = New-Object System.Windows.Forms.Button
        $btnRecordHK1.Text     = "Record"
        $btnRecordHK1.Location = New-Object System.Drawing.Point(270, 10)
        $btnRecordHK1.Size     = New-Object System.Drawing.Size(80, 23)
        $btnRecordHK1.BackColor = $darkButtonBack
        $btnRecordHK1.ForeColor = $darkFore
        $btnRecordHK1.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnRecordHK1.Add_Click({
            $script:txtHK1.Text = "Press keys..."
            $script:txtHK1.Focus()
        })

        # ===== Secondary Hotkey =====
        $lblHK2 = New-Object System.Windows.Forms.Label
        $lblHK2.Text     = "Secondary Hotkey:"
        $lblHK2.Location = New-Object System.Drawing.Point(12, 50)
        $lblHK2.Size     = New-Object System.Drawing.Size(105, 20)
        $lblHK2.ForeColor = $darkFore

        $script:txtHK2 = New-Object System.Windows.Forms.TextBox
        $script:txtHK2.Location  = New-Object System.Drawing.Point(120, 47)
        $script:txtHK2.Size      = New-Object System.Drawing.Size(140, 20)
        $script:txtHK2.ReadOnly  = $true
        $script:txtHK2.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
        $script:txtHK2.ForeColor = $darkFore
        if ($script:config.Hotkey2) {
            $script:txtHK2.Text = Format-HotkeyString $script:config.Hotkey2
        } else {
            $script:txtHK2.Text = "None"
        }

        $btnRecordHK2 = New-Object System.Windows.Forms.Button
        $btnRecordHK2.Text     = "Record"
        $btnRecordHK2.Location = New-Object System.Drawing.Point(270, 45)
        $btnRecordHK2.Size     = New-Object System.Drawing.Size(80, 23)
        $btnRecordHK2.BackColor = $darkButtonBack
        $btnRecordHK2.ForeColor = $darkFore
        $btnRecordHK2.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnRecordHK2.Add_Click({
            $script:txtHK2.Text = "Press keys..."
            $script:txtHK2.Focus()
        })

        $btnClearHK2 = New-Object System.Windows.Forms.Button
        $btnClearHK2.Text     = "Clear"
        $btnClearHK2.Location = New-Object System.Drawing.Point(270, 75)
        $btnClearHK2.Size     = New-Object System.Drawing.Size(80, 23)
        $btnClearHK2.BackColor = $darkButtonBack
        $btnClearHK2.ForeColor = $darkFore
        $btnClearHK2.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnClearHK2.Add_Click({
            $script:config.Hotkey2 = $null
            $script:txtHK2.Text = "None"
            Save-Config $script:config
            Update-HotkeyRegistration
        })

        # ===== Centering Mode =====
        $grpMode = New-Object System.Windows.Forms.GroupBox
        $grpMode.Text     = "Centering Mode"
        $grpMode.Location = New-Object System.Drawing.Point(12, 110)
        $grpMode.Size     = New-Object System.Drawing.Size(340, 70)
        $grpMode.ForeColor = $darkFore

        $radRespect = New-Object System.Windows.Forms.RadioButton
        $radRespect.Text     = "Respect taskbar"
        $radRespect.Location = New-Object System.Drawing.Point(15, 25)
        $radRespect.Size     = New-Object System.Drawing.Size(140, 20)
        $radRespect.ForeColor = $darkFore

        $radIgnore = New-Object System.Windows.Forms.RadioButton
        $radIgnore.Text     = "Ignore taskbar"
        $radIgnore.Location = New-Object System.Drawing.Point(170, 25)
        $radIgnore.Size     = New-Object System.Drawing.Size(140, 20)
        $radIgnore.ForeColor = $darkFore

        if ($script:config.CenteringMode -eq "RespectTaskbar") {
            $radRespect.Checked = $true
        } else {
            $radIgnore.Checked  = $true
        }

        $grpMode.Controls.AddRange(@($radRespect, $radIgnore))

        $radRespect.Add_CheckedChanged({
            if ($radRespect.Checked) {
                $script:config.CenteringMode = "RespectTaskbar"
                Save-Config $script:config
            }
        })
        $radIgnore.Add_CheckedChanged({
            if ($radIgnore.Checked) {
                $script:config.CenteringMode = "IgnoreTaskbar"
                Save-Config $script:config
            }
        })

        # ===== Save / re‑register button =====
        $btnSave = New-Object System.Windows.Forms.Button
        $btnSave.Text     = "Save & Re-register"
        $btnSave.Location = New-Object System.Drawing.Point(120, 200)
        $btnSave.Size     = New-Object System.Drawing.Size(140, 30)
        $btnSave.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
        $btnSave.ForeColor = [System.Drawing.Color]::White
        $btnSave.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnSave.Add_Click({
            Save-Config $script:config
            Update-HotkeyRegistration
        })

        $script:settingsForm.Controls.AddRange(@(
            $lblHK1, $script:txtHK1, $btnRecordHK1,
            $lblHK2, $script:txtHK2, $btnRecordHK2, $btnClearHK2,
            $grpMode, $btnSave
        ))

        # ------ Hotkey recording handlers (correctly separate modifiers from key) ------
        $script:txtHK1.Add_KeyDown({
            $e = $_
            if ($script:txtHK1.Text -eq "Press keys...") { $script:txtHK1.Text = "" }
            $mods = 0
            if ($e.Control) { $mods = $mods -bor $MOD_CONTROL }
            if ($e.Shift)   { $mods = $mods -bor $MOD_SHIFT }
            if ($e.Alt)     { $mods = $mods -bor $MOD_ALT }
            $keyCode = [int]$e.KeyCode
            # Ignore pure modifier presses
            if ($keyCode -in 0x10, 0x11, 0x12) { return }

            # Build the modifier string (only modifiers, no key yet)
            $modStr = ""
            if ($e.Control) { $modStr += "Control+" }
            if ($e.Shift)   { $modStr += "Shift+" }
            if ($e.Alt)     { $modStr += "Alt+" }

            # The stored modifiers part (without the key)
            $modifiersOnly = $modStr.TrimEnd('+')

            # Display string: modifiers + key
            $display = if ($modifiersOnly.Length -gt 0) { "$modifiersOnly+$($e.KeyCode)" } else { $e.KeyCode.ToString() }
            $script:txtHK1.Text = $display

            $script:config.Hotkey1 = @{
                Modifiers     = $modifiersOnly
                Key           = $e.KeyCode.ToString()
                ModifierFlags = $mods
                VirtualKey    = $keyCode
            }
            Save-Config $script:config
            Update-HotkeyRegistration
            $e.SuppressKeyPress = $true
        })

        $script:txtHK2.Add_KeyDown({
            $e = $_
            if ($script:txtHK2.Text -eq "Press keys...") { $script:txtHK2.Text = "" }
            $mods = 0
            if ($e.Control) { $mods = $mods -bor $MOD_CONTROL }
            if ($e.Shift)   { $mods = $mods -bor $MOD_SHIFT }
            if ($e.Alt)     { $mods = $mods -bor $MOD_ALT }
            $keyCode = [int]$e.KeyCode
            if ($keyCode -in 0x10, 0x11, 0x12) { return }

            $modStr = ""
            if ($e.Control) { $modStr += "Control+" }
            if ($e.Shift)   { $modStr += "Shift+" }
            if ($e.Alt)     { $modStr += "Alt+" }

            $modifiersOnly = $modStr.TrimEnd('+')
            $display = if ($modifiersOnly.Length -gt 0) { "$modifiersOnly+$($e.KeyCode)" } else { $e.KeyCode.ToString() }
            $script:txtHK2.Text = $display

            $script:config.Hotkey2 = @{
                Modifiers     = $modifiersOnly
                Key           = $e.KeyCode.ToString()
                ModifierFlags = $mods
                VirtualKey    = $keyCode
            }
            Save-Config $script:config
            Update-HotkeyRegistration
            $e.SuppressKeyPress = $true
        })

        # Closing the settings window only hides it, never exits
        $script:settingsForm.Add_FormClosing({
            if ($_.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
                $_.Cancel = $true
                $script:settingsForm.Hide()
            }
        })

        $script:settingsForm.Show()
    }

    # Helper: format hotkey object for display
    function Format-HotkeyString {
        param($hotkey)
        if (-not $hotkey) { return "None" }
        $mods = $hotkey.Modifiers
        $key  = $hotkey.Key
        if ([string]::IsNullOrEmpty($mods)) {
            return $key
        }
        return "$mods+$key"
    }

    # -----------------------------------------------------------------------------
    # Start the application
    # -----------------------------------------------------------------------------
    Update-HotkeyRegistration
    [System.Windows.Forms.Application]::Run($script:hiddenForm)
}
catch {
    $msg = "[{0}] ERROR`r`n" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    $msg += "Message: $($_.Exception.Message)`r`n"
    if ($_.Exception.InnerException) {
        $msg += "Inner Exception: $($_.Exception.InnerException.Message)`r`n"
    }
    if ($_.Exception -is [System.Management.Automation.MethodInvocationException]) {
        $inner = $_.Exception.InnerException
        while ($inner) {
            if ($inner -is [System.Reflection.ReflectionTypeLoadException]) {
                foreach ($lex in $inner.LoaderExceptions) {
                    $msg += "Loader Exception: $($lex.Message)`r`n"
                }
            }
            $inner = $inner.InnerException
        }
    }
    $msg += "Full Exception Details:`r`n$($_.Exception.ToString())`r`n"
    $msg += "Stack Trace:`r`n$($_.ScriptStackTrace)`r`n"
    $msg += "`r`n`$Error[0]:`r`n$($Error[0] | Out-String)`r`n"

    Set-Content -Path $errorLog -Value $msg -Encoding UTF8
    [System.Windows.Forms.MessageBox]::Show(
        "The tool encountered an error:`r`n`r`n$($_.Exception.Message)`r`n`r`nSee $errorLog for details.",
        "Window Centering Tool Error",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error)
}
:PS_END