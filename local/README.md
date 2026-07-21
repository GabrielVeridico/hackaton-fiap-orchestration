# Ambiente local — Conexão Solidária

Sobe **toda a plataforma** localmente via `docker-compose`, com a saga de doação rodando
**fim-a-fim** usando emuladores Azure.

## O que sobe

| Container | Imagem | Porta host | Papel |
|---|---|---|---|
| `cs-sqlserver` | mssql/server:2022 | `1433` | bancos `HackatonFiapUsersDb` / `PaymentsDb` / `DonationsDb` (1 por serviço) + backing do Service Bus emulator |
| `cs-servicebus` | azure-messaging/servicebus-emulator | `5672` | tópicos `donation-requested` e `payment-result` (ver `servicebus/config.json`) |
| `cs-azurite` | azure-storage/azurite | `10000-10002` | storage da NotificationFunction (`AzureWebJobsStorage`) |
| `cs-users-api` | build `../../hackaton-fiap-users` | `5001` | UserAPI (auth/JWT) |
| `cs-payments-api` | build `../../hackaton-fiap-payments` | `5002` | PaymentAPI (gateway mock) |
| `cs-donations-api` | build `../../hackaton-fiap-donations` | `5003` | DonationAPI (campanhas/doações/consumer) |
| `cs-notifications-func` | build `../../hackaton-fiap-notifications` | — | NotificationFunction (notifica o doador, canal mock/log) |
| `cs-front` | build `../../hackaton-fiap-front` | `3000` | Front-end Next.js + BFF (fala com as 3 APIs pelos hostnames internos) |
| `cs-cosmos` *(profile `cosmos`)* | cosmosdb/linux/azure-cosmos-emulator:vnext-preview | `8081` | read store opcional (ver nota abaixo) |
| `cs-prometheus` / `cs-grafana` *(profile `observability`)* | prom/prometheus, grafana | `9090` / `3001` | métricas locais (Grafana em `3001` p/ não colidir com o `front`) |

> Os builds usam os repositórios irmãos no workspace (`../../hackaton-fiap-*`). Clone-os ao lado
> deste repo antes de subir.

## Pré-requisitos

- Docker Desktop (com `docker compose` v2).
- Repos `hackaton-fiap-users`, `-payments`, `-donations`, `-notifications` clonados ao lado deste.
- ~6 GB de RAM livres (SQL Server + Service Bus emulator + 4 imagens .NET).

## Subir

```bash
cp .env.example .env          # ajuste senhas se quiser
docker compose up -d --build  # builda as imagens e sobe tudo
docker compose ps             # confere o estado
docker compose logs -f donations-api
```

Derrubar: `docker compose down` (com volumes: `docker compose down -v`).

## Smoke test da saga (fim-a-fim)

Swagger de cada API (somente em Development): `http://localhost:5001/swagger`, `:5002`, `:5003`.

1. **Registrar um doador** — `POST http://localhost:5001/api/auth/register` (não use o documento
   `52998224725`, reservado ao Owner).
2. **Login** — `POST http://localhost:5001/api/auth/login` → guarde o `accessToken`.
3. **Criar campanha** — autentique como **GestorONG/Owner** e `POST http://localhost:5003/api/campaigns`.
   (Owner: e-mail `owner@conexaosolidaria.org`, senha = `OWNER_PASSWORD` do `.env`.)
4. **Doar** — `POST http://localhost:5003/api/donations` (Bearer do doador) → responde `202 Accepted`.
   - Valor com centavos **`,99`** é **recusado** de propósito pelo gateway mock (RN06.11).
5. **Observar a saga**:
   ```bash
   docker compose logs -f payments-api notifications-func donations-api
   ```
   - `donations-api` publica `donation-requested`;
   - `payments-api` consome, processa o mock e publica `payment-result`;
   - `donations-api` consolida o `ValorArrecadado` (idempotente);
   - `notifications-func` loga a notificação ao doador (aprovado/recusado).
6. **Painel de transparência** (anônimo) — `GET http://localhost:5003/api/transparency/campaigns`.

Health/observabilidade por serviço: `/health` (liveness), `/ready` (readiness), `/metrics` (Prometheus).

## Observabilidade local (opcional)

```bash
docker compose --profile observability up -d
```
- Prometheus: `http://localhost:9090` (já com scrape dos 3 `/metrics`).
- Grafana: `http://localhost:3001` (anônimo habilitado; admin/`admin`). Datasource Prometheus **e** o
  dashboard **"Conexão Solidária — Aplicação"** já vêm provisionados (pasta "Conexão Solidária"):
  requests/s, latência p95 e 5xx por serviço — com dados reais assim que houver tráfego nas APIs.
- O Grafana usa a porta host **`3001`** (o `front` ocupa a `3000`), então `make up-obs` sobe os dois sem conflito.

## Troubleshooting

- **Service Bus emulator não sobe / EULA:** o emulador exige `ACCEPT_EULA=Y` (já no compose) e um
  backing SQL saudável. Ele aguarda o healthcheck do `sqlserver`. Veja `docker compose logs servicebus-emulator`.
  Se houver conflito com o backing compartilhado, suba um SQL dedicado para o emulador.
- **SQL Server reinicia em loop:** a senha em `SA_PASSWORD` precisa atender à política (>=8 chars, com
  maiúscula, minúscula e número).
- **APIs sobem antes do banco:** elas fazem `Database.Migrate()` no start com retry (`EnableRetryOnFailure`);
  o `depends_on: service_healthy` garante o SQL pronto. Se uma API falhar, `docker compose restart <svc>`.
- **NotificationFunction não conecta no storage:** o `AzureWebJobsStorage` aponta para o Azurite por
  **hostname** (`azurite`), não `UseDevelopmentStorage=true` (que resolveria 127.0.0.1 e não cruza containers).
- **Cosmos emulator (profile `cosmos`):** por padrão a DonationAPI usa o **read store in-memory**, então a
  saga roda sem o Cosmos. O build atual da DonationAPI cria `new CosmosClient(connStr)` **sem** bypass do
  certificado self-signed do emulador — logo, apontar para `cs-cosmos` exige um ajuste no serviço
  (`CosmosClientOptions` com `ConnectionMode.Gateway` + `ServerCertificateCustomValidationCallback`).
  Enquanto esse ajuste não existe, mantenha o profile `cosmos` desligado. Detalhe registrado como
  follow-up no design (`docs/superpowers/specs/2026-06-18-orchestration-infra-design.md`).
