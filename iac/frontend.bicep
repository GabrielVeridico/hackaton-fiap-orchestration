// -----------------------------------------------------------------------------
// Deploy STANDALONE do front-end (Azure Container Apps).
//
// Cria um Container Apps Environment + a Container App do front (Next.js 16 + BFF),
// referenciando recursos PERSISTENTES já existentes por nome (ACR + Log Analytics).
// Permite subir/derrubar o front sem tocar no resto — igual ao aks.bicep.
//
//   Criar:    az deployment group create -g hackaton-fiap --name frontend-standalone \
//               --template-file frontend.bicep \
//               --parameters apimBaseUrl=https://apim-conexao-solidaria-<suffix>.azure-api.net
//             (ou, mais simples, pwsh ./deploy-frontend.ps1 — faz build/push + deploy)
//   Destruir: az containerapp delete -g hackaton-fiap -n ca-conexao-front --yes
//             az containerapp env delete -g hackaton-fiap -n cae-conexao-solidaria --yes
//
// Pré-requisito: baseline provisionado (ACR + Log Analytics já existem) e a imagem
// hackatonfiap-front:<tag> publicada no ACR (deploy-frontend.ps1 faz o build/push).
// O BFF do front só responde de fato quando APIM + AKS (backends) estão no ar.
// -----------------------------------------------------------------------------
targetScope = 'resourceGroup'

@description('Região dos recursos')
param location string = 'brazilsouth'

@description('Nome do ACR existente (default = mesmo sufixo determinístico do main.bicep)')
param acrName string = 'acrconexaosolidaria${take(uniqueString(subscription().id, resourceGroup().name), 6)}'

@description('Nome do Log Analytics workspace existente (criado por modules/monitoring.bicep)')
param logAnalyticsName string = 'log-conexao-solidaria'

@description('URL base do gateway APIM — RAIZ, SEM /api e SEM barra final. Ex.: https://apim-conexao-solidaria-7xafxr.azure-api.net (o /api já vem do path que o BFF emite).')
param apimBaseUrl string

@description('Tag da imagem do front no ACR')
param imageTag string = 'latest'

@description('Réplicas mínimas. 0 = scale-to-zero (~US$0 ocioso, com cold start no 1º acesso). Use 1 na demo ao vivo.')
@minValue(0)
@maxValue(5)
param minReplicas int = 0

var frontImageName = 'hackatonfiap-front'

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: acrName
}

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsName
}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-conexao-solidaria'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
  }
}

resource front 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-conexao-front'
  location: location
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 3000
        transport: 'auto'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      // ACR com adminUserEnabled=true → autentica o pull via usuário/senha admin
      // (evita roleAssignment/AcrPull). Coerente com o ambiente descartável de teste.
      registries: [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-pwd'
        }
      ]
      secrets: [
        {
          name: 'acr-pwd'
          value: acr.listCredentials().passwords[0].value
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'front'
          image: '${acr.properties.loginServer}/${frontImageName}:${imageTag}'
          resources: {
            cpu: json('0.5')
            memory: '1.0Gi'
          }
          // Runtime do BFF (Next 16). Sem NEXT_PUBLIC_* — nada vai para o browser.
          env: [
            {
              name: 'UPSTREAM_MODE'
              value: 'apim'
            }
            {
              name: 'APIM_BASE_URL'
              value: apimBaseUrl
            }
            {
              name: 'NODE_ENV'
              value: 'production'
            }
            {
              name: 'PORT'
              value: '3000'
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: 3
        rules: [
          {
            name: 'http'
            http: {
              metadata: {
                concurrentRequests: '50'
              }
            }
          }
        ]
      }
    }
  }
}

output frontUrl string = 'https://${front.properties.configuration.ingress.fqdn}'
output containerAppName string = front.name
output environmentName string = env.name
