#requires -Version 7
# Validacao E2E ABRANGENTE de todas as operacoes, atraves do gateway do APIM (default)
# ou direto (passe -ApiBase http://<ip-users>:8080 etc. nao — use o APIM que cobre os dois).
# Cobre: auth, RBAC, gestao de usuarios, CRUD de campanhas + regras, doacao aprovada/recusada
# (saga, com polling), transparencia e payments. Imprime um placar no final.
param(
  # Gateway do APIM: https://apim-conexao-solidaria-<suffix>.azure-api.net  (rota /api/...)
  [Parameter(Mandatory)][string]$ApiBase,
  # Base direta da PaymentAPI (ex.: http://localhost:5002 via port-forward). O payments
  # nao fica atras do APIM (nao e rota publica + limite de 3 IPs na Free Trial). Vazio = pula.
  [string]$PaymentsBase = '',
  [string]$OwnerEmail = 'owner@conexaosolidaria.org',
  [string]$OwnerPassword = 'SenhaSuperForte!123'
)
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function Check($name, $cond, $detail='') {
  if ($cond) { $script:pass++; Write-Host "  [OK] $name" -ForegroundColor Green }
  else { $script:fail++; Write-Host "  [FALHOU] $name $detail" -ForegroundColor Red }
}
function Req($method, $path, $token=$null, $body=$null, $base=$null) {
  $u = if ($base) { $base } else { $ApiBase }
  $h = @{}; if ($token) { $h['Authorization'] = "Bearer $token" }
  $args = @{ Method=$method; Uri="$u$path"; Headers=$h; SkipHttpErrorCheck=$true; MaximumRedirection=0; AllowInsecureRedirect=$true; TimeoutSec=30 }
  if ($body -ne $null) { $args['ContentType']='application/json'; $args['Body']=($body | ConvertTo-Json) }
  $r = Invoke-WebRequest @args
  $obj = $null; if ($r.Content) { try { $obj = $r.Content | ConvertFrom-Json } catch {} }
  return [pscustomobject]@{ Code=[int]$r.StatusCode; Body=$obj }
}
function Tok($r) { if ($r.Body.AccessToken) { $r.Body.AccessToken } else { $r.Body.accessToken } }
function New-Cpf {
  $d = 0..8 | ForEach-Object { Get-Random -Minimum 0 -Maximum 10 }
  $s1 = 0; for ($i=0; $i -lt 9; $i++) { $s1 += $d[$i] * (10 - $i) }
  $r1 = $s1 % 11; $dv1 = if ($r1 -lt 2) { 0 } else { 11 - $r1 }
  $s2 = 0; for ($i=0; $i -lt 9; $i++) { $s2 += $d[$i] * (11 - $i) }; $s2 += $dv1 * 2
  $r2 = $s2 % 11; $dv2 = if ($r2 -lt 2) { 0 } else { 11 - $r2 }
  return (($d -join '') + "$dv1$dv2")
}
$rnd = Get-Random
$cpf = New-Cpf

Write-Host "== AUTH ==" -ForegroundColor Cyan
$owner = Req POST '/api/auth/login' $null @{ email=$OwnerEmail; password=$OwnerPassword }
Check "login owner 200" ($owner.Code -eq 200) "(got $($owner.Code))"
$ownerTok = Tok $owner
Check "login senha errada -> 401" ((Req POST '/api/auth/login' $null @{ email=$OwnerEmail; password='errada!' }).Code -eq 401)
$donorEmail = "doador.$rnd@teste.com"
$reg = Req POST '/api/auth/register' $null @{ personType=0; document=$cpf; name='Doador E2E'; email=$donorEmail; password='Senha@123' }
Check "register doador 201" ($reg.Code -eq 201) "(got $($reg.Code))"
Check "register senha fraca -> 400" ((Req POST '/api/auth/register' $null @{ personType=0; document=(New-Cpf); name='x'; email="a.$rnd@t.com"; password='abc' }).Code -eq 400)
Check "register CPF invalido -> 400" ((Req POST '/api/auth/register' $null @{ personType=0; document='12345678900'; name='x'; email="b.$rnd@t.com"; password='Senha@123' }).Code -eq 400)
$dup = Req POST '/api/auth/register' $null @{ personType=0; document=$cpf; name='x'; email=$donorEmail; password='Senha@123' }
Check "register duplicado -> 409" ($dup.Code -eq 409) "(got $($dup.Code))"
$donorTok = Tok (Req POST '/api/auth/login' $null @{ email=$donorEmail; password='Senha@123' })
Check "login doador 200" ($donorTok -ne $null)

