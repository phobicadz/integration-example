# Product Import Integration — Durable Functions Demo

A small but complete **integration** built with Azure Durable Functions (.NET isolated worker):

```
POST /api/products/import
        │
        ▼
┌───────────────────────────┐
│ ImportTrigger (HTTP)      │  starts an orchestration, returns 202 + status URL
└───────────┬───────────────┘
            ▼
┌───────────────────────────────────────┐
│ ProductImportOrchestrator             │  the "brain": deterministic workflow
│  1. call FetchProducts (with retry)   │
│  2. fan-out per item (batches of 5)   │
│  3. aggregate a summary               │
└───────┬───────────────────────┬───────┘
        ▼                       ▼
┌───────────────────┐   ┌──────────────────────────┐
│ FetchProducts     │   │ ProcessAndPostProduct     │
│ activity          │   │ activity                  │
│ (mock source API, │   │ validate → transform →    │
│  15% flaky)       │   │ post to mock destination  │
└───────────────────┘   └──────────────────────────┘
                                │
                                ▼
                        MockDestinationStore
                        (GET /api/products/destination to inspect)
```

## Running it locally

1. **Start Azurite** (the local Azure Storage emulator — the Functions runtime itself needs
   a storage backend; only *orchestration state* has moved to DTS, see the DTS section below):
   ```powershell
   npm install -g azurite   # one-time
   azurite --silent --location .azurite
   ```
2. **Start the Durable Task Scheduler emulator** (orchestration state backend + dashboard):
   ```powershell
   docker run -d --name dts-emulator -p 8080:8080 -p 8082:8082 `
     -e DTS_TASK_HUB_NAMES=productimport,default `
     mcr.microsoft.com/dts/dts-emulator:latest
   ```
   Dashboard: http://localhost:8082 — gRPC scheduler: http://localhost:8080.
3. **Start the Functions host**:
   ```powershell
   cd src/ProductIntegration
   func start --port 7071
   ```
4. **Kick off an import run** (async HTTP pattern — the run may take seconds/minutes,
   so the API accepts the work and hands you a status URL):
   ```powershell
   Invoke-WebRequest -Uri http://localhost:7071/api/products/import -Method Post `
     -ContentType 'application/json' -Body '{"category":null}'
   # → 202 Accepted, body contains runId + correlationId + statusUrl, header Retry-After: 5
   ```

   Optionally supply your own correlation id (recommended when you call this from a
   system that already has one — it is what lets you stitch logs across services):
   ```powershell
   Invoke-WebRequest -Uri http://localhost:7071/api/products/import -Method Post `
     -ContentType 'application/json' -Headers @{ 'x-correlation-id' = "my-run-42" } `
     -Body '{"category":null}'
   # or a W3C trace header instead:  -Headers @{ 'traceparent' = "00-4bf9ef7e92de95c3cf1f4bfcbb90ba96-00f0000000000001-01" }
   # → that id comes back in the x-correlation-id response header and in every log line
   ```
5. **Poll the status endpoint** until `runtimeStatus` is `Completed` / `Failed`:
   ```powershell
   Invoke-WebRequest http://localhost:7071/api/products/import/<runId>/status
   ```
6. **Inspect what landed at the destination**:
   ```powershell
   Invoke-WebRequest http://localhost:7071/api/products/destination
   ```

Expected happy path: the mock source has 14 products, 5 of them deliberately dirty
(empty name, negative price, zero stock, missing SKU, multiple issues at once)
→ first run shows `posted: 9, skipped: 0, rejected: 5`.

**Run it a second time** (same host process): every item's version is unchanged, so the
destination's version guard rejects them all → `posted: 0, skipped: 9, rejected: 5`.
That second run is the idempotency demo — see below.

## How an integration like this should work (the patterns)

### 1. Trigger → Orchestrator → Activities
- The **HTTP trigger** does almost nothing: it starts an orchestration and returns
  `202 Accepted` with a `Location`/status URL and `Retry-After`. Long-running work
  never blocks an HTTP request.
