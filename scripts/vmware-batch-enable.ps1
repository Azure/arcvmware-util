<#
.SYNOPSIS
This is a helper script for enabling VMs in a vCenter in batch. It will enable 200 VMs per ARM deployment if guest management is opted for, else 400 VMs per ARM deployment. The script will create the following files:
  vmware-batch.log - log file
  all-deployments-<timestamp>.txt - list of Azure portal links to all deployments created
  vmw-dep-<timestamp>-<batch>.json - ARM deployment files

**There are some lines which are marked with NOTE. Please read the comments and modify the script accordingly. It is recommended to run the script with the DryRun switch first to ensure that the deployments are created as expected.**

Before running this script, please install az cli and the connectedvmware extension.
az extension add --name connectedvmware

The script can be run as a cronjob to enable all VMs in a vCenter.
You can use a service principal for authenticating to azure for this automation. Please refer to the following documentation for more details:
https://docs.microsoft.com/en-us/azure/active-directory/develop/howto-create-service-principal-portal
Then, you can login to azure using the service principal using the following command:
az login --service-principal --username <clientId> --password <clientSecret> --tenant <tenantId>

Following is a sample powershell script to run the script as a cronjob:

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-File "C:\Path\To\vmware-batch-enable.ps1" -VCenterId "/subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter" -EnableGuestManagement -VMCountPerDeployment 3 -DryRun' # Adjust the parameters as needed
$trigger = New-ScheduledTaskTrigger -Daily -At 3am  # Adjust the schedule as needed

Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "EnableVMs"

To unregister the task, run the following command:
Unregister-ScheduledTask -TaskName "EnableVMs"

.PARAMETER VCenterId
The ARM ID of the vCenter where the VMs are located. For example: /subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter

.PARAMETER EnableGuestManagement
If this switch is specified, the script will enable guest management on the VMs. If not specified, guest management will not be enabled.

.PARAMETER VMCountPerDeployment
The number of VMs to enable per ARM deployment. The maximum value is 200 if guest management is enabled, else 400.

.PARAMETER DryRun
If this switch is specified, the script will only create the ARM deployment files. Else, the script will also deploy the ARM deployments.

#>
param(
  [Parameter(Mandatory=$true)]
  [string]$VCenterId,
  [switch]$EnableGuestManagement,
  [int]$VMCountPerDeployment,
  [switch]$DryRun
)

$logFile = Join-Path $PSScriptRoot -ChildPath "vmware-batch.log"

# https://stackoverflow.com/a/40098904/7625884
$PSDefaultParameterValues = @{ '*:Encoding' = 'utf8' }

Write-Host "Setting the TLS Protocol for the current session to TLS 1.3 if supported, else TLS 1.2."
# Ensure TLS 1.2 is accepted. Older PowerShell builds (sometimes) complain about the enum "Tls12" so we use the underlying value
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
# Ensure TLS 1.3 is accepted, if this .NET supports it (older versions don't)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 12288 } catch {}

$VCenterIdFormat = "/subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter"

function Get-TimeStamp {
  return (Get-Date).ToUniversalTime().ToString("[yyyy-MM-ddTHH:mm:ss.fffZ]")
}

$StartTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ss")

$deploymentUrlsFilePath = Join-Path $PSScriptRoot -ChildPath "all-deployments-$StartTime.txt"

function LogText {
  param(
    [Parameter(Mandatory=$true)]
    [string]$Text
  )
  Write-Host "$(Get-TimeStamp) $Text"
  Add-Content -Path $logFile -Value "$(Get-TimeStamp) $Text"
}

function LogError {
  param(
    [Parameter(Mandatory=$true)]
    [string]$Text
  )
  Write-Error "$(Get-TimeStamp) $Text"
  Add-Content -Path $logFile -Value "$(Get-TimeStamp) Error: $Text"
}

function Get-ARMPartsFromID($id) {
  if ($id -match "/+subscriptions/+([^/]+)/+resourceGroups/+([^/]+)/+providers/+([^/]+)/+([^/]+)/+([^/]+)") {
    return @{
      SubscriptionId = $Matches[1]
      ResourceGroup  = $Matches[2]
      Provider       = $Matches[3]
      Type           = $Matches[4]
      Name           = $Matches[5]
    }
  }
  else {
    return $null
  }
}

