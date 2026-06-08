#####################################################################################################
Write-Output "Setting dark mode wallpaper..."

Write-Output "Downloading fresh wallpaper..."
$Url="https://raw.githubusercontent.com/martona/wallpapers/main/static/apple/26-Tahoe-Beach-Night.png"
$Destination = "$env:PUBLIC\Pictures\deployment_wallpaper.jpg"
$UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -UserAgent $UserAgent

$WallpaperPath = $Destination
# 1. Compile a tiny C# class in memory to access the Windows API
$CsharpCode = @'
using System.Runtime.InteropServices;
public class Desktop {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
Add-Type -TypeDefinition $CsharpCode -ErrorAction SilentlyContinue

# 2. Update the Registry
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name Wallpaper -Value $WallpaperPath

# 3. Call the API to force Explorer to redraw the desktop instantly
# 0x0014 = SPI_SETDESKWALLPAPER, 3 = Update INI file and broadcast change
[Desktop]::SystemParametersInfo(0x0014, 0, $WallpaperPath, 3)
