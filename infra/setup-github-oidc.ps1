# =============================================================================
# One-time setup for GitHub Actions -> Azure publishing (OIDC, no secrets).
#
# Creates, in the same resource group as the Function App:
#   1. a user-assigned managed identity  (id-integration-example-ci)
#   2. a federated identity credential   (trusts this GitHub repo's OIDC token)
#   3. two role assignments              (Contributor on the RG, Website
#                                         Contributor on the Function App)
#
# Then prints the four values that go into GitHub as *repository variables*:
#   AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID / FUNCTIONAPP_NAME
#
# Requires an authenticated Az context in the CURRENT session, same rule as
# deploy.ps1:
#   Import-Module Az.Accounts
#   Connect-AzAccount
#   . infra/setup-github-oidc.ps1        # dot-source it
#
# Uses Invoke-AzRestMethod instead of Az.Resources cmdlets on purpose: no extra
# modules, no AAD lookups (role assignments are written with principalType
# ServicePrincipal explicitly), and it is idempotent - re-running it updates the
# same resources instead of failing.
# =============================================================================

$ErrorActionPreference = 'Stop'
Import-Module Az.Accounts -ErrorAction Stop

# --- configuration (mirrors infra/deploy.ps1 + infra/deployment-outputs.json) ---
$rgName        = 'Fanny'
$identityName  = 'id-integration-example-ci'
$githubRepo    = 'phobicadz/integration-example'
# The subject claim GitHub actually presents is what has to match. azure/login prints it
# in its failure line (AADSTS700213 'No matching federated identity record found for
# presented assertion subject …'), and on this repo it came out as:
#   repo:phobicadz@1702616/integration-example@1423810732:ref:refs/heads/main
# i.e. with the owner and repository ids embedded. The `repo:org/repo:*` wildcard forms
# (both spellings) never matched it; registering the exact claim string is what worked.
# All four are registered so the run goes green first - then delete the ones that never
# matched and keep just the exact subject.
$githubSubjects = @(
    'repo:phobicadz@1702616/integration-example@1423810732:ref:refs/heads/main',
    "repo:${githubRepo}:ref:refs/heads/main",
    "repo:${githubRepo}:*",
    'repo:phobicadz@1702616/integration-example@1423810732:*'
)
$githubIssuer  = 'https://token.actions.githubusercontent.com'
$functionAppName = 'prodint-fn-wrkc7gwtmfswq'

# Built-in role definition ids (must be the real GUIDs, not names).
$contributorRoleId        = 'b24988ac-6180-42a0-ab88-20f7382dd24c'  # Contributor
$websiteContributorRoleId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'  # Website Contributor

# ARM api-versions. Note: 2023-01-01 is NOT valid for userAssignedIdentities (the
# provider answers NoRegisteredProviderFound and lists what is); 2023-01-31 is the GA one.
$apiRg       = '2021-04-01'
$apiIdentity = '2023-01-31'
$apiWeb      = '2023-01-01'
$apiRole     = '2022-04-01'

$ctx = Get-AzContext
if (-not $ctx) { throw 'No Azure context. Run Connect-AzAccount first (then dot-source this file).' }
$subscriptionId = $ctx.Subscription.Id
$tenantId       = $ctx.Tenant.Id
Write-Host "Subscription: $subscriptionId"
Write-Host "Tenant      : $tenantId"

# NOTE on the URI strings: `$var?api-version` is NOT safe in PowerShell - the parser
# swallows part of the variable name when a `?` follows it. Always write `${var}?api-version`.
$rg = Invoke-AzRestMethod -Path "/subscriptions/$subscriptionId/resourceGroups/${rgName}?api-version=$apiRg" -Method GET
if ($rg.StatusCode -ne 200) { throw "Resource group '$rgName' not found (HTTP $($rg.StatusCode)). Run infra/deploy.ps1 first." }
$rgObj = $rg.Content | ConvertFrom-Json
$location = $rgObj.location
$rgId = "/subscriptions/$subscriptionId/resourceGroups/$rgName"
Write-Host "Resource group: $rgId ($location)"

# --- 1. user-assigned managed identity -------------------------------------------------
$identityId = "$rgId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$identityName"
$identityResp = Invoke-AzRestMethod -Path "${identityId}?api-version=$apiIdentity" -Method PUT -Payload (@{
    location = $location
    tags     = @{ owner = 'chamb'; project = 'integration-example'; purpose = 'github-actions-oidc' }
    properties = @{}
} | ConvertTo-Json -Depth 6)
if ($identityResp.StatusCode -notin 200, 201) { throw "identity create failed (HTTP $($identityResp.StatusCode)): $($identityResp.Content)" }
$identity = $identityResp.Content | ConvertFrom-Json
$clientId    = $identity.properties.clientId
$principalId = $identity.properties.principalId
Write-Host "`n[1/3] user-assigned identity '$identityName'"
Write-Host "      clientId    : $clientId"
Write-Host "      principalId : $principalId"

