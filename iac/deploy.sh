#!/usr/bin/env bash
set -euo pipefail
LOCATION="${LOCATION:-brazilsouth}"
RG="${RG:-hackaton-fiap}"
SQL_LOGIN="${SQL_LOGIN:-csadmin}"
BUDGET_EMAIL="${BUDGET_EMAIL:?defina BUDGET_EMAIL}"
DEV_IP="${DEV_IP:-}"

echo "== login & quota =="
az account show -o none
az vm list-usage --location "$LOCATION" -o table | grep -Ei 'Standard B|Total Regional' || true

JWT_KEY="$(openssl rand -base64 48)"
OWNER_PWD="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9')Aa1!"
SQL_PWD="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9')Aa1!"
DEPLOYER_OID="$(az ad signed-in-user show --query id -o tsv)"

echo "== deployment =="
OUT="$(az deployment sub create --location "$LOCATION" --template-file main.bicep \
  --parameters main.parameters.json \
  --parameters sqlAdminPassword="$SQL_PWD" deployerObjectId="$DEPLOYER_OID" devIpAddress="$DEV_IP" budgetContactEmail="$BUDGET_EMAIL" \
  --query properties.outputs -o json)"

KV=$(echo "$OUT" | jq -r .keyVaultName.value)
SB_NS=$(echo "$OUT" | jq -r .serviceBusNamespace.value)
SB_RULE=$(echo "$OUT" | jq -r .serviceBusAuthRule.value)
SQL_FQDN=$(echo "$OUT" | jq -r .sqlServerFqdn.value)
COSMOS=$(echo "$OUT" | jq -r .cosmosAccountName.value)
FUNC=$(echo "$OUT" | jq -r .functionAppName.value)

SB_CONN=$(az servicebus namespace authorization-rule keys list -g "$RG" --namespace-name "$SB_NS" --name "$SB_RULE" --query primaryConnectionString -o tsv)
COSMOS_CONN=$(az cosmosdb keys list -g "$RG" -n "$COSMOS" --type connection-strings --query "connectionStrings[0].connectionString" -o tsv)
APPI_CONN=$(az monitor app-insights component show -g "$RG" -a appi-conexao-solidaria --query connectionString -o tsv)
sqlconn() { echo "Server=tcp:$SQL_FQDN,1433;Database=$1;User ID=$SQL_LOGIN;Password=$SQL_PWD;Encrypt=true;TrustServerCertificate=false;"; }

declare -A SECRETS=(
  [Users-ConnectionString]="$(sqlconn HackatonFiapUsersDb)"
  [Payments-ConnectionString]="$(sqlconn HackatonFiapPaymentsDb)"
  [Donations-ConnectionString]="$(sqlconn HackatonFiapDonationsDb)"
  [ServiceBus-ConnectionString]="$SB_CONN"
  [Cosmos-ConnectionString]="$COSMOS_CONN"
  [Jwt-Key]="$JWT_KEY"
  [Owner-Password]="$OWNER_PWD"
  [AppInsights-ConnectionString]="$APPI_CONN"
)
for n in "${!SECRETS[@]}"; do az keyvault secret set --vault-name "$KV" --name "$n" --value "${SECRETS[$n]}" -o none && echo "  ok: $n"; done

az functionapp config appsettings set -g "$RG" -n "$FUNC" --settings \
  "SERVICEBUS_CONNECTION=$SB_CONN" "APPLICATIONINSIGHTS_CONNECTION_STRING=$APPI_CONN" -o none

ACR_NAME=$(echo "$OUT" | jq -r .acrLoginServer.value | cut -d. -f1)
ACR_PWD=$(az acr credential show -n "$ACR_NAME" --query "passwords[0].value" -o tsv)
echo "== GitHub secrets =="
echo "RESOURCE_GROUP=$RG"; echo "ACR_NAME=$ACR_NAME"; echo "ACR_USERNAME=$ACR_NAME"; echo "ACR_PASSWORD=$ACR_PWD"; echo "AKS_CLUSTER_NAME=aks-conexao-solidaria"; echo "FUNCTION_APP_NAME=$FUNC"
