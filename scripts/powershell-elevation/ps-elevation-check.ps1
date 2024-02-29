# if govc is not installed, install it
if (-not (Get-Command govc -ErrorAction SilentlyContinue)) {
  $url = "https://github.com/vmware/govmomi/releases/download/v0.34.2/govc_Windows_x86_64.zip"
  Invoke-WebRequest -Uri $url -OutFile govc.zip
  Expand-Archive -Path govc.zip -DestinationPath $env:ProgramFiles
}

$env:GOVC_INSECURE = 'true'

$vCenterAddress = Read-Host -Prompt "Enter the vCenter Address (e.g. vcenter.contoso.com, 1.2.3.4:443). Please do not include https:// or trailing slash"
$vCenterCredential = Get-Credential -Message "Enter the vCenter credentials"
$vCenterUser = $vCenterCredential.UserName
$vCenterPass = $vCenterCredential.GetNetworkCredential().Password
$env:GOVC_URL = $vCenterAddress
$env:GOVC_USERNAME = $vCenterUser
$env:GOVC_PASSWORD = $vCenterPass

# $env:GOVC_URL = "vcenter.contoso.com"
# $env:GOVC_USERNAME = "contoso@vsphere.local"
# $env:GOVC_PASSWORD = "contosopass"

$VMCredential = Get-Credential -Message "Enter the credentials for the Windows VM"
$VMUser = $VMCredential.UserName
$VMPass = $VMCredential.GetNetworkCredential().Password

# $VMUser = 'contoso\administrator'
# $VMPass = 'contosovmpass'

$VMCreds = "$($VMUser):$($VMPass)"

$VMName = Read-Host -Prompt "Enter the name of the Windows VM"

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
$vmPath = (govc find -type m -name vm-01-acces-local)
if (!$vmPath) {
  Write-Host "VM not found: $VMName"
  exit 1
}

govc guest.run -vm $vmPath -l $VMCreds "powershell.exe -NoLogo -NoProfile -NonInteractive -executionpolicy bypass -encodedCommand $EncodedScript" | Out-File ps-elevation-output.log

Write-Host "Please check the file ps-elevation-output.log for the output of the script."
