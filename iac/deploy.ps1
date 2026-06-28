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

function New-StrongPassword([int]$Length = 20) {
  # Explicit alphabet — excludes chars that break SQL connection strings or shells:
  # no ; ' " ` = space
  $upper   = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.ToCharArray()
  $lower   = 'abcdefghijklmnopqrstuvwxyz'.ToCharArray()
  $digits  = '0123456789'.ToCharArray()
  $symbols = '!@#$%^*-_'.ToCharArray()
  $all     = $upper + $lower + $digits + $symbols

  # Guarantee at least one of each class
  $pwd = [System.Collections.Generic.List[char]]::new()
  $pwd.Add($upper[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($upper.Length)])
  $pwd.Add($lower[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($lower.Length)])
  $pwd.Add($digits[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($digits.Length)])
  $pwd.Add($symbols[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($symbols.Length)])

  for ($i = 4; $i -lt $Length; $i++) {
    $pwd.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)])
  }

  # Fisher-Yates shuffle using CSPRNG
  for ($i = $pwd.Count - 1; $i -gt 0; $i--) {
    $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
    $tmp = $pwd[$i]; $pwd[$i] = $pwd[$j]; $pwd[$j] = $tmp
  }

  return -join $pwd
}

# 1) Pré-requisitos e quota
Write-Host '== Verificando login e quota ==' -ForegroundColor Cyan
az account show -o none
if ($LASTEXITCODE -ne 0) { throw 'az account show failed — execute az login first' }
az vm list-usage --location $Location --query "[?contains(localName,'Standard B') || contains(localName,'Total Regional')].{name:localName,used:currentValue,limit:limit}" -o table

# 2) Segredos gerados localmente (nunca commitados) — usando CSPRNG
$b = [byte[]]::new(48); [System.Security.Cryptography.RandomNumberGenerator]::Fill($b); $jwtKey = [Convert]::ToBase64String($b)
$ownerPwd = New-StrongPassword -Length 24
$sqlPwd   = New-StrongPassword -Length 24
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

# 7) Bloco de secrets do GitHub — sensíveis gravados em arquivo local, NÃO no stdout
$acrName = ($deploy.acrLoginServer.value -split '\.')[0]
$acrPwd = Invoke-AzChecked { az acr credential show -n $acrName --query "passwords[0].value" -o tsv } 'az acr credential show'

$secretsFile = Join-Path $PSScriptRoot 'github-secrets.local'
$secretsContent = @"
# GitHub Actions secrets — NÃO commite este arquivo; apague após colar nos GitHub secrets.
RESOURCE_GROUP=$RgName
ACR_NAME=$acrName
ACR_USERNAME=$acrName
ACR_PASSWORD=$acrPwd
AKS_CLUSTER_NAME=aks-conexao-solidaria
FUNCTION_APP_NAME=$funcApp
"@
Set-Content -Path $secretsFile -Value $secretsContent -Encoding UTF8
# Restringir ACL ao usuário corrente (remove herança, concede somente o usuário atual)
icacls $secretsFile /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null

Write-Host "`n== GitHub Actions secrets ==" -ForegroundColor Yellow
Write-Host "RESOURCE_GROUP=$RgName"
Write-Host "ACR_NAME=$acrName"
Write-Host "ACR_USERNAME=$acrName"
Write-Host "AKS_CLUSTER_NAME=aks-conexao-solidaria"
Write-Host "FUNCTION_APP_NAME=$funcApp"
Write-Host "`nSecrets sensíveis (ACR_PASSWORD) gravados em iac/github-secrets.local — NÃO commite; apague após colar nos GitHub secrets." -ForegroundColor Red
Write-Host "Para AZURE_CREDENTIALS/KUBE_CONFIG veja o README (fallback Free Trial)."
