$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $PSScriptRoot

python -m pip install -r requirements.txt
if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' }
python build_exe.py
if ($LASTEXITCODE -ne 0) { throw 'Windows executable build failed.' }

Write-Host "Windows executable: $PSScriptRoot\dist\StarlyBridge.exe"
