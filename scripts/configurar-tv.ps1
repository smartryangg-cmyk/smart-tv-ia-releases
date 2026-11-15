<#
.SYNOPSIS
  Configuração única da assistência remota do Smart TV IA (rodar uma vez no PC, com a TV na mesma rede).

.DESCRIPTION
  Pelo adb (depuração por rede ligada na TV), dá ao Smart TV IA permissões que só o PC pode dar:
    - READ_LOGS               : ler os avisos do sistema (logcat) ligados a Google/YouTube/Netflix/rede
    - DUMP                    : ler o resumo técnico da WebView, da conexão e quantas contas existem
    - WRITE_SECURE_SETTINGS   : aplicar correções seguras de ajustes (ex.: data e hora automáticas, DNS privado)
    - PACKAGE_USAGE_STATS     : saber se YouTube/Netflix foram abertos nos últimos 7 dias
    - WRITE_SETTINGS          : ajustes da categoria "system"
    - REQUEST_INSTALL_PACKAGES: instalar as atualizações do app
  Depois tenta tornar o app "dono do aparelho" (device owner), para ele se atualizar sem pedir OK
  e poder ocultar/mostrar/reativar apps a pedido do desenvolvedor. Isso SÓ funciona se a TV não
  tiver nenhuma conta (Google ou outra) cadastrada. Se falhar, o resto continua valendo; só as
  atualizações vão pedir um OK na tela.
  Por fim pergunta se deve ligar a assistência remota (o envio do relatório técnico).
  Tudo pode ser desfeito com desfazer-configuracao.ps1.

.EXAMPLE
  .\configurar-tv.ps1
  .\configurar-tv.ps1 -Ip 192.168.0.50
  .\configurar-tv.ps1 -PularDono -AtivarAssistencia
#>
[CmdletBinding()]
param(
    [string]$Ip = '192.168.0.112',
    [int]$Porta = 5555,
    # Caminho do adb.exe. Vazio = .\adb.exe da pasta atual, da pasta do script ou o adb do PATH.
    [string]$Adb = '',
    # Não tenta tornar o app dono do aparelho.
    [switch]$PularDono,
    # Liga a assistência remota sem perguntar.
    [switch]$AtivarAssistencia
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Pacote = 'br.smarttvia.launcher'
$Admin = 'br.smarttvia.launcher/br.smarttvia.tv.CareAdminReceiver'
$script:Falhas = 0

function Stop-ComErro([string]$msg) {
    Write-Host ''
    Write-Host "ERRO: $msg" -ForegroundColor Red
    exit 1
}

function Find-Adb {
    if ($Adb) {
        if (Test-Path -LiteralPath $Adb) { return (Resolve-Path -LiteralPath $Adb).Path }
        Stop-ComErro "adb não encontrado em '$Adb'."
    }
    foreach ($p in @((Join-Path (Get-Location).Path 'adb.exe'), (Join-Path $PSScriptRoot 'adb.exe'))) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Stop-ComErro 'adb não encontrado. Rode o script na pasta do adb.exe (.\adb) ou use -Adb C:\caminho\adb.exe.'
}

function Invoke-Adb([string[]]$Argumentos) {
    $antes = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $saida = & $script:AdbExe @Argumentos 2>&1 | ForEach-Object { "$_" }
        $codigo = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $antes
    }
    return [pscustomobject]@{ Codigo = $codigo; Texto = (@($saida) -join "`n").Trim() }
}

function Invoke-Tv([string]$Comando) {
    return Invoke-Adb @('-s', $script:Serial, 'shell', $Comando)
}

# Primeira linha útil da resposta, para explicar o motivo de uma falha.
function Get-Motivo([string]$texto) {
    if (-not $texto) { return 'sem resposta' }
    foreach ($l in ($texto -split "`n")) {
        $t = $l.Trim()
        if ($t -and $t -notmatch '^\s*at ') { return $t }
    }
    return $texto.Trim()
}

function Test-Falhou($r) {
    return ($r.Codigo -ne 0) -or ($r.Texto -match '(?i)exception|error|failure|not allowed|unknown|denied')
}

# Roda um comando na TV e mostra OK/FALHOU com o motivo.
function Invoke-Passo([string]$Titulo, [string]$Comando) {
    $r = Invoke-Tv $Comando
    if (Test-Falhou $r) {
        $script:Falhas++
        Write-Host ("  FALHOU  {0}: {1}" -f $Titulo, (Get-Motivo $r.Texto)) -ForegroundColor Red
        return $false
    }
    Write-Host ("  OK      {0}" -f $Titulo) -ForegroundColor Green
    return $true
}

function Test-DonoDoAparelho {
    $r = Invoke-Tv 'dumpsys device_policy'
    return ($r.Texto -match 'Device Owner' -and $r.Texto -match [regex]::Escape("ComponentInfo{$Admin}"))
}

# ------------------------------------------------------------------ início

if ($Ip -notmatch '^[A-Za-z0-9.\-]+$') { Stop-ComErro "IP inválido: $Ip" }
$script:AdbExe = Find-Adb
$script:Serial = "${Ip}:$Porta"

Write-Host '=== Smart TV IA - configurar assistência remota ===' -ForegroundColor Cyan
Write-Host "adb: $script:AdbExe"
Write-Host "Conectando em $script:Serial ..."
$c = Invoke-Adb @('connect', $script:Serial)
Write-Host "  $($c.Texto)"
$estado = (Invoke-Adb @('-s', $script:Serial, 'get-state')).Texto
if ($estado -ne 'device') {
    Stop-ComErro "a TV não respondeu como 'device' (resposta: $estado). Confira o IP, se a depuração por rede está ligada e aceite o aviso 'Permitir depuração' na tela da TV."
}
$modelo = (Invoke-Tv 'getprop ro.product.model').Texto
$android = (Invoke-Tv 'getprop ro.build.version.release').Texto
Write-Host "TV: $modelo (Android $android)"

