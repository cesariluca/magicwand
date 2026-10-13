# MagicWand - select text anywhere in Windows, click the orb, get Google's answer in a card under the cursor.
# Windows PowerShell 5.1, needs -STA. No admin, no account, no API key.
#   Left-click the orb   : Google (AI Overview, compact phone layout) in a card under the cursor
#   Right-click the orb  : Google AI Mode
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
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    public static void StyleWindow(IntPtr h, bool dark) {   // Windows 11 rounded corners + dark frame
        int round = 2; DwmSetWindowAttribute(h, 33, ref round, 4);
        int d = dark ? 1 : 0; DwmSetWindowAttribute(h, 20, ref d, 4);
    }
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

# ---- 4. the wand: a little glowing orb that pops up next to the selection -------
$script:Dark = $false
try { $script:Dark = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize').AppsUseLightTheme -eq 0 } catch {}
$script:Theme = if ($script:Dark) {
    @{ BG = '#202124'; FG = '#E8EAED'; FG2 = '#9AA0A6'; LINE = '#3C4043'; SEGBG = '#2D2E31'; SEG = '#45474B'; HOVER = '#33FFFFFF'; SKEL = '#3C4043' }
} else {
    @{ BG = '#FFFFFF'; FG = '#1F1F1F'; FG2 = '#5F6368'; LINE = '#DADCE0'; SEGBG = '#F1F3F4'; SEG = '#FFFFFF'; HOVER = '#14000000'; SKEL = '#E8EAED' }
}
function Expand-Theme([string]$xamlText) {
    foreach ($k in $script:Theme.Keys) { $xamlText = $xamlText.Replace("{$k}", $script:Theme[$k]) }
    $xamlText
}

# The orb is shared by the wand and the popup header (same gradient + sparkle).
$script:OrbXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Ellipse>
    <Ellipse.Fill>
      <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
        <GradientStop Color="#4285F4" Offset="0"/>
        <GradientStop Color="#9B72CB" Offset="0.55"/>
        <GradientStop Color="#D96570" Offset="1"/>
      </LinearGradientBrush>
    </Ellipse.Fill>
  </Ellipse>
  <Ellipse Margin="2" Opacity="0.35">
    <Ellipse.Fill>
      <RadialGradientBrush GradientOrigin="0.3,0.25" Center="0.3,0.25" RadiusX="0.7" RadiusY="0.7">
        <GradientStop Color="#FFFFFFFF" Offset="0"/>
        <GradientStop Color="#00FFFFFF" Offset="1"/>
      </RadialGradientBrush>
    </Ellipse.Fill>
  </Ellipse>
  <Viewbox Margin="7">
    <Canvas Width="24" Height="24" RenderTransformOrigin="0.5,0.5">
      <Canvas.RenderTransform><RotateTransform x:Name="Spin"/></Canvas.RenderTransform>
      <Path Fill="White" Data="M12,0 C12.9,6.6 17.4,11.1 24,12 C17.4,12.9 12.9,17.4 12,24 C11.1,17.4 6.6,12.9 0,12 C6.6,11.1 11.1,6.6 12,0 Z"/>
      <Path Fill="White" Opacity="0.85" Data="M20,0 C20.3,2.2 21.8,3.7 24,4 C21.8,4.3 20.3,5.8 20,8 C19.7,5.8 18.2,4.3 16,4 C18.2,3.7 19.7,2.2 20,0 Z"/>
    </Canvas>
  </Viewbox>
</Grid>
'@
function New-Orb {
    $o = [Windows.Markup.XamlReader]::Parse($script:OrbXaml)
    @{ Root = $o; Spin = $o.FindName('Spin') }
}
function Start-Spin($orb) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 360, [TimeSpan]::FromSeconds(1.6))
    $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $orb.Spin.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $a)
}
function Stop-Spin($orb) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation(0, [TimeSpan]::FromMilliseconds(300))
    $orb.Spin.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $a)
}

[xml]$wandXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True"
        ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize" Width="52" Height="52">
  <Grid x:Name="Btn" Width="30" Height="30" Cursor="Hand" Background="Transparent" RenderTransformOrigin="0.5,0.5"
        ToolTip="Ask about this  (right-click: AI Mode)">
    <Grid.RenderTransform><ScaleTransform x:Name="Pop" ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
    <Grid.Effect><DropShadowEffect x:Name="Glow" Color="#8E6CEF" BlurRadius="14" ShadowDepth="0" Opacity="0.75"/></Grid.Effect>
    <ContentControl x:Name="OrbHost"/>
  </Grid>
