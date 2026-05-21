using McpOAuthEntra.Services;
using McpOAuthEntra.Tools;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;

var builder = WebApplication.CreateBuilder(args);

// ── Entra ID configuration ───────────────────────────────────────────────────
var azureAd = builder.Configuration.GetSection("AzureAd");
var tenantId = azureAd["TenantId"] ?? throw new InvalidOperationException("AzureAd:TenantId is required.");
var clientId = azureAd["ClientId"] ?? throw new InvalidOperationException("AzureAd:ClientId is required.");
var instance = (azureAd["Instance"] ?? "https://login.microsoftonline.com").TrimEnd('/');

// ── Authentication ───────────────────────────────────────────────────────────
builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.Authority = $"{instance}/{tenantId}/v2.0";

        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidAudiences = [$"api://{clientId}", clientId],
            // Accept both v1 (sts.windows.net) and v2 (login.microsoftonline.com) issuers.
            ValidIssuers = [
                $"{instance}/{tenantId}/v2.0",
                $"https://sts.windows.net/{tenantId}/"
            ],
        };

        options.Events = new JwtBearerEvents
        {
            OnChallenge = async context =>
            {
                context.HandleResponse();
                var req    = context.Request;
                var prmUrl = $"{req.Scheme}://{req.Host}/.well-known/oauth-protected-resource";
                context.Response.StatusCode = StatusCodes.Status401Unauthorized;
                context.Response.Headers.WWWAuthenticate = $"Bearer resource_metadata=\"{prmUrl}\"";
                context.Response.ContentType = "application/json";
                await context.Response.WriteAsync(
                    """{"error":"unauthorized","error_description":"A valid Bearer token is required. Authenticate via Entra ID."}""");
            }
        };
    });

builder.Services.AddAuthorization();
builder.Services.AddHttpContextAccessor();
builder.Services.AddScoped<GraphService>();

// ── MCP server ───────────────────────────────────────────────────────────────
builder.Services
    .AddMcpServer()
    .WithHttpTransport(o => o.Stateless = true)
    .WithTools<UserTool>();

var app = builder.Build();

app.UseHttpsRedirection();
app.UseAuthentication();
app.UseAuthorization();

// ── RFC 9728 — OAuth 2.0 Protected Resource Metadata ─────────────────────────
// Advertises the Entra ID authorization server so MCP clients can perform
// automatic OAuth discovery after receiving the 401 challenge.
var prmDocument = new
{
    resource                 = $"api://{clientId}",
    authorization_servers    = new[] { $"{instance}/{tenantId}/v2.0" },
    bearer_methods_supported = new[] { "header" },
    scopes_supported         = new[] { $"api://{clientId}/user_impersonation" }
};
app.MapGet("/.well-known/oauth-protected-resource", () => Results.Ok(prmDocument));

app.MapMcp("/mcp").RequireAuthorization();

app.Run();
