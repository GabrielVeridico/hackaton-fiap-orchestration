#requires -Version 7
param(
  [string]$Location = 'brazilsouth',
  [string]$RgName = 'hackaton-fiap',
  [string]$SqlAdminLogin = 'csadmin',
  [Parameter(Mandatory)][string]$BudgetEmail,
  [string]$DevIp = ''
)
$ErrorActionPreference = 'Stop'

function Invoke-AzChecked {
  param([scriptblock]$Action, [string]$What)
  $r = & $Action
  if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" }
  return $r
}

# 1) Pré-requisitos e quota
Write-Host '== Verificando login e quota ==' -ForegroundColor Cyan
az account show -o none
if ($LASTEXITCODE -ne 0) { throw 'az account show failed — execute az login first' }
az vm list-usage --location $Location --query "[?contains(localName,'Standard B') || contains(localName,'Total Regional')].{name:localName,used:currentValue,limit:limit}" -o table

# 2) Segredos gerados localmente (nunca commitados)
$jwtKey = [Convert]::ToBase64String([byte[]](1..48 | ForEach-Object { Get-Random -Max 256 }))
$ownerPwd = ([Convert]::ToBase64String([byte[]](1..18 | ForEach-Object { Get-Random -Max 256 })) -replace '[^A-Za-z0-9]','') + 'Aa1!'
$sqlPwd = ([Convert]::ToBase64String([byte[]](1..18 | ForEach-Object { Get-Random -Max 256 })) -replace '[^A-Za-z0-9]','') + 'Aa1!'
$deployerObjectId = Invoke-AzChecked { az ad signed-in-user show --query id -o tsv } 'az ad signed-in-user show'

# 3) Deploy do Bicep (subscription-scope)
Write-Host '== az deployment sub create ==' -ForegroundColor Cyan
$deployJson = az deployment sub create `
  --location $Location `
  --template-file main.bicep `
  --parameters main.parameters.json `
  --parameters sqlAdminPassword=$sqlPwd deployerObjectId=$deployerObjectId devIpAddress=$DevIp budgetContactEmail=$BudgetEmail `
  --query properties.outputs -o json
if ($LASTEXITCODE -ne 0) { throw 'az deployment sub create failed' }
$deploy = $deployJson | ConvertFrom-Json
if ($null -eq $deploy) { throw 'az deployment sub create returned null output — check Bicep template' }

$kv      = $deploy.keyVaultName.value
$sbNs    = $deploy.serviceBusNamespace.value
$sbRule  = $deploy.serviceBusAuthRule.value
$sqlFqdn = $deploy.sqlServerFqdn.value
$cosmos  = $deploy.cosmosAccountName.value
$funcApp = $deploy.functionAppName.value

# 4) Coletar connection strings das fontes
Write-Host '== Coletando connection strings ==' -ForegroundColor Cyan
$sbConn    = Invoke-AzChecked { az servicebus namespace authorization-rule keys list -g $RgName --namespace-name $sbNs --name $sbRule --query primaryConnectionString -o tsv } 'az servicebus keys list'
$cosmosConn = Invoke-AzChecked { az cosmosdb keys list -g $RgName -n $cosmos --type connection-strings --query "connectionStrings[0].connectionString" -o tsv } 'az cosmosdb keys list'
$appiConn  = Invoke-AzChecked { az monitor app-insights component show -g $RgName -a appi-conexao-solidaria --query connectionString -o tsv } 'az monitor app-insights component show'
function SqlConn($db) { "Server=tcp:$sqlFqdn,1433;Database=$db;User ID=$SqlAdminLogin;Password=$sqlPwd;Encrypt=true;TrustServerCertificate=false;" }

# 5) Gravar os 8 secrets no Key Vault (nomes que o Helm espera)
Write-Host '== Gravando secrets no Key Vault ==' -ForegroundColor Cyan
$secrets = @{
  'Users-ConnectionString'        = (SqlConn 'HackatonFiapUsersDb')
  'Payments-ConnectionString'     = (SqlConn 'HackatonFiapPaymentsDb')
  'Donations-ConnectionString'    = (SqlConn 'HackatonFiapDonationsDb')
  'ServiceBus-ConnectionString'   = $sbConn
  'Cosmos-ConnectionString'       = $cosmosConn
  'Jwt-Key'                       = $jwtKey
  'Owner-Password'               = $ownerPwd
  'AppInsights-ConnectionString' = $appiConn
}
foreach ($name in $secrets.Keys) {
  az keyvault secret set --vault-name $kv --name $name --value $secrets[$name] -o none
  if ($LASTEXITCODE -ne 0) { throw "az keyvault secret set failed for $name" }
  Write-Host "  ok: $name"
}

# 6) App settings de connection da Function
Write-Host '== App settings da Function ==' -ForegroundColor Cyan
az functionapp config appsettings set -g $RgName -n $funcApp --settings `
  "SERVICEBUS_CONNECTION=$sbConn" "APPLICATIONINSIGHTS_CONNECTION_STRING=$appiConn" -o none
if ($LASTEXITCODE -ne 0) { throw 'az functionapp config appsettings set failed' }

# 7) Bloco de secrets do GitHub (colar nos repos)
Write-Host "`n== GitHub Actions secrets (colar nos repos) ==" -ForegroundColor Yellow
$acrName = ($deploy.acrLoginServer.value -split '\.')[0]
$acrPwd = Invoke-AzChecked { az acr credential show -n $acrName --query "passwords[0].value" -o tsv } 'az acr credential show'
Write-Host "RESOURCE_GROUP=$RgName"
Write-Host "ACR_NAME=$acrName"
Write-Host "ACR_USERNAME=$acrName"
Write-Host "ACR_PASSWORD=$acrPwd"
Write-Host "AKS_CLUSTER_NAME=aks-conexao-solidaria"
Write-Host "FUNCTION_APP_NAME=$funcApp"
Write-Host "`nGuarde com seguranca. Para AZURE_CREDENTIALS/KUBE_CONFIG veja o README (fallback Free Trial)."
