// =============================================================================
// MCP OAuth Entra – Azure Infrastructure
// =============================================================================
// Deploys a Linux App Service Plan + Web App to host the MCP server.
// Authentication is handled by the application (JwtBearer / Entra ID).
//
// Before deploying, verify the AVM module versions against the public catalog:
//   https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/web
// =============================================================================

targetScope = 'resourceGroup'

// ── Parameters ────────────────────────────────────────────────────────────────

@description('Azure region for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Prefix used for all resource names (3–15 alphanumeric characters).')
@minLength(3)
@maxLength(15)
param appName string = 'mcp-entra'

@description('App Service Plan SKU. B1 is sufficient for development.')
@allowed(['B1', 'B2', 'B3', 'S1', 'S2', 'P1v3', 'P2v3', 'P3v3'])
param appServicePlanSku string = 'B1'

@description('Entra ID Tenant ID (Directory ID).')
param tenantId string

@description('Entra ID Application (Client) ID of the app registration.')
param clientId string

@description('Entra ID authority instance URL.')
param instance string = 'https://login.microsoftonline.com/'

@description('Optional resource tags applied to all resources.')
param tags object = {}

// ── App Service Plan (Linux) ──────────────────────────────────────────────────
// AVM module: https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/web/serverfarm
// Verify latest version before pinning.

module appServicePlan 'br/public:avm/res/web/serverfarm:0.4.1' = {
  name: 'appServicePlanDeployment'
  params: {
    name: '${appName}-asp'
    location: location
    skuName: appServicePlanSku
    reserved: true // required for Linux hosting
    tags: tags
  }
}

// ── Web App ───────────────────────────────────────────────────────────────────
// AVM module: https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/web/site
// Verify latest version before pinning.

module webApp 'br/public:avm/res/web/site:0.13.3' = {
  name: 'webAppDeployment'
  params: {
    name: '${appName}-app'
    location: location
    kind: 'app,linux'
    serverFarmResourceId: appServicePlan.outputs.resourceId
    tags: tags

    // Enable system-assigned managed identity for future Key Vault / Graph integration.
    managedIdentities: {
      systemAssigned: true
    }

    httpsOnly: true

    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|9.0'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
    }

    // App settings consumed by Program.cs via IConfiguration.
    // Double-underscore (__) is the hierarchy separator for environment variables
    // in ASP.NET Core (equivalent to ":" in appsettings.json).
    appSettingsKeyValuePairs: {
      ASPNETCORE_ENVIRONMENT: 'Production'
      AzureAd__Instance: instance
      AzureAd__TenantId: tenantId
      AzureAd__ClientId: clientId
      // Set to '1' so the app runs from the uploaded ZIP package.
      WEBSITE_RUN_FROM_PACKAGE: '1'
    }
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

@description('Default hostname of the deployed web app.')
output webAppHostname string = webApp.outputs.defaultHostname

@description('Name of the deployed web app.')
output webAppName string = webApp.outputs.name

@description('MCP endpoint URL (pass this to your MCP client).')
output mcpEndpointUrl string = 'https://${webApp.outputs.defaultHostname}/mcp'

@description('OAuth Protected Resource Metadata URL (auto-discovered by MCP clients).')
output prmUrl string = 'https://${webApp.outputs.defaultHostname}/.well-known/oauth-protected-resource'

@description('Principal ID of the system-assigned managed identity.')
output managedIdentityPrincipalId string = webApp.outputs.systemAssignedMIPrincipalId
