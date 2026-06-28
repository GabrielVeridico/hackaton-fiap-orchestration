@description('Região')
param location string
@description('Sufixo único')
param suffix string
@description('E-mail do publisher')
param publisherEmail string
@description('Nome do publisher')
param publisherName string = 'Conexao Solidaria'

resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = {
  name: 'apim-conexao-solidaria-${suffix}'
  location: location
  sku: { name: 'Consumption', capacity: 0 }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

resource globalPolicy 'Microsoft.ApiManagement/service/policies@2023-05-01-preview' = {
  parent: apim
  name: 'policy'
  properties: {
    format: 'xml'
    value: '<policies><inbound><rate-limit-by-key calls="100" renewal-period="60" counter-key="@(context.Request.IpAddress)" /></inbound><backend><forward-request /></backend><outbound /><on-error /></policies>'
  }
}

output apimName string = apim.name
