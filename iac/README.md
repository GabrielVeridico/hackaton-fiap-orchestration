# IaC — Recursos Azure do Conexão Solidária (Bicep)

Provisiona todos os recursos no RG único **`hackaton-fiap`** (Brazil South), sob teto de **US$200** (Free Trial).

## Pré-requisitos

- `az` CLI logado: `az login` (e `az account set -s <subscription>` se houver mais de uma).
- Bicep: `az bicep install`.
- PowerShell 7 (`pwsh`) para o `deploy.ps1`, ou bash + `jq` + `openssl` para o `deploy.sh`.
- **Verificar quota ANTES do AKS:** `az vm list-usage --location brazilsouth -o table` — precisa de ~4 vCPU livres p/ 2× B2ms. Se faltar, use `eastus2` ou `deployAks=false`.

## Ordem e flags

Baseline barato primeiro (sem AKS/APIM):

```bash
cd iac
pwsh ./deploy.ps1 -BudgetEmail gabriel.verissimo@esolution.com.br
```

Ligar AKS/APIM quando for usar — edite `main.parameters.json` (`deployAks=true`, `deployApim=true`) e rode de novo. Para dev barato, `useSpot=true`.

## Custo

- Baseline ~US$16–20/mês. AKS 2× B2ms + LB **24/7 ~US$140–180/mês** (a evitar).
- **Desligue o AKS fora das demos:** `make aks-stop` (religar: `make aks-start`). Zera nós + Load Balancer.
- SQL serverless auto-pausa; Cosmos/Function/APIM são free/consumption.

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