</Window>
'@
$wand = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $wandXaml))
$btn  = $wand.FindName('Btn')
$script:WandPop  = $wand.FindName('Pop')
$script:WandGlow = $wand.FindName('Glow')
$script:WandOrb  = New-Orb
$wand.FindName('OrbHost').Content = $script:WandOrb.Root
$btn.Add_MouseEnter({
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation(1.15, [TimeSpan]::FromMilliseconds(140))
    $script:WandPop.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $a)
    $script:WandPop.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $a)
    $script:WandAt = [datetime]::Now
})
$btn.Add_MouseLeave({
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, [TimeSpan]::FromMilliseconds(140))
    $script:WandPop.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $a)
    $script:WandPop.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $a)
})
$wand.Left = -10000; $wand.Top = -10000
$wand.Show()
$script:WandHwnd = (New-Object System.Windows.Interop.WindowInteropHelper $wand).Handle
[MWNative]::MakeNoActivate($script:WandHwnd)
$script:Scale = [System.Windows.PresentationSource]::FromVisual($wand).CompositionTarget.TransformToDevice.M11
$script:WandPx = [int](52 * $script:Scale)

$script:WandShown = $false
$script:WandAt = [datetime]::MinValue
$script:WandX = 0; $script:WandY = 0
$script:SourceHwnd = [IntPtr]::Zero

function Show-Wand([int]$x, [int]$y) {
    $wa = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point $x, $y)).WorkingArea
    $wx = [Math]::Min([Math]::Max($x + 2, $wa.Left), $wa.Right - $script:WandPx)
    $wy = $y - $script:WandPx + [int](8 * $script:Scale)
    if ($wy -lt $wa.Top) { $wy = $y + 12 }
    $script:WandX = $wx; $script:WandY = $wy
    # HWND_TOPMOST, SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW
    [void][MWNative]::SetWindowPos($script:WandHwnd, [IntPtr](-1), $wx, $wy, 0, 0, 0x0051)
    # pop in with a little overshoot
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation(0.3, 1.0, [TimeSpan]::FromMilliseconds(260))
    $a.EasingFunction = New-Object System.Windows.Media.Animation.BackEase -Property @{ Amplitude = 0.5; EasingMode = 'EaseOut' }
    $script:WandPop.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $a)
    $script:WandPop.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $a)
    $g = New-Object System.Windows.Media.Animation.DoubleAnimation(0.45, 0.9, [TimeSpan]::FromMilliseconds(900))
    $g.AutoReverse = $true; $g.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $script:WandGlow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $g)
    $script:WandShown = $true
    $script:WandAt = [datetime]::Now
    $script:SourceHwnd = [MWNative]::GetForegroundWindow()
}
function Hide-Wand {
    if (-not $script:WandShown) { return }
    [void][MWNative]::SetWindowPos($script:WandHwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x0093)   # HIDE|NOSIZE|NOMOVE|NOACTIVATE
    $script:WandGlow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $null)
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

