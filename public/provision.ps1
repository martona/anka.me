<#
  provision.ps1 - one-off machine provisioning steps
  ---------------------------------------------------
  Run elevated (Windows PowerShell 5.1). With no args it shows a menu; with
  --all it runs every step in order, unattended. The rename step is menu-only
  unless a new name is supplied with --name; the local-admin step is menu-only
  (it always prompts for a name and password).

      powershell -ExecutionPolicy Bypass -File .\provision.ps1
      powershell -ExecutionPolicy Bypass -File .\provision.ps1 --all [--name NEWPC]

  Or straight off a site, no download (execution policy does not gate iex):

      irm https://anka.me/provision.ps1 | iex
      & ([scriptblock]::Create((irm https://anka.me/provision.ps1))) --all

  Most steps need administrator rights (the cert, execution-policy and dark
  mode steps are per-user), but the script requires elevation overall.
  DESTRUCTIVE: deletes restore points and removes the pagefile.
#>

$ErrorActionPreference = 'Stop'

# ---- pretty, uniform output ------------------------------------------------
function Section ($m) {
    Write-Host ''
    Write-Host "  $m" -ForegroundColor Green
    Write-Host ('  ' + ('-' * $m.Length)) -ForegroundColor DarkGray
}
function Step ($m) { Write-Host '==> ' -ForegroundColor Cyan   -NoNewline; Write-Host $m -ForegroundColor White }
function Done ($m) { Write-Host '==> ' -ForegroundColor Green  -NoNewline; Write-Host $m -ForegroundColor White }
function Note ($m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Warn ($m) { Write-Host '!   '  -ForegroundColor Yellow -NoNewline; Write-Host $m -ForegroundColor White }
function Fail ($m) { Write-Host 'x   '  -ForegroundColor Red    -NoNewline; Write-Host $m -ForegroundColor White }

# Create a registry key only if it's missing: New-Item -Force on an existing
# key RECREATES it, wiping its values and subkeys (e.g. the Edge policy key
# and everything under it).
function Ensure-RegKey ($Path) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
}

# ---- args ------------------------------------------------------------------
$All  = [bool]($args | Where-Object { $_ -match '^(--?all|/all)$' })
$Help = [bool]($args | Where-Object { $_ -match '^(--?help|/\?|-h)$' })
$NewName = $null
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -match '^(--?name|/name)$' -and $i + 1 -lt $args.Count) { $NewName = [string]$args[$i + 1] }
}
if ($Help) {
    Write-Host ''
    Write-Host '  provision.ps1 - menu of machine setup steps.' -ForegroundColor White
    Note 'run with no args for the menu, or --all to run everything unattended.'
    Note '--all skips the rename step unless --name NEWPC is also given.'
    Write-Host ''
    return
}

# ---- environment -----------------------------------------------------------
# $IsWindows is $null on Windows PowerShell 5.1, so this only fires on pwsh for Linux/macOS.
if ($IsWindows -eq $false) { Fail 'This script is for Windows.'; return }

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Fail 'Administrator rights required - re-run from an elevated PowerShell.'
    return
}

$script:RebootNeeded = $false

# ===========================================================================
#  the steps
# ===========================================================================

# 1) delete all restore points for C:\ and turn off System Protection.
function Invoke-DisableRestore {
    Step 'Disabling System Protection on C:\ (this also deletes all restore points)...'
    if (Get-Command Disable-ComputerRestore -ErrorAction SilentlyContinue) {
        Disable-ComputerRestore -Drive 'C:\'
    } else {
        # PowerShell 7 dropped the cmdlet: disable via policy instead.
        Note 'Disable-ComputerRestore not available - falling back to policy.'
        Ensure-RegKey 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore'
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Name 'DisableSR' -Value 1 -Type DWord
    }
    # Disabling protection does not reliably purge existing shadow copies
    # (restore points are VSS shadows on the system drive) - do it explicitly.
    cmd /c 'vssadmin delete shadows /for=C: /all /quiet >nul 2>&1'
    Done 'System Protection off; restore points cleared on C:\.'
}

# 2) disable hibernation - powercfg removes hiberfil.sys as part of this.
function Invoke-DisableHibernation {
    Step 'Disabling hibernation...'
    & powercfg /hibernate off
    if ($LASTEXITCODE -ne 0) { throw "powercfg exited with code $LASTEXITCODE." }
    if (Test-Path "$env:SystemDrive\hiberfil.sys") {
        Note 'hiberfil.sys still present - it is freed on the next reboot.'
    } else {
        Note 'hiberfil.sys removed.'
    }
    Done 'Hibernation disabled.'
}

