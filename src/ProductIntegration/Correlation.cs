using System.Diagnostics;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;

namespace ProductIntegration;

/// <summary>
/// Correlation-id plumbing for the whole integration.
///
/// Rules this demo encodes:
///  - The correlation id is created ONCE, at the edge (the HTTP trigger).
///  - It is honoured if the caller already sent one: we accept our own
///    `x-correlation-id` header, or the trace-id from a W3C `traceparent`
///    header (that is what most gateways/API managers send).
///  - It is then threaded through the orchestration input, every activity
///    payload, every log line, the records written to the destination, and
///    every HTTP response (body + `x-correlation-id` header).
///
/// IMPORTANT: never generate a correlation id inside an orchestrator — call
/// `Guid.NewGuid()` there and you break determinism/replayability. Orchestrators
/// derive it from their (replayable) input, falling back to the instance id.
/// </summary>
public static class Correlation
{
    /// <summary>Header used to pass a correlation id in and out of this service.</summary>
    public const string HeaderName = "x-correlation-id";

    /// <summary>W3C Trace Context header: `version-traceid-parentid-flags`.</summary>
    public const string TraceParentHeaderName = "traceparent";

    /// <summary>
    /// Resolve the correlation id for an incoming request: caller-supplied
    /// `x-correlation-id` wins, then the `traceparent` trace-id, then the
    /// ambient Activity (set by the Functions host / telemetry SDK), else a new id.
    /// </summary>
    public static string Resolve(HttpRequestData req)
        => Resolve(name => GetHeader(req, name));

    /// <summary>Same resolution for an ASP.NET Core request (used by the middleware).</summary>
    public static string Resolve(Microsoft.AspNetCore.Http.HttpRequest request)
        => Resolve(name => request.Headers.TryGetValue(name, out var value) ? value.ToString() : null);

    private static string Resolve(Func<string, string?> getHeader)
    {
        var explicitId = getHeader(HeaderName);
        if (IsValid(explicitId)) return explicitId!;

        string? traceId;
        if (TryGetTraceIdFromTraceParent(getHeader(TraceParentHeaderName), out traceId))
            return traceId!;

        var current = Activity.Current;
        if (current is not null && current.TraceId != default)
            return current.TraceId.ToHexString();

        return Guid.NewGuid().ToString("N");
    }

    /// <summary>
    /// Correlation id for an orchestration run: reuse the one that came in with the
    /// request (deterministic across replays); fall back to the instance id, which is
    /// itself stable for a given run.
    /// </summary>
    public static string ForRun(string? requestCorrelationId, string instanceId)
        => string.IsNullOrWhiteSpace(requestCorrelationId) ? instanceId : requestCorrelationId!;

    /// <summary>
    /// Adds `correlationId` (and the run id) as structured log properties so the
    /// fields are queryable in Application Insights instead of only being text in
    /// the message. Always used in a `using` block so it is scoped to one call.
    /// </summary>
    public static IDisposable? BeginLogScope(ILogger logger, string correlationId, string? runId = null)
    {
        var scope = new Dictionary<string, object> { ["correlationId"] = correlationId };
        if (!string.IsNullOrWhiteSpace(runId)) scope["runId"] = runId!;
        return logger.BeginScope(scope);
    }

    private static string? GetHeader(HttpRequestData req, string name)
    {
        foreach (var header in req.Headers)
        {
            if (!string.Equals(header.Key, name, StringComparison.OrdinalIgnoreCase)) continue;

            var value = header.Value.FirstOrDefault();
            return string.IsNullOrWhiteSpace(value) ? null : value;
        }

        return null;
    }

    /// <summary>Parse the trace-id out of a W3C traceparent value.</summary>
    private static bool TryGetTraceIdFromTraceParent(string? traceParent, out string? traceId)
    {
        traceId = null;
        if (string.IsNullOrWhiteSpace(traceParent)) return false;

        // Format: version(2) '-' traceid(32 hex) '-' parentid(16 hex) '-' flags(2 hex)
        var parts = traceParent.Trim().Split('-');
        if (parts.Length < 2 || parts[1].Length != 32 || !IsHex(parts[1])) return false;

        // All-zero trace-id means "invalid/unsampled" upstream context — ignore it.
        if (parts[1] == "00000000000000000000000000000000") return false;

        traceId = parts[1];
        return true;
    }

    private static bool IsHex(string value)
        => value.All(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'));

    private static bool IsValid(string? value)
        => !string.IsNullOrWhiteSpace(value) && value.Length is >= 8 and <= 128 && !value.Contains('\n');
}
