@description('Região')
param location string
@description('Usa Spot (apenas dev)')
param useSpot bool = false
@description('Nome do ACR (p/ AcrPull)')
param acrName string
@description('Resource ID da MI de Key Vault')
param kvIdentityId string
@description('Nome da MI de Key Vault (p/ federated credentials)')
param kvIdentityName string
@description('Workspace do Log Analytics (não usado p/ Container Insights — reservado)')
param logAnalyticsWorkspaceId string = ''
@description('Nós do system pool — 1 basta para a demo (metade do custo); aumente para HA')
param systemNodeCount int = 1
@description('SKU da VM dos nós. B-series NÃO é permitida nesta Free Trial; Standard_D2s_v6 (2 vCPU/8GB) é permitida e tem quota.')
param nodeVmSize string = 'Standard_D2s_v6'

var serviceAccounts = [
  'hackatonfiap-users'
  'hackatonfiap-payments'
  'hackatonfiap-donations'
]
var acrPull = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

var systemPool = {
  name: 'system'
  mode: 'System'
  count: systemNodeCount
  vmSize: nodeVmSize
  osType: 'Linux'
  osDiskSizeGB: 32
  type: 'VirtualMachineScaleSets'
}

var spotPool = {
  name: 'spot'
  mode: 'User'
  count: 1
  vmSize: nodeVmSize
  osType: 'Linux'
  osDiskSizeGB: 32
  type: 'VirtualMachineScaleSets'
  scaleSetPriority: 'Spot'
  scaleSetEvictionPolicy: 'Delete'
  spotMaxPrice: json('-1')
}

resource aks 'Microsoft.ContainerService/managedClusters@2024-05-01' = {
  name: 'aks-conexao-solidaria'
  location: location
  sku: { name: 'Base', tier: 'Free' }
  identity: { type: 'SystemAssigned' }
  properties: {
    dnsPrefix: 'conexao'
    enableRBAC: true
    oidcIssuerProfile: { enabled: true }
    securityProfile: {
      workloadIdentity: { enabled: true }
    }
    addonProfiles: {
      azureKeyvaultSecretsProvider: {
        enabled: true
        config: { enableSecretRotation: 'true' }
      }
    }
    agentPoolProfiles: useSpot ? concat([systemPool], [spotPool]) : [systemPool]
    networkProfile: {
      networkPlugin: 'kubenet'
      loadBalancerSku: 'standard'
    }
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: acrName
}

resource acrPullAssign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, aks.id, acrPull)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPull)
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

resource mi 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: kvIdentityName
}

// @batchSize(1): federated credentials da MESMA identidade NÃO podem ser criadas em
// paralelo (o serviço serializa; em paralelo só uma "vence" e as demais falham com
// AADSTS700213 no runtime). Força criação sequencial.
@batchSize(1)
resource fic 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = [for sa in serviceAccounts: {
  parent: mi
  name: 'fic-${sa}'
  properties: {
    issuer: aks.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:conexao-solidaria:sa-${sa}'
    audiences: [ 'api://AzureADTokenExchange' ]
  }
}]

output clusterName string = aks.name
output oidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL
output kubeletObjectId string = aks.properties.identityProfile.kubeletidentity.objectId
