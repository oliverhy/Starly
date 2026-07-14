param(
  [string]$DevEcoRoot = $env:DEVECO_STUDIO_HOME
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($DevEcoRoot)) {
  throw '请通过 -DevEcoRoot 参数或 DEVECO_STUDIO_HOME 环境变量指定 DevEco Studio 安装目录。'
}
$Hvigor = Join-Path $DevEcoRoot 'tools\hvigor\bin\hvigorw.bat'
if (-not (Test-Path -LiteralPath $Hvigor)) {
  throw "未找到 Hvigor：$Hvigor"
}
$env:DEVECO_SDK_HOME = "$DevEcoRoot\sdk"
$env:OHOS_SDK_HOME = "$DevEcoRoot\sdk\default\openharmony"
$env:JAVA_HOME = "$DevEcoRoot\jbr"
$env:Path = "$env:JAVA_HOME\bin;$env:Path"

Set-Location $ProjectRoot
& $Hvigor --mode module -p product=default assembleHap --no-daemon
if ($LASTEXITCODE -ne 0) { throw 'HarmonyOS build failed.' }

& "$ProjectRoot\pc\build.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }

$ReleaseDir = "$ProjectRoot\release"
New-Item -ItemType Directory -Force -Path $ReleaseDir | Out-Null
$Hap = Get-ChildItem "$ProjectRoot\entry\build\default\outputs\default" -Filter '*-signed.hap' -Recurse |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($null -eq $Hap) {
  throw 'HarmonyOS HAP output was not found.'
}
Copy-Item -Force -LiteralPath $Hap.FullName -Destination "$ReleaseDir\Starly.hap"
Copy-Item -Force -LiteralPath "$ProjectRoot\pc\dist\StarlyBridge.exe" -Destination "$ReleaseDir\StarlyBridge.exe"
Copy-Item -Force -LiteralPath "$ProjectRoot\README.md" -Destination "$ReleaseDir\使用说明.md"

Write-Host "Release files: $ReleaseDir"
