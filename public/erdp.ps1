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

Section 'Enabling Remote Desktop (RDP)'

# Writes to HKLM, the firewall, and services - all need elevation.
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Fail 'Administrator rights required - re-run from an elevated PowerShell.'
    return
}

Step 'Enforcing Network Level Authentication'
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 1 -Type DWord -Force

Step 'Allowing incoming RDP connections'
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0 -Type DWord -Force

Step 'Opening the Remote Desktop firewall rules'
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' | Out-Null

Step 'Setting the Remote Desktop service to start automatically'
Set-Service -Name TermService -StartupType Automatic
Start-Service -Name TermService -ErrorAction SilentlyContinue

Ok 'RDP is enabled - this machine now accepts remote connections.'
