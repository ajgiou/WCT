@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%POWERSHELL%" (echo PowerShell not found.& pause & exit /b 1)
set "me=%~f0"
set "CENTER_WINDOW_BATDIR=%~dp0"
set "CENTER_WINDOW_BATFILE=%me%"

REM Use unique temporary filenames to avoid collisions between multiple instances
set "tempPs=%TEMP%\CenterWindowTray_%PID%.ps1"
set "tempVbs=%TEMP%\CenterWindowTray_%PID%.vbs"

REM Extract the embedded PowerShell script (between :PS_START and :PS_END)
for /f "tokens=1 delims=:" %%N in ('findstr /n "^:PS_START" "%me%"') do set "startLine=%%N"
for /f "tokens=1 delims=:" %%N in ('findstr /n "^:PS_END"   "%me%"') do set "endLine=%%N"
set /a "startLine+=1"
set /a "endLine-=1"
"%POWERSHELL%" -NoProfile -Command "$lines = Get-Content '%me%'; $lines[(%startLine%-1)..(%endLine%-1)] | Set-Content '%tempPs%' -Encoding UTF8"

REM Create a tiny VBScript that launches the PowerShell script hidden, then cleans up the .ps1
(
echo On Error Resume Next
echo Set WshShell = CreateObject^("WScript.Shell"^)
echo WshShell.Run """%POWERSHELL%"" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""%tempPs%""", 0, False
echo WScript.Sleep 2000
echo Set fso = CreateObject^("Scripting.FileSystemObject"^)
echo fso.DeleteFile "%tempPs%", True
) > "%tempVbs%"
wscript.exe //nologo "%tempVbs%"

REM The batch file's job is done – the tool runs in the background now
exit /b

:PS_START
#region Bootstrap & error trap
# NOTE: $ErrorActionPreference='Stop' is set by the launcher (Task 2) so unhandled
# errors route into this catch{}. For now the existing default is preserved.
$configDir = $env:CENTER_WINDOW_BATDIR
if (-not $configDir) { $configDir = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path) }
$script:batFile = $env:CENTER_WINDOW_BATFILE
if (-not $script:batFile) { $script:batFile = "" }
$errorLog = Join-Path $configDir "WindowCenterTool_error.log"
$selfPath = $MyInvocation.MyCommand.Path
if ($selfPath -and (Test-Path $selfPath)) { Remove-Item $selfPath -Force -ErrorAction SilentlyContinue }

try {
#endregion

#region Paths & Config
    $script:configFile = Join-Path $configDir "WindowCenteringTool.json"
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing

    $WM_HOTKEY = 0x0312
    $MOD_ALT     = 0x0001
    $MOD_CONTROL = 0x0002
    $MOD_SHIFT   = 0x0004
    $MOD_WIN     = 0x0008

    $script:hotkeyIds = @{ Primary = 1; Secondary = 2 }

    $script:defaultConfig = [PSCustomObject]@{
        Hotkey1 = @{ Modifiers = "Control+Shift"; Key = "C"; ModifierFlags = 6; VirtualKey = 0x43 }
        Hotkey2 = $null
        CenteringMode = "RespectTaskbar"
    }

    function Load-Config {
        if (Test-Path $script:configFile) {
            try {
                $cfg = Get-Content $script:configFile -Raw | ConvertFrom-Json
                if (-not $cfg.Hotkey1) { $cfg.Hotkey1 = $script:defaultConfig.Hotkey1 }
                if (-not $cfg.CenteringMode) { $cfg.CenteringMode = $script:defaultConfig.CenteringMode }
                return $cfg
            } catch { Write-Warning "Config corrupted, using defaults" }
        }
        return $script:defaultConfig | ConvertTo-Json -Depth 4 | ConvertFrom-Json
    }

    function Save-Config {
        param($config)
        $config | ConvertTo-Json -Depth 4 | Set-Content $script:configFile -Encoding UTF8
    }
#endregion

#region Native interop (WinAPI P/Invoke + MessageOnlyWindow)
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
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
    [DllImport("user32.dll")]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")]
    public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr hWnd, uint gaFlags);
    [DllImport("kernel32.dll")]
    public static extern bool FreeConsole();
    [DllImport("kernel32.dll")]
    public static extern bool SetProcessWorkingSetSize(IntPtr hProcess, int dwMinimumWorkingSetSize, int dwMaximumWorkingSetSize);

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
    public const uint GA_ROOT = 2;
    public static readonly IntPtr HWND_MESSAGE = new IntPtr(-3);
}

