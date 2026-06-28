@description('Região')
param location string
@description('Sufixo único')
param suffix string

resource sb 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: 'sb-conexao-solidaria-${suffix}'
  location: location
  sku: { name: 'Standard', tier: 'Standard' }
}

resource appRule 'Microsoft.ServiceBus/namespaces/authorizationRules@2022-10-01-preview' = {
  parent: sb
  name: 'app'
  properties: { rights: [ 'Send', 'Listen' ] }
}

resource tDonationRequested 'Microsoft.ServiceBus/namespaces/topics@2022-10-01-preview' = {
  parent: sb
  name: 'donation-requested'
  properties: { defaultMessageTimeToLive: 'P14D' }
}

resource sPayments 'Microsoft.ServiceBus/namespaces/topics/subscriptions@2022-10-01-preview' = {
  parent: tDonationRequested
  name: 'payments'
  properties: {
    deadLetteringOnMessageExpiration: true
    maxDeliveryCount: 3
  }
}

resource tPaymentResult 'Microsoft.ServiceBus/namespaces/topics@2022-10-01-preview' = {
  parent: sb
  name: 'payment-result'
  properties: { defaultMessageTimeToLive: 'P14D' }
}

resource sDonations 'Microsoft.ServiceBus/namespaces/topics/subscriptions@2022-10-01-preview' = {
  parent: tPaymentResult
  name: 'donations'
  properties: {
    deadLetteringOnMessageExpiration: true
    maxDeliveryCount: 3
  }
}

resource sNotifications 'Microsoft.ServiceBus/namespaces/topics/subscriptions@2022-10-01-preview' = {
  parent: tPaymentResult
  name: 'notifications'
  properties: {
    deadLetteringOnMessageExpiration: true
    maxDeliveryCount: 3
  }
}

output namespaceName string = sb.name
output authRuleName string = appRule.name
