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

# CSPRNG — explicit alphabet (no ; ' " ` = space) to guarantee complexity & fixed length
# Generates a strong password of $1 chars from an alphabet that covers all 4 Azure SQL classes.
# Strategy: rejection sampling to avoid modulo bias, then enforce at least one char per class.
gen_password() {
  local length="${1:-24}"
  local upper='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
  local lower='abcdefghijklmnopqrstuvwxyz'
  local digits='0123456789'
  local symbols='!@#$%^*-_'
  local alphabet="${upper}${lower}${digits}${symbols}"
  local alen=${#alphabet}

  # Rejection sampling: map bytes to alphabet without bias
  # limit = 256 - (256 % alen) ensures uniform distribution
  local limit=$(( 256 - (256 % alen) ))

  # Helper to convert hex byte string to decimal
  byte_to_dec() {
    local hex="$1"
    printf '%d\n' "0x${hex}"
  }

  # Draw (length + 32) bytes as headroom, map each to alphabet with rejection sampling, take first $length
  local raw
  raw=$(openssl rand -hex $(( (length + 32) * 2 )) | fold -w2 | while read -r h; do
    local n
    n=$(byte_to_dec "$h")
    # Rejection sampling: discard bytes >= limit
    while (( n >= limit )); do
      h=$(openssl rand -hex 1)
      n=$(byte_to_dec "$h")
    done
    idx=$(( n % alen ))
    printf '%s' "${alphabet:$idx:1}"
  done | head -c "$length")

  # Guarantee at least one char from each class — replace positions 0-3 with forced chars
  # Use rejection sampling for per-class indices as well
  local u l d s rest

  # Upper: rejection sampling over uppercase alphabet
  local limit_u=$(( 256 - (256 % ${#upper}) ))
  while true; do
    local hex_u
    hex_u=$(openssl rand -hex 1)
    local dec_u
    dec_u=$(byte_to_dec "$hex_u")
    if (( dec_u < limit_u )); then
      u="${upper:$(( dec_u % ${#upper} )):1}"
      break
    fi
  done

  # Lower: rejection sampling over lowercase alphabet
  local limit_l=$(( 256 - (256 % ${#lower}) ))
  while true; do
    local hex_l
    hex_l=$(openssl rand -hex 1)
    local dec_l
    dec_l=$(byte_to_dec "$hex_l")
    if (( dec_l < limit_l )); then
      l="${lower:$(( dec_l % ${#lower} )):1}"
      break
    fi
  done

  # Digits: rejection sampling over digits alphabet
  local limit_d=$(( 256 - (256 % ${#digits}) ))
  while true; do
    local hex_d
    hex_d=$(openssl rand -hex 1)
    local dec_d
    dec_d=$(byte_to_dec "$hex_d")
    if (( dec_d < limit_d )); then
      d="${digits:$(( dec_d % ${#digits} )):1}"
      break
    fi
  done

  # Symbols: rejection sampling over symbols alphabet
  local limit_s=$(( 256 - (256 % ${#symbols}) ))
  while true; do
    local hex_s
    hex_s=$(openssl rand -hex 1)
    local dec_s
    dec_s=$(byte_to_dec "$hex_s")
    if (( dec_s < limit_s )); then
      s="${symbols:$(( dec_s % ${#symbols} )):1}"
      break
    fi
  done

  rest="${raw:4}"
  # Concatenate guaranteed chars + remaining, then shuffle with openssl-seeded sort
  local combined="${u}${l}${d}${s}${rest}"
  # Fisher-Yates-equivalent: pair each char with a random key and sort
  local shuffled
  shuffled=$(printf '%s' "$combined" | fold -w1 | \
    while read -r c; do printf '%s %s\n' "$(openssl rand -hex 2)" "$c"; done | \
    sort | awk '{printf "%s", $2}')
  printf '%s' "$shuffled"
}

JWT_KEY="$(openssl rand -base64 48)"   # Jwt-Key permanece aleatoria (precisa de >=32 bytes)
# ATENCAO: senha FIXA e FRACA, so para AMBIENTE DE TESTE descartavel (Free Trial),
# demonstrada de PROPOSITO no video. NUNCA reutilizar em ambiente real.
# Para producao, voltar a: gen_password 24
OWNER_PWD='SenhaSuperForte!123'
SQL_PWD='SenhaSuperForte!123'
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

declare -A SECRETS
SECRETS[Users-ConnectionString]="$(sqlconn HackatonFiapUsersDb)"
SECRETS[Payments-ConnectionString]="$(sqlconn HackatonFiapPaymentsDb)"
SECRETS[Donations-ConnectionString]="$(sqlconn HackatonFiapDonationsDb)"
SECRETS[ServiceBus-ConnectionString]="$SB_CONN"
SECRETS[Cosmos-ConnectionString]="$COSMOS_CONN"
SECRETS[Jwt-Key]="$JWT_KEY"
SECRETS[Owner-Password]="$OWNER_PWD"
SECRETS[AppInsights-ConnectionString]="$APPI_CONN"

for n in "${!SECRETS[@]}"; do az keyvault secret set --vault-name "$KV" --name "$n" --value "${SECRETS[$n]}" -o none && echo "  ok: $n"; done

az functionapp config appsettings set -g "$RG" -n "$FUNC" --settings \
  "SERVICEBUS_CONNECTION=$SB_CONN" "APPLICATIONINSIGHTS_CONNECTION_STRING=$APPI_CONN" -o none

ACR_NAME=$(echo "$OUT" | jq -r .acrLoginServer.value | cut -d. -f1)
ACR_PWD=$(az acr credential show -n "$ACR_NAME" --query "passwords[0].value" -o tsv)

# Secrets sensíveis gravados em arquivo local com permissões restritas (0600)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="${SCRIPT_DIR}/github-secrets.local"
umask 077
cat > "$SECRETS_FILE" <<EOF
# GitHub Actions secrets — NÃO commite este arquivo; apague após colar nos GitHub secrets.
RESOURCE_GROUP=$RG
ACR_NAME=$ACR_NAME
ACR_USERNAME=$ACR_NAME
ACR_PASSWORD=$ACR_PWD
AKS_CLUSTER_NAME=aks-conexao-solidaria
FUNCTION_APP_NAME=$FUNC
EOF

echo "== GitHub secrets =="
echo "RESOURCE_GROUP=$RG"
echo "ACR_NAME=$ACR_NAME"
echo "ACR_USERNAME=$ACR_NAME"
echo "AKS_CLUSTER_NAME=aks-conexao-solidaria"
echo "FUNCTION_APP_NAME=$FUNC"
echo ""
echo "Secrets sensíveis (ACR_PASSWORD) gravados em iac/github-secrets.local — NÃO commite; apague após colar nos GitHub secrets."
