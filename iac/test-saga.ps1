#requires -Version 7
# Teste E2E da saga de doacao. Pre-requisito: port-forward ativo dos servicos:
#   kubectl port-forward -n conexao-solidaria svc/hackatonfiap-users 5001:8080
#   kubectl port-forward -n conexao-solidaria svc/hackatonfiap-donations 5003:8080
# Valida: login owner -> cria campanha -> registra/loga doador -> doacao aprovada
# (amountRaised sobe) -> doacao recusada (,99) nao altera. Idempotente (reusa doador).
param(
  [string]$UsersBase = 'http://localhost:5001',
  [string]$DonationsBase = 'http://localhost:5003',
  [string]$OwnerEmail = 'owner@conexaosolidaria.org',
  [string]$OwnerPassword = 'SenhaSuperForte!123',
  [double]$ApprovedAmount = 100.00,
  [double]$DeclinedAmount = 50.99
)
$ErrorActionPreference = 'Stop'
function Login($base, $email, $pwd) {
  $r = Invoke-RestMethod -Method Post -Uri "$base/api/auth/login" -ContentType 'application/json' `
    -Body (@{ email = $email; password = $pwd } | ConvertTo-Json)
  # UserAPI responde PascalCase (AccessToken)
  if ($r.AccessToken) { return $r.AccessToken } else { return $r.accessToken }
}
function Panel($id) {
  $all = Invoke-RestMethod -Method Get -Uri "$DonationsBase/api/transparency/campaigns"
  return ($all | Where-Object { $_.id -eq $id })
}

Write-Host '== 1) Login do owner ==' -ForegroundColor Cyan
$ownerTok = Login $UsersBase $OwnerEmail $OwnerPassword
Write-Host "  owner OK (token ${ownerTok:0:12}...)"

Write-Host '== 2) Criar campanha (goal alto p/ ficar Active) ==' -ForegroundColor Cyan
$camp = Invoke-RestMethod -Method Post -Uri "$DonationsBase/api/campaigns" `
  -Headers @{ Authorization = "Bearer $ownerTok" } -ContentType 'application/json' `
  -Body (@{ title='Campanha E2E'; description='teste saga'; startDate='2026-07-01T00:00:00Z'; endDate='2026-12-31T23:59:59Z'; goal=100000 } | ConvertTo-Json)
$campaignId = $camp.id
Write-Host "  campanha criada: $campaignId"

Write-Host '== 3) Registrar (ignora 409) + login do doador ==' -ForegroundColor Cyan
$donorEmail = 'doador.e2e@teste.com'; $donorPwd = 'Senha@123'
try {
  Invoke-RestMethod -Method Post -Uri "$UsersBase/api/auth/register" -ContentType 'application/json' `
    -Body (@{ personType=0; document='11144477735'; name='Doador E2E'; email=$donorEmail; password=$donorPwd } | ConvertTo-Json) | Out-Null
  Write-Host '  doador registrado'
} catch { Write-Host '  doador ja existia (409) — seguindo' }
$donorTok = Login $UsersBase $donorEmail $donorPwd

Write-Host '== 4) Painel baseline ==' -ForegroundColor Cyan
$before = (Panel $campaignId).amountRaised
Write-Host "  amountRaised antes = $before"

Write-Host "== 5) Doacao APROVADA ($ApprovedAmount) ==" -ForegroundColor Cyan
$don = Invoke-RestMethod -Method Post -Uri "$DonationsBase/api/donations" `
  -Headers @{ Authorization = "Bearer $donorTok" } -ContentType 'application/json' `
  -Body (@{ campaignId=$campaignId; amount=$ApprovedAmount; paymentMethod=0 } | ConvertTo-Json)
Write-Host "  202 -> donationId=$($don.donationId) status=$($don.status)"

Write-Host '== 6) Polling do painel (consolidacao assincrona, ate 90s) ==' -ForegroundColor Cyan
$target = [double]$before + $ApprovedAmount; $ok = $false
for ($i=1; $i -le 30; $i++) {
  Start-Sleep -Seconds 3
  $now = (Panel $campaignId).amountRaised
  Write-Host "  [$i] amountRaised = $now (alvo $target)"
  if ([double]$now -ge $target) { $ok = $true; break }
}
if ($ok) { Write-Host '  >>> SAGA APROVADA OK (valor consolidado)' -ForegroundColor Green }
else { Write-Host '  >>> FALHOU: valor nao consolidou no tempo' -ForegroundColor Red }

Write-Host "== 7) Doacao RECUSADA ($DeclinedAmount, centavos=99) ==" -ForegroundColor Cyan
$don2 = Invoke-RestMethod -Method Post -Uri "$DonationsBase/api/donations" `
  -Headers @{ Authorization = "Bearer $donorTok" } -ContentType 'application/json' `
  -Body (@{ campaignId=$campaignId; amount=$DeclinedAmount; paymentMethod=0 } | ConvertTo-Json)
Write-Host "  202 -> donationId=$($don2.donationId)"
Start-Sleep -Seconds 12
$afterDeclined = (Panel $campaignId).amountRaised
Write-Host "  amountRaised apos recusada = $afterDeclined (deve seguir = $target)"
if ([double]$afterDeclined -eq [double]$target) { Write-Host '  >>> RECUSA OK (nao somou)' -ForegroundColor Green }
else { Write-Host '  >>> ATENCAO: valor mudou apos recusa' -ForegroundColor Yellow }

Write-Host "`nRESUMO: aprovada=$ok ; campanha=$campaignId ; amountRaised final=$afterDeclined" -ForegroundColor Cyan
