using Microsoft.Azure.Functions.Worker;
using Microsoft.DurableTask;
using ProductIntegration.Models;

namespace ProductIntegration.Functions;

/// <summary>
/// The orchestrator: the durable, replayable "conductor" of the integration.
///
/// Orchestrator rules (important to remember):
///  - Deterministic: no I/O, no randomness, no direct calls to other functions.
///  - All side effects (HTTP calls, DB writes) happen inside Activities.
///  - The orchestrator only decides WHAT runs and WHEN (Task.WhenAll, durable timers, sub-orchestrations).
///
/// Flow:  fetch -> fan-out (process + post per item) -> aggregate summary.
/// </summary>
public class ProductImportOrchestrator
{
    // Retry policy for talking to the (deliberately flaky) mock source: 4 attempts, exponential backoff.
    private static readonly TaskOptions SourceRetryOptions = TaskOptions.FromRetryPolicy(
        new RetryPolicy(
            maxNumberOfAttempts: 4,
            firstRetryInterval: TimeSpan.FromSeconds(2),
            backoffCoefficient: 2.0,
            maxRetryInterval: TimeSpan.FromSeconds(30)));

    // Retry policy for posting to the destination: 3 attempts.
    private static readonly TaskOptions DestinationRetryOptions = TaskOptions.FromRetryPolicy(
        new RetryPolicy(
            maxNumberOfAttempts: 3,
            firstRetryInterval: TimeSpan.FromSeconds(2),
            backoffCoefficient: 2.0,
            maxRetryInterval: TimeSpan.FromSeconds(20)));

    [Function(nameof(ProductImportOrchestrator))]
    public async Task<IntegrationSummary> Run(
        [OrchestrationTrigger] TaskOrchestrationContext context,
        IntegrationRequest? request)
    {
        // A run id we thread through every activity for tracing/monitoring.
        string runId = context.InstanceId;

        // 1. FETCH: pull products from the mocked upstream endpoint.
        //    If the upstream is down the retry policy retries with backoff; if every
        //    attempt fails the whole run fails and the status endpoint surfaces it.
        var products = await context.CallActivityAsync<List<Product>>(
            nameof(Activities.FetchProducts),
            new FetchRequest { RunId = runId, Category = request?.Category },
            SourceRetryOptions);

        if (products is null || products.Count == 0)
        {
            return new IntegrationSummary { RunId = runId, TotalFetched = 0 };
        }

        // 2. FAN-OUT: process + post each product.
        //    Each item is its own activity, so one bad item does not kill the run:
        //    we catch TaskFailedException per item and record it as "failed".
        var workItems = products
            .Select(p => new ItemWorkItem { RunId = runId, Product = p })
            .ToList();

        var outcomeTasks = workItems
            .Select(item => RunItemSafely(context, item))
            .ToList();

        // Fan-out with a concurrency cap: batches of 5 so we don't overwhelm the destination.
        // (Overkill for 8 mock records, but it is the pattern to remember at real volumes.)
        const int batchSize = 5;
        var outcomes = new List<ItemOutcome>();
        for (int i = 0; i < outcomeTasks.Count; i += batchSize)
        {
            var results = await Task.WhenAll(outcomeTasks.Skip(i).Take(batchSize));
            outcomes.AddRange(results);
        }

        // 3. AGGREGATE: build the summary the status endpoint exposes.
        // Invariant: Posted + Skipped + Rejected + Failed == TotalFetched.
        return new IntegrationSummary
        {
            RunId = runId,
            TotalFetched = products.Count,
            Posted = outcomes.Count(o => o.Success && o.Reason != "skipped"),
            Skipped = outcomes.Count(o => o.Success && o.Reason == "skipped"),
            Rejected = outcomes.Count(o => !o.Success && o.Reason == "rejected"),
            Failed = outcomes.Count(o => !o.Success && o.Reason == "failed"),
        };
    }

    /// <summary>
    /// Wraps one item's activity call so a hard failure (after all retries) is captured
    /// as an outcome instead of failing the entire orchestration.
    /// </summary>
    private static async Task<ItemOutcome> RunItemSafely(
        TaskOrchestrationContext context, ItemWorkItem item)
    {
        try
        {
            return await context.CallActivityAsync<ItemOutcome>(
                nameof(Activities.ProcessAndPostProduct), item, DestinationRetryOptions);
        }
        catch (TaskFailedException ex)
        {
            // In the isolated model the original exception is NOT on InnerException;
            // inspect FailureDetails instead.
            return new ItemOutcome
            {
                Sku = item.Product.Sku,
                Success = false,
                Reason = "failed",
                Detail = $"{ex.FailureDetails.ErrorType}: {ex.FailureDetails.ErrorMessage}"
            };
        }
    }
}
