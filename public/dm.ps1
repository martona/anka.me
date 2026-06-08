param (
    # Defaults to $true if no parameter is passed
    [bool]$DarkMode = $true 
)

$RegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"

# Windows logic is inverted: 0 means Dark (Light theme is off), 1 means Light
$ThemeValue = if ($DarkMode) { 0 } else { 1 }

Write-Output "Setting Dark Mode enabled: $DarkMode"

# SystemUsesLightTheme controls the Taskbar, Start Menu, and Action Center
Set-ItemProperty -Path $RegPath -Name "SystemUsesLightTheme" -Value $ThemeValue

# AppsUseLightTheme controls Explorer windows, Settings, and standard apps
Set-ItemProperty -Path $RegPath -Name "AppsUseLightTheme" -Value $ThemeValue

$CsharpCode = @'
using System;
using System.Runtime.InteropServices;
public class Theme {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
'@
Add-Type -TypeDefinition $CsharpCode -ErrorAction SilentlyContinue

# Broadcast the change to the OS
$HWND_BROADCAST = [IntPtr]0xffff
$WM_SETTINGCHANGE = 0x001A
$SMTO_ABORTIFHUNG = 0x0002
$result = [UIntPtr]::Zero

Write-Output "Broadcasting theme change to Windows..."
[Theme]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, "ImmersiveColorSet", $SMTO_ABORTIFHUNG, 5000, [ref]$result) | Out-Null
