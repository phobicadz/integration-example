using System.Collections.Concurrent;

namespace ProductIntegration.Services;

/// <summary>
/// In-memory stand-in for the DESTINATION system.
/// Everything the integration successfully posts lands here, so the
/// /products/destination endpoint can show exactly what was delivered.
///
/// In a real integration this would be a database, an Event Grid topic,
/// a Service Bus queue, or another team's API.
/// </summary>
/// <summary>Outcome of a compare-and-swap upsert against the store.</summary>
public enum UpsertResult
{
    /// <summary>The item was newer (or new) and was written.</summary>
    Applied,

    /// <summary>The store already holds an equal-or-newer version — idempotent no-op.</summary>
    SkippedStale,
}

public class MockDestinationStore
{
    private readonly ConcurrentDictionary<string, Models.ProcessedProduct> _items = new();

    public IReadOnlyCollection<Models.ProcessedProduct> All() => _items.Values.ToList();

    /// <summary>
    /// Compare-and-swap upsert: only writes when the incoming version is strictly
    /// newer than what is stored. This is the idempotency guard that makes replays
    /// and duplicate deliveries harmless. A real destination would do the same via
    /// Cosmos _etag / SQL "WHERE version &lt; @version" / Service Bus MessageId dedupe.
    /// </summary>
    public UpsertResult Upsert(Models.ProcessedProduct item)
    {
        var final = _items.AddOrUpdate(
            item.Sku,
            _ => item,
            (_, current) => item.Version > current.Version ? item : current);

        return ReferenceEquals(final, item) ? UpsertResult.Applied : UpsertResult.SkippedStale;
    }

    public int Count => _items.Count;
}