public class MessageOnlyWindow : NativeWindow
{
    public event Action HotkeyPressed;
    public const int WM_HOTKEY = 0x0312;

    public MessageOnlyWindow()
    {
        CreateHandle(new CreateParams
        {
            Parent = WinAPI.HWND_MESSAGE
        });
    }

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
#endregion

#region App state
    [WinAPI]::FreeConsole() | Out-Null
    [WinAPI]::SetProcessWorkingSetSize((Get-Process -Id $pid).Handle, -1, -1) | Out-Null

    $script:config = Load-Config
    $script:paused = $false

    $script:msgWindow = New-Object MessageOnlyWindow
    $script:msgWindow.add_HotkeyPressed({ Center-ActiveWindow })

    $script:settingsForm = $null
    $script:txtHK1 = $null
    $script:txtHK2 = $null
    $script:pendingHK1 = $null
    $script:pendingHK2 = $null
#endregion

#region Centering logic
    function Center-ActiveWindow {
        $hwndFore = [WinAPI]::GetForegroundWindow()
        if ($hwndFore -eq [IntPtr]::Zero) { return }

        $hwnd = [WinAPI]::GetAncestor($hwndFore, [WinAPI]::GA_ROOT)
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

        if ($script:config.CenteringMode -eq "RespectTaskbar") { $bounds = $monInfo.rcWork }
        else { $bounds = $monInfo.rcMonitor }

        if (($rect.Left  -le $bounds.Left)  -and ($rect.Top    -le $bounds.Top) -and
            ($rect.Right -ge $bounds.Right) -and ($rect.Bottom -ge $bounds.Bottom)) {
            return
        }

        $newX = $bounds.Left + [Math]::Floor(($bounds.Right - $bounds.Left - $wWidth) / 2)
        $newY = $bounds.Top  + [Math]::Floor(($bounds.Bottom - $bounds.Top - $wHeight) / 2)
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
            [WinAPI]::MoveWindow($hwnd, $newX, $newY, $wWidth, $wHeight, $true) | Out-Null
        }

        [WinAPI]::SetProcessWorkingSetSize((Get-Process -Id $pid).Handle, -1, -1) | Out-Null
    }
#endregion

#region Hotkey registration
    function Update-HotkeyRegistration {
        [WinAPI]::UnregisterHotKey($script:msgWindow.Handle, $script:hotkeyIds.Primary)   | Out-Null
        [WinAPI]::UnregisterHotKey($script:msgWindow.Handle, $script:hotkeyIds.Secondary) | Out-Null
        if (-not $script:paused) {
            if ($script:config.Hotkey1) {
                $mod = [uint32]$script:config.Hotkey1.ModifierFlags
                $vk  = [uint32]$script:config.Hotkey1.VirtualKey
                $success = [WinAPI]::RegisterHotKey($script:msgWindow.Handle, $script:hotkeyIds.Primary, $mod, $vk)
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
                [WinAPI]::RegisterHotKey($script:msgWindow.Handle, $script:hotkeyIds.Secondary, $mod, $vk) | Out-Null
            }
        }
    }
#endregion

