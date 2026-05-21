using System.Text;
using System.Text.Json;

namespace McpOAuthEntra.AuthProxy;

public static class AuthProxyEndpoints
{
    public static IEndpointRouteBuilder MapAuthProxy(this IEndpointRouteBuilder app)
    {
        app.MapGet("/.well-known/oauth-protected-resource", ProtectedResourceMetadata);
        app.MapGet("/.well-known/oauth-authorization-server", AuthorizationServerMetadata);
        app.MapGet("/authorize", Authorize);
        app.MapGet("/callback", Callback);
        app.MapPost("/token", Token);
        return app;
    }

    // RFC 9728: points MCP clients at this server's own OAuth proxy endpoints.
    private static IResult ProtectedResourceMetadata(HttpRequest req, IConfiguration cfg)
    {
        var cid     = cfg["AzureAd:ClientId"];
        var baseUrl = $"{req.Scheme}://{req.Host}";
        return Results.Json(new
        {
            resource                 = $"api://{cid}",
            authorization_servers    = new[] { baseUrl },
            bearer_methods_supported = new[] { "header" },
            scopes_supported         = new[] { $"api://{cid}/user_impersonation" }
        });
    }

    // RFC 8414: advertises /authorize and /token so clients don't have to guess.
    private static IResult AuthorizationServerMetadata(HttpRequest req, IConfiguration cfg)
    {
        var cid     = cfg["AzureAd:ClientId"];
        var baseUrl = $"{req.Scheme}://{req.Host}";
        return Results.Json(new
        {
            issuer                                = baseUrl,
            authorization_endpoint                = $"{baseUrl}/authorize",
            token_endpoint                        = $"{baseUrl}/token",
            response_types_supported              = new[] { "code" },
            grant_types_supported                 = new[] { "authorization_code", "refresh_token" },
            code_challenge_methods_supported      = new[] { "S256" },
            token_endpoint_auth_methods_supported = new[] { "none" },
            scopes_supported                      = new[] { $"api://{cid}/user_impersonation", "offline_access" }
        });
    }

    // Packs the client's redirect_uri + state into our proxy state, then redirects
    // to Entra ID using our fixed /callback URL. This means only one redirect URI
    // ever needs to be registered in the app registration.
    private static IResult Authorize(HttpRequest req, IConfiguration cfg)
    {
        var tid  = cfg["AzureAd:TenantId"];
        var cid  = cfg["AzureAd:ClientId"];
        var inst = Instance(cfg);

        var proxyState = ToBase64Json(new
        {
            redirectUri = req.Query["redirect_uri"].ToString(),
            state       = req.Query["state"].ToString()
        });

        var qs = QueryString.Create([
            KeyValuePair.Create<string, string?>("response_type",         "code"),
            KeyValuePair.Create<string, string?>("client_id",             cid),
            KeyValuePair.Create<string, string?>("redirect_uri",          $"{req.Scheme}://{req.Host}/callback"),
            KeyValuePair.Create<string, string?>("scope",                 $"api://{cid}/user_impersonation offline_access"),
            KeyValuePair.Create<string, string?>("code_challenge",        req.Query["code_challenge"].ToString()),
            KeyValuePair.Create<string, string?>("code_challenge_method", req.Query["code_challenge_method"].FirstOrDefault() ?? "S256"),
            KeyValuePair.Create<string, string?>("state",                 proxyState),
        ]);

        return Results.Redirect($"{inst}/{tid}/oauth2/v2.0/authorize{qs}");
    }

    // Entra ID returns here. Unpacks the proxy state and relays the code to the
    // MCP client's original redirect_uri (e.g. VS Code's random localhost port).
    private static IResult Callback(HttpRequest req)
    {
        try
        {
            var packed          = FromBase64Json(req.Query["state"].ToString());
            var clientRedirect  = packed.GetProperty("redirectUri").GetString() ?? "";
            var clientState     = packed.GetProperty("state").GetString() ?? "";

            var error = req.Query["error"].ToString();
            if (!string.IsNullOrEmpty(error))
            {
                var desc = Uri.EscapeDataString(req.Query["error_description"].ToString());
                return Results.Redirect(
                    $"{clientRedirect}?error={Uri.EscapeDataString(error)}&error_description={desc}&state={Uri.EscapeDataString(clientState)}");
            }

            return Results.Redirect(
                $"{clientRedirect}?code={Uri.EscapeDataString(req.Query["code"].ToString())}&state={Uri.EscapeDataString(clientState)}");
        }
        catch
        {
            return Results.BadRequest("Invalid callback state.");
        }
    }

    // Proxies the code exchange (or refresh) to Entra ID's token endpoint.
    private static async Task<IResult> Token(HttpRequest req, IConfiguration cfg, IHttpClientFactory http)
    {
        var tid  = cfg["AzureAd:TenantId"];
        var cid  = cfg["AzureAd:ClientId"];
        var inst = Instance(cfg);

        var form      = await req.ReadFormAsync();
        var grantType = form["grant_type"].FirstOrDefault() ?? "authorization_code";

        var tokenParams = grantType == "refresh_token"
            ? new Dictionary<string, string>
              {
                  ["grant_type"]    = "refresh_token",
                  ["client_id"]     = cid!,
                  ["refresh_token"] = form["refresh_token"].FirstOrDefault() ?? "",
                  ["scope"]         = $"api://{cid}/user_impersonation offline_access",
              }
            : new Dictionary<string, string>
              {
                  ["grant_type"]    = "authorization_code",
                  ["client_id"]     = cid!,
                  ["code"]          = form["code"].FirstOrDefault()          ?? "",
                  ["redirect_uri"]  = $"{req.Scheme}://{req.Host}/callback",
                  ["code_verifier"] = form["code_verifier"].FirstOrDefault() ?? "",
                  ["scope"]         = $"api://{cid}/user_impersonation offline_access",
              };

        var response = await http.CreateClient().PostAsync(
            $"{inst}/{tid}/oauth2/v2.0/token",
            new FormUrlEncodedContent(tokenParams));

        return Results.Content(
            await response.Content.ReadAsStringAsync(),
            "application/json",
            statusCode: (int)response.StatusCode);
    }

    private static string Instance(IConfiguration cfg) =>
        (cfg["AzureAd:Instance"] ?? "https://login.microsoftonline.com").TrimEnd('/');

    private static string ToBase64Json(object value) =>
        Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(value)));

    private static JsonElement FromBase64Json(string base64) =>
        JsonSerializer.Deserialize<JsonElement>(Encoding.UTF8.GetString(Convert.FromBase64String(base64)));
}