# 3) turn the pagefile off completely. Windows deletes pagefile.sys on reboot.
function Invoke-DisablePagefile {
    Step 'Disabling the pagefile...'
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($cs.AutomaticManagedPagefile) {
        $cs | Set-CimInstance -Property @{ AutomaticManagedPagefile = $false }
        Note 'Turned off automatic pagefile management.'
    }
    $pf = Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue
    if ($pf) {
        $pf | ForEach-Object { Note "Removing pagefile: $($_.Name)"; $_ | Remove-CimInstance }
    } else {
        Note 'No explicit pagefile configured.'
    }
    $script:RebootNeeded = $true
    Done 'Pagefile disabled - reboot to free the pagefile.sys file(s).'
}

# 4) share C:\ as "C", full control for the current user only, if not already shared.
function Invoke-ShareC {
    Step 'Sharing C:\ over SMB as "C"...'
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    # $_.Special is true for the built-in admin shares (C$, ADMIN$, IPC$); ignore those.
    $existing = Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq 'C:\' -and -not $_.Special }
    $nameTaken = Get-SmbShare -Name 'C' -ErrorAction SilentlyContinue
    if ($existing) {
        Warn "C:\ is already shared as '$($existing.Name)' - leaving it alone."
    } elseif ($nameTaken) {
        Warn "Share name 'C' is already in use (path $($nameTaken.Path)) - leaving it alone."
    } else {
        # Naming an explicit account suppresses the default 'Everyone: Read' ACL,
        # so only $me gets access - no deny stanza needed.
        New-SmbShare -Name 'C' -Path 'C:\' -FullAccess $me | Out-Null
        Done "Shared C:\ as 'C' with Full Control for $me (and no one else)."
    }
}

# 5) Edge: skip the first-run wizard, disable startup boost.
#    Tab restore is deliberately NOT automated: empirically (mid-2026 Edge) the
#    RestoreOnStartup=1 policy loads but does not restore tabs, and the
#    session.restore_on_startup pref is MAC/enclave-protected, so direct
#    Preferences edits self-revert and initial_preferences seeding is ignored.
#    Flip it by hand instead: edge://settings/onStartup.
function Invoke-EdgeSetup {
    Step 'Configuring Edge: no first-run wizard, no startup boost...'
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    Ensure-RegKey $edge
    Set-ItemProperty -Path $edge -Name 'HideFirstRunExperience' -Value 1 -Type DWord   # no welcome wizard / splash
    Set-ItemProperty -Path $edge -Name 'AutoImportAtFirstRun'   -Value 4 -Type DWord   # 4 = DisabledAutoImport
    Set-ItemProperty -Path $edge -Name 'StartupBoostEnabled'    -Value 0 -Type DWord   # close really closes; policies load on next start
    Done 'First-run wizard suppressed; startup boost off.'
}

