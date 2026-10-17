using System.Net;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;
using Microsoft.DurableTask;
using Microsoft.DurableTask.Client;
using ProductIntegration.Models;
using ProductIntegration;

namespace ProductIntegration.Functions;

/// <summary>
/// Monitoring endpoint: poll this to watch a run progress.
/// Returns runtime status (Running/Completed/Failed/Terminated), timing, failure
/// details, the final summary, and (where the backend supports it) the full
/// orchestration history — the event-by-event audit trail of the integration.
/// </summary>
public class ImportStatus
{
    [Function("products-import-status")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "products/import/{id}/status")] HttpRequestData req,
        [DurableClient] DurableTaskClient client,
        string id,
        FunctionContext executionContext)
    {
        // getInputsAndOutputs: true also fetches the serialized input/output payloads.
        OrchestrationMetadata? metadata =
            await client.GetInstanceAsync(id, getInputsAndOutputs: true);

        if (metadata is null)
        {
            var notFound = req.CreateResponse(HttpStatusCode.NotFound);
            await notFound.WriteAsJsonAsync(new { error = $"No run found with id '{id}'." });
            return notFound;
        }

        // The correlation id the run was started with: read it from the orchestration
        // input so it is available even while the run is still in progress.
        string? correlationId = null;
        try { correlationId = metadata.ReadInputAs<IntegrationRequest>()?.CorrelationId; } catch { /* older payload */ }
        correlationId = Correlation.ForRun(correlationId, metadata.InstanceId);

        // The orchestrator's return value: an IntegrationSummary once finished.
        IntegrationSummary? summary = null;
        if (metadata.RuntimeStatus == OrchestrationRuntimeStatus.Completed)
        {
            try { summary = metadata.ReadOutputAs<IntegrationSummary>(); } catch { /* older payload */ }
            // Prefer the summary's value when present (it is the authoritative one).
            if (!string.IsNullOrWhiteSpace(summary?.CorrelationId)) correlationId = summary!.CorrelationId;
        }

        // Logging the RUN's correlation id here means one grep on that id also finds
        // every status poll made against this run, not just the run's own log lines.
        executionContext.GetLogger(nameof(ImportStatus))
            .LogInformation("[corr:{RunCorrelationId}] status requested for run {RunId} (status={Status})",
                correlationId, metadata.InstanceId, metadata.RuntimeStatus);

        // The event history is the audit trail: every task scheduled/completed,
        // retries, timers... Some backends don't support it, so guard the call.
        object? history = null;
        try
        {
            history = await client.GetOrchestrationHistoryAsync(id);
        }
        catch
        {
            // history not supported by this backend — status data above is still useful.
        }

        var response = req.CreateResponse(HttpStatusCode.OK);
        response.Headers.Add("Retry-After", metadata.IsCompleted ? "0" : "5");

        await response.WriteAsJsonAsync(new
        {
            runId = metadata.InstanceId,
            correlationId,
            name = metadata.Name,
            runtimeStatus = metadata.RuntimeStatus.ToString(),
            isRunning = metadata.IsRunning,
            isCompleted = metadata.IsCompleted,
            createdAt = metadata.CreatedAt,
            lastUpdatedAt = metadata.LastUpdatedAt,
            output = summary,
            failure = metadata.FailureDetails is null
                ? null
                : new
                {
                    errorType = metadata.FailureDetails.ErrorType,
                    message = metadata.FailureDetails.ErrorMessage,
                    stackTrace = metadata.FailureDetails.StackTrace
                },
            history
        });
        return response;
    }
}
