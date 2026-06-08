<#
    clean.ps1 - debloat & sanity-restore a fresh Windows install.

    Needs an elevated PowerShell, and:
        Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#>

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

# Create a registry/file path only if it doesn't already exist (quietly).
function New-FolderForced {
    param ([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

# This script writes all over HKLM, so it needs elevation.
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Fail 'Administrator rights required - re-run from an elevated PowerShell.'
    return
}

# ===========================================================================
Section 'Optimizing the user experience'
# ===========================================================================

Step 'Disabling the Sticky / Filter / Toggle key prompts'
Set-ItemProperty -Path 'HKCU:\Control Panel\Accessibility\StickyKeys'        'Flags' '506'
Set-ItemProperty -Path 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122'
Set-ItemProperty -Path 'HKCU:\Control Panel\Accessibility\ToggleKeys'        'Flags' '58'

Step 'Disabling the Edge desktop shortcut for new profiles'
Set-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer' -Name DisableEdgeDesktopShortcutCreation -Type DWord -Value 1

Step 'Setting Explorer to open at This PC'
Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 1

Step 'Disabling trending searches in the search box'
New-FolderForced -Path 'HKLM:\Software\Policies\Microsoft\Windows\Explorer'
Set-ItemProperty -Path 'HKLM:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1

Step 'Removing the user folders under This PC'
$FolderKeys = @(
    # Desktop
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}'
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}'
    # Documents
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{A8CDFF1C-4878-43be-B5FD-F8091C1C60D0}'
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{d3162b92-9365-467a-956b-92703aca08af}'
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{A8CDFF1C-4878-43be-B5FD-F8091C1C60D0}'
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{d3162b92-9365-467a-956b-92703aca08af}'
    # Downloads
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{374DE290-123F-4565-9164-39C4925E467B}'
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{088e3905-0323-4b02-9826-5d99428e115f}'
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{374DE290-123F-4565-9164-39C4925E467B}'
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{088e3905-0323-4b02-9826-5d99428e115f}'
    # Music
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{1CF1260C-4DD0-4ebb-811F-33C572699FDE}'
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{3dfdf296-dbec-4fb4-81d1-6a3438bcf4de}'
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{1CF1260C-4DD0-4ebb-811F-33C572699FDE}'
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{3dfdf296-dbec-4fb4-81d1-6a3438bcf4de}'
    # Pictures
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{3ADD1653-EB32-4cb0-BBD7-DFA0ABB5ACCA}'
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{24ad3ad4-a569-4530-98e1-ab02f9417aa8}'
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{3ADD1653-EB32-4cb0-BBD7-DFA0ABB5ACCA}'
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{24ad3ad4-a569-4530-98e1-ab02f9417aa8}'
    # Videos
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{A0953C92-50DC-43bf-BE83-3742FED03C9C}'
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{f86fa3ab-70d2-4fc7-9c99-fcbf05467f3a}'
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{A0953C92-50DC-43bf-BE83-3742FED03C9C}'
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{f86fa3ab-70d2-4fc7-9c99-fcbf05467f3a}'
    # 3D Objects
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}'
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}'
)
foreach ($Key in $FolderKeys) {
    Remove-Item -Path $Key -Recurse -Force -ErrorAction SilentlyContinue
}

Step 'Pinning the Recycle Bin to the Explorer sidebar'
New-FolderForced -Path 'HKCU:\SOFTWARE\Classes\CLSID\{645FF040-5081-101B-9F08-00AA002F954E}'
Set-ItemProperty -Path 'HKCU:\SOFTWARE\Classes\CLSID\{645FF040-5081-101B-9F08-00AA002F954E}' 'System.IsPinnedToNameSpaceTree' 1

Step 'Setting folder view options (show hidden files, real extensions)'
Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Hidden' 1
Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0
Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideDrivesWithNoMedia' 0
Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSuperHidden' 1

Step 'Restoring the classic right-click context menu'
reg add 'HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' /f /ve 2>&1 | Out-Null

Step "Pinning your home folder ($HOME) to the sidebar"
$clsid   = '{59031a47-3f72-44a7-89c5-5595fe6b30ee}'
$keyPath = "HKCU:\Software\Classes\CLSID\$clsid"
New-FolderForced -Path $keyPath
Set-ItemProperty -Path $keyPath -Name 'System.IsPinnedToNameSpaceTree' -Value 1 -Type DWord
Set-ItemProperty -Path $keyPath -Name 'SortOrderIndex' -Value 0 -Type DWord

