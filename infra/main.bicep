// =============================================================================
//  Deploy the ProductIntegration durable-functions example to Azure.
//
//  This file provisions the INFRASTRUCTURE only (storage, Function App on the
//  Flex Consumption plan, Application Insights, and a Durable Task Scheduler
//  with a task hub). It does not deploy your code — publish that afterwards.
//
//  This machine has no az CLI, so use the PowerShell path (from the repo root):
//    Import-Module Az.Accounts, Az.Resources
//    Connect-AzAccount
//    . infra/deploy.ps1        # dot-source: builds main.bicep, validates, deploys
//
//  (With the az CLI it would be:
//     az group create -n rg-integration-example -l northeurope
//     az deployment group create -g rg-integration-example `
//       --file infra/main.bicep --parameters infra/main.bicepparam )
//
//  (Do NOT use westeurope: Azure currently refuses new customers there —
//   every resource fails with [RequestDisallowedByAzure]. See main.bicepparam.)
//
//  Then publish the code:
//    cd src/ProductIntegration
//    func azure functionapp publish <functionAppName from the outputs>
//
//  After publishing, the same endpoints work remotely:
//    POST https://<name>.azurewebsites.net/api/products/import
//    GET  https://<name>.azurewebsites.net/api/products/import/{runId}/status
//    GET  https://<name>.azurewebsites.net/api/products/destination
// =============================================================================

@description('Prefix used to name every resource. Lowercase, no spaces, 2-12 chars.')
@minLength(2)
@maxLength(12)
param baseName string = 'prodint'

@description('Region for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

// HOSTING: Flex Consumption (replaces the old B1/EP1/Y1 plan options).
// Why: Linux Consumption (Y1) is RETIRED for new Function Apps, and dedicated
// tiers like B1 need an "App Service cores" quota this subscription does not have
// in northeurope (deployment failed with "Current Limit (B1 VMs): 0"). Flex has
// its own regional quota (default 250 vCPU), scales to zero, has free monthly
// grants (1M executions + 400k GB-s), and is fully supported for Durable
// Functions with a Durable Task Scheduler backend.

@description('Flex Consumption instance memory in MB. 2048 (1 vCPU) is the balanced default; 512 is cheapest, 4096 for heavy payloads.')
@allowed([512, 2048, 4096])
param instanceMemoryMB int = 2048

@description('Flex Consumption scale-out ceiling (1-1000 instances). The app scales to zero when idle; this is only the upper bound.')
@minValue(1)
@maxValue(1000)
param maximumInstanceCount int = 20

@description('Durable Task Scheduler SKU. Consumption = pay-per-action, no base fee, <=500 actions/s, 30-day retention (right-sized for this demo). Dedicated = fixed monthly cost per capacity unit (1 CU = 2,000 actions/s + 50 GB, 90-day retention).')
@allowed(['Consumption', 'Dedicated'])
param dtsSku string = 'Consumption'

@description('Durable Task Scheduler capacity. Only used when dtsSku is Dedicated (1-3 per deployment).')
@minValue(1)
@maxValue(3)
param dtsCapacity int = 1

@description('IP allowlist for the Durable Task Scheduler. 0.0.0.0/0 allows any client. Outbound IPs of a serverless Function App are dynamic, so locking them down needs private endpoints.')
param dtsIpAllowlist array = ['0.0.0.0/0']

@description('Storage account SKU. Durable Functions runs on Azure Storage queues/tables, so this account is on the hot path. Standard_GRS is the safe default; "Durables" is purpose-built for Durable Functions and cheaper for durable-heavy workloads.')
@allowed(['Standard_LRS', 'Standard_GRS', 'Standard_GRR', 'Standard_G3', 'Standard_RAGRS', 'PremiumV2', 'Durables'])
param storageSku string = 'Standard_GRS'

@description('Log retention in days for the Log Analytics workspace backing App Insights.')
@minValue(7)
@maxValue(90)
param retentionDays int = 30

@description('Extra tags applied to every resource.')
param tags object = {}

// -----------------------------------------------------------------------------
// Naming + SKU tables
// -----------------------------------------------------------------------------

var unique = uniqueString(resourceGroup().id, baseName)
var namePrefix = toLower('${baseName}-${unique}')

// Storage account names: 3-24 chars, lowercase alphanumeric only (no hyphens).
var storageName = toLower(take('stg${baseName}${unique}', 24))
var appName = take('${baseName}-fn-${unique}', 62)
var planName = take('${baseName}-plan-${unique}', 39)
var lawName = 'law-${namePrefix}'
var aiName = '${baseName}-ai-${unique}'

// Flex pulls the deployed code zip from a blob container on the storage account
// (this replaces WEBSITE_RUN_FROM_PACKAGE / content shares used by older plans).
var deploymentContainerName = 'app-package-${take(appName, 32)}-${take(unique, 7)}'

// Durable Task Scheduler + task hub: the managed replacement for the local DTS
// emulator + Azurite durable backend. Scheduler/task-hub names must match
// ^[a-zA-Z0-9-]{3,64}$ — namePrefix is lowercase alphanumerics + hyphens.
var dtsName = take('dts-${namePrefix}', 64)
var taskHubName = '${baseName}-hub'

// Built-in role definition ids for the workload identity (keyless storage + DTS access).
// roleDefinitionId must be a FULLY QUALIFIED role definition resource id — a bare GUID is
// rejected by the ARM deployment engine.
// GUIDs verified against the official Azure quickstart template
// (function-app-flex-managed-identities) and a live deployment: the earlier values
// b696d7c6.../97844e71... do not exist as role definitions (RoleDefinitionDoesNotExist).
var roleStorageBlobDataOwner = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
var roleStorageQueueDataContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
var roleStorageTableDataContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
// 'Durable Task Data Contributor' — the data-plane role an app needs to run
// orchestrations against a DTS task hub (GUID from the official DTS samples).
var roleDurableTaskDataContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0ad04412-c4d5-4796-b79c-f76d14c8d402')

// -----------------------------------------------------------------------------
// Monitoring: Log Analytics + Application Insights
// -----------------------------------------------------------------------------

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionDays
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// NOTE: the Microsoft.Insights/* resource types have no types in the local Bicep type index,
// so the editor shows an informational "does not have types available" message. It does not
// block deployment. If you want a fully typed file, bump the Bicep extension/CLI version.
// API version note: 2022-06-15 is NOT registered in northeurope — deployment fails
// with NoRegisteredProviderFound. 2020-02-02 is the newest version registered in every
// region and is what the official Azure quickstart templates use. Retention is handled
// by the Log Analytics workspace (retentionInDays above), so it is not set here.
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: aiName
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// The old 'components/diagnosticSourceSettings' child resource (Durable Functions
// "Diagnostic Sources" tracking) has NO ARM/Bicep API version at all — it cannot be
// deployed as code. Enable it in the portal instead: App Insights resource ->
// "Diagnostic Sources" -> add "Durable Functions". With a Durable Task Scheduler the
// richer live orchestration view is the task hub dashboard (see the outputs below).

// -----------------------------------------------------------------------------
// Storage: the Durable Task hub (queues + tables) and the Functions state store
// -----------------------------------------------------------------------------

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  kind: 'StorageV2'
  tags: tags
  sku: { name: storageSku }
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    // The app now uses keyless (managed-identity) storage auth — see the app settings and
    // RBAC below. Shared-key access stays enabled only as a fallback (e.g. connecting
    // Azurite-style tools or a connection string); set false to enforce keyless-only.
    allowSharedKeyAccess: true
    publicNetworkAccess: 'Enabled' // the Functions host talks to queues/tables directly; private endpoints need extra config
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Flex Consumption deploys your code as a zip into a blob container on this
// storage account (see functionAppConfig.deployment below).
resource storageBlobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: false }
  }
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: storageBlobServices
  name: deploymentContainerName
  properties: {
    publicAccess: 'None'
  }
}

