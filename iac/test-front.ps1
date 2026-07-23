#requires -Version 7
# Validacao E2E ATRAVES DO FRONT (BFF): browser -> BFF (/api/bff/*) -> APIM -> servicos -> saga.
# Exercita a MESMA cadeia que o navegador usa, incl. cookies httpOnly (cs_at/cs_rt) via cookie jar.
# Pre-requisito: front no ar (Container Apps) + APIM + AKS (3 servicos) no ar.
# Enums vao como STRING (o BFF converte p/ int no upstream): method='Pix', personType='Individual', action='Close'.
param(
  [string]$FrontBase = 'https://ca-conexao-front.salmonfield-1077cb39.brazilsouth.azurecontainerapps.io',
  [string]$OwnerEmail = 'owner@conexaosolidaria.org',
  [string]$OwnerPassword = 'SenhaSuperForte!123'
)
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function Check($name, $cond, $detail = '') {
  if ($cond) { $script:pass++; Write-Host "  [OK] $name" -ForegroundColor Green }
  else { $script:fail++; Write-Host "  [FALHOU] $name $detail" -ForegroundColor Red }
}
function New-Session { [Microsoft.PowerShell.Commands.WebRequestSession]::new() }
function HasCookie($session, $name) {
  return (@($session.Cookies.GetAllCookies() | Where-Object { $_.Name -eq $name }).Count -ge 1)
}
# Chamada ao BFF do front (mesma origem que o browser). $session mantem os cookies.
function Bff($method, $path, $session, $body = $null) {
  $a = @{ Method = $method; Uri = "$FrontBase/api/bff$path"; WebSession = $session; SkipHttpErrorCheck = $true; MaximumRedirection = 0; TimeoutSec = 60 }
  if ($null -ne $body) { $a['ContentType'] = 'application/json'; $a['Body'] = ($body | ConvertTo-Json) }
  $r = Invoke-WebRequest @a
  $obj = $null; if ($r.Content) { try { $obj = $r.Content | ConvertFrom-Json } catch {} }
  return [pscustomobject]@{ Code = [int]$r.StatusCode; Body = $obj }
}
function New-Cpf {
  $d = 0..8 | ForEach-Object { Get-Random -Minimum 0 -Maximum 10 }
  $s1 = 0; for ($i = 0; $i -lt 9; $i++) { $s1 += $d[$i] * (10 - $i) }
  $r1 = $s1 % 11; $dv1 = if ($r1 -lt 2) { 0 } else { 11 - $r1 }
  $s2 = 0; for ($i = 0; $i -lt 9; $i++) { $s2 += $d[$i] * (11 - $i) }; $s2 += $dv1 * 2
  $r2 = $s2 % 11; $dv2 = if ($r2 -lt 2) { 0 } else { 11 - $r2 }
  return (($d -join '') + "$dv1$dv2")
}
$rnd = Get-Random
$anon = New-Session; $owner = New-Session; $donor = New-Session

Write-Host "== FRONT: $FrontBase ==" -ForegroundColor Cyan
Write-Host "== TRANSPARENCIA (publica) ==" -ForegroundColor Cyan
$t = Bff GET '/transparency/campaigns' $anon
Check "transparencia sem login -> 200" ($t.Code -eq 200) "(got $($t.Code))"

Write-Host "== AUTH ==" -ForegroundColor Cyan
$lo = Bff POST '/auth/login' $owner @{ email = $OwnerEmail; password = $OwnerPassword }
Check "login owner -> 200" ($lo.Code -eq 200) "(got $($lo.Code))"
Check "login owner setou cookie cs_at" (HasCookie $owner 'cs_at')
Check "login senha errada -> 401" ((Bff POST '/auth/login' (New-Session) @{ email = $OwnerEmail; password = 'errada!' }).Code -eq 401)

$donorEmail = "doador.$rnd@teste.com"; $cpf = New-Cpf
$reg = Bff POST '/auth/register' (New-Session) @{ personType = 'Individual'; document = $cpf; name = 'Doador E2E Front'; email = $donorEmail; password = 'Senha@123' }
Check "register doador -> 201" ($reg.Code -eq 201) "(got $($reg.Code))"
$dl = Bff POST '/auth/login' $donor @{ email = $donorEmail; password = 'Senha@123' }
Check "login doador -> 200" ($dl.Code -eq 200) "(got $($dl.Code))"
$me = Bff GET '/auth/me' $donor
Check "doador /auth/me -> 200 e role=Doador" ($me.Code -eq 200 -and $me.Body.role -eq 'Doador') "(got $($me.Code)/$($me.Body.role))"

Write-Host "== RBAC ==" -ForegroundColor Cyan
Check "doador cria campanha -> 403" ((Bff POST '/campaigns' $donor @{ title = 'x'; description = 'y'; startDate = '2026-07-01T00:00:00Z'; endDate = '2026-12-31T00:00:00Z'; goal = 1000 }).Code -eq 403)
Check "anonimo lista campanhas (admin) -> 401" ((Bff GET '/campaigns' $anon).Code -eq 401)

Write-Host "== CAMPANHA (owner) ==" -ForegroundColor Cyan
$camp = Bff POST '/campaigns' $owner @{ title = "Campanha Front $rnd"; description = 'teste via front'; startDate = '2026-07-01T00:00:00Z'; endDate = '2026-12-31T23:59:59Z'; goal = 100000 }
Check "owner cria campanha -> 201" ($camp.Code -eq 201) "(got $($camp.Code))"
$campId = $camp.Body.id
Check "campanha retornou id" ($null -ne $campId)

Write-Host "== DOACAO + SAGA ==" -ForegroundColor Cyan
$don = Bff POST '/donations' $donor @{ campaignId = $campId; amount = 100.00; method = 'Pix' }
Check "doacao -> 202 (Pending)" ($don.Code -eq 202) "(got $($don.Code))"
$donId = $don.Body.donationId
$approved = $false
for ($i = 0; $i -lt 30; $i++) { Start-Sleep 3; if ((Bff GET "/donations/$donId" $donor).Body.status -eq 'Approved') { $approved = $true; break } }
Check "saga: doacao -> Approved (polling)" $approved
$consol = $false
for ($i = 0; $i -lt 20; $i++) { Start-Sleep 3; $p = (Bff GET '/transparency/campaigns' $anon).Body | Where-Object { $_.id -eq $campId }; if ($p -and [double]$p.amountRaised -ge 100) { $consol = $true; break } }
Check "saga: transparencia amountRaised >= 100" $consol
$don2 = Bff POST '/donations' $donor @{ campaignId = $campId; amount = 50.99; method = 'Pix' }
$declined = $false
for ($i = 0; $i -lt 20; $i++) { Start-Sleep 3; if ((Bff GET "/donations/$($don2.Body.donationId)" $donor).Body.status -eq 'Declined') { $declined = $true; break } }
Check "saga: doacao ,99 -> Declined (polling)" $declined

Write-Host "`n===== PLACAR (via front/BFF): $script:pass OK / $script:fail FALHOU =====" -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 }
