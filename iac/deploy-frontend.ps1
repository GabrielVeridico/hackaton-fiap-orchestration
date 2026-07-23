#requires -Version 7
# Deploy STANDALONE do front-end (Next.js 16 + BFF) no Azure Container Apps.
# 1) build+push da imagem do front no ACR (ACR Tasks e bloqueado na Free Trial -> build local);
# 2) deploy do frontend.bicep (Container Apps Environment + Container App).
# Pre-requisitos: baseline provisionado (deploy.ps1 -> ACR + Log Analytics existem),
# Docker Desktop rodando, e `az login` feito. O front so responde de fato com APIM + AKS no ar.
param(
  [string]$RgName = 'hackaton-fiap',
  [string]$Location = 'brazilsouth',
  [string]$ImageTag = 'latest',
  # 0 = scale-to-zero (~US$0 ocioso). Use 1 na demo ao vivo p/ evitar cold start.
  [int]$MinReplicas = 0,
  # Raiz do gateway APIM, SEM /api. Vazio = deriva do APIM existente no RG.
  [string]$ApimBaseUrl = ''
)
$ErrorActionPreference = 'Stop'

function Invoke-AzChecked {
  param([scriptblock]$Action, [string]$What)
  $r = & $Action
  if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" }
  return $r
}

Write-Host '== Login e providers ==' -ForegroundColor Cyan
az account show -o none
if ($LASTEXITCODE -ne 0) { throw 'az account show failed - execute az login primeiro' }
az config set extension.use_dynamic_install=yes_without_prompt -o none
# Container Apps exige o provider Microsoft.App (subscription nova pode vir NotRegistered).
az provider register -n Microsoft.App -o none
az provider register -n Microsoft.OperationalInsights -o none

Write-Host '== Coletando ACR do RG ==' -ForegroundColor Cyan
$acrName   = Invoke-AzChecked { az acr list -g $RgName --query "[0].name"        -o tsv } 'az acr list'
$acrServer = Invoke-AzChecked { az acr list -g $RgName --query "[0].loginServer" -o tsv } 'az acr list'
if (-not $acrName) { throw "ACR nao encontrado no RG $RgName (rode deploy.ps1 primeiro)" }
Write-Host "  ACR=$acrServer"

# APIM base URL (RAIZ do gateway, SEM /api). Deriva do RG se nao informado.
if (-not $ApimBaseUrl) {
  $apimName = Invoke-AzChecked { az resource list -g $RgName --resource-type Microsoft.ApiManagement/service --query "[0].name" -o tsv } 'az resource list (apim)'
  if (-not $apimName) { throw 'APIM nao encontrado no RG. Suba o APIM (deployApim=true) ou passe -ApimBaseUrl.' }
  $ApimBaseUrl = "https://$apimName.azure-api.net"
}
Write-Host "  APIM_BASE_URL=$ApimBaseUrl"

Write-Host '== Build + push da imagem do front ==' -ForegroundColor Cyan
Invoke-AzChecked { az acr login -n $acrName } 'az acr login'
$img      = "$acrServer/hackatonfiap-front:$ImageTag"
$frontCtx = Join-Path $PSScriptRoot '..' '..' 'hackaton-fiap-front'
if (-not (Test-Path (Join-Path $frontCtx 'Dockerfile'))) { throw "Dockerfile do front nao encontrado em $frontCtx" }
docker build -t $img -f (Join-Path $frontCtx 'Dockerfile') $frontCtx
if ($LASTEXITCODE -ne 0) { throw 'docker build falhou (Docker Desktop esta rodando?)' }
docker push $img
if ($LASTEXITCODE -ne 0) { throw 'docker push falhou' }

Write-Host '== az deployment group create (frontend.bicep) ==' -ForegroundColor Cyan
$outJson = az deployment group create -g $RgName --name frontend-standalone `
  --template-file (Join-Path $PSScriptRoot 'frontend.bicep') `
  --parameters apimBaseUrl=$ApimBaseUrl imageTag=$ImageTag minReplicas=$MinReplicas `
  --query properties.outputs -o json
if ($LASTEXITCODE -ne 0) { throw 'az deployment group create failed' }
$out = $outJson | ConvertFrom-Json
if ($null -eq $out) { throw 'deployment retornou output nulo — confira o frontend.bicep' }

Write-Host "`nOK - front no ar: $($out.frontUrl.value)" -ForegroundColor Green
Write-Host "Container App: $($out.containerAppName.value)  |  Environment: $($out.environmentName.value)"
Write-Host "Lembrete: o fluxo logado exige APIM + AKS no ar (az aks start se estiver pausado)." -ForegroundColor Yellow