- The **orchestrator** (`ProductImportOrchestrator`) is the workflow. It is *replayed*
  after every await, so it must be **deterministic**:
  - no direct I/O, no `DateTime.Now`, no `Guid.NewGuid()`, no random numbers
    (use `context.CurrentUtcDateTime` and pass IDs in from the trigger instead),
  - no `Task.Delay` / `Task.WhenAny` on non-Durable tasks (use `context.CreateTimer`),
  - code must produce the same sequence of scheduled tasks on every replay.
- **Activities** are where side effects live (HTTP calls, DB writes). They run once
  per attempt and are the unit that retries apply to. Make them **idempotent** —
  a retry re-runs the whole activity (our destination upsert is keyed by SKU, so
  re-posting the same product is safe).

### 2. Retries and failure isolation
Retries are declared **at the orchestrator's call site**, not on the activity:

```csharp
static readonly TaskOptions SourceRetryOptions = TaskOptions.FromRetryPolicy(
    new RetryPolicy(
        maxNumberOfAttempts: 4,
        firstRetryInterval: TimeSpan.FromSeconds(2),
        backoffCoefficient: 2.0,
        maxRetryInterval: TimeSpan.FromSeconds(30)));

await context.CallActivityAsync<List<Product>>(nameof(FetchProducts), request, SourceRetryOptions);
```

The deliberate design split:
- **Transport failures throw** → the retry policy retries them with exponential backoff.
- **Validation failures return a "rejected" outcome** (no throw) → not retried, recorded.
- The orchestrator wraps each item in `try/catch (TaskFailedException)` so **one bad
  item can't kill the whole run**; after retries are exhausted the failure is recorded
  in the summary and the run continues. `TaskFailedException.FailureDetails` carries
  the error type/message/stack — not `InnerException`.

### 3. Fan-out with batching
8 (or 8,000) items are fanned out in **batches of 5** with `Task.WhenAll`. Unbounded
fan-out can overwhelm downstream systems and the Functions host; batching is the
throttle. Each item's outcome is aggregated into an `IntegrationSummary`
(`totalFetched / posted / rejected / failed`) — the run reports *what actually happened*,
not just "it finished".

### 4. Mocked endpoints = swap points
`MockSourceCatalog` and `MockDestinationStore` are singletons behind tiny abstractions.
In a real integration you'd replace them with an HTTP client (source) and a queue/API/DB
write (destination) — the orchestrator, retries, monitoring, and failure semantics stay
identical. That's the point: the *integration skeleton* is what you learn, not the mocks.

### 5. Idempotency and versioning (the `skipped` outcome)

Retries and replays mean the same item **will** be delivered more than once. The defense is
a **version supplied by the source**, carried unchanged through the whole pipeline:

```
Product.Version (source, monotonic) ──► ProcessedProduct.Version (copied verbatim)
                                   ──► MockDestinationStore.Upsert (compare-and-swap)
```

- `MockDestinationStore.Upsert` uses `ConcurrentDictionary.AddOrUpdate` as a CAS:
  the incoming item wins **only if** `item.Version > current.Version`; otherwise the
  stored item is kept and the upsert reports `SkippedStale`.
- The activity logs `SKIPPED {Sku} v{n}: destination already current` and returns
  `ItemOutcome { Success = true, Reason = "skipped" }` — a stale duplicate is a
  *successful no-op*, not a failure.
- The orchestrator aggregates `Posted / Skipped / Rejected / Failed` with the invariant
  `Posted + Skipped + Rejected + Failed == TotalFetched`, so duplicate suppression is
  *visible* in the summary instead of hidden.

**Why the version must come from the source:** a locally generated value like
`ProcessedAtUtc` would be *newer* on every retry, so the guard would accept the duplicate
and a late/out-of-order write would win. Only the source knows which revision is newer.

Real-world equivalents of the same guard:

| System | Equivalent mechanism |
|---|---|
| Azure Cosmos DB | `_etag` + `If-Match` (optimistic concurrency) |
| SQL / relational | `UPDATE ... WHERE version < @version` |
| Service Bus / queues | duplicate detection via `MessageId` |
| HTTP APIs | `If-Match` / `ETag`, or an idempotency-key header |
| Event-sourced systems | sequence number / vector clock per aggregate |

### 6. Correlation ids (trace one run end to end)

Two ids, two jobs — both are threaded through the whole run:

