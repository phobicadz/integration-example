using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using ProductIntegration.Services;
using ProductIntegration;

var host = new HostBuilder()
    .ConfigureFunctionsWebApplication(builder =>
    {
        // Register the mocked source/destination as singletons so state persists
        // across function invocations within the host (good enough for a demo).
        builder.Services.AddSingleton<MockSourceCatalog>();
        builder.Services.AddSingleton<MockDestinationStore>();

        // Correlation middleware: resolves/echoes x-correlation-id for every HTTP
        // invocation and logs each request with it. Runs for all HTTP functions.
        builder.Use(next => CorrelationMiddleware.Wrap(next));

        // Application Insights telemetry for monitoring (enable by setting
        // APPINSIGHTS_INSTRUMENTATIONKEY or CONNECTION_STRING).
        builder.Services
            .AddApplicationInsightsTelemetryWorkerService()
            .ConfigureFunctionsApplicationInsights();
    })
    .Build();

host.Run();
