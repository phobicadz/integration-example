using System.Text.Json.Serialization;

namespace ProductIntegration.Models;

/// <summary>A product as returned by the (mocked) upstream source system.</summary>
public record Product
{
    [JsonPropertyName("sku")]
    public string Sku { get; init; } = "";

    [JsonPropertyName("name")]
    public string Name { get; init; } = "";

    [JsonPropertyName("category")]
    public string Category { get; init; } = "";

    [JsonPropertyName("unitPrice")]
    public decimal UnitPrice { get; init; }

    [JsonPropertyName("stock")]
    public int Stock { get; init; }

    /// <summary>
    /// Source-supplied revision counter. It must come FROM the source and be
    /// monotonic — never generated locally (e.g. from ProcessedAtUtc), because a
    /// retry would mint a newer value and defeat the destination's staleness guard.
    /// </summary>
    [JsonPropertyName("version")]
    public long Version { get; init; }
}
