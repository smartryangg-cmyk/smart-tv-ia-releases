<#
.SYNOPSIS
  Desfaz o configurar-tv.ps1: desliga a assistência remota e tira as permissões dadas pelo PC.

.DESCRIPTION
  - Desliga a assistência remota (para de enviar relatórios).
  - Revoga READ_LOGS, DUMP, WRITE_SECURE_SETTINGS e PACKAGE_USAGE_STATS e volta os appops ao padrão.
  - "Dono do aparelho" NÃO sai pelo adb (o Android só permite isso para apps de teste). Para tirar,
    abra na TV: Smart TV IA > Atualizar app > Assistência remota > "Deixar de ser dono do aparelho".
    O script avisa se ainda for dono.
  - A permissão de instalar atualizações (REQUEST_INSTALL_PACKAGES) é mantida; use -TambemInstalar para tirar.

.EXAMPLE
  .\desfazer-configuracao.ps1
  .\desfazer-configuracao.ps1 -Ip 192.168.0.50 -TambemInstalar
#>
[CmdletBinding()]
param(
    [string]$Ip = '192.168.0.112',
    [int]$Porta = 5555,
    [string]$Adb = '',
    # Também tira a permissão de instalar atualizações (aí cada atualização precisa liberar de novo).
    [switch]$TambemInstalar
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

function Get-Motivo([string]$texto) {
    if (-not $texto) { return 'sem resposta' }
    foreach ($l in ($texto -split "`n")) {
        $t = $l.Trim()
        if ($t -and $t -notmatch '^\s*at ') { return $t }
    }
    return $texto.Trim()
}

function Invoke-Passo([string]$Titulo, [string]$Comando) {
    $r = Invoke-Tv $Comando
    if (($r.Codigo -ne 0) -or ($r.Texto -match '(?i)exception|error|failure|not allowed|unknown|denied')) {
        $script:Falhas++
        Write-Host ("  FALHOU  {0}: {1}" -f $Titulo, (Get-Motivo $r.Texto)) -ForegroundColor Red
        return $false
    }
    Write-Host ("  OK      {0}" -f $Titulo) -ForegroundColor Green
    return $true
}

if ($Ip -notmatch '^[A-Za-z0-9.\-]+$') { Stop-ComErro "IP inválido: $Ip" }
$script:AdbExe = Find-Adb
$script:Serial = "${Ip}:$Porta"

Write-Host '=== Smart TV IA - desfazer configuração da assistência remota ===' -ForegroundColor Cyan
Write-Host "Conectando em $script:Serial ..."
$c = Invoke-Adb @('connect', $script:Serial)
Write-Host "  $($c.Texto)"
$estado = (Invoke-Adb @('-s', $script:Serial, 'get-state')).Texto
if ($estado -ne 'device') {
    Stop-ComErro "a TV não respondeu como 'device' (resposta: $estado). Confira o IP e a depuração por rede."
}

# Primeiro desliga o envio (o broadcast exige DUMP de quem manda, que é o adb, não o app).
$r = Invoke-Tv "am broadcast -f 32 -a br.smarttvia.CARE_CONSENT -n $Pacote/br.smarttvia.tv.CareConsentReceiver --ez on false"
if ($r.Texto -match 'Broadcast completed') {
    Write-Host '  OK      assistência remota desligada' -ForegroundColor Green
} else {
    $script:Falhas++
    Write-Host "  FALHOU  desligar assistência remota: $(Get-Motivo $r.Texto)" -ForegroundColor Red
}

foreach ($perm in @('android.permission.READ_LOGS', 'android.permission.DUMP', 'android.permission.WRITE_SECURE_SETTINGS', 'android.permission.PACKAGE_USAGE_STATS')) {
    [void](Invoke-Passo "revogar $perm" "pm revoke $Pacote $perm")
}
[void](Invoke-Passo 'uso de apps (appops GET_USAGE_STATS) no padrão' "appops set $Pacote GET_USAGE_STATS default")
[void](Invoke-Passo 'ajustes do sistema (appops WRITE_SETTINGS) no padrão' "appops set $Pacote WRITE_SETTINGS default")
if ($TambemInstalar) {
    [void](Invoke-Passo 'instalar atualizações (appops REQUEST_INSTALL_PACKAGES) no padrão' "appops set $Pacote REQUEST_INSTALL_PACKAGES default")
} else {
    Write-Host '  MANTIDO instalar atualizações (use -TambemInstalar para tirar)' -ForegroundColor Yellow
}

$dp = Invoke-Tv 'dumpsys device_policy'
if ($dp.Texto -match 'Device Owner' -and $dp.Texto -match [regex]::Escape("ComponentInfo{$Admin}")) {
    Write-Host ''
    Write-Host 'O app AINDA é dono do aparelho. O adb não consegue tirar isso (só em apps de teste).' -ForegroundColor Yellow
    Write-Host 'Na TV, abra: Smart TV IA > Atualizar app > Assistência remota > "Deixar de ser dono do aparelho".' -ForegroundColor Yellow
} else {
    Write-Host '  OK      o app não é dono do aparelho' -ForegroundColor Green
}

Write-Host ''
if ($script:Falhas -eq 0) { Write-Host 'Pronto: configuração desfeita.' -ForegroundColor Green }
else { Write-Host "Terminado com $($script:Falhas) passo(s) com falha (veja acima)." -ForegroundColor Yellow }
