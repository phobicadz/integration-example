using Microsoft.Azure.Functions.Worker;
using Microsoft.DurableTask;
using ProductIntegration.Models;
using ProductIntegration.Services;
using ProductIntegration;
using Microsoft.Extensions.Logging;

namespace ProductIntegration.Functions;

/// <summary>
/// Activities are where all the side effects live: HTTP calls, DB writes, etc.
/// Unlike orchestrators, activities are NOT replayed deterministically, so they
/// are the safe place to talk to the outside world.
///
/// Each activity gets a RetryPolicy: Durable Functions will automatically retry
/// it with exponential backoff when it throws, and after the attempts are
/// exhausted the failure surfaces to the orchestrator (which can decide to
/// fail the run or, as we do here, record the item as failed and continue).
/// </summary>
public class Activities
{
    private readonly MockSourceCatalog _source;
    private readonly MockDestinationStore _destination;

    public Activities(MockSourceCatalog source, MockDestinationStore destination)
    {
        _source = source;
        _destination = destination;
    }

    /// <summary>ACTIVITY 1 — import from the mocked source endpoint.</summary>
    /// <remarks>
    /// The orchestrator applies a RetryPolicy to this call (SourceRetryOptions), so a
    /// transient failure here is retried automatically with exponential backoff.
    /// Activities must be idempotent because a retry re-runs the whole activity.
    /// </remarks>
    [Function(nameof(FetchProducts))]
    public Task<List<Product>> FetchProducts(
        [ActivityTrigger] FetchRequest request, FunctionContext executionContext)
    {
        ILogger logger = executionContext.GetLogger(nameof(FetchProducts));
        using var _ = Correlation.BeginLogScope(logger, request.CorrelationId, request.RunId);

        logger.LogInformation("[corr:{CorrelationId}] Fetching products from mock source (category={Category})",
            request.CorrelationId, request.Category ?? "all");

        // A transient failure here is retried automatically by the durable runtime.
        var products = _source.Fetch(request.Category);

        logger.LogInformation("[corr:{CorrelationId}] Fetched {Count} products from source",
            request.CorrelationId, products.Count);

        return Task.FromResult(products);
    }

    /// <summary>ACTIVITY 2 — transform/validate a product, then push it to the mocked destination.</summary>
    /// <remarks>
    /// The orchestrator applies a RetryPolicy to this call (DestinationRetryOptions).
    /// Validation failures are NOT thrown (they return a "rejected" outcome) so they are
    /// not retried — only genuine transport failures throw and trigger a retry.
    /// </remarks>
    [Function(nameof(ProcessAndPostProduct))]
    public Task<ItemOutcome> ProcessAndPostProduct(
        [ActivityTrigger] ItemWorkItem item, FunctionContext executionContext)
    {
        ILogger logger = executionContext.GetLogger(nameof(ProcessAndPostProduct));
        using var _ = Correlation.BeginLogScope(logger, item.CorrelationId, item.RunId);
        var product = item.Product;

        // --- Processing / validation step ---
        var issues = new List<string>();
        if (string.IsNullOrWhiteSpace(product.Name)) issues.Add("Name is required.");
        if (product.UnitPrice <= 0) issues.Add("Unit price must be greater than zero.");
        if (product.Stock <= 0) issues.Add("Stock must be greater than zero.");
        if (string.IsNullOrWhiteSpace(product.Sku)) issues.Add("SKU is required.");

        var processed = new ProcessedProduct
        {
            Sku = product.Sku,
            Name = product.Name,
            Category = product.Category,
            UnitPrice = product.UnitPrice,
            // Example transformation: derive a wholesale price (70% of retail).
            WholesalePrice = Math.Round(product.UnitPrice * 0.70m, 2),
            Stock = product.Stock,
            // Version flows straight through from the source — never generated here.
            Version = product.Version,
            IsValid = issues.Count == 0,
            ValidationIssues = issues,
            ProcessedAtUtc = DateTimeOffset.UtcNow,
            // The destination record keeps the correlation id: downstream trouble can be
            // traced back to the exact run (and its log lines / orchestration history).
            CorrelationId = item.CorrelationId,
        };

        if (!processed.IsValid)
        {
            logger.LogWarning("[corr:{CorrelationId}] REJECTED {Sku}: {Issues}",
                item.CorrelationId, product.Sku, string.Join("; ", issues));
            return Task.FromResult(new ItemOutcome
            {
                Sku = product.Sku,
                Success = false,
                Reason = "rejected"
            });
        }

        // --- Send to the mocked destination endpoint ---
        try
        {
            var result = _destination.Upsert(processed);

            if (result == UpsertResult.SkippedStale)
            {
                // Destination already has an equal-or-newer version. Success, but counted
                // as "skipped" — this is what a duplicate delivery / replay looks like
                // against an idempotent destination.
                logger.LogInformation("[corr:{CorrelationId}] SKIPPED {Sku} v{Version}: destination already current",
                    item.CorrelationId, processed.Sku, processed.Version);

                return Task.FromResult(new ItemOutcome
                {
                    Sku = processed.Sku,
                    Success = true,
                    Reason = "skipped"
                });
            }

            logger.LogInformation("[corr:{CorrelationId}] POSTED {Sku} v{Version} to destination (wholesale={Price})",
                item.CorrelationId, processed.Sku, processed.Version, processed.WholesalePrice);

            return Task.FromResult(new ItemOutcome { Sku = processed.Sku, Success = true });
        }
        catch (Exception ex)
        {
            // Throwing here triggers the RetryPolicy above; if all retries fail
            // the orchestrator records the item as failed and the run continues.
            logger.LogError(ex, "[corr:{CorrelationId}] Failed to post {Sku}", item.CorrelationId, processed.Sku);
            throw;
        }
    }
}

/// <summary>Input shape for the fetch activity.</summary>
public record FetchRequest
{
    public string RunId { get; init; } = "";
    public string CorrelationId { get; init; } = "";
    public string? Category { get; init; }
}
