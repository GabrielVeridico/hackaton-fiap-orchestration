@description('Região')
param location string
@description('Sufixo único (não usado em nomes, reservado p/ consistência)')
param suffix string = ''

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-conexao-solidaria'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-conexao-solidaria'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
  }
}

output workspaceId string = law.id
output appInsightsName string = appi.name
output appInsightsId string = appi.id