# 6) import root CA into the current user's Trusted Root store.
function Invoke-ImportCert {
    Step "Importing root CA into the current user's Trusted Root store..."
    # serial e8:58:65:17:b0:10:c2:d3:7d:96:30:ec:54:79:81:d4:43:ee:b3
    $pem = @'
-----BEGIN CERTIFICATE-----
MIIFtzCCA5+gAwIBAgIUAOhYZRewEMLTfZYw7FR5gdRD7rMwDQYJKoZIhvcNAQEL
BQAwajELMAkGA1UEBhMCVVMxCzAJBgNVBAgMAkZMMSYwJAYDVQQKDB1NYXJ0b24n
cyBTdXBlciBTZWN1cmUgUm9vdCBDQTEmMCQGA1UEAwwdTWFydG9uJ3MgU3VwZXIg
U2VjdXJlIFJvb3QgQ0EwIBcNMjQwMjA5MDc0MTUwWhgPMjEyNDAxMTYwNzQxNTBa
MGoxCzAJBgNVBAYTAlVTMQswCQYDVQQIDAJGTDEmMCQGA1UECgwdTWFydG9uJ3Mg
U3VwZXIgU2VjdXJlIFJvb3QgQ0ExJjAkBgNVBAMMHU1hcnRvbidzIFN1cGVyIFNl
Y3VyZSBSb290IENBMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAuN8y
xDoKUMvauF2wFso/CqlqQ2Gojf/XxuserYs0eRQTLbR5Oel2MqV/CnbcFHeLV4mn
LrCTMgNcqis2nH0uUsYcHfvqMwyLxa5MTnrzqasLApdbPLINeOvHPGfipKNWFyAN
YoZl0zFXKU5djHKv4sxt/damifj1tZ/xLfPJkapmF5BMZZYX/brPf6We0kG7DYOW
/Z4RtMMqyKGwLk1BLGu9RGrKENFecxcA3Y42OGK+8mdf086bqfAUCafr6CeWTEfa
EgKkQxfNsHdR/7rXxEWjXyONyf1DV+sC03NvVPQnfiuu87mVl8x1HwrAJqNbljUS
MpkqToGU0M6GalTN97uZVoYQpRgfQaEgi0otjG7rqAFQ9HYiUMylgJX0Z7z9Zrag
7MrapgXtv3AMfBGJcH7t3flJw20KjrGIyXirAPRrg+bXelr4gBuVn/NxKju/VLFs
1ZNnPtCiSc+BZtULhC6HndmhSryBsmXW+oS8uBxs3n7IzE9bft/xp1peQ3o8NaFg
CUinDolo4CCxuGsa90JggMo7ApsQfXO42XBw+hrFhD8OGp5YYJ05IUBA/zRnOUOn
OXsJMRJvW3FHFPdMGZsw0Apf1uUDLK3pjWyeFVsTLanAgRP/k3f6oSnaLydHc42t
SA71ksixEFo4g0czFhnsgqUimYpOfZPDqTuvuFECAwEAAaNTMFEwHQYDVR0OBBYE
FLc0o7Lv41OqClh2AaQyFBLJPNXCMB8GA1UdIwQYMBaAFLc0o7Lv41OqClh2AaQy
FBLJPNXCMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggIBAHnfYVZC
+iTSoFgfE/WJesH+kKIcW2PYXiFZKeizL+Tm67+yE1NFL4RewcB6EBh4zdsmEjPk
cMs5UH2u9NDuzJx1idn3SzcjKx/0CHVWrk5dO2d0iab0z1cdGn00kxG3v2CbcfzI
i3+BbSWsWOJDkSqaVjhQb5nOIHGph/ATi/Ukx+j21NPIEjmWwKtrIdFH6KbWvM4Q
kYkK00LUjJeFFw0LgIELxUQ2rQV2z4VT1WQc3iXdS3TK4DhOR63lbWodHjY8qhki
UlNeoM8hc9YakfQDEVIJJAELmzRtROiVnFKl87n51Wehrc0eStXHrMbiRuJju6xq
m6zKCfaZtOXxk7WuB2WnzhUIGuyhROgQFMZ06TW8i9bcfIntcGtSPCtk0sGUOQZi
ANxQrh+IUYdgb7zHA+hlKGhdO/YnRbqoXrY0I64ttzkO21v8LarAlfm+YHERye19
+rqpWuxaSCZzEa3yf/pkNA/LlmicbTbfiwQSPfi3kvQAJ0rpOY7PW1y/djloFHra
260OU6EntLX+PKybYd2J3VaPn0bqkPz6gom2VV7uhKJdb+DAmYT39g8fl9tUYbk+
FKny5Xz+b9ZGsPUhRywlEFVn4SmDSEmmTs14VauVQYCYEW2MPPTV3K1apOLLaQcQ
DhtkHfQhABbKBEVTp02l1iHF7L/1MPhbmWLS
-----END CERTIFICATE-----
'@
    $b64  = ($pem -replace '-{5}[^-]+-{5}', '') -replace '\s', ''
    $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($b64))
    $store = [Security.Cryptography.X509Certificates.X509Store]::new('Root', 'CurrentUser')
    $store.Open('ReadWrite')
    try {
        $present = $store.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
        if ($present) {
            Note "Already trusted (thumbprint $($cert.Thumbprint)) - nothing to do."
        } else {
            $store.Add($cert)
            Done "Imported: $($cert.Subject)"
            Note "thumbprint $($cert.Thumbprint)"
        }
    } finally {
        $store.Close()
    }
}

