@description('Região')
param location string

resource mi 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-conexao-aks-kv'
  location: location
}

output id string = mi.id
output principalId string = mi.properties.principalId
output clientId string = mi.properties.clientId
output name string = mi.name
