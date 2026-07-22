# IaC — Recursos Azure do Conexão Solidária (Bicep)

Provisiona todos os recursos no RG único **`hackaton-fiap`** (Brazil South), sob teto de **US$200** (Free Trial).

## Pré-requisitos

- `az` CLI logado: `az login` (e `az account set -s <subscription>` se houver mais de uma).
- Bicep: `az bicep install`.
- PowerShell 7 (`pwsh`) para o `deploy.ps1`, ou bash + `jq` + `openssl` para o `deploy.sh`.
- **Verificar quota ANTES do AKS:** `az vm list-usage --location brazilsouth -o table` — 1× B2ms precisa de ~2 vCPU livres. Se faltar, use `eastus2`.

## Ordem e flags

Baseline barato primeiro (sem AKS/APIM):

```bash
cd iac
pwsh ./deploy.ps1 -BudgetEmail gabriel.verissimo@esolution.com.br
```

O `deploy.ps1` deixa `deployAks=false` (baseline barato). O **AKS é efêmero** — crie e destrua só o cluster, sem tocar no baseline:

```bash
make aks-up      # cria SÓ o AKS (~5-10 min), referenciando ACR + identidade já existentes
make deploy-users && make deploy-payments && make deploy-donations   # (re)aplica os apps
# ... grava a demo ...
make aks-down    # destrói cluster + LB + IP + discos  ->  custo do AKS = US$0
```

`iac/aks.bicep` é um template standalone (RG-scoped) que reaproveita `modules/aks.bicep`.
Não use `useSpot=true` (B2ms não é elegível a Spot → o deploy falha). APIM é opcional
(`deployApim=true` no `main.parameters.json`) e não é necessário para a demo.

## Custo

- Baseline ~US$16–20/mês. AKS 1× B2ms + LB **24/7 ~US$120/mês** (a evitar; `systemNodeCount=1` por padrão).
- **Fora das demos, derrube o AKS:** `make aks-down` (remove cluster + LB + IP + discos → AKS = US$0). Recriar: `make aks-up`.
- Alternativa rápida: `make aks-stop`/`aks-start` desaloca só os nós; **LB + IP + discos continuam** cobrando ~US$1/dia.
- SQL em tier **Basic** (~US$5/mês por banco, fixo — sem risco do serverless não pausar); Cosmos/Function/APIM são free/consumption.

## Secrets

- O `deploy.ps1` grava os 8 secrets no Key Vault (nomes que o Helm já referencia) e imprime os secrets do GitHub.
- **AZURE_CREDENTIALS (service principal):** se a Free Trial permitir, `az ad sp create-for-rbac --name conexao-cicd --role contributor --scopes /subscriptions/<id>/resourceGroups/hackaton-fiap --sdk-auth`. **Se bloqueado:** use o fallback — `ACR_USERNAME/ACR_PASSWORD` (já impressos) para o push, e `KUBE_CONFIG` (de `az aks get-credentials ... --file -`) para o deploy no AKS.

## Teardown

`make iac-destroy` apaga o RG inteiro ao fim do hackathon.

## Verificação

- Por módulo: `az bicep build --file modules/<x>.bicep`.
- Integração (sem custo, requer login): `make iac-whatif`.

## Notas de segurança e operação

- **Secrets na linha de comando:** o `deploy.ps1`/`deploy.sh` passam segredos via argumentos `az` (`--parameters`, `--value`); aceito por serem executados **localmente pelo operador** (máquina single-user). Não rodar esses scripts em runners de CI compartilhados.
- **`iac/github-secrets.local`:** o deploy grava o bloco de secrets do GitHub (inclui `ACR_PASSWORD`) nesse arquivo (gitignored, permissão restrita). **Apague após colar nos GitHub secrets.**
- **Key Vault soft-delete:** o KV tem soft-delete (7 dias) sem purge-protection; se um deploy anterior deixou um KV soft-deleted com o mesmo nome, rode `az keyvault purge --name <kv>` antes de re-deployar.
- **Pré-deploy:** rode `az vm list-usage --location brazilsouth -o table` e confirme ~4 vCPU livres antes de `deployAks=true`.
