<#
  install.ps1 - menu installer for Marton's Windows apps
  -------------------------------------------------------
  Usage:   irm https://anka.me/install.ps1 | iex
  Source:  https://anka.me

  Pick an app, and the script downloads the latest signed release from GitHub
  for your architecture and installs it. clipp and WM_NIGHT ship as MSIX
  (WM_NIGHT installs elevated - expect a UAC prompt); mstsfence ships as a
  loose zip and lands in %LOCALAPPDATA%\Programs.
#>

& {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference    = 'SilentlyContinue'   # IWR's progress bar tanks download speed on Windows PowerShell 5.1

  # ---- pretty, uniform output ------------------------------------------------
  function Step ($m) { Write-Host '==> ' -ForegroundColor Cyan   -NoNewline; Write-Host $m -ForegroundColor White }
  function Done ($m) { Write-Host '==> ' -ForegroundColor Green  -NoNewline; Write-Host $m -ForegroundColor White }
  function Note ($m) { Write-Host "    $m" -ForegroundColor DarkGray }
  function Warn ($m) { Write-Host '!   '  -ForegroundColor Yellow -NoNewline; Write-Host $m -ForegroundColor White }
  function Fail ($m) { Write-Host 'x   '  -ForegroundColor Red    -NoNewline; Write-Host $m -ForegroundColor White }

  # ---- the catalog -------------------------------------------------------------
  # Url takes {arch} = amd64 | arm64. Kind: msix (Add-AppxPackage) or zip (extract
  # to %LOCALAPPDATA%\Programs\<name> and start the exe).
  $catalog = @(
    [pscustomobject]@{
      Key = '1'; Name = 'clipp';     Tagline = 'peer-to-peer clipboard sync'
      Kind = 'msix'; Elevated = $false
      Url  = 'https://github.com/martona/clipp/releases/latest/download/clipp-windows-{arch}.msix'
    }
    [pscustomobject]@{
      Key = '2'; Name = 'mstsfence'; Tagline = 'fence full-screen RDP to the work area'
      Kind = 'msix';  Elevated = $false
      Url  = 'https://github.com/martona/mstsfence/releases/latest/download/mstsfence-windows-{arch}.msix'
    }
    [pscustomobject]@{
      Key = '3'; Name = 'WM_NIGHT';  Tagline = 'dark mode for the classic Win32 desktop'
      Kind = 'msix'; Elevated = $true
      Url  = 'https://github.com/martona/WM_NIGHT/releases/latest/download/WM_NIGHT-windows-{arch}.msix'
    }
  )

  # ---- environment ---------------------------------------------------------
  # $IsWindows is $null on Windows PowerShell 5.1, so this only fires on pwsh for Linux/macOS.
  if ($IsWindows -eq $false) { Fail 'This installer is for Windows.'; return }

  # PROCESSOR_ARCHITEW6432 holds the true OS arch when a 32-bit shell runs on
  # 64-bit Windows; otherwise PROCESSOR_ARCHITECTURE is correct.
  $rawArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
  $arch = switch ($rawArch) {
    'AMD64' { 'amd64' }
    'ARM64' { 'arm64' }
    default { Fail "Unsupported architecture '$rawArch' - these apps need 64-bit Windows."; return }
  }

  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12   # older Win10 5.1 may not default to TLS 1.2

  $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

  # ---- install helpers ------------------------------------------------------
  function Get-Artifact ($proj) {
    $url  = $proj.Url -replace '\{arch\}', $arch
    $file = Join-Path $env:TEMP (Split-Path $url -Leaf)
    Step "Downloading the latest $($proj.Name) release..."
    Note $url
    Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing
    Note ('{0:N1} MB downloaded' -f ((Get-Item $file).Length / 1MB))
    return $file
  }

  function Install-Msix ($proj) {
    $msix = Get-Artifact $proj
    try {
      if ($proj.Elevated -and -not $IsAdmin) {
        # Hand just the Add-AppxPackage step to an elevated Windows PowerShell;
        # -EncodedCommand sidesteps quoting issues. Expect one UAC prompt.
        Step "Installing $($proj.Name) (UAC prompt incoming)..."
        $child = @"
`$ErrorActionPreference = 'Stop'
try {
  Add-AppxPackage -Path '$msix' -ForceUpdateFromAnyVersion -ForceApplicationShutdown
  exit 0
} catch {
  Write-Host `$_.Exception.Message -ForegroundColor Red
  Start-Sleep -Seconds 6
  exit 1
}
"@
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
        $p = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc -Verb RunAs -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "The elevated install reported an error (exit code $($p.ExitCode))." }
      }
      else {
        # PowerShell 7 doesn't load the Appx module natively - pull it in from Windows PowerShell.
        if (-not (Get-Command Add-AppxPackage -ErrorAction SilentlyContinue)) {
          Step 'Loading the Appx module (PowerShell 7)...'
          Import-Module Appx -UseWindowsPowerShell
        }
        Step "Installing $($proj.Name)..."
        Add-AppxPackage -Path $msix -ForceUpdateFromAnyVersion -ForceApplicationShutdown
      }
      Done "$($proj.Name) installed."
    }
    finally {
      Remove-Item $msix -Force -ErrorAction SilentlyContinue
    }
  }

  function Install-Zip ($proj) {
    $zip  = Get-Artifact $proj
    $dest = Join-Path $env:LOCALAPPDATA "Programs\$($proj.Name)"
    try {
      # Kill a running instance so the exe isn't locked while we overwrite it.
      if (Get-Process -Name ($proj.Exe -replace '\.exe$', '') -ErrorAction SilentlyContinue) {
        Step "Stopping the running $($proj.Name)..."
        Stop-Process -Name ($proj.Exe -replace '\.exe$', '') -Force
        Start-Sleep -Milliseconds 800
      }
      Step "Extracting to $dest..."
      Expand-Archive -Path $zip -DestinationPath $dest -Force
      Step "Starting $($proj.Exe) (tray app - registers itself to run at login)..."
      Start-Process (Join-Path $dest $proj.Exe)
      Done "$($proj.Name) installed."
    }
    finally {
      Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }
  }

  # ---- the menu ---------------------------------------------------------------
  while ($true) {
    Write-Host ''
    Write-Host '  anka.me installer' -ForegroundColor Green -NoNewline
    Write-Host " - latest signed builds from GitHub ($arch)" -ForegroundColor Gray
    Write-Host '  -----------------------------------------------' -ForegroundColor DarkGray
    foreach ($proj in $catalog) {
      Write-Host "  [$($proj.Key)] " -ForegroundColor Cyan -NoNewline
      Write-Host $proj.Name.PadRight(11) -ForegroundColor White -NoNewline
      Write-Host $proj.Tagline -ForegroundColor DarkGray -NoNewline
      if ($proj.Elevated) { Write-Host '  (admin)' -ForegroundColor Yellow -NoNewline }
      Write-Host ''
    }
    Write-Host '  [q] ' -ForegroundColor Cyan -NoNewline
    Write-Host 'quit' -ForegroundColor White
    Write-Host ''

    $choice = Read-Host '  install which?'
    if ($choice -match '^(q|quit|exit)$') { Write-Host ''; Done 'Bye.'; break }

    $proj = $catalog | Where-Object Key -eq $choice.Trim()
    if (-not $proj) { Warn "No such option '$choice'."; continue }

    Write-Host ''
    try {
      if ($proj.Kind -eq 'msix') { Install-Msix $proj } else { Install-Zip $proj }
    }
    catch {
      Fail $_.Exception.Message
      Note "Manual download: https://github.com/martona/$($proj.Name)/releases/latest"
    }
    Write-Host ''
    Read-Host '  Enter to return to the menu' | Out-Null
  }
}
