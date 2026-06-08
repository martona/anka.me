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

Section 'Setting the desktop wallpaper'

$Url         = 'https://raw.githubusercontent.com/martona/wallpapers/main/static/apple/26-Tahoe-Beach-Night.png'
$Destination = "$env:PUBLIC\Pictures\deployment_wallpaper.png"
$UserAgent   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'

Step 'Downloading the wallpaper'
Note $Url
Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -UserAgent $UserAgent

# Compile a tiny C# shim so we can call the desktop API.
Step 'Compiling the desktop API shim'
$CSharp = @'
using System.Runtime.InteropServices;
public class Desktop {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
Add-Type -TypeDefinition $CSharp -ErrorAction SilentlyContinue

Step 'Recording the wallpaper in the registry'
Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $Destination

Step 'Telling Explorer to redraw the desktop'
# 0x0014 = SPI_SETDESKWALLPAPER; flag 3 = update the INI file and broadcast.
[Desktop]::SystemParametersInfo(0x0014, 0, $Destination, 3) | Out-Null

Ok 'Wallpaper applied.'
