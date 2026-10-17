using System.Net;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.DurableTask.Client;
using ProductIntegration.Models;

namespace ProductIntegration.Functions;

/// <summary>
/// HTTP entry point that KICKS OFF the durable orchestration and immediately
/// returns 202 Accepted with links to the status/history/query-management endpoints.
///
/// This is the standard Durable Functions "async HTTP pattern": the caller polls
/// the status endpoint instead of waiting for the whole integration to finish.
/// </summary>
public class ImportTrigger
{
    [Function("products-import")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "products/import")] HttpRequestData req,
        [DurableClient] DurableTaskClient client)
    {
        var request = await TryReadRequestAsync(req);

        string instanceId = await client.ScheduleNewOrchestrationInstanceAsync(
            nameof(ProductImportOrchestrator), new IntegrationRequest { Category = request?.Category });

        var response = req.CreateResponse(HttpStatusCode.Accepted);
        response.Headers.Add("Location", $"/api/products/import/{instanceId}/status");
        response.Headers.Add("Retry-After", "5");
        await response.WriteAsJsonAsync(new
        {
            runId = instanceId,
            statusUrl = $"/api/products/import/{instanceId}/status",
            message = "Integration run started. Poll the statusUrl until the orchestration completes."
        });
        return response;
    }

    private static async Task<IntegrationRequest?> TryReadRequestAsync(HttpRequestData req)
    {
        try
        {
            return await req.ReadFromJsonAsync<IntegrationRequest>();
        }
        catch
        {
            return null; // body is optional
        }
    }
}
