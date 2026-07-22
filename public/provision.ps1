<#
  provision.ps1 - one-off machine provisioning steps
  ---------------------------------------------------
  Run elevated (Windows PowerShell 5.1). With no args it shows a menu; with
  --all it runs every step in order, unattended.

      powershell -ExecutionPolicy Bypass -File .\provision.ps1
      powershell -ExecutionPolicy Bypass -File .\provision.ps1 --all

  Or straight off a site, no download (execution policy does not gate iex):

      irm https://anka.me/provision.ps1 | iex
      & ([scriptblock]::Create((irm https://anka.me/provision.ps1))) --all

  Most steps need administrator rights; 6 (user cert) and 7 (execution policy)
  do not, but the script requires elevation overall. DESTRUCTIVE: deletes
  restore points and removes the pagefile.
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

# ---- args ------------------------------------------------------------------
$All  = [bool]($args | Where-Object { $_ -match '^(--?all|/all)$' })
$Help = [bool]($args | Where-Object { $_ -match '^(--?help|/\?|-h)$' })
if ($Help) {
    Write-Host ''
    Write-Host '  provision.ps1 - menu of machine setup steps.' -ForegroundColor White
    Note 'run with no args for the menu, or --all to run everything unattended.'
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
        # PowerShell 7 dropped the cmdlet: purge the shadow copies (restore points
        # are VSS shadows on the system drive) and disable via policy instead.
        Note 'Disable-ComputerRestore not available - falling back to vssadmin + policy.'
        & vssadmin delete shadows /for=C: /all /quiet *> $null
        New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Name 'DisableSR' -Value 1 -Type DWord
    }
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

# 5) make Edge restore the previous session on startup (documented enterprise policy).
function Invoke-EdgeRestore {
    Step 'Setting Edge to reopen the previous tabs on startup...'
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    New-Item -Path $edge -Force | Out-Null
    Set-ItemProperty -Path $edge -Name 'RestoreOnStartup' -Value 1 -Type DWord   # 1 = restore last session
    Done 'Edge will restore the last session on startup.'
    Note 'This is the enterprise policy, so Edge will show "managed by your organization"'
    Note 'and the setting is locked. Undo: delete RestoreOnStartup under HKLM\...\Policies\Microsoft\Edge.'
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

# 8) download and run clean.ps1 (the debloat script) straight from the site.
function Invoke-RemoteClean {
    Step 'Fetching https://anka.me/clean.ps1 and running it...'
    # Win10/11 ship .NET 4.8 (OS TLS defaults); the -bor keeps 1.2 on for older builds.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $src = Invoke-RestMethod -Uri 'https://anka.me/clean.ps1'
    if ($src -is [byte[]]) { $src = [Text.Encoding]::UTF8.GetString($src) }
    # child scope, so clean.ps1's own helper functions can't clobber ours
    & ([scriptblock]::Create($src))
    Done 'clean.ps1 finished.'
}

# ---- catalog ---------------------------------------------------------------
$steps = @(
    [pscustomobject]@{ Key = '1'; Title = 'Delete restore points + disable System Protection (C:)'; Fn = 'Invoke-DisableRestore';    Tag = 'destructive' }
    [pscustomobject]@{ Key = '2'; Title = 'Disable hibernation (removes hiberfil.sys)';             Fn = 'Invoke-DisableHibernation'; Tag = '' }
    [pscustomobject]@{ Key = '3'; Title = 'Disable the pagefile completely';                        Fn = 'Invoke-DisablePagefile';    Tag = 'reboot' }
    [pscustomobject]@{ Key = '4'; Title = 'Share C:\ as "C" (full control, current user only)';     Fn = 'Invoke-ShareC';             Tag = '' }
    [pscustomobject]@{ Key = '5'; Title = 'Make Edge reopen previous tabs on startup';              Fn = 'Invoke-EdgeRestore';        Tag = '' }
    [pscustomobject]@{ Key = '6'; Title = "Trust root CA (current user)";                           Fn = 'Invoke-ImportCert';         Tag = '' }
    [pscustomobject]@{ Key = '7'; Title = 'Execution policy: RemoteSigned (current user)';          Fn = 'Invoke-ExecPolicy';         Tag = '' }
    [pscustomobject]@{ Key = '8'; Title = 'Run clean.ps1 (debloat) from https://anka.me';           Fn = 'Invoke-RemoteClean';        Tag = 'network' }
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
    foreach ($s in $steps) { Invoke-OneStep $s }
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
        Write-Host "  [$($s.Key)] " -ForegroundColor Cyan -NoNewline
        Write-Host $s.Title -ForegroundColor White -NoNewline
        if ($s.Tag -eq 'destructive') { Write-Host '  (destructive)' -ForegroundColor Red -NoNewline }
        elseif ($s.Tag -eq 'reboot')  { Write-Host '  (reboot)'      -ForegroundColor Yellow -NoNewline }
        elseif ($s.Tag -eq 'network') { Write-Host '  (network)'     -ForegroundColor DarkGray -NoNewline }
        Write-Host ''
    }
    Write-Host '  [a] ' -ForegroundColor Cyan -NoNewline; Write-Host 'run all' -ForegroundColor White
    Write-Host '  [q] ' -ForegroundColor Cyan -NoNewline; Write-Host 'quit'    -ForegroundColor White
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
