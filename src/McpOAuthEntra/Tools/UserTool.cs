using System.ComponentModel;
using System.Security.Claims;
using McpOAuthEntra.Services;
using ModelContextProtocol.Server;

namespace McpOAuthEntra.Tools;

[McpServerToolType]
public sealed class UserTool(IHttpContextAccessor httpContextAccessor, GraphService graphService, ILogger<UserTool> logger)
{
    [McpServerTool(Name = "get_user")]
    [Description("Returns all non-null claims present in the authenticated user's JWT token.")]
    public Dictionary<string, string> GetUser()
    {
        var principal = httpContextAccessor.HttpContext?.User
            ?? throw new InvalidOperationException("No HTTP context available.");

        var claims = principal.Claims
            .Where(c => !string.IsNullOrEmpty(c.Value))
            .GroupBy(c => c.Type)
            .ToDictionary(
                g => g.Key,
                g => string.Join(", ", g.Select(c => c.Value))
            );

        var upn = principal.FindFirst("preferred_username")?.Value
               ?? principal.FindFirst("upn")?.Value
               ?? "(unknown)";

        logger.LogInformation("get_user invoked for {Upn} — returning {ClaimCount} claims", upn, claims.Count);

        return claims;
    }

    [McpServerTool(Name = "get_graph_profile")]
    [Description("Returns the authenticated user's Microsoft Graph profile (display name, UPN, email, job title, department, office location).")]
    public async Task<object> GetGraphProfileAsync()
    {
        logger.LogInformation("get_graph_profile invoked");

        var user = await graphService.GetProfileAsync();

        return new
        {
            displayName      = user.DisplayName,
            userPrincipalName = user.UserPrincipalName,
            mail             = user.Mail,
            givenName        = user.GivenName,
            surname          = user.Surname,
            jobTitle         = user.JobTitle,
            department       = user.Department,
            officeLocation   = user.OfficeLocation,
            id               = user.Id,
        };
    }
}
