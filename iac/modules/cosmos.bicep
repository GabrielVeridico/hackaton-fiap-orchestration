@description('Região')
param location string
@description('Sufixo único')
param suffix string

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: 'cosmos-conexao-solidaria-${suffix}'
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    enableFreeTier: true
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
  }
}

resource db 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  parent: cosmos
  name: 'HackatonFiapDonations'
  properties: {
    resource: { id: 'HackatonFiapDonations' }
    options: { throughput: 400 }
  }
}

resource container 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: db
  name: 'campaigns'
  properties: {
    resource: {
      id: 'campaigns'
      partitionKey: { paths: [ '/id' ], kind: 'Hash' }
    }
  }
}

output accountName string = cosmos.name
