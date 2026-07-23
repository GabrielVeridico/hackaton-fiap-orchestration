@description('Região')
param location string
@description('Sufixo único')
param suffix string
@description('E-mail do publisher')
param publisherEmail string
@description('Nome do publisher')
param publisherName string = 'Conexao Solidaria'
@description('URL base pública da UserAPI, incluindo /api (ex.: http://<ip>:8080/api)')
param usersBackendUrl string
@description('URL base pública da DonationAPI, incluindo /api (ex.: http://<ip>:8080/api)')
param donationsBackendUrl string

resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = {
  name: 'apim-conexao-solidaria-${suffix}'
  location: location
  sku: { name: 'Consumption', capacity: 0 }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

// API única em /api. As operações wildcard capturam qualquer rota; a policy
// roteia por prefixo de path para o backend correto e aplica rate-limit.
resource api 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: 'conexao-api'
  properties: {
    displayName: 'Conexao Solidaria API'
    path: 'api'
    protocols: [ 'https' ]
    subscriptionRequired: false
  }
}

var verbs = [ 'GET', 'POST', 'PUT', 'PATCH', 'DELETE' ]
resource ops 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = [for v in verbs: {
  parent: api
  name: 'all-${toLower(v)}'
  properties: {
    displayName: '${v} (wildcard)'
    method: v
    urlTemplate: '/*'
    templateParameters: []
    responses: []
  }
}]

// Roteamento por prefixo de path. base-url inclui /api, então /api/auth/login é
// preservado ao chegar no backend. NOTA: o SKU Consumption NÃO suporta as policies
// rate-limit/rate-limit-by-key (limitação do tier) — por isso não há rate-limit aqui.
resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-05-01-preview' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'xml'
    value: '<policies><inbound><base /><choose><when condition="@(context.Request.OriginalUrl.Path.StartsWith(&quot;/api/auth&quot;) || context.Request.OriginalUrl.Path.StartsWith(&quot;/api/users&quot;))"><set-backend-service base-url="${usersBackendUrl}" /></when><otherwise><set-backend-service base-url="${donationsBackendUrl}" /></otherwise></choose></inbound><backend><forward-request /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
  dependsOn: [ ops ]
}

output apimName string = apim.name
output gatewayUrl string = apim.properties.gatewayUrl
