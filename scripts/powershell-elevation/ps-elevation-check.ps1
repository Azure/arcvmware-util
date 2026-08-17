$ProgressPreference = 'SilentlyContinue'
$tmpFolder = Join-Path $PSScriptRoot ".temp"
if ((Test-Path -Path $tmpFolder) -eq $false) {
  New-Item -ItemType Directory -Path $tmpFolder | Out-Null
}
$govcExe = Join-Path $tmpFolder "govc.exe"
if((Test-Path -Path $govcExe) -eq $false)
{
  Write-Host "Downloading govc..."
  $govcZipPath = Join-Path $tmpFolder "govc_Windows_x86_64.zip"
  Invoke-WebRequest https://github.com/vmware/govmomi/releases/download/v0.34.2/govc_Windows_x86_64.zip -OutFile $govcZipPath
  Expand-Archive -Force $govcZipPath -DestinationPath $tmpFolder
}

# Verify the vCenter certificate. If vCenter uses a self-signed certificate, either trust its
# certificate authority on this machine, or pin the certificate thumbprint when prompted below.
$env:GOVC_INSECURE = 'false'

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

# Optional: pin the vCenter certificate to an expected thumbprint. This verifies the server
# identity without needing the issuing authority in the machine trust store. Get the thumbprint
# from a trusted network with: govc about.cert -u <vcenter> -k -thumbprint
$vCenterThumbprint = Read-Host "Enter the vCenter certificate SHA-1 thumbprint to pin (optional, press Enter to skip)"
if ($vCenterThumbprint) {
  $knownHostsFile = Join-Path $tmpFolder "known_hosts"
  Set-Content -Path $knownHostsFile -Value "$($vCenterAddress.Split('/')[0]) $vCenterThumbprint" -Encoding ascii
  $env:GOVC_TLS_KNOWN_HOSTS = $knownHostsFile
}

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
    Write-Host "If the vCenter connection itself failed, the certificate may not be trusted. Trust the vCenter certificate authority on this machine, or re-run and pin the certificate thumbprint when prompted."
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

# Pass the guest credentials through the environment rather than the `-l <user>:<password>`
# argument, so they are not readable in the govc.exe command line by other processes on the host.
$env:GOVC_GUEST_LOGIN = "$($VMUser):$($VMPass)"

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

. $govcExe guest.run -vm $vmPath "powershell.exe -NoLogo -NoProfile -NonInteractive -executionpolicy bypass -encodedCommand $EncodedScript" | Out-File ps-elevation-output.log

Write-Host -ForegroundColor Yellow "`n`nPlease check the file ps-elevation-output.log for the output of the script."
$ProgressPreference = 'Continue'
