# Atalhos de infra do Conexão Solidária.
# Uso: make <alvo>. Requer docker compose e helm no PATH.

COMPOSE := docker compose -f local/docker-compose.yml --env-file local/.env
CHART   := helm/conexao-service
NS      := conexao-solidaria

.PHONY: help up up-obs down logs ps lint template deploy-users deploy-payments deploy-donations namespace

help:
	@echo "Alvos:"
	@echo "  up                Sobe o ambiente local (build)"
	@echo "  up-obs            Sobe local + Prometheus/Grafana (profile observability)"
	@echo "  down              Derruba o ambiente local"
	@echo "  logs              Segue os logs da saga (payments/donations/notifications)"
	@echo "  ps                Estado dos containers"
	@echo "  lint              helm lint + docker compose config"
	@echo "  template          Renderiza o chart para os 3 serviços"
	@echo "  namespace         Aplica o namespace no cluster"
	@echo "  deploy-<svc>      helm upgrade --install do serviço (users|payments|donations)"

up:
	$(COMPOSE) up -d --build

up-obs:
	$(COMPOSE) --profile observability up -d --build

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f payments-api donations-api notifications-func

ps:
	$(COMPOSE) ps

lint:
	helm lint $(CHART) -f $(CHART)/values-users.yaml
	helm lint $(CHART) -f $(CHART)/values-payments.yaml
	helm lint $(CHART) -f $(CHART)/values-donations.yaml
	docker compose -f local/docker-compose.yml --env-file local/.env.example config >/dev/null && echo "compose OK"

template:
	helm template users $(CHART) -f $(CHART)/values-users.yaml
	helm template payments $(CHART) -f $(CHART)/values-payments.yaml
	helm template donations $(CHART) -f $(CHART)/values-donations.yaml

namespace:
	kubectl apply -f k8s/namespace.yaml

deploy-users:
	helm upgrade --install hackatonfiap-users $(CHART) -f $(CHART)/values-users.yaml -n $(NS)

deploy-payments:
	helm upgrade --install hackatonfiap-payments $(CHART) -f $(CHART)/values-payments.yaml -n $(NS)

deploy-donations:
	helm upgrade --install hackatonfiap-donations $(CHART) -f $(CHART)/values-donations.yaml -n $(NS)

# ---- Azure IaC (Bicep) ----
RG       := hackaton-fiap
LOCATION := brazilsouth
IAC      := iac

.PHONY: iac-whatif iac-deploy iac-destroy aks-up aks-down aks-start aks-stop front-up front-down
AKS := aks-conexao-solidaria
CAE := cae-conexao-solidaria
CA  := ca-conexao-front

iac-whatif:
	cd $(IAC) && az deployment sub what-if --location $(LOCATION) \
	  --template-file main.bicep --parameters main.parameters.json \
	  --parameters sqlAdminPassword=$$SQL_PWD deployerObjectId=$$(az ad signed-in-user show --query id -o tsv) budgetContactEmail=$$BUDGET_EMAIL

iac-deploy:
	cd $(IAC) && pwsh ./deploy.ps1 -BudgetEmail $$BUDGET_EMAIL

iac-destroy:
	az group delete --name $(RG) --yes --no-wait

# AKS efêmero: criar/destruir só o cluster (baseline permanece de pé).
aks-up:
	cd $(IAC) && az deployment group create --resource-group $(RG) \
	  --name aks-standalone --template-file aks.bicep

# Destrói o cluster + Load Balancer + IP + discos (zera 100% do custo do AKS).
aks-down:
	az aks delete --resource-group $(RG) --name $(AKS) --yes

# Pausa/religa (mais rápido que up/down, mas mantém LB+IP+discos cobrando ~US$1/dia).
aks-start:
	az aks start --resource-group $(RG) --name $(AKS)

aks-stop:
	az aks stop --resource-group $(RG) --name $(AKS)

# Front-end no Azure Container Apps: build+push da imagem + deploy (deriva a URL do APIM).
front-up:
	cd $(IAC) && pwsh ./deploy-frontend.ps1

# Derruba a Container App + o Environment (o baseline permanece de pé).
front-down:
	az containerapp delete --resource-group $(RG) --name $(CA) --yes
	az containerapp env delete --resource-group $(RG) --name $(CAE) --yes
