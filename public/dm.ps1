param (
    # Dark mode on by default; pass -DarkMode $false for light.
    [bool] $DarkMode = $true
)

# ---------------------------------------------------------------------------
#  pretty, uniform console output
# ---------------------------------------------------------------------------
function Section ($m) {
    Write-Host ''
    Write-Host "  $m" -ForegroundColor Green
    Write-Host ('  ' + ('-' * $m.Length)) -ForegroundColor DarkGray
}
function Step ($m) { Write-Host '[*] ' -ForegroundColor Cyan   -NoNewline; Write-Host $m -ForegroundColor Gray }
function Ok   ($m) { Write-Host '[+] ' -ForegroundColor Green  -NoNewline; Write-Host $m -ForegroundColor DarkGray }
function Warn ($m) { Write-Host '[!] ' -ForegroundColor Yellow -NoNewline; Write-Host $m -ForegroundColor Gray }
function Fail ($m) { Write-Host '[x] ' -ForegroundColor Red    -NoNewline; Write-Host $m -ForegroundColor Gray }
function Note ($m) { Write-Host '    '                         -NoNewline; Write-Host $m -ForegroundColor DarkGray }

$mode = if ($DarkMode) { 'dark' } else { 'light' }
Section "Switching Windows to $mode mode"

$RegPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
# Windows is inverted here: 0 = dark theme, 1 = light theme.
$ThemeValue = if ($DarkMode) { 0 } else { 1 }

Step 'Theming the system (taskbar, Start, tray)'
Set-ItemProperty -Path $RegPath -Name 'SystemUsesLightTheme' -Value $ThemeValue

Step 'Theming apps (Explorer, Settings, standard apps)'
Set-ItemProperty -Path $RegPath -Name 'AppsUseLightTheme' -Value $ThemeValue

Step 'Broadcasting the change to Windows'
$CSharp = @'
using System;
using System.Runtime.InteropServices;
public class Theme {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
'@
Add-Type -TypeDefinition $CSharp -ErrorAction SilentlyContinue

$HWND_BROADCAST   = [IntPtr] 0xffff
$WM_SETTINGCHANGE = 0x001A
$SMTO_ABORTIFHUNG = 0x0002
$result           = [UIntPtr]::Zero
[Theme]::SendMessageTimeout(
    $HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero,
    'ImmersiveColorSet', $SMTO_ABORTIFHUNG, 5000, [ref] $result) | Out-Null

Ok "Windows is now in $mode mode."
