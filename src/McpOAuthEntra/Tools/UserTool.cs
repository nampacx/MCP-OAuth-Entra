using System.ComponentModel;
using System.Security.Claims;
using ModelContextProtocol.Server;

namespace McpOAuthEntra.Tools;

[McpServerToolType]
public sealed class UserTool(IHttpContextAccessor httpContextAccessor)
{
    [McpServerTool(Name = "get_user")]
    [Description("Returns all non-null claims present in the authenticated user's JWT token.")]
    public Dictionary<string, string> GetUser()
    {
        var principal = httpContextAccessor.HttpContext?.User
            ?? throw new InvalidOperationException("No HTTP context available.");

        return principal.Claims
            .Where(c => !string.IsNullOrEmpty(c.Value))
            .GroupBy(c => c.Type)
            .ToDictionary(
                g => g.Key,
                g => string.Join(", ", g.Select(c => c.Value))
            );
    }
}
