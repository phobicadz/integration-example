using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Middleware;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace ProductIntegration;

/// <summary>
/// Cross-cutting correlation middleware: for every HTTP invocation it resolves the
/// correlation id (caller-supplied `x-correlation-id` or W3C `traceparent`, else a
/// fresh one), echoes it on the response so the caller can quote it back, and logs
/// one start/finish line per request carrying it.
///
/// This is the "one place, every request" half of correlation; the trigger,
/// orchestrator and activities thread the same id through the run itself.
/// Registered in Program.cs via `builder.Use(next => CorrelationMiddleware.Wrap(next))`.
/// </summary>
public static class CorrelationMiddleware
{
    public static FunctionExecutionDelegate Wrap(FunctionExecutionDelegate next) => async context =>
    {
        // Activities/orchestrations have no HTTP request; only trace HTTP invocations.
        var http = context.GetHttpContext();
        if (http is null)
        {
            await next(context);
            return;
        }

        var logger = context.InstanceServices
            .GetRequiredService<ILoggerFactory>()
            .CreateLogger(nameof(CorrelationMiddleware));

        string correlationId = Correlation.Resolve(http.Request);
        http.Response.Headers[Correlation.HeaderName] = correlationId;

        using (Correlation.BeginLogScope(logger, correlationId))
        {
            logger.LogInformation("[corr:{CorrelationId}] {Method} {Path}",
                correlationId, http.Request.Method, http.Request.Path.Value);

            await next(context);

            logger.LogInformation("[corr:{CorrelationId}] {Method} {Path} -> {Status}",
                correlationId, http.Request.Method, http.Request.Path.Value, http.Response.StatusCode);
        }
    };
}
