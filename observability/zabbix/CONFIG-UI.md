# Zabbix — configuração fina na UI (Conexão Solidária)

Os manifestos (`zabbix-server.yaml`, `zabbix-agent-daemonset.yaml`) sobem o **server + web + postgres + agent (DaemonSet)**. A coleta de host (CPU/mem/disco dos nós) já funciona via o agent. Os passos abaixo são a configuração que fecha o RT4 (disponibilidade + scrape de `/metrics` + alertas).

> ⚡ **Atalho automatizado (recomendado):** em vez de clicar tudo na UI, rode **`pwsh ./configure-zabbix.ps1`** (com o `port-forward svc/zabbix-web 8888:80` ativo). Ele cria, via **API do Zabbix**, o grupo `Conexao Solidaria` + 3 hosts (`svc-users/payments/donations`), cada um com **web scenario** (`/health`+`/ready` → 200), **item HTTP `app.metrics`** (scrape `/metrics`) e **trigger de indisponibilidade** (High). É **idempotente** — como o Postgres do Zabbix é `emptyDir`, **rode de novo após cada `az aks stop/start`** para reconstruir tudo em segundos. Os passos manuais abaixo continuam válidos como referência do que é criado.

## 0. Acessar a UI
```bash
kubectl -n observability port-forward svc/zabbix-web 8888:80
```
- Abra `http://localhost:8888` → login inicial **Admin / zabbix** → **troque a senha** (Users → Admin).
- Os endereços internos dos serviços (para os itens/cenários abaixo):
  `http://hackatonfiap-users.conexao-solidaria.svc.cluster.local:8080`, `...payments...:8080`, `...donations...:8080`
  (rotas: `/health`, `/ready`, `/metrics`).

## 1. Hosts dos nós (Zabbix Agent, RNF27)
- **Data collection → Hosts**: os nós do AKS aparecem (agent modo ativo, hostname = nome do nó). Se não, cadastre 1 host por nó com o mesmo nome.
- Em cada host: **Templates → Link** `Linux by Zabbix agent` (CPU, memória, disco, filesystem). Opcional: template de Kubernetes.

## 2. Disponibilidade / uptime (Web scenarios, RNF09)
Crie **1 host lógico por microsserviço** (ex.: `svc-users`, `svc-payments`, `svc-donations`) ou use um host "Aplicação".
- **Data collection → Hosts → Web** → *Create web scenario*:
  - Nome: `users-health`; Update interval: `30s`.
  - Steps: `GET http://hackatonfiap-users.conexao-solidaria.svc.cluster.local:8080/health` → **Required status codes: 200**; adicione um 2º step para `/ready`.
  - Repita para payments e donations.
- Isso alimenta o SLA/uptime (meta 99,5%).

## 3. Métricas da aplicação (`/metrics`) via HTTP agent + preprocessing Prometheus (RNF25/26)
Em cada host de serviço, **Items → Create item**:
- Type: **HTTP agent**; Key: `app.metrics`; URL: `http://hackatonfiap-<svc>.conexao-solidaria.svc.cluster.local:8080/metrics`; Type of information: Text; Update interval: `30s`.
- Crie **itens dependentes** (Master item = `app.metrics`) para as métricas de negócio, com **Preprocessing → Prometheus pattern**:
  - `http_server_request_duration_seconds_count` (requests) → padrão Prometheus `http_server_request_duration_seconds_count`.
  - `donations_approved_total`, `payments_approved_total`, `payments_declined_total`, `amount_raised_total`.
  - (nomes exatos em `DonationMetrics.cs` / métricas OTel dos serviços.)

## 4. Triggers / alertas (RNF30)
Em **Data collection → Hosts → Triggers → Create trigger**:
- **Indisponibilidade**: `last(/svc-users/web.test.fail[users-health]) <> 0` (severidade High).
- **CPU alta (nó)**: `avg(/<no>/system.cpu.util,5m) > 85` (Warning/High).
- **Memória alta (nó)**: `(last(/<no>/vm.memory.size[pused])) > 85` (Warning).
- **Erros 5xx** (se expor no /metrics): trigger sobre a taxa do item dependente de 5xx.
- Ações/notificação: **Alerts → Actions** (e-mail/webhook) se quiser escalonamento.

## Observações
- Postgres do Zabbix usa `emptyDir` (efêmero): ao **pausar/reiniciar** o cluster, os dados do Zabbix (hosts/itens/triggers configurados aqui) **se perdem** — reconfigurar. Para persistir, trocar por um PVC (StorageClass do AKS) no `zabbix-server.yaml`.
- Sem Ingress: acesso só por `port-forward`.
- Grafana/Prometheus (kube-prometheus-stack) cobrem métricas de **aplicação/negócio**; o Zabbix cobre **infra/host + disponibilidade + alertas** (divisão do ADR-002).