# 7) let the current user run local scripts without -ExecutionPolicy.
function Invoke-ExecPolicy {
    Step 'Setting execution policy to RemoteSigned (current user)...'
    $cur = Get-ExecutionPolicy -Scope CurrentUser
    if ($cur -eq 'RemoteSigned') {
        Note 'Already RemoteSigned - nothing to do.'
    } else {
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        Done "Execution policy (current user): $cur -> RemoteSigned."
    }
}

# 8) set the active network connection(s) to the Private profile.
function Invoke-NetPrivate {
    Step 'Setting the active network connection(s) to Private...'
    $profiles = @(Get-NetConnectionProfile)
    if (-not $profiles) { Note 'No active network connections.'; return }
    foreach ($p in $profiles) {
        $label = "$($p.InterfaceAlias) ($($p.Name))"
        if ($p.NetworkCategory -eq 'DomainAuthenticated') {
            Note "$label is domain-authenticated - leaving it alone."
        } elseif ($p.NetworkCategory -eq 'Private') {
            Note "$label is already Private."
        } else {
            Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private
            Done "$label -> Private."
        }
    }
}

# 9) enable Remote Desktop: NLA on, connections allowed, firewall open, service auto.
function Invoke-EnableRdp {
    Step 'Enabling Remote Desktop...'
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 1 -Type DWord -Force
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0 -Type DWord -Force
    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' | Out-Null
    Set-Service -Name TermService -StartupType Automatic
    Start-Service -Name TermService -ErrorAction SilentlyContinue
    Done 'RDP enabled (with Network Level Authentication) - the machine accepts remote connections.'
}

# 10) switch Windows to dark mode and broadcast the change so open apps repaint.
function Invoke-DarkMode {
    Step 'Switching Windows to dark mode...'
    $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    # Windows is inverted here: 0 = dark theme, 1 = light theme.
    Set-ItemProperty -Path $p -Name 'SystemUsesLightTheme' -Value 0 -Type DWord
    Set-ItemProperty -Path $p -Name 'AppsUseLightTheme'    -Value 0 -Type DWord
    if (-not ('Theme' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Theme {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
'@
    }
    # WM_SETTINGCHANGE 'ImmersiveColorSet' to HWND_BROADCAST (SMTO_ABORTIFHUNG, 5s).
    $result = [UIntPtr]::Zero
    [Theme]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'ImmersiveColorSet', 0x0002, 5000, [ref]$result) | Out-Null
    Done 'Windows is now in dark mode.'
}

# 11) put Dark Reader on Edge's force-install list (documented enterprise policy).
function Invoke-DarkReader {
    Step 'Adding Dark Reader to the Edge force-installed extensions...'
    $id  = 'ifoakfbpdcdoeenechcleahebpibofpc'   # Dark Reader's id on the Edge Add-ons store
    $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist'
    Ensure-RegKey $key
    $names = @((Get-Item $key).Property)
    $entries = foreach ($n in $names) { (Get-ItemProperty -Path $key -Name $n).$n }
    if ($entries -match "^$id") {
        Note 'Already on the force-install list - nothing to do.'
        return
    }
    $i = 1
    while ($names -contains "$i") { $i++ }
    Set-ItemProperty -Path $key -Name "$i" -Value "$id;https://edge.microsoft.com/extensionwebstorebase/v1/crx" -Type String
    Done 'Dark Reader installs (or becomes policy-managed, if present) on the next Edge start.'
    Note 'Undo: remove the entry under HKLM\...\Policies\Microsoft\Edge\ExtensionInstallForcelist.'
}

# 12) set the time zone to US Eastern.
function Invoke-TimeZone {
    Step 'Setting the time zone to US Eastern...'
    $cur = Get-TimeZone
    if ($cur.Id -eq 'Eastern Standard Time') {
        Note "Already '$($cur.Id)' - nothing to do."
    } else {
        Set-TimeZone -Id 'Eastern Standard Time'
        Done "Time zone: '$($cur.Id)' -> 'Eastern Standard Time'."
    }
}

# 13) show the computer name and set a new one. The menu prompts for it; --all
#     runs this only when --name <newname> was given on the command line.
function Invoke-Rename {
    Step "This computer is named '$env:COMPUTERNAME'."
    $target = $NewName
    if (-not $target) {
        $target = (Read-Host '    new name (Enter keeps it)').Trim()
        if (-not $target) { Note 'Keeping the current name.'; return }
    }
    if ($target -ieq $env:COMPUTERNAME) { Note "Already named '$target' - nothing to do."; return }
    if ($target -notmatch '^[A-Za-z0-9-]{1,15}$') {
        throw "'$target' is not a valid computer name (1-15 letters, digits or hyphens)."
    }
    Rename-Computer -NewName $target -Force -WarningAction SilentlyContinue | Out-Null
    $script:RebootNeeded = $true
    Done "Renamed to '$target' - takes effect after a reboot."
}

# 14) download and run clean.ps1 (the debloat script) straight from the site.
function Invoke-RemoteClean {
    Step 'Fetching https://anka.me/clean.ps1 and running it...'
    # Win10/11 ship .NET 4.8 (OS TLS defaults); the -bor keeps 1.2 on for older builds.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $src = Invoke-RestMethod -Uri 'https://anka.me/clean.ps1'
    if ($src -is [byte[]]) { $src = [Text.Encoding]::UTF8.GetString($src) }
    # Child scope: clean.ps1's helper functions can't clobber ours, and it runs
    # under its own default ErrorActionPreference - our 'Stop' would turn native
    # stderr chatter (reg.exe and friends) into terminating errors mid-script.
    & { $ErrorActionPreference = 'Continue'; & ([scriptblock]::Create($src)) }
    Done 'clean.ps1 finished.'
}

# 15) create a local administrator account. Always prompts for the name and
#     password, so it is menu-only (--all skips it).
function Invoke-CreateAdmin {
    Step 'Creating a local administrator account...'
    $name = (Read-Host '    user name (Enter cancels)').Trim()
    if (-not $name) { Note 'Cancelled.'; return }
    if ($name -notmatch '^[A-Za-z0-9 ._-]{1,20}$') {
        throw "'$name' is not a valid local user name (1-20 letters, digits, spaces, . _ -)."
    }
    if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) {
        Warn "User '$name' already exists - leaving it alone."
        return
    }
    $p1 = Read-Host '    password' -AsSecureString
    if ($p1.Length -eq 0) { throw 'Password cannot be empty.' }
    $p2 = Read-Host '    password (again)' -AsSecureString
    # SecureStrings can't be compared directly - round-trip through BSTRs.
    $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1)
    $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2)
    try {
        $match = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1) -ceq
                 [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)
    }
    if (-not $match) { throw 'Passwords do not match.' }
    New-LocalUser -Name $name -Password $p1 -PasswordNeverExpires -AccountNeverExpires | Out-Null
    # By SID, not by name - the Administrators group is localized on non-English Windows.
    Add-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-544') -Member $name
    Done "Created local administrator '$name' (password never expires)."
}

