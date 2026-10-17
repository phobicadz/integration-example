using System.Text.Json.Serialization;

namespace ProductIntegration.Models;

/// <summary>A product after our integration's transformation/validation step.</summary>
public record ProcessedProduct
{
    [JsonPropertyName("sku")]
    public string Sku { get; init; } = "";

    [JsonPropertyName("name")]
    public string Name { get; init; } = "";

    [JsonPropertyName("category")]
    public string Category { get; init; } = "";

    [JsonPropertyName("unitPrice")]
    public decimal UnitPrice { get; init; }

    [JsonPropertyName("wholesalePrice")]
    public decimal WholesalePrice { get; init; }

    [JsonPropertyName("stock")]
    public int Stock { get; init; }

    /// <summary>Version copied verbatim from the source product — used by the destination CAS guard.</summary>
    [JsonPropertyName("version")]
    public long Version { get; init; }

    [JsonPropertyName("isValid")]
    public bool IsValid { get; init; }

    [JsonPropertyName("validationIssues")]
    public List<string> ValidationIssues { get; init; } = new();

    [JsonPropertyName("processedAtUtc")]
    public DateTimeOffset ProcessedAtUtc { get; init; }

    /// <summary>
    /// Which integration run delivered this record — the destination keeps the
    /// correlation id so a downstream problem can be traced back to the exact run
    /// and its log lines. In a real system this is a column / message property.
    /// </summary>
    [JsonPropertyName("correlationId")]
    public string CorrelationId { get; init; } = "";
}
