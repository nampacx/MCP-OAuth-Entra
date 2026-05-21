// =============================================================================
// MCP OAuth Entra – Azure AI Foundry
// =============================================================================
// Deploys an AI Foundry account and a Foundry Project for Identity Passthrough
// testing. swedencentral is the recommended region (widest model coverage).
//
// Resource types:
//   Microsoft.CognitiveServices/accounts          – Foundry account
//   Microsoft.CognitiveServices/accounts/projects – Foundry project
// =============================================================================

targetScope = 'resourceGroup'

// ── Parameters ────────────────────────────────────────────────────────────────

@description('Prefix used for all resource names (3–15 alphanumeric characters).')
@minLength(3)
@maxLength(15)
param appName string = 'mcp-entra'

@description('Azure region for all Foundry resources.')
param location string = 'swedencentral'

@description('Optional resource tags applied to all resources.')
param tags object = {}

// ── Variables ─────────────────────────────────────────────────────────────────

// customSubDomainName: 3–24 lowercase alphanumeric, globally unique, required
// before any projects can be created under the account.
var customSubDomainName = take('${toLower(replace(appName, '-', ''))}${uniqueString(resourceGroup().id)}', 24)

// ── AI Foundry account ────────────────────────────────────────────────────────

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: '${appName}-fndry'
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    publicNetworkAccess: 'Enabled'
    allowProjectManagement: true
    customSubDomainName: customSubDomainName
    disableLocalAuth: true
  }
}

// ── Model deployment ─────────────────────────────────────────────────────────

resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: foundry
  name: 'gpt-5.4'
  sku: {
    name: 'GlobalStandard'
    capacity: 500 // 500 = 500 000 tokens per minute
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-5.4'
      version: '2026-03-05'
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
}

// ── AI Foundry project ────────────────────────────────────────────────────────

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundry
  name: '${appName}-prj'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: '${appName} Project'
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

@description('Name of the AI Foundry account.')
output foundryName string = foundry.name

@description('Name of the AI Foundry project.')
output projectName string = project.name

@description('Name of the model deployment.')
output modelDeploymentName string = modelDeployment.name
