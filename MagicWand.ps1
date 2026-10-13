# MagicWand - select text anywhere in Windows, click the wand, get Google's answer in a popup.
# Windows PowerShell 5.1, needs -STA. No admin, no account, no API key.
#   Left-click the wand  : Google search (AI Overview) in a small popup next to the cursor
#   Right-click the wand : Google AI Mode
#   Tray icon click      : look up what is on the clipboard (fallback for apps where no wand shows)
# Script must stay pure ASCII.

$ErrorActionPreference = 'Stop'

# ---- 1. single instance / STA -------------------------------------------------
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
    exit
}
$script:Mutex = New-Object Threading.Mutex($false, 'Local\MagicWand.SingleInstance')
if (-not $script:Mutex.WaitOne(0)) { exit }

$script:LogFile = Join-Path $env:LOCALAPPDATA 'MagicWand\log.txt'
function Write-Log([string]$msg) {
    try {
        $dir = Split-Path $script:LogFile
        if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory $dir) }
        Add-Content -Path $script:LogFile -Value ("{0:s} {1}" -f (Get-Date), $msg)
    } catch {}
}

# ---- 2. settings --------------------------------------------------------------
$script:PopupW      = 540     # popup size in DIPs
$script:PopupH      = 720
$script:WandTimeout = 4.0     # seconds the wand stays visible
$script:DoubleCopy  = $false   # Ctrl+C twice = look up the clipboard (off: DeepL uses the same gesture)
# Apps whose text cursor is not the system I-beam: any drag / double-click shows the wand.
$script:AnyDragApps = @('acrord32', 'acrobat', 'foxitpdfreader', 'foxitphantompdf', 'sumatrapdf', 'winword', 'powerpnt', 'outlook', 'onenote', 'excel')
# Terminals: Ctrl+C would interrupt, use Ctrl+Insert instead.
$script:TerminalApps = @('windowsterminal', 'conhost', 'cmd', 'powershell', 'pwsh', 'mintty', 'putty', 'wsl')

# ---- 3. native helpers ---------------------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MWNative {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] struct CURSORINFO { public int cbSize; public int flags; public IntPtr hCursor; public POINT pt; }
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool GetCursorInfo(ref CURSORINFO ci);
    [DllImport("user32.dll")] static extern IntPtr LoadCursor(IntPtr h, IntPtr id);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] public static extern uint GetDoubleClickTime();
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    static readonly IntPtr IBeam = LoadCursor(IntPtr.Zero, new IntPtr(32513));

    public static bool IsDown(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }
    public static bool IsIBeam() {
        CURSORINFO ci = new CURSORINFO(); ci.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
        return GetCursorInfo(ref ci) && ci.hCursor == IBeam;
    }
    public static uint WindowPid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
    public static void MakeNoActivate(IntPtr h) {   // WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
        SetWindowLong(h, -20, GetWindowLong(h, -20) | 0x08000000 | 0x80);
    }
    public static void SendCopy(bool ctrlInsert) {
        byte k = ctrlInsert ? (byte)0x2D : (byte)0x43;
        uint ext = ctrlInsert ? 1u : 0u;
        keybd_event(0x11, 0, 0, UIntPtr.Zero);
        keybd_event(k, 0, ext, UIntPtr.Zero);
        keybd_event(k, 0, ext | 2, UIntPtr.Zero);
        keybd_event(0x11, 0, 2, UIntPtr.Zero);
    }
}
'@

# ---- 4. the wand window --------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True"
        ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize" Width="40" Height="40">
  <Border x:Name="Btn" Margin="4" CornerRadius="16" Background="#FFFFFF" BorderBrush="#DADCE0" BorderThickness="1"
          Cursor="Hand" ToolTip="Look it up on Google  (right-click: AI Mode)">
    <Border.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="1" Opacity="0.3"/></Border.Effect>
    <Viewbox Width="20" Height="20">
      <Canvas Width="20" Height="20">
        <Line X1="3" Y1="17" X2="12" Y2="8" Stroke="#5F6368" StrokeThickness="2.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
        <Path Fill="#1A73E8" Data="M15,1 L16.2,3.8 L19,5 L16.2,6.2 L15,9 L13.8,6.2 L11,5 L13.8,3.8 Z"/>
        <Path Fill="#FBBC04" Data="M6,2 L6.6,3.4 L8,4 L6.6,4.6 L6,6 L5.4,4.6 L4,4 L5.4,3.4 Z"/>
        <Path Fill="#EA4335" Data="M18,12 L18.5,13.5 L20,14 L18.5,14.5 L18,16 L17.5,14.5 L16,14 L17.5,13.5 Z"/>
      </Canvas>
    </Viewbox>
  </Border>
