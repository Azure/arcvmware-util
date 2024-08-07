$ProgressPreference = 'SilentlyContinue'
$tmpFolder = Join-Path $PSScriptRoot ".temp"
if ((Test-Path -Path $tmpFolder) -eq $false) {
  New-Item -ItemType Directory -Path $tmpFolder | Out-Null
}
$govcExe = Join-Path $tmpFolder "govc.exe"
if((Test-Path -Path $govcExe) -eq $false)
{
  Write-Host "Downloading govc..."
  $govcZipPath = Join-Path $tmpFolder "govc_windows_amd64.exe.zip"
  Invoke-WebRequest https://github.com/vmware/govmomi/releases/download/v0.34.2/govc_windows_amd64.zip -OutFile $govcZipPath
  Expand-Archive -Force $govcZipPath -DestinationPath $tmpFolder
}

$env:GOVC_INSECURE = 'true'

Write-Host -ForegroundColor Yellow "Please provide the VCenter details"
while ($true) {
  $vCenterAddress = Read-Host -Prompt "Enter the vCenter Address (e.g. vcenter.contoso.com, 1.2.3.4:443). Please do not include https:// or trailing slash"
  if (!$vCenterAddress) {
    Write-Host -ForegroundColor Red "vCenter Address cannot be empty"
    continue
  }
  $vCenterUser = Read-Host "Please enter vCenter username"
  if (!$vCenterUser) {
    Write-Host -ForegroundColor Red "vCenter username cannot be empty"
    continue
  }
  $passwordSec = Read-Host "Please enter vCenter password" -AsSecureString
  $vCenterPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($passwordSec))
  if (!$vCenterPass) {
    Write-Host -ForegroundColor Red "vCenter password cannot be empty"
    continue
  }
  break
}

$env:GOVC_URL = $vCenterAddress
$env:GOVC_USERNAME = $vCenterUser
$env:GOVC_PASSWORD = $vCenterPass

# $env:GOVC_URL = "vcenter.contoso.com"
# $env:GOVC_USERNAME = "contoso@vsphere.local"
# $env:GOVC_PASSWORD = "contosopass"

Write-Host -ForegroundColor Yellow "Please provide the Windows VM details"
while ($true) {
  $VMName = Read-Host -Prompt "Enter the name of the Windows VM"
  if (!$VMName) {
    Write-Host -ForegroundColor Red "VM name cannot be empty"
    continue
  }
  $vmPath = (. $govcExe find -type m -name $VMName)
  if (!$vmPath) {
    Write-Host "VM not found: $VMName"
    continue
  }
  $VMUser = Read-Host "Please enter the Windows VM username"
  if (!$VMUser) {
    Write-Host -ForegroundColor Red "VM username cannot be empty"
    continue
  }
  $passwordSec = Read-Host "Please enter the Windows VM password" -AsSecureString
  $VMPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($passwordSec))
  if (!$VMPass) {
    Write-Host -ForegroundColor Red "VM password cannot be empty"
    continue
  }
  break
}

# $VMUser = 'contoso\administrator'
# $VMPass = 'contosovmpass'

$VMCreds = "$($VMUser):$($VMPass)"

$scriptContents = @'
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent());
$isRunningElevated = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);
Write-Host "`nIs running elevated: $isRunningElevated`n"
Write-Host "`nThe current user is part of the following groups:"
Write-Host "$(whoami /groups /FO csv | ConvertFrom-Csv | ConvertTo-Json -Compress)"
Write-Host "`nDetails of the processes vmtoolsd.exe running on the system using Get-Process`n"
Get-Process -Name vmtoolsd -IncludeUserName | Select-Object Id, UserName, Name, ProcessName | ConvertTo-Json -Compress
Write-Host "`nDetails of the processes vmtoolsd.exe running on the system using Win32_Process`n"
Get-WmiObject Win32_Process -Filter "name='vmtoolsd.exe'" | Select-Object Name, @{Name = "UserName"; Expression = { $_.GetOwner().Domain + "\" + $_.GetOwner().User } } | ConvertTo-Json -Compress
Write-Host "`nDone collecting required info`n`n"
'@

$EncodedScript = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($scriptContents))

. $govcExe guest.run -vm $vmPath -l $VMCreds "powershell.exe -NoLogo -NoProfile -NonInteractive -executionpolicy bypass -encodedCommand $EncodedScript" | Out-File ps-elevation-output.log

Write-Host -ForegroundColor Yellow "`n`nPlease check the file ps-elevation-output.log for the output of the script."
$ProgressPreference = 'Continue'
