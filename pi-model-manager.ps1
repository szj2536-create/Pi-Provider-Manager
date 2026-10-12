param(
    [string]$AgentDirectory,
    [switch]$CheckOnly,
    [switch]$UiSmokeTest,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ApiTypes = @('openai-completions', 'openai-responses', 'anthropic-messages')

function Get-AgentRoot {
    if (-not [string]::IsNullOrWhiteSpace($AgentDirectory)) {
        return [System.IO.Path]::GetFullPath($AgentDirectory)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:PI_CODING_AGENT_DIR)) {
        return [System.IO.Path]::GetFullPath($env:PI_CODING_AGENT_DIR)
    }
    return Join-Path $env:USERPROFILE '.pi\agent'
}

$AgentRoot = Get-AgentRoot
$ModelsPath = Join-Path $AgentRoot 'models.json'
$AuthPath = Join-Path $AgentRoot 'auth.json'

function Test-ObjectProperty {
    param([object]$Object, [string]$Name)
    return ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name])
}

function Get-ObjectProperty {
    param([object]$Object, [string]$Name)
    if (Test-ObjectProperty $Object $Name) { return $Object.PSObject.Properties[$Name].Value }
    return $null
}

function Set-ObjectProperty {
    param([object]$Object, [string]$Name, [object]$Value)
    if (Test-ObjectProperty $Object $Name) { $Object.PSObject.Properties[$Name].Value = $Value }
    else { $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value }
}

function Remove-ObjectProperty {
    param([object]$Object, [string]$Name)
    if (Test-ObjectProperty $Object $Name) { $Object.PSObject.Properties.Remove($Name) }
}

