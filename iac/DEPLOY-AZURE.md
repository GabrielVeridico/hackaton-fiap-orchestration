# Subir o Conexão Solidária na Azure — passo a passo (runbook)

Sequência **validada end-to-end** numa conta **Free Trial** (RG único `hackaton-fiap`, Brazil South, teto US$200). Cobre baseline + Function + AKS + observabilidade + apps (Helm) + APIM + **front (Container Apps)** + validação + pausa. Comandos a partir de `hackaton-fiap-orchestration/`.

> **Gotchas da Free Trial já resolvidos aqui** (não são bugs do projeto): série B bloqueada p/ AKS → **D2s_v6**; Functions Consumption Y1 bloqueado → **Flex Consumption**; **ACR Tasks bloqueado** → build local + push; federated credentials criadas em sequência (`@batchSize(1)`); teto **4 vCPU** → AKS de 1–2 nós.

## 0. Pré-requisitos
- `az` CLI, **Docker Desktop rodando**, `helm` v4, `kubectl`, e (opcional) `func` (Azure Functions Core Tools) — todos no PATH.
- Login (conta pessoal exige MFA no tenant): `az login --tenant c6632fc8-319e-46c2-8b12-0b5e7061e83a` → `az account set -s e437ac69-e3e2-4986-ae02-f2b3e397b08e`.
- `az config set extension.use_dynamic_install=yes_without_prompt` (o `deploy.ps1` já faz; evita prompt do App Insights).

## 1. Baseline + Function (Flex)
```bash
cd iac
pwsh ./deploy.ps1 -BudgetEmail gabrielvmarra1@hotmail.com
```
Cria RG + SQL (3 bancos **Basic**) + Service Bus (tópicos `donation-requested`/`payment-result` + subs `payments`/`donations`/`notifications`) + Cosmos (free tier) + ACR + Key Vault (**8 secrets**, inclui `Owner-Password` e `Jwt-Key` compartilhada) + Log Analytics + App Insights + **Function Flex Consumption**. Idempotente (rode 2× se algum passo pós-deploy falhar).
Confira: `az resource list -g hackaton-fiap -o table` (15 recursos). O sufixo é determinístico (ex.: `7xafxr`); use-o abaixo.

## 2. Imagens no ACR (build local — ACR Tasks é bloqueado na Free Trial)
```bash
ACR=acrconexaosolidaria<suffix>; REG=$ACR.azurecr.io
az acr login -n $ACR
docker build -t $REG/hackatonfiap-users:latest     -f ../hackaton-fiap-users/src/HackatonFiap.Users.API/Dockerfile ../hackaton-fiap-users     && docker push $REG/hackatonfiap-users:latest
docker build -t $REG/hackatonfiap-payments:latest  -f ../hackaton-fiap-payments/Dockerfile  ../hackaton-fiap-payments  && docker push $REG/hackatonfiap-payments:latest
docker build -t $REG/hackatonfiap-donations:latest -f ../hackaton-fiap-donations/Dockerfile ../hackaton-fiap-donations && docker push $REG/hackatonfiap-donations:latest
```

## 3. Código da NotificationFunction (opcional — hop de notificação)
```bash
cd ../hackaton-fiap-notifications/src/HackatonFiap.Notifications
func azure functionapp publish func-conexao-notifications-<suffix>
cd ../../../hackaton-fiap-orchestration
```

## 4. AKS (2 nós D2s_v6)
```bash
az deployment group create -g hackaton-fiap --name aks-standalone \
  --template-file iac/aks.bicep --parameters systemNodeCount=2
az aks get-credentials -g hackaton-fiap -n aks-conexao-solidaria --overwrite-existing
kubectl get nodes    # 2x Ready; as 3 FICs sao criadas em sequencia (@batchSize(1))
```

