targetScope = 'subscription'

@description('E-mail para alertas')
param contactEmail string
@description('Primeiro dia do mês (yyyy-MM-01)')
param startDate string
@description('Teto do budget em USD')
param amount int = 200

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: 'budget-conexao-solidaria'
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
    }
    notifications: {
      Actual_50: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 50
        thresholdType: 'Actual'
        contactEmails: [ contactEmail ]
      }
      Actual_80: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: [ contactEmail ]
      }
      Forecasted_100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Forecasted'
        contactEmails: [ contactEmail ]
      }
    }
  }
}