Write-Host "== RBAC / USUARIOS ==" -ForegroundColor Cyan
Check "Doador em GET /api/users -> 403" ((Req GET '/api/users' $donorTok).Code -eq 403)
Check "anonimo em GET /api/users -> 401" ((Req GET '/api/users' $null).Code -eq 401)
Check "owner GET /api/users -> 200" ((Req GET '/api/users' $ownerTok).Code -eq 200)
$me = Req GET '/api/users/me' $donorTok
Check "doador GET /api/users/me -> 200" ($me.Code -eq 200)
$newGestor = Req POST '/api/users' $ownerTok @{ personType=0; document=(New-Cpf); name='Gestor2'; email="gestor.$rnd@t.com"; password='Senha@123'; role=1 }
Check "owner cria GestorONG -> 201" ($newGestor.Code -eq 201) "(got $($newGestor.Code))"

Write-Host "== CAMPANHAS (regras) ==" -ForegroundColor Cyan
Check "Doador cria campanha -> 403" ((Req POST '/api/campaigns' $donorTok @{ title='x'; description='y'; startDate='2026-07-01T00:00:00Z'; endDate='2026-12-31T00:00:00Z'; goal=1000 }).Code -eq 403)
Check "goal=0 -> 400" ((Req POST '/api/campaigns' $ownerTok @{ title='x'; description='y'; startDate='2026-07-01T00:00:00Z'; endDate='2026-12-31T00:00:00Z'; goal=0 }).Code -eq 400)
Check "endDate no passado -> 400" ((Req POST '/api/campaigns' $ownerTok @{ title='x'; description='y'; startDate='2020-01-01T00:00:00Z'; endDate='2020-02-01T00:00:00Z'; goal=1000 }).Code -eq 400)
$camp = Req POST '/api/campaigns' $ownerTok @{ title="Campanha $rnd"; description='teste'; startDate='2026-07-01T00:00:00Z'; endDate='2026-12-31T23:59:59Z'; goal=100000 }
Check "cria campanha valida -> 201" ($camp.Code -eq 201) "(got $($camp.Code))"
$campId = $camp.Body.id
Check "GET campanha by id -> 200" ((Req GET "/api/campaigns/$campId" $ownerTok).Code -eq 200)

Write-Host "== DOACAO + SAGA ==" -ForegroundColor Cyan
Check "GestorONG doando -> 403" ((Req POST '/api/donations' $ownerTok @{ campaignId=$campId; amount=10; paymentMethod=0 }).Code -eq 403)
Check "amount=0 -> 400" ((Req POST '/api/donations' $donorTok @{ campaignId=$campId; amount=0; paymentMethod=0 }).Code -eq 400)
Check "campanha inexistente -> 422" ((Req POST '/api/donations' $donorTok @{ campaignId='00000000-0000-0000-0000-000000000000'; amount=10; paymentMethod=0 }).Code -eq 422)
$don = Req POST '/api/donations' $donorTok @{ campaignId=$campId; amount=100.00; paymentMethod=0 }
Check "doacao aprovada -> 202" ($don.Code -eq 202) "(got $($don.Code))"
$donId = $don.Body.donationId
# polling consolidacao
$consolidou = $false
for ($i=0; $i -lt 30; $i++) {
  Start-Sleep -Seconds 3
  $panel = (Req GET '/api/transparency/campaigns' $null).Body | Where-Object { $_.id -eq $campId }
  if ($panel -and [double]$panel.amountRaised -ge 100) { $consolidou = $true; break }
}
Check "saga: amountRaised consolidou p/ 100" $consolidou
$donDet = Req GET "/api/donations/$donId" $donorTok
Check "doacao status Approved" ($donDet.Body.status -eq 'Approved') "(got $($donDet.Body.status))"
# recusada (,99)
$don2 = Req POST '/api/donations' $donorTok @{ campaignId=$campId; amount=50.99; paymentMethod=0 }
$declined = $false
for ($i=0; $i -lt 20; $i++) { Start-Sleep -Seconds 3; if ((Req GET "/api/donations/$($don2.Body.donationId)" $donorTok).Body.status -eq 'Declined') { $declined = $true; break } }
Check "saga: doacao ,99 -> Declined" $declined
$panelAfter = (Req GET '/api/transparency/campaigns' $null).Body | Where-Object { $_.id -eq $campId }
Check "recusada nao credita (amountRaised=100)" ([double]$panelAfter.amountRaised -eq 100)

Write-Host "== TRANSPARENCIA + PAYMENTS ==" -ForegroundColor Cyan
Check "transparencia publica (sem token) -> 200" ((Req GET '/api/transparency/campaigns' $null).Code -eq 200)
if ($PaymentsBase) {
  Check "payment by donation (owner, direto) -> 200" ((Req GET "/api/payments/$donId" $ownerTok $null $PaymentsBase).Code -eq 200)
  Check "payment (doador, direto) -> 403" ((Req GET "/api/payments/$donId" $donorTok $null $PaymentsBase).Code -eq 403)
} else {
  Write-Host "  [SKIP] payments GET (nao exposto via APIM; limite de 3 IPs) - passe -PaymentsBase p/ validar direto" -ForegroundColor Yellow
}

Write-Host "`n===== PLACAR: $script:pass OK / $script:fail FALHOU =====" -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 }