# 16) read-only: report the allocation unit (cluster) size of C:\.
function Invoke-CheckClusterSize {
    Step 'Checking the allocation unit size of C:\...'
    $bs = (Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='C:'").BlockSize
    if (-not $bs) { Warn 'Could not read the allocation unit size of C:\.'; return }
    $kb = [int]($bs / 1KB)
    if ($bs -ge 16KB) {
        Done "C:\ allocation unit size: ${kb}K (16K or larger)."
    } else {
        Fail "C:\ allocation unit size: ${kb}K - smaller than 16K."
    }
}

# ---- cheap state probes ----------------------------------------------------
# Each probe returns $true when its step is already in the desired end state;
# the menu renders done/todo from this. Steps without a probe (rename, clean.ps1)
# show no state. Probes run on every menu redraw - keep them read-only and fast.
$checks = @{
    # Done = protection flag off AND zero restore points actually on disk (both
    # via WMI root/default, so it works in 5.1 and pwsh 7 alike). Note: a clean
    # Windows install ships with System Protection OFF, so 'done' on a brand-new
    # machine is expected, not a misread.
    'Invoke-DisableRestore'     = { $cfg = Get-CimInstance -Namespace root/default -ClassName SystemRestoreConfig -ErrorAction SilentlyContinue
                                    if (-not $cfg) { return $null }
                                    if ($cfg.RPSessionInterval -ne 0) { return $false }
                                    @(Get-CimInstance -Namespace root/default -ClassName SystemRestore -ErrorAction SilentlyContinue).Count -eq 0 }
    'Invoke-DisableHibernation' = { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue).HibernateEnabled -eq 0 }
    'Invoke-DisablePagefile'    = { -not (Get-CimInstance -ClassName Win32_ComputerSystem).AutomaticManagedPagefile -and -not (Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue) }
    'Invoke-ShareC'             = { [bool](Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq 'C:\' -and -not $_.Special }) }
    'Invoke-EdgeSetup'          = { $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -ErrorAction SilentlyContinue
                                    $pol.HideFirstRunExperience -eq 1 -and $pol.AutoImportAtFirstRun -eq 4 -and $pol.StartupBoostEnabled -eq 0 }
    # keep the thumbprint in sync with the PEM inside Invoke-ImportCert
    'Invoke-ImportCert'         = { Test-Path 'Cert:\CurrentUser\Root\E0096052D4A02B61CB4E357B933981E9D35AD2C0' }
    'Invoke-ExecPolicy'         = { (Get-ExecutionPolicy -Scope CurrentUser) -eq 'RemoteSigned' }
    'Invoke-NetPrivate'         = { -not (Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.NetworkCategory -eq 'Public' }) }
    'Invoke-EnableRdp'          = { (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue).fDenyTSConnections -eq 0 }
    'Invoke-DarkMode'           = { $p = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue; $p.AppsUseLightTheme -eq 0 -and $p.SystemUsesLightTheme -eq 0 }
    'Invoke-DarkReader'         = { $k = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist'; if (Test-Path $k) { [bool](@((Get-Item $k).Property | ForEach-Object { (Get-ItemProperty -Path $k -Name $_).$_ }) -match '^ifoakfbpdcdoeenechcleahebpibofpc') } else { $false } }
    'Invoke-TimeZone'           = { (Get-TimeZone).Id -eq 'Eastern Standard Time' }
    # read-only test: green (ok) at 16K clusters or larger, red (FAIL) below.
    'Invoke-CheckClusterSize'   = { $bs = (Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='C:'").BlockSize
                                    if (-not $bs) { return $null }
                                    $bs -ge 16KB }
}

# ---- catalog ---------------------------------------------------------------
$steps = @(
    [pscustomobject]@{ Key = '1' ; Title = 'Delete restore points + disable System Protection (C:)'; Fn = 'Invoke-DisableRestore';     Tag = '' }
    [pscustomobject]@{ Key = '2' ; Title = 'Disable hibernation (removes hiberfil.sys)';             Fn = 'Invoke-DisableHibernation'; Tag = '' }
    [pscustomobject]@{ Key = '3' ; Title = 'Disable the pagefile completely';                        Fn = 'Invoke-DisablePagefile';    Tag = 'reboot' }
    [pscustomobject]@{ Key = '4' ; Title = 'Share C:\ as "C" (full control, current user only)';     Fn = 'Invoke-ShareC';             Tag = '' }
    [pscustomobject]@{ Key = '5' ; Title = 'Edge: no first-run wizard, no startup boost';            Fn = 'Invoke-EdgeSetup';          Tag = '' }
    [pscustomobject]@{ Key = '6' ; Title = "Trust root CA (current user)";                           Fn = 'Invoke-ImportCert';         Tag = '' }
    [pscustomobject]@{ Key = '7' ; Title = 'Execution policy: RemoteSigned (current user)';          Fn = 'Invoke-ExecPolicy';         Tag = '' }
    [pscustomobject]@{ Key = '8' ; Title = 'Set the active network connection(s) to Private';        Fn = 'Invoke-NetPrivate';         Tag = '' }
    [pscustomobject]@{ Key = '9' ; Title = 'Enable Remote Desktop (NLA, firewall, service)';         Fn = 'Invoke-EnableRdp';          Tag = '' }
    [pscustomobject]@{ Key = '10'; Title = 'Switch Windows to dark mode';                            Fn = 'Invoke-DarkMode';           Tag = '' }
    [pscustomobject]@{ Key = '11'; Title = 'Install Dark Reader for Edge (policy)';                  Fn = 'Invoke-DarkReader';         Tag = '' }
    [pscustomobject]@{ Key = '12'; Title = 'Set the time zone to US Eastern';                        Fn = 'Invoke-TimeZone';           Tag = '' }
    [pscustomobject]@{ Key = '13'; Title = 'Rename this computer (asks for the new name)';           Fn = 'Invoke-Rename';             Tag = 'reboot' }
    [pscustomobject]@{ Key = '14'; Title = 'Run clean.ps1 (debloat) from https://anka.me';           Fn = 'Invoke-RemoteClean';        Tag = 'network' }
    [pscustomobject]@{ Key = '15'; Title = 'Create a local administrator user (asks name + password)'; Fn = 'Invoke-CreateAdmin';      Tag = '' }
    [pscustomobject]@{ Key = '16'; Title = 'Check C:\ allocation unit size (want 16K or larger)';    Fn = 'Invoke-CheckClusterSize';   Tag = 'check' }
)

function Invoke-OneStep ($step) {
    Write-Host ''
    try { & $step.Fn }
    catch { Fail $_.Exception.Message }
}

function Show-RebootReminder {
    if ($script:RebootNeeded) {
        Write-Host ''
        Warn 'A reboot is required to finish (pagefile removal).'
    }
}

# ---- run -------------------------------------------------------------------
if ($All) {
    Section 'Provisioning - running all steps'
    foreach ($s in $steps) {
        if ($s.Fn -eq 'Invoke-Rename' -and -not $NewName) {
            Write-Host ''
            Note 'Skipping the rename step (no --name given).'
            continue
        }
        if ($s.Fn -eq 'Invoke-CreateAdmin') {
            Write-Host ''
            Note 'Skipping the local admin step (interactive only - run it from the menu).'
            continue
        }
        Invoke-OneStep $s
    }
    Show-RebootReminder
    Write-Host ''
    Done 'All steps complete.'
    return
}

while ($true) {
    Write-Host ''
    Write-Host '  provision' -ForegroundColor Green -NoNewline
    Write-Host ' - machine setup steps' -ForegroundColor Gray
    Write-Host '  -----------------------------------------------' -ForegroundColor DarkGray
    foreach ($s in $steps) {
        $state = ''
        if ($checks.ContainsKey($s.Fn)) {
            # A probe returning $null means "can't tell here" - show no state, not todo.
            try {
                $r = & $checks[$s.Fn]
                if ($null -ne $r) { $state = if ($r) { 'done' } else { 'todo' } }
            } catch { $state = '' }
        }
        Write-Host "  [$($s.Key.PadLeft(2))] " -ForegroundColor Cyan -NoNewline
        # 'check' steps are read-only tests: pass renders green, fail renders red.
        if     ($state -eq 'done' -and $s.Tag -eq 'check') { Write-Host 'ok    ' -ForegroundColor Green -NoNewline }
        elseif ($state -eq 'todo' -and $s.Tag -eq 'check') { Write-Host 'FAIL  ' -ForegroundColor Red   -NoNewline }
        elseif ($state -eq 'done') { Write-Host 'done  ' -ForegroundColor DarkGreen -NoNewline }
        elseif ($state -eq 'todo') { Write-Host 'todo  ' -ForegroundColor Yellow    -NoNewline }
        else                       { Write-Host '      '                            -NoNewline }
        Write-Host $s.Title -ForegroundColor $(if ($state -eq 'done') { 'DarkGray' } else { 'White' }) -NoNewline
        if ($s.Tag -eq 'destructive') { Write-Host '  (destructive)' -ForegroundColor Red -NoNewline }
        elseif ($s.Tag -eq 'reboot')  { Write-Host '  (reboot)'      -ForegroundColor Yellow -NoNewline }
        elseif ($s.Tag -eq 'network') { Write-Host '  (network)'     -ForegroundColor DarkGray -NoNewline }
        elseif ($s.Tag -eq 'check')   { Write-Host '  (read-only)'   -ForegroundColor DarkGray -NoNewline }
        Write-Host ''
    }
    Write-Host '  [ a] ' -ForegroundColor Cyan -NoNewline; Write-Host '      run all' -ForegroundColor White
    Write-Host '  [ q] ' -ForegroundColor Cyan -NoNewline; Write-Host '      quit'    -ForegroundColor White
    Write-Host ''

    $choice = (Read-Host '  run which?').Trim()
    if ($choice -match '^(q|quit|exit)$') { Show-RebootReminder; Write-Host ''; Done 'Bye.'; break }

    if ($choice -match '^(a|all)$') {
        foreach ($s in $steps) { Invoke-OneStep $s }
        Write-Host ''
        Read-Host '  Enter to return to the menu' | Out-Null
        continue
    }

    $step = $steps | Where-Object Key -eq $choice
    if (-not $step) { Warn "No such option '$choice'."; continue }

    Invoke-OneStep $step
    Write-Host ''
    Read-Host '  Enter to return to the menu' | Out-Null
}