# ---- 6. the answer card: Google, compact, inside a modern popup under the cursor ---
$script:Lib = Join-Path $PSScriptRoot 'lib'
Add-Type -Path (Join-Path $script:Lib 'Microsoft.Web.WebView2.Core.dll')
Add-Type -Path (Join-Path $script:Lib 'Microsoft.Web.WebView2.Wpf.dll')
[Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath($script:Lib)
# Google's phone layout is the compact one: AI Overview first, no side panels.
$script:MobileUA = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36'

$popXaml = Expand-Theme @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MagicWand" WindowStyle="None" ResizeMode="CanResize" ShowInTaskbar="False" Topmost="True"
        Width="400" Height="560" MinWidth="320" MinHeight="320" Background="{BG}" BorderBrush="{LINE}" BorderThickness="1"
        FontFamily="Segoe UI Variable Text, Segoe UI">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="0" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
    <Style x:Key="Icon" TargetType="Button">
      <Setter Property="Width" Value="30"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Foreground" Value="{FG2}"/>
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="8" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="{HOVER}"/>
                <Setter Property="Foreground" Value="{FG}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{FG2}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" CornerRadius="11" Padding="12,4" Background="Transparent">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="{SEG}"/>
                <Setter Property="Foreground" Value="{FG}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid x:Name="Header" Background="Transparent" Margin="12,10,8,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <ContentControl x:Name="OrbHost" Width="30" Height="30" VerticalAlignment="Top" Margin="0,2,0,0"/>
      <StackPanel Grid.Column="1" Margin="10,0,6,0" VerticalAlignment="Center">
        <TextBlock x:Name="QueryText" FontSize="14" FontWeight="SemiBold" Foreground="{FG}" TextWrapping="Wrap"
                   TextTrimming="CharacterEllipsis" MaxHeight="40"/>
        <TextBlock x:Name="Status" FontSize="11.5" Foreground="{FG2}" Margin="0,1,0,0"/>
      </StackPanel>
      <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Top">
        <Button x:Name="BtnPin" Style="{StaticResource Icon}" Content="&#xE718;" ToolTip="Keep open"/>
        <Button x:Name="BtnOpen" Style="{StaticResource Icon}" Content="&#xE8A7;" ToolTip="Open in browser"/>
        <Button x:Name="BtnClose" Style="{StaticResource Icon}" Content="&#xE711;" ToolTip="Close (Esc)"/>
      </StackPanel>
    </Grid>
    <Grid Grid.Row="1" x:Name="Body">
      <StackPanel x:Name="Skeleton" Margin="18,8,18,0">
        <StackPanel.Triggers>
          <EventTrigger RoutedEvent="Loaded">
            <BeginStoryboard>
              <Storyboard>
                <DoubleAnimation Storyboard.TargetProperty="Opacity" From="1" To="0.35" Duration="0:0:0.8"
                                 AutoReverse="True" RepeatBehavior="Forever"/>
              </Storyboard>
            </BeginStoryboard>
          </EventTrigger>
        </StackPanel.Triggers>
        <Border Height="12" CornerRadius="6" Background="{SKEL}" Margin="0,6" Width="140" HorizontalAlignment="Left"/>
        <Border Height="12" CornerRadius="6" Background="{SKEL}" Margin="0,6"/>
        <Border Height="12" CornerRadius="6" Background="{SKEL}" Margin="0,6,40,6"/>
        <Border Height="12" CornerRadius="6" Background="{SKEL}" Margin="0,6,90,6"/>
        <Border Height="12" CornerRadius="6" Background="{SKEL}" Margin="0,22,0,6"/>
        <Border Height="12" CornerRadius="6" Background="{SKEL}" Margin="0,6,60,6"/>
        <Border Height="12" CornerRadius="6" Background="{SKEL}" Margin="0,6,130,6"/>
      </StackPanel>
    </Grid>
    <Grid Grid.Row="2" Margin="10,6,10,10">
      <Border CornerRadius="13" Background="{SEGBG}" Padding="2" HorizontalAlignment="Left">
        <StackPanel Orientation="Horizontal">
          <RadioButton x:Name="ModeSearch" Style="{StaticResource Seg}" Content="AI Overview" GroupName="mode" IsChecked="True"/>
          <RadioButton x:Name="ModeAi" Style="{StaticResource Seg}" Content="AI Mode" GroupName="mode"/>
        </StackPanel>
      </Border>
      <TextBlock HorizontalAlignment="Right" VerticalAlignment="Center" FontSize="11" Foreground="{FG2}" Text="Esc to close"/>
    </Grid>
  </Grid>
</Window>
'@
$pop = [Windows.Markup.XamlReader]::Parse($popXaml)
$P = @{}
foreach ($n in 'Header', 'OrbHost', 'QueryText', 'Status', 'BtnPin', 'BtnOpen', 'BtnClose', 'Body', 'Skeleton', 'ModeSearch', 'ModeAi') {
    $P[$n] = $pop.FindName($n)
}
$script:PopOrb = New-Orb
$P.OrbHost.Content = $script:PopOrb.Root

$web = New-Object Microsoft.Web.WebView2.Wpf.WebView2
$web.Visibility = 'Hidden'
$web.DefaultBackgroundColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.BG)
$cp = New-Object Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties
$cp.UserDataFolder = Join-Path $env:LOCALAPPDATA 'MagicWand\WebView2'
$web.CreationProperties = $cp
[void]$P.Body.Children.Add($web)

