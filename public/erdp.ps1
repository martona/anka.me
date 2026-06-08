#####################################################################################################
Write-Output "Enabling Remote Desktop Protocol (RDP)..."
# 0. Enforce Network Level Authentication (NLA)
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name "UserAuthentication" -Value 1 -Type DWord -Force
# 1. Turn on RDP in the Registry
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0 -Type DWord -Force
# 2. Enable the Remote Desktop rules in Windows Firewall
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
# 3. Ensure the Terminal Services service is set to start automatically
Set-Service -Name TermService -StartupType Automatic
Start-Service -Name TermService -ErrorAction SilentlyContinue