Step 'Disabling third-party promoted junk in the Start menu'
New-FolderForced -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableThirdPartySuggestions'    -Value 1 -Type DWord -Force
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -Value 1 -Type DWord -Force

# ===========================================================================
Section 'Tuning Windows Update'
# ===========================================================================

Step 'Switching updates to notify-before-download'
New-FolderForced -Path 'HKLM:\SOFTWARE\Wow6432Node\Policies\Microsoft\Windows\WindowsUpdate\AU'
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Wow6432Node\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate'         1
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Wow6432Node\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions'           2
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Wow6432Node\Policies\Microsoft\Windows\WindowsUpdate\AU' 'ScheduledInstallDay'  0
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Wow6432Node\Policies\Microsoft\Windows\WindowsUpdate\AU' 'ScheduledInstallTime' 3

Step 'Disabling peer-to-peer update sharing'
New-FolderForced -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0

# ===========================================================================
Section 'Removing default apps'
# ===========================================================================

$apps = @(
    # default Windows 10 apps
    'Microsoft.549981C3F5F10' # Cortana
    'Microsoft.3DBuilder'
    'Microsoft.Appconnector'
    'Microsoft.BingFinance'
    'Microsoft.BingNews'
    'Microsoft.BingSports'
    'Microsoft.BingTranslator'
    'Microsoft.BingWeather'
    'Microsoft.MicrosoftPowerBIForWindows'
    'Microsoft.MinecraftUWP'
    'Microsoft.NetworkSpeedTest'
    'Microsoft.People'
    'Microsoft.Print3D'
    'Microsoft.SkypeApp'
    'Microsoft.Wallet'
    'Microsoft.WindowsCamera'
    'microsoft.windowscommunicationsapps'
    'Microsoft.WindowsMaps'
    'Microsoft.WindowsPhone'
    'Microsoft.WindowsSoundRecorder'
    'Microsoft.YourPhone'
    'Microsoft.ZuneMusic'
    'Microsoft.ZuneVideo'

    'Microsoft.GetHelp'
    'Microsoft.Getstarted'
    'Microsoft.Messaging'
    'Microsoft.Office.Sway'
    'Microsoft.OneConnect'
    'Microsoft.WindowsFeedbackHub'
    'Microsoft.OutlookForWindows'
    'MSTeams'
    'Microsoft.MicrosoftOfficeHub'
    'Microsoft.BingSearch'

    # generic Windows 11 crap
    'Clipchamp.Clipchamp'

    # Creators Update apps
    'Microsoft.Microsoft3DViewer'

    # Redstone apps
    'Microsoft.BingFoodAndDrink'
    'Microsoft.BingHealthAndFitness'
    'Microsoft.BingTravel'
    'Microsoft.WindowsReadingList'

    # Redstone 5 apps
    'Microsoft.MixedReality.Portal'
    'Microsoft.ScreenSketch'

    # non-Microsoft
    '*PicsArt-PhotoStudio*'
    '*EclipseManager*'
    '*Netflix*'
    '*PolarrPhotoEditor*'
    '*6Wunderkinder*'
    '*LinkedIn*'
    '*AutodeskSketchBook*'
    '*Twitter*'
    '*DisneyMagicKingdoms*'
    '*MarchofEmpires*'
    '*ActiproSoftwareLLC*'
    '*Plex*'
    '*ClearChannelRadio*'
    '*FarmVille*'
    '*Duolingo*'
    '*CyberLinkMediaSuiteEssentials*'
    '*DolbyLaboratories*'
    '*Drawboard*'
    '*Facebook*'
    '*Fitbit*'
    '*Flipboard*'
    '*GAMELOFTSA*'
    '*KeeperSecurityInc*'
    '*NORDCURRENT*'
    '*PandoraMediaInc*'
    '*Playtika*'
    '*Shazam*'
    '*SlingTV*'
    '*SpotifyAB*'
    '*TheNewYorkTimes*'
    '*ThumbmunkeysLtd*'
    '*TuneIn*'
    '*WinZipComputing*'
    '*XINGAG.XING*'
    '*flaregamesGmbH*'
    '*king.com.*'
    '*Yandex.Music*'
    '*WhatsApp*'

    # apps that cannot be removed with Remove-AppxPackage (left here for reference)
    #'Microsoft.BioEnrollment'
    #'Microsoft.MicrosoftEdge'
    #'Microsoft.Windows.Cortana'
    #'Microsoft.WindowsFeedback'
    #'Microsoft.XboxGameCallableUI'
    #'Microsoft.XboxIdentityProvider'
    #'Windows.ContactSupport'

    # the big one
    '*Copilot*'
)