$script:WebReady   = $false
$script:PendingUrl = $null
$script:PopupShown = $false
$script:Pinned     = $false
$script:Populating = $false
$script:Query      = ''
$script:PopHwnd    = [IntPtr]::Zero

# Skip Google's own logo + search box (our header already shows the query).
$script:TidyJs = '(function(){var f=document.querySelector("form[action=' + "'/search'" + ']");if(f){var b=f.getBoundingClientRect().bottom+window.scrollY;if(b>0&&b<400)window.scrollTo(0,b);}})();'
function Show-WebContent {
    [void]$web.CoreWebView2.ExecuteScriptAsync($script:TidyJs)
    $web.Visibility = 'Visible'
    $P.Skeleton.Visibility = 'Collapsed'
    Stop-Spin $script:PopOrb
    $P.Status.Text = if ($P.ModeAi.IsChecked) { 'Google AI Mode' } else { 'Google ' + $script:Dot + ' AI Overview' }
}
$script:Dot = [char]0x00B7

$web.Add_CoreWebView2InitializationCompleted({
    param($s, $e)
    if (-not $e.IsSuccess) { Write-Log "webview2: $($e.InitializationException.Message)"; return }
    $c = $web.CoreWebView2
    $c.Settings.UserAgent = $script:MobileUA
    $c.Settings.IsStatusBarEnabled = $false
    $c.Settings.AreDevToolsEnabled = $false
    $web.ZoomFactor = 0.9
    $c.Profile.PreferredColorScheme = if ($script:Dark) { 'Dark' } else { 'Light' }
    $c.Add_NewWindowRequested({
        param($s2, $e2)
        $e2.Handled = $true
        if ($e2.Uri -match '^https?://') { Start-Process $e2.Uri }
    })
    $c.Add_DOMContentLoaded({ Show-WebContent })
    $script:WebReady = $true
    if ($script:PendingUrl) { $u = $script:PendingUrl; $script:PendingUrl = $null; $c.Navigate($u) }
    if (-not $script:PopupShown) { $pop.Hide() }   # warm-up done
    if ($env:MAGICWAND_DEMO) { try { Open-Lookup $env:MAGICWAND_DEMO $false } catch { Write-Log "demo: $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)" } }   # for screenshots/tests
})

$pop.Add_SourceInitialized({
    $script:PopHwnd = (New-Object System.Windows.Interop.WindowInteropHelper $pop).Handle
    [MWNative]::StyleWindow($script:PopHwnd, $script:Dark)
})

function Get-CleanText([string]$text) {
    $t = $text -replace '(\w)-\s*\r?\n\s*(\w)', '$1$2'      # PDF hyphenation
    ($t -replace '\s+', ' ').Trim().Trim('.', ',', ';', ':', '"', "'", '(', ')', '[', ']')
}
function ConvertTo-Query([string]$clean) {
    $words = $clean.Split(' ')
    if ($words.Count -le 6) { return "what is $clean" }
    'explain: ' + (($words | Select-Object -First 30) -join ' ')
}
function Get-SearchUrl {
    $url = 'https://www.google.com/search?q=' + [uri]::EscapeDataString($script:Query)
    $url += '&hl=' + [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName   # Google guesses from location otherwise
    if ($P.ModeAi.IsChecked) { $url += '&udm=50' }
    $url
}

function Start-Search {
    $url = Get-SearchUrl
    $web.Visibility = 'Hidden'
    $P.Skeleton.Visibility = 'Visible'
    Start-Spin $script:PopOrb
    $P.Status.Text = 'Thinking...'
    if ($script:WebReady) { $web.CoreWebView2.Navigate($url) } else { $script:PendingUrl = $url }
}

function Set-PopupPosition {
    $p = New-Object MWNative+POINT
    [void][MWNative]::GetCursorPos([ref]$p)
    $s = $script:Scale
    $wa = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point $p.X, $p.Y)).WorkingArea
    $w = [Math]::Min([int]($pop.Width * $s), $wa.Width - 16)
    $h = [Math]::Min([int]($pop.Height * $s), $wa.Height - 16)
    $x = [Math]::Min([Math]::Max($p.X - [int](36 * $s), $wa.Left + 8), $wa.Right - $w - 8)
    $y = $p.Y + [int](24 * $s)                                  # just under the cursor
    if ($y + $h -gt $wa.Bottom - 8) { $y = [Math]::Max($wa.Top + 8, $p.Y - [int](24 * $s) - $h) }
    $pop.Width = $w / $s; $pop.Height = $h / $s
    $pop.Left = $x / $s; $pop.Top = $y / $s
}

