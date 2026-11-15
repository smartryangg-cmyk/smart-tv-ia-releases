# Smart TV IA - coleta de diagnostico (so leitura; abre o YouTube e a Netflix por alguns segundos para ver o erro)
# Uso (na pasta do adb):  powershell -ExecutionPolicy Bypass -File .\coletar-diagnostico.ps1
param([string]$Ip = "192.168.0.112")
$ErrorActionPreference = "Continue"
$adb = Join-Path $PSScriptRoot "adb.exe"
if (-not (Test-Path $adb)) { $adb = "adb" }
$out = Join-Path $PSScriptRoot ("diagnostico-tv-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".txt")

function Sec($titulo, $cmd) {
  Add-Content -Path $out -Value "`r`n===== $titulo =====`r`n> $cmd" -Encoding UTF8
  $r = & $adb shell $cmd 2>&1 | Out-String
  Add-Content -Path $out -Value $r -Encoding UTF8
  Write-Host "ok: $titulo"
}

& $adb connect "$($Ip):5555" | Out-Null
Set-Content -Path $out -Value "Diagnostico Smart TV IA - $(Get-Date)" -Encoding UTF8

Sec "Aparelho" "getprop ro.product.model; getprop ro.product.device; getprop ro.build.fingerprint; getprop ro.build.version.release; getprop ro.build.version.security_patch; getprop ro.product.cpu.abilist"
Sec "Data, hora e fuso" "date; settings get global auto_time; settings get global auto_time_zone; getprop persist.sys.timezone"
Sec "Rede" "ip addr show | grep -E 'inet |state'; getprop net.dns1; getprop net.dns2; settings get global private_dns_mode; settings get global private_dns_specifier; settings get global http_proxy; settings get global captive_portal_mode"
Sec "Ping IP" "ping -c 3 -W 3 8.8.8.8"
Sec "Ping nome" "ping -c 3 -W 3 www.google.com"
Sec "Ping YouTube/Netflix" "ping -c 2 -W 3 www.youtube.com; ping -c 2 -W 3 api-global.netflix.com"
Sec "Wi-Fi" "dumpsys wifi | grep -E 'mWifiInfo|Supplicant state|mNetworkInfo' | head -5"
Sec "Conectividade" "dumpsys connectivity | grep -E 'NetworkAgentInfo|VALIDATED|PARTIAL|CAPTIVE' | head -12"
Sec "Versoes dos apps Google/streaming" 'for p in com.google.android.gms com.google.android.gsf com.android.vending com.google.android.webview com.android.webview com.android.chrome com.google.android.youtube.tv com.google.android.youtube com.netflix.ninja com.netflix.mediaclient com.google.android.tvlauncher com.google.android.leanbacklauncher br.smarttvia.launcher; do echo "== $p"; dumpsys package $p | grep -E ''versionName|enabled=|targetSdk'' | head -4; done'
Sec "WebView em uso" "dumpsys webviewupdate"
Sec "Apps desativados" "pm list packages -d"
Sec "Tela inicial atual" "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME"
Sec "Contas Google (so a quantidade)" "dumpsys account | grep -c 'Account {'"
Sec "Memoria" "cat /proc/meminfo | head -4"

# Abre o YouTube e a Netflix e guarda o log dos erros
foreach ($app in @(
  @{n="YouTube"; c="monkey -p com.google.android.youtube.tv -c android.intent.category.LEANBACK_LAUNCHER 1"},
  @{n="Netflix"; c="monkey -p com.netflix.ninja -c android.intent.category.LEANBACK_LAUNCHER 1"})) {
  & $adb logcat -c
  & $adb shell $app.c | Out-Null
  Write-Host "Abrindo $($app.n)... aguarde 20 s (nao mexa na TV)"
  Start-Sleep -Seconds 20
  Add-Content -Path $out -Value "`r`n===== LOG ao abrir $($app.n) =====" -Encoding UTF8
  $log = & $adb logcat -d -v time "*:W" 2>&1 | Select-Object -Last 400 | Out-String
  Add-Content -Path $out -Value $log -Encoding UTF8
  & $adb shell input keyevent KEYCODE_HOME | Out-Null
}

Write-Host ""
Write-Host "Pronto! Mande este arquivo no chat: $out"
