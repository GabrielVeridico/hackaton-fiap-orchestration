# Manifests Kubernetes — Conexão Solidária

Conjunto **canônico e plain-YAML** dos 3 microsserviços para rodar em um cluster
Kubernetes local (Minikube, Kind ou Docker Desktop K8s). Todos no **mesmo namespace
`conexao-solidaria`**, cada serviço com **Deployment + Service + ConfigMap** (RT3).

> Para AKS em produção (com Workload Identity + Azure Key Vault via CSI), use o
> **Helm chart** em `../helm/conexao-service` — ele é o caminho oficial de deploy no
> cluster gerenciado. Estes manifests são a entrega em YAML puro e a via de demo local.

## Estrutura

```
k8s/
├── namespace.yaml            # namespace conexao-solidaria
├── users/                    # UserAPI      (configmap + deployment + service + secret.example)
├── payments/                 # PaymentAPI   (idem)
└── donations/                # DonationAPI  (idem)
```

Cada serviço expõe a porta `8080` (`/health`, `/ready`, `/metrics`) e traz as
annotations `prometheus.io/scrape` para coleta de métricas.

## Como aplicar (cluster local)

```bash
# 1) Namespace
kubectl apply -f namespace.yaml

# 2) Build das imagens (nos repos irmãos) e carga no cluster
#    (Kind: kind load docker-image <img>; Minikube: minikube image load <img>)
docker build -t hackatonfiap-users:latest      ../../hackaton-fiap-users -f ../../hackaton-fiap-users/src/HackatonFiap.Users.API/Dockerfile
docker build -t hackatonfiap-payments:latest   ../../hackaton-fiap-payments
docker build -t hackatonfiap-donations:latest  ../../hackaton-fiap-donations

# 3) Secrets — copie os exemplos, preencha e aplique (NÃO commite valores reais)
cp users/secret.example.yaml     users/secret.yaml       # edite os CHANGE_ME
cp payments/secret.example.yaml  payments/secret.yaml
cp donations/secret.example.yaml donations/secret.yaml
kubectl apply -f users/secret.yaml -f payments/secret.yaml -f donations/secret.yaml

# 4) ConfigMaps + Deployments + Services
kubectl apply -R -f users/ -f payments/ -f donations/

# 5) Conferir os pods
kubectl get pods -n conexao-solidaria
```

> As APIs dependem de SQL Server e Azure Service Bus (a DonationAPI também de Cosmos
> em `Production`). Aponte as connection strings dos secrets para instâncias acessíveis
> pelo cluster, ou suba o stack completo via `../local/docker-compose.yml`. Para demo
> local sem Cosmos, use `ASPNETCORE_ENVIRONMENT=Development` no configmap da DonationAPI
> (read store in-memory).

## Observabilidade

Prometheus + Grafana no cluster: instale o `kube-prometheus-stack` (ver
`../observability/`). Os manifests do Helm chart criam `ServiceMonitor` por serviço
(`metrics.serviceMonitor.enabled=true` nos `values-*.yaml`). O dashboard da aplicação
está em `../observability/grafana/dashboards/conexao-apps.json`.