Step "Removing $($apps.Count) bundled apps"
$provisioned = Get-AppxProvisionedPackage -Online
foreach ($app in $apps) {
    Note "removing $app"
    Get-AppxPackage -AllUsers -Name $app -ErrorAction SilentlyContinue |
        Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    $provisioned |
        Where-Object { $_.PackageName -like $app -or $_.DisplayName -like $app } |
        Remove-AppxProvisionedPackage -Online -AllUsers -ErrorAction SilentlyContinue
}

Step 'Stopping the apps from re-installing themselves'
$cdm = @(
    'ContentDeliveryAllowed'
    'FeatureManagementEnabled'
    'OemPreInstalledAppsEnabled'
    'PreInstalledAppsEnabled'
    'PreInstalledAppsEverEnabled'
    'SilentInstalledAppsEnabled'
    'SubscribedContent-314559Enabled'
    'SubscribedContent-338387Enabled'
    'SubscribedContent-338388Enabled'
    'SubscribedContent-338389Enabled'
    'SubscribedContent-338393Enabled'
    'SubscribedContentEnabled'
    'SystemPaneSuggestionsEnabled'
)
New-FolderForced -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
foreach ($key in $cdm) {
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' $key 0
}

Step 'Stopping the Store from auto-downloading apps'
New-FolderForced -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2

Step 'Blocking "suggested applications" from returning'
New-FolderForced -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1

# ===========================================================================
Section 'Optimizing OneDrive (j/k - removing it with prejudice)'
# ===========================================================================

Step 'Running the OneDrive uninstaller'
if (Test-Path "$env:systemroot\System32\OneDriveSetup.exe") {
    & "$env:systemroot\System32\OneDriveSetup.exe" /uninstall
}
if (Test-Path "$env:systemroot\SysWOW64\OneDriveSetup.exe") {
    & "$env:systemroot\SysWOW64\OneDriveSetup.exe" /uninstall
}

Step 'Deleting OneDrive leftovers'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue "$env:localappdata\Microsoft\OneDrive"
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue "$env:programdata\Microsoft OneDrive"
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue "$env:systemdrive\OneDriveTemp"
# Only remove the user's OneDrive folder if it's empty.
if ((Get-ChildItem "$env:userprofile\OneDrive" -Recurse -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue "$env:userprofile\OneDrive"
}

Step 'Disabling OneDrive via group policy'
New-FolderForced -Path 'HKLM:\SOFTWARE\Wow6432Node\Policies\Microsoft\Windows\OneDrive'
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Wow6432Node\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1

Step 'Removing OneDrive from the Explorer sidebar'
New-PSDrive -PSProvider 'Registry' -Root 'HKEY_CLASSES_ROOT' -Name 'HKCR' | Out-Null
New-FolderForced -Path 'HKCR:\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
Set-ItemProperty -Path 'HKCR:\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}' 'System.IsPinnedToNameSpaceTree' 0
New-FolderForced -Path 'HKCR:\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
Set-ItemProperty -Path 'HKCR:\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}' 'System.IsPinnedToNameSpaceTree' 0
Remove-PSDrive 'HKCR'

Step 'Removing the OneDrive run hook for new users'
reg load   'hku\Default' 'C:\Users\Default\NTUSER.DAT' 2>&1 | Out-Null
reg delete 'HKEY_USERS\Default\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' /v 'OneDriveSetup' /f 2>&1 | Out-Null
reg unload 'hku\Default' 2>&1 | Out-Null

Step 'Removing the Start menu shortcut'
Remove-Item -Force -ErrorAction SilentlyContinue "$env:userprofile\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\OneDrive.lnk"

Step 'Removing the OneDrive scheduled task'
Get-ScheduledTask -TaskPath '\' -TaskName 'OneDrive*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false

# ===========================================================================
Section 'Restarting Explorer'
# ===========================================================================

Step 'Restarting Explorer to apply the changes'
Stop-Process -Name explorer -Force
Start-Process 'explorer.exe'

Ok 'Cleanup complete - a reboot is recommended to settle everything.'
