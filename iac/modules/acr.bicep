@description('Região')
param location string
@description('Sufixo único')
param suffix string

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: 'acrconexaosolidaria${suffix}'
  location: location
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: true
  }
}

output id string = acr.id
output loginServer string = acr.properties.loginServer
output name string = acr.name
