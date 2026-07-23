# Acesso aos painéis de observabilidade (Grafana · Prometheus · Zabbix)

Os três painéis rodam **dentro do AKS**, no namespace **`observability`**, todos como **ClusterIP** (sem ingress público — a Free Trial limita a 3 IPs públicos, já usados por users/donations/egress). Portanto o acesso é **sempre por `kubectl port-forward`** a partir de uma máquina com credenciais do cluster.

> ⚠️ **O AKS precisa estar LIGADO.** Entre as demos ele fica pausado (`az aks stop`). Se estiver `Stopped`, nada de observabilidade responde — comece pelo passo 1.

> ⚠️ **Zabbix perde a configuração ao pausar/religar.** O Postgres do Zabbix usa `emptyDir`, então templates/web scenarios/triggers configurados pela UI **somem** a cada `az aks stop`→`start` e precisam ser refeitos (ver [CONFIG-UI.md](zabbix/CONFIG-UI.md)). Grafana/Prometheus persistem (config no etcd).

---

## 1. Ligar o AKS e pegar credenciais (só se estiver pausado)
```bash
az login --tenant c6632fc8-319e-46c2-8b12-0b5e7061e83a          # se necessário
az account set -s e437ac69-e3e2-4986-ae02-f2b3e397b08e
az aks start -g hackaton-fiap -n aks-conexao-solidaria           # ~3-5 min  (ou: make aks-start)
az aks get-credentials -g hackaton-fiap -n aks-conexao-solidaria --overwrite-existing
kubectl get pods -n observability                                # aguarde Grafana/Prometheus/Zabbix Running
```

## 2. Grafana
```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80
```
- **URL:** http://localhost:3000
- **Usuário:** `admin`
- **Senha:** não é fixa no repo (RNF21) — leia do Secret do cluster:
  ```bash
  kubectl -n observability get secret kube-prometheus-stack-grafana \
    -o jsonpath="{.data.admin-password}" | base64 -d ; echo
  ```
  (O default do chart kube-prometheus-stack é `prom-operator`, mas a fonte da verdade é o Secret acima.)
- **Dashboard:** *"Conexão Solidária — Aplicação"* (tags `conexao-solidaria`, `aplicacao`) — Requests/s por serviço, latência p95, respostas 5xx/s. Provisionado pela ConfigMap `conexao-apps-dashboard` (importada pelo sidecar do Grafana). Menu **Dashboards → Browse**.

## 3. Prometheus
```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```
- **URL:** http://localhost:9090 (sem login).
- Útil para conferir os **targets UP** dos 3 serviços em *Status → Targets* e testar métricas de negócio (`donations_approved_total`, `payments_approved_total`, `amount_raised_total`, `http_server_request_duration_seconds_count`).

## 4. Zabbix
```bash
kubectl -n observability port-forward svc/zabbix-web 8888:80
```
- **URL:** http://localhost:8888
- **Login inicial:** `Admin` / `zabbix` (A maiúsculo) — **troque a senha no primeiro acesso** (Users → Admin).
- **Senha do Postgres** (secret `zabbix-db`, se precisar): 
  ```bash
  kubectl -n observability get secret zabbix-db -o jsonpath="{.data.POSTGRES_PASSWORD}" | base64 -d ; echo
  ```
- **Configuração** (hosts, web scenarios de `/health`/`/ready`, itens de `/metrics`, triggers): rode **`pwsh observability/zabbix/configure-zabbix.ps1`** (com o port-forward ativo) — cria tudo via API, idempotente. **Refazer após cada religada do AKS** (Postgres em `emptyDir`). Detalhes/manual em [CONFIG-UI.md](zabbix/CONFIG-UI.md).

---

## Resumo

| Painel | port-forward | URL local | Credenciais |
|---|---|---|---|
| **Grafana** | `svc/kube-prometheus-stack-grafana 3000:80` | http://localhost:3000 | `admin` / (ler do Secret `kube-prometheus-stack-grafana`) |
| **Prometheus** | `svc/kube-prometheus-stack-prometheus 9090:9090` | http://localhost:9090 | — |
| **Zabbix** | `svc/zabbix-web 8888:80` | http://localhost:8888 | `Admin` / `zabbix` (trocar no 1º acesso) |

> A **NotificationFunction** roda **fora do AKS** (Azure Function) → a telemetria dela vai para o **Application Insights** (`appi-conexao-solidaria`) no portal da Azure, **não** para o Grafana/Zabbix in-cluster.

Ver também: [`iac/DEPLOY-AZURE.md`](../iac/DEPLOY-AZURE.md) (subida completa), [`observability/zabbix/README.md`](zabbix/README.md), [`observability/zabbix/CONFIG-UI.md`](zabbix/CONFIG-UI.md).