function Assert-ProviderName {
    param([string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw '供应商名称只能包含字母、数字、点、下划线和连字符，并且必须以字母或数字开头。'
    }
}

function Assert-BaseUrl {
    param([string]$BaseUrl)
    $uri = $null
    if (-not [uri]::TryCreate($BaseUrl, [System.UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https')) {
        throw 'Base URL 必须是有效的 http:// 或 https:// 地址。'
    }
}

function Assert-ApiType {
    param([string]$ApiType)
    if ($ApiTypes -notcontains $ApiType) { throw "不支持的 API 类型：$ApiType" }
}

function Assert-ModelId {
    param([string]$ModelId)
    if ([string]::IsNullOrWhiteSpace($ModelId) -or $ModelId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]*$') {
        throw "模型 ID 格式无效：$ModelId"
    }
}

function Read-JsonObjectFile {
    param([string]$Path, [string]$DisplayName)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [PSCustomObject]@{ Exists = $false; Original = $null; Object = [PSCustomObject]@{} }
    }
    $original = [System.IO.File]::ReadAllText($Path, $Utf8NoBom)
    if ([string]::IsNullOrWhiteSpace($original)) { throw "$DisplayName 为空，未做任何更改。" }
    try { $object = $original | ConvertFrom-Json }
    catch { throw "$DisplayName 不是有效 JSON：$($_.Exception.Message)" }
    if ($object -isnot [PSCustomObject]) { throw "$DisplayName 的根节点必须是 JSON 对象。" }
    return [PSCustomObject]@{ Exists = $true; Original = $original; Object = $object }
}

function Get-ConfigSnapshot {
    $modelsRecord = Read-JsonObjectFile -Path $ModelsPath -DisplayName 'models.json'
    $authRecord = Read-JsonObjectFile -Path $AuthPath -DisplayName 'auth.json'
    $providers = Get-ObjectProperty $modelsRecord.Object 'providers'
    if ($null -eq $providers) {
        $providers = [PSCustomObject]@{}
        Set-ObjectProperty $modelsRecord.Object 'providers' $providers
    }
    if ($providers -isnot [PSCustomObject]) { throw 'models.json 中的 providers 必须是 JSON 对象。' }
    return [PSCustomObject]@{
        Models = $modelsRecord.Object
        Auth = $authRecord.Object
        ModelsOriginal = $modelsRecord.Original
        AuthOriginal = $authRecord.Original
        ModelsExisted = [bool]$modelsRecord.Exists
        AuthExisted = [bool]$authRecord.Exists
    }
}

function Write-JsonFileAtomic {
    param(
        [string]$Path,
        [string]$Content,
        [AllowNull()][string]$ExpectedOriginal,
        [bool]$ExpectedExists
    )
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    if ($ExpectedExists) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "保存期间文件消失：$Path" }
        $current = [System.IO.File]::ReadAllText($Path, $Utf8NoBom)
        if ($current -cne $ExpectedOriginal) { throw "文件在保存期间被其他程序修改：$Path" }
    } elseif (Test-Path -LiteralPath $Path) {
        throw "保存期间出现了同名文件：$Path"
    }

    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [System.IO.File]::WriteAllText($temp, $Content, $Utf8NoBom)
        if ($ExpectedExists) {
            try {
                Set-Acl -LiteralPath $temp -AclObject (Get-Acl -LiteralPath $Path)
                [System.IO.File]::Replace($temp, $Path, [System.Management.Automation.Language.NullString]::Value)
            } catch {
                $current = [System.IO.File]::ReadAllText($Path, $Utf8NoBom)
                if ($current -cne $ExpectedOriginal) { throw '目标文件已发生变化，无法安全回退为直接写入。' }
                [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
            }
        } else {
            [System.IO.File]::Move($temp, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Restore-OriginalFile {
    param([string]$Path, [bool]$OriginallyExisted, [AllowNull()][string]$Original)
    if ($OriginallyExisted) {
        $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.rollback.tmp'
        try {
            [System.IO.File]::WriteAllText($temp, $Original, $Utf8NoBom)
            if (Test-Path -LiteralPath $Path) {
                try { [System.IO.File]::Replace($temp, $Path, [System.Management.Automation.Language.NullString]::Value) }
                catch { [System.IO.File]::WriteAllText($Path, $Original, $Utf8NoBom) }
            } else { [System.IO.File]::Move($temp, $Path) }
        } finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
    } elseif (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Commit-ConfigSnapshot {
    param([object]$Snapshot, [bool]$ModelsChanged, [bool]$AuthChanged)
    $modelsContent = if ($ModelsChanged) { $Snapshot.Models | ConvertTo-Json -Depth 100 } else { $null }
    $authContent = if ($AuthChanged) { $Snapshot.Auth | ConvertTo-Json -Depth 100 } else { $null }
    $modelsWritten = $false
    $authWritten = $false
    try {
        if ($ModelsChanged) {
            Write-JsonFileAtomic -Path $ModelsPath -Content $modelsContent -ExpectedOriginal $Snapshot.ModelsOriginal -ExpectedExists $Snapshot.ModelsExisted
            $modelsWritten = $true
        }
        if ($AuthChanged) {
            Write-JsonFileAtomic -Path $AuthPath -Content $authContent -ExpectedOriginal $Snapshot.AuthOriginal -ExpectedExists $Snapshot.AuthExisted
            $authWritten = $true
        }
        if ($ModelsChanged) {
            $savedModels = [System.IO.File]::ReadAllText($ModelsPath, $Utf8NoBom)
            if ($savedModels -cne $modelsContent) { throw 'models.json 写入后内容校验失败。' }
            [void]($savedModels | ConvertFrom-Json)
        }
        if ($AuthChanged) {
            $savedAuth = [System.IO.File]::ReadAllText($AuthPath, $Utf8NoBom)
            if ($savedAuth -cne $authContent) { throw 'auth.json 写入后内容校验失败。' }
            [void]($savedAuth | ConvertFrom-Json)
        }
    } catch {
        $reason = $_.Exception.Message
        $rollbackProblems = @()
        if ($authWritten) {
            try { Restore-OriginalFile -Path $AuthPath -OriginallyExisted $Snapshot.AuthExisted -Original $Snapshot.AuthOriginal }
            catch { $rollbackProblems += 'auth.json 回滚失败' }
        }
        if ($modelsWritten) {
            try { Restore-OriginalFile -Path $ModelsPath -OriginallyExisted $Snapshot.ModelsExisted -Original $Snapshot.ModelsOriginal }
            catch { $rollbackProblems += 'models.json 回滚失败' }
        }
        $suffix = if ($rollbackProblems.Count) { '；' + ($rollbackProblems -join '、') } else { '；已回滚本次已写入内容' }
        throw "保存失败：$reason$suffix"
    }
}

function Get-CredentialType {
    param([object]$Credential)
    if ($null -eq $Credential) { return '' }
    $type = [string](Get-ObjectProperty $Credential 'type')
    if ([string]::IsNullOrWhiteSpace($type)) { return 'unknown' }
    return $type
}

function Get-ProviderObject {
    param([object]$Snapshot, [string]$ProviderName)
    return Get-ObjectProperty (Get-ObjectProperty $Snapshot.Models 'providers') $ProviderName
}

function Get-CredentialObject {
    param([object]$Snapshot, [string]$ProviderName)
    return Get-ObjectProperty $Snapshot.Auth $ProviderName
}

function Get-ProviderModels {
    param([object]$Provider)
    if ($null -eq $Provider) { return @() }
    $models = Get-ObjectProperty $Provider 'models'
    if ($null -eq $models) { return @() }
    return @($models)
}

function Add-CustomProvider {
    param([string]$ProviderName, [string]$BaseUrl, [string]$ApiType, [string]$ApiKey, [string[]]$ModelIds)
    Assert-ProviderName $ProviderName
    Assert-BaseUrl $BaseUrl
    Assert-ApiType $ApiType
    if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw 'API Key 不能为空。' }
    $ids = @($ModelIds | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if ($ids.Count -eq 0) { throw '请至少填写一个模型 ID。' }
    foreach ($id in $ids) { Assert-ModelId $id }

    $snapshot = Get-ConfigSnapshot
    $providers = Get-ObjectProperty $snapshot.Models 'providers'
    if (Test-ObjectProperty $providers $ProviderName -or Test-ObjectProperty $snapshot.Auth $ProviderName) {
        throw "供应商或登录凭据「$ProviderName」已经存在。为保护现有凭据，请使用其他名称。"
    }
    $provider = [PSCustomObject]@{
        baseUrl = $BaseUrl
        api = $ApiType
        models = [object[]]@($ids | ForEach-Object { [PSCustomObject]@{ id = $_ } })
    }
    $credential = [PSCustomObject]@{ type = 'api_key'; key = $ApiKey }
    Set-ObjectProperty $providers $ProviderName $provider
    Set-ObjectProperty $snapshot.Auth $ProviderName $credential
    Commit-ConfigSnapshot -Snapshot $snapshot -ModelsChanged $true -AuthChanged $true

    $verify = Get-ConfigSnapshot
    if ($null -eq (Get-ProviderObject $verify $ProviderName) -or (Get-CredentialType (Get-CredentialObject $verify $ProviderName)) -ne 'api_key') {
        throw "保存后校验失败：供应商「$ProviderName」未完整写入。"
    }
}

function Update-CustomProvider {
    param([string]$ProviderName, [string]$BaseUrl, [string]$ApiType)
    Assert-BaseUrl $BaseUrl
    Assert-ApiType $ApiType
    $snapshot = Get-ConfigSnapshot
    $provider = Get-ProviderObject $snapshot $ProviderName
    if ($null -eq $provider) { throw "未找到自定义供应商「$ProviderName」。" }
    Set-ObjectProperty $provider 'baseUrl' $BaseUrl
    Set-ObjectProperty $provider 'api' $ApiType
    Commit-ConfigSnapshot -Snapshot $snapshot -ModelsChanged $true -AuthChanged $false
}

function Update-CustomProviderKey {
    param([string]$ProviderName, [string]$ApiKey)
    if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw '新 API Key 不能为空。' }
    $snapshot = Get-ConfigSnapshot
    if ($null -eq (Get-ProviderObject $snapshot $ProviderName)) { throw "未找到自定义供应商「$ProviderName」。" }
    $credential = Get-CredentialObject $snapshot $ProviderName
    $type = Get-CredentialType $credential
    if ($credential -and $type -ne 'api_key') { throw "供应商「$ProviderName」使用受保护的 $type 登录凭据，不能覆盖。" }
    if ($null -eq $credential) {
        $credential = [PSCustomObject]@{ type = 'api_key'; key = $ApiKey }
        Set-ObjectProperty $snapshot.Auth $ProviderName $credential
    } else {
        Set-ObjectProperty $credential 'key' $ApiKey
    }
    Commit-ConfigSnapshot -Snapshot $snapshot -ModelsChanged $false -AuthChanged $true
}

function Rename-CustomProvider {
    param([string]$OldName, [string]$NewName)
    Assert-ProviderName $NewName
    if ($OldName -eq $NewName) { throw '新名称与当前名称相同。' }
    $snapshot = Get-ConfigSnapshot
    $providers = Get-ObjectProperty $snapshot.Models 'providers'
    $provider = Get-ObjectProperty $providers $OldName
    if ($null -eq $provider) { throw "未找到自定义供应商「$OldName」。" }
    if (Test-ObjectProperty $providers $NewName -or Test-ObjectProperty $snapshot.Auth $NewName) {
        throw "名称「$NewName」已经被供应商或登录凭据使用。"
    }
    $credential = Get-CredentialObject $snapshot $OldName
    $type = Get-CredentialType $credential
    if ($credential -and $type -ne 'api_key') {
        throw "供应商「$OldName」使用受保护的 $type 登录凭据，不能重命名。"
    }
    Remove-ObjectProperty $providers $OldName
    Set-ObjectProperty $providers $NewName $provider
    $authChanged = $false
    if ($credential) {
        Remove-ObjectProperty $snapshot.Auth $OldName
        Set-ObjectProperty $snapshot.Auth $NewName $credential
        $authChanged = $true
    }
    Commit-ConfigSnapshot -Snapshot $snapshot -ModelsChanged $true -AuthChanged $authChanged

    $verify = Get-ConfigSnapshot
    if ($null -ne (Get-ProviderObject $verify $OldName) -or $null -eq (Get-ProviderObject $verify $NewName)) {
        throw '重命名后的校验失败。'
    }
}

function Remove-CustomProvider {
    param([string]$ProviderName)
    $snapshot = Get-ConfigSnapshot
    $providers = Get-ObjectProperty $snapshot.Models 'providers'
    if (-not (Test-ObjectProperty $providers $ProviderName)) { throw "未找到自定义供应商「$ProviderName」。" }
    $credential = Get-CredentialObject $snapshot $ProviderName
    $type = Get-CredentialType $credential
    $removeCredential = ($null -ne $credential -and $type -eq 'api_key')
    Remove-ObjectProperty $providers $ProviderName
    if ($removeCredential) { Remove-ObjectProperty $snapshot.Auth $ProviderName }
    Commit-ConfigSnapshot -Snapshot $snapshot -ModelsChanged $true -AuthChanged $removeCredential

    $verify = Get-ConfigSnapshot
    if ($null -ne (Get-ProviderObject $verify $ProviderName)) { throw '删除后校验失败：models.json 中仍存在该供应商。' }
    if ($removeCredential -and $null -ne (Get-CredentialObject $verify $ProviderName)) {
        throw '删除后校验失败：auth.json 中仍存在该 API Key 凭据。'
    }
}

function Add-ProviderModels {
    param([string]$ProviderName, [string[]]$ModelIds)
    $ids = @($ModelIds | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if ($ids.Count -eq 0) { throw '请至少填写一个模型 ID。' }
    foreach ($id in $ids) { Assert-ModelId $id }
    $snapshot = Get-ConfigSnapshot
    $provider = Get-ProviderObject $snapshot $ProviderName
    if ($null -eq $provider) { throw "未找到自定义供应商「$ProviderName」。" }
    $models = @(Get-ProviderModels $provider)
    $existing = @($models | ForEach-Object { [string](Get-ObjectProperty $_ 'id') })
    $added = 0
    foreach ($id in $ids) {
        if ($existing -notcontains $id) {
            $models += [PSCustomObject]@{ id = $id }
            $existing += $id
            $added++
        }
    }
    if ($added -eq 0) { throw '所填模型均已存在。' }
    Set-ObjectProperty $provider 'models' ([object[]]$models)
    Commit-ConfigSnapshot -Snapshot $snapshot -ModelsChanged $true -AuthChanged $false
}

function Rename-ProviderModel {
    param([string]$ProviderName, [string]$OldModelId, [string]$NewModelId)
    Assert-ModelId $NewModelId
    if ($OldModelId -eq $NewModelId) { throw '新模型 ID 与当前 ID 相同。' }
    $snapshot = Get-ConfigSnapshot
    $provider = Get-ProviderObject $snapshot $ProviderName
    if ($null -eq $provider) { throw "未找到自定义供应商「$ProviderName」。" }
    $models = @(Get-ProviderModels $provider)
    $target = $null
    foreach ($model in $models) {
        $id = [string](Get-ObjectProperty $model 'id')
        if ($id -eq $NewModelId) { throw "模型「$NewModelId」已经存在。" }
        if ($id -eq $OldModelId) { $target = $model }
    }
    if ($null -eq $target) { throw "未找到模型「$OldModelId」。" }
    Set-ObjectProperty $target 'id' $NewModelId
    Set-ObjectProperty $provider 'models' ([object[]]$models)
    Commit-ConfigSnapshot -Snapshot $snapshot -ModelsChanged $true -AuthChanged $false
}

function Remove-ProviderModel {
    param([string]$ProviderName, [string]$ModelId)
    $snapshot = Get-ConfigSnapshot
    $provider = Get-ProviderObject $snapshot $ProviderName
    if ($null -eq $provider) { throw "未找到自定义供应商「$ProviderName」。" }
    $models = @(Get-ProviderModels $provider)
    $remaining = @($models | Where-Object { [string](Get-ObjectProperty $_ 'id') -ne $ModelId })
    if ($remaining.Count -eq $models.Count) { throw "未找到模型「$ModelId」。" }
    Set-ObjectProperty $provider 'models' ([object[]]$remaining)
    Commit-ConfigSnapshot -Snapshot $snapshot -ModelsChanged $true -AuthChanged $false
}

function Get-ProviderRows {
    $snapshot = Get-ConfigSnapshot
    $providers = Get-ObjectProperty $snapshot.Models 'providers'
    $names = @($providers.PSObject.Properties | ForEach-Object { $_.Name }) + @($snapshot.Auth.PSObject.Properties | ForEach-Object { $_.Name })
    $rows = @()
    foreach ($name in @($names | Sort-Object -Unique)) {
        $provider = Get-ObjectProperty $providers $name
        $credential = Get-CredentialObject $snapshot $name
        $credentialType = Get-CredentialType $credential
        $isCustom = $null -ne $provider
        $protected = $null -ne $credential -and $credentialType -ne 'api_key'
        $models = @(Get-ProviderModels $provider)
        $authLabel = if ($null -eq $credential) { '无' } elseif ($credentialType -eq 'api_key') { 'API Key' } elseif ($credentialType -eq 'oauth') { 'OAuth 登录' } else { $credentialType + '（只读）' }
        $category = if ($isCustom -and $protected) { '自定义模型 + 登录凭据' } elseif ($isCustom) { '第三方 API' } else { '登录凭据（只读）' }
        $rows += [PSCustomObject]@{
            Name = [string]$name
            Category = $category
            AuthLabel = $authLabel
            BaseUrl = if ($isCustom) { [string](Get-ObjectProperty $provider 'baseUrl') } else { '' }
            ApiType = if ($isCustom) { [string](Get-ObjectProperty $provider 'api') } else { '' }
            Models = [object[]]$models
            IsCustom = $isCustom
            IsCredentialProtected = $protected
            CredentialType = $credentialType
        }
    }
    return @($rows)
}

function Invoke-SelfTest {
    if ([string]::IsNullOrWhiteSpace($AgentDirectory)) { throw '-SelfTest 必须显式提供临时 AgentDirectory。' }
    $full = [System.IO.Path]::GetFullPath($AgentDirectory)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $full.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '-SelfTest 只允许使用系统临时目录。'
    }
    New-Item -ItemType Directory -Path $AgentRoot -Force | Out-Null
    $initialModels = [PSCustomObject]@{ providers = [PSCustomObject]@{} }
    $initialAuth = [PSCustomObject]@{
        'login-keep' = [PSCustomObject]@{ type = 'oauth'; access = 'FAKE-OAUTH' }
        'key-keep' = [PSCustomObject]@{ type = 'api_key'; key = 'FAKE-KEEP' }
    }
    [System.IO.File]::WriteAllText($ModelsPath, ($initialModels | ConvertTo-Json -Depth 20), $Utf8NoBom)
    [System.IO.File]::WriteAllText($AuthPath, ($initialAuth | ConvertTo-Json -Depth 20), $Utf8NoBom)

    Add-CustomProvider 'test-provider' 'https://example.invalid/v1' 'openai-completions' 'FAKE-NEW' @('model-a')
    Update-CustomProvider 'test-provider' 'https://example.invalid/api' 'openai-responses'
    Update-CustomProviderKey 'test-provider' 'FAKE-UPDATED'
    Add-ProviderModels 'test-provider' @('model-b')
    Rename-ProviderModel 'test-provider' 'model-b' 'model-c'
    Remove-ProviderModel 'test-provider' 'model-a'
    Rename-CustomProvider 'test-provider' 'test-provider-renamed'
    Remove-CustomProvider 'test-provider-renamed'

    $verify = Get-ConfigSnapshot
    if ($null -ne (Get-ProviderObject $verify 'test-provider-renamed')) { throw '自测失败：供应商仍存在。' }
    if ($null -ne (Get-CredentialObject $verify 'test-provider-renamed')) { throw '自测失败：API Key 凭据仍存在。' }
    if ((Get-CredentialType (Get-CredentialObject $verify 'login-keep')) -ne 'oauth') { throw '自测失败：登录凭据被修改。' }
    if ((Get-CredentialType (Get-CredentialObject $verify 'key-keep')) -ne 'api_key') { throw '自测失败：其他 API Key 被修改。' }
    Write-Output 'Independent provider CRUD self-test passed.'
}

if ($SelfTest) { Invoke-SelfTest; exit 0 }
if ($CheckOnly) {
    $rows = @(Get-ProviderRows)
    Write-Output "Configuration valid. Providers/credentials: $($rows.Count). No API request made."
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ColorBackground = [System.Drawing.ColorTranslator]::FromHtml('#F4F6FA')
$ColorPanel = [System.Drawing.Color]::White
$ColorInk = [System.Drawing.ColorTranslator]::FromHtml('#18243A')
$ColorMuted = [System.Drawing.ColorTranslator]::FromHtml('#66758A')
$ColorAccent = [System.Drawing.ColorTranslator]::FromHtml('#3F63E8')
$AppFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)

function New-UiLabel {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height, [bool]$Bold = $false)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    $label.ForeColor = $ColorInk
    if ($Bold) { $label.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold) }
    $Parent.Controls.Add($label)
    return $label
}

function New-UiButton {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width, [bool]$Primary = $false)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($Width, 36)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = if ($Primary) { $ColorAccent } else { [System.Drawing.ColorTranslator]::FromHtml('#E9EDF6') }
    $button.ForeColor = if ($Primary) { [System.Drawing.Color]::White } else { $ColorInk }
    $Parent.Controls.Add($button)
    return $button
}

function Show-AppError {
    param($Owner, $ErrorRecord)
    [System.Windows.Forms.MessageBox]::Show($Owner, $ErrorRecord.Exception.Message, '操作未完成', 'OK', 'Error') | Out-Null
}

function Show-TextInputDialog {
    param($Owner, [string]$Title, [string]$Prompt, [string]$InitialValue = '', [bool]$Secret = $false)
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.ClientSize = New-Object System.Drawing.Size(560, 190)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.BackColor = $ColorBackground
    $dialog.Font = $AppFont
    New-UiLabel $dialog $Prompt 24 22 512 48 $true | Out-Null
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(24, 78)
    $box.Size = New-Object System.Drawing.Size(512, 28)
    $box.Text = $InitialValue
    $box.UseSystemPasswordChar = $Secret
    $dialog.Controls.Add($box)
    $cancel = New-UiButton $dialog '取消' 314 130 104
    $cancel.DialogResult = 'Cancel'
    $ok = New-UiButton $dialog '确定' 432 130 104 $true
    $ok.DialogResult = 'OK'
    $dialog.CancelButton = $cancel
    $dialog.AcceptButton = $ok
    $dialog.Add_Shown({ $box.SelectAll(); $box.Focus() }.GetNewClosure())
    try {
        if ($dialog.ShowDialog($Owner) -eq 'OK') { return $box.Text }
        return $null
    } finally { $box.Text = ''; $dialog.Dispose() }
}

function Show-ModelIdsDialog {
    param($Owner, [string]$ProviderName)
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "新增模型 · $ProviderName"
    $dialog.ClientSize = New-Object System.Drawing.Size(580, 340)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.BackColor = $ColorBackground
    $dialog.Font = $AppFont
    New-UiLabel $dialog "向供应商「$ProviderName」添加模型" 24 20 532 30 $true | Out-Null
    $note = New-UiLabel $dialog '每行一个模型 ID；不会修改供应商的 API Key。' 24 54 532 24
    $note.ForeColor = $ColorMuted
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(24, 86)
    $box.Size = New-Object System.Drawing.Size(532, 170)
    $box.Multiline = $true
    $box.ScrollBars = 'Vertical'
    $box.AcceptsReturn = $true
    $dialog.Controls.Add($box)
    $cancel = New-UiButton $dialog '取消' 334 282 104
    $cancel.DialogResult = 'Cancel'
    $ok = New-UiButton $dialog '添加' 452 282 104 $true
    $ok.DialogResult = 'OK'
    $dialog.CancelButton = $cancel
    $dialog.AcceptButton = $ok
    try {
        if ($dialog.ShowDialog($Owner) -eq 'OK') {
            return @($box.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        return $null
    } finally { $dialog.Dispose() }
}

function Show-NewProviderDialog {
    param($Owner)
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '新增第三方 API'
    $dialog.ClientSize = New-Object System.Drawing.Size(700, 550)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.BackColor = $ColorBackground
    $dialog.Font = $AppFont
    New-UiLabel $dialog '新增第三方 API 供应商' 24 18 652 32 $true | Out-Null
    $note = New-UiLabel $dialog 'API Key 仅写入 Pi 的 auth.json，不会显示或记录。' 24 52 652 24
    $note.ForeColor = $ColorMuted

    New-UiLabel $dialog '供应商名称' 24 92 150 26 $true | Out-Null
    $nameBox = New-Object System.Windows.Forms.TextBox
    $nameBox.Location = New-Object System.Drawing.Point(184, 92)
    $nameBox.Size = New-Object System.Drawing.Size(492, 28)
    $dialog.Controls.Add($nameBox)
    New-UiLabel $dialog 'Base URL' 24 138 150 26 $true | Out-Null
    $urlBox = New-Object System.Windows.Forms.TextBox
    $urlBox.Location = New-Object System.Drawing.Point(184, 138)
    $urlBox.Size = New-Object System.Drawing.Size(492, 28)
    $dialog.Controls.Add($urlBox)
    New-UiLabel $dialog 'API 类型' 24 184 150 26 $true | Out-Null
    $apiBox = New-Object System.Windows.Forms.ComboBox
    $apiBox.Location = New-Object System.Drawing.Point(184, 184)
    $apiBox.Size = New-Object System.Drawing.Size(492, 28)
    $apiBox.DropDownStyle = 'DropDownList'
    $apiBox.Items.AddRange([object[]]$ApiTypes)
    $apiBox.SelectedIndex = 0
    $dialog.Controls.Add($apiBox)
    New-UiLabel $dialog 'API Key' 24 230 150 26 $true | Out-Null
    $keyBox = New-Object System.Windows.Forms.TextBox
    $keyBox.Location = New-Object System.Drawing.Point(184, 230)
    $keyBox.Size = New-Object System.Drawing.Size(492, 28)
    $keyBox.UseSystemPasswordChar = $true
    $dialog.Controls.Add($keyBox)
    New-UiLabel $dialog '模型 ID（每行一个）' 24 278 300 26 $true | Out-Null
    $modelsBox = New-Object System.Windows.Forms.TextBox
    $modelsBox.Location = New-Object System.Drawing.Point(24, 310)
    $modelsBox.Size = New-Object System.Drawing.Size(652, 140)
    $modelsBox.Multiline = $true
    $modelsBox.ScrollBars = 'Vertical'
    $dialog.Controls.Add($modelsBox)
    $cancel = New-UiButton $dialog '取消' 454 490 104
    $cancel.DialogResult = 'Cancel'
    $save = New-UiButton $dialog '保存' 572 490 104 $true
    $dialog.CancelButton = $cancel
    $dialog.AcceptButton = $save
    $save.Add_Click({
        try {
            $name = $nameBox.Text.Trim()
            $url = $urlBox.Text.Trim()
            $key = $keyBox.Text
            $type = [string]$apiBox.SelectedItem
            $ids = @($modelsBox.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
            Assert-ProviderName $name
            Assert-BaseUrl $url
            Assert-ApiType $type
            if ([string]::IsNullOrWhiteSpace($key)) { throw 'API Key 不能为空。' }
            if ($ids.Count -eq 0) { throw '请至少填写一个模型 ID。' }
            foreach ($id in $ids) { Assert-ModelId $id }
            $dialog.Tag = [PSCustomObject]@{ Name = $name; BaseUrl = $url; ApiType = $type; ApiKey = $key; ModelIds = [string[]]$ids }
            $keyBox.Text = ''
            $dialog.DialogResult = 'OK'
            $dialog.Close()
        } catch { Show-AppError $dialog $_ }
    }.GetNewClosure())
    try {
        $dialog.ShowDialog($Owner) | Out-Null
        return $dialog.Tag
    } finally { $keyBox.Text = ''; $dialog.Dispose() }
}

function Show-ProviderSettingsDialog {
    param($Owner, $ProviderRow)
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "编辑供应商 · $($ProviderRow.Name)"
    $dialog.ClientSize = New-Object System.Drawing.Size(620, 270)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.BackColor = $ColorBackground
    $dialog.Font = $AppFont
    New-UiLabel $dialog "编辑「$($ProviderRow.Name)」" 24 20 572 30 $true | Out-Null
    New-UiLabel $dialog 'Base URL' 24 76 130 26 $true | Out-Null
    $urlBox = New-Object System.Windows.Forms.TextBox
    $urlBox.Location = New-Object System.Drawing.Point(164, 76)
    $urlBox.Size = New-Object System.Drawing.Size(432, 28)
    $urlBox.Text = $ProviderRow.BaseUrl
    $dialog.Controls.Add($urlBox)
    New-UiLabel $dialog 'API 类型' 24 126 130 26 $true | Out-Null
    $apiBox = New-Object System.Windows.Forms.ComboBox
    $apiBox.Location = New-Object System.Drawing.Point(164, 126)
    $apiBox.Size = New-Object System.Drawing.Size(432, 28)
    $apiBox.DropDownStyle = 'DropDownList'
    $apiBox.Items.AddRange([object[]]$ApiTypes)
    $apiBox.SelectedItem = $ProviderRow.ApiType
    if ($apiBox.SelectedIndex -lt 0) { $apiBox.SelectedIndex = 0 }
    $dialog.Controls.Add($apiBox)
    $cancel = New-UiButton $dialog '取消' 374 206 104
    $cancel.DialogResult = 'Cancel'
    $save = New-UiButton $dialog '保存' 492 206 104 $true
    $save.DialogResult = 'OK'
    $dialog.CancelButton = $cancel
    $dialog.AcceptButton = $save
    try {
        if ($dialog.ShowDialog($Owner) -eq 'OK') {
            $url = $urlBox.Text.Trim()
            $type = [string]$apiBox.SelectedItem
            Assert-BaseUrl $url
            Assert-ApiType $type
            return [PSCustomObject]@{ BaseUrl = $url; ApiType = $type }
        }
        return $null
    } finally { $dialog.Dispose() }
}

function Open-ManagedFile {
    param($Owner, [string]$Path, [bool]$ContainsSecrets = $false)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "文件尚不存在：$Path" }
    if ($ContainsSecrets) {
        $answer = [System.Windows.Forms.MessageBox]::Show($Owner, 'auth.json 可能包含 API Key 和登录令牌。确定使用系统默认程序打开吗？', '敏感文件提醒', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }
    Start-Process -FilePath $Path | Out-Null
}

function New-MainWindow {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Pi 模型与第三方 API 管理器'
    $form.ClientSize = New-Object System.Drawing.Size(1040, 720)
    $form.MinimumSize = New-Object System.Drawing.Size(1056, 759)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = $ColorBackground
    $form.Font = $AppFont

    New-UiLabel $form 'Pi 模型与第三方 API 管理器' 28 18 700 34 $true | Out-Null
    $pathLabel = New-UiLabel $form "Pi 配置目录：$AgentRoot" 28 54 984 24
    $pathLabel.ForeColor = $ColorMuted

    $addProvider = New-UiButton $form '新增供应商' 28 88 126 $true
    $editProvider = New-UiButton $form '编辑地址/API' 164 88 126
    $updateKey = New-UiButton $form '更新 API Key' 300 88 126
    $renameProvider = New-UiButton $form '重命名' 436 88 110
    $deleteProvider = New-UiButton $form '删除供应商' 556 88 126
    $refresh = New-UiButton $form '刷新' 692 88 96

    $providerList = New-Object System.Windows.Forms.ListView
    $providerList.Location = New-Object System.Drawing.Point(28, 136)
    $providerList.Size = New-Object System.Drawing.Size(984, 250)
    $providerList.Anchor = 'Top,Left,Right'
    $providerList.View = 'Details'
    $providerList.FullRowSelect = $true
    $providerList.MultiSelect = $false
    $providerList.HideSelection = $false
    $providerList.Columns.Add('供应商', 170) | Out-Null
    $providerList.Columns.Add('类别', 180) | Out-Null
    $providerList.Columns.Add('凭据', 120) | Out-Null
    $providerList.Columns.Add('Base URL', 260) | Out-Null
    $providerList.Columns.Add('API 类型', 170) | Out-Null
    $providerList.Columns.Add('模型数', 70) | Out-Null
    $form.Controls.Add($providerList)

    New-UiLabel $form '所选供应商的模型' 28 400 300 28 $true | Out-Null
    $addModel = New-UiButton $form '新增模型' 596 396 120
    $renameModel = New-UiButton $form '修改模型 ID' 726 396 130
    $deleteModel = New-UiButton $form '删除模型' 866 396 120

    $modelList = New-Object System.Windows.Forms.ListView
    $modelList.Location = New-Object System.Drawing.Point(28, 438)
    $modelList.Size = New-Object System.Drawing.Size(984, 150)
    $modelList.Anchor = 'Top,Bottom,Left,Right'
    $modelList.View = 'Details'
    $modelList.FullRowSelect = $true
    $modelList.MultiSelect = $false
    $modelList.HideSelection = $false
    $modelList.Columns.Add('模型 ID', 420) | Out-Null
    $modelList.Columns.Add('模型名称/类型（如有）', 520) | Out-Null
    $form.Controls.Add($modelList)

    $openModels = New-UiButton $form '打开 models.json' 28 606 150
    $openAuth = New-UiButton $form '打开 auth.json' 188 606 150
    $openFolder = New-UiButton $form '打开配置目录' 348 606 140
    $chooseFile = New-UiButton $form '选择文件打开' 498 606 140
    $status = New-UiLabel $form '准备读取配置。' 28 660 984 34
    $status.ForeColor = $ColorMuted
    $status.Anchor = 'Bottom,Left,Right'

    $getSelectedProvider = {
        if ($providerList.SelectedItems.Count -eq 0) { return $null }
        return $providerList.SelectedItems[0].Tag
    }.GetNewClosure()
    $getSelectedModelId = {
        if ($modelList.SelectedItems.Count -eq 0) { return $null }
        return [string]$modelList.SelectedItems[0].Text
    }.GetNewClosure()

    $updateButtons = {
        $row = & $getSelectedProvider
        $custom = $null -ne $row -and [bool]$row.IsCustom
        $editProvider.Enabled = $custom
        $updateKey.Enabled = $custom -and -not [bool]$row.IsCredentialProtected
        $renameProvider.Enabled = $custom -and -not [bool]$row.IsCredentialProtected
        $deleteProvider.Enabled = $custom
        $addModel.Enabled = $custom
        $hasModel = $custom -and $modelList.SelectedItems.Count -gt 0
        $renameModel.Enabled = $hasModel
        $deleteModel.Enabled = $hasModel
    }.GetNewClosure()

    $showModels = {
        $modelList.Items.Clear()
        $row = & $getSelectedProvider
        if ($null -ne $row -and $row.IsCustom) {
            foreach ($model in @($row.Models)) {
                $id = [string](Get-ObjectProperty $model 'id')
                $name = [string](Get-ObjectProperty $model 'name')
                $type = [string](Get-ObjectProperty $model 'type')
                $detail = @($name, $type | Where-Object { $_ }) -join ' / '
                $item = New-Object System.Windows.Forms.ListViewItem($id)
                $item.SubItems.Add($detail) | Out-Null
                $modelList.Items.Add($item) | Out-Null
            }
        }
        & $updateButtons
    }.GetNewClosure()

    $reload = {
        param([string]$SelectName)
        $providerList.Items.Clear()
        $modelList.Items.Clear()
        $rows = @(Get-ProviderRows)
        foreach ($row in $rows) {
            $item = New-Object System.Windows.Forms.ListViewItem($row.Name)
            $item.SubItems.Add($row.Category) | Out-Null
            $item.SubItems.Add($row.AuthLabel) | Out-Null
            $item.SubItems.Add($row.BaseUrl) | Out-Null
            $item.SubItems.Add($row.ApiType) | Out-Null
            $item.SubItems.Add([string]$row.Models.Count) | Out-Null
            $item.Tag = $row
            $providerList.Items.Add($item) | Out-Null
            if ($SelectName -and $row.Name -eq $SelectName) { $item.Selected = $true; $item.Focused = $true }
        }
        if ($providerList.SelectedItems.Count -gt 0) { $providerList.EnsureVisible($providerList.SelectedItems[0].Index) }
        $status.Text = "已读取 $($rows.Count) 个供应商/凭据。登录凭据保持只读；列表不会显示任何 Key。"
        & $showModels
    }.GetNewClosure()

    $providerList.Add_SelectedIndexChanged($showModels)
    $modelList.Add_SelectedIndexChanged($updateButtons)

    $refresh.Add_Click({
        try { & $reload $null } catch { Show-AppError $form $_ }
    }.GetNewClosure())

    $addProvider.Add_Click({
        try {
            $data = Show-NewProviderDialog $form
            if ($null -eq $data) { return }
            Add-CustomProvider $data.Name $data.BaseUrl $data.ApiType $data.ApiKey $data.ModelIds
            $data.ApiKey = ''
            & $reload $data.Name
            $status.Text = "已新增供应商 $($data.Name)。请重启正在运行的 Pi 会话以加载变化。"
        } catch { Show-AppError $form $_ }
    }.GetNewClosure())

    $editProvider.Add_Click({
        try {
            $row = & $getSelectedProvider
            if ($null -eq $row -or -not $row.IsCustom) { return }
            $data = Show-ProviderSettingsDialog $form $row
            if ($null -eq $data) { return }
            Update-CustomProvider $row.Name $data.BaseUrl $data.ApiType
            & $reload $row.Name
            $status.Text = "已更新供应商 $($row.Name)。"
        } catch { Show-AppError $form $_ }
    }.GetNewClosure())

    $updateKey.Add_Click({
        try {
            $row = & $getSelectedProvider
            if ($null -eq $row -or -not $row.IsCustom -or $row.IsCredentialProtected) { return }
            $key = Show-TextInputDialog $form '更新 API Key' "输入供应商「$($row.Name)」的新 API Key（不会显示原 Key）" '' $true
            if ($null -eq $key) { return }
            Update-CustomProviderKey $row.Name $key
            $key = ''
            & $reload $row.Name
            $status.Text = "已更新供应商 $($row.Name) 的 API Key。"
        } catch { Show-AppError $form $_ }
    }.GetNewClosure())

    $renameProvider.Add_Click({
        try {
            $row = & $getSelectedProvider
            if ($null -eq $row -or -not $row.IsCustom -or $row.IsCredentialProtected) { return }
            $newName = Show-TextInputDialog $form '重命名供应商' "输入「$($row.Name)」的新名称" $row.Name
            if ($null -eq $newName) { return }
            $newName = $newName.Trim()
            Rename-CustomProvider $row.Name $newName
            & $reload $newName
            $status.Text = "已将供应商重命名为 $newName。"
        } catch { Show-AppError $form $_ }
    }.GetNewClosure())

    $deleteProvider.Add_Click({
        try {
            $row = & $getSelectedProvider
            if ($null -eq $row -or -not $row.IsCustom) { return }
            $credentialLine = if ($row.IsCredentialProtected) { "`n其 $($row.CredentialType) 登录凭据将被保留。" } else { "`n对应的 API Key 凭据也会删除。" }
            $answer = [System.Windows.Forms.MessageBox]::Show($form, "确定删除第三方供应商「$($row.Name)」及其所有模型吗？$credentialLine`n`n此操作不会撤销服务商网站上的令牌。", '确认删除供应商', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }
            Remove-CustomProvider $row.Name
            & $reload $null
            $status.Text = "已删除供应商 $($row.Name)。"
        } catch { Show-AppError $form $_ }
    }.GetNewClosure())

    $addModel.Add_Click({
        try {
            $row = & $getSelectedProvider
            if ($null -eq $row -or -not $row.IsCustom) { return }
            $ids = Show-ModelIdsDialog $form $row.Name
            if ($null -eq $ids) { return }
            Add-ProviderModels $row.Name $ids
            & $reload $row.Name
            $status.Text = "已向 $($row.Name) 添加模型。"
        } catch { Show-AppError $form $_ }
    }.GetNewClosure())

    $renameModel.Add_Click({
        try {
            $row = & $getSelectedProvider
            $oldId = & $getSelectedModelId
            if ($null -eq $row -or -not $oldId) { return }
            $newId = Show-TextInputDialog $form '修改模型 ID' "输入模型「$oldId」的新 ID" $oldId
            if ($null -eq $newId) { return }
            $newId = $newId.Trim()
            Rename-ProviderModel $row.Name $oldId $newId
            & $reload $row.Name
            $status.Text = "已将模型 $oldId 修改为 $newId。"
        } catch { Show-AppError $form $_ }
    }.GetNewClosure())

    $deleteModel.Add_Click({
        try {
            $row = & $getSelectedProvider
            $modelId = & $getSelectedModelId
            if ($null -eq $row -or -not $modelId) { return }
            $answer = [System.Windows.Forms.MessageBox]::Show($form, "确定从「$($row.Name)」删除模型「$modelId」吗？`n供应商及共享 API Key 会保留。", '确认删除模型', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }
            Remove-ProviderModel $row.Name $modelId
            & $reload $row.Name
            $status.Text = "已删除模型 $modelId；供应商和 API Key 已保留。"
        } catch { Show-AppError $form $_ }
    }.GetNewClosure())

    $openModels.Add_Click({ try { Open-ManagedFile $form $ModelsPath $false } catch { Show-AppError $form $_ } }.GetNewClosure())
    $openAuth.Add_Click({ try { Open-ManagedFile $form $AuthPath $true } catch { Show-AppError $form $_ } }.GetNewClosure())
    $openFolder.Add_Click({
        try {
            if (-not (Test-Path -LiteralPath $AgentRoot -PathType Container)) { New-Item -ItemType Directory -Path $AgentRoot -Force | Out-Null }
            Start-Process explorer.exe -ArgumentList @("`"$AgentRoot`"") | Out-Null
        } catch { Show-AppError $form $_ }
    }.GetNewClosure())
    $chooseFile.Add_Click({
        $picker = New-Object System.Windows.Forms.OpenFileDialog
        try {
            $picker.Title = '选择要打开的配置文件'
            $picker.InitialDirectory = if (Test-Path -LiteralPath $AgentRoot) { $AgentRoot } else { $env:USERPROFILE }
            $picker.Filter = 'JSON 文件 (*.json)|*.json|所有文件 (*.*)|*.*'
            if ($picker.ShowDialog($form) -eq 'OK') { Start-Process -FilePath $picker.FileName | Out-Null }
        } catch { Show-AppError $form $_ }
        finally { $picker.Dispose() }
    }.GetNewClosure())

    $form.Add_Shown({ try { & $reload $null } catch { Show-AppError $form $_ } }.GetNewClosure())
    & $updateButtons
    return [PSCustomObject]@{ Form = $form; ProviderList = $providerList; ModelList = $modelList; Reload = $reload; Status = $status }
}

$app = New-MainWindow
if ($UiSmokeTest) {
    try {
        # 不进入消息循环，避免自动化测试被任何模态窗口阻塞。
        & $app.Reload $null
        if ($app.ProviderList.Columns.Count -ne 6) { throw '供应商列表列数错误。' }
        if ($app.ModelList.Columns.Count -ne 2) { throw '模型列表列数错误。' }
        Write-Output 'Independent GUI smoke test passed.'
    } finally { $app.Form.Dispose() }
    exit 0
}

try { $app.Form.ShowDialog() | Out-Null }
finally { $app.Form.Dispose() }
