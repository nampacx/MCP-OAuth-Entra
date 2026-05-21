using Azure.Identity;
using Microsoft.Graph;
using Microsoft.Graph.Models;

namespace McpOAuthEntra.Services;

public sealed class GraphService(IConfiguration config, IHttpContextAccessor http, ILogger<GraphService> logger)
{
    public async Task<User> GetProfileAsync()
    {
        var tenantId     = config["AzureAd:TenantId"]     ?? throw new InvalidOperationException("AzureAd:TenantId is required.");
        var clientId     = config["AzureAd:ClientId"]     ?? throw new InvalidOperationException("AzureAd:ClientId is required.");
        var clientSecret = config["AzureAd:ClientSecret"] ?? throw new InvalidOperationException("AzureAd:ClientSecret is required.");

        var authHeader = http.HttpContext?.Request.Headers.Authorization.ToString()
            ?? throw new InvalidOperationException("No Authorization header present.");

        var userToken = authHeader.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)
            ? authHeader["Bearer ".Length..]
            : throw new InvalidOperationException("Authorization header is not a Bearer token.");

        logger.LogDebug("Exchanging incoming token for Graph-scoped token via OBO");

        // Exchange the incoming token for a Graph-scoped token via OAuth 2.0 OBO flow.
        var credential  = new OnBehalfOfCredential(tenantId, clientId, clientSecret, userToken);
        var graphClient = new GraphServiceClient(credential);

        var user = await graphClient.Me.GetAsync()
            ?? throw new InvalidOperationException("Microsoft Graph returned null for /me.");

        logger.LogInformation("Graph /me succeeded for {Upn}", user.UserPrincipalName);

        return user;
    }
}
