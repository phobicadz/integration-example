# Requires an authenticated Az context in the CURRENT session.
# Usage (from the repo root):  . infra/deploy.ps1     (dot-source it — do NOT run it in a
# child powershell process: the Az context and the user-scoped Az modules are per-session).
$ErrorActionPreference = 'Stop'

Import-Module Az.Accounts, Az.Resources -ErrorAction Stop

$rgName = 'Fanny'
$location = 'uksouth'
$bicepFile = Join-Path $PSScriptRoot 'main.bicep'
$templateFile = Join-Path $PSScriptRoot 'main.deploy.json'
$outFile = Join-Path $PSScriptRoot 'deployment-outputs.json'

# Parameter values mirror infra/main.bicepparam. Az PowerShell's -TemplateParameterFile does
# not accept .bicepparam files, and this Bicep CLI cannot build one either, so the values are
# passed explicitly to the ARM template built from main.bicep.
$params = @{
  baseName               = 'prodint'
  location               = $location
  instanceMemoryMB       = 2048
  maximumInstanceCount   = 20
  dtsSku                 = 'Consumption'
  dtsIpAllowlist         = @('0.0.0.0/0')
  storageSku             = 'Standard_GRS'
  retentionDays          = 30
  tags                   = @{ owner = 'chamb'; project = 'integration-example'; env = 'dev' }
}

# Build main.bicep -> ARM JSON so the deployment uses a validated template.
$bicep = Join-Path $HOME '.localbin\bicep.exe'
if (-not (Test-Path $bicep)) { throw "Bicep CLI not found at $bicep" }
Write-Host '[0/3] Building main.bicep into an ARM template ...'
& $bicep build $bicepFile --outfile $templateFile
if (-not (Test-Path $templateFile)) { throw 'Bicep build produced no template.' }

$ctx = Get-AzContext
if (-not $ctx) { throw 'No Azure context. Run Connect-AzAccount first.' }
Write-Host "Subscription: $($ctx.Subscription.Name) ($($ctx.Subscription.Id))"
Write-Host "Tenant      : $($ctx.Tenant.Id)"

Write-Host "`n[1/3] Ensuring resource group '$rgName' in $location ..."
# A resource group's region is immutable. If one exists in another region (e.g. the earlier
# westeurope attempt), it must be deleted and recreated — resources cannot be moved across
# regions either, so an empty group is simply replaced.
$existing = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
if ($existing -and $existing.Location -ne $location) {
  Write-Host "  existing group is in '$($existing.Location)' — deleting and recreating in $location ..."
  Remove-AzResourceGroup -Name $rgName -Force | Out-Null
  $existing = $null
}
if (-not $existing) {
  New-AzResourceGroup -Name $rgName -Location $location -Force | Out-Null
  Write-Host '  created.'
} else {
  Write-Host '  already exists in the right region, reusing.'
}

Write-Host "`n[2/3] Validating the template against the subscription in $location ..."
$validation = $null
try {
  $validation = Test-AzResourceGroupDeployment `
    -ResourceGroupName $rgName `
    -TemplateFile $templateFile `
    -TemplateParameterObject $params `
    -Mode Incremental `
    -SkipTemplateParameterPrompt `
    -ErrorAction Stop
} catch {
  Write-Host "  VALIDATION THREW: $($_.Exception.Message)"
  throw
}

if ($validation) {
  Write-Host '  VALIDATION ERRORS:'
  foreach ($e in $validation) {
    Write-Host ("   - [{0}] {1}" -f $e.Code, $e.Message)
    foreach ($d in @($e.Details)) {
      if ($d) { Write-Host ("       -> [{0}] {1}" -f $d.Code, $d.Message) }
    }
  }
  throw 'Template validation failed; deployment not attempted.'
}
Write-Host '  validation passed.'

Write-Host "`n[3/3] Deploying infrastructure ..."
$deployment = $null
try {
  $deployment = New-AzResourceGroupDeployment `
    -ResourceGroupName $rgName `
    -Name 'productintegration' `
    -TemplateFile $templateFile `
    -TemplateParameterObject $params `
    -Mode Incremental `
    -SkipTemplateParameterPrompt `
    -ErrorAction Stop
  Write-Host "  ProvisioningState: $($deployment.ProvisioningState)"
} catch {
  Write-Host "  DEPLOYMENT FAILED: $($_.Exception.Message)"
  try {
    $ops = Get-AzResourceGroupDeploymentOperation -ResourceGroupName $rgName -Name 'productintegration' -ErrorAction Stop
    foreach ($op in $ops) {
      if ($op.ProvisioningState -ne 'Succeeded') {
        Write-Host ("   - resource={0} status={1}" -f $op.ResourceName, $op.ProvisioningState)
        if ($op.StatusMessage) {
          Write-Host ('       statusMessage: ' + (($op.StatusMessage | Out-String) -replace '\s+', ' ').Trim())
        }
      }
    }
  } catch {
    Write-Host "   (could not read deployment operations: $($_.Exception.Message))"
  }
  throw
}

$outputs = @{}
foreach ($o in $deployment.Outputs.GetEnumerator()) {
  $outputs[$o.Key] = $o.Value.Value
}
$outputs | ConvertTo-Json -Depth 6 | Set-Content -Path $outFile -Encoding utf8

Write-Host "`n=== Deployment outputs ==="
foreach ($key in @('functionAppName', 'functionAppUrl', 'statusUrlTemplate', 'storageAccountName', 'applicationInsightsName', 'dtsSchedulerName', 'dtsEndpoint', 'taskHubName', 'publishCommand')) {
  if ($outputs.ContainsKey($key)) { Write-Host ("{0,-28}: {1}" -f $key, $outputs[$key]) }
}
Write-Host "`nFull outputs written to $outFile"
