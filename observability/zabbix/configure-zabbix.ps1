#requires -Version 7
# Configura o Zabbix (Conexao Solidaria) via API JSON-RPC — IDEMPOTENTE (re-executavel).
# Fecha o RT4: disponibilidade (web scenarios /health+/ready), scrape de /metrics e alertas.
# Como o Postgres do Zabbix e emptyDir, a config some a cada aks stop/start — rode este
# script novamente apos religar (pre-req: port-forward svc/zabbix-web 8888:80 ativo).
#
#   kubectl -n observability port-forward svc/zabbix-web 8888:80
#   pwsh ./configure-zabbix.ps1
param(
  [string]$ZbxUrl = 'http://localhost:8888',
  [string]$User = 'Admin',
  [string]$Pass = 'zabbix'
)
$ErrorActionPreference = 'Stop'
$api = "$ZbxUrl/api_jsonrpc.php"
$script:rid = 0
function Zbx($method, $params, $auth = $null) {
  $script:rid++
  $body = @{ jsonrpc = '2.0'; method = $method; params = $params; id = $script:rid }
  if ($auth) { $body['auth'] = $auth }
  $json = $body | ConvertTo-Json -Depth 12
  $r = Invoke-RestMethod -Uri $api -Method Post -ContentType 'application/json-rpc' -Body $json
  if ($r.PSObject.Properties.Name -contains 'error') { throw "$method -> $($r.error.message): $($r.error.data)" }
  return $r.result
}

Write-Host '== login ==' -ForegroundColor Cyan
$token = Zbx 'user.login' @{ username = $User; password = $Pass }
Write-Host "  ok"

# Host group (get-or-create)
$grpName = 'Conexao Solidaria'
$grp = Zbx 'hostgroup.get' @{ filter = @{ name = @($grpName) } } $token
$groupId = if ($grp.Count -ge 1) { $grp[0].groupid } else { (Zbx 'hostgroup.create' @{ name = $grpName } $token).groupids[0] }
Write-Host "== host group '$grpName' (id=$groupId) =="

$services = 'users', 'payments', 'donations'
foreach ($svc in $services) {
  $hostName = "svc-$svc"
  $fqdn = "http://hackatonfiap-$svc.conexao-solidaria.svc.cluster.local:8080"
  Write-Host "== $hostName ($fqdn) ==" -ForegroundColor Cyan

  # Host get-or-(delete+)create para idempotencia (delete leva junto web/items/triggers)
  $ex = Zbx 'host.get' @{ filter = @{ host = @($hostName) } } $token
  if ($ex.Count -ge 1) { Zbx 'host.delete' @($ex[0].hostid) $token | Out-Null; Write-Host "  (host existente removido p/ recriar)" }
  $hostId = (Zbx 'host.create' @{ host = $hostName; name = $hostName; groups = @(@{ groupid = $groupId }); status = 0 } $token).hostids[0]
  Write-Host "  host id=$hostId"

  # Web scenario: disponibilidade /health + /ready (RNF09)
  Zbx 'httptest.create' @{
    name   = "$svc-health"
    hostid = $hostId
    delay  = '30s'
    steps  = @(
      @{ name = 'health'; url = "$fqdn/health"; status_codes = '200'; no = 1; required = '' },
      @{ name = 'ready'; url = "$fqdn/ready"; status_codes = '200'; no = 2; required = '' }
    )
  } $token | Out-Null
  Write-Host "  web scenario '$svc-health' (GET /health + /ready -> 200)"

  # Item HTTP agent: scrape de /metrics (RNF25) — master p/ futuros itens dependentes Prometheus
  Zbx 'item.create' @{
    name = 'App metrics (/metrics)'; key_ = 'app.metrics'; hostid = $hostId
    type = 19; value_type = 4; url = "$fqdn/metrics"; delay = '30s'
  } $token | Out-Null
  Write-Host "  item HTTP agent 'app.metrics' (scrape /metrics)"

  # Trigger de indisponibilidade (RNF30)
  Zbx 'trigger.create' @{
    description = "{HOST.NAME}: servico indisponivel (health)"
    expression  = "last(/$hostName/web.test.fail[$svc-health])<>0"
    priority    = 4
  } $token | Out-Null
  Write-Host "  trigger 'indisponivel' (High)"
}

Write-Host "`nOK - Zabbix configurado: $($services.Count) hosts (web scenario /health+/ready, item /metrics, trigger de indisponibilidade)." -ForegroundColor Green
Write-Host "Veja em: Monitoring -> Hosts / Latest data / Web, e Data collection -> Hosts."
Zbx 'user.logout' @{} $token | Out-Null