function Open-Lookup([string]$text, [bool]$aiMode) {
    $clean = Get-CleanText $text
    if (-not $clean) { return }
    $script:Query = ConvertTo-Query $clean
    $P.QueryText.Text = if ($clean.Length -gt 140) { $clean.Substring(0, 140) + '...' } else { $clean }
    $script:Populating = $true
    if ($aiMode) { $P.ModeAi.IsChecked = $true } else { $P.ModeSearch.IsChecked = $true }
    $script:Populating = $false
    if (-not $script:PopupShown) { Set-PopupPosition }
    Start-Search
    $pop.ShowActivated = $true
    $pop.Show()
    [void]$pop.Activate()
    $script:PopupShown = $true
}

function Hide-Popup {
    if (-not $script:PopupShown) { return }
    $pop.Hide()
    $script:PopupShown = $false
}

function Test-InPopup($p) {
    $r = New-Object MWNative+RECT
    if (-not [MWNative]::GetWindowRect($script:PopHwnd, [ref]$r)) { return $false }
    $p.X -ge $r.Left -and $p.X -lt $r.Right -and $p.Y -ge $r.Top -and $p.Y -lt $r.Bottom
}

$P.BtnClose.Add_Click({ Hide-Popup })
$P.BtnOpen.Add_Click({
    $u = if ($web.Source -and $web.Source.AbsoluteUri -match '^https?://') { $web.Source.AbsoluteUri } else { Get-SearchUrl }
    Start-Process $u
    if (-not $script:Pinned) { Hide-Popup }
})
$P.BtnPin.Add_Click({
    $script:Pinned = -not $script:Pinned
    $P.BtnPin.Content = if ($script:Pinned) { [string][char]0xE840 } else { [string][char]0xE718 }
    $P.BtnPin.ToolTip = if ($script:Pinned) { 'Pinned: stays open' } else { 'Keep open' }
})
$P.ModeSearch.Add_Checked({ if (-not $script:Populating -and $script:Query) { Start-Search } })
$P.ModeAi.Add_Checked({ if (-not $script:Populating -and $script:Query) { Start-Search } })
$P.Header.Add_MouseLeftButtonDown({ try { $pop.DragMove() } catch {} })

function Invoke-Lookup([bool]$aiMode) {
    Hide-Wand
    $text = Get-SelectedText
    if ($text -and $text.Trim()) { Open-Lookup $text $aiMode }
}

$btn.Add_MouseLeftButtonUp({ try { Invoke-Lookup $false } catch { Write-Log "lookup: $($_.Exception.Message)" } })
$btn.Add_MouseRightButtonUp({ try { Invoke-Lookup $true } catch { Write-Log "lookup: $($_.Exception.Message)" } })

# Warm up WebView2 off-screen so the first lookup is instant.
$pop.ShowActivated = $false
$pop.Left = -20000; $pop.Top = -20000
$pop.Show()
[void]$pop.Dispatcher.BeginInvoke([Action]{   # needs the event loop running
    try { [void]$web.EnsureCoreWebView2Async($null) } catch { Write-Log "webview2: $($_.Exception.Message)" }
}, [System.Windows.Threading.DispatcherPriority]::Background)

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
    if ($script:PopupShown -and [MWNative]::IsDown(0x1B) -and [MWNative]::GetForegroundWindow() -eq $script:PopHwnd) { Hide-Popup }

    if ($down -and -not $script:WasDown) {                       # press
        if ($script:PopupShown -and -not $script:Pinned -and -not (Test-InPopup $p)) { Hide-Popup }
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
Write-Log "started (scale: $script:Scale, dark: $script:Dark)"
[System.Windows.Threading.Dispatcher]::Run()