| Id | Where it comes from | What it identifies |
|---|---|---|
| `runId` | the Durable Functions **orchestration instance id** | one run of the workflow (queryable via the status endpoint + history) |
| `correlationId` | the **caller**: `x-correlation-id` header, else the trace-id of a W3C `traceparent` header, else the ambient `Activity`, else a new GUID | one logical request, correlatable with the calling system's own logs |

```csharp
// ImportTrigger: the id is created at the edge, once
string correlationId = Correlation.Resolve(req);            // honours the caller's id
// ProductImportOrchestrator: it is *carried* in the (replayable) orchestration input
string correlationId = Correlation.ForRun(request?.CorrelationId, context.InstanceId);
```

Where it shows up:

- **HTTP**: `x-correlation-id` on every response (set in one place, `CorrelationMiddleware`),
  and `correlationId` in the JSON body of the 202 response, the status response and the
  destination dump.
- **Activity payloads**: `IntegrationRequest` → `FetchRequest` / `ItemWorkItem` carry it into
  every activity, so side effects are attributable even though they run on another process.
- **Logs**: every line is prefixed `[corr:{CorrelationId}]`, and `Correlation.BeginLogScope`
  also adds `correlationId` + `runId` as *structured* properties, so in Application Insights
  you can query `customDimensions.correlationId` instead of grepping text.
- **The destination**: `ProcessedProduct.CorrelationId` records *which run wrote this record*
  (the CAS guard keeps the original winner, so it stays the id of the run that actually applied it).

The one rule that matters: **never generate a correlation id inside an orchestrator.**
`Guid.NewGuid()` in orchestration code breaks determinism and replay. Orchestrators derive
the id from their input (or fall back to the instance id, which is stable per run).

Real-world equivalents: API Management / Application Gateway forward a `traceparent`;
Service Bus messages have `CorrelationId`; Application Insights ties everything together with
`Operation_Id` — which is exactly the trace-id this project reads and re-emits.

## Monitoring this integration