</Window>
'@
$wand = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$btn  = $wand.FindName('Btn')
$wand.Left = -10000; $wand.Top = -10000
$wand.Show()
$script:WandHwnd = (New-Object System.Windows.Interop.WindowInteropHelper $wand).Handle
[MWNative]::MakeNoActivate($script:WandHwnd)
$script:Scale = [System.Windows.PresentationSource]::FromVisual($wand).CompositionTarget.TransformToDevice.M11
$script:WandPx = [int](40 * $script:Scale)

$script:WandShown = $false
$script:WandAt = [datetime]::MinValue
$script:WandX = 0; $script:WandY = 0
$script:SourceHwnd = [IntPtr]::Zero

function Show-Wand([int]$x, [int]$y) {
    $wa = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point $x, $y)).WorkingArea
    $wx = [Math]::Min([Math]::Max($x + 8, $wa.Left), $wa.Right - $script:WandPx)
    $wy = $y - $script:WandPx - 6
    if ($wy -lt $wa.Top) { $wy = $y + 16 }
    $script:WandX = $wx; $script:WandY = $wy
    # HWND_TOPMOST, SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW
    [void][MWNative]::SetWindowPos($script:WandHwnd, [IntPtr](-1), $wx, $wy, 0, 0, 0x0051)
    $script:WandShown = $true
    $script:WandAt = [datetime]::Now
    $script:SourceHwnd = [MWNative]::GetForegroundWindow()
}
function Hide-Wand {
    if (-not $script:WandShown) { return }
    [void][MWNative]::SetWindowPos($script:WandHwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x0093)   # HIDE|NOSIZE|NOMOVE|NOACTIVATE
    $script:WandShown = $false
}
function Test-OverWand($p) {
    $script:WandShown -and $p.X -ge $script:WandX -and $p.X -lt ($script:WandX + $script:WandPx) -and
        $p.Y -ge $script:WandY -and $p.Y -lt ($script:WandY + $script:WandPx)
}

# ---- 5. grab the selection via the clipboard (and put the old clipboard back) ---
function Get-ProcName([IntPtr]$hwnd) {
    try { (Get-Process -Id ([MWNative]::WindowPid($hwnd))).ProcessName.ToLowerInvariant() } catch { '' }
}

function Get-SelectedText {
    $fg = [MWNative]::GetForegroundWindow()
    if ([MWNative]::WindowPid($fg) -eq $PID) { return '' }
    $saved = $null
    try {
        $src = [System.Windows.Clipboard]::GetDataObject()
        if ($src) {
            $saved = New-Object System.Windows.DataObject
            $any = $false
            foreach ($f in $src.GetFormats($false)) {
                try { $v = $src.GetData($f); if ($null -ne $v) { $saved.SetData($f, $v); $any = $true } } catch {}
            }
            if (-not $any) { $saved = $null }
        }
    } catch { $saved = $null }

    $seq = [MWNative]::GetClipboardSequenceNumber()
    [MWNative]::SendCopy($script:TerminalApps -contains (Get-ProcName $fg))
    $deadline = [datetime]::Now.AddMilliseconds(900)
    while ([MWNative]::GetClipboardSequenceNumber() -eq $seq -and [datetime]::Now -lt $deadline) { Start-Sleep -Milliseconds 25 }
    if ([MWNative]::GetClipboardSequenceNumber() -eq $seq) { Write-Log "no copy from $(Get-ProcName $fg)"; return '' }   # nothing copied: leave clipboard alone

    $text = ''
    for ($i = 0; $i -lt 6 -and -not $text; $i++) {
        try { $text = [System.Windows.Clipboard]::GetText() } catch { Start-Sleep -Milliseconds 40 }
    }
    try {
        if ($saved) { [System.Windows.Clipboard]::SetDataObject($saved, $true) } else { [System.Windows.Clipboard]::Clear() }
    } catch { Write-Log "clipboard restore failed: $($_.Exception.Message)" }
    $text
}

# ---- 6. open Google in a small app window next to the cursor ---------------------
function Get-BrowserPath {
    foreach ($exe in 'msedge.exe', 'chrome.exe') {
        foreach ($root in 'HKCU:', 'HKLM:') {
            try {
                $p = (Get-ItemProperty "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exe" -ErrorAction Stop).'(default)'
                if ($p -and (Test-Path $p)) { return $p }
            } catch {}
        }
    }
    $null
}
$script:Browser = Get-BrowserPath
$script:PendingMove = $null

