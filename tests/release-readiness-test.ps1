$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$projectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$requiredIgnoreRules = @('_tickets/', '_receipts/', 'auth.json', 'models.json', '*.log', '*.tmp', '*.rollback.tmp')
$allowedTopLevel = @('.gitignore', 'README.md', 'start.cmd', 'pi-model-manager.ps1', 'tests', '.git', '_tickets', '_receipts')
$managedTopLevelFiles = @('.gitignore', 'README.md', 'start.cmd', 'pi-model-manager.ps1')
$localOnlyDirectories = @('.git', '_tickets', '_receipts')
$stagingRoot = Join-Path $env:TEMP ('pi-provider-manager release copy ' + [guid]::NewGuid().ToString('N'))

function Get-RelativeProjectPath {
    param([string]$FullName)
    $prefix = $projectRoot.TrimEnd('\', '/') + [string][char]92
    return $FullName.Substring($prefix.Length).Replace([string][char]92, '/')
}

function Invoke-PowerShellFile {
    param(
        [string]$ScriptPath,
        [string[]]$Arguments
    )
    $output = & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "命令失败（退出码 $LASTEXITCODE）：$ScriptPath`n$($output -join [Environment]::NewLine)"
    }
    return @($output)
}

$testError = $null
try {
    # 先从实际树检查顶层；托管资料施工期间保留，但永远不进入发布副本。
    $topLevelEntries = @(Get-ChildItem -LiteralPath $projectRoot -Force)
    $unexpectedTopLevel = @($topLevelEntries | Where-Object { $allowedTopLevel -notcontains $_.Name })
    if ($unexpectedTopLevel.Count -gt 0) {
        throw ('Unexpected top-level entries: ' + (($unexpectedTopLevel | ForEach-Object Name) -join ', '))
    }
    foreach ($requiredFile in $managedTopLevelFiles) {
        $requiredPath = Join-Path $projectRoot $requiredFile
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "缺少发布文件：$requiredFile" }
    }
    $testsRoot = Join-Path $projectRoot 'tests'
    if (-not (Test-Path -LiteralPath $testsRoot -PathType Container)) { throw '缺少发布目录：tests' }

    $releaseFiles = @(
        $topLevelEntries |
            Where-Object { $_.PSIsContainer -eq $false -and $managedTopLevelFiles -contains $_.Name } |
            ForEach-Object { Get-RelativeProjectPath $_.FullName }
        Get-ChildItem -LiteralPath $testsRoot -Recurse -File | ForEach-Object { Get-RelativeProjectPath $_.FullName }
    ) | Sort-Object -Unique
    if ($releaseFiles.Count -eq 0) { throw '实际发布面为空。' }

    $ignorePath = Join-Path $projectRoot '.gitignore'
    $ignoreLines = @(Get-Content -LiteralPath $ignorePath)
    $missing = @($requiredIgnoreRules | Where-Object { $ignoreLines -notcontains $_ })
    if ($missing.Count -gt 0) { throw ('缺少忽略规则: ' + ($missing -join ', ')) }

    # 用拼接构造规则及样例，避免规则自身因包含测试样例而自匹配。
    $drive = '[A-Z]'
    $backslash = [string][char]92
    $regexBackslash = $backslash + $backslash
    $slash = [string][char]47
    $fixedPathPattern = '(?i)(?:' + $drive + ':' + $regexBackslash + '|' + $slash + 'Users' + $slash + '|' + $slash + 'home' + $slash + ')'
    $positiveWindowsPath = 'D' + ':' + $backslash + 'build' + $backslash + 'private.json'
    $positiveWindowsPath2 = 'z' + ':' + $backslash + 'work' + $backslash + 'machine-config.json'
    $negativeWindowsPath = 'relative' + $backslash + 'path.json'
    if ($positiveWindowsPath -notmatch $fixedPathPattern -or $positiveWindowsPath2 -notmatch $fixedPathPattern) {
        throw '任意盘符 Windows 绝对路径规则自检失败：正例未匹配。'
    }
    if ($negativeWindowsPath -match $fixedPathPattern -or 'C:relative.txt' -match $fixedPathPattern) {
        throw '任意盘符 Windows 绝对路径规则自检失败：反例误匹配。'
    }
    if (('x' + $slash + 'Users' + $slash + 'name') -notmatch $fixedPathPattern -or
        ('x' + $slash + 'home' + $slash + 'name') -notmatch $fixedPathPattern) {
        throw 'Unix 用户目录规则自检失败。'
    }

    $privateKeyPattern = 'BEGIN ' + '(RSA|OPENSSH|EC|DSA)' + ' PRIVATE KEY'
    $secretAssignmentPattern = '(?i)(' + 'auth' + '\.json|models' + '\.json)' + '\s*[:=]\s*[^\r\n]*secret|(?:' + 'api[_-]?key|token|password' + ')' + '\s*[:=]\s*["''][^"'']{12,}["'']'
    $forbiddenNames = @('auth.json', 'models.json', '*.log', '*.tmp', '*.rollback.tmp')
    foreach ($relativePath in $releaseFiles) {
        $sourcePath = Join-Path $projectRoot ($relativePath -replace '/', '\')
        $content = [System.IO.File]::ReadAllText($sourcePath)
        if ($content -match $fixedPathPattern -or $content -match $privateKeyPattern) {
            throw "发布文件含固定本机路径或私钥材料：$relativePath"
        }
        if ($content -match $secretAssignmentPattern) {
            throw "发布文件疑似含敏感值：$relativePath"
        }
    }

    foreach ($namePattern in $forbiddenNames) {
        $found = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File -Filter $namePattern -ErrorAction SilentlyContinue |
            Where-Object {
                $relative = Get-RelativeProjectPath $_.FullName
                $parts = $relative -split '/'
                $parts[0] -notin $localOnlyDirectories
            })
        if ($found.Count -gt 0) { throw "公开发布面发现禁止的生成/敏感文件：$namePattern" }
    }

    New-Item -ItemType Directory -Path (Join-Path $stagingRoot 'tests') -Force | Out-Null
    foreach ($relativePath in $releaseFiles) {
        $sourcePath = Join-Path $projectRoot ($relativePath -replace '/', '\')
        $destinationPath = Join-Path $stagingRoot ($relativePath -replace '/', '\')
        $destinationDirectory = Split-Path -Parent $destinationPath
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    }

    $sourceSmoke = Invoke-PowerShellFile (Join-Path $projectRoot 'tests/smoke-test.ps1') @()
    $copySmoke = Invoke-PowerShellFile (Join-Path $stagingRoot 'tests/smoke-test.ps1') @()
    Write-Output 'Release file privacy and ignore-rule checks passed.'
    $sourceSmoke | ForEach-Object { Write-Output $_ }
    $copySmoke | ForEach-Object { Write-Output $_ }
    Write-Output 'Portable temporary-path copy test passed.'
} catch {
    $testError = $_
}

$cleanupError = $null
try {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $stagingRoot) {
        throw "发布临时副本清理后仍存在：$stagingRoot"
    }
} catch {
    $cleanupError = $_
}

if ($testError -and $cleanupError) {
    throw "发布检查失败：$($testError.Exception.Message)`n临时发布副本清理失败：$($cleanupError.Exception.Message)`n路径：$stagingRoot"
}
if ($testError) { throw $testError }
if ($cleanupError) {
    throw "临时发布副本清理失败：$($cleanupError.Exception.Message)`n路径：$stagingRoot"
}