| Signal | Where | What it tells you |
|---|---|---|
| Run status | `GET /api/products/import/{id}/status` | `runtimeStatus` (Running/Completed/Failed/Terminated), created/updated timestamps, failure details, final summary, and the run's `correlationId` |
| Audit trail | same endpoint, `history` field (`client.GetOrchestrationHistoryAsync`) | every event: each task scheduled/completed, retries, timers — replay this and you can reconstruct exactly how the run progressed |
| Destination check | `GET /api/products/destination` | what actually arrived downstream (the integration's real output) |
| Structured logs | `ILogger` in activities/trigger → console locally, **Application Insights** in prod (`AddApplicationInsightsTelemetryWorkerService().ConfigureFunctionsApplicationInsights()` is already wired in `Program.cs`) | per-item POSTED/REJECTED/FAILED lines, correlation via `[corr:{CorrelationId}]` in every message plus `correlationId`/`runId` log-scope properties (queryable as `customDimensions`) |
| Instance inventory | `client.GetAllInstancesAsync(new OrchestrationQuery { ... })` | list/paginate all runs by status or time window — build a dashboard endpoint from this |
| **DTS dashboard** | http://localhost:8082 (emulator) or the task hub's dashboard URL in Azure | live orchestration inventory per task hub: running/completed/failed counts, per-instance drill-down into event history — no code required |
| Production dashboards | Application Insights (Functions app maps, end-to-end transactions) and **Durable Task Scheduler** (for the DTS backend) | orchestration-level metrics, failure rates, alerting |

Monitoring rules of thumb this demo encodes:
- **Every run has an ID, and every log line carries a correlation ID.** Correlation is the
  whole game: `grep "corr:<your-id>"` over the console output (or a `customDimensions`
  query in Application Insights) reproduces the entire run — trigger, fetch, every item,
  and every status poll made against it.
- **Status polling with `Retry-After`** is the client-facing monitoring contract for async integrations.
- **A run that "completed" is not necessarily a successful integration** — the summary
  distinguishes posted/rejected/failed so partial success is visible, not hidden.
- The **orchestration history is your replayable audit log** — far more useful than
  scattered logs when someone asks "why did this item get rejected?".

## Durable Task Scheduler (this project's state backend)

This project runs its orchestration state on **Durable Task Scheduler (DTS)** instead of the
classic storage-provider backends. Locally that means the official DTS emulator container;
in Azure it is a real resource (`Microsoft.DurableTask/schedulers` + task hubs).

What changed in the code: **nothing.** DTS is a backend swap, not an API change —
`TaskOrchestrationContext`, `DurableTaskClient`, `GetInstanceAsync`, and
`GetOrchestrationHistoryAsync` all work identically. The swap lives entirely in config:

- `ProductIntegration.csproj` — `Microsoft.Azure.Functions.Worker.Extensions.DurableTask.AzureManaged`
- `host.json` —
  ```json
  "extensions": {
    "durableTask": {
      "storageProvider": {
        "type": "azureManaged",
        "connectionStringName": "DTS_CONNECTION_STRING"
      },
      "hubName": "%TASKHUB_NAME%"
    }
  }
  ```
- `local.settings.json` —
  ```json
  "DTS_CONNECTION_STRING": "Endpoint=http://localhost:8080;Authentication=None",
  "TASKHUB_NAME": "productimport"
  ```
  (`Authentication=None` is emulator-only. In Azure:
  `Endpoint=https://{scheduler}.{region}.durabletask.io;Authentication=DefaultAzure`, a
  managed identity, and the **Durable Task Data Contributor** RBAC role on the task hub —
  plus **Durable Task Dashboard Viewer** for dashboard access.)

Caveats and notes:

- **Azurite is still required.** `AzureWebJobsStorage` is used by the Functions runtime
  itself (triggers, locks, internal state). Only orchestration state moved to DTS.
- The emulator's state is **in-memory**: restarting the container loses all runs. In Azure,
  state persists per the task hub's retention/autopurge policies.
- The dashboard (port 8082 locally) complements the `/status` endpoint rather than replacing
  it: the endpoint is the *client-facing contract* your callers poll; the dashboard is the
  *operator's view* — instance counts by status, worker counts, and event-history drill-down
  per instance, without writing any monitoring code.
- One run of `func start` keeps the in-memory `MockDestinationStore` alive; the
  `skipped: 9` demo only works when both runs happen in the **same host process**. DTS
  state itself survives `func start` restarts (until the emulator container restarts).

## Deploy to Azure (verified working)

The infrastructure lives in `infra/` and is deployed with Az PowerShell (no az CLI or azd needed):

```powershell
# 1. Provision the infrastructure (builds Bicep, ensures the RG, validates, deploys,
#    and writes the outputs to infra/deployment-outputs.json)
Import-Module Az.Accounts, Az.Resources
Connect-AzAccount
. ./infra/deploy.ps1

# 2. Publish the Functions code
func azure functionapp publish <functionAppName>   # name printed by deploy.ps1
```

What `infra/main.bicep` provisions (all in one region, e.g. `northeurope`):

| Resource | Purpose |
|---|---|
| Function App (**Flex Consumption**, Linux, `dotnet-isolated 8.0`) | runs the 6 functions |
| Storage account + `app-package-*` blob container | Flex deployment package + Functions runtime state |
| Durable Task Scheduler + task hub (`Microsoft.DurableTask/schedulers@2025-11-01`) | orchestration state backend (`azureManaged`) |
| User-assigned managed identity + 4 RBAC role assignments | keyless auth: Blob Data Owner, Queue/Table Data Contributor, **Durable Task Data Contributor** (`0ad04412-c4d5-4796-b79c-f76d14c8d402`) |
| Log Analytics + App Insights | monitoring |

Key facts learned while getting this to deploy (all reflected in the template):

- **Region:** West Europe is closed to new customers on this subscription → use `northeurope`.
- **App Insights:** API version `2022-06-15` is not registered in `northeurope`; the template
  uses `2020-02-02`. `diagnosticSourceSettings` has no ARM API at all — enable Durable
  tracking in the portal (App Insights → Diagnostic Sources) instead.
- **Flex Consumption** replaces the retired Linux Consumption plan (a fresh subscription has
  0 App Service cores quota for B1). On Flex, do **not** set the classic app settings
  (`FUNCTIONS_WORKER_RUNTIME`, `linuxFxVersion`, `WEBSITE_RUN_FROM_PACKAGE`, …) — runtime and
  scaling live in `functionAppConfig` instead.
- **Workload identity:** a *user-assigned* identity is created **before** the Function App so
  the role assignments can grant it access to the deployment blob container (system-assigned
  would be a chicken-and-egg dependency). Storage is then keyless via
  `AzureWebJobsStorage__accountName/__credential/__clientId`.
- **DTS connection string** (set automatically by the template):
  `Endpoint=https://<scheduler>.<region>.durabletask.io;Authentication=ManagedIdentity;ClientID=<identity clientId>`.
  Note Azure shortens the scheduler name inside the endpoint host.
- **Role GUIDs** must be the real built-in ids (e.g. Storage Blob Data Owner
  `b7e6dc6d-f1e8-4753-8033-0f276bb0955b`) — a wrong GUID fails with `RoleDefinitionDoesNotExist`.

Smoke test after publishing:

```powershell
$r = Invoke-RestMethod "https://<app>.azurewebsites.net/api/products/import" -Method Post -ContentType 'application/json'
Invoke-RestMethod "https://<app>.azurewebsites.net$($r.statusUrl)"   # poll until runtimeStatus = Completed
```

First run: `posted 9 / skipped 0 / rejected 5`. Repeat runs on the same warm instance:
`posted 0 / skipped 9` — the version guard live in production.

> Caveat: `GET /api/products/destination` reads the **in-memory** `MockDestinationStore`, which
> is per-instance. Flex scales out, so the GET may land on a different instance and show 0
> items even after a successful run. The orchestration itself (and its version guard) is fully
> durable in DTS; only the mock destination view is instance-local. Swap
> `MockDestinationStore` for a real store (Cosmos, SQL, …) to make the destination view global.

Teardown: `Remove-AzResourceGroup -Name Fanny -Force` (that is the group `infra/deploy.ps1`
creates; `infra/main.bicepparam` and `deploy.ps1` are the source of truth for the name).
Cost for this demo: Flex Consumption free grants (1M executions / 400k GB-s per month) plus
DTS Consumption SKU (pay-per-action, no base fee) — effectively near zero.

## Publish from GitHub Actions

`.github/workflows/publish.yml` publishes the **code** (it does not provision infra — that
stays `infra/deploy.ps1`, which is a one-off and needs an interactive login).

| Trigger | What runs |
|---|---|
| push to `main` touching `src/**`, `scripts/smoke-test.sh`, or the workflow itself | `build → deploy → verify` |
| `workflow_dispatch` (Actions → Publish to Azure → Run workflow) | same, with an optional `functionAppName` input to publish somewhere else |

| Job | What it does |
|---|---|
| `build` | `dotnet publish -c Release` of `src/ProductIntegration` (a build failure never reaches Azure), uploaded as an artifact |
| `deploy` | `azure/login@v3` (OIDC) → `Azure/functions-action@v1` → one-deploy to the **Flex Consumption** app. `sku` is not set: with OIDC+RBAC the action resolves the plan itself, and Flex must not get the classic app settings |
| `verify` | runs `scripts/smoke-test.sh` against the live app: starts a run with an `x-correlation-id`, requires that id back in the response header, in the 202 body and in the finished run summary, then asserts `posted + skipped + rejected + failed == totalFetched` |

### One-time setup (OIDC — no secrets to rotate)

This machine has no `az` CLI, so the Azure side is scripted with Az PowerShell —
`infra/setup-github-oidc.ps1` does all three steps and is **idempotent** (it re-PUTs the
identity/credential and skips a role assignment that already exists):

```powershell
Import-Module Az.Accounts
Connect-AzAccount
. infra/setup-github-oidc.ps1     # dot-source, same rule as deploy.ps1
#  [1/3] user-assigned identity 'id-integration-example-ci'   -> clientId + principalId
#  [2/3] federated credential 'github-integration-example'    -> trusts this repo's OIDC token
#  [3/3] role assignments                                     -> Contributor on the RG,
#                                                               Website Contributor on the app
#  then prints the exact values to put into GitHub
```

<details>
<summary>Same thing with the az CLI (Cloud Shell / a machine that has it)</summary>

```bash
SUB=…  RG=Fanny  APP=prodint-fn-…            # from infra/deployment-outputs.json
az identity create -g $RG -n id-integration-example-ci -l uksouth
CI_ID=$(az identity show -g $RG -n id-integration-example-ci --query clientId -o tsv)
PRINCIPAL=$(az identity show -g $RG -n id-integration-example-ci --query principalId -o tsv)

az identity federated-credential create -g $RG --identity-name id-integration-example-ci \
  -n github-integration-example \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "repo:phobicadz/integration-example:*" \
  --audiences "api://AzureADTokenExchange"

APP_ID=$(az functionapp show -n $APP -g $RG --query id -o tsv)
az role assignment create --role Contributor           --assignee-object-id $PRINCIPAL \
  --assignee-principal-type ServicePrincipal --scope "/subscriptions/$SUB/resourceGroups/$RG"
az role assignment create --role "Website Contributor" --assignee-object-id $PRINCIPAL \
  --assignee-principal-type ServicePrincipal --scope "$APP_ID"
```

</details>

The workflow's `azure/login` step pins `audience: api://AzureADTokenExchange`, which must be
the **one and only** audience on the federated credential (ARM rejects more than one).


Then in GitHub: **Settings → Secrets and variables → Actions → Variables** (Create a
repository variable) and add:

| Variable | Value |
|---|---|
| `AZURE_CLIENT_ID` | `$CI_ID` above — the identity's **clientId**, not its principalId |
| `AZURE_TENANT_ID` | `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | `$SUB` |
| `FUNCTIONAPP_NAME` | `$APP` (otherwise the workflow discovers the only function app in `RESOURCE_GROUP`) |
| `RESOURCE_GROUP` | optional; only used by that discovery fallback |

If a variable is missing, the `deploy` job stops at its **Preflight** step naming exactly
which one — that is the expected outcome of the *first* run right after pushing this
workflow, before the variables exist.

Variables can also be written from the CLI instead of the portal (a PAT with `repo` scope is
enough):

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/phobicadz/integration-example/actions/variables \
  -d '{"name":"AZURE_CLIENT_ID","value":"<clientId printed by setup-github-oidc.ps1>"}'
```

### Notes

- `local.settings.json` is gitignored on purpose: the deployed app takes its settings from the
  Bicep template (`DTS_CONNECTION_STRING`, `TASKHUB_NAME`, keyless storage), not from the repo.
- `verify` asserts the **invariant**, not exact counts: a fresh instance posts 9 / rejects 5, a
  warm repeat is suppressed to `posted 0 / skipped 9` by the version guard. Both pass.
- `GET /api/products/destination` is deliberately not asserted — the mock store is in-memory
  and per-instance (caveat above).
- The manual path still works for a one-off: `func azure functionapp publish <app>`.

### Running the smoke test by hand

`scripts/smoke-test.sh` is exactly what the `verify` job runs, usable locally too:

```bash
./scripts/smoke-test.sh http://localhost:7071                        # needs func start + Azurite
./scripts/smoke-test.sh https://prodint-fn-wrkc7gwtmfswq.azurewebsites.net "my-run-42"
POLL_MAX_ATTEMPTS=60 ./scripts/smoke-test.sh https://<app>.azurewebsites.net   # cold-start allowance
```

It needs `curl` and `jq`, exits non-zero at the first broken assumption, and prints the run
summary (ids + counts) so a failing CI run is readable without extra digging.

## Project layout

```
.github/workflows/
└── publish.yml                     # build → publish (OIDC) → live smoke test
scripts/
└── smoke-test.sh                   # end-to-end check: correlation id round trip + summary invariant
infra/
├── main.bicep / main.bicepparam    # infrastructure: Flex Consumption app, DTS scheduler, App Insights
├── deploy.ps1                      # provision the infrastructure (Az PowerShell, dot-source it)
├── setup-github-oidc.ps1           # CI identity + federated credential + role assignments
└── deployment-outputs.json         # names produced by a deployment (function app, DTS endpoint…)
src/ProductIntegration/
├── Program.cs                      # host setup, DI, App Insights wiring, correlation middleware
├── Correlation.cs                  # resolve/propagate correlation ids (x-correlation-id, traceparent)
├── CorrelationMiddleware.cs        # per-request correlation: response header + request log lines
├── host.json                       # Functions host config + azureManaged (DTS) backend
├── local.settings.json             # Azurite + DTS_CONNECTION_STRING + TASKHUB_NAME
├── Models/                         # Product, ProcessedProduct (with Version), request/summary DTOs
├── Functions/
│   ├── ImportTrigger.cs            # POST /api/products/import  (202 + status URL)
│   ├── ImportStatus.cs             # GET  status + history       (monitoring)
│   ├── ProductImportOrchestrator.cs# the workflow + retry policies + fan-out batching
│   ├── Activities.cs               # FetchProducts / ProcessAndPostProduct (side effects)
│   └── DestinationInspector.cs     # GET  /api/products/destination
└── Services/
    ├── MockSourceCatalog.cs        # 14 seeded products (5 dirty, source versions), 15% transient failures
    └── MockDestinationStore.cs     # in-memory destination keyed by SKU (CAS version guard)
```

## Notes / gotchas hit while building this

- The **isolated worker model** uses `Microsoft.DurableTask.*` APIs
  (`TaskOrchestrationContext`, `TaskOptions.FromRetryPolicy`), *not* the older in-process
  `IDurableOrchestrationContext` / `[RetryOptions]` attribute. There is no
  `context.RetryOptions` and no `metadata.Output` — use `ReadOutputAs<T>()` /
  `SerializedOutput` and `metadata.FailureDetails`.
- `host.json` has **no `inMemory` option** — orchestration state always goes to the
  storage backend (`AzureWebJobsStorage`). Locally that's Azurite; in production,
  Azure Storage or Durable Task Scheduler. That backend is what makes the workflow
  *durable* across restarts and scale-out.
- Package versions must line up: Worker SDK 2.x + Worker 2.x + DurableTask extension 1.19.x
  (mixing Worker 1.x with the current Functions host causes `MissingMethodException` at
  invocation time). The DTS backend is a *separate* package
  (`...Extensions.DurableTask.AzureManaged`) and must match the DurableTask extension line.
- With pinned NuGet packages in an isolated project, **remove the `extensionBundle` block
  from `host.json`** — the bundle can resolve conflicting versions of the same extensions.
- `func start` works, but the CLI itself warns that `dotnet run` is the more reliable way
  to start an isolated project (it builds first and runs from the right output directory).
- The status response's run id field is `runId` (not `id`) — poll
  `/api/products/import/{runId}/status`.
- Correlation ids are **resolved at the HTTP edge only**. Generating one inside an
  orchestrator (e.g. `Guid.NewGuid()`) breaks determinism: on replay the id would change,
  so logs from the same run would no longer match. The orchestrator takes it from its
  input and falls back to `context.InstanceId`.
- GitHub **repository variables are not environment variables**: a `run:` step only sees them
  when they are mapped explicitly (`env: AZURE_CLIENT_ID: ${{ vars.AZURE_CLIENT_ID }}`).
  Secrets have the same trap. The `Preflight` step exists precisely because this fails
  silently otherwise.
- Pushing a file under `.github/workflows/` needs a token with the **`workflow`** scope;
  a `repo`-only PAT is rejected with *“refusing to allow a Personal Access Token to create
  or update workflow … without `workflow` scope”*.
- Shell scripts need LF line endings or `bash` on the runner fails on `\r` — `.gitattributes`
  pins `*.sh text eol=lf` so a Windows checkout cannot break the workflow.
- ARM gotchas hit while writing `infra/setup-github-oidc.ps1`:
  - `roleDefinitionId` in a role-assignment PUT must be the **full role-definition resource
    id**; a bare GUID fails with `BadRequestFormat` / `InvalidResourceType`.
  - a federated identity credential accepts **exactly one** audience
    (`InvalidFederatedIdentityCredentialsAudienceLength`) — use `api://AzureADTokenExchange`,
    which is what `azure/login` asks for (the workflow pins it explicitly).
  - `2023-01-01` is not a valid api-version for `userAssignedIdentities` (`2023-01-31` is).
  - in a PowerShell double-quoted string `$var?api-version=…` silently mangles the variable
    name — write `${var}?api-version=…`.