# --- 2. federated identity credentials (trust GitHub's OIDC token) -------------------
# ARM accepts EXACTLY ONE audience per credential (InvalidFederatedIdentityCredentialsAudienceLength).
# 'api://AzureADTokenExchange' is the audience azure/login requests (the workflow pins it
# explicitly); if you ever change that `audience`, these credentials have to match it.
# An identity may hold several federated credentials, which is how the two subject
# spellings above are both trusted.
Write-Host "`n[2/3] federated credentials on '$identityName'"
# Idempotency: (issuer, subject) is unique per identity, so reuse the existing credential
# name for a subject that is already trusted - PUT-ing a different name for the same pair
# fails with 409 Conflict.
$existingCreds = @()
$list = Invoke-AzRestMethod -Path "$identityId/federatedIdentityCredentials?api-version=$apiIdentity" -Method GET
if ($list.StatusCode -eq 200) { $existingCreds = ($list.Content | ConvertFrom-Json).value }

foreach ($subject in $githubSubjects) {
    $match = $existingCreds | Where-Object {
        $_.properties.subject -eq $subject -and $_.properties.issuer -eq $githubIssuer
    } | Select-Object -First 1

    if ($match) {
        $credName = $match.name
    } else {
        # New names: URL-safe, derived from the subject so they stay recognisable.
        $credName = $subject -replace '[^A-Za-z0-9_.-]', '-'
        if ($credName.Length -gt 80) { $credName = $credName.Substring(0, 80) }
    }
    $fedCredId = "$identityId/federatedIdentityCredentials/$credName"
    $fedResp = Invoke-AzRestMethod -Path "${fedCredId}?api-version=$apiIdentity" -Method PUT -Payload (@{
        properties = @{
            issuer    = $githubIssuer
            subject   = $subject
            audiences = @('api://AzureADTokenExchange')
        }
    } | ConvertTo-Json -Depth 6)
    if ($fedResp.StatusCode -notin 200, 201) { throw "federated credential '$credName' failed (HTTP $($fedResp.StatusCode)): $($fedResp.Content)" }
    Write-Host "      subject : $subject"
    Write-Host "      name    : $credName"
}
Write-Host "      issuer  : $githubIssuer (audience: api://AzureADTokenExchange)"

# --- 3. role assignments --------------------------------------------------------------
$app = Invoke-AzRestMethod -Path "$rgId/providers/Microsoft.Web/sites/${functionAppName}?api-version=$apiWeb" -Method GET
if ($app.StatusCode -ne 200) { throw "Function App '$functionAppName' not found in '$rgName' (HTTP $($app.StatusCode))." }
$appId = ($app.Content | ConvertFrom-Json).id

function Set-RoleAssignment {
    param([string]$Scope, [string]$RoleDefinitionId, [string]$Label)

    # Idempotency: list what this scope already grants and skip an exact duplicate,
    # so re-running the script does not pile up identical assignments.
    # (ARM returns roleDefinitionId as a full resource id, so match on the suffix.)
    $list = Invoke-AzRestMethod -Path "$Scope/providers/Microsoft.Authorization/roleAssignments?api-version=$apiRole" -Method GET
    if ($list.StatusCode -eq 200) {
        $duplicates = ($list.Content | ConvertFrom-Json).value | Where-Object {
            $_.properties.roleDefinitionId -like "*roleDefinitions/$RoleDefinitionId" -and
            $_.properties.principalId -eq $principalId
        }
        if ($duplicates) {
            Write-Host "      '$Label' already granted on $Scope - skipping"
            return
        }
    }

    # Role assignment names are arbitrary GUIDs.
    $assignmentId = [guid]::NewGuid()
    # roleDefinitionId must be the FULL role-definition resource id here: with a bare
    # GUID the API answers BadRequestFormat / InvalidResourceType.
    $roleDefinitionId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/roleDefinitions/$RoleDefinitionId"
    $payload = @{
        properties = @{
            roleDefinitionId = $roleDefinitionId
            principalId      = $principalId
            principalType    = 'ServicePrincipal'
        }
    } | ConvertTo-Json -Depth 6

    $resp = Invoke-AzRestMethod -Path "$Scope/providers/Microsoft.Authorization/roleAssignments/${assignmentId}?api-version=$apiRole" -Method PUT -Payload $payload
    if ($resp.StatusCode -notin 200, 201, 204) { throw "role assignment '$Label' failed (HTTP $($resp.StatusCode)): $($resp.Content)" }
    Write-Host "      granted '$Label' -> $Scope"
}

Write-Host "`n[3/3] role assignments for principal $principalId"
Set-RoleAssignment -Scope $rgId  -RoleDefinitionId $contributorRoleId        -Label 'Contributor'
Set-RoleAssignment -Scope $appId -RoleDefinitionId $websiteContributorRoleId -Label 'Website Contributor'

# --- what to paste into GitHub -------------------------------------------------------
Write-Host @"

Done. In GitHub: Settings -> Secrets and variables -> Actions -> Variables
(Create a repository *variable*, not a secret - these are not sensitive)

  AZURE_CLIENT_ID        = $clientId
  AZURE_TENANT_ID        = $tenantId
  AZURE_SUBSCRIPTION_ID  = $subscriptionId
  FUNCTIONAPP_NAME       = $functionAppName
  RESOURCE_GROUP         = $rgName   (optional; only the discovery fallback uses it)

Verify with:  gh api repos/$githubRepo/actions/variables
Teardown:     Remove-AzUserAssignedIdentity -ResourceGroupName $rgName -Name $identityName
"@
