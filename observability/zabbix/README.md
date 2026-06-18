# Zabbix — monitoramento de infra/host, disponibilidade e alertas

Camada **complementar** ao Prometheus/Grafana (que cobrem aplicação/negócio). O Zabbix cobre
**infra/host** (CPU, memória, pods/nós), **disponibilidade/uptime** e concentra os **alertas**
operacionais. Decisão registrada como **ADR-002**.

## Componentes (manifests)

| Arquivo | Conteúdo |
|---|---|
| `zabbix-server.yaml` | PostgreSQL (backing) + `zabbix-server-pgsql` + `zabbix-web-nginx-pgsql` (frontend) + Services, no namespace `observability` |
| `zabbix-agent-daemonset.yaml` | `zabbix-agent2` como **DaemonSet** (1 por nó) para métricas de host/nó (RNF27) |

```bash
kubectl create namespace observability   # se ainda não existir
kubectl apply -f observability/zabbix/zabbix-server.yaml
kubectl apply -f observability/zabbix/zabbix-agent-daemonset.yaml
# acesso ao frontend (porta-forward):
kubectl -n observability port-forward svc/zabbix-web 8888:80
# UI em http://localhost:8888 (login inicial: Admin / zabbix)
```

> Troque as senhas inline (`Secret zabbix-db`, login `Admin`) por valores reais antes de qualquer
> uso fora de demonstração (RNF21).

## Configuração na UI/API do Zabbix

A parte abaixo é configurada **dentro do Zabbix** (frontend ou API), não em manifests. Cobre as três
vias de coleta previstas no ADR-002:

### 1. Web scenarios — disponibilidade (RNF09)
Para cada serviço (users/payments/donations), crie um *Web scenario* com dois passos HTTP:
- `GET http://<service>.conexao-solidaria.svc.cluster.local:8080/health` → esperado **200**.
- `GET http://<service>.conexao-solidaria.svc.cluster.local:8080/ready` → esperado **200**.
Intervalo 30–60s. Esses cenários alimentam a métrica de **uptime** (meta 99,5% — RNF09).

### 2. Item HTTP — scrape do `/metrics` (RNF27)
Crie um item do tipo **HTTP agent** apontando para `:8080/metrics`, com *preprocessing* **Prometheus
pattern** para extrair as séries de interesse (ex.: contadores de request, latência). Permite reaproveitar
no Zabbix as mesmas métricas Prometheus expostas pelas APIs.

### 3. Zabbix Agent — host/nó
O DaemonSet já reporta CPU/memória/disco de cada nó. Vincule os hosts ao template
**"Linux by Zabbix agent"** (e, se desejar, ao template de Kubernetes) para popular os itens de host.

### 4. Triggers e ações (alertas — RNF30)
Configure triggers/ações de notificação para:
- **Indisponibilidade**: web scenario de `/health` ou `/ready` falhando.
- **CPU/memória anormais**: uso de CPU do nó acima do limiar (ex.: > 85% por 5 min).
- **Consumo excessivo de serviço**: latência/erros derivados do item de `/metrics`.

> Backlog de fila/DLQ do Service Bus é melhor observado via Azure Monitor / Grafana (RNF29); o Zabbix
> concentra disponibilidade e infra.
