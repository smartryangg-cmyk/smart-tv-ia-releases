<#
.SYNOPSIS
  Conserta o Google Play Services da TV (causa do YouTube, Netflix e Play Store não funcionarem).

.DESCRIPTION
  O diagnóstico de 15/11 mostrou o Google Play Services (com.google.android.gms, versão de fábrica
  20.12.16) travando toda vez que abre, com o erro do Android
  "Check failed: klass->IsArrayClass() java.lang.Class<zol>". Esse erro costuma vir do código
  pré-compilado (otimização ART) estragado. Sem o Play Services, o YouTube, a Play Store e o login
  dos apps não funcionam.

  Etapa 1 (padrão, não apaga nada): força o Android a compilar de novo, do zero, o Play Services,
  o YouTube, a Play Store e a Netflix contra o sistema atual da TV (cmd package compile -m speed -f).
  O código de fábrica que vem pronto não bate com o sistema da TV ("Didn't find oat method index").
  Demora: o Play Services pode levar 5 a 15 minutos. Depois reinicia a TV e confere se ainda trava.
  Etapa 2 (-LimparDados): além disso, limpa os dados do Play Services e da Play Store, igual a
  "Limpar dados" nas Configurações. A conta Google continua na TV; o Play Services baixa os módulos
  de novo sozinho.

  No fim grava resultado-conserto-<data>.txt na pasta atual. Mande esse arquivo para o Claude.

.EXAMPLE
  .\consertar-google.ps1
  .\consertar-google.ps1 -LimparDados
#>
[CmdletBinding()]
param(
    [string]$Ip = '192.168.0.112',
    [int]$Porta = 5555,
    [string]$Adb = '',
    [switch]$LimparDados
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Pacotes = @('com.google.android.gms', 'com.google.android.youtube.tv', 'com.android.vending', 'com.netflix.ninja')
$Alvo = "${Ip}:$Porta"
$Log = New-Object System.Collections.Generic.List[string]

function Escreve([string]$msg, [string]$cor = 'Gray') {
    Write-Host $msg -ForegroundColor $cor
    $Log.Add($msg)
}

function Acha-Adb {
    if ($Adb) { return $Adb }
    foreach ($p in @((Join-Path (Get-Location).Path 'adb.exe'), (Join-Path $PSScriptRoot 'adb.exe'))) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Write-Host 'ERRO: adb.exe não encontrado. Rode o script dentro da pasta platform-tools.' -ForegroundColor Red
    exit 1
}
$AdbExe = Acha-Adb

function Adb([string[]]$a) {
    # No PowerShell 5.1 o stderr do adb vira erro; aqui ele é só texto.
    $antes = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $saida = & $AdbExe -s $Alvo @a 2>&1 | ForEach-Object { "$_" } | Out-String
    } finally {
        $ErrorActionPreference = $antes
    }
    return $saida.Trim()
}

function Conecta([int]$tentativas) {
    for ($i = 0; $i -lt $tentativas; $i++) {
        & $AdbExe connect $Alvo 2>&1 | Out-Null
        $estado = (& $AdbExe -s $Alvo get-state 2>&1 | ForEach-Object { "$_" } | Out-String).Trim()
        if ($estado -eq 'device') { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

Escreve "== Conserto do Google Play Services ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))" 'Cyan'
if (-not (Conecta 3)) {
    Escreve "ERRO: não conectei em $Alvo. Confira o IP e se a depuração por rede está ligada (aceite o aviso na TV)." 'Red'
    exit 1
}

Escreve '-- Versões antes:'
foreach ($p in $Pacotes) {
    $v = Adb @('shell', "dumpsys package $p 2>/dev/null | grep versionName")
    Escreve "   ${p}: $v"
}

Escreve '-- Etapa 1: compilar de novo, do zero, contra o sistema atual (não apaga dados)' 'Cyan'
Escreve '   Isso demora. Não desligue a TV. O Play Services pode levar até 15 minutos.' 'Yellow'
foreach ($p in $Pacotes) {
    $t0 = Get-Date
    $r = Adb @('shell', 'cmd', 'package', 'compile', '-m', 'speed', '-f', $p)
    $seg = [int]((Get-Date) - $t0).TotalSeconds
    Escreve "   $p -> $r ($seg s)"
}
$r = Adb @('shell', "dumpsys package dexopt 2>/dev/null | grep -A3 'com.google.android.gms]'")
Escreve "   estado do Play Services: $r"

if ($LimparDados) {
    Escreve '-- Etapa 2: limpar dados do Play Services e da Play Store' 'Cyan'
    foreach ($p in @('com.google.android.gms', 'com.android.vending')) {
        $r = Adb @('shell', 'pm', 'clear', $p)
        Escreve "   $p -> $r"
    }
}

Escreve '-- Reiniciando a TV (leva 1 a 2 minutos)...' 'Cyan'
Adb @('logcat', '-b', 'crash', '-c') | Out-Null
Adb @('reboot') | Out-Null
Start-Sleep -Seconds 40
if (-not (Conecta 30)) {
    Escreve 'ERRO: a TV não voltou na rede em 3 minutos. Ligue a TV e rode o script de novo.' 'Red'
    exit 1
}
for ($i = 0; $i -lt 36; $i++) {
    if ((Adb @('shell', 'getprop', 'sys.boot_completed')) -eq '1') { break }
    Start-Sleep -Seconds 5
}
Escreve '-- TV ligada. Esperando 60 s o Play Services subir...'
Start-Sleep -Seconds 60

Escreve '-- Abrindo o YouTube por 25 s...'
Adb @('shell', 'monkey', '-p', 'com.google.android.youtube.tv', '-c', 'android.intent.category.LEANBACK_LAUNCHER', '1') | Out-Null
Start-Sleep -Seconds 25
Adb @('shell', 'input', 'keyevent', 'HOME') | Out-Null

$crash = Adb @('logcat', '-b', 'crash', '-d')
$gmsCai = $crash -match 'com\.google\.android\.gms'
$ytCai = $crash -match 'youtube'
$gmsVivo = Adb @('shell', 'pidof', 'com.google.android.gms.persistent')

Escreve ''
if (-not $gmsCai -and $gmsVivo) {
    Escreve "RESULTADO: Play Services rodando sem travar (pid $gmsVivo). Teste YouTube e Netflix na TV." 'Green'
} elseif ($gmsCai) {
    if ($LimparDados) {
        Escreve 'RESULTADO: o Play Services ainda trava. Próximo passo: instalar o Play Services atualizado (o Claude manda o passo a passo).' 'Yellow'
    } else {
        Escreve 'RESULTADO: o Play Services ainda trava. Rode de novo com:  .\consertar-google.ps1 -LimparDados' 'Yellow'
    }
} else {
    Escreve 'RESULTADO: sem travamento registrado, mas o Play Services não estava rodando. Mande o arquivo de resultado.' 'Yellow'
}
if ($ytCai) { Escreve 'Obs.: o YouTube também registrou travamento.' 'Yellow' }

$arquivo = Join-Path (Get-Location).Path ("resultado-conserto-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmm'))
$Log.Add('')
$Log.Add('== logcat crash depois do conserto')
$Log.Add($crash)
[System.IO.File]::WriteAllText($arquivo, ($Log -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
Write-Host "Arquivo salvo: $arquivo" -ForegroundColor Cyan
