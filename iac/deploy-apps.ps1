#requires -Version 7
# Deploy dos 3 microsserviços no AKS via Helm, preenchendo os valores dinâmicos
# (ACR, Key Vault, clientId da managed identity, tenant) a partir dos recursos do RG.
# Pré-requisitos: baseline provisionado (deploy.ps1), AKS no ar (aks.bicep) e
# `az aks get-credentials` já feito. Requer helm no PATH.
param(
  [string]$RgName = 'hackaton-fiap',
  [string]$Namespace = 'conexao-solidaria',
  [string]$ImageTag = 'latest',
  # 'true' só quando o kube-prometheus-stack (CRD ServiceMonitor) estiver instalado no cluster.
  [string]$ServiceMonitor = 'false'
)
$ErrorActionPreference = 'Stop'

# helm é instalado pelo winget no PATH do usuário; recarrega para achá-lo nesta sessão.
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')

$chart = Join-Path $PSScriptRoot '..' 'helm' 'conexao-service'

Write-Host '== Coletando dados do ambiente ==' -ForegroundColor Cyan
$acr      = az acr list      -g $RgName --query "[0].loginServer" -o tsv
$kv       = az keyvault list -g $RgName --query "[0].name"        -o tsv
$clientId = az identity show -g $RgName -n id-conexao-aks-kv --query clientId -o tsv
$tenant   = az account show --query tenantId -o tsv
if (-not $acr -or -not $kv -or -not $clientId -or -not $tenant) {
  throw "Falha ao coletar ACR/KV/identity/tenant do RG $RgName"
}
Write-Host "  ACR=$acr  KV=$kv  clientId=$clientId"

foreach ($svc in 'users','payments','donations') {
  Write-Host "== helm upgrade --install hackatonfiap-$svc ==" -ForegroundColor Cyan
  helm upgrade --install "hackatonfiap-$svc" $chart `
    -f (Join-Path $chart "values-$svc.yaml") `
    -n $Namespace --create-namespace `
    --set image.registry=$acr `
    --set image.tag=$ImageTag `
    --set serviceAccount.workloadIdentity=true `
    --set keyVault.enabled=true `
    --set keyVault.name=$kv `
    --set keyVault.clientID=$clientId `
    --set keyVault.tenantId=$tenant `
    --set metrics.serviceMonitor.enabled=$ServiceMonitor
  if ($LASTEXITCODE -ne 0) { throw "helm falhou para $svc" }
}
Write-Host "`nOK - 3 releases aplicados. Confira: kubectl get pods -n $Namespace" -ForegroundColor Green