#Region: ARM Template

# ARM Template part for VM Creation
$VMtpl = @'
{
  "type": "Microsoft.Resources/deployments",
  "apiVersion": "2021-04-01",
  "name": "{{vmName}}-vmcreation",
  "properties": {
    "mode": "Incremental",
    "template": {
      "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
      "contentVersion": "1.0.0.0",
      "resources": [
        {
          "type": "Microsoft.HybridCompute/machines",
          "apiVersion": "2023-03-15-preview",
          "name": "{{vmName}}",
          "kind": "VMware",
          "location": "eastus2euap",
          "properties": {}
        },
        {
          "type": "Microsoft.ConnectedVMwarevSphere/VirtualMachineInstances",
          "apiVersion": "2023-03-01-preview",
          "name": "default",
          "scope": "[concat('Microsoft.HybridCompute/machines', '/', '{{vmName}}')]",
          "properties": {
            "infrastructureProfile": {
              "inventoryItemId": "{{vCenterId}}/InventoryItems/{{moRefId}}"
            }
          },
          "extendedLocation": {
            "type": "CustomLocation",
            "name": "{{customLocationId}}"
          },
          "dependsOn": [
            "[resourceId('Microsoft.HybridCompute/machines','{{vmName}}')]"
          ]
        }
      ]
    }
  }
}
'@

# ARM Template part for Guest Management
$GMtpl = @'
{
  "type": "Microsoft.Resources/deployments",
  "apiVersion": "2021-04-01",
  "name": "{{vmName}}-guestmgmt",
  "dependsOn": [
    "[resourceId('Microsoft.Resources/deployments','{{vmName}}-vmcreation')]"
  ],
  "properties": {
    "mode": "Incremental",
    "template": {
      "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
      "contentVersion": "1.0.0.0",
      "resources": [
        {
          "type": "Microsoft.HybridCompute/machines",
          "apiVersion": "2023-03-15-preview",
          "name": "{{vmName}}",
          "kind": "VMware",
          "location": "eastus2euap",
          "properties": {},
          "identity": {
            "type": "SystemAssigned"
          }
        },
        {
          "type": "Microsoft.ConnectedVMwarevSphere/VirtualMachineInstances/guestAgents",
          "apiVersion": "2023-03-01-preview",
          "name": "default/default",
          "scope": "[concat('Microsoft.HybridCompute/machines', '/', '{{vmName}}')]",
          "properties": {
            "provisioningAction": "install",
            "credentials": {
              "username": "{{username}}",
              "password": "{{password}}"
            }
          },
          "dependsOn": [
            "[resourceId('Microsoft.HybridCompute/machines','{{vmName}}')]"
          ]
        }
      ]
    }
  }
}
'@

$deploymentTemplate = @'
{
  "$schema": "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "resources": [
    {{resources}}
  ]
}
'@

#EndRegion: ARM Template

LogText @"
Starting script with the following parameters:
  VCenterId: $VCenterId
  EnableGuestManagement: $EnableGuestManagement
  VMCountPerDeployment: $VMCountPerDeployment
  DryRun: $DryRun
"@

if (!(Get-Command az -ErrorAction SilentlyContinue)) {
  LogError "az command is not found. Please install azure cli before running this script."
  exit
}

if (!(az extension show --name connectedvmware -o json)) {
  LogError "The Azure CLI extension connectedvmware is not installed. Please run 'az extension add --name connectedvmware' before running this script."
  exit
}

$resInfo = Get-ARMPartsFromID $VCenterId
if (!$resInfo) {
  LogError "Invalid VCenterId: $VCenterId . Expected format: $VCenterIdFormat"
  exit
}

$subId = $resInfo.SubscriptionId
$resourceGroupName = $resInfo.ResourceGroup
$vCenterName = $resInfo.Name

if ($resInfo.Provider -ne "Microsoft.ConnectedVMwarevSphere") {
  LogError "Invalid VCenterId: $VCenterId . Expected format: $VCenterIdFormat"
  exit
}
if ($resInfo.Type -ne "VCenters") {
  LogError "Invalid VCenterId: $VCenterId . Expected format: $VCenterIdFormat"
  exit
}

