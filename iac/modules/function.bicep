@description('Região')
param location string
@description('Sufixo único')
param suffix string
@description('Nome do Key Vault (p/ role Secrets User)')
param keyVaultName string

var secretsUser = '4633458b-17de-408a-b874-0445c86b69e6'
var deployContainerName = 'deploymentpackage'

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'stcsfunc${suffix}'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storage
  name: 'default'
}

resource deployContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: deployContainerName
}

// Plano Flex Consumption (FC1): serverless, scale-to-zero, tier gerenciado mais barato.
// Usa uma quota distinta do Consumption clássico (Y1), que a Free Trial bloqueia (Microsoft.Web=0).
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'plan-conexao-notifications'
  location: location
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  kind: 'functionapp'
  properties: { reserved: true }
}

resource func 'Microsoft.Web/sites@2023-12-01' = {
  name: 'func-conexao-notifications-${suffix}'
  location: location
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deployContainerName}'
          authentication: {
            type: 'StorageAccountConnectionString'
            storageAccountConnectionStringName: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 512
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '8.0'
      }
    }
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
      ]
    }
  }
  dependsOn: [ deployContainer ]
}

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource funcKvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, func.id, secretsUser)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsUser)
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output functionAppName string = func.name
output storageAccountName string = storage.name
