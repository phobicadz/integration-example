using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using ProductIntegration.Services;

namespace ProductIntegration.Functions;

/// <summary>
/// Inspect the mocked DESTINATION endpoint: shows exactly what the integration
/// has delivered so far. Handy for verifying end-to-end behaviour.
/// </summary>
public class DestinationInspector
{
    private readonly MockDestinationStore _destination;

    public DestinationInspector(MockDestinationStore destination) => _destination = destination;

    [Function("products-destination")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "products/destination")] HttpRequestData req)
    {
        var items = _destination.All();
        var response = req.CreateResponse(System.Net.HttpStatusCode.OK);
        await response.WriteAsJsonAsync(new
        {
            received = items.Count,
            items = items.OrderBy(i => i.Sku)
        });
        return response;
    }
}