#region Tray (icon / menu / events)
    # Build a simple tray icon
    $global:iconBitmap = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($global:iconBitmap)
    $g.Clear([System.Drawing.Color]::FromArgb(45,45,45))
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::DodgerBlue)
    $g.FillEllipse($brush, 1, 1, 14, 14)
    $g.Dispose()
    $script:icon = [System.Drawing.Icon]::FromHandle($global:iconBitmap.GetHicon())

    $script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:notifyIcon.Text = "Window Centering Tool"
    $script:notifyIcon.Icon = $script:icon
    $script:notifyIcon.Visible = $true

    # Keep the tray icon visible (Windows often hides unused icons)
    function Protect-TrayIcon {
        $regRoot = 'HKCU:\Control Panel\NotifyIconSettings'
        if (Test-Path $regRoot) {
            # Only promote the icon for THIS PowerShell process (exact executable path)
            $myExe = (Get-Process -Id $pid).Path
            Get-ChildItem -Path $regRoot -Recurse | ForEach-Object {
                $ep = (Get-ItemProperty $_.PSPath -Name ExecutablePath -EA SilentlyContinue).ExecutablePath
                if ($ep -eq $myExe) {
                    Set-ItemProperty $_.PSPath -Name IsPromoted -Value 1 -Type DWORD -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    Protect-TrayIcon

    $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $script:menuSettings = New-Object System.Windows.Forms.ToolStripMenuItem -Property @{Text = "Settings"}
    $script:menuPause    = New-Object System.Windows.Forms.ToolStripMenuItem -Property @{Text = "Pause Hotkey"; CheckOnClick = $true}
    $script:menuRestart  = New-Object System.Windows.Forms.ToolStripMenuItem -Property @{Text = "Restart as Administrator"}
    $script:menuExit     = New-Object System.Windows.Forms.ToolStripMenuItem -Property @{Text = "Exit"}
    $contextMenu.Items.AddRange(@($script:menuSettings, $script:menuPause, $script:menuRestart, $script:menuExit))
    $script:notifyIcon.ContextMenuStrip = $contextMenu

    $script:notifyIcon.Add_Click({
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-SettingsWindow }
    })
    $script:menuSettings.Add_Click({ Show-SettingsWindow })
    $script:menuPause.Add_Click({
        $script:paused = $script:menuPause.Checked
        Update-HotkeyRegistration
    })
    $script:menuRestart.Add_Click({ Restart-AsAdmin })
    $script:menuExit.Add_Click({ Stop-Application })

    # Periodic memory trimming (every 5 minutes)
    $trimTimer = New-Object System.Windows.Forms.Timer
    $trimTimer.Interval = 300000  # 5 minutes in milliseconds
    $trimTimer.Add_Tick({
        [WinAPI]::SetProcessWorkingSetSize((Get-Process -Id $pid).Handle, -1, -1) | Out-Null
    })
    $trimTimer.Start()
#endregion

#region Settings UI
    function Format-HotkeyString {
        param($hotkey)
        if (-not $hotkey) { return "None" }
        $mods = $hotkey.Modifiers
        $key  = $hotkey.Key
        if ([string]::IsNullOrEmpty($mods)) { return $key }
        return "$mods+$key"
    }

    function HotkeysDiffer {
        param($a, $b)
        if ($a -eq $null -and $b -eq $null) { return $false }
        if ($a -eq $null -or $b -eq $null) { return $true }
        return ($a.Modifiers -ne $b.Modifiers) -or ($a.Key -ne $b.Key) -or
               ($a.ModifierFlags -ne $b.ModifierFlags) -or ($a.VirtualKey -ne $b.VirtualKey)
    }

    # Returns a fresh hashtable copy of a hotkey object (or $null). Replaces the
    # repeated inline @{ Modifiers=...; Key=...; ModifierFlags=...; VirtualKey=... } copies.
    function Copy-HotkeyObject {
        param($hotkey)
        if (-not $hotkey) { return $null }
        return @{
            Modifiers      = $hotkey.Modifiers
            Key            = $hotkey.Key
            ModifierFlags  = $hotkey.ModifierFlags
            VirtualKey     = $hotkey.VirtualKey
        }
    }

    # Pure logic: parse a WinForms KeyEventArgs into a hotkey descriptor, or $null
    # if only a bare modifier key (Shift/Ctrl/Alt) was pressed. Returns a hashtable
    # with Display, Modifiers, Key, ModifierFlags, VirtualKey. Pure (no $script: writes),
    # so the inline Add_KeyDown handlers below stay scope-safe while staying small.
    function Get-HotkeyFromKeyArgs {
        param($e)
        $mods = 0
        if ($e.Control) { $mods = $mods -bor $MOD_CONTROL }
        if ($e.Shift)   { $mods = $mods -bor $MOD_SHIFT }
        if ($e.Alt)     { $mods = $mods -bor $MOD_ALT }
        $keyCode = [int]$e.KeyCode
        if ($keyCode -in 0x10, 0x11, 0x12) { return $null }
        $modStr = ""
        if ($e.Control) { $modStr += "Control+" }
        if ($e.Shift)   { $modStr += "Shift+" }
        if ($e.Alt)     { $modStr += "Alt+" }
        $modifiersOnly = $modStr.TrimEnd('+')
        $display = if ($modifiersOnly.Length -gt 0) { "$modifiersOnly+$($e.KeyCode)" } else { $e.KeyCode.ToString() }
        return @{
            Display        = $display
            Modifiers      = $modifiersOnly
            Key            = $e.KeyCode.ToString()
            ModifierFlags  = $mods
            VirtualKey     = $keyCode
        }
    }

    function Reset-SettingsFields {
        $script:pendingHK1 = Copy-HotkeyObject $script:config.Hotkey1
        $script:pendingHK2 = Copy-HotkeyObject $script:config.Hotkey2
        if ($script:txtHK1) { $script:txtHK1.Text = Format-HotkeyString $script:pendingHK1 }
        if ($script:txtHK2) { $script:txtHK2.Text = Format-HotkeyString $script:pendingHK2 }
    }

    function Show-SettingsWindow {
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

        $script:settingsForm = New-Object System.Windows.Forms.Form
        $script:settingsForm.Text = "Window Centering Settings"
        $script:settingsForm.Size = New-Object System.Drawing.Size(390, 290)
        $script:settingsForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $script:settingsForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $script:settingsForm.MaximizeBox = $false
        $script:settingsForm.MinimizeBox = $false
        $script:settingsForm.TopMost = $true
        $darkBack = [System.Drawing.Color]::FromArgb(30, 30, 30)
        $darkFore = [System.Drawing.Color]::FromArgb(220, 220, 220)
        $darkButtonBack = [System.Drawing.Color]::FromArgb(60, 60, 60)
        $script:settingsForm.BackColor = $darkBack
        $script:settingsForm.ForeColor = $darkFore

        Reset-SettingsFields

        $lblHK1 = New-Object System.Windows.Forms.Label
        $lblHK1.Text = "Primary Hotkey:"
        $lblHK1.Location = New-Object System.Drawing.Point(12, 15)
        $lblHK1.Size = New-Object System.Drawing.Size(105, 20)
        $lblHK1.ForeColor = $darkFore

        $script:txtHK1 = New-Object System.Windows.Forms.TextBox
        $script:txtHK1.Location = New-Object System.Drawing.Point(120, 12)
        $script:txtHK1.Size = New-Object System.Drawing.Size(140, 20)
        $script:txtHK1.ReadOnly = $true
        $script:txtHK1.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
        $script:txtHK1.ForeColor = $darkFore
        $script:txtHK1.Text = Format-HotkeyString $script:pendingHK1

        $btnRecordHK1 = New-Object System.Windows.Forms.Button
        $btnRecordHK1.Text = "Record"
        $btnRecordHK1.Location = New-Object System.Drawing.Point(270, 10)
        $btnRecordHK1.Size = New-Object System.Drawing.Size(80, 23)
        $btnRecordHK1.BackColor = $darkButtonBack
        $btnRecordHK1.ForeColor = $darkFore
        $btnRecordHK1.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnRecordHK1.Add_Click({
            $script:txtHK1.Text = "Press keys..."
            $script:txtHK1.Focus()
        })

        $lblHK2 = New-Object System.Windows.Forms.Label
        $lblHK2.Text = "Secondary Hotkey:"
        $lblHK2.Location = New-Object System.Drawing.Point(12, 50)
        $lblHK2.Size = New-Object System.Drawing.Size(105, 20)
        $lblHK2.ForeColor = $darkFore

        $script:txtHK2 = New-Object System.Windows.Forms.TextBox
        $script:txtHK2.Location = New-Object System.Drawing.Point(120, 47)
        $script:txtHK2.Size = New-Object System.Drawing.Size(140, 20)
        $script:txtHK2.ReadOnly = $true
        $script:txtHK2.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
        $script:txtHK2.ForeColor = $darkFore
        $script:txtHK2.Text = Format-HotkeyString $script:pendingHK2

        $btnRecordHK2 = New-Object System.Windows.Forms.Button
        $btnRecordHK2.Text = "Record"
        $btnRecordHK2.Location = New-Object System.Drawing.Point(270, 45)
        $btnRecordHK2.Size = New-Object System.Drawing.Size(80, 23)
        $btnRecordHK2.BackColor = $darkButtonBack
        $btnRecordHK2.ForeColor = $darkFore
        $btnRecordHK2.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnRecordHK2.Add_Click({
            $script:txtHK2.Text = "Press keys..."
            $script:txtHK2.Focus()
        })

        $btnClearHK2 = New-Object System.Windows.Forms.Button
        $btnClearHK2.Text = "Clear"
        $btnClearHK2.Location = New-Object System.Drawing.Point(270, 75)
        $btnClearHK2.Size = New-Object System.Drawing.Size(80, 23)
        $btnClearHK2.BackColor = $darkButtonBack
        $btnClearHK2.ForeColor = $darkFore
        $btnClearHK2.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnClearHK2.Add_Click({
            $script:pendingHK2 = $null
            $script:txtHK2.Text = "None"
        })

        $grpMode = New-Object System.Windows.Forms.GroupBox
        $grpMode.Text = "Centering Mode"
        $grpMode.Location = New-Object System.Drawing.Point(12, 110)
        $grpMode.Size = New-Object System.Drawing.Size(340, 60)
        $grpMode.ForeColor = $darkFore

        $radRespect = New-Object System.Windows.Forms.RadioButton
        $radRespect.Text = "Respect taskbar"
        $radRespect.Location = New-Object System.Drawing.Point(15, 22)
        $radRespect.Size = New-Object System.Drawing.Size(140, 20)
        $radRespect.ForeColor = $darkFore

        $radIgnore = New-Object System.Windows.Forms.RadioButton
        $radIgnore.Text = "Ignore taskbar"
        $radIgnore.Location = New-Object System.Drawing.Point(170, 22)
        $radIgnore.Size = New-Object System.Drawing.Size(140, 20)
        $radIgnore.ForeColor = $darkFore

        if ($script:config.CenteringMode -eq "RespectTaskbar") { $radRespect.Checked = $true } else { $radIgnore.Checked = $true }

        $grpMode.Controls.AddRange(@($radRespect, $radIgnore))
        $radRespect.Add_CheckedChanged({
            if ($radRespect.Checked) { $script:config.CenteringMode = "RespectTaskbar"; Save-Config $script:config }
        })
        $radIgnore.Add_CheckedChanged({
            if ($radIgnore.Checked) { $script:config.CenteringMode = "IgnoreTaskbar"; Save-Config $script:config }
        })

        # Three horizontal action buttons
        $btnSave = New-Object System.Windows.Forms.Button
        $btnSave.Text = "Save"
        $btnSave.Location = New-Object System.Drawing.Point(12, 190)
        $btnSave.Size = New-Object System.Drawing.Size(105, 30)
        $btnSave.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
        $btnSave.ForeColor = [System.Drawing.Color]::White
        $btnSave.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnSave.Add_Click({
            if ($script:pendingHK1) { $script:config.Hotkey1 = $script:pendingHK1 } else { $script:config.Hotkey1 = $null }
            if ($script:pendingHK2) { $script:config.Hotkey2 = $script:pendingHK2 } else { $script:config.Hotkey2 = $null }
            Save-Config $script:config
            Update-HotkeyRegistration
            $script:pendingHK1 = Copy-HotkeyObject $script:config.Hotkey1
            $script:pendingHK2 = Copy-HotkeyObject $script:config.Hotkey2
        })

        $btnOpenConfig = New-Object System.Windows.Forms.Button
        $btnOpenConfig.Text = "Open Config"
        $btnOpenConfig.Location = New-Object System.Drawing.Point(125, 190)
        $btnOpenConfig.Size = New-Object System.Drawing.Size(105, 30)
        $btnOpenConfig.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
        $btnOpenConfig.ForeColor = $darkFore
        $btnOpenConfig.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnOpenConfig.Add_Click({
            if (Test-Path $script:configFile) { Start-Process $script:configFile }
            else { [System.Windows.Forms.MessageBox]::Show("Config file not found.`r`n$($script:configFile)", "Window Centering Tool", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) }
        })

        $btnRestartAdmin = New-Object System.Windows.Forms.Button
        $btnRestartAdmin.Text = "Restart Admin"
        $btnRestartAdmin.Location = New-Object System.Drawing.Point(238, 190)
        $btnRestartAdmin.Size = New-Object System.Drawing.Size(105, 30)
        $btnRestartAdmin.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
        $btnRestartAdmin.ForeColor = $darkFore
        $btnRestartAdmin.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnRestartAdmin.Add_Click({ Restart-AsAdmin })

        $script:settingsForm.Controls.AddRange(@(
            $lblHK1, $script:txtHK1, $btnRecordHK1,
            $lblHK2, $script:txtHK2, $btnRecordHK2, $btnClearHK2,
            $grpMode, $btnSave, $btnOpenConfig, $btnRestartAdmin
        ))

        # KeyDown handlers stay inline (WinForms passes $sender,$e and inline
        # scriptblocks close cleanly over $script: scope). They delegate the pure
        # parse to Get-HotkeyFromKeyArgs so the two slots share one implementation.
        $script:txtHK1.Add_KeyDown({
            $e = $_
            if ($script:txtHK1.Text -eq "Press keys...") { $script:txtHK1.Text = "" }
            $hk = Get-HotkeyFromKeyArgs $e
            if (-not $hk) { return }
            $script:txtHK1.Text = $hk.Display
            $script:pendingHK1 = @{
                Modifiers      = $hk.Modifiers
                Key            = $hk.Key
                ModifierFlags  = $hk.ModifierFlags
                VirtualKey     = $hk.VirtualKey
            }
            $e.SuppressKeyPress = $true
        })

        $script:txtHK2.Add_KeyDown({
            $e = $_
            if ($script:txtHK2.Text -eq "Press keys...") { $script:txtHK2.Text = "" }
            $hk = Get-HotkeyFromKeyArgs $e
            if (-not $hk) { return }
            $script:txtHK2.Text = $hk.Display
            $script:pendingHK2 = @{
                Modifiers      = $hk.Modifiers
                Key            = $hk.Key
                ModifierFlags  = $hk.ModifierFlags
                VirtualKey     = $hk.VirtualKey
            }
            $e.SuppressKeyPress = $true
        })

        # Fixed: allow the form to really close when the application exits
        $script:settingsForm.Add_FormClosing({
            if ($_.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
                $changed = (HotkeysDiffer $script:pendingHK1 $script:config.Hotkey1) -or
                           (HotkeysDiffer $script:pendingHK2 $script:config.Hotkey2)
                if ($changed) {
                    $result = [System.Windows.Forms.MessageBox]::Show(
                        "Do you want to save hotkey changes?",
                        "Window Centering Tool",
                        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                        [System.Windows.Forms.MessageBoxIcon]::Question)
                    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
                        if ($script:pendingHK1) { $script:config.Hotkey1 = $script:pendingHK1 } else { $script:config.Hotkey1 = $null }
                        if ($script:pendingHK2) { $script:config.Hotkey2 = $script:pendingHK2 } else { $script:config.Hotkey2 = $null }
                        Save-Config $script:config
                        Update-HotkeyRegistration
                    }
                    if ($result -eq [System.Windows.Forms.DialogResult]::Cancel) {
                        $_.Cancel = $true
                        return
                    }
                }
                # Hide instead of closing (so the form stays alive for the next show)
                $_.Cancel = $true
                $script:settingsForm.Hide()
                [WinAPI]::SetProcessWorkingSetSize((Get-Process -Id $pid).Handle, -1, -1) | Out-Null
            }
            # For ApplicationExit or WindowsShutDown we do nothing -> form closes normally
        })

        $script:settingsForm.Show()
    }
#endregion

#region Lifecycle (Restart-AsAdmin + Stop-Application)
    function Restart-AsAdmin {
        Save-Config $script:config

        if (-not $script:batFile) {
            [System.Windows.Forms.MessageBox]::Show("Cannot restart: batch file path unknown.", "Window Centering Tool", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            return
        }
        try {
            Start-Process -FilePath $script:batFile -Verb RunAs -ErrorAction Stop
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Administrator elevation was cancelled or failed. The tool will continue without admin rights.", "Window Centering Tool", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }

        # Elevation succeeded: hand off to the new (elevated) instance and tear down.
        Stop-Application
    }

    # Single teardown helper used by the Exit menu, Restart-AsAdmin, and reusable
    # from catch{}. Replaces the previously-duplicated unregister/dispose/exit blocks.
    function Stop-Application {
        try { [WinAPI]::UnregisterHotKey($script:msgWindow.Handle, $script:hotkeyIds.Primary)   | Out-Null } catch {}
        try { [WinAPI]::UnregisterHotKey($script:msgWindow.Handle, $script:hotkeyIds.Secondary) | Out-Null } catch {}
        if ($script:notifyIcon) {
            $script:notifyIcon.Visible = $false
            $script:notifyIcon.Dispose()
        }
        if ($script:msgWindow) { try { $script:msgWindow.DestroyHandle() } catch {} }
        [System.Windows.Forms.Application]::Exit()
    }
#endregion

#region Startup
    Update-HotkeyRegistration
    [System.Windows.Forms.Application]::Run()
}
catch {
    $msg = "[{0}] ERROR`r`n" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
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
    $msg += "Full Exception Details:`r`n$($_.Exception.ToString())`r`n"
    $msg += "Stack Trace:`r`n$($_.ScriptStackTrace)`r`n"
    $msg += "`r`n`$Error[0]:`r`n$($Error[0] | Out-String)`r`n"

    Set-Content -Path $errorLog -Value $msg -Encoding UTF8
    [System.Windows.Forms.MessageBox]::Show("The tool encountered an error:`r`n`r`n$($_.Exception.Message)`r`n`r`nSee $errorLog for details.", "Window Centering Tool Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)

    if (Test-Path $errorLog) { Start-Process $errorLog }
}
#endregion
:PS_END