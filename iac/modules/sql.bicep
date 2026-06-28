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

resource dbs 'Microsoft.Sql/servers/databases@2023-08-01-preview' = [for db in databaseNames: {
  parent: sqlServer
  name: db
  location: location
  sku: { name: 'GP_S_Gen5_1', tier: 'GeneralPurpose', family: 'Gen5', capacity: 1 }
  properties: {
    autoPauseDelay: 60
    minCapacity: json('0.5')
    maxSizeBytes: 2147483648
    zoneRedundant: false
  }
}]

output serverName string = sqlServer.name
output serverFqdn string = sqlServer.properties.fullyQualifiedDomainName
output databaseNames array = databaseNames
