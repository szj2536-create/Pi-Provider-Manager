$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = Join-Path $projectRoot 'pi-model-manager.ps1'
if (-not (Test-Path -LiteralPath $mainScript -PathType Leaf)) { throw '未找到 pi-model-manager.ps1。' }

$tempAgent = Join-Path $env:TEMP ('pi-model-manager-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempAgent | Out-Null
$testError = $null
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $mainScript -SelfTest -AgentDirectory $tempAgent
    if ($LASTEXITCODE -ne 0) { throw "CRUD 自测失败，退出码：$LASTEXITCODE" }

    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $mainScript -UiSmokeTest -AgentDirectory $tempAgent
    if ($LASTEXITCODE -ne 0) { throw "GUI 冒烟测试失败，退出码：$LASTEXITCODE" }

    Write-Output 'All standalone project tests passed.'
} catch {
    $testError = $_
}

$cleanupError = $null
try {
    if (Test-Path -LiteralPath $tempAgent) {
        Remove-Item -LiteralPath $tempAgent -Recurse -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $tempAgent) {
        throw "临时目录清理后仍存在：$tempAgent"
    }
} catch {
    $cleanupError = $_
}

if ($testError -and $cleanupError) {
    throw "测试失败：$($testError.Exception.Message)`n临时目录清理失败：$($cleanupError.Exception.Message)`n路径：$tempAgent"
}
if ($testError) { throw $testError }
if ($cleanupError) {
    throw "临时目录清理失败：$($cleanupError.Exception.Message)`n路径：$tempAgent"
}
