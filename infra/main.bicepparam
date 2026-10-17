using './main.bicep'

param baseName = 'prodint'

// West Europe is currently CLOSED to new customers (Azure region-access policy:
// https://aka.ms/locationineligible). A tenant with no existing resources there gets
// [RequestDisallowedByAzure] on every resource. North Europe is West Europe's paired
// region and has the same latency profile for EU/UK users.
param location = 'northeurope'

// Hosting is Flex Consumption (no SKU parameter anymore): pay-per-execution, scales to
// zero, free monthly grants. These two knobs replace the old functionAppSku parameter:
//   - instanceMemoryMB: 512 / 2048 / 4096 (2048 = 1 vCPU, the balanced default)
//   - maximumInstanceCount: the scale-out ceiling (this demo needs very little)
param instanceMemoryMB = 2048
param maximumInstanceCount = 20

// Durable Task Scheduler: Consumption SKU = pay-per-action, no base fee.
// The Function App talks to it via managed identity (DTS_CONNECTION_STRING app setting).
param dtsSku = 'Consumption'
param dtsIpAllowlist = ['0.0.0.0/0']

// The Functions host (AzureWebJobsStorage) still uses this storage account for its own
// bookkeeping; the durable orchestration state now lives in the DTS task hub instead.
param storageSku = 'Standard_GRS'

param retentionDays = 30
param tags = {
  owner: 'chamb'
  project: 'integration-example'
  env: 'dev'
}