$path = Invoke-Tv "pm path $Pacote"
if ($path.Texto -notmatch 'package:') {
    Stop-ComErro "o Smart TV IA ($Pacote) não está instalado nesta TV. Instale o APK primeiro."
}

Write-Host ''
Write-Host '1) Permissões que só o PC pode dar' -ForegroundColor Cyan
foreach ($perm in @('android.permission.READ_LOGS', 'android.permission.DUMP', 'android.permission.WRITE_SECURE_SETTINGS', 'android.permission.PACKAGE_USAGE_STATS')) {
    [void](Invoke-Passo "permissão $perm" "pm grant $Pacote $perm")
}
[void](Invoke-Passo 'uso de apps (appops GET_USAGE_STATS)' "appops set $Pacote GET_USAGE_STATS allow")
[void](Invoke-Passo 'ajustes do sistema (appops WRITE_SETTINGS)' "appops set $Pacote WRITE_SETTINGS allow")
[void](Invoke-Passo 'instalar atualizações (appops REQUEST_INSTALL_PACKAGES)' "appops set $Pacote REQUEST_INSTALL_PACKAGES allow")

Write-Host ''
Write-Host '2) Dono do aparelho (atualização sem OK e correções em apps)' -ForegroundColor Cyan
Write-Host '   Só funciona se a TV NÃO tiver nenhuma conta (Google ou outra) cadastrada.'
Write-Host '   Pode ser desfeito no app: Atualizar app > Assistência remota > "Deixar de ser dono do aparelho".'
if ($PularDono) {
    Write-Host '  PULADO  dono do aparelho (-PularDono)' -ForegroundColor Yellow
} elseif (Test-DonoDoAparelho) {
    Write-Host '  OK      o app já é dono do aparelho' -ForegroundColor Green
} else {
    $r = Invoke-Tv "dpm set-device-owner $Admin"
    if ($r.Texto -match 'Success') {
        Write-Host '  OK      o app agora é dono do aparelho: as atualizações instalam sozinhas.' -ForegroundColor Green
    } else {
        $script:Falhas++
        $motivo = Get-Motivo $r.Texto
        Write-Host "  FALHOU  dono do aparelho: $motivo" -ForegroundColor Red
        if ($r.Texto -match '(?i)account') {
            Write-Host '          A TV tem conta(s) cadastrada(s) (por exemplo a conta Google), e o Android só deixa' -ForegroundColor Yellow
            Write-Host '          um app virar dono do aparelho sem contas. Tudo bem: as permissões acima continuam' -ForegroundColor Yellow
            Write-Host '          valendo e o relatório funciona; só as atualizações vão pedir um OK na tela.' -ForegroundColor Yellow
            Write-Host '          (Não remova a conta só por isso.)' -ForegroundColor Yellow
        } elseif ($r.Texto -match '(?i)already') {
            Write-Host '          Já existe um dono do aparelho ou a TV já foi configurada de outro jeito. O resto continua valendo.' -ForegroundColor Yellow
        } elseif ($r.Texto -match '(?i)users') {
            Write-Host '          A TV tem mais de um usuário/perfil. O resto continua valendo.' -ForegroundColor Yellow
        } else {
            Write-Host '          O resto continua valendo; só as atualizações vão pedir um OK na tela.' -ForegroundColor Yellow
        }
    }
}

Write-Host ''
Write-Host '3) Assistência remota (envio do relatório técnico ao desenvolvedor)' -ForegroundColor Cyan
Write-Host '   Envia a cada 6 h: modelo, versões, rede, data/hora, estado dos apps do Google/YouTube/Netflix,'
Write-Host '   avisos do sistema sem e-mails/senhas e quantas contas existem (nunca nomes ou e-mails).'
$ativar = $AtivarAssistencia
if (-not $ativar) {
    $resp = Read-Host 'Ativar assistência remota? Digite SIM para ativar'
    $ativar = ($resp.Trim().ToUpperInvariant() -eq 'SIM')
}
if ($ativar) {
    $r = Invoke-Tv "am broadcast -f 32 -a br.smarttvia.CARE_CONSENT -n $Pacote/br.smarttvia.tv.CareConsentReceiver --ez on true"
    if ((Test-Falhou $r) -or ($r.Texto -notmatch 'Broadcast completed')) {
        $script:Falhas++
        Write-Host "  FALHOU  ativar assistência remota: $(Get-Motivo $r.Texto)" -ForegroundColor Red
    } else {
        Write-Host '  OK      assistência remota ligada; o primeiro relatório sai em instantes.' -ForegroundColor Green
    }
} else {
    Write-Host '  PULADO  assistência remota continua desligada (dá para ligar na TV, em Atualizar app > Assistência remota).' -ForegroundColor Yellow
}

Write-Host ''
if ($script:Falhas -eq 0) {
    Write-Host 'Pronto: tudo configurado.' -ForegroundColor Green
} else {
    Write-Host "Terminado com $($script:Falhas) passo(s) com falha (veja acima). O que deu OK já está valendo." -ForegroundColor Yellow
}
Write-Host 'Para desfazer: .\desfazer-configuracao.ps1'
