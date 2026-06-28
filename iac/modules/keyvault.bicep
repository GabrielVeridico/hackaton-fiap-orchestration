@description('Região')
param location string
@description('Sufixo único')
param suffix string
@description('principalId da MI do AKS (Key Vault Secrets User)')
param aksIdentityPrincipalId string
@description('objectId de quem roda o deploy (Key Vault Secrets Officer)')
param deployerObjectId string

var secretsUser = '4633458b-17de-408a-b874-0445c86b69e6'
var secretsOfficer = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-cs-${suffix}'
  location: location
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

resource aksRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, aksIdentityPrincipalId, secretsUser)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsUser)
    principalId: aksIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource deployerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, deployerObjectId, secretsOfficer)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsOfficer)
    principalId: deployerObjectId
    principalType: 'User'
  }
}

output name string = kv.name
output uri string = kv.properties.vaultUri