## 5. Observabilidade — ANTES dos apps (o CRD ServiceMonitor precisa existir)
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update
kubectl create namespace observability
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n observability -f observability/prometheus/values.yaml --wait --timeout 8m   # release DEVE ser 'kube-prometheus-stack'
kubectl apply -f observability/grafana/dashboard-configmap.yaml                  # dashboard (sidecar do Grafana importa)
# Zabbix:
kubectl -n observability create secret generic zabbix-db --from-literal=POSTGRES_USER=zabbix --from-literal=POSTGRES_PASSWORD=<senha> --from-literal=POSTGRES_DB=zabbix
kubectl apply -f observability/zabbix/zabbix-server.yaml -f observability/zabbix/zabbix-agent-daemonset.yaml
# config fina do Zabbix (web scenarios / /metrics / triggers): observability/zabbix/CONFIG-UI.md
```

## 6. IPs públicos estáticos + apps (Helm, com LoadBalancer p/ o APIM)
```bash
MC=$(az aks show -g hackaton-fiap -n aks-conexao-solidaria --query nodeResourceGroup -o tsv)
az network public-ip create -g $MC -n pip-users      --sku Standard --allocation-method Static -l brazilsouth
az network public-ip create -g $MC -n pip-donations  --sku Standard --allocation-method Static -l brazilsouth
kubectl apply -f k8s/namespace.yaml
pwsh ./iac/deploy-apps.ps1 -ServiceMonitor true      # users/donations viram LoadBalancer (bindam os IPs); helm com KV CSI + Workload Identity
kubectl get pods -n conexao-solidaria   # 3x 1/1 Running
kubectl get svc  -n conexao-solidaria   # users/donations com EXTERNAL-IP = os IPs reservados
```

## 7. APIM (roteando para os serviços via os IPs públicos)
```bash
UIP=$(az network public-ip show -g $MC -n pip-users     --query ipAddress -o tsv)
DIP=$(az network public-ip show -g $MC -n pip-donations --query ipAddress -o tsv)
az deployment group create -g hackaton-fiap --name apim-standalone --template-file iac/modules/apim.bicep \
  --parameters location=brazilsouth suffix=<suffix> publisherEmail=gabrielvmarra1@hotmail.com \
  usersBackendUrl="http://$UIP:8080/api" donationsBackendUrl="http://$DIP:8080/api"   # Consumption; ~5-15 min
```
Gateway: `https://apim-conexao-solidaria-<suffix>.azure-api.net`. Rotas `/api/auth|users` → UserAPI; `/api/campaigns|donations|transparency` → DonationAPI (a policy roteia por `context.Request.OriginalUrl.Path`). **A PaymentAPI NÃO fica atrás do APIM** (é query admin-only, não é rota pública, e a Free Trial limita a **3 IPs públicos** por região — já usados por users, donations e o LB de egress do AKS). **NOTA:** o SKU **Consumption não suporta as policies rate-limit/rate-limit-by-key** — o gateway faz roteamento (e normalização), sem rate-limit.

## 7b. Front-end (Azure Container Apps)
```bash
cd iac
pwsh ./deploy-frontend.ps1        # build+push da imagem do front + deploy; deriva a URL do APIM do RG
```
Cria o Container Apps Environment `cae-conexao-solidaria` + a app `ca-conexao-front` (Next.js 16 + BFF), ingress HTTPS externo na porta **3000**, com `UPSTREAM_MODE=apim` e `APIM_BASE_URL=https://apim-conexao-solidaria-<suffix>.azure-api.net` (**raiz, sem `/api`** — o `/api` já vem do path que o BFF emite). Requer **Docker Desktop** (ACR Tasks é bloqueado na Free Trial → build local). O script imprime a **URL pública** do front (`https://<fqdn>`). Scale-to-zero por default (`minReplicas=0`, ~US$0 ocioso); para a demo ao vivo, `pwsh ./deploy-frontend.ps1 -MinReplicas 1` evita cold start. Derrubar: `make front-down`.

> O front **sobe mesmo com o AKS pausado**, mas login/campanhas/transparência só respondem com **APIM + AKS no ar** (`az aks start`). O browser fala só com o BFF (mesma origem → sem CORS).

## 8. Validação E2E
```bash
# payments nao fica atras do APIM -> valida-lo direto via port-forward
kubectl port-forward -n conexao-solidaria svc/hackatonfiap-payments 5002:8080 &
pwsh ./iac/test-all.ps1 -ApiBase https://apim-conexao-solidaria-<suffix>.azure-api.net -PaymentsBase http://localhost:5002
```
Cobre (28 checagens) auth, RBAC, campanhas+regras, doação aprovada/recusada (saga com polling), transparência e payments — a maioria via APIM. Observabilidade: `kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80` (dashboard "Conexão Solidária"); `svc/zabbix-web 8888:80`.

## 9. Custo e ciclo de vida
| Estado | Custo |
|---|---|
| Baseline (sempre) | ~US$1/dia (SQL Basic + Service Bus + ACR + IPs) |
| AKS ligado | + ~US$0,27/h (2 nós) |
| **Pausar entre demos** | `az aks stop -g hackaton-fiap -n aks-conexao-solidaria` → ~US$2/dia |
| Religar | `az aks start ...` (pods e obs voltam; config persiste; Zabbix Postgres emptyDir zera) |
| Derrubar só AKS | `az aks delete ...` (zera nós+LB+discos; IPs estáticos e baseline ficam) |
| Derrubar tudo | `az group delete -n hackaton-fiap --yes` |

> Atalhos equivalentes no `Makefile`: `aks-up`/`aks-down`/`aks-start`/`aks-stop`/`iac-destroy` (requer `make`; no Windows, use os comandos `az` acima diretamente).
