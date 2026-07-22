// -----------------------------------------------------------------------------
// Deploy STANDALONE do AKS (recurso efêmero).
//
// Cria SOMENTE o cluster AKS, referenciando os recursos PERSISTENTES já existentes
// (ACR + managed identity) por nome. Permite derrubar e recriar o AKS à vontade,
// SEM tocar em SQL / Service Bus / Cosmos / Key Vault / Function / monitoring.
//
//   Criar:    make aks-up     (az deployment group create ... aks.bicep)  ~5-10 min
//   Destruir: make aks-down   (az aks delete — remove cluster + LB + IP + discos = US$0)
//
// Pré-requisito: o baseline já deve ter sido provisionado uma vez pelo main.bicep
// (deploy.ps1) — que cria o ACR e a identidade referenciados aqui.
// Após 'aks-up', reaplique os apps: make deploy-users / deploy-payments / deploy-donations.
// -----------------------------------------------------------------------------
targetScope = 'resourceGroup'

@description('Região dos recursos')
param location string = 'brazilsouth'

@description('Usa node pool Spot (dev). ATENÇÃO: B2ms NÃO é elegível a Spot — manter false.')
param useSpot bool = false

@description('Nós do system pool (1 basta para a demo; aumente para HA)')
param systemNodeCount int = 1

@description('Nome do ACR existente (default = mesmo sufixo determinístico do main.bicep)')
param acrName string = 'acrconexaosolidaria${take(uniqueString(subscription().id, resourceGroup().name), 6)}'

@description('Nome da managed identity existente (criada por modules/identity.bicep)')
param identityName string = 'id-conexao-aks-kv'

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: acrName
}

resource mi 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

module aks 'modules/aks.bicep' = {
  name: 'aks'
  params: {
    location: location
    useSpot: useSpot
    systemNodeCount: systemNodeCount
    acrName: acr.name
    kvIdentityId: mi.id
    kvIdentityName: mi.name
  }
}

output clusterName string = aks.outputs.clusterName
output oidcIssuerUrl string = aks.outputs.oidcIssuerUrl
