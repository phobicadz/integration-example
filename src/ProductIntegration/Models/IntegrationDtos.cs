using System.Text.Json.Serialization;

namespace ProductIntegration.Models;

/// <summary>Payload sent to the orchestrator when a run is started.</summary>
public record IntegrationRequest
{
    /// <summary>Optional category filter applied when fetching from the source.</summary>
    [JsonPropertyName("category")]
    public string? Category { get; init; }

    /// <summary>
    /// Correlation id for the whole run, created at the HTTP edge and threaded through
    /// every activity, log line and destination record. Sent as `x-correlation-id`, or
    /// taken from the caller's W3C `traceparent` header.
    /// </summary>
    [JsonPropertyName("correlationId")]
    public string? CorrelationId { get; init; }
}

/// <summary>What an activity receives: the item plus the ids used for tracing.</summary>
public record ItemWorkItem
{
    [JsonPropertyName("runId")]
    public string RunId { get; init; } = "";

    [JsonPropertyName("correlationId")]
    public string CorrelationId { get; init; } = "";

    [JsonPropertyName("product")]
    public Product Product { get; init; } = new();
}

/// <summary>Result of processing+posting a single item.</summary>
public record ItemOutcome
{
    [JsonPropertyName("sku")]
    public string Sku { get; init; } = "";

    [JsonPropertyName("success")]
    public bool Success { get; init; }

    [JsonPropertyName("reason")]
    public string? Reason { get; init; }

    [JsonPropertyName("detail")]
    public string? Detail { get; init; }
}

/// <summary>Final result returned by the orchestrator.</summary>
public record IntegrationSummary
{
    [JsonPropertyName("runId")]
    public string RunId { get; init; } = "";

    /// <summary>The correlation id every log line and destination record of this run carries.</summary>
    [JsonPropertyName("correlationId")]
    public string CorrelationId { get; init; } = "";

    [JsonPropertyName("totalFetched")]
    public int TotalFetched { get; init; }

    [JsonPropertyName("posted")]
    public int Posted { get; init; }

    /// <summary>Items accepted by the destination but already current there (stale version).</summary>
    [JsonPropertyName("skipped")]
    public int Skipped { get; init; }

    [JsonPropertyName("rejected")]
    public int Rejected { get; init; }

    [JsonPropertyName("failed")]
    public int Failed { get; init; }
}