function ConvertTo-Query([string]$text) {
    $t = $text -replace '(\w)-\s*\r?\n\s*(\w)', '$1$2'      # PDF hyphenation
    $t = ($t -replace '\s+', ' ').Trim().Trim('.', ',', ';', ':', '"', "'", '(', ')', '[', ']')
    if (-not $t) { return '' }
    $words = $t.Split(' ')
    if ($words.Count -le 6) { return "what is $t" }
    'explain: ' + (($words | Select-Object -First 30) -join ' ')
}

function Open-Lookup([string]$text, [bool]$aiMode) {
    $q = ConvertTo-Query $text
    if (-not $q) { return }
    $url = 'https://www.google.com/search?q=' + [uri]::EscapeDataString($q)
    if ($aiMode) { $url += '&udm=50' }

    $p = New-Object MWNative+POINT
    [void][MWNative]::GetCursorPos([ref]$p)
    $wa = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point $p.X, $p.Y)).WorkingArea
    $w = [Math]::Min([int]($script:PopupW * $script:Scale), $wa.Width)
    $h = [Math]::Min([int]($script:PopupH * $script:Scale), $wa.Height)
    $x = if ($p.X + 24 + $w -le $wa.Right) { $p.X + 24 } else { [Math]::Max($wa.Left, $p.X - 24 - $w) }
    $y = [Math]::Min([Math]::Max($wa.Top, $p.Y - [int]($h / 3)), $wa.Bottom - $h)

    if (-not $script:Browser) { Start-Process $url; return }
    $bargs = @("--app=`"$url`"", "--window-size=$($script:PopupW),$($script:PopupH)",
              "--window-position=$([int]($x / $script:Scale)),$([int]($y / $script:Scale))")
    # Edge may hand the URL to an already running process, which ignores the size switches:
    # move the new window ourselves once it comes to the front.
    $script:PendingMove = @{ Before = [MWNative]::GetForegroundWindow(); X = $x; Y = $y; W = $w; H = $h
                             Deadline = [datetime]::Now.AddSeconds(5) }
    Start-Process -FilePath $script:Browser -ArgumentList $bargs
}

function Invoke-Lookup([bool]$aiMode) {
    Hide-Wand
    $text = Get-SelectedText
    if ($text -and $text.Trim()) { Open-Lookup $text $aiMode }
}

$btn.Add_MouseLeftButtonUp({ try { Invoke-Lookup $false } catch { Write-Log "lookup: $($_.Exception.Message)" } })
$btn.Add_MouseRightButtonUp({ try { Invoke-Lookup $true } catch { Write-Log "lookup: $($_.Exception.Message)" } })

# ---- 7. watch the mouse: drag or double-click over text shows the wand -----------
$script:Paused   = $false
$script:WasDown  = $false
$script:DownPt   = $null
$script:DownBeam = $false
$script:LastClickAt = [datetime]::MinValue
$script:LastClickPt = $null
$script:CopyHeld = $false
$script:LastCopyAt = [datetime]::MinValue
$script:CopyLookupAt = $null
$script:CopySeq = 0
$script:DblMs = [MWNative]::GetDoubleClickTime()

function Test-TextTarget([bool]$beamNow) {
    if ($script:DownBeam -or $beamNow) { return $true }
    $script:AnyDragApps -contains (Get-ProcName ([MWNative]::GetForegroundWindow()))
}

function Invoke-Tick {
    $p = New-Object MWNative+POINT
    [void][MWNative]::GetCursorPos([ref]$p)
    $down = [MWNative]::IsDown(0x01)

    if ($script:PendingMove) {
        $m = $script:PendingMove
        $fg = [MWNative]::GetForegroundWindow()
        if ($fg -ne $m.Before -and $fg -ne [IntPtr]::Zero -and (Get-ProcName $fg) -match '^(msedge|chrome)$') {
            [void][MWNative]::SetWindowPos($fg, [IntPtr]::Zero, $m.X, $m.Y, $m.W, $m.H, 0x0004)   # NOZORDER
            $script:PendingMove = $null
        } elseif ([datetime]::Now -gt $m.Deadline) { $script:PendingMove = $null }
    }

    # Ctrl+C twice (within 600 ms): look up what the user just copied
    $cDown = [MWNative]::IsDown(0x11) -and [MWNative]::IsDown(0x43)
    if ($script:DoubleCopy -and $cDown -and -not $script:CopyHeld -and -not $script:Paused) {
        $now = [datetime]::Now
        if (($now - $script:LastCopyAt).TotalMilliseconds -le 600) {
            $script:LastCopyAt = [datetime]::MinValue
            $script:CopyLookupAt = $now.AddMilliseconds(1000)     # give up if the clipboard never changes
        } else { $script:LastCopyAt = $now; $script:CopySeq = [MWNative]::GetClipboardSequenceNumber() }
    }
    $script:CopyHeld = $cDown
    if ($script:CopyLookupAt -and -not [MWNative]::IsDown(0x11)) {
        $changed = [MWNative]::GetClipboardSequenceNumber() -ne $script:CopySeq
        if ($changed -or [datetime]::Now -ge $script:CopyLookupAt) {
            $script:CopyLookupAt = $null
            if ($changed) {
                Start-Sleep -Milliseconds 50                      # apps may write several formats
                Hide-Wand
                $text = ''
                try { $text = [System.Windows.Clipboard]::GetText() } catch {}
                if ($text -and $text.Trim()) { Open-Lookup $text $false }
            }
        }
    }
    if ($down -and -not $script:WasDown) {                       # press
        if (-not (Test-OverWand $p)) {
            Hide-Wand
            $script:DownPt = $p
            $script:DownBeam = [MWNative]::IsIBeam()
        } else { $script:DownPt = $null }
    } elseif (-not $down -and $script:WasDown -and $script:DownPt) { # release
        $fgPid = [MWNative]::WindowPid([MWNative]::GetForegroundWindow())
        if (-not $script:Paused -and $fgPid -ne $PID) {
            $dx = $p.X - $script:DownPt.X; $dy = $p.Y - $script:DownPt.Y
            $now = [datetime]::Now
            if (($dx * $dx + $dy * $dy) -ge 64) {
                if (Test-TextTarget ([MWNative]::IsIBeam())) { Show-Wand $p.X $p.Y }
                $script:LastClickAt = [datetime]::MinValue
            } else {
                $lc = $script:LastClickPt
                $isMulti = $lc -and ($now - $script:LastClickAt).TotalMilliseconds -le $script:DblMs -and
                           [Math]::Abs($p.X - $lc.X) -le 6 -and [Math]::Abs($p.Y - $lc.Y) -le 6
                if ($isMulti -and (Test-TextTarget ([MWNative]::IsIBeam()))) { Show-Wand $p.X $p.Y }
                elseif ([MWNative]::IsDown(0x10) -and (Test-TextTarget ([MWNative]::IsIBeam()))) { Show-Wand $p.X $p.Y }  # shift+click
                $script:LastClickAt = $now; $script:LastClickPt = $p
            }
        }
        $script:DownPt = $null
    }
    $script:WasDown = $down

    if ($script:WandShown -and -not $btn.IsMouseOver) {
        if (([datetime]::Now - $script:WandAt).TotalSeconds -gt $script:WandTimeout -or
            [MWNative]::GetForegroundWindow() -ne $script:SourceHwnd) { Hide-Wand }
    }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(25)
$timer.Add_Tick({ try { Invoke-Tick } catch { Write-Log "tick: $($_.Exception.Message)" } })

# ---- 8. tray icon -----------------------------------------------------------------
function New-WandIcon {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(95, 99, 104)), 4
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $g.DrawLine($pen, 5, 27, 19, 13)
    $star = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF 24, 1), (New-Object System.Drawing.PointF 26, 6), (New-Object System.Drawing.PointF 31, 8),
        (New-Object System.Drawing.PointF 26, 10), (New-Object System.Drawing.PointF 24, 15), (New-Object System.Drawing.PointF 22, 10),
        (New-Object System.Drawing.PointF 17, 8), (New-Object System.Drawing.PointF 22, 6))
    $g.FillPolygon((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(26, 115, 232))), $star)
    $g.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-WandIcon
$tray.Text = 'MagicWand - click to look up the clipboard'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miPause = $menu.Items.Add('Pause')
$miPause.Add_Click({
    $script:Paused = -not $script:Paused
    $miPause.Text = if ($script:Paused) { 'Resume' } else { 'Pause' }
    if ($script:Paused) { Hide-Wand }
})
[void]$menu.Items.Add('Quit').Add_Click({
    $timer.Stop()
    $tray.Visible = $false
    $tray.Dispose()
    $wand.Close()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})
$tray.ContextMenuStrip = $menu
$tray.Add_MouseClick({ param($s, $e)
    if ($e.Button -ne 'Left') { return }
    try { $t = [System.Windows.Clipboard]::GetText(); if ($t -and $t.Trim()) { Open-Lookup $t $false } } catch { Write-Log "tray: $($_.Exception.Message)" }
})
$tray.Visible = $true

$script:WandShown = $true; Hide-Wand   # start hidden
$timer.Start()
Write-Log "started (browser: $script:Browser, scale: $script:Scale)"
[System.Windows.Threading.Dispatcher]::Run()
