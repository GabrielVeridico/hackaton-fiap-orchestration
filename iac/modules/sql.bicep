@description('Região')
param location string
@description('Sufixo único')
param suffix string
@description('Login admin')
param adminLogin string
@secure()
@description('Senha admin')
param adminPassword string
@description('IP do dev (opcional)')
param devIpAddress string = ''

var databaseNames = [
  'HackatonFiapUsersDb'
  'HackatonFiapPaymentsDb'
  'HackatonFiapDonationsDb'
]

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: 'sql-conexao-solidaria-${suffix}'
  location: location
  properties: {
    administratorLogin: adminLogin
    administratorLoginPassword: adminPassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

resource allowAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}

resource allowDev 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = if (!empty(devIpAddress)) {
  parent: sqlServer
  name: 'AllowDevIp'
  properties: { startIpAddress: devIpAddress, endIpAddress: devIpAddress }
}

// Tier fixo Basic (~US$5/mês por banco): custo previsível e baixo, SEM o risco do
// serverless nunca pausar — o probe /ready consulta o SQL a cada 10s, então o banco
// nunca ficaria ocioso 60 min e cobraria o piso de compute 24/7. Basic = 5 DTU, máx.
// 2 GB, o que atende de sobra o MVP/testes (um banco por serviço — database-per-service).
resource dbs 'Microsoft.Sql/servers/databases@2023-08-01-preview' = [for db in databaseNames: {
  parent: sqlServer
  name: db
  location: location
  sku: { name: 'Basic', tier: 'Basic' }
  properties: {
    maxSizeBytes: 2147483648
  }
}]

output serverName string = sqlServer.name
output serverFqdn string = sqlServer.properties.fullyQualifiedDomainName
output databaseNames array = databaseNames