// -----------------------------------------------------------------------------
// Durable Task Scheduler (DTS) — managed backend for Durable Functions
// -----------------------------------------------------------------------------
// Replaces the local DTS emulator + Azurite durable backend. host.json already
// points at it: storageProvider.type = 'azureManaged',
// connectionStringName = 'DTS_CONNECTION_STRING', hubName = '%TASKHUB_NAME%' —
// no host.json change is needed for the cloud deployment.

resource dts 'Microsoft.DurableTask/schedulers@2025-11-01' = {
  name: dtsName
  location: location
  tags: tags
  properties: {
    ipAllowlist: dtsIpAllowlist // REQUIRED property per the ARM schema
    // publicNetworkAccess exists only in the 2026-05-01-preview API version; the
    // scheduler is publicly reachable by default on 2025-11-01.
    sku: dtsSku == 'Dedicated' ? { name: dtsSku, capacity: dtsCapacity } : { name: dtsSku }
  }
}

resource taskHub 'Microsoft.DurableTask/schedulers/taskhubs@2025-11-01' = {
  parent: dts
  name: taskHubName
}

// -----------------------------------------------------------------------------
// Workload identity for storage + DTS data-plane access
// -----------------------------------------------------------------------------
// A USER-assigned identity (not system-assigned): the RBAC role assignments below
// only reference this identity, so they are created BEFORE the Function App —
// Flex downloads the deployment zip at site-creation time, and the identity must
// already have blob access at that moment (a system-assigned identity would be a
// chicken-and-egg dependency).

resource workloadIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'uai-${namePrefix}'
  location: location
  tags: tags
}

// -----------------------------------------------------------------------------
// Function App (.NET isolated, Functions v4, Flex Consumption)
// -----------------------------------------------------------------------------

resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  kind: 'functionapp'
  tags: tags
  sku: {
    name: 'FC1' // the only Flex Consumption SKU name
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true // Linux plan
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: appName
  location: location
  kind: 'functionapp,linux' // Flex Consumption is Linux-only
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${workloadIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    siteConfig: {
      minTlsVersion: '1.2'
      cors: {
        allowedOrigins: ['https://portal.azure.com']
        supportCredentials: false
      }
    }
    // Flex Consumption replaces the old app settings / siteConfig knobs with this
    // structured block. On Flex these are DEPRECATED and must not be set:
    // FUNCTIONS_EXTENSION_VERSION, FUNCTIONS_WORKER_RUNTIME(_VERSION), linuxFxVersion,
    // netFrameworkVersion, alwaysOn, use32BitWorkerProcess, ftpsState, WEBSITE_* ...
    // https://learn.microsoft.com/azure/azure-functions/functions-flex-consumption-plan
    functionAppConfig: {
      runtime: {
        name: 'dotnet-isolated'
        version: '8.0' // matches TargetFramework net8.0 in the csproj
      }
      scaleAndConcurrency: {
        maximumInstanceCount: maximumInstanceCount
        instanceMemoryMB: instanceMemoryMB
      }
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: workloadIdentity.id
          }
        }
      }
    }
  }
}

// App settings = the production equivalent of local.settings.json.
// local.settings.json is deliberately NOT deployed (CopyToPublishDirectory=Never),
// so anything the app needs in Azure must appear here.
// Do NOT add FUNCTIONS_EXTENSION_VERSION / FUNCTIONS_WORKER_RUNTIME / WEBSITE_DNS_SERVER
// here — they are deprecated on Flex Consumption (the runtime comes from
// functionAppConfig above). The Functions host still needs AzureWebJobsStorage for
// its own bookkeeping (function keys, locks) — that is separate from the durable
// backend, which now lives in DTS.
resource appSettings 'Microsoft.Web/sites/config@2024-04-01' = {
  name: 'appsettings'
  parent: functionApp
  properties: {
    // --- Durable Task Scheduler (host.json: connectionStringName = 'DTS_CONNECTION_STRING',
    //     hubName = '%TASKHUB_NAME%'). Managed-identity auth needs the workload identity to
    //     hold 'Durable Task Data Contributor' on the scheduler (role assignment below).
    DTS_CONNECTION_STRING: 'Endpoint=${dts.properties.endpoint};Authentication=ManagedIdentity;ClientID=${workloadIdentity.properties.clientId}'
    TASKHUB_NAME: taskHub.name

    // --- Keyless Azure Storage auth for the Functions host (replaces Azurite) ---
    AzureWebJobsStorage__accountName: storage.name
    AzureWebJobsStorage__credential: 'managedidentity'
    AzureWebJobsStorage__clientId: workloadIdentity.properties.clientId
    AZURE_CLIENT_ID: workloadIdentity.properties.clientId // pins DefaultAzureCredential to the same identity

    // --- Application Insights (consumed by AddApplicationInsightsTelemetryWorkerService in Program.cs) ---
    APPLICATIONINSIGHTS_CONNECTION_STRING: appInsights.properties.ConnectionString
    APPINSIGHTS_INSTRUMENTATIONKEY: appInsights.properties.InstrumentationKey

    // --- Optional Durable Task tuning (overrides host.json values) ---
    // AzureFunctionsJobHost__extensions__durableTask__maxConcurrentActivities: '16'
    // AzureFunctionsJobHost__extensions__durableTask__maxConcurrentOrchestratorFunctions: '4'
  }
}

// RBAC for the workload identity: blob read/write (host state + deployment zip),
// queue + table (WebJobs host bookkeeping), and DTS data-plane access.
resource roleBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, workloadIdentity.id, 'blob-data-owner')
  properties: {
    principalId: workloadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleStorageBlobDataOwner
  }
}

resource roleQueueContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, workloadIdentity.id, 'queue-data-contributor')
  properties: {
    principalId: workloadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleStorageQueueDataContributor
  }
}

resource roleTableContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, workloadIdentity.id, 'table-data-contributor')
  properties: {
    principalId: workloadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleStorageTableDataContributor
  }
}

resource roleDtsDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: dts
  name: guid(dts.id, workloadIdentity.id, 'durable-task-data-contributor')
  properties: {
    principalId: workloadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDurableTaskDataContributor
  }
}

// -----------------------------------------------------------------------------
// Outputs / deploy hints
// -----------------------------------------------------------------------------

output functionAppName string = functionApp.name
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output statusUrlTemplate string = 'https://${functionApp.properties.defaultHostName}/api/products/import/{runId}/status'
output storageAccountName string = storage.name
output applicationInsightsName string = appInsights.name
output applicationInsightsId string = appInsights.id
output logAnalyticsWorkspaceId string = logAnalytics.id

output dtsSchedulerName string = dts.name
output dtsEndpoint string = dts.properties.endpoint // https://<scheduler>.<region>.durabletask.io
output taskHubName string = taskHub.name
output taskHubDashboardHint string = 'Portal -> Durable Task Scheduler -> ${dts.name} -> Task hubs -> ${taskHub.name} -> "Open dashboard" shows live orchestrations (same view as the local emulator dashboard).'

output publishCommand string = 'cd src/ProductIntegration; func azure functionapp publish ${functionApp.name}'