$customLocationId = az connectedvmware vcenter show --resource-group $resourceGroupName --name $vCenterName --query 'extendedLocation.name' -o tsv
if (!$customLocationId) {
  LogError "Failed to extract custom location id from vCenter $vCenterName"
  exit
}

LogText "Extracted custom location: $customLocationId"

$vmInventoryList = az connectedvmware vcenter inventory-item list --resource-group $resourceGroupName --vcenter $vCenterName --query '[?kind == `VirtualMachine`].{moRefId:moRefId, moName:moName, managedResourceId:managedResourceId}' -o json | ConvertFrom-Json

LogText "Found $($vmInventoryList.Length) VMs in the inventory"

$nonManagedVMs = @()

for ($i = 0; $i -lt $vmInventoryList.Length; $i++) {
  if (!$vmInventoryList[$i].managedResourceId) {
    $nonManagedVMs += $vmInventoryList[$i]
  }
}

LogText "Found $($nonManagedVMs.Length) non-managed VMs in the inventory"

function normalizeMoName() {
  param(
    [Parameter(Mandatory=$true)]
    [string]$name
  )
  return $name.toLower() -replace "[^a-z0-9-]", "-"
}

$maxVMCountPerDeployment = 200
if (!$EnableGuestManagement) {
  $maxVMCountPerDeployment = 400
}

if (!$VMCountPerDeployment) {
  $vmCountPerDeployment = $maxVMCountPerDeployment
}
else {
  if ($VMCountPerDeployment -gt $maxVMCountPerDeployment) {
    LogError "Invalid VMCountPerDeployment: $VMCountPerDeployment. Max allowed value is 400 if guest management is not enabled, else 200. Using max allowed value."
    $VMCountPerDeployment = $maxVMCountPerDeployment
  }
  $vmCountPerDeployment = $VMCountPerDeployment
}

$resources = @()

for ($i = 0; $i -lt $nonManagedVMs.Length; $i++) {
  $moRefId = $nonManagedVMs[$i].moRefId
  $vmName = normalizeMoName $nonManagedVMs[$i].moName
  $vmName += "-$moRefId"

  $vmResource = $VMtpl `
    -replace "{{vmName}}", $vmName `
    -replace "{{moRefId}}", $moRefId `
    -replace "{{vCenterId}}", $VCenterId `
    -replace "{{customLocationId}}", $customLocationId
  $resources += $vmResource

  if ($EnableGuestManagement) {
    # NOTE: Set the username and password here. You can also use environment variables to fetch the username and password.
    $username = "Administrator"
    $password = "Password"

    $gmResource = $GMtpl `
      -replace "{{vmName}}", $vmName `
      -replace "{{username}}", $username `
      -replace "{{password}}", $password
    $resources += $gmResource
  }

  $totalBatches = [int](($nonManagedVMs.Length + $vmCountPerDeployment -1) / $vmCountPerDeployment)
  if (($i + 1) % $vmCountPerDeployment -eq 0 -or ($i + 1) -eq $nonManagedVMs.Length) {
    $deployment = $deploymentTemplate -replace "{{resources}}", ($resources -join ",")

    $batch = [int](($i + 1) / $vmCountPerDeployment)
    $deploymentName = "vmw-dep-$StartTime-$batch"
    $deploymentFilePath = Join-Path $PSScriptRoot -ChildPath "$deploymentName.json"

    # NOTE: Uncomment the following lines if you want to pretty print the ARM deployment files.
    # $deployment = ConvertFrom-Json | ConvertTo-Json -Depth 100

    $deployment `
    | Out-File -FilePath $deploymentFilePath -Encoding UTF8

    $deploymentId = "/subscriptions/$subId/resourceGroups/$resourceGroupName/providers/Microsoft.Resources/deployments/$deploymentName"
    $deploymentUrl = "https://portal.azure.com/#resource$($deploymentId)/overview"
    Add-Content -Path $deploymentUrlsFilePath -Value $deploymentUrl

    LogText "($batch / $totalBatches) Deploying $deploymentFilePath"
    
    if (!$DryRun) {
      az deployment group create --resource-group $resourceGroupName --name $deploymentName --template-file $deploymentFilePath --verbose *>> $logFile
    }
    $resources = @()

    # NOTE: set sleep time between deployments here, if needed.
    Start-Sleep -Seconds 5
  }
}
