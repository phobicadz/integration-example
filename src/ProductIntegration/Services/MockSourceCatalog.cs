using ProductIntegration.Models;

namespace ProductIntegration.Services;

/// <summary>
/// In-memory stand-in for the SOURCE system (the "mocked endpoint" we import from).
///
/// Deliberately imperfect, like a real upstream:
///  - a couple of records are dirty (missing name, negative price, zero stock)
///    so the processing/validation step has something to reject,
///  - it randomly fails ~15% of the time so the retry policy in the activity
///    has something to demonstrate.
/// </summary>
public class MockSourceCatalog
{
    private static readonly Random _random = new();

    public List<Product> Fetch(string? category)
    {
        // Simulate an unstable upstream so retries are meaningful.
        if (_random.NextDouble() < 0.15)
        {
            throw new TransientUpstreamException(
                "Mock upstream returned 503 (simulated transient failure).");
        }

        // Versions are static on purpose: a second run in the same host fetches the
        // SAME versions, so the destination's CAS guard reports them as stale.
        // SKU-008 carries version 2 to simulate a source-side edit between releases.
        var all = new List<Product>
        {
            new() { Sku = "SKU-001", Name = "Widget Alpha",   Category = "widgets",   UnitPrice = 12.50m, Stock = 120, Version = 1 },
            new() { Sku = "SKU-002", Name = "Widget Beta",    Category = "widgets",   UnitPrice = 9.99m,  Stock = 80,  Version = 1 },
            new() { Sku = "SKU-003", Name = "Gadget Prime",   Category = "gadgets",   UnitPrice = 45.00m, Stock = 35,  Version = 1 },
            new() { Sku = "SKU-004", Name = "Gadget Minor",   Category = "gadgets",   UnitPrice = 22.75m, Stock = 12,  Version = 1 },
            new() { Sku = "SKU-005", Name = "",               Category = "gadgets",   UnitPrice = 5.00m,  Stock = 4,   Version = 1 }, // dirty: no name
            new() { Sku = "SKU-006", Name = "Doohickey",      Category = "misc",      UnitPrice = -3.00m, Stock = 9,   Version = 1 }, // dirty: negative price
            new() { Sku = "SKU-007", Name = "Thingamajig",    Category = "misc",      UnitPrice = 18.40m, Stock = 0,   Version = 1 }, // dirty: out of stock
            new() { Sku = "SKU-008", Name = "Contraption X",  Category = "widgets",   UnitPrice = 130.00m, Stock = 5,   Version = 2 }, // source edited this one
            new() { Sku = "SKU-009", Name = "Sprocket Kit",    Category = "tools",     UnitPrice = 34.99m,  Stock = 60,  Version = 1 },
            new() { Sku = "SKU-010", Name = "Caliper Pro",     Category = "tools",     UnitPrice = 89.95m,  Stock = 25,  Version = 1 },
            new() { Sku = "SKU-011", Name = "Sensor Hub",      Category = "electronics", UnitPrice = 210.00m, Stock = 18, Version = 3 }, // source edited this one twice
            new() { Sku = "SKU-012", Name = "Cable Set",       Category = "electronics", UnitPrice = 7.25m,  Stock = 500, Version = 1 },
            new() { Sku = "",        Name = "Mystery Part",    Category = "misc",      UnitPrice = 15.00m,  Stock = 10,  Version = 1 }, // dirty: no SKU
            new() { Sku = "SKU-014", Name = "Broken Combo",    Category = "misc",      UnitPrice = -1.50m,  Stock = 0,   Version = 1 }, // dirty: negative price AND out of stock
        };

        return string.IsNullOrWhiteSpace(category)
            ? all
            : all.Where(p => p.Category.Equals(category, StringComparison.OrdinalIgnoreCase)).ToList();
    }
}

/// <summary>Thrown by the mock source to simulate a transient upstream outage.</summary>
public class TransientUpstreamException : Exception
{
    public TransientUpstreamException(string message) : base(message) { }
}
