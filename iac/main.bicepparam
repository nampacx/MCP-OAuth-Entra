using './main.bicep'

// Replace these values before deploying.
// Run deploy/01-Register-EntraApp.ps1 first — it prints TenantId and ClientId.

param appName           = 'mcp-entra'
param appServicePlanSku = 'B1'
param tenantId                = 'YOUR_TENANT_ID'
param clientId                = 'YOUR_CLIENT_ID'
param deployingUserObjectId   = 'YOUR_OBJECT_ID'  // overridden by 01-Provision.ps1
param instance          = 'https://login.microsoftonline.com/'
param tags              = {
  Project: 'MCP-OAuth-Entra'
  ManagedBy: 'Bicep'
}
