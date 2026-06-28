targetScope = 'subscription'

@description('Região de todos os recursos')
param location string = 'brazilsouth'

@description('Nome do resource group único')
param rgName string = 'hackaton-fiap'

@description('Sufixo para nomes globalmente únicos (deixe o default)')
param uniqueSuffix string = ''

@description('Provisiona o AKS (custo dominante — só quando for usar)')
param deployAks bool = false

@description('Provisiona o APIM')
param deployApim bool = false

@description('Usa node pool Spot no AKS (apenas dev)')
param useSpot bool = false

@description('E-mail para alertas de budget')
param budgetContactEmail string

@description('Primeiro dia do mês para o budget (yyyy-MM-01)')
param budgetStartDate string = utcNow('yyyy-MM-01')

@description('Login admin do SQL Server')
param sqlAdminLogin string = 'csadmin'

@secure()
@description('Senha admin do SQL Server (>=12 chars, complexa)')
param sqlAdminPassword string

@description('objectId de quem roda o deploy (preenchido pelo deploy.ps1)')
param deployerObjectId string

@description('IP do desenvolvedor para firewall do SQL (opcional)')
param devIpAddress string = ''

var suffix = empty(uniqueSuffix) ? take(uniqueString(subscription().id, rgName), 6) : uniqueSuffix

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgName
  location: location
}

module monitoring 'modules/monitoring.bicep' = {
  scope: rg
  name: 'monitoring'
  params: {
    location: location
    suffix: suffix
  }
}

module acr 'modules/acr.bicep' = {
  scope: rg
  name: 'acr'
  params: {
    location: location
    suffix: suffix
  }
}

module identity 'modules/identity.bicep' = {
  scope: rg
  name: 'identity'
  params: {
    location: location
  }
}

module keyvault 'modules/keyvault.bicep' = {
  scope: rg
  name: 'keyvault'
  params: {
    location: location
    suffix: suffix
    aksIdentityPrincipalId: identity.outputs.principalId
    deployerObjectId: deployerObjectId
  }
}

module servicebus 'modules/servicebus.bicep' = {
  scope: rg
  name: 'servicebus'
  params: {
    location: location
    suffix: suffix
  }
}

output rgName string = rg.name
output tenantId string = subscription().tenantId
output acrLoginServer string = acr.outputs.loginServer
output aksKvIdentityClientId string = identity.outputs.clientId
output aksKvIdentityName string = identity.outputs.name
output keyVaultName string = keyvault.outputs.name
output serviceBusNamespace string = servicebus.outputs.namespaceName
output serviceBusAuthRule string = servicebus.outputs.authRuleName
