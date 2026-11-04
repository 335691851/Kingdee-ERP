$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
if (-not (Test-Path -LiteralPath '.venv/Scripts/python.exe')) {
    py -3.12 -m venv .venv
    if ($LASTEXITCODE -ne 0) { throw '需要先安装 Python 3.12。' }
}
& ./.venv/Scripts/python.exe -m pip install -r requirements.txt
if ($LASTEXITCODE -ne 0) { throw '依赖安装失败。' }
if (-not (Test-Path -LiteralPath '.env.local')) { Copy-Item -LiteralPath '.env.example' -Destination '.env.local' }
if (-not (Test-Path -LiteralPath 'work/erp.db')) {
    & ./.venv/Scripts/python.exe scripts/seed.py --cycles 10000
    if ($LASTEXITCODE -ne 0) { throw '模拟数据初始化失败，请查看上方信息。' }
}
& ./.venv/Scripts/python.exe scripts/init_db.py
if ($LASTEXITCODE -ne 0) { throw '本地数据表升级失败。' }
Write-Host '打开 http://127.0.0.1:8765 ，本地账户：admin / luyan-demo-2026'
& ./.venv/Scripts/python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8765
